import { bundleManager, common } from '@kit.AbilityKit';
import { distributedKVStore } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreference, EVENT_NAMES, PREF_KEYS } from './AppPreference';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { TokenConfig } from './TokenConfig';
import { TokenBatchProgressCallback } from './TokenBatchProgress';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from "@kit.CoreFileKit";
import { KvBatchEntry, LegacyTokenKv, TokenKvStore, TransactionalKv } from './StoragePorts';
import { commitTokenBatchInChunks, migrateLegacyTokenEntries } from './TokenKvBatch';

/** SingleKVStore 事务原语适配 TokenKvBatch 的 TransactionalKv 端口。 */
class KvStoreTransactionAdapter implements TransactionalKv {
  private store: distributedKVStore.SingleKVStore;

  constructor(store: distributedKVStore.SingleKVStore) {
    this.store = store;
  }

  async startTransaction(): Promise<void> {
    await this.store.startTransaction();
  }

  async putBatch(entries: KvBatchEntry[]): Promise<void> {
    const distEntries: distributedKVStore.Entry[] = entries.map((entry: KvBatchEntry): distributedKVStore.Entry => {
      return { key: entry.key, value: { type: distributedKVStore.ValueType.STRING, value: entry.value } };
    });
    await this.store.putBatch(distEntries);
  }

  async deleteBatch(keys: string[]): Promise<void> {
    await this.store.deleteBatch(keys);
  }

  async commit(): Promise<void> {
    await this.store.commit();
  }

  async rollback(): Promise<void> {
    await this.store.rollback();
  }
}

/** SingleKVStore 读写适配 TokenKvBatch 的旧版本迁移端口。 */
class KvStoreLegacyAdapter implements LegacyTokenKv {
  private store: distributedKVStore.SingleKVStore;

  constructor(store: distributedKVStore.SingleKVStore) {
    this.store = store;
  }

  async getRawEntries(prefix: string): Promise<KvBatchEntry[]> {
    const entries = await this.store.getEntries(prefix);
    return entries.map((entry: distributedKVStore.Entry): KvBatchEntry => {
      return { key: entry.key, value: entry.value.value as string };
    });
  }

  async getString(key: string): Promise<string | null> {
    try {
      const data = await this.store.get(key);
      return data ? data as string : null;
    } catch (e) {
      return null;
    }
  }

  async setString(key: string, value: string): Promise<void> {
    await this.store.put(key, value);
  }

  async deleteValue(key: string): Promise<void> {
    await this.store.delete(key);
  }
}

export class KvManager implements TokenKvStore {
  //单版本分布式键值数据库
  private _kvMgr: distributedKVStore.KVManager | undefined = undefined;
  private _kvStore: distributedKVStore.SingleKVStore | undefined = undefined;
  private _kvStoreNoE: distributedKVStore.SingleKVStore | undefined = undefined;

  private static instance: KvManager;
  // SingleKVStore 事务属于连接，普通写入也必须排队，避免被另一批事务回滚。
  private writeQueue: Promise<void> = Promise.resolve();

  private enqueueWrite(operation: () => Promise<void>): Promise<void> {
    const pending = this.writeQueue.then(operation);
    this.writeQueue = pending.catch(() => {});
    return pending;
  }

  /** 原子提交令牌变更；分块/事务编排委托 TokenKvBatch.commitTokenBatchInChunks。 */
  async saveTokenBatch(prefix: string, tokens: TokenConfig[], deletedUuids: string[] = [],
    onProgress?: TokenBatchProgressCallback): Promise<void> {
    const entries: KvBatchEntry[] = tokens.map((token: TokenConfig): KvBatchEntry => {
      return { key: `${prefix}${token.TokenUUID}`, value: JSON.stringify(token) };
    });
    const keys = deletedUuids.map(uuid => `${prefix}${uuid}`);
    if (entries.length === 0 && keys.length === 0) {
      return;
    }
    return this.enqueueWrite(async () => {
      const store = this._kvStore;
      if (!store) {
        throw new Error('Token batch failed: KV store not initialized');
      }
      await commitTokenBatchInChunks(new KvStoreTransactionAdapter(store), entries, keys, onProgress);
    });
  }

  private constructor() {

  }

  //#region 基础部分

  public static getInstance(): KvManager {
    if (!KvManager.instance) {
      KvManager.instance = new KvManager();
    }
    return KvManager.instance;
  }

  /** TokenKvStore 端口的初始化入口（主进程：读取 AppStorage 上下文并建库）。 */
  init(): Promise<void> {
    return this.initKvManager();
  }

  /**
   * 初始化KV存储（内部方法）.
   * 接受通用Context类型，同时支持UIAbilityContext和BackupExtensionContext.
   * BackupExtension运行在独立进程，需要通过该接口传入ExtensionContext完成初始化.
   */
  private async initKvStore(ctx: common.Context): Promise<distributedKVStore.SingleKVStore[]> {
    if (!this._kvMgr) {
      let bundleName = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).name;
      const kvManagerConfig: distributedKVStore.KVManagerConfig = {
        context: ctx,
        bundleName: bundleName,
      }
      this._kvMgr = distributedKVStore.createKVManager(kvManagerConfig);
    }
    let dbs: distributedKVStore.SingleKVStore[] = [];
    const options: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: true,
      backup: false,
      autoSync: true,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
      securityLevel: distributedKVStore.SecurityLevel.S4,
    };
    const noEncryptoptions: distributedKVStore.Options = {
      createIfMissing: true,
      encrypt: false,
      backup: false,
      autoSync: true,
      kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
      securityLevel: distributedKVStore.SecurityLevel.S4,
    };
    dbs[0] = await this._kvMgr.getKVStore('main_store', options);
    dbs[1] = await this._kvMgr.getKVStore('main_store_noE', noEncryptoptions);
    return dbs;
  }

  /**
   * 主进程初始化KV管理器.
   * 从AppStorage获取UIAbilityContext，初始化加密/非加密KV数据库并订阅同步事件.
   */
  async initKvManager(): Promise<void> {
    let ctx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    if (this._kvStore) {
      return;
    }
    await this.initKvStore(ctx).then((store) => {
      this._kvStore = store[0];
      this._kvStoreNoE = store[1];
      this._kvStore.on('syncComplete', (data: [string, number][]) => {
        hilog.info(0, 'KvManager', `syncComplete ${data}`);
        ctx.eventHub.emit(EVENT_NAMES.KV_STORE_SYNC_COMPLETE);
      });
      this._kvStore.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_LOCAL, (data: distributedKVStore.ChangeNotification) => {
        hilog.info(0, 'KvManager', `dataChange callback call data: ${data}`);
      });
    }).catch((reason: BusinessError) => {
      hilog.error(reason.code, 'KvManager', reason.message);
    });
  }

  /**
   * BackupExtension进程初始化KV管理器.
   * BackupExtension运行在独立进程中，单例为空，需要通过ExtensionContext重新初始化.
   * 仅初始化KV存储，不订阅同步事件（Extension进程中无需订阅）.
   * 初始化失败时抛出异常，确保调用方感知失败而非静默跳过.
   *
   * @param ctx - BackupExtensionContext，由BackupExtensionAbility的this.context获取
   * @throws 初始化失败时抛出Error
   */
  async initKvManagerForBackup(ctx: common.Context): Promise<void> {
    if (this._kvStore && this._kvStoreNoE) {
      return;
    }
    try {
      const store = await this.initKvStore(ctx);
      this._kvStore = store[0];
      this._kvStoreNoE = store[1];
    } catch (reason) {
      let e = reason as BusinessError;
      hilog.error(e.code, 'KvManager', `initKvManagerForBackup failed: ${e.message}`);
      throw new Error(`initKvManagerForBackup failed: ${e.message}`);
    }
  }
  /**
   * 备份整个kv数据库到目标文件.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  BuckupToFile(backupFile:string)
  {
    try {
      if (fs.accessSync(backupFile)) {//如果文件存在需要删除然后重新备份
        let files = [backupFile];
        try {
          this._kvStore?.deleteBackup(files).then((data) => {
            hilog.info(0,"BuckUP",`Succeed in deleting Backup. Data:filename is ${data[0]},result is ${data[1]}.`);
          }).catch((err: BusinessError) => {
            hilog.error(err.code,"BuckUP",`Fail to delete Backup. Code:${err.code},message:${err.message}`);
          })
        } catch (e) {
          let error = e as BusinessError;
          hilog.error(error.code,"BuckUP",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
        }
      }
      this._kvStore?.backup(backupFile, (err) => {
        if (err) {
          hilog.error(err.code,"BuckUP",`Fail to backup data.code:${err.code},message:${err.message}`);
        } else {
          hilog.info(0,"BuckUP",'Succeeded in backupping data.');
        }
      });
    } catch (e) {
      let error = e as BusinessError;
      hilog.error(error.code,"BuckUP",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
    }
  }
  /**
   * 从备份文件中还原整个数据库.
   *
   * @param { backupFile } 目标文件路径 需要保证目标路径是有权限的
   */
  RestoreByFile(backupFile:string)
  {
    try {
      if (fs.accessSync(backupFile)) { 
        this._kvStore?.restore(backupFile, (err) => {
          if (err) {
            hilog.error(err.code,"Restore",`Fail to restore data. Code:${err.code},message:${err.message}`);
          } else {
            hilog.info(0,"Restore",'Succeeded in restoring data.');
          }
        });
      }

    } catch (e) {
      let error = e as BusinessError;
      hilog.error(error.code,"Restore",`An unexpected error occurred. Code:${error.code},message:${error.message}`);
    }
  }

  async setValue<T>(key: string, value: T): Promise<void> {
    const json = JSON.stringify(value);
    return this.enqueueWrite(async () => {
      if (!this._kvStore) {
        throw new Error('KV store not initialized');
      }
      await this._kvStore.put(key, json);
    });
  }


  async getValue<T>(key: string): Promise<T | null> {
    if (this._kvStore) {
      return this._kvStore.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: T | null = null;
        if (data) {
          value = JSON.parse(data as string) as T;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }

  // 使用getEntries模拟一个可以兼容的数组 这样可以规避多设备覆盖的问题
  // 旧版本键迁移委托 TokenKvBatch.migrateLegacyTokenEntries。
  async getTokenArray(prefix: string): Promise<TokenConfig[]> {
    let token_array: TokenConfig[] = [];
    if (this._kvStore) {
      try {
        // load from old version
        await migrateLegacyTokenEntries(new KvStoreLegacyAdapter(this._kvStore), prefix);

        const entries = await this._kvStore.getEntries(prefix);
        entries.forEach((item) => {
          const json = item.value.value as string;
          if (json.length > 0) {
            token_array.push(JSON.parse(item.value.value as string) as TokenConfig);
          }
        });
      } catch (e) {
        let error = e as BusinessError;
        hilog.error(error.code, 'KvManager', `duplicated calls should be ok. code is ${error.code}, message is ${error.message}`);
      }
    }
    return token_array;
  }

  async setString(key: string, value: string): Promise<void> {
    return this.enqueueWrite(async () => {
      if (!this._kvStore) {
        throw new Error('KV store not initialized');
      }
      await this._kvStore.put(key, value);
    });
  }

  async getString(key: string): Promise<string|null> {
    if (this._kvStore) {
      return this._kvStore.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: string | null = null;
        if (data) {
          value = data as string;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }

  async setStringNoE(key: string, value: string): Promise<void> {
    if (this._kvStoreNoE) {
      this._kvStoreNoE.put(key, value, (err) => {
        if (err != undefined) {
          hilog.error(err.code, 'KvManager', `Failed to put.code is ${err.code},message is ${err.message}`);
          return;
        }
        hilog.info(0, 'KvManager', "Succeeded in putting");
      });
    }
  }

  async getStringNoE(key: string): Promise<string|null> {
    if (this._kvStoreNoE) {
      return this._kvStoreNoE.get(key).then((data: boolean | string | number | Uint8Array) => {
        let value: string | null = null;
        if (data) {
          value = data as string;
        }
        return value;
      }).catch(() => {
        return null;
      });
    }
    return null;
  }
  async deleteValue(key: string): Promise<void> {
    return this.enqueueWrite(async () => {
      if (!this._kvStore) {
        throw new Error('KV store not initialized');
      }
      await this._kvStore.delete(key);
    });
  }

  /**
   * 换机备份：将加密KV数据库所有条目直接拷贝到非加密KV数据库.
   *
   * 背景：加密KV数据库的密钥存储在设备TEE中，换机后新设备无法解密旧设备的加密KV文件。
   * 方案：在BackupExtension.onBackup回调中调用此方法，将加密KV数据拷贝到非加密KV。
   *       非加密KV数据库虽然encrypt=false，但其核心数据在HarmonyOS KV存储框架的
   *       系统保护内存中处理，安全等级（S4）高于应用层JSON文件（files/目录）。
   *       系统通过BackupExtension自动传输非加密KV数据库文件到新设备。
   *
   * 流程：onBackup → 清空非加密KV → 加密KV getEntries → 非加密KV putBatch → 系统传输
   *
   * 注意：先清空非加密KV再写入，避免旧备份残留数据导致已删除的token在新设备上复活.
   * 操作失败时抛出Error，确保BackupExtension感知失败而非静默传输空数据.
   */
  async DataSyncToNoEncryptDatabase(): Promise<number> {
    if (this._kvStore && this._kvStoreNoE) {
      try {
        await this.ClearNoEncryptDatabase();
        const allEntries = await this._kvStore.getEntries('^');
        if (allEntries && allEntries.length > 0) {
          await this._kvStoreNoE.putBatch(allEntries);
          return allEntries.length;
        }
        hilog.info(0, 'KvManager', 'DataSyncToNoEncryptDatabase: encrypted KV is empty, nothing to backup.');
        return 0;
      } catch (err) {
        let e = err as BusinessError;
        hilog.error(e.code, 'KvManager', `DataSyncToNoEncryptDatabase failed: ${e.message}`);
        throw new Error(`DataSyncToNoEncryptDatabase failed: ${e.message}`);
      }
    }
    throw new Error('DataSyncToNoEncryptDatabase failed: KV stores not initialized.');
  }

  /**
   * 换机恢复：将非加密KV数据库所有条目直接拷贝回加密KV数据库.
   *
   * 背景：新设备通过系统换机克隆接收到旧设备的非加密KV数据库文件。
   * 方案：在BackupExtension.onRestore回调中调用此方法，将非加密KV数据写回加密KV。
   *       恢复完成后加密KV由新设备TEE管理加密密钥，数据安全得到保障。
   *
   * 流程：onRestore → 非加密KV getEntries → 加密KV putBatch → 新设备加密KV生效
   */
  async DataSyncToEncryptDatabase(): Promise<number> {
    if (this._kvStore && this._kvStoreNoE) {
      try {
        const allEntries = await this._kvStoreNoE.getEntries('^');
        if (allEntries && allEntries.length > 0) {
          await this.enqueueWrite(async () => {
            await this._kvStore?.putBatch(allEntries);
          });
          return allEntries.length;
        }
        hilog.info(0, 'KvManager', 'DataSyncToEncryptDatabase: non-encrypted KV is empty, nothing to restore.');
        return 0;
      } catch (err) {
        let e = err as BusinessError;
        hilog.error(e.code, 'KvManager', `DataSyncToEncryptDatabase failed: ${e.message}`);
        throw new Error(`DataSyncToEncryptDatabase failed: ${e.message}`);
      }
    }
    throw new Error('DataSyncToEncryptDatabase failed: KV stores not initialized.');
  }

  /**
   * 清空非加密KV数据库中的所有条目.
   * 恢复完成后或备份完成后调用，清理非加密KV中的明文数据，减少数据暴露面.
   * 使用deleteBatch批量删除，性能远优于逐条删除.
   */
  async ClearNoEncryptDatabase(): Promise<void> {
    if (this._kvStoreNoE) {
      try {
        const allEntries = await this._kvStoreNoE.getEntries('^');
        if (allEntries && allEntries.length > 0) {
          const keys: string[] = allEntries.map((entry: distributedKVStore.Entry) => entry.key);
          await this._kvStoreNoE.deleteBatch(keys);
          hilog.info(0, 'KvManager', `ClearNoEncryptDatabase: cleared ${keys.length} entries.`);
        }
      } catch (err) {
        let e = err as BusinessError;
        hilog.error(e.code, 'KvManager', `ClearNoEncryptDatabase failed: ${e.message}`);
      }
    }
  }

  //#endregion
  //手动同步
  async DataSync(): Promise<void> {
    if (AppPreference.getPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE)) {
      try {
        let bundleInfo = AppStorage.get<bundleManager.BundleInfo>("BundleInfo");
        let dmInstance = distributedDeviceManager.createDeviceManager(bundleInfo?.name);
        let deviceInfoList: Array<distributedDeviceManager.DeviceBasicInfo> = dmInstance.getAvailableDeviceListSync();
        if (deviceInfoList.length > 0) {
          let deviceNetWorkIDList:string[] = [];
          for (let i = 0; i < deviceInfoList.length; i++) {
            deviceNetWorkIDList[i] = deviceInfoList[i].networkId as string;
          }
          // deviceInfoList.forEach(dev => {
          //   //目前仅同步
          //   // -14: PHONE。
          //   // -17: PAD。
          //   // -2607: 2in1。
          //   if (dev.deviceType === "PHONE" ||dev.deviceType === "PAD"||dev.deviceType === "2in1") {
          //     if (dev.networkId!=null) {
          //       deviceNetWorkIDList.push(dev.networkId as string );
          //     }
          //   }
          // });
          if (deviceNetWorkIDList.length > 0) {
            let formattedDate: string = Date.now().toString();
            await this.setString("LastSyncTime", formattedDate);
            const query = new distributedKVStore.Query();
            query.prefixKey("_token_uuid_");
            this._kvStore?.sync(deviceNetWorkIDList, query, distributedKVStore.SyncMode.PUSH_PULL, 1000*10);
            this._kvStoreNoE?.sync(deviceNetWorkIDList, query, distributedKVStore.SyncMode.PUSH_PULL, 1000*10);
          }
        }
      } catch (err) {
        let e: BusinessError = err as BusinessError;
        hilog.error(e.code, 'KvManager', 'getAvailableDeviceListSync errCode:' + e.code + ', errMessage:' + e.message);
      }

    }
  }
}