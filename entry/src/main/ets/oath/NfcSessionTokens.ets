import { common } from '@kit.AbilityKit';
import { otpType, TokenConfig } from 'common';
import { EVENT_NAMES } from 'common';
import { OathReadResult } from './OathApplet';
import { Logger } from 'common';

let logger = Logger;

/**
 * NFC 外部令牌会话存储（单例）。
 *
 * 外部令牌仅当前应用会话显示、不持久化（禁止写入 TokenStore/KV/ASSET/备份）。
 * 变更时经 eventHub 发送 EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED，
 * Index 订阅后执行合并刷新。
 */
export class NfcSessionTokens {
  private static instance: NfcSessionTokens;
  private tokens: TokenConfig[] = [];

  private constructor() {
  }

  public static getInstance(): NfcSessionTokens {
    if (!NfcSessionTokens.instance) {
      NfcSessionTokens.instance = new NfcSessionTokens();
    }
    return NfcSessionTokens.instance;
  }

  public getTokens(): TokenConfig[] {
    return this.tokens;
  }

  public remove(uuid: string): void {
    this.tokens = this.tokens.filter((t) => t.TokenUUID !== uuid);
    this.notifyChanged();
  }

  /**
   * 将一次读取结果并入会话存储。
   *
   * 去重更新（T020/US3）：按 TokenType === NFC_external && TokenIssuer === issuer
   * && TokenName === name 查找既有令牌，命中则保留原 TokenUUID 仅刷新验证码
   * （及 digits/period），未命中才新建（util.generateRandomUUID）。
   *
   * @returns 本次并入/更新的令牌条数
   */
  public applyResult(result: OathReadResult): number {
    let count = 0;
    for (const cred of result.credentials) {
      if (cred.code === null || cred.code === undefined) {
        continue;
      }
      const existing = this.tokens.find((t) =>
        t.TokenType === otpType.NFC_external &&
        t.TokenIssuer === cred.issuer &&
        t.TokenName === cred.name);
      if (existing !== undefined) {
        // 命中：创建新对象替换旧对象（保留 TokenUUID/RankScore，仅刷新验证码等字段）。
        // 必须产生新的对象引用——TokenListPage 的 LazyForEach 按 index 复用 TokenItem，
        // 若原地修改，@Param Config 引用不变，组件不会重绘，验证码无法刷新。
        const updated = new TokenConfig('', otpType.NFC_external, existing.TokenIssuer, existing.TokenName,
          'SHA1', cred.period, cred.digits, 0, existing.RankScore);
        updated.TokenUUID = existing.TokenUUID;
        updated.TokenExternalCode = cred.code;
        this.tokens[this.tokens.indexOf(existing)] = updated;
        logger.info(`applyResult HIT name=${existing.TokenName} uuid=${updated.TokenUUID}`);
      } else {
        const conf = new TokenConfig('', otpType.NFC_external, cred.issuer, cred.name,
          'SHA1', cred.period, cred.digits, 0, 0);
        conf.TokenSecret = '';
        conf.TokenExternalCode = cred.code;
        this.tokens.push(conf);
        logger.info(`applyResult NEW name=${cred.name} uuid=${conf.TokenUUID}`);
      }
      count++;
    }
    this.notifyChanged();
    logger.info(`applyResult merged=${count} total=${this.tokens.length}`);
    return count;
  }

  private notifyChanged(): void {
    const appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (appCtx !== undefined && appCtx !== null && appCtx.eventHub !== undefined) {
      appCtx.eventHub.emit(EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED);
    }
  }
}
