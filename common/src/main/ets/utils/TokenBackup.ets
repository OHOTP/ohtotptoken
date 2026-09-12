import { readFileContent, writeFileContentCheckHashEqual } from "./FileUtils";
import { TokenConfig } from "./TokenConfig";
import { TokenBatchProgressCallback, TokenBatchStage, reportTokenBatchProgress } from './TokenBatchProgress';
import { TokenGroup, TokenGroupStore } from './TokenGroupStore';
import { BackupTextIo } from './StoragePorts';
import { base32Decode, base32Encode, intArrayToString, stringToIntArray } from "./TokenUtils";
import { decryptFile, encryptFile } from "./CryptoUtils";

const TOKEN_BACKUP_MAGIC = 0x55aaeebb;

/** BackupTextIo 生产实现：走 FileUtils（fs + 哈希防重复写入）。 */
class FileUtilsBackupTextIo implements BackupTextIo {
  async readText(uri: string): Promise<string> {
    return readFileContent(uri);
  }

  async writeText(uri: string, content: string): Promise<void> {
    await writeFileContentCheckHashEqual(uri, content);
  }
}

export class TokenBackup {
  magic: number;
  version: number;
  configs: Array<TokenConfig>;
  groups: TokenGroup[];

  constructor(version: number, configs: Array<TokenConfig>) {
    this.magic = TOKEN_BACKUP_MAGIC;
    this.version = version;
    this.configs = configs;
    this.groups = [...TokenGroupStore.getInstance().state.groups];
  }
}

export async function saveBackupToFile(file_uri: string, backup: TokenBackup, do_encrypt: boolean = false,
  password: string = '', io: BackupTextIo = new FileUtilsBackupTextIo()): Promise<void> {
  const backup_json = JSON.stringify(backup);
  const backup_raw = do_encrypt ? await encryptFile(backup_json, password) : stringToIntArray(backup_json);
  const b32_encoded = base32Encode(backup_raw);
  await io.writeText(file_uri, b32_encoded);
}

export async function restoreFromBackup(file_uri: string, is_encrypt: boolean = false, password: string = '',
  onProgress?: TokenBatchProgressCallback, io: BackupTextIo = new FileUtilsBackupTextIo()): Promise<TokenBackup> {
  reportTokenBatchProgress(onProgress, TokenBatchStage.READING);
  const file_content = await io.readText(file_uri);
  reportTokenBatchProgress(onProgress, TokenBatchStage.DECODING);
  const b32_decoded = base32Decode(file_content);
  if (is_encrypt) {
    reportTokenBatchProgress(onProgress, TokenBatchStage.DECRYPTING);
  }
  const backup_string = is_encrypt ? await decryptFile(b32_decoded, password) : intArrayToString(b32_decoded.buffer as ArrayBuffer);
  reportTokenBatchProgress(onProgress, TokenBatchStage.PARSING);
  const backup: TokenBackup = JSON.parse(backup_string) as TokenBackup;
  if (backup.magic !== TOKEN_BACKUP_MAGIC || !Array.isArray(backup.configs)) {
    throw new Error('invalid backup file');
  }
  await TokenGroupStore.getInstance().merge(backup.groups);
  return backup;
}
