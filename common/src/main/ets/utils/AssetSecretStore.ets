import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SecretStore } from './StoragePorts';
import { utf8ByteLength } from './SteamAuth';

const TAG = 'AssetSecretStore';
const DOMAIN = 0xFF00;

const ALIAS_PREFIX = 'opt_token_secret_';
const ASSET_LABEL = 'opt_token_secret';
const ASSET_NOT_FOUND = 24000002;
const MAX_SECRET_BYTES = 900;

function stringToUint8Array(str: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(str);
}

function uint8ArrayToString(arr: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
  return decoder.decodeToString(arr, { stream: false });
}

/**
 * Asset Store Kit 关键资产存储封装.
 *
 * 将 TokenSecret 存储到 HarmonyOS ASSET（TEE 硬件保护 + AES256-GCM），
 * 替代加密 KV 数据库中的软件加密存储。
 *
 * 设计要点：
 * - ALIAS 格式: `{ALIAS_PREFIX}{TokenUUID}`，每条 Secret 一个 ASSET 条目
 * - SyncType.TRUSTED_DEVICE: 支持换机克隆时自动同步到新设备
 * - Accessibility.DEVICE_FIRST_UNLOCKED: 开机首次解锁后即可访问
 * - ConflictResolution.OVERWRITE: upsert 语义，写入时若已存在则覆盖
 * - Secret 大小限制: UTF-8 编码后 ≤ 900 字节（ASSET 单条上限 1KB，预留元数据空间）
 * - DATA_LABEL_NORMAL_1: 写入时附加统一标签，供未来属性级批量查询使用
 *   注意：存量 ASSET 条目无此标签，未来采用标签查询前需执行一次性 re-upsert 迁移
 */
export class AssetSecretStore implements SecretStore {
  private static instance: AssetSecretStore;

  private constructor() {}

  public static getInstance(): AssetSecretStore {
    if (!AssetSecretStore.instance) {
      AssetSecretStore.instance = new AssetSecretStore();
    }
    return AssetSecretStore.instance;
  }

  /** 检查 Secret 的 UTF-8 字节长度是否在 ASSET 存储限制内 */
  public isSecretSizeValid(secret: string): boolean {
    if (secret.length === 0) {
      return false;
    }
    return utf8ByteLength(secret) <= MAX_SECRET_BYTES;
  }

  /** 构建 ASSET ALIAS: {ALIAS_PREFIX}{tokenUUID} */
  private buildAlias(tokenUUID: string): Uint8Array {
    return stringToUint8Array(`${ALIAS_PREFIX}${tokenUUID}`);
  }

  /**
   * 写入或更新 Secret 到 ASSET.
   *
   * 使用 ConflictResolution.OVERWRITE 实现 upsert 语义，
   * 无论条目是否已存在都能正常写入。
   *
   * @returns true=写入成功, false=Secret 过大或 ASSET 写入失败（降级到 KV）
   */
  async upsertSecret(tokenUUID: string, secret: string): Promise<boolean> {
    if (!this.isSecretSizeValid(secret)) {
      hilog.warn(DOMAIN, TAG, `upsertSecret: secret size exceeds limit for ${tokenUUID}, skipping ASSET`);
      return false;
    }

    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, stringToUint8Array(secret));
    attr.set(asset.Tag.ALIAS, this.buildAlias(tokenUUID));
    attr.set(asset.Tag.DATA_LABEL_NORMAL_1, stringToUint8Array(ASSET_LABEL));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.SYNC_TYPE, asset.SyncType.TRUSTED_DEVICE);
    attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);

    try {
      await asset.add(attr);
      hilog.info(DOMAIN, TAG, `upsertSecret: saved ${tokenUUID}`);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `upsertSecret: failed for ${tokenUUID}, code=${err.code}, msg=${err.message}`);
      return false;
    }
  }

  /**
   * 从 ASSET 查询单条 Secret.
   *
   * @returns Secret 明文字符串, null=未找到或查询失败
   */
  async querySecret(tokenUUID: string): Promise<string | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.buildAlias(tokenUUID));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length > 0) {
        const secretBytes = results[0].get(asset.Tag.SECRET) as Uint8Array;
        return uint8ArrayToString(secretBytes);
      }
      return null;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `querySecret: failed for ${tokenUUID}, code=${err.code}, msg=${err.message}`);
      return null;
    }
  }

  /**
   * 从 ASSET 删除单条 Secret.
   *
   * 条目不存在时静默忽略（错误码 24000002），不视为异常。
   */
  async removeSecret(tokenUUID: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.buildAlias(tokenUUID));

    try {
      await asset.remove(query);
      hilog.info(DOMAIN, TAG, `removeSecret: removed ${tokenUUID}`);
     } catch (e) {
      const err = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND) {
        hilog.info(DOMAIN, TAG, `removeSecret: already absent ${tokenUUID}`);
      } else {
        hilog.error(DOMAIN, TAG, `removeSecret: failed for ${tokenUUID}, code=${err.code}, msg=${err.message}`);
      }
    }
  }

  // ---------------------------------------------------------------------
  // 通用别名接口：供 Steam 等多字段凭证复用同一套 ASSET 语义
  // ---------------------------------------------------------------------

  /** 写入/更新任意别名（别名长度需 ≤ 256 字节，ASSET 限制） */
  async upsertNamedSecret(alias: string, secret: string): Promise<boolean> {
    if (!this.isSecretSizeValid(secret)) {
      hilog.warn(DOMAIN, TAG, `upsertNamedSecret: size exceeds limit for ${alias}`);
      return false;
    }
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.SECRET, stringToUint8Array(secret));
    attr.set(asset.Tag.ALIAS, stringToUint8Array(alias));
    attr.set(asset.Tag.DATA_LABEL_NORMAL_1, stringToUint8Array(ASSET_LABEL));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attr.set(asset.Tag.SYNC_TYPE, asset.SyncType.TRUSTED_DEVICE);
    attr.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      await asset.add(attr);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, `upsertNamedSecret: failed for ${alias}, code=${err.code}, msg=${err.message}`);
      return false;
    }
  }

  /** 查询任意别名；未找到返回 null */
  async queryNamedSecret(alias: string): Promise<string | null> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToUint8Array(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length > 0) {
        return uint8ArrayToString(results[0].get(asset.Tag.SECRET) as Uint8Array);
      }
      return null;
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND) {
        // 分片探测会主动查询「下一个分片是否存在」，未找到属正常路径
        hilog.info(DOMAIN, TAG, `queryNamedSecret: absent ${alias}`);
      } else {
        hilog.error(DOMAIN, TAG, `queryNamedSecret: failed for ${alias}, code=${err.code}, msg=${err.message}`);
      }
      return null;
    }
  }

  /** 删除任意别名；不存在时静默忽略 */
  async removeNamedSecret(alias: string): Promise<void> {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToUint8Array(alias));
    try {
      await asset.remove(query);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code !== ASSET_NOT_FOUND) {
        hilog.error(DOMAIN, TAG, `removeNamedSecret: failed for ${alias}, code=${err.code}, msg=${err.message}`);
      }
    }
  }

  /**
   * 批量查询 ASSET 中的 Secret（逐条串行查询）.   *
   * 【限制说明】ASSET 按标签批量查询（DATA_LABEL_NORMAL_1 + RETURN_TYPE=ALL）
   * 会返回错误码 24000017 "该子功能不支持"，即 ASSET API 虽然支持批量查询属性
   * （RETURN_TYPE=ATTRIBUTES），但不支持批量查询关键资产明文（SECRET）。
   * RETURN_LIMIT/RETURN_OFFSET 分页同样仅对属性查询有效。
   * 这是 TEE 硬件解密的限制——无法批量解密多条 SECRET。（华为官方安全限制）
   *
   * 因此只能逐条通过 ALIAS 精确查询单条 SECRET（TEE 逐条解密）。
   * 写入时仍保留 DATA_LABEL_NORMAL_1 标签，供未来可能的属性级批量查询使用。
   */
  async batchQuerySecrets(tokenUUIDs: string[]): Promise<Map<string, string>> {
    const result = new Map<string, string>();

    for (const uuid of tokenUUIDs) {
      const secret = await this.querySecret(uuid);
      if (secret !== null) {
        result.set(uuid, secret);
      }
    }

    hilog.info(DOMAIN, TAG, `batchQuerySecrets: found ${result.size}/${tokenUUIDs.length}`);
    return result;
  }
}
