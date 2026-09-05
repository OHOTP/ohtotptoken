import { HMACAlgorithm } from './TokenUtils';
import { util } from '@kit.ArkTS';
import { maFile } from './SteamUtils';
export enum otpType {
  TOTP,
  Forti,
  HOTP,
  Steam,
  /** 外部OATH设备（NFC读取）令牌：仅当前会话显示，静态验证码 */
  NFC_external = 4
}
export class TokenConfig {
  TokenUUID: string;
  TokenType: otpType;
  TokenSecret: string;
  TokenIssuer: string;
  TokenName: string;
  TokenAlgorithm: HMACAlgorithm;
  TokenPeriod: number;
  TokenDigits: number;
  TokenCounter: number;
  FortiToken: string;
  FortiDevID: string;
  RankScore: number;
  /** 空值或旧数据缺失字段表示未分组。 */
  TokenGroupId: string = '';
  SteamMaFile: maFile | undefined = undefined;
  TokenIconPath: string | undefined = undefined;
  /** 外部OATH设备（NFC）令牌的静态验证码缓存：仅会话显示，不持久化 */
  TokenExternalCode: string = '';

  constructor(
    secret: string = '',
    type: otpType = 0,
    issuer: string = 'Issuer',
    name: string = 'Name',
    algorithm: HMACAlgorithm = 'SHA1',
    period: number = 30,
    digits: number = 6,
    counter: number = 0,
    rank: number = 0
  ) {
    this.TokenSecret = secret;
    this.TokenType = type;
    this.TokenIssuer = issuer;
    this.TokenName = name;
    this.TokenAlgorithm = algorithm;
    this.TokenPeriod = period;
    this.TokenDigits = digits;
    this.TokenCounter = counter;
    this.FortiToken = '';
    this.FortiDevID = '';
    this.TokenUUID = util.generateRandomUUID();
    this.RankScore = rank;
  }
}

/**
 * LazyForEach ViewModel 包装层。
 *
 * ArkUI LazyForEach 通过 key (keyGenerator 返回值) 标识组件实例。
 * 当 key 不变时组件被复用，key 变化时销毁旧实例并创建新实例
 * （触发 aboutToAppear 重新初始化 OTP 计算等状态）。
 *
 * objid 作为 LazyForEach key，初始等于 TokenUUID。
 * 当单条 Token 被编辑或 HOTP 计数器自增后，调用 refreshObjId()
 * 生成新的随机 UUID 作为 key，迫使 LazyForEach 销毁并重建该行组件，
 * 从而保证 UI 与最新数据一致——无需依赖 @Observed/@Trace 等深度观测机制。
 */
export class TokenConfigVM {
  /** LazyForEach key —— 变更即触发组件重建 */
  objid: string;
  /** 实际数据，引用与 TokenStore.token_array 中的对象共享 */
  config: TokenConfig;

  constructor(config: TokenConfig) {
    this.config = config;
    this.objid = config.TokenUUID;
  }

  /** 生成全新 objid，配合 updateItem() 通知 LazyForEach，使目标行立即重建 */
  refreshObjId(): void {
    this.objid = util.generateRandomUUID();
  }
}