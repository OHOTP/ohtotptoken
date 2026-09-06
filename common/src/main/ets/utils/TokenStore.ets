import { KvManager } from "./KvManager";
import { TokenConfig, otpType } from "./TokenConfig";
import { TokenGroupStore } from './TokenGroupStore';
import { RdbManager } from "./RdbManager";
import { common } from '@kit.AbilityKit';
import { EVENT_NAMES, PREF_KEYS, AppPreference } from "./AppPreference";
import { AssetSecretStore } from './AssetSecretStore';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'TokenStore';
const DOMAIN = 0xFF00;

/**
 * Token 数据存储管理器（单例）.
 *
 * TokenConfig 元数据（发行方、名称、算法等）存储在加密 KV 数据库，
 * TokenSecret 同时存储在以下两处以兼顾安全与数据安全：
 * - ASSET（TEE 硬件保护 + AES256-GCM）：首次写入时自动迁移，运行时优先从中读取
 * - 加密 KV（软件加密 S4 级别）：作为备份/克隆场景的降级路径
 *
 * 上层代码通过 {@link TokenConfig.TokenSecret} 字段透明读写，
 * 无需感知底层存储拆分。
 *
 * 数据流：
 * - 写入: saveToken() → ASSET upsert Secret + KV 写入完整 TokenConfig
 * - 读取: LoadTokenByDataBase() → KV 加载 → ASSET 批量回填 Secret（优先）
 * - 删除: deleteToken() → ASSET 删除 Secret + KV 删除元数据
 *
 * 存量用户迁移: fillSecretsFromAsset() 自动检测 KV 中尚未在 ASSET
 * 的旧 Secret，三重验证确认 ASSET 正常后写入（KV 保留不动，仅增加 ASSET 副本）。
 *
 * TODO: ASSET 迁移完全落地后，当 Secret 满足 isSecretSizeValid 条件时，
 * KV 不再存储 TokenSecret（仅保留元数据），Secret 唯一存储于 ASSET。
 * 届时 saveToken() 写入 KV 前需清空 TokenConfig.TokenSecret，
 * fillSecretsFromAsset() 成为 Secret 的唯一读取来源。
 * 超大 Secret（>900 字节）仍降级存储到 KV。
 * 此变更需确保 BackupRestoreHelper / CloudBackupManager 等备份恢复路径兼容。
 */
export class TokenStore {
  private kvMgr: KvManager = KvManager.getInstance();
  private rdbMgr: RdbManager = RdbManager.getInstance();
  private assetStore: AssetSecretStore = AssetSecretStore.getInstance();
  private token_array: TokenConfig[] = [];
  private appCtx: common.UIAbilityContext | undefined = undefined;
  private init_done: boolean = false;
  private static instance: TokenStore;

  private token_prefix: string = "_token_uuid_";

  private constructor() {
  }

  private async emitTokenChanged(): Promise<void> {
    this.appCtx?.eventHub.emit(EVENT_NAMES.TOKEN_CHANGED);
  }

  /**
   * 单条 Token 更新事件（精准刷新）。
   *
   * 与 TOKEN_CHANGED（全量刷新）不同，此事件携带完整 TokenConfig，
   * 消费方可按 UUID 精准定位并仅刷新该条记录，避免全列表重建。
   */
  private async emitTokenSingleUpdated(token: TokenConfig): Promise<void> {
    this.appCtx?.eventHub.emit(EVENT_NAMES.TOKEN_SINGLE_UPDATED, token);
  }

  public static getInstance(): TokenStore {
    if (!TokenStore.instance) {
      TokenStore.instance = new TokenStore();
    }
    return TokenStore.instance;
  }

  public async initTokenStore(): Promise<void> {
    if (this.init_done) {
      return;
    }
    await this.kvMgr.initKvManager();
    await this.LoadTokenByDataBase();
    this.init_done = true;
  }

  public async LoadTokenByDataBase(): Promise<void> {
     await TokenGroupStore.getInstance().load();
     this.token_array = await this.kvMgr.getTokenArray(this.token_prefix)
     this.appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
     await this.fillSecretsFromAsset();
     this.sortTokens();
  }

  /**
   * 从 ASSET 回填 Secret 到内存，并迁移旧版 KV 数据到 ASSET.
   *
   * 一次性迁移：完成一次后持久化 {@link PREF_KEYS.ASSET_MIGRATION_DONE}=true，
   * 后续调用直接返回（零 ASSET I/O），不再重复检查。
   * 三种无需迁移/跳过场景：
   * - 空 Token 列表（新用户）：直接设标记 true。
   * - 标记已为 true：立即返回，KV 双写保证 Secret 始终可用。
   * - Secret 超过 ASSET 字节上限（>900 字节 UTF-8）：视为不可迁移，
   *   不设 migrationFailed（因非失败，乃设计降级），滞留 KV 单写。
   *
   * 设计原则：ASSET 是首要来源，KV 是安全后裔（降级/克隆场景）。
   * 迁移仅增加 ASSET 副本，不清除 KV 数据。
   *
   * 三种路径：
   * 1. ASSET 已有 Secret → 直接使用（优先 TEE 保护版本）
   * 2. ASSET 无 Secret 但 KV 有 → 旧版数据，执行迁移并回填
   * 3. ASSET 和 KV 皆无 Secret → Secret 为空（如云端恢复尚未完成）
   *
   * 迁移三重防呆：
   * - 第一重: upsertSecret 返回 true（ASSET add 调用未抛异常）
   * - 第二重: querySecret 返回非 null（ASSET 确实能查回该条目）
   * - 第三重: 查询结果与原始 Secret 内容一致（数据完整性校验）
   * 三重全部通过后才将 ASSET 版本标记为优先来源。
   * 任何一重失败则保留 KV 数据，下次加载重试。
   */
  private async fillSecretsFromAsset(): Promise<void> {
    if (AppPreference.getPreference(PREF_KEYS.ASSET_MIGRATION_DONE)) {
      return;
    }

    if (this.token_array.length === 0) {
      AppPreference.setPreference(PREF_KEYS.ASSET_MIGRATION_DONE, true);
      return;
    }

    const uuids: string[] = [];
    for (const t of this.token_array) {
      uuids.push(t.TokenUUID);
    }
    const assetSecrets: Map<string, string> = await this.assetStore.batchQuerySecrets(uuids);

    let migrationFailed = false;
    for (const token of this.token_array) {
      const assetSecret = assetSecrets.get(token.TokenUUID);
      if (assetSecret !== undefined && assetSecret !== null) {
        token.TokenSecret = assetSecret;
      } else if (token.TokenSecret.length > 0) {
        if (this.assetStore.isSecretSizeValid(token.TokenSecret)) {
          const originalSecret = token.TokenSecret;

          const upsertOk = await this.assetStore.upsertSecret(token.TokenUUID, originalSecret);
          if (!upsertOk) {
            migrationFailed = true;
            continue;
          }

          const verifySecret = await this.assetStore.querySecret(token.TokenUUID);
          if (verifySecret === null) {
            hilog.error(DOMAIN, TAG, `fillSecretsFromAsset: verify failed (not found) for ${token.TokenUUID}`);
            migrationFailed = true;
            continue;
          }

          if (verifySecret !== originalSecret) {
            hilog.error(DOMAIN, TAG, `fillSecretsFromAsset: verify failed (mismatch) for ${token.TokenUUID}`);
            migrationFailed = true;
            continue;
          }

          hilog.info(DOMAIN, TAG, `fillSecretsFromAsset: migrated ${token.TokenUUID} to ASSET (triple verified)`);
        }
      }
    }

    if (!migrationFailed) {
      AppPreference.setPreference(PREF_KEYS.ASSET_MIGRATION_DONE, true);
      hilog.info(DOMAIN, TAG, 'fillSecretsFromAsset: all tokens migrated, flag set');
    }
  }

  public async getTokens(): Promise<TokenConfig[]> {
    return this.token_array;
  }

  /**
   * 按UUID查询单条 Token（KV + ASSET 组合读取）.
   *
   * 先从 KV 加载完整 TokenConfig，若已有 Secret 则直接返回（降级场景），
   * 否则尝试从 ASSET 回填。ASSET 不可用时 KV 中的 Secret 作为安全后裔。
   */
  public async queryToken(token_uuid: string): Promise<TokenConfig> {
    let token = await this.kvMgr.getValue<TokenConfig>(`${this.token_prefix}${token_uuid}`);
    if (token && token.TokenSecret.length === 0) {
      const secret = await this.assetStore.querySecret(token_uuid);
      if (secret !== null) {
        token.TokenSecret = secret;
      }
    }
    return token ?? new TokenConfig();
  }

  public sortTokens(): void {
    this.token_array = this.token_array.sort((a, b) => a.RankScore - b.RankScore)
    this.emitTokenChanged();
  }

  /**
   * 持久化单条 Token（ASSET + KV 双写）.
   *
   * 仅在 Secret 发生变更时调用（如 updateToken）。
   * ASSET 写入失败时不回退 KV（KV 仍作为安全后裔），
   * Secret 为空时同步清除 ASSET 条目。
   * KV 始终写入完整 TokenConfig（含 Secret），确保备份/克隆场景数据完整。
   */
  private async saveToken(token: TokenConfig): Promise<void> {
    const secret = token.TokenSecret;
    if (secret.length > 0 && this.assetStore.isSecretSizeValid(secret)) {
      await this.assetStore.upsertSecret(token.TokenUUID, secret);
    } else if (secret.length === 0) {
      await this.assetStore.removeSecret(token.TokenUUID);
    }
    // KV 始终写入完整 TokenConfig（含 Secret），作为备份/克隆的数据后裔
    // TODO: ASSET 迁移落地后，满足 isSecretSizeValid 时 KV 不再存储 Secret，
    // 改为: token.TokenSecret = '' 后再写入 KV，Secret 唯一存于 ASSET
    await this.kvMgr.setValue<TokenConfig>(`${this.token_prefix}${token.TokenUUID}`, token);
  }

  /**
   * 仅持久化到 KV（不涉及 ASSET）.
   *
   * 用于 RankScore 等非 Secret 字段变更场景，避免不必要的 TEE 硬件调用。
   */
  private async saveTokenKvOnly(token: TokenConfig): Promise<void> {
    await this.kvMgr.setValue<TokenConfig>(`${this.token_prefix}${token.TokenUUID}`, token);
  }

  public async moveTokenToGroup(uuid: string, groupId: string): Promise<void> {
    const token = this.token_array.find(item => item.TokenUUID === uuid);
    if (!token || token.TokenType === otpType.NFC_external) {
      return;
    }
    if (groupId !== '' && !TokenGroupStore.getInstance().state.groups.some(group => group.id === groupId)) {
      throw new Error('Group no longer exists');
    }
    const previous = token.TokenGroupId;
    token.TokenGroupId = groupId;
    try {
      await this.saveTokenKvOnly(token);
    } catch (error) {
      token.TokenGroupId = previous;
      throw new Error((error as BusinessError).message);
    }
    this.emitTokenChanged();
  }

  public async setTokenFavorite(uuid: string, favorite: boolean): Promise<void> {
    const token = this.token_array.find(item => item.TokenUUID === uuid);
    if (!token || token.TokenType === otpType.NFC_external) {
      return;
    }
    const previous = token.TokenFavorite;
    token.TokenFavorite = favorite;
    try {
      await this.saveTokenKvOnly(token);
    } catch (error) {
      token.TokenFavorite = previous;
      throw new Error((error as BusinessError).message);
    }
    this.emitTokenChanged();
  }

  public async deleteGroup(id: string): Promise<void> {
    // 先归还令牌，再删除目录；中断时目录仍存在，可安全重试。
    for (const token of this.token_array.filter(item => item.TokenGroupId === id)) {
      await this.moveTokenToGroup(token.TokenUUID, '');
    }
    await TokenGroupStore.getInstance().remove(id);
    this.emitTokenChanged();
  }

  public async updateTokenRank(from: number, to: number): Promise<void> {
    this.token_array[from].RankScore = to;
    await this.saveTokenKvOnly(this.token_array[from]);
    if (from > to) {
      for (let i = to; i < from; i++) {
        this.token_array[i].RankScore++;
        await this.saveTokenKvOnly(this.token_array[i]);
      }
    } else {
      for (let i = from + 1; i <= to; i++) {
        this.token_array[i].RankScore--;
        await this.saveTokenKvOnly(this.token_array[i]);
      }
    }
    this.sortTokens();
  }

  public async updateToken(token: TokenConfig): Promise<void> {
    const token_new = token;
    token_new.TokenGroupId = token_new.TokenGroupId ?? '';
    const previousGroupId = this.token_array.find(item => item.TokenUUID === token.TokenUUID)?.TokenGroupId ?? '';
    const token_uuids = this.token_array.map(t => t.TokenUUID);
    if (!token_uuids.includes(token_new.TokenUUID)) {
      token_new.RankScore = this.token_array.length;
      this.token_array.push(token_new);
    } else {
      const token_index = token_uuids.findIndex(uuid => uuid === token_new.TokenUUID);
      token_new.RankScore = this.token_array[token_index].RankScore;
      // 编辑表单重建 TokenConfig 时保留本地收藏状态；收藏操作走独立元数据入口。
      token_new.TokenFavorite = this.token_array[token_index].TokenFavorite === true;
      this.token_array[token_index] = token_new;
    }
    await this.saveToken(token_new);
    this.emitTokenSingleUpdated(token_new);
    if (previousGroupId !== token_new.TokenGroupId) {
      this.emitTokenChanged();
    }
  }

  public async deleteToken(token_uuid: string): Promise<void> {
    const token_uuids = this.token_array.map(t => t.TokenUUID);
    const token_index = token_uuids.findIndex(uuid => uuid === token_uuid);
    if (token_index === -1) {
      return;
    }
    for (let i = token_index; i < this.token_array.length; i++) {
      this.token_array[i].RankScore--;
      await this.saveTokenKvOnly(this.token_array[i]);
    }
    this.token_array = this.token_array.filter(t => t.TokenUUID !== token_uuid);
    await this.kvMgr.deleteValue(`${this.token_prefix}${token_uuid}`);
    await this.assetStore.removeSecret(token_uuid);
    this.emitTokenChanged();
  }

  /**
    * 手动触发同步.
    *
    */
  async DataSync(): Promise<void> {
    await this.kvMgr.DataSync();
  }
  /**
    * 备份整个kv数据库到目标文件.
    *
    * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
    */
  public BuckupToFile(backupFile:string): void {
    this.kvMgr.BuckupToFile(backupFile);
  }
  /**
    * 从备份文件中还原整个数据库.
    *
    * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
    */
  public RestoreByFile(backupFile:string): void {
    this.kvMgr.RestoreByFile(backupFile);
  }
}
