import { ble, connection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TokenConfig } from './TokenConfig';
import { TokenStore } from './TokenStore';
import { AppPreference, PREF_KEYS, SettingValue } from './AppPreference';
import { decryptBlePayload, encryptBlePayload } from './CryptoUtils';

const TAG = 'BleTokenTransfer';
const DOMAIN = 0xFF01;

/**
 * 手机→手表 蓝牙(BLE)令牌传输方案.
 *
 * 背景: 分布式 KV 同步受"数据库安全等级 ≤ 对端设备安全等级"约束,
 * 手表为低安全设备, S4 存储(令牌属认证凭据, 不能降级)无法与其跨设备同步.
 * 因此改用 BLE 手动传输: 手表端 GATT Server 广播接收, 手机端 GATT Client 扫描连接后写入.
 *
 * 安全模型(双层):
 * - 系统 BLE 配对(connection.pairDevice, LE Secure Connections): 链路层由系统 LTK 加密,
 *   未 bonded 的设备禁止传输 secret 载荷
 * - 应用层 AES-256-GCM(encryptBlePayload/decryptBlePayload): 链路被降级/未加密时的纵深防御,
 *   防被动嗅探与内容篡改(tag 校验)
 *
 * 传输协议(分片):
 * - 首帧: JSON 头 {"total": 数据总字节数, "count": 令牌数}
 * - 后续帧: ≤ MAX_CHUNK 字节的加密数据分片(AES-256-GCM, 载荷格式 [MAGIC][iv][tag][ciphertext])
 * - 接收方按 total 重组, 解密后解析为 TokenConfig 数组, 逐条写入 TokenStore
 */

/** 自定义 GATT 服务 UUID(两端必须一致) */
export const BLE_SERVICE_UUID = 'aabbccdd-0000-1000-8000-00805f9b34fb';
/** 自定义 GATT 写特征 UUID */
export const BLE_CHAR_UUID = 'aabbccdd-0001-1000-8000-00805f9b34fb';
/** 广播响应包中携带设备名的自定义服务 UUID(手机端经 ScanResult.serviceDataMap 解析) */
export const BLE_NAME_UUID = 'aabbccdd-0002-1000-8000-00805f9b34fb';
/** 手表端广播的显示名(legacy 广播包 31B 限制: 主包放 128 位服务 UUID, 名字走响应包) */
const BLE_ADV_DEVICE_NAME = 'OHOTP Watch';

/**
 * 解析设备显示名: 广播名 → 响应包自定义名 → 系统已知名 → deviceId 兜底.
 * 手表端广播未携带标准设备名时, deviceName 为空会显示一串数字, 本函数逐级兜底.
 */
export function getDeviceDisplayName(device: ble.ScanResult): string {
  if (device.deviceName.length > 0) {
    return device.deviceName;
  }
  const nameBytes = device.serviceDataMap?.get(BLE_NAME_UUID);
  if (nameBytes !== undefined && nameBytes.byteLength > 0) {
    return new util.TextDecoder('utf-8').decodeToString(nameBytes);
  }
  try {
    const remoteName = connection.getRemoteDeviceName(device.deviceId);
    if (remoteName.length > 0) {
      return remoteName;
    }
  } catch (err) {
    // 未配对设备查询远端名可能失败, 忽略走兜底
  }
  return device.deviceId;
}

/** 单次 GATT 写入最大载荷(默认 MTU 下留安全余量) */
const MAX_CHUNK = 480;
/** 单次传输数据上限保护(512KB) */
const MAX_RECEIVE = 512 * 1024;
/**
 * GATT 单次操作超时(ms): 连接断开/手表锁屏时写入 Promise 可能长期挂起,
 * 无超时保护会让主线程 await 冻结导致 ANR(THREAD_BLOCK); 超时后立即失败,
 * 由调用方提示用户重试.
 */
const GATT_OP_TIMEOUT_MS = 5000;

/** 带超时的 Promise.race 封装: 超时以指定错误拒绝 */
function withTimeout<T>(op: Promise<T>, timeoutMs: number, timeoutMsg: string): Promise<T> {
  return Promise.race([
    op,
    new Promise<T>((_, reject) => {
      setTimeout(() => reject(new Error(timeoutMsg)), timeoutMs);
    })
  ]);
}

/** 传输头部帧结构 */
interface TransferHeader {
  total: number;
  count: number;
  /** 消息类型: 缺省为 tokens(向后兼容旧版发送端) */
  type?: string;
}

/** 设置同步载荷项: 偏好键 + 值 */
interface SettingValuePair {
  key: string;
  value: SettingValue;
}

interface ReceiveState {
  inProgress: boolean;
  total: number;
  count: number;
  type: string;
  received: number;
  chunks: Array<Uint8Array>;
}

/** 消息类型常量 */
const MSG_TYPE_TOKENS = 'tokens';
const MSG_TYPE_SETTINGS = 'settings';

/**
 * 手表端消费的设置白名单(与 ArcTokenItem/ArcTokenListPage/ArcTokenIcon 实际引用的
 * TokenPreference 字段一致): 同步设置时只传输这些键, 避免把手机专属设置
 * (图标包/云备份等)写入表盘. 新增手表端消费的设置字段时需同步补充本清单.
 */
export const WATCH_SYNC_PREF_KEYS: string[] = [
  PREF_KEYS.SAFETY_HIDE_TOKEN_ENABLE,
  PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE,
  PREF_KEYS.APPEARANCE_ITEM_HEIGHT,
  PREF_KEYS.APPEARANCE_LOGO_BACKGROUND,
  PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_SIZE,
  PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_RADIUS,
  PREF_KEYS.APPEARANCE_LOGO_BACKGROUND_COLOR,
  PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER,
  PREF_KEYS.APPEARANCE_LOGO_DARK_FILTER_COLOR,
  PREF_KEYS.APPEARANCE_LOGO_SIZE,
  PREF_KEYS.APPEARANCE_TOKEN_COLOR,
  PREF_KEYS.APPEARANCE_TOKEN_COLOR_DARK,
  PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR,
  PREF_KEYS.APPEARANCE_TOKEN_NEXT_COLOR_DARK,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_START,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_LIGHT_COLOR_END,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_START,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_DARK_COLOR_END,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_MARGIN,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_START,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_LIGHT_COLOR_END,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_START,
  PREF_KEYS.APPEARANCE_TOKEN_COUNTER_NEXT_DARK_COLOR_END,
  PREF_KEYS.APPEARANCE_TOKEN_FONT_WEIGHT,
  PREF_KEYS.APPEARANCE_TOKEN_FONT_SIZE,
];

/**
 * 手表端 BLE GATT Server: 广播令牌接收服务, 手机写入的令牌数据重组后入库.
 */
export class BleTokenServer {
  private static instance: BleTokenServer;
  private gattServer: ble.GattServer | undefined = undefined;
  private receive: ReceiveState = {
    inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: []
  };
  private onTokensSaved: ((count: number) => void) | undefined = undefined;
  private onSettingsApplied: (() => void) | undefined = undefined;

  public static getInstance(): BleTokenServer {
    if (!BleTokenServer.instance) {
      BleTokenServer.instance = new BleTokenServer();
    }
    return BleTokenServer.instance;
  }

  /** 注册令牌入库完成回调(UI 提示用) */
  public setOnTokensSaved(cb: (count: number) => void): void {
    this.onTokensSaved = cb;
  }

  /** 注册设置应用完成回调(UI 提示用) */
  public setOnSettingsApplied(cb: () => void): void {
    this.onSettingsApplied = cb;
  }

  /**
   * 启动 GATT Server 并开始广播. 幂等: 已启动则直接返回.
   */
  public async start(): Promise<void> {
    if (this.gattServer) {
      return;
    }
    // 启动竞态: 蓝牙权限(user_grant)可能尚未授予, 重试至多 5 次
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        const server: ble.GattServer = ble.createGattServer();
        server.addService({
          serviceUuid: BLE_SERVICE_UUID,
          isPrimary: true,
          characteristics: [{
            serviceUuid: BLE_SERVICE_UUID,
            characteristicUuid: BLE_CHAR_UUID,
            characteristicValue: new ArrayBuffer(0),
            descriptors: [],
            properties: { write: true },
            permissions: { write: true },
          }],
        });
        server.on('characteristicWrite', (req: ble.CharacteristicWriteRequest) => {
          this.handleWrite(req);
        });
        server.on('connectionStateChange', (state: ble.BLEConnectionChangeState) => {
          hilog.info(DOMAIN, TAG, `connection state: ${state.state}`);
          try {
            hilog.info(DOMAIN, TAG, `pair state: ${connection.getPairState(state.deviceId)}`);
          } catch (err) {
            let e: BusinessError = err as BusinessError;
            hilog.warn(e.code, TAG, `getPairState failed: ${e.message}`);
          }
        });
        // 配对状态订阅: 仅日志记录(配对发起顺序两端可能不同步, 服务器端不做强制拦截)
        connection.on('bondStateChange', (data: connection.BondStateParam) => {
          hilog.info(DOMAIN, TAG, `bond state change: ${data.deviceId} -> ${data.state}`);
        });
        this.gattServer = server;
        // 设备名走广播响应包(scan response): legacy 广播包 31 字节限制下,
        // 主包放 128 位服务 UUID, 名字放响应包(扫描端聚合后经 serviceDataMap 读取)
        const nameBytes = new util.TextEncoder().encodeInto(BLE_ADV_DEVICE_NAME);
        ble.startAdvertising(
          { interval: 100, txPower: 0, connectable: true },
          { serviceUuids: [BLE_SERVICE_UUID], manufactureData: [], serviceData: [] },
          {
            serviceUuids: [], manufactureData: [],
            serviceData: [{ serviceUuid: BLE_NAME_UUID, serviceValue: nameBytes.buffer as ArrayBuffer }]
          }
        );
        hilog.info(DOMAIN, TAG, 'BLE server started, advertising token receive service');
        return;
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        hilog.error(e.code, TAG, `BleTokenServer.start attempt ${attempt} failed: ${e.message}`);
        this.gattServer = undefined;
        if (attempt < 4) {
          await new Promise<void>((resolve) => setTimeout(resolve, 1000));
        }
      }
    }
  }

  /**
   * 停止广播并释放监听.
   */
  public async stop(): Promise<void> {
    try {
      ble.stopAdvertising();
      connection.off('bondStateChange');
      if (this.gattServer) {
        this.gattServer.off('characteristicWrite');
        this.gattServer.off('connectionStateChange');
        this.gattServer = undefined;
      }
      this.receive = { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `BleTokenServer.stop failed: ${e.message}`);
    }
  }

  /**
   * 分片协议接收: 首帧为头 JSON, 之后为数据分片, 收满后重组入库.
   */
  private handleWrite(req: ble.CharacteristicWriteRequest): void {
    try {
      const bytes: Uint8Array = new Uint8Array(req.value);
      if (!this.receive.inProgress) {
        // 首帧: 头 JSON {"total":N,"count":M}
        const decoder = new util.TextDecoder('utf-8');
        const header = JSON.parse(decoder.decodeToString(bytes)) as TransferHeader;
        if (header.total <= 0 || header.total > MAX_RECEIVE) {
          hilog.error(DOMAIN, TAG, `invalid transfer header: ${JSON.stringify(header)}`);
        } else {
          this.receive = {
            inProgress: true, total: header.total, count: header.count,
            type: header.type ?? MSG_TYPE_TOKENS, received: 0, chunks: []
          };
          hilog.info(DOMAIN, TAG, `receive start: total=${header.total}, count=${header.count}, type=${this.receive.type}`);
        }
      } else {
        this.receive.chunks.push(bytes);
        this.receive.received += bytes.byteLength;
        if (this.receive.received >= this.receive.total) {
          this.assembleAndSave();
        }
      }
      // GATT 写事务必须有响应, 否则客户端写入会阻塞直至超时失败
      if (req.needRsp && this.gattServer) {
        this.gattServer.sendResponse({
          deviceId: req.deviceId,
          transId: req.transId,
          status: 0,
          offset: req.offset,
          value: new ArrayBuffer(0),
        });
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `handleWrite failed: ${e.message}`);
      this.receive = { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
    }
  }

  /**
   * 重组全部数据分片, 解析 TokenConfig 数组并逐条保存.
   */
  private async assembleAndSave(): Promise<void> {
    const full: Uint8Array = new Uint8Array(this.receive.total);
    let offset: number = 0;
    for (let i = 0; i < this.receive.chunks.length; i++) {
      full.set(this.receive.chunks[i], offset);
      offset += this.receive.chunks[i].byteLength;
    }
    const msgType: string = this.receive.type;
    this.receive = { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
    try {
      // 应用层解密(AES-256-GCM): 失败视为载荷被篡改或密钥版本不匹配, 丢弃且不入库
      const plain: Uint8Array | null = await decryptBlePayload(full);
      if (plain === null) {
        hilog.error(DOMAIN, TAG, 'decryptBlePayload failed: data may be tampered or key version mismatch, discarding');
        return;
      }
      if (msgType === MSG_TYPE_SETTINGS) {
        await this.applySettings(plain);
        return;
      }
      const decoder = new util.TextDecoder('utf-8');
      const tokens = JSON.parse(decoder.decodeToString(plain)) as TokenConfig[];
      hilog.info(DOMAIN, TAG, `received ${tokens.length} tokens, saving...`);
      const tkStore: TokenStore = TokenStore.getInstance();
      // 已存在令牌覆盖: 按 issuer+name 匹配本地令牌, 复用本地 TokenUUID 更新.
      // 手机端与手表端令牌 UUID 不同(各端独立生成), 直接 updateToken 会按 UUID 判为新增
      // 导致重复令牌; 复用本地 UUID 同时维持排序/删除等引用的稳定性.
      const existing = await tkStore.getTokens();
      for (let i = 0; i < tokens.length; i++) {
        for (let j = 0; j < existing.length; j++) {
          if (existing[j].TokenIssuer === tokens[i].TokenIssuer &&
            existing[j].TokenName === tokens[i].TokenName) {
            tokens[i].TokenUUID = existing[j].TokenUUID;
            break;
          }
        }
      }
      for (let i = 0; i < tokens.length; i++) {
        await tkStore.updateToken(tokens[i]);
      }
      tkStore.sortTokens();
      this.onTokensSaved?.(tokens.length);
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `assembleAndSave failed: ${e.message}`);
    }
  }

  /**
   * 应用手机端下发的设置载荷.
   *
   * 仅应用 WATCH_SYNC_PREF_KEYS 白名单内的键(防手机端扩展键误写入手表),
   * 逐键写入 Preferences 后刷新 TokenPreference(AppStorageV2) 使手表 UI 即时生效.
   */
  private async applySettings(plain: Uint8Array): Promise<void> {
    try {
      const decoder = new util.TextDecoder('utf-8');
      const pairs = JSON.parse(decoder.decodeToString(plain)) as Array<SettingValuePair>;
      let applied: number = 0;
      for (let i = 0; i < pairs.length; i++) {
        if (WATCH_SYNC_PREF_KEYS.includes(pairs[i].key)) {
          AppPreference.setPreference(pairs[i].key, pairs[i].value);
          applied++;
        }
      }
      // 刷新 TokenPreference(@Trace 字段), 手表端 ArcTokenItem 等 UI 立即按新设置重绘
      AppPreference.loadTokenAppearance();
      // 诊断: 输出应用后的 logo_background 实际值(布尔)
      hilog.info(DOMAIN, TAG,
        `settings applied: ${applied}/${pairs.length} keys, logo_background=${AppPreference.getPreference(PREF_KEYS.APPEARANCE_LOGO_BACKGROUND)}`);
      this.onSettingsApplied?.();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `applySettings failed: ${e.message}`);
    }
  }
}

/**
 * 手机端 BLE GATT Client: 扫描手表服务 → 连接 → 分片写入令牌数据.
 */
export class BleTokenClient {
  private static instance: BleTokenClient;
  private gattClient: ble.GattClientDevice | undefined = undefined;
  private found: Map<string, ble.ScanResult> = new Map();
  private onDevicesChanged: ((devices: Array<ble.ScanResult>) => void) | undefined = undefined;
  private onConnectionChanged: ((deviceId: string, connected: boolean) => void) | undefined = undefined;
  /** 当前连接的设备ID(配对门禁用) */
  private currentDeviceId: string = '';
  /** 设备配对状态缓存(deviceId → bonded) */
  private bonded: Map<string, boolean> = new Map();
  private onPairChanged: ((deviceId: string, bonded: boolean) => void) | undefined = undefined;

  public static getInstance(): BleTokenClient {
    if (!BleTokenClient.instance) {
      BleTokenClient.instance = new BleTokenClient();
    }
    return BleTokenClient.instance;
  }

  /** 扫描结果变化回调(UI 刷新设备列表用) */
  public setOnDevicesChanged(cb: (devices: Array<ble.ScanResult>) => void): void {
    this.onDevicesChanged = cb;
  }

  /** 连接状态变化回调 */
  public setOnConnectionChanged(cb: (deviceId: string, connected: boolean) => void): void {
    this.onConnectionChanged = cb;
  }

  /** 配对状态变化回调(UI 配对提示用) */
  public setOnPairChanged(cb: (deviceId: string, bonded: boolean) => void): void {
    this.onPairChanged = cb;
  }

  /** 当前扫描到的设备(按 deviceId 去重) */
  public getFoundDevices(): Array<ble.ScanResult> {
    return Array.from(this.found.values());
  }

  /**
   * 开始扫描(按服务 UUID 过滤, 只发现手表).
   */
  public startScan(): void {
    try {
      ble.on('BLEDeviceFind', (results: Array<ble.ScanResult>) => {
        for (let i = 0; i < results.length; i++) {
          this.found.set(results[i].deviceId, results[i]);
        }
        this.onDevicesChanged?.(this.getFoundDevices());
      });
      // 配对状态订阅: 生命周期与扫描一致(页面存活期间持续监听)
      connection.on('bondStateChange', (data: connection.BondStateParam) => {
        const isBonded: boolean = data.state === connection.BondState.BOND_STATE_BONDED;
        this.bonded.set(data.deviceId, isBonded);
        hilog.info(DOMAIN, TAG, `client bond state: ${data.deviceId} -> ${isBonded}`);
        this.onPairChanged?.(data.deviceId, isBonded);
      });
      ble.startBLEScan([{ serviceUuid: BLE_SERVICE_UUID }], { interval: 100 });
      hilog.info(DOMAIN, TAG, 'BLE scan started');
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `startScan failed: ${e.message}`);
    }
  }

  /**
   * 停止扫描并注销监听.
   */
  public stopScan(): void {
    try {
      ble.stopBLEScan();
      ble.off('BLEDeviceFind');
      connection.off('bondStateChange');
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `stopScan failed: ${e.message}`);
    }
  }

  /**
   * 确保设备已完成系统 BLE 配对(bonded).
   *
   * 已配对则直接置位返回; 未配对调用 connection.pairDevice 拉起系统配对流程
   * (配对对话框由系统弹出, 手表端自动弹确认). 配对失败(用户取消等)置 false 并上抛.
   */
  private async ensureBonded(deviceId: string): Promise<void> {
    try {
      if (connection.getPairState(deviceId) === connection.BondState.BOND_STATE_BONDED) {
        this.bonded.set(deviceId, true);
        this.onPairChanged?.(deviceId, true);
        return;
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.warn(e.code, TAG, `getPairState failed: ${e.message}`);
    }
    await connection.pairDevice(deviceId);
    this.bonded.set(deviceId, true);
    this.onPairChanged?.(deviceId, true);
    hilog.info(DOMAIN, TAG, `paired with ${deviceId}`);
  }

  /**
   * 连接指定设备(先断开旧连接).
   */
  public connect(deviceId: string): void {
    try {
      if (this.gattClient) {
        this.gattClient.disconnect();
      }
      this.currentDeviceId = deviceId;
      const client: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
      client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
        const connected: boolean = state.state === constant.ProfileConnectionState.STATE_CONNECTED;
        hilog.info(DOMAIN, TAG, `client connection state: ${state.state}`);
        if (connected) {
          // 连接后协商更大 MTU, 使 480 字节分片写入可行
          try {
            client.setBLEMtuSize(512);
          } catch (mtuErr) {
            let me: BusinessError = mtuErr as BusinessError;
            hilog.warn(me.code, TAG, `setBLEMtuSize failed: ${me.message}`);
          }
          // 连接成功后确保系统配对(bonded), 未配对则拉起系统配对流程
          this.ensureBonded(deviceId).catch((err: BusinessError) => {
            hilog.error(err.code, TAG, `ensureBonded failed: ${err.message}`);
            this.onPairChanged?.(deviceId, false);
          });
        }
        this.onConnectionChanged?.(deviceId, connected);
      });
      this.gattClient = client;
      client.connect();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `connect failed: ${e.message}`);
    }
  }

  /**
   * 断开当前连接.
   */
  public disconnect(): void {
    try {
      this.gattClient?.disconnect();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `disconnect failed: ${e.message}`);
    }
  }

  /**
   * 分片写入令牌数据: 首帧头 + 数据分片, 逐帧等待写入完成保证顺序.
   *
   * @param tokens 要传输的令牌列表
   * @throws 未连接或写入失败时抛出
   */
  /**
   * 分片写入令牌数据: 首帧头 + 数据分片, 逐帧等待写入完成保证顺序.
   *
   * @param tokens 要传输的令牌列表
   * @throws 未连接或写入失败时抛出
   */
  public async sendTokens(tokens: TokenConfig[]): Promise<void> {
    const encoder = new util.TextEncoder();
    await this.sendPayload(encoder.encodeInto(JSON.stringify(tokens)), tokens.length, MSG_TYPE_TOKENS);
  }

  /**
   * 同步设置到手表扬表端: 读取 WATCH_SYNC_PREF_KEYS 白名单键的当前值, 加密后分片传输.
   *
   * @throws 未连接/未配对或写入失败时抛出
   */
  public async sendSettings(): Promise<void> {
    const pairs: Array<SettingValuePair> = [];
    for (let i = 0; i < WATCH_SYNC_PREF_KEYS.length; i++) {
      pairs.push({ key: WATCH_SYNC_PREF_KEYS[i], value: AppPreference.getPreference(WATCH_SYNC_PREF_KEYS[i]) });
    }
    const encoder = new util.TextEncoder();
    await this.sendPayload(encoder.encodeInto(JSON.stringify(pairs)), pairs.length, MSG_TYPE_SETTINGS);
    hilog.info(DOMAIN, TAG, `sendSettings done: ${pairs.length} keys`);
  }

  /**
   * 分片协议公共实现: 配对门禁 → 服务发现 → 应用层加密 → 首帧头(type) → 数据分片.
   */
  private async sendPayload(plain: Uint8Array, count: number, type: string): Promise<void> {
    if (!this.gattClient) {
      throw new Error('BLE client not connected');
    }
    // 配对门禁: 系统 BLE 配对(bonded)后才允许传输 secret/设置载荷
    if (!this.bonded.get(this.currentDeviceId)) {
      throw new Error('BLE device not bonded, pair first');
    }
    // 服务发现, 确认对端特征存在(超时保护: 连接断开时可能挂起)
    const services: Array<ble.GattService> =
      await withTimeout(this.gattClient.getServices(), GATT_OP_TIMEOUT_MS, 'BLE getServices timeout');
    hilog.info(DOMAIN, TAG, `services discovered: ${services.length}`);

    const encoder = new util.TextEncoder();
    // 应用层加密(AES-256-GCM): 载荷格式 [MAGIC][iv][tag][ciphertext], 分片协议不变
    const encrypted: Uint8Array = await encryptBlePayload(plain);
    const total: number = encrypted.byteLength;

    // 首帧: 头 {"total":N,"count":M,"type":T}
    const headerBytes: Uint8Array = encoder.encodeInto(JSON.stringify({ total: total, count: count, type: type }));
    await this.writeFrame(headerBytes);

    // 数据分片
    let offset: number = 0;
    while (offset < total) {
      const end: number = Math.min(offset + MAX_CHUNK, total);
      const chunk: Uint8Array = new Uint8Array(end - offset);
      chunk.set(encrypted.subarray(offset, end));
      await this.writeFrame(chunk);
      offset = end;
    }
    hilog.info(DOMAIN, TAG, `sendPayload done: type=${type}, count=${count}, ${total} encrypted bytes`);
  }

  private async writeFrame(data: Uint8Array): Promise<void> {
    const buf: ArrayBuffer = new ArrayBuffer(data.byteLength);
    new Uint8Array(buf).set(data);
    const characteristic: ble.BLECharacteristic = {
      serviceUuid: BLE_SERVICE_UUID,
      characteristicUuid: BLE_CHAR_UUID,
      characteristicValue: buf,
      descriptors: [],
    };
    // 超时保护: 连接断开/手表锁屏时 GATT 写入 Promise 可能长期挂起,
    // 无超时会让主线程 await 冻结(THREAD_BLOCK_6S ANR); 超时即失败中断整次传输
    await withTimeout(
      this.gattClient!.writeCharacteristicValue(characteristic, ble.GattWriteType.WRITE),
      GATT_OP_TIMEOUT_MS,
      'BLE write timeout');
  }
}
