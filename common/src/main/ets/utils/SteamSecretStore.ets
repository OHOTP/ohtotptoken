import { NamedSecretStore } from './StoragePorts';
import { AssetSecretStore } from './AssetSecretStore';
import { joinSecretChunks, splitSecretChunks, SteamAuth } from './SteamAuth';

/**
 * Steam 凭证的 ASSET（TEE）存储。
 *
 * 为什么要单独存：
 * - `TokenConfig` 会被序列化进加密 KV，并**原样同步到手表**（BLE/WearEngine），
 *   把 `identity_secret` / `refresh_token` 放进去等于把它们发到手表；
 * - ASSET 由 TEE 保护且支持换机克隆（SYNC_TYPE.TRUSTED_DEVICE），符合本项目
 *   「密钥进 ASSET、元数据进 KV」的既有原则。
 *
 * 别名规则（每条 ≤ 900 字节，超长则分片）：
 * - `opt_steam_sec_{uuid}_id`   identity_secret（base64，几十字节）
 * - `opt_steam_sec_{uuid}_rev`  revocation_code
 * - `opt_steam_sec_{uuid}_rt_{i}` refresh_token 分片（JWT 可能 > 900 字节）
 */

const ALIAS_PREFIX = 'opt_steam_sec_';
const FIELD_IDENTITY = 'id';
const FIELD_REVOCATION = 'rev';
const FIELD_REFRESH = 'rt';
/** refresh_token 最大分片数（8 × 800 ≈ 6.4KB，远超 JWT 实际长度） */
const MAX_REFRESH_CHUNKS = 8;

export class SteamSecretStore {
  private static instance: SteamSecretStore;
  private assets: NamedSecretStore = AssetSecretStore.getInstance();

  private constructor() {}

  public static getInstance(): SteamSecretStore {
    if (!SteamSecretStore.instance) {
      SteamSecretStore.instance = new SteamSecretStore();
    }
    return SteamSecretStore.instance;
  }

  /** 测试注入：LocalUnit 下 asset 不可用，替换为内存别名密钥后端。 */
  useBackendForTest(assets: NamedSecretStore): void {
    this.assets = assets;
  }

  private alias(tokenUUID: string, field: string): string {
    return `${ALIAS_PREFIX}${tokenUUID}_${field}`;
  }

  private async saveSingle(tokenUUID: string, field: string, value: string): Promise<void> {
    const alias: string = this.alias(tokenUUID, field);
    if (value.length === 0) {
      await this.assets.removeNamedSecret(alias);
      return;
    }
    await this.assets.upsertNamedSecret(alias, value);
  }

  private async saveChunked(tokenUUID: string, field: string, value: string): Promise<void> {
    const chunks: string[] = splitSecretChunks(value);
    for (let i = 0; i < chunks.length; i++) {
      await this.assets.upsertNamedSecret(`${this.alias(tokenUUID, field)}_${i}`, chunks[i]);
    }
    // 只清理「上次确实写过、这次不再需要」的尾部分片：先探测再删除，
    // 避免每次保存都发起 MAX_REFRESH_CHUNKS 次无意义的 TEE 调用。
    let stale: number = chunks.length;
    while (stale < MAX_REFRESH_CHUNKS) {
      const existing: string | null = await this.assets.queryNamedSecret(
        `${this.alias(tokenUUID, field)}_${stale}`);
      if (existing === null) {
        break;
      }
      await this.assets.removeNamedSecret(`${this.alias(tokenUUID, field)}_${stale}`);
      stale += 1;
    }
  }

  private async loadChunked(tokenUUID: string, field: string): Promise<string> {
    const chunks: string[] = [];
    for (let i = 0; i < MAX_REFRESH_CHUNKS; i++) {
      const value: string | null = await this.assets.queryNamedSecret(
        `${this.alias(tokenUUID, field)}_${i}`);
      if (value === null) {
        break;
      }
      chunks.push(value);
    }
    return joinSecretChunks(chunks);
  }

  /** 写入 Steam 凭证（identity_secret / revocation_code / refresh_token） */
  async save(tokenUUID: string, auth: SteamAuth): Promise<void> {
    await this.saveSingle(tokenUUID, FIELD_IDENTITY, auth.identitySecret);
    await this.saveSingle(tokenUUID, FIELD_REVOCATION, auth.revocationCode);
    await this.saveChunked(tokenUUID, FIELD_REFRESH, auth.refreshToken);
  }

  /**
   * 回填 Steam 凭证到内存对象。
   *
   * 语义：ASSET 有值才覆盖。ASSET 为空时**保留**调用方已有的值——
   * 否则「旧 mafile 迁移」路径会被清空：TokenStore 先用 mafile 构造 SteamAuth，
   * 紧接着调用本方法（此时 ASSET 尚无数据），若无条件覆盖就等于把密钥丢掉。
   */
  async load(tokenUUID: string, auth: SteamAuth): Promise<void> {
    const identity: string | null = await this.assets.queryNamedSecret(this.alias(tokenUUID, FIELD_IDENTITY));
    if (identity !== null && identity.length > 0) {
      auth.identitySecret = identity;
    }
    const revocation: string | null = await this.assets.queryNamedSecret(
      this.alias(tokenUUID, FIELD_REVOCATION));
    if (revocation !== null && revocation.length > 0) {
      auth.revocationCode = revocation;
    }
    const refresh: string = await this.loadChunked(tokenUUID, FIELD_REFRESH);
    if (refresh.length > 0) {
      auth.refreshToken = refresh;
    }
  }

  /** 删除该令牌的全部 Steam 凭证 */
  async remove(tokenUUID: string): Promise<void> {
    await this.assets.removeNamedSecret(this.alias(tokenUUID, FIELD_IDENTITY));
    await this.assets.removeNamedSecret(this.alias(tokenUUID, FIELD_REVOCATION));
    // 分片数量不确定：探测到第一个不存在的分片即停止
    for (let i = 0; i < MAX_REFRESH_CHUNKS; i++) {
      const alias: string = `${this.alias(tokenUUID, FIELD_REFRESH)}_${i}`;
      const existing: string | null = await this.assets.queryNamedSecret(alias);
      if (existing === null) {
        break;
      }
      await this.assets.removeNamedSecret(alias);
    }
  }
}
