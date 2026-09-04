import { ble, connection, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TokenConfig } from './TokenConfig';
import { AppPreference } from './AppPreference';
import { decryptBlePayload, encryptBlePayload } from './CryptoUtils';
import { WEAR_SYNC_PREF_KEYS, SettingValuePair, saveTokensBatch, applyWearSettings } from './WearEngineTransfer';

const TAG = 'BleTokenTransfer';
const DOMAIN = 0xFF01;

/**
 * 手机→手表 蓝牙(BLE)令牌传输方案(P2P 之外的独立验证通道).
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
 * - 首帧: JSON 头 {"total": 数据总字节数, "count": 令牌数, "type": "tokens"|"settings"}
 * - 后续帧: ≤ MAX_CHUNK 字节的加密数据分片(AES-256-GCM, 载荷格式 [MAGIC][iv][tag][ciphertext])
 * - 接收方按 total 重组, 解密后按 type 分发; 令牌入库/设置应用复用 WearEngineTransfer 共享实现
 * - 最后一个数据帧的写应答延后到重组处理完成: 成功回 status 0, 失败回非 0,
 *   使手机端写入结果与手表端实际入库结果一致(防"页面成功、手表无数据"的假成功)
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
 * 由调用方提示用户重试. 收尾帧应答延后到处理完成, 5 秒同样覆盖解密/入库耗时.
 */
const GATT_OP_TIMEOUT_MS = 5000;

/**
 * 带超时的 Promise 封装: 超时或操作完成/失败均清理定时器,
 * 避免成功路径下定时器悬挂至超时时刻才触发.
 */
function withTimeout<T>(op: Promise<T>, timeoutMs: number, timeoutMsg: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timerId = setTimeout(() => reject(new Error(timeoutMsg)), timeoutMs);
    op.then((value: T) => {
      clearTimeout(timerId);
      resolve(value);
    }, (err: Error) => {
      clearTimeout(timerId);
      reject(err);
    });
  });
}

/** 传输头部帧结构 */
interface TransferHeader {
  total: number;
  count: number;
  /** 消息类型: 缺省为 tokens(向后兼容旧版发送端) */
  type?: string;
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

/** 手表端 BLE 接收状态(驱动列表页同步状态文本, 接收中/成功/失败) */
export enum BleSyncStatus {
  /** 已收到传输头, 正在接收数据分片 */
  RECEIVING = 0,
  /** 批次完整接收并处理成功 */
  SUCCESS = 1,
  /** 接收失败(解密失败/数据异常/处理异常), 本批次已丢弃 */
  FAILED = 2
}

/**
 * 手表端 BLE GATT Server: 广播令牌接收服务, 手机写入的令牌数据重组后入库.
 *
 * 接收状态机以"批次"为隔离单元: 连接建立与每个批次开始时重置 inProgress/chunks,
 * 任何失败路径(头非法/分片越界/解密失败/重组异常)下未完整接收的批次均不入库,
 * 防止中断重试后残留分片拼入新批次造成"手机端成功、手表无数据"的假成功.
 */
export class BleTokenServer {
  private static instance: BleTokenServer;
  private gattServer: ble.GattServer | undefined = undefined;
  private receive: ReceiveState = BleTokenServer.newReceiveState();
  private onTokensSaved: ((count: number) => void) | undefined = undefined;
  private onSettingsApplied: (() => void) | undefined = undefined;
  private onSyncStatus: ((status: BleSyncStatus, count: number) => void) | undefined = undefined;

  /** 空白接收状态(批次开始/结束/失败时统一以此重置) */
  private static newReceiveState(): ReceiveState {
    return { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
  }

  public static getInstance(): BleTokenServer {
    if (!BleTokenServer.instance) {
      BleTokenServer.instance = new BleTokenServer();
    }
    return BleTokenServer.instance;
  }

  /** 注册令牌入库完成回调(UI 提示用); 传 undefined 注销 */
  public setOnTokensSaved(cb: ((count: number) => void) | undefined): void {
    this.onTokensSaved = cb;
  }

  /** 注册设置应用完成回调(UI 提示用); 传 undefined 注销 */
  public setOnSettingsApplied(cb: (() => void) | undefined): void {
    this.onSettingsApplied = cb;
  }

  /** 注册接收状态回调(接收中/成功/失败, UI 状态文本用); 传 undefined 注销 */
  public setOnSyncStatus(cb: ((status: BleSyncStatus, count: number) => void) | undefined): void {
    this.onSyncStatus = cb;
  }

  /**
   * 启动 GATT Server 并开始广播. 幂等: 已启动则直接返回.
   * 启动竞态保护: 蓝牙权限/开关未就绪时以 5 次 × 1 秒延时重试, 全部失败仅记日志
   * (调用方 P2P/BLE 并行启动, BLE 失败不得影响 P2P 接收).
   * 每次失败尝试均注销/close 已创建的 GattServer, 避免重试路径泄漏监听与实例.
   */
  public async start(): Promise<void> {
    if (this.gattServer) {
      return;
    }
    for (let attempt = 0; attempt < 5; attempt++) {
      let server: ble.GattServer | undefined = undefined;
      try {
        server = ble.createGattServer();
        // await 服务注册完成: 注册失败(蓝牙未就绪)进入 catch 走重试与清理
        await server.addService({
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
          // 建连/断连均重置接收状态机: 断连可能发生在批次中途, 残留分片不得跨连接拼入
          this.resetReceive();
          try {
            hilog.info(DOMAIN, TAG, `pair state: ${connection.getPairState(state.deviceId)}`);
          } catch (err) {
            let e: BusinessError = err as BusinessError;
            hilog.warn(e.code, TAG, `getPairState failed: ${e.message}`);
          }
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
        // 配对状态订阅: 仅日志记录(配对发起顺序两端可能不同步, 服务器端不做强制拦截);
        // 全局监听仅在启动成功后注册一次, 与 stop 的注销成对
        connection.on('bondStateChange', (data: connection.BondStateParam) => {
          hilog.info(DOMAIN, TAG, `bond state change: ${data.deviceId} -> ${data.state}`);
        });
        hilog.info(DOMAIN, TAG, 'BLE server started, advertising token receive service');
        return;
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        hilog.error(e.code, TAG, `BleTokenServer.start attempt ${attempt} failed: ${e.message}`);
        // 清理本次尝试已创建的实例/监听/广播, 避免重试路径泄漏
        if (server) {
          try {
            server.off('characteristicWrite');
            server.off('connectionStateChange');
            server.close();
          } catch (cleanupErr) {
            let ce: BusinessError = cleanupErr as BusinessError;
            hilog.warn(ce.code, TAG, `gatt server cleanup failed: ${ce.message}`);
          }
        }
        try {
          ble.stopAdvertising();
        } catch (cleanupErr) {
          // 未开始广播时 stop 会抛错, 忽略
        }
        this.gattServer = undefined;
        if (attempt < 4) {
          await new Promise<void>((resolve) => setTimeout(resolve, 1000));
        }
      }
    }
  }

  /**
   * 停止广播并释放监听(与 start 注册一一成对注销).
   */
  public async stop(): Promise<void> {
    try {
      ble.stopAdvertising();
      connection.off('bondStateChange');
      if (this.gattServer) {
        this.gattServer.off('characteristicWrite');
        this.gattServer.off('connectionStateChange');
        this.gattServer.close();
        this.gattServer = undefined;
      }
      this.resetReceive();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `BleTokenServer.stop failed: ${e.message}`);
    }
  }

  /** 重置接收状态机: 丢弃未完整接收的批次残留 */
  private resetReceive(): void {
    this.receive = BleTokenServer.newReceiveState();
  }

  /**
   * 分片协议接收: 首帧为头 JSON, 之后为数据分片, 收满后重组分发.
   * 头帧到达即视为新批次开始(重置接收状态), 并上报"接收中"状态.
   * 收尾帧(收满 total)的写应答延后到处理完成后回发, 使手机端拿到真实入库结果.
   */
  private handleWrite(req: ble.CharacteristicWriteRequest): void {
    let batchComplete = false;
    try {
      const bytes: Uint8Array = new Uint8Array(req.value);
      if (!this.receive.inProgress) {
        // 首帧: 头 JSON {"total":N,"count":M,"type":T}
        const decoder = new util.TextDecoder('utf-8');
        const header = JSON.parse(decoder.decodeToString(bytes)) as TransferHeader;
        if (header.total <= 0 || header.total > MAX_RECEIVE) {
          hilog.error(DOMAIN, TAG, `invalid transfer header: ${JSON.stringify(header)}`);
          this.resetReceive();
          this.onSyncStatus?.(BleSyncStatus.FAILED, 0);
          this.sendWriteResponse(req, false);
          return;
        }
        this.receive = {
          inProgress: true, total: header.total, count: header.count,
          type: header.type ?? MSG_TYPE_TOKENS, received: 0, chunks: []
        };
        this.onSyncStatus?.(BleSyncStatus.RECEIVING, 0);
        hilog.info(DOMAIN, TAG, `receive start: total=${header.total}, count=${header.count}, type=${this.receive.type}`);
      } else {
        this.receive.chunks.push(bytes);
        this.receive.received += bytes.byteLength;
        if (this.receive.received >= this.receive.total) {
          batchComplete = true;
        }
      }
      if (batchComplete) {
        // 收尾帧: 应答延后到处理完成(成功 status 0 / 失败非 0), 手机端据此给出真实反馈
        this.assembleAndSave(req);
      } else {
        // 非收尾帧: GATT 写事务必须有响应, 否则客户端写入会阻塞直至超时失败
        this.sendWriteResponse(req, true);
      }
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `handleWrite failed: ${e.message}`);
      this.resetReceive();
      this.onSyncStatus?.(BleSyncStatus.FAILED, 0);
      this.sendWriteResponse(req, false);
    }
  }

  /** 回发写应答: status 0 表示成功, 非 0 使手机端写入失败(真实结果反馈) */
  private sendWriteResponse(req: ble.CharacteristicWriteRequest, success: boolean): void {
    if (!req.needRsp || !this.gattServer) {
      return;
    }
    try {
      this.gattServer.sendResponse({
        deviceId: req.deviceId,
        transId: req.transId,
        status: success ? 0 : 1,
        offset: req.offset,
        value: new ArrayBuffer(0),
      });
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.warn(e.code, TAG, `sendResponse failed: ${e.message}`);
    }
  }

  /**
   * 重组全部数据分片, 解密后按 type 分发: 令牌走共享入库, 设置走共享应用.
   * 分片先快照到局部变量并立即重置接收状态机(后续新批次可立即开始, 互不残留),
   * 重组/解密/处理的任何失败路径均上报失败并丢弃本批次, 收尾帧回失败应答.
   *
   * @param finalReq 收尾帧写请求(处理完成后回发应答; 无则静默处理)
   */
  private async assembleAndSave(finalReq?: ble.CharacteristicWriteRequest): Promise<void> {
    const chunks: Array<Uint8Array> = this.receive.chunks;
    const total: number = this.receive.total;
    const msgType: string = this.receive.type;
    this.resetReceive();
    let ok = false;
    try {
      const full: Uint8Array = new Uint8Array(total);
      let offset: number = 0;
      for (let i = 0; i < chunks.length; i++) {
        full.set(chunks[i], offset);
        offset += chunks[i].byteLength;
      }
      if (offset !== total) {
        // 分片总量与头不符(交叠写入/异常发送方): 判失败, 丢弃本批次
        hilog.error(DOMAIN, TAG, `chunk size mismatch: got ${offset}, expect ${total}`);
        this.onSyncStatus?.(BleSyncStatus.FAILED, 0);
        return;
      }
      // 应用层解密(AES-256-GCM): 失败视为载荷被篡改或密钥版本不匹配, 丢弃且不入库
      const plain: Uint8Array | null = await decryptBlePayload(full);
      if (plain === null) {
        hilog.error(DOMAIN, TAG, 'decryptBlePayload failed: data may be tampered or key version mismatch, discarding');
        this.onSyncStatus?.(BleSyncStatus.FAILED, 0);
        return;
      }
      const decoder = new util.TextDecoder('utf-8');
      if (msgType === MSG_TYPE_SETTINGS) {
        const pairs = JSON.parse(decoder.decodeToString(plain)) as Array<SettingValuePair>;
        await applyWearSettings(pairs);
        this.onSettingsApplied?.();
      } else {
        const tokens = JSON.parse(decoder.decodeToString(plain)) as TokenConfig[];
        hilog.info(DOMAIN, TAG, `received ${tokens.length} tokens, saving...`);
        const saved = await saveTokensBatch(tokens);
        this.onTokensSaved?.(saved);
        this.onSyncStatus?.(BleSyncStatus.SUCCESS, saved);
      }
      ok = true;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `assembleAndSave failed: ${e.message}`);
      this.onSyncStatus?.(BleSyncStatus.FAILED, 0);
    } finally {
      if (finalReq) {
        this.sendWriteResponse(finalReq, ok);
      }
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
  private onPairFailed: ((deviceId: string) => void) | undefined = undefined;

  public static getInstance(): BleTokenClient {
    if (!BleTokenClient.instance) {
      BleTokenClient.instance = new BleTokenClient();
    }
    return BleTokenClient.instance;
  }

  /** 扫描结果变化回调(UI 刷新设备列表用); 传 undefined 注销 */
  public setOnDevicesChanged(cb: ((devices: Array<ble.ScanResult>) => void) | undefined): void {
    this.onDevicesChanged = cb;
  }

  /** 连接状态变化回调; 传 undefined 注销 */
  public setOnConnectionChanged(cb: ((deviceId: string, connected: boolean) => void) | undefined): void {
    this.onConnectionChanged = cb;
  }

  /** 配对状态变化回调(UI 配对提示用); 传 undefined 注销 */
  public setOnPairChanged(cb: ((deviceId: string, bonded: boolean) => void) | undefined): void {
    this.onPairChanged = cb;
  }

  /** 配对流程失败回调(用户取消/系统拒绝, UI 提示重试用); 传 undefined 注销 */
  public setOnPairFailed(cb: ((deviceId: string) => void) | undefined): void {
    this.onPairFailed = cb;
  }

  /** 当前扫描到的设备(按 deviceId 去重) */
  public getFoundDevices(): Array<ble.ScanResult> {
    return Array.from(this.found.values());
  }

  /** 清空扫描结果(重新扫描前调用, 避免展示陈旧广播) */
  public clearFoundDevices(): void {
    this.found.clear();
    this.onDevicesChanged?.(this.getFoundDevices());
  }

  /**
   * 开始扫描(按服务 UUID 过滤, 只发现手表).
   * 监听注册与 stopScan 的注销一一成对.
   *
   * @returns 扫描是否成功启动(蓝牙未就绪等失败返回 false, 调用方复位扫描态)
   */
  public startScan(): boolean {
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
      return true;
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `startScan failed: ${e.message}`);
      return false;
    }
  }

  /**
   * 停止扫描并注销监听(与 startScan 注册一一成对注销).
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
   * 确保设备已完成系统 BLE 配对(bonded); 未配对调用 connection.pairDevice 拉起
   * 系统配对流程(配对对话框由系统弹出, 手表端自动弹确认).
   *
   * @throws 配对失败(用户取消/系统拒绝)时抛出, 由调用方决定反馈方式
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
   * 重新发起系统配对(配对失败后的重试入口, 需已连接该设备).
   *
   * @throws 配对流程再次失败时抛出
   */
  public async retryPairing(deviceId: string): Promise<void> {
    if (this.gattClient === undefined || this.currentDeviceId !== deviceId) {
      throw new Error('BLE device not connected');
    }
    this.bonded.set(deviceId, false);
    await this.ensureBonded(deviceId);
  }

  /**
   * 释放旧 GATT Client: 注销监听 → 断开 → close(注销设备并清理回调).
   * 切换设备/页面退出时必须先释放, 避免 GATT 连接与监听泄漏.
   */
  private releaseClient(): void {
    if (!this.gattClient) {
      return;
    }
    try {
      this.gattClient.off('BLEConnectionStateChange');
      this.gattClient.disconnect();
      this.gattClient.close();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.warn(e.code, TAG, `release gatt client failed: ${e.message}`);
    }
    this.gattClient = undefined;
  }

  /** 当前是否已连接指定设备 */
  public isConnected(deviceId: string): boolean {
    return this.gattClient !== undefined && this.currentDeviceId === deviceId;
  }

  /**
   * 连接指定设备(先释放旧连接).
   */
  public connect(deviceId: string): void {
    try {
      this.releaseClient();
      this.currentDeviceId = deviceId;
      const client: ble.GattClientDevice = ble.createGattClientDevice(deviceId);
      client.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
        const connected: boolean = state.state === constant.ProfileConnectionState.STATE_CONNECTED;
        hilog.info(DOMAIN, TAG, `client connection state: ${state.state}`);
        if (connected) {
          // 连接后协商更大 MTU, 使 480 字节分片写入可行(setBLEMtuSize 为同步接口)
          try {
            client.setBLEMtuSize(512);
          } catch (mtuErr) {
            let me: BusinessError = mtuErr as BusinessError;
            hilog.warn(me.code, TAG, `setBLEMtuSize failed: ${me.message}`);
          }
          // 连接成功后确保系统配对(bonded), 未配对则拉起系统配对流程;
          // 配对失败(用户取消/系统拒绝)回调 onPairFailed 供 UI 提示重试
          this.ensureBonded(deviceId).catch((err: BusinessError) => {
            hilog.error(err.code, TAG, `ensureBonded failed: ${err.message}`);
            this.bonded.set(deviceId, false);
            this.onPairChanged?.(deviceId, false);
            this.onPairFailed?.(deviceId);
          });
        }
        this.onConnectionChanged?.(deviceId, connected);
      });
      this.gattClient = client;
      client.connect();
    } catch (err) {
      let e: BusinessError = err as BusinessError;
      hilog.error(e.code, TAG, `connect failed: ${e.message}`);
      this.gattClient = undefined;
      this.onConnectionChanged?.(deviceId, false);
    }
  }

  /**
   * 断开当前连接并释放客户端(与 connect 的监听/连接成对清理).
   */
  public disconnect(): void {
    this.releaseClient();
    if (this.currentDeviceId !== '') {
      this.onConnectionChanged?.(this.currentDeviceId, false);
      this.currentDeviceId = '';
    }
  }

  /**
   * 分片写入令牌数据: 首帧头 + 数据分片, 逐帧等待写入完成保证顺序.
   *
   * @param tokens 要传输的令牌列表
   * @throws 未连接/未配对或写入失败(含手表端处理失败的非 0 应答)时抛出
   */
  public async sendTokens(tokens: TokenConfig[]): Promise<void> {
    const encoder = new util.TextEncoder();
    await this.sendPayload(encoder.encodeInto(JSON.stringify(tokens)), tokens.length, MSG_TYPE_TOKENS);
  }

  /**
   * 同步设置到手表: 读取 WEAR_SYNC_PREF_KEYS 白名单键的当前值, 加密后分片传输.
   *
   * @throws 未连接/未配对或写入失败(含手表端处理失败的非 0 应答)时抛出
   */
  public async sendSettings(): Promise<void> {
    const pairs: Array<SettingValuePair> = [];
    for (let i = 0; i < WEAR_SYNC_PREF_KEYS.length; i++) {
      pairs.push({ key: WEAR_SYNC_PREF_KEYS[i], value: AppPreference.getPreference(WEAR_SYNC_PREF_KEYS[i]) });
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
