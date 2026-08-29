import { wearEngine } from '@kit.WearEngine';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TokenConfig } from './TokenConfig';
import { TokenStore } from './TokenStore';
import { AppPreference, PREF_KEYS, SettingValue } from './AppPreference';
import { decryptBlePayload, encryptBlePayload } from './CryptoUtils';

const TAG = 'WearEngineTransfer';
const DOMAIN = 0xFF03;

/**
 * 手机↔手表 令牌传输方案(Wear Engine 应用间消息通信, 替代 BLE).
 *
 * 背景: 分布式 KV 同步受"数据库安全等级 ≤ 对端设备安全等级"约束(S4 无法同步 SL1 手表),
 * BLE 手动传输存在设备发现/配对/连接管理负担. Wear Engine P2P 基于华为运动健康既有配对与
 * 连接(华为账号信任链背书), 无需自研扫描配对.
 *
 * 安全模型(与 BLE 方案一致):
 * - 传输信任链由华为账号/Wear Engine 背书
 * - 应用层 AES-256-GCM(encryptBlePayload/decryptBlePayload)纵深防御
 *
 * 消息协议(分片, 复用 BLE 分片思想):
 * - P2P 单条消息上限 4096 字节, 本实现每帧 ≤ P2P_FRAME_MAX(4000B) 留余量
 * - 首帧: JSON 头 {"total": 数据总字节数, "count": 消息数, "type": "tokens"|"settings"}
 * - 后续帧: ≤ P2P_FRAME_MAX 的加密载荷分片
 * - 接收方按 total 重组, 解密后按 type 分发
 */

/** P2P 单帧最大载荷(4096 上限留余量) */
const P2P_FRAME_MAX = 4000;
/** 首帧头与数据帧的区分: 数据帧以魔数字节开头, 头帧为纯 JSON */
const FRAME_HEADER_PREFIX = 'OTPW';
const FRAME_HEADER_PREFIX_BYTES: Uint8Array = new util.TextEncoder().encodeInto(FRAME_HEADER_PREFIX);

/** 消息类型常量(与 BLE 方案一致) */
const MSG_TYPE_TOKENS = 'tokens';
const MSG_TYPE_SETTINGS = 'settings';

/**
 * 手表端消费的设置白名单(与 ArcTokenItem/ArcTokenListPage/ArcTokenIcon 实际引用的
 * TokenPreference 字段一致): 同步设置时只传输这些键, 避免把手机专属设置写入表盘.
 */
export const WEAR_SYNC_PREF_KEYS: string[] = [
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

/** 设置同步载荷项 */
interface SettingValuePair {
  key: string;
  value: SettingValue;
}

/** 首帧头结构 */
interface TransferHeader {
  total: number;
  count: number;
  type?: string;
}

/** 分片接收状态 */
interface ReceiveState {
  inProgress: boolean;
  total: number;
  count: number;
  type: string;
  received: number;
  chunks: Array<Uint8Array>;
}

/**
 * 手机端 Wear Engine P2P 客户端: 设备列表查询/拉起手表应用/分片发送令牌与设置.
 */
export class WearEngineClient {
  private static instance: WearEngineClient;
  private p2pClient: wearEngine.P2pClient | null = null;
  private deviceClient: wearEngine.DeviceClient | null = null;
  /** 对端(手表)应用参数: bundleName/fingerprint 运行时从本应用签名信息动态获取(两端同 bundle 同签名) */
  private remoteAppParam: wearEngine.P2pAppParam = {
    remoteApp: {
      bundleName: '',
      fingerprint: ''
    }
  };
  private appParamInitialized: boolean = false;

  private constructor() {
  }

  public static getInstance(): WearEngineClient {
    if (!WearEngineClient.instance) {
      WearEngineClient.instance = new WearEngineClient();
    }
    return WearEngineClient.instance;
  }

  private ensureClients(): void {
    if (this.p2pClient === null || this.deviceClient === null) {
      const ctx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
      this.p2pClient = wearEngine.getP2pClient(ctx);
      this.deviceClient = wearEngine.getDeviceClient(ctx);
    }
  }

  /**
   * 初始化对端应用参数: 从本应用签名信息动态获取 bundleName 与指纹.
   * 手机与手表为同一 bundle 的不同模块且同签名, 本应用信息即对端应用信息.
   */
  private async ensureAppParam(): Promise<void> {
    if (this.appParamInitialized) {
      return;
    }
    try {
      const bundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION |
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
      this.remoteAppParam.remoteApp.bundleName = bundleInfo.name;
      this.remoteAppParam.remoteApp.fingerprint = bundleInfo.signatureInfo?.fingerprint ?? '';
      this.appParamInitialized = true;
      hilog.info(DOMAIN, TAG, `appParam initialized: ${bundleInfo.name}`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `getBundleInfoForSelf failed: ${e.message}`);
    }
  }

  /**
   * 查询并请求用户授权(受限权限, 如穿戴用户状态).
   *
   * 注: P2P 通信(设备基础信息)本身无需用户授权; 本方法用于验证授权链路,
   * 以及为需要用户授权的 Wear Engine 能力(状态/传感器)铺路.
   * @returns 是否已获得 USER_STATUS 授权
   */
  public async ensureAuthorized(): Promise<boolean> {
    const ctx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    const authClient: wearEngine.AuthClient = wearEngine.getAuthClient(ctx);
    try {
      const granted = await authClient.getAuthorization();
      if (granted.permissions.includes(wearEngine.Permission.USER_STATUS)) {
        hilog.info(DOMAIN, TAG, 'USER_STATUS already authorized');
        return true;
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `getAuthorization failed: ${e.message}`);
    }
    try {
      const request: wearEngine.AuthorizationRequest = {
        permissions: [wearEngine.Permission.USER_STATUS]
      };
      const resp = await authClient.requestAuthorization(request);
      hilog.info(DOMAIN, TAG, `requestAuthorization result: ${resp.permissions}`);
      return resp.permissions.includes(wearEngine.Permission.USER_STATUS);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `requestAuthorization failed: ${e.message}`);
      return false;
    }
  }

  /** 获取已连接穿戴设备列表(华为运动健康已配对连接) */
  public async getConnectedDevices(): Promise<Array<wearEngine.Device>> {
    await this.ensureAppParam();
    this.ensureClients();
    return await this.deviceClient!.getConnectedDevices();
  }

  /** 查看手表端应用是否安装 */
  public async isRemoteAppInstalled(randomId: string): Promise<boolean> {
    await this.ensureAppParam();
    this.ensureClients();
    return await this.p2pClient!.isRemoteAppInstalled(randomId, this.remoteAppParam.remoteApp.bundleName);
  }

  /** 拉起手表端应用(发送前调用, 两端应用需同时启动) */
  public async startRemoteApp(randomId: string): Promise<void> {
    await this.ensureAppParam();
    this.ensureClients();
    await this.p2pClient!.startRemoteApp(randomId, this.remoteAppParam.remoteApp.bundleName);
    hilog.info(DOMAIN, TAG, `startRemoteApp ok: ${randomId}`);
  }

  /**
   * 分片发送令牌到手表.
   * @throws 未获取到 P2P 客户端或发送失败时抛出
   */
  public async sendTokens(randomId: string, tokens: TokenConfig[]): Promise<void> {
    const encoder = new util.TextEncoder();
    await this.sendPayload(randomId, encoder.encodeInto(JSON.stringify(tokens)), tokens.length, MSG_TYPE_TOKENS);
  }

  /** 同步设置到手表(WEAR_SYNC_PREF_KEYS 白名单) */
  public async sendSettings(randomId: string): Promise<void> {
    const pairs: Array<SettingValuePair> = [];
    for (let i = 0; i < WEAR_SYNC_PREF_KEYS.length; i++) {
      pairs.push({ key: WEAR_SYNC_PREF_KEYS[i], value: AppPreference.getPreference(WEAR_SYNC_PREF_KEYS[i]) });
    }
    const encoder = new util.TextEncoder();
    await this.sendPayload(randomId, encoder.encodeInto(JSON.stringify(pairs)), pairs.length, MSG_TYPE_SETTINGS);
    hilog.info(DOMAIN, TAG, `sendSettings done: ${pairs.length} keys`);
  }

  /**
   * 分片发送公共实现: AES-256-GCM 加密 → 首帧头(JSON) → ≤P2P_FRAME_MAX 数据帧.
   * 帧格式: 头帧以 FRAME_HEADER_PREFIX 开头, 数据帧为原始字节, 接收方按首帧 total 重组.
   */
  private async sendPayload(randomId: string, plain: Uint8Array, count: number, type: string): Promise<void> {
    await this.ensureAppParam();
    this.ensureClients();
    const encrypted: Uint8Array = await encryptBlePayload(plain);
    const total: number = encrypted.byteLength;

    // 首帧: 头 JSON
    const headerBytes: Uint8Array = new util.TextEncoder().encodeInto(
      `${FRAME_HEADER_PREFIX}${JSON.stringify({ total: total, count: count, type: type })}`);
    await this.sendFrame(randomId, headerBytes);

    // 数据分片(每帧 ≤ P2P_FRAME_MAX)
    let offset: number = 0;
    while (offset < total) {
      const end: number = Math.min(offset + P2P_FRAME_MAX, total);
      const chunk: Uint8Array = new Uint8Array(end - offset);
      chunk.set(encrypted.subarray(offset, end));
      await this.sendFrame(randomId, chunk);
      offset = end;
    }
    hilog.info(DOMAIN, TAG, `sendPayload done: type=${type}, count=${count}, ${total} bytes`);
  }

  private async sendFrame(randomId: string, data: Uint8Array): Promise<void> {
    const message: wearEngine.P2pMessage = { content: data };
    await this.p2pClient!.sendMessage(randomId, this.remoteAppParam, message);
  }
}

/**
 * 手表端 Wear Engine P2P 接收服务: 订阅对端消息, 重组分片 → 解密 → 按 type 分发.
 */
export class WearEngineServer {
  private static instance: WearEngineServer;
  private p2pClient: wearEngine.P2pClient | null = null;
  private receive: ReceiveState = {
    inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: []
  };
  private onTokensSaved: ((count: number) => void) | undefined = undefined;
  private onSettingsApplied: (() => void) | undefined = undefined;
  /** 对端(手机)应用参数: bundleName/fingerprint 运行时从本应用签名信息动态获取 */
  private remoteAppParam: wearEngine.P2pAppParam = {
    remoteApp: {
      bundleName: '',
      fingerprint: ''
    }
  };
  private appParamInitialized: boolean = false;
  private receiverCallback: ((message: wearEngine.P2pMessage) => void) | undefined = undefined;
  private registeredRandomIds: Array<string> = [];

  private constructor() {
  }

  public static getInstance(): WearEngineServer {
    if (!WearEngineServer.instance) {
      WearEngineServer.instance = new WearEngineServer();
    }
    return WearEngineServer.instance;
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
   * 对已连接对端设备注册消息接收(幂等).
   *
   * @param randomIds 对端设备 randomId 列表(手机侧; 可由 getConnectedDevices 获取)
   */
  public async registerReceiver(randomIds: Array<string>): Promise<void> {
    if (!this.appParamInitialized) {
      try {
        const bundleInfo = await bundleManager.getBundleInfoForSelf(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION |
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_SIGNATURE_INFO);
        this.remoteAppParam.remoteApp.bundleName = bundleInfo.name;
        this.remoteAppParam.remoteApp.fingerprint = bundleInfo.signatureInfo?.fingerprint ?? '';
        this.appParamInitialized = true;
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(e.code, TAG, `getBundleInfoForSelf failed: ${e.message}`);
      }
    }
    const ctx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (this.p2pClient === null) {
      this.p2pClient = wearEngine.getP2pClient(ctx);
    }
    if (this.receiverCallback === undefined) {
      this.receiverCallback = (message: wearEngine.P2pMessage): void => {
        this.handleMessage(message);
      };
    }
    for (let i = 0; i < randomIds.length; i++) {
      if (this.registeredRandomIds.includes(randomIds[i])) {
        continue;
      }
      try {
        await this.p2pClient.registerMessageReceiver(randomIds[i], this.remoteAppParam, this.receiverCallback);
        this.registeredRandomIds.push(randomIds[i]);
        hilog.info(DOMAIN, TAG, `registerReceiver ok: ${randomIds[i]}`);
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(e.code, TAG, `registerReceiver failed for ${randomIds[i]}: ${e.message}`);
      }
    }
  }

  /** 注销全部已注册的消息接收 */
  public async unregisterReceivers(): Promise<void> {
    if (this.p2pClient === null || this.receiverCallback === undefined) {
      return;
    }
    for (let i = 0; i < this.registeredRandomIds.length; i++) {
      try {
        await this.p2pClient.unregisterMessageReceiver(
          this.registeredRandomIds[i], this.remoteAppParam, this.receiverCallback);
      } catch (err) {
        const e = err as BusinessError;
        hilog.error(e.code, TAG, `unregisterReceiver failed: ${e.message}`);
      }
    }
    this.registeredRandomIds = [];
  }

  /** 帧协议处理: 首帧头(FRAME_HEADER_PREFIX 前缀 JSON) → 数据帧累积 → total 齐后重组分发 */
  private handleMessage(message: wearEngine.P2pMessage): void {
    try {
      const bytes: Uint8Array = message.content;
      if (this.startsWith(bytes, FRAME_HEADER_PREFIX_BYTES)) {
        // 首帧: 头 JSON {total, count, type}
        const decoder = new util.TextDecoder('utf-8');
        const headerText = decoder.decodeToString(bytes.subarray(FRAME_HEADER_PREFIX_BYTES.byteLength));
        const header = JSON.parse(headerText) as TransferHeader;
        if (header.total <= 0) {
          hilog.error(DOMAIN, TAG, `invalid transfer header: ${headerText}`);
          return;
        }
        this.receive = {
          inProgress: true, total: header.total, count: header.count,
          type: header.type ?? MSG_TYPE_TOKENS, received: 0, chunks: []
        };
        hilog.info(DOMAIN, TAG, `receive start: total=${header.total}, count=${header.count}, type=${this.receive.type}`);
      } else if (this.receive.inProgress) {
        this.receive.chunks.push(bytes);
        this.receive.received += bytes.byteLength;
        if (this.receive.received >= this.receive.total) {
          this.assembleAndDispatch();
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `handleMessage failed: ${e.message}`);
      this.receive = { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
    }
  }

  /** 重组全部数据分片 → 解密 → 按 type 分发 */
  private async assembleAndDispatch(): Promise<void> {
    const full: Uint8Array = new Uint8Array(this.receive.total);
    let offset: number = 0;
    for (let i = 0; i < this.receive.chunks.length; i++) {
      full.set(this.receive.chunks[i], offset);
      offset += this.receive.chunks[i].byteLength;
    }
    const msgType: string = this.receive.type;
    this.receive = { inProgress: false, total: 0, count: 0, type: MSG_TYPE_TOKENS, received: 0, chunks: [] };
    try {
      // 应用层解密: 失败视为载荷被篡改或密钥版本不匹配, 丢弃且不入库
      const plain: Uint8Array | null = await decryptBlePayload(full);
      if (plain === null) {
        hilog.error(DOMAIN, TAG, 'decrypt failed: data may be tampered or key version mismatch, discarding');
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
      // 已存在令牌覆盖: 按 issuer+name 匹配本地令牌, 复用本地 TokenUUID 更新
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
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `assembleAndDispatch failed: ${e.message}`);
    }
  }

  /** 应用手机端下发的设置载荷(白名单过滤后写入手表 Preferences) */
  private async applySettings(plain: Uint8Array): Promise<void> {
    try {
      const decoder = new util.TextDecoder('utf-8');
      const pairs = JSON.parse(decoder.decodeToString(plain)) as Array<SettingValuePair>;
      let applied: number = 0;
      for (let i = 0; i < pairs.length; i++) {
        if (WEAR_SYNC_PREF_KEYS.includes(pairs[i].key)) {
          AppPreference.setPreference(pairs[i].key, pairs[i].value);
          applied++;
        }
      }
      // 刷新 TokenPreference(@Trace 字段), 手表 UI 立即按新设置重绘
      AppPreference.loadTokenAppearance();
      hilog.info(DOMAIN, TAG, `settings applied: ${applied}/${pairs.length} keys`);
      this.onSettingsApplied?.();
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(e.code, TAG, `applySettings failed: ${e.message}`);
    }
  }

  private startsWith(data: Uint8Array, prefix: Uint8Array): boolean {
    if (data.length < prefix.length) {
      return false;
    }
    for (let i = 0; i < prefix.length; i++) {
      if (data[i] !== prefix[i]) {
        return false;
      }
    }
    return true;
  }
}
