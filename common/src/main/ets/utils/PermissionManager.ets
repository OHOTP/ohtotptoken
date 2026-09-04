import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl, bundleManager, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { EVENT_NAMES } from './AppPreference';
import { hilog } from '@kit.PerformanceAnalysisKit';

//权限管理
export class PermissionManager {
  private static instance: PermissionManager;

  public static getInstance(): PermissionManager {
    if (!PermissionManager.instance) {
      PermissionManager.instance = new PermissionManager();
    }
    return PermissionManager.instance;
  }

  private static permissions: Array<Permissions> =
    ['ohos.permission.DISTRIBUTED_DATASYNC', 'ohos.permission.STORE_PERSISTENT_DATA'];
    // 注意: ACCESS_BLUETOOTH 不加入本名单 —— 本名单会被 DataSyncSheet 的
    // reqPermissionsFromUser 整体申请, 蓝牙权限应由手表同步页按需单独申请
    // (WearEngineClient.requestBluetoothPermission / checkPermissionGrantBool).

  public async verifyPermissionGrant(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;

    // 获取应用程序的accessTokenID
    let tokenId: number = 0;
    try {
      let bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(err.code, 'PermissionManager', `Failed to get bundle info for self. Code is ${err.code}, message is ${err.message}`);
    }

    // 校验应用是否被授予权限
    try {
      grantStatus = await atManager.verifyAccessToken(tokenId, permission);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(err.code, 'PermissionManager', `Failed to check access token. Code is ${err.code}, message is ${err.message}`);
    }

    return grantStatus;
  }

  public async checkPermissionGrant(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;

    // 获取应用程序的accessTokenID
    let tokenId: number = 0;
    try {
      let bundleInfo: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(err.code, 'PermissionManager', `Failed to get bundle info for self. Code is ${err.code}, message is ${err.message}`);
    }

    // 校验应用是否被授予权限
    try {
      grantStatus = await atManager.checkAccessToken(tokenId, permission);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.error(err.code, 'PermissionManager', `Failed to check access token. Code is ${err.code}, message is ${err.message}`);
    }

    return grantStatus;
  }

  private async checkPermissions(): Promise<void> {
    let grantStatus: abilityAccessCtrl.GrantStatus = await this.checkPermissionGrant(PermissionManager.permissions[0]);

    if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      // 已经授权，可以继续访问目标操作
      // 设置相关状态 这样其他模块可以知道OK不OK
      PermissionManager.permissions.forEach(element => {
        AppStorage.setOrCreate(element, true)
      });

    } else {
      // 拒绝授权
      PermissionManager.permissions.forEach(element => {
        AppStorage.setOrCreate(element, false)
      });
    }
  }

  public async checkPermissionsBool(): Promise<boolean> {
    let grantStatus: abilityAccessCtrl.GrantStatus = await this.checkPermissionGrant(PermissionManager.permissions[0]);

    if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      // 已经授权，可以继续访问目标操作
      return true;

    } else {
      // 拒绝授权
      return false;
    }
  }

  /**
   * 按权限名检查是否已授权(布尔).
   *
   * 注意: checkPermissionsBool/verifyPermissionsBool 只检查 permissions[0],
   * 新增的权限(如 ACCESS_BLUETOOTH)必须用本方法按名单逐个检查.
   */
  public async checkPermissionGrantBool(permission: Permissions): Promise<boolean> {
    let grantStatus: abilityAccessCtrl.GrantStatus = await this.checkPermissionGrant(permission);
    return grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  public async verifyPermissionsBool(): Promise<boolean> {
    let grantStatus: abilityAccessCtrl.GrantStatus = await this.verifyPermissionGrant(PermissionManager.permissions[0]);

    if (grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      // 已经授权，可以继续访问目标操作
      return true;

    } else {
      // 拒绝授权
      return false;
    }
  }

  // 使用UIExtensionAbility：将common.UIAbilityContext 替换为common.UIExtensionContext
  public async reqPermissionsFromUser(context: common.UIAbilityContext): Promise<void> {
    let atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    //requestPermissionsFromUser会判断权限的授权状态来决定是否唤起弹窗
    atManager.requestPermissionsFromUser(context, PermissionManager.permissions).then((data) => {
      let grantStatus: Array<number> = data.authResults;
      let length: number = grantStatus.length;
      for (let i = 0; i < length; i++) {
        if (grantStatus[i] === 0) {
          // 用户授权，可以继续访问目标操作
          this.verifyPermissionsAndPushEvent();
        } else {
          // 用户拒绝授权，提示用户必须授权才能访问当前页面的功能，并引导用户到系统设置中打开相应的权限
          atManager.requestPermissionOnSetting(context, [PermissionManager.permissions[i]])
            .then((data: Array<abilityAccessCtrl.GrantStatus>) => {
              hilog.info(0, 'PermissionManager', 'data:' + JSON.stringify(data));
              this.verifyPermissionsAndPushEvent();
            })
            .catch((err: BusinessError) => {
              hilog.error(err.code, 'PermissionManager', 'data:' + JSON.stringify(err));
            });
        }
      }
      // 授权成功
    })
  }

  //检查权限授权状态并且推送便跟事件
  public async verifyPermissionsAndPushEvent(): Promise<void> {
    let appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
    let isAccess = await this.verifyPermissionsBool()
    //向前台告知授权信息
    appCtx.eventHub.emit(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, isAccess)
  }
}