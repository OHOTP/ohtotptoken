import { describe, it, expect } from '@ohos/hypium';
import { common } from '@kit.AbilityKit';
import { DeviceMigrationKv, performBackup, performRestore } from 'common';

/**
 * 换机备份/恢复编排测试（Phase 2 DeviceMigrationKv 端口注入）。
 *
 * 核心决策：恢复仅在成功（count > 0）时清理非加密 KV 中转数据，
 * 失败路径保留唯一数据副本；错误向上传播由 BackupExtension 感知。
 */

class FakeMigrationKv implements DeviceMigrationKv {
  initCalls: number = 0;
  copyToNoEncryptResult: number = 0;
  copyToEncryptResult: number = 0;
  failCopyToNoEncrypt: boolean = false;
  failCopyToEncrypt: boolean = false;
  clearCalls: number = 0;

  initForBackup(_ctx: common.Context): Promise<void> {
    this.initCalls++;
    return Promise.resolve();
  }

  copyToNoEncrypt(): Promise<number> {
    if (this.failCopyToNoEncrypt) {
      return Promise.reject(new Error('backup copy failed'));
    }
    return Promise.resolve(this.copyToNoEncryptResult);
  }

  copyToEncrypt(): Promise<number> {
    if (this.failCopyToEncrypt) {
      return Promise.reject(new Error('restore copy failed'));
    }
    return Promise.resolve(this.copyToEncryptResult);
  }

  clearNoEncrypt(): Promise<void> {
    this.clearCalls++;
    return Promise.resolve();
  }
}

// 编排层不对 ctx 解引用（生产语义：透传给 KvManager 初始化），假上下文即可。
const FAKE_CTX = new Object() as common.Context;

export default function backupRestoreHelperTest() {
  describe('backupRestoreHelperTest', () => {
    it('perform_backup_returns_count_and_initializes', 0, async () => {
      const kv = new FakeMigrationKv();
      kv.copyToNoEncryptResult = 42;

      const count = await performBackup(FAKE_CTX, kv);
      expect(count).assertEqual(42);
      expect(kv.initCalls).assertEqual(1);
      // 备份后不清空非加密 KV：系统还要传输该文件
      expect(kv.clearCalls).assertEqual(0);
    });

    it('perform_backup_error_propagates', 0, async () => {
      const kv = new FakeMigrationKv();
      kv.failCopyToNoEncrypt = true;

      let threw = false;
      try {
        await performBackup(FAKE_CTX, kv);
      } catch (e) {
        threw = (e as Error).message === 'backup copy failed';
      }
      expect(threw).assertTrue();
    });

    it('perform_restore_clears_staging_only_on_success', 0, async () => {
      const kv = new FakeMigrationKv();
      kv.copyToEncryptResult = 7;

      const count = await performRestore(FAKE_CTX, kv);
      expect(count).assertEqual(7);
      expect(kv.clearCalls).assertEqual(1);

      // count == 0：保留唯一数据副本，不清空
      const empty = new FakeMigrationKv();
      empty.copyToEncryptResult = 0;
      const zero = await performRestore(FAKE_CTX, empty);
      expect(zero).assertEqual(0);
      expect(empty.clearCalls).assertEqual(0);
    });

    it('perform_restore_error_propagates_without_clear', 0, async () => {
      const kv = new FakeMigrationKv();
      kv.failCopyToEncrypt = true;

      let threw = false;
      try {
        await performRestore(FAKE_CTX, kv);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
      expect(kv.clearCalls).assertEqual(0);
    });
  });
}
