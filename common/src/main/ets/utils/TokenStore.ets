import { KvManager } from "./KvManager";
import { TokenConfig, otpType, copyTokenConfig, sanitizedTokenForTransfer } from "./TokenConfig";
import { TokenGroupStore } from './TokenGroupStore';
import { TokenBatchProgressCallback, TokenBatchStage, reportTokenBatchProgress } from './TokenBatchProgress';
import { common } from '@kit.AbilityKit';
import { EVENT_NAMES, PREF_KEYS, AppPreference } from "./AppPreference";
import { SecretStore, TokenKvStore } from './StoragePorts';
import { AssetSecretStore } from './AssetSecretStore';
import { SteamSecretStore } from './SteamSecretStore';
import { SteamAuth } from './SteamAuth';
import { hilog } from '@kit.PerformanceAnalysisKit';

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
 * - 写入: updateTokens()/updateToken() → KV 事务提交完整配置 → ASSET 同步变更 Secret
 * - 读取: LoadTokenByDataBase() → KV 加载 → ASSET 批量回填 Secret（优先）
 * - 删除: deleteToken() → ASSET 删除 Secret + KV 删除元数据
 *
 * 存量用户迁移: fillSecretsFromAsset() 自动检测 KV 中尚未在 ASSET
 * 的旧 Secret，三重验证确认 ASSET 正常后写入（KV 保留不动，仅增加 ASSET 副本）。
 *
 * TODO: ASSET 迁移完全落地后，当 Secret 满足 isSecretSizeValid 条件时，
 * KV 不再存储 TokenSecret（仅保留元数据），Secret 唯一存储于 ASSET。
 * 届时需重新设计跨 KV/ASSET 提交与恢复流程，再清空 KV 中的 TokenSecret，
 * fillSecretsFromAsset() 成为 Secret 的唯一读取来源。
 * 超大 Secret（>900 字节）仍降级存储到 KV。
 * 此变更需确保 BackupRestoreHelper / CloudBackupManager 等备份恢复路径兼容。
 */
export class TokenStore {
  // 设备专属能力（换机分布式同步/整库文件备份）不参与端口注入，保持具体引用。
  private kvMgr: KvManager = KvManager.getInstance();
  // 令牌主存储与密钥读写走端口（Phase 2 解耦，见 docs/TEST_PLAN.md 第 4 节）。
  private kvBackend: TokenKvStore = KvManager.getInstance();
  private assetStore: SecretStore = AssetSecretStore.getInstance();
  private steamSecretStore: SteamSecretStore = SteamSecretStore.getInstance();
  private token_array: TokenConfig[] = [];
  private appCtx: common.UIAbilityContext | undefined = undefined;
  private init_done: boolean = false;
  private static instance: TokenStore;

  private token_prefix: string = "_token_uuid_";
  private mutationQueue: Promise<void> = Promise.resolve();

  /**
   * 测试注入：LocalUnit 下 distributedKVStore/asset 不可用，
   * 替换 KV/密钥端口并清空内存状态，隔离用例间污染。
   */
  public useBackendsForTest(kv: TokenKvStore, secrets: SecretStore, steam?: SteamSecretStore): void {
    this.kvBackend = kv;
    this.assetStore = secrets;
    if (steam !== undefined) {
      this.steamSecretStore = steam;
    }
    this.token_array = [];
    this.init_done = false;
    this.mutationQueue = Promise.resolve();
    this.appCtx = undefined;
  }

  // 排序、单条编辑、批量操作和重新加载共享队列，避免 await 期间互相覆盖内存快照。
  private enqueueMutation(operation: () => Promise<void>): Promise<void> {
    const pending = this.mutationQueue.then(operation);
    this.mutationQueue = pending.catch(() => {});
    return pending;
  }

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
    await this.kvBackend.init();
    await this.LoadTokenByDataBase();
    this.init_done = true;
  }

  public async LoadTokenByDataBase(): Promise<void> {
    return this.enqueueMutation(async () => {
      await TokenGroupStore.getInstance().load();
      this.token_array = await this.kvBackend.getTokenArray(this.token_prefix);
      // KV 里的对象是 JSON 裸数据：TokenConfig/SteamAuth 都没有原型方法，
      // 统一用 copyTokenConfig 重建实例，否则后续调用实例方法会崩溃
      this.token_array = this.token_array.map((token: TokenConfig): TokenConfig => copyTokenConfig(token));
      this.appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
      await this.fillSecretsFromAsset();
      await this.fillSteamSecretsFromAsset();
      this.sortTokens();
    });
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

  /**
   * 从 ASSET 回填 Steam 凭证，并迁移旧版 mafile 数据。
   *
   * - 新数据：KV 只存非敏感元数据；identity_secret / revocation_code / refresh_token 在 ASSET
   * - 旧数据：TokenConfig.SteamMaFile 内含明文密钥，转换为 SteamAuth 并补写 ASSET，
   *   后续保存时 sanitizedForTransfer() 会把 KV 中的 mafile 密钥剥离
   */
  private async fillSteamSecretsFromAsset(): Promise<void> {
    for (const token of this.token_array) {
      if (token.TokenType !== otpType.Steam) {
        continue;
      }
      let migratedFromMaFile: boolean = false;
      if (token.SteamAuth === undefined && token.SteamMaFile !== undefined) {
        token.SteamAuth = SteamAuth.fromMaFile(token.SteamMaFile);
        migratedFromMaFile = true;
      }
      const auth: SteamAuth | undefined = token.SteamAuth;
      if (auth === undefined) {
        continue;
      }
      await this.steamSecretStore.load(token.TokenUUID, auth);
      if (migratedFromMaFile && (auth.identitySecret.length > 0 || auth.revocationCode.length > 0)) {
        await this.steamSecretStore.save(token.TokenUUID, auth);
        hilog.info(DOMAIN, TAG, `fillSteamSecretsFromAsset: migrated legacy mafile ${token.TokenUUID}`);
      }
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
    let token = await this.kvBackend.getValue<TokenConfig>(`${this.token_prefix}${token_uuid}`);
    if (token && token.TokenSecret.length === 0) {
      const secret = await this.assetStore.querySecret(token_uuid);
      if (secret !== null) {
        token.TokenSecret = secret;
      }
    }
    if (!token) {
      return new TokenConfig();
    }
    // 同上：补齐原型方法后再交给 UI
    return copyTokenConfig(token);
  }

  public sortTokens(): void {
    this.token_array = this.token_array.sort((a, b) => a.RankScore - b.RankScore)
    this.emitTokenChanged();
  }

  /** KV 提交成功后同步新增/变更的密钥；ASSET 失败仍保留完整加密 KV 降级副本。 */
  private async saveTokenSecret(token: TokenConfig): Promise<void> {
    const secret = token.TokenSecret;
    if (secret.length > 0 && this.assetStore.isSecretSizeValid(secret)) {
      const saved = await this.assetStore.upsertSecret(token.TokenUUID, secret);
      if (!saved) {
        // 写入失败时不保留可能已过期的密钥，完整加密 KV 仍可恢复。
        await this.assetStore.removeSecret(token.TokenUUID);
      }
    } else {
      // 密钥清空或变为超限长度时清除旧 ASSET 副本，避免迁移回填旧值。
      await this.assetStore.removeSecret(token.TokenUUID);
    }
  }

  /**
   * 仅持久化到 KV（不涉及 ASSET）.
   *
   * 用于 RankScore 等非 Secret 字段变更场景，避免不必要的 TEE 硬件调用。
   */
  private async saveTokenKvOnly(token: TokenConfig): Promise<void> {
    await this.kvBackend.setValue<TokenConfig>(`${this.token_prefix}${token.TokenUUID}`, token);
  }

  public async moveTokenToGroup(uuid: string, groupId: string): Promise<void> {
    return this.enqueueMutation(async () => {
      const index = this.token_array.findIndex(item => item.TokenUUID === uuid);
      if (index < 0 || this.token_array[index].TokenType === otpType.NFC_external) {
        return;
      }
      if (groupId !== '' && !TokenGroupStore.getInstance().state.groups.some(group => group.id === groupId)) {
        throw new Error('Group no longer exists');
      }
      if ((this.token_array[index].TokenGroupId ?? '') === groupId) {
        return;
      }
      const token = copyTokenConfig(this.token_array[index]);
      token.TokenGroupId = groupId;
      await this.saveTokenKvOnly(token);
      this.token_array[index] = token;
      this.emitTokenChanged();
    });
  }

  public async setTokenFavorite(uuid: string, favorite: boolean): Promise<void> {
    return this.setTokensFavorite([uuid], favorite);
  }

  /** 只写入真正改变的本地令牌；同一事务、同一次列表刷新，不访问 ASSET。 */
  public async setTokensFavorite(uuids: string[], favorite: boolean,
    onProgress?: TokenBatchProgressCallback): Promise<void> {
    const selected = new Set(uuids);
    return this.enqueueMutation(async () => {
      const changed: TokenConfig[] = [];
      const next = this.token_array.map((token: TokenConfig): TokenConfig => {
        if (!selected.has(token.TokenUUID) || token.TokenType === otpType.NFC_external ||
          (token.TokenFavorite === true) === favorite) {
          return token;
        }
        const updated = copyTokenConfig(token);
        updated.TokenFavorite = favorite;
        changed.push(updated);
        return updated;
      });
      if (changed.length > 0) {
        await this.kvBackend.saveTokenBatch(this.token_prefix, changed, [], onProgress);
        this.token_array = next;
        this.emitTokenChanged();
      }
      reportTokenBatchProgress(onProgress, TokenBatchStage.DONE, changed.length, changed.length);
    });
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
    return this.enqueueMutation(async () => {
      if (from === to || from < 0 || to < 0 || from >= this.token_array.length || to >= this.token_array.length) {
        return;
      }
      const next = [...this.token_array];
      const moved = next.splice(from, 1)[0];
      next.splice(to, 0, moved);
      const changed: TokenConfig[] = [];
      for (let i = Math.min(from, to); i <= Math.max(from, to); i++) {
        const updated = copyTokenConfig(next[i]);
        updated.RankScore = i;
        next[i] = updated;
        changed.push(updated);
      }
      await this.kvBackend.saveTokenBatch(this.token_prefix, changed);
      this.token_array = next;
      this.emitTokenChanged();
    });
  }

  public async updateToken(token: TokenConfig): Promise<void> {
    const snapshot = copyTokenConfig(token);
    return this.enqueueMutation(() => this.persistTokens([snapshot], true));
  }

  /** URI/备份统一批量入口。UUID 覆盖语义不变，KV 失败整批回滚，不发布未保存数据。 */
  public async updateTokens(tokens: TokenConfig[], onProgress?: TokenBatchProgressCallback): Promise<void> {
    const snapshots = tokens.map((token: TokenConfig): TokenConfig => copyTokenConfig(token));
    return this.enqueueMutation(() => this.persistTokens(snapshots, false, onProgress));
  }

  private async persistTokens(tokens: TokenConfig[], single: boolean,
    onProgress?: TokenBatchProgressCallback): Promise<void> {
    if (tokens.length === 0) {
      reportTokenBatchProgress(onProgress, TokenBatchStage.DONE);
      return;
    }
    const next = [...this.token_array];
    const indexes = new Map<string, number>();
    const originalSecrets = new Map<string, string>();
    let nextRank = 0;
    this.token_array.forEach((token: TokenConfig, index: number) => {
      indexes.set(token.TokenUUID, index);
      originalSecrets.set(token.TokenUUID, token.TokenSecret);
      nextRank = Math.max(nextRank, token.RankScore + 1);
    });
    const previousGroup = indexes.has(tokens[0].TokenUUID) ?
      (next[indexes.get(tokens[0].TokenUUID)!].TokenGroupId ?? '') : '';
    const changed = new Map<string, TokenConfig>();
    for (const token of tokens) {
      if (!token.TokenUUID || typeof token.TokenSecret !== 'string' || token.TokenType === otpType.NFC_external) {
        throw new Error('Invalid persistent token');
      }
      const index = indexes.get(token.TokenUUID);
      const updated = copyTokenConfig(token);
      updated.TokenGroupId = token.TokenGroupId ?? '';
      if (index === undefined) {
        // 兼容历史 RankScore 有间隙的库，新令牌始终追加末尾。
        updated.RankScore = nextRank++;
        indexes.set(updated.TokenUUID, next.length);
        next.push(updated);
      } else {
        updated.RankScore = next[index].RankScore;
        // 已有令牌保留本地收藏；同批重复 UUID 最后一条内容生效，顺序保持首次出现的位置。
        updated.TokenFavorite = next[index].TokenFavorite === true;
        next[index] = updated;
      }
      changed.set(updated.TokenUUID, updated);
    }
    const writes = Array.from(changed.values());
    // 先提交完整加密 KV，避免 KV 失败留下幽灵内存条目或提前覆盖 ASSET。
    // KV 副本必须剥离 Steam 凭证与 mafile 密钥：TokenConfig 会被手表同步原样序列化，
    // 高权限字段（identity_secret / refresh_token / revocation_code）只允许留在 ASSET。
    const kvWrites = writes.map((token: TokenConfig): TokenConfig => sanitizedTokenForTransfer(token));
    await this.kvBackend.saveTokenBatch(this.token_prefix, kvWrites, [], onProgress);
    this.token_array = next;
    const secretWrites = writes.filter(token => originalSecrets.get(token.TokenUUID) !== token.TokenSecret);
    if (secretWrites.length > 0) {
      reportTokenBatchProgress(onProgress, TokenBatchStage.WRITING_SECRETS, 0, secretWrites.length);
      for (let i = 0; i < secretWrites.length; i++) {
        await this.saveTokenSecret(secretWrites[i]);
        reportTokenBatchProgress(onProgress, TokenBatchStage.WRITING_SECRETS, i + 1, secretWrites.length);
      }
    }
    // Steam 凭证写入 ASSET（内存对象保留明文，KV 副本已剥离）
    for (let i = 0; i < writes.length; i++) {
      const token: TokenConfig = writes[i];
      if (token.TokenType !== otpType.Steam) {
        continue;
      }
      const auth: SteamAuth | undefined = token.SteamAuth;
      if (auth === undefined) {
        continue;
      }
      await this.steamSecretStore.save(token.TokenUUID, auth);
    }
    if (single) {
      this.emitTokenSingleUpdated(writes[0]);
      if (previousGroup !== writes[0].TokenGroupId) {
        this.emitTokenChanged();
      }
    } else {
      this.emitTokenChanged();
    }
    reportTokenBatchProgress(onProgress, TokenBatchStage.DONE, writes.length, writes.length);
  }

  public async deleteToken(token_uuid: string): Promise<void> {
    return this.deleteTokens([token_uuid]);
  }

  /** 一次过滤、一次重排，仅重写剩余且排序变化的令牌；清空时零排序写入。 */
  public async deleteTokens(uuids: string[], onProgress?: TokenBatchProgressCallback): Promise<void> {
    const selected = new Set(uuids);
    return this.enqueueMutation(async () => {
      const removed = this.token_array.filter(token => selected.has(token.TokenUUID));
      if (removed.length === 0) {
        reportTokenBatchProgress(onProgress, TokenBatchStage.DONE);
        return;
      }
      const changed: TokenConfig[] = [];
      const next: TokenConfig[] = [];
      let removedBefore = 0;
      for (const token of this.token_array) {
        if (selected.has(token.TokenUUID)) {
          removedBefore++;
        } else if (removedBefore === 0) {
          next.push(token);
        } else {
          // 保持旧排序语义：只扣除前面删除的数量，不顺便重排其他历史数据。
          const updated = copyTokenConfig(token);
          updated.RankScore = token.RankScore - removedBefore;
          next.push(updated);
          changed.push(updated);
        }
      }
      await this.kvBackend.saveTokenBatch(this.token_prefix, changed, removed.map(token => token.TokenUUID), onProgress);
      this.token_array = next;
      reportTokenBatchProgress(onProgress, TokenBatchStage.REMOVING_SECRETS, 0, removed.length);
      for (let i = 0; i < removed.length; i++) {
        await this.assetStore.removeSecret(removed[i].TokenUUID);
        await this.steamSecretStore.remove(removed[i].TokenUUID);
        reportTokenBatchProgress(onProgress, TokenBatchStage.REMOVING_SECRETS, i + 1, removed.length);
      }
      this.emitTokenChanged();
      reportTokenBatchProgress(onProgress, TokenBatchStage.DONE, removed.length, removed.length);
    });
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
