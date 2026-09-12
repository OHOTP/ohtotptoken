import { fileIo as fs } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { TokenConfig } from './TokenConfig';
import { TokenBatchProgressCallback } from './TokenBatchProgress';

/**
 * 分组目录 KV 后端接口（历史名，Phase 1 引入；Phase 2 并入本文件端口族）。
 * TokenGroupStore 与 TokenKvStore 共享此标称祖先：
 * TokenStore 加载时用同一后端驱动 TokenGroupStore，测试注入一个实现即可覆盖两者。
 */
export interface TokenGroupKvBackend {
  getValue<T>(key: string): Promise<T | null>;
  setValue<T>(key: string, value: T): Promise<void>;
}

/**
 * Phase 2 存储与密钥解耦端口（docs/TEST_PLAN.md 第 4 节）。
 *
 * 四个核心端口家族：
 * - {@link KeyValueStore} / {@link TokenKvStore}：键值与令牌主存储（生产 KvManager/PreferenceManager）
 * - {@link SecretStore} / {@link NamedSecretStore}：TEE 密钥读写（生产 AssetSecretStore）
 * - {@link CryptoEngine}：密码学引擎（生产 cryptoFramework，LocalUnit 不可用）
 * - {@link FsGateway}：文件系统网关（生产 fileIo/cloudSync，LocalUnit 不可用）
 *
 * 业务层（TokenStore/CloudBackupManager/CryptoUtils 等）只依赖端口，
 * 测试注入内存/确定性假实现，真机行为由生产适配器保证。
 *
 * 注：UTF-8 字节长度工具使用 SteamAuth.utf8ByteLength（避免 common/Index 的
 * star-export 命名冲突），本文件不再重复导出。
 */

/**
 * 通用键值存储端口。
 * 生产实现：KvManager（加密 KV）、PreferenceManager（preferences）。
 */
export interface KeyValueStore {
  getValue<T>(key: string): Promise<T | null>;
  setValue<T>(key: string, value: T): Promise<void>;
  deleteValue(key: string): Promise<void>;
}

/** 批量条目：值统一为 JSON 字符串（与加密 KV 的存储形态一致）。 */
export interface KvBatchEntry {
  key: string;
  value: string;
}

/**
 * 令牌主存储端口（分组目录后端 + 令牌数组/事务批量）。
 * 生产实现为 KvManager；TokenStore 仅依赖本端口。
 */
export interface TokenKvStore extends TokenGroupKvBackend {
  /** 初始化底层存储（生产 KvManager.initKvManager，测试为 no-op） */
  init(): Promise<void>;
  getTokenArray(prefix: string): Promise<TokenConfig[]>;
  saveTokenBatch(prefix: string, tokens: TokenConfig[], deletedUuids?: string[],
    onProgress?: TokenBatchProgressCallback): Promise<void>;
}

/** 分布式 KV 事务原语端口（供分块提交/回滚编排使用）。 */
export interface TransactionalKv {
  startTransaction(): Promise<void>;
  putBatch(entries: KvBatchEntry[]): Promise<void>;
  deleteBatch(keys: string[]): Promise<void>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

/** 旧版本令牌键迁移所需的最小 KV 读写端口。 */
export interface LegacyTokenKv {
  getRawEntries(prefix: string): Promise<KvBatchEntry[]>;
  getString(key: string): Promise<string | null>;
  setString(key: string, value: string): Promise<void>;
  deleteValue(key: string): Promise<void>;
}

/**
 * 任意别名密钥存储端口（ASSET 语义）。
 * Steam 分片凭证（SteamSecretStore）依赖本端口而非具体 AssetSecretStore。
 */
export interface NamedSecretStore {
  upsertNamedSecret(alias: string, secret: string): Promise<boolean>;
  queryNamedSecret(alias: string): Promise<string | null>;
  removeNamedSecret(alias: string): Promise<void>;
}

/**
 * 令牌密钥存储端口（生产实现为 AssetSecretStore / TEE 硬件保护）。
 * TokenStore 的迁移三重验证、降级判断只依赖本端口。
 */
export interface SecretStore extends NamedSecretStore {
  /** Secret 的 UTF-8 字节长度是否在存储限制内（≤900 字节） */
  isSecretSizeValid(secret: string): boolean;
  upsertSecret(tokenUUID: string, secret: string): Promise<boolean>;
  querySecret(tokenUUID: string): Promise<string | null>;
  removeSecret(tokenUUID: string): Promise<void>;
  batchQuerySecrets(tokenUUIDs: string[]): Promise<Map<string, string>>;
}

/** GCM 加封结果：密文与认证标签分离返回。 */
export class CryptoSealedBytes {
  ciphertext: Uint8Array = new Uint8Array(0);
  tag: Uint8Array = new Uint8Array(0);
}

/**
 * 密码学引擎端口：屏蔽 cryptoFramework（LocalUnit 下静默失效）。
 * CryptoUtils 的格式/协议逻辑（魔数、salt/iv 布局、legacy 兼容分支）只依赖本端口，
 * 数值正确性（AES/PBKDF2/GCM 向量）由真机 ohosTest 与生产实现保证。
 */
export interface CryptoEngine {
  randomBytes(length: number): Uint8Array;
  utf8Encode(text: string): Uint8Array;
  utf8Decode(data: Uint8Array): string;
  /** PBKDF2-SHA256 派生对称密钥字节 */
  pbkdf2Derive(password: string, salt: Uint8Array, iterations: number, keySize: number): Promise<Uint8Array>;
  sha256(data: Uint8Array): Promise<Uint8Array>;
  /** AES-CBC-PKCS7 加密；key 为原始密钥字节（AES-128） */
  aesCbcEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array>;
  /** AES-CBC-PKCS7 解密；填充非法时抛异常 */
  aesCbcDecrypt(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array>;
  /** AES-256-GCM 加密，返回密文与 16 字节认证标签 */
  aesGcmSeal(plain: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array): Promise<CryptoSealedBytes>;
  /** AES-256-GCM 解密；认证失败抛异常 */
  aesGcmOpen(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array, aad: Uint8Array, tag: Uint8Array): Promise<Uint8Array>;
}

/** 文件状态（location: 0=本地 2=仅云端）。 */
export class FsStatInfo {
  size: number = 0;
  location: number = 0;
  isDirectory: boolean = false;
}

/**
 * 文件系统网关端口：屏蔽 @kit.CoreFileKit 的 fileIo/cloudSync。
 * 覆盖云备份编排所需的最小面（stat/list/read/write/mkdir/unlink/copy）。
 */
export interface FsGateway {
  stat(path: string): Promise<FsStatInfo>;
  listFiles(dir: string): Promise<string[]>;
  readTextFile(path: string): Promise<string>;
  writeTextFile(path: string, content: string): Promise<void>;
  writeBinaryFile(path: string, data: Uint8Array): Promise<void>;
  makeDir(path: string): Promise<void>;
  /** 删除空目录（fs.rmdir 语义） */
  removeDir(path: string): Promise<void>;
  deleteFile(path: string): Promise<void>;
  copyFile(src: string, dest: string): Promise<void>;
}

/** 文本文件读写端口（本地备份管线用；生产实现走 FileUtils）。 */
export interface BackupTextIo {
  readText(uri: string): Promise<string>;
  writeText(uri: string, content: string): Promise<void>;
}

/** {@link FsGateway} 的生产实现：包装 @kit.CoreFileKit fileIo。 */
export class FileIoFsGateway implements FsGateway {
  async stat(path: string): Promise<FsStatInfo> {
    const raw = await fs.stat(path);
    const info = new FsStatInfo();
    info.size = raw.size;
    info.location = raw.location;
    info.isDirectory = raw.isDirectory();
    return info;
  }

  async listFiles(dir: string): Promise<string[]> {
    return fs.listFileSync(dir);
  }

  async readTextFile(path: string): Promise<string> {
    const info = await this.stat(path);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const arrayBuffer = new ArrayBuffer(info.size);
      const readLen = fs.readSync(file.fd, arrayBuffer);
      return buffer.from(new Uint8Array(arrayBuffer.slice(0, readLen))).toString('utf-8');
    } finally {
      fs.closeSync(file);
    }
  }

  async writeTextFile(path: string, content: string): Promise<void> {
    await this.writeBinaryFile(path, new Uint8Array(buffer.from(content, 'utf-8').buffer));
  }

  async writeBinaryFile(path: string, data: Uint8Array): Promise<void> {
    const file = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, data);
    } finally {
      fs.closeSync(file);
    }
  }

  async makeDir(path: string): Promise<void> {
    await fs.mkdir(path);
  }

  async removeDir(path: string): Promise<void> {
    await fs.rmdir(path);
  }

  async deleteFile(path: string): Promise<void> {
    await fs.unlink(path);
  }

  async copyFile(src: string, dest: string): Promise<void> {
    await fs.copyFile(src, dest);
  }
}
