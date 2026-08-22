import { bundleManager,common } from '@kit.AbilityKit';
import { base32Encode, otpType, TokenConfig, dialogSystemMaterial } from 'common';
import { util, url } from '@kit.ArkTS';
// [冷启动优化] 文件 I/O 仅在 deferredInit 中使用
import lazy { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppPreference, SettingTopEffectType, SettingBottomTabsType, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES, BUILTIN_DEFAULT_PACK_ID } from 'common';
// [冷启动优化] privacyManager 仅在 deferredInit 的 GetPrivacyManageInfo 中使用
import lazy { privacyManager } from '@kit.StoreKit';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import CommonEventManager from '@ohos.commonEventManager';
import { TokenStore } from 'common';
// [冷启动优化] 权限检查仅在 deferredInit 中使用
import lazy { PermissionManager } from 'common';
// [冷启动优化] 拖拽弹框仅在 onDragEnter 时触发
import lazy { DropFilesDialog } from '../dialogs/DropFilesDialog';
// [冷启动优化] 加密导入弹框仅在文件拖入 .bak 时触发
import lazy { EncryptionPassWordDialog } from '../dialogs/EncryptionPassWordDialog';
// [冷启动优化] 备份恢复仅在文件拖入时触发
import lazy { restoreFromBackup } from 'common';
// [冷启动优化] TokenIconPacks 仅在 deferredInit 中使用，ScanBarCode 仅在扫码时使用
import lazy { TokenIconPacks, ScanBarCode } from 'common';
// [冷启动优化] 云备份管理器仅在 deferredInit 中使用
import lazy { CloudBackupManager } from 'common';
import { AppWindowInfo } from 'common';
// [冷启动优化] AppLockOverlay 导入 @kit.CryptoArchitectureKit + @kit.UserAuthenticationKit，
// bindContentCover 的 Builder 仅在 isAppLockOverlayVisible=true 时评估
import lazy { AppLockOverlay } from './AppLockOverlay';
import { AppStorageV2, ComponentContent, window } from '@kit.ArkUI';
import { ScrollEffectType } from '@kit.UIDesignKit';
// [冷启动优化] Google Auth 解码仅在扫描迁移链接时使用
import lazy { decodeProtobuf } from '../utils/GoogleAuthUtils';
// [冷启动优化] 华为账号管理器仅在 deferredInit 中初始化
import lazy { HuaweiAccountManager } from 'common';
import lazy { IconPackCloudBackup } from 'common';
import { DlpAntiPeepManager } from 'common';
import { AppShell } from '../shell/AppShell';
import { HomeTabs } from '../shell/HomeTabs';
// [冷启动优化] SheetCoordinator("我的"页签 + 8 个 Sheet)仅在用户切换到"我的"Tab 时触发模块评估
import lazy { SheetCoordinator } from '../shell/SheetCoordinator';
import { NFCReadDialog } from '../dialogs/NFCReadDialog';
import { NfcSessionTokens } from '../oath/NfcSessionTokens';
import { NfcOathReader, NfcSupportStatus } from '../oath/NfcOathReader';
import { OathReadResult } from '../oath/OathApplet';

const TAG = 'PrivacySubscribe';

class AddTotpRouteParams {
  initialUri: string;

  constructor(initialUri: string) {
    this.initialUri = initialUri;
  }
}


/** 将SettingTopEffectType映射到ScrollEffectType(自 common/AppPreference 迁入,
 *  枚举值为 UIDesignKit 运行时符号,手表端不可用,仅手机端使用) */
const SCROLL_EFFECT_TYPE_MAP: Map<SettingTopEffectType, ScrollEffectType> = new Map([
  [SettingTopEffectType.COMMON_BLUR, ScrollEffectType.COMMON_BLUR],
  [SettingTopEffectType.GRADUAL_BLUR, ScrollEffectType.GRADUAL_BLUR],
  [SettingTopEffectType.GRADIENT_BLUR, ScrollEffectType.GRADIENT_BLUR],
  [SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR, ScrollEffectType.IMMERSIVE_GRADIENT_BLUR],
]);

let tkStore = TokenStore.getInstance();

@Builder
function TokenAddMenuBuilder(host: Index) {
  Menu() {
    MenuItem({ content: $r('app.string.app_scan_code') })
      .onClick(() => {
        host.start_quick_scan();
      })
      .accessibilityText($r('app.string.app_scan_code'))
    MenuItem({ content: $r('app.string.tab_token_add_key') })
      .onClick(() => {
        host.openTotpAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_key'))
    MenuItem({ content: $r('app.string.tab_token_add_forti_key') })
      .onClick(() => {
        host.openFortiAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_forti_key'))
    MenuItem({ content: $r('app.string.tab_token_add_stream_key') })
      .onClick(() => {
        host.openSteamAddPage();
      })
      .accessibilityText($r('app.string.tab_token_add_stream_key'))
    MenuItem({ content: $r('app.string.menu_add_nfc_read') })
      .onClick(() => {
        host.openNfcReadDialog();
      })
      .accessibilityText($r('app.string.menu_add_nfc_read'))
  }
}

@Entry
@ComponentV2
struct Index {
  @Local CurrentTokens: TokenConfig[] = [];
  @Local token_loading: Boolean = true;
  @Local background_blur_flag: Boolean = false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  @Local tokenListScroller: Scroller = new Scroller();
  @Local settingEntryScroller: Scroller = new Scroller();
  @Local currentHomeTabIndex: number = 0;
  @Local CurrentTokensCount: number = 0;
  @Local scrollEffectVersion: number = 0;
  @Local bottomTabsTypeVersion: number = 0;
  @Local isAppLockOverlayVisible: boolean = false;
  pageInfos: NavPathStack = new NavPathStack();

  /**
   * 获取当前的滚动效果类型
   * 根据用户设置的顶部效果类型映射到对应的ScrollEffectType
   */
  @Computed
  get currentScrollEffectType(): ScrollEffectType {
    // 依赖scrollEffectVersion以触发重新计算
    const _ = this.scrollEffectVersion;
    const topEffectType = AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE) as SettingTopEffectType;
    return SCROLL_EFFECT_TYPE_MAP.get(topEffectType) ?? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  }

  /**
   * 获取当前的底部页签类型
   * 根据用户设置的底部页签类型（悬浮/平铺）驱动 HomeTabs 重建
   */
  @Computed
  get currentBottomTabsType(): SettingBottomTabsType {
    // 依赖bottomTabsTypeVersion以触发重新计算
    const _ = this.bottomTabsTypeVersion;
    return AppPreference.getPreference(PREF_KEYS.APPEARANCE_BOTTOM_TABS_TYPE) as SettingBottomTabsType;
  }

  private appIsInit = false;
  private appIsShow = false;
  private icon_pack_dir = this.appCtx.filesDir + "/icon_packs";
  private user_icon_dir = this.appCtx.filesDir + "/user_icons";
  private DropFilesDialogIsOpen:boolean = false;
  // 存储 setInterval ID 以便在 aboutToDisappear 中清理
  private timestampIntervalId: number = -1;
  // 防止 onPageShow 中重复注册 windowStageEvent 监听器
  private windowStageEventListenerRegistered: boolean = false;

  private readonly eventId = 'usual.event.PRIVACY_STATE_CHANGED';
  // 订阅者信息, 用于保存创建成功的订阅者对象，后续使用其完成订阅及退订的动作
  private subscriber: CommonEventManager.CommonEventSubscriber | undefined = undefined;
  // 事件列表
  private subscribeInfo: CommonEventManager.CommonEventSubscribeInfo = {
    events: [this.eventId]
  };
  //拖拽文件弹框
  private DropFilesDialogController: CustomDialogController | null = new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: DropFilesDialog({}),
    cancel: () => {},
    autoCancel: true,
    openAnimation:({
      delay: 0,
      duration: 200, // 动画时长
      curve: Curve.EaseInOut, // 动画曲线
    }),
    closeAnimation:({
      delay: 0,
      duration: 200, // 动画时长
      curve: Curve.EaseInOut, // 动画曲线
    }),
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'Index', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'Index', "dialog onWillDismiss")
      this.DropFilesDialogIsOpen=false;
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
      }
    },
    alignment: DialogAlignment.Bottom,
    offset: { dx: 0, dy: -20 },
    gridCount: 4,
    customStyle: false,
    cornerRadius: 10,
  })

  private backup_select_uri: string = '';
  private readonly addTokenMenuTargetId: string = 'app_ua_add_token';
  private dialog_nfc_read?: CustomDialogController;

  // [性能打点] hiTraceMeter 用于 DevEco Profiler 冷启动分析，搜索 "H:" 前缀查看各阶段耗时
  aboutToAppear(): void {
    // 异步打点：覆盖整个 aboutToAppear 到首帧数据就绪（token_loading=false）
    hiTraceMeter.startTrace('H:aboutToAppear', 1);

    // 同步打点：6 个 eventHub 监听器注册耗时（预期 <1ms）
    hiTraceMeter.startTrace('H:aboutToAppear.eventHub', 1);
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.on(EVENT_NAMES.KV_STORE_SYNC_COMPLETE, () => {
        AppPreference.setPreference(PREF_KEYS.DB_KV_SYNC_TIME,new Date().toISOString());
      });
      this.appCtx.eventHub.on(EVENT_NAMES.RDB_STORE_SYNC_COMPLETE, () => {});
      this.appCtx.eventHub.on(EVENT_NAMES.DATASYNC_PERMISSIONS_UPDATE, (isAccess: boolean) => {
        if (!isAccess) {
          AppPreference.setPreference(PREF_KEYS.DB_RDS_SYNC_ENABLE, false);
          AppPreference.setPreference(PREF_KEYS.DB_RDS_CLOUD_SYNC_ENABLE, false);
        }
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_QUICK_SCAN, () => {
        this.start_quick_scan();
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_CARD_CONFIG, () => {
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenCardConfigPage, null);
      });
      this.appCtx.eventHub.on(EVENT_NAMES.START_TOKEN_SORT, () => {
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenSortPage, null);
      });
      // NFC 外部令牌变更事件：合并刷新（本地令牌 + 会话级 NFC 令牌）
      this.appCtx.eventHub.on(EVENT_NAMES.NFC_EXTERNAL_TOKENS_CHANGED, () => this.refreshDisplayTokens());
      this.appCtx.eventHub.on(EVENT_NAMES.FILE_DROP, (uri: string) => {
        this.backup_select_uri = uri;
        if (this.backup_select_uri.endsWith('.bak')) {
          this.password_input_dialog?.open();
        } else if (this.backup_select_uri.endsWith('.json')) {
          restoreFromBackup(uri).then((backup) => {
            this.updateTokenConfigs(backup.configs).then(() => {
              tkStore.sortTokens();
            });
          });
        }
        setTimeout(() => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        }, 250)
      });
    }
    hiTraceMeter.finishTrace('H:aboutToAppear.eventHub', 1);

    // 异步打点：TokenStore 初始化（KV 数据库打开 + ASSET 迁移）
    let stepReached = 0;
    hiTraceMeter.startTrace('H:aboutToAppear.initTokenStore', 1);
    tkStore.initTokenStore().then(() => {
      stepReached = 1;
      hiTraceMeter.finishTrace('H:aboutToAppear.initTokenStore', 1);

      // 异步打点：从 TokenStore 读取全部 Token 列表
      hiTraceMeter.startTrace('H:aboutToAppear.getTokens', 1);
      if (this.appCtx.eventHub != undefined) {
        this.appCtx.eventHub.on(EVENT_NAMES.TOKEN_CHANGED, () => this.onTokenChanged());
        this.appCtx.eventHub.on(EVENT_NAMES.TOP_EFFECT_TYPE_CHANGED, () => {
          this.scrollEffectVersion++;
        });
        this.appCtx.eventHub.on(EVENT_NAMES.BOTTOM_TABS_TYPE_CHANGED, () => {
          this.bottomTabsTypeVersion++;
        });
      }
      return tkStore.getTokens();
    }).then((tokens) => {
      stepReached = 2;
      hiTraceMeter.finishTrace('H:aboutToAppear.getTokens', 1);

      this.CurrentTokens = [...tokens, ...NfcSessionTokens.getInstance().getTokens()];
      this.CurrentTokensCount = tokens.length;
      this.token_loading = false;
      this.appIsInit = true;
      // 首帧数据已就绪，结束 aboutToAppear 打点
      hiTraceMeter.finishTrace('H:aboutToAppear', 1);

      setTimeout(() => this.deferredInit(), 0);
    }).catch((err: BusinessError) => {
      // 根据 stepReached 判断失败阶段，仅 finish 已 start 的 trace
      if (stepReached >= 1) {
        hiTraceMeter.finishTrace('H:aboutToAppear.getTokens', 1);
      } else {
        hiTraceMeter.finishTrace('H:aboutToAppear.initTokenStore', 1);
      }
      hiTraceMeter.finishTrace('H:aboutToAppear', 1);
      this.token_loading = false;
      hilog.error(err.code, TAG, `aboutToAppear init failed: ${err.message}`);
    });

    this.timestampIntervalId = setInterval(() => {
      if (this.appCtx != undefined && this.appIsShow)
        if (this.appCtx.eventHub != undefined)
          this.updateTimestamp();
    }, 1000);
  }

  // [冷启动优化] 非首帧必要的初始化操作，由 aboutToAppear 中 setTimeout(0) 延迟调用
  // 包含：华为账号、权限检查、文件 I/O、隐私订阅等，均不阻塞首帧渲染
  // [性能打点] deferredInit 整体耗时 + 华为账号初始化子阶段耗时
  private deferredInit(): void {
    hiTraceMeter.startTrace('H:deferredInit', 1);

    // 异步打点：华为账号初始化（含网络请求，是 deferredInit 中最耗时操作）
    hiTraceMeter.startTrace('H:deferredInit.accountInit', 1);
    HuaweiAccountManager.getInstance().init().then(() => {
      hiTraceMeter.finishTrace('H:deferredInit.accountInit', 1);
      // 账号 UI 状态由 SheetCoordinator 持有，广播事件通知其重新同步
      if (this.appCtx.eventHub != undefined) {
        this.appCtx.eventHub.emit(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED);
      }
      CloudBackupManager.getInstance().checkAndAutoBackup();
    }).catch((err: BusinessError) => {
      hiTraceMeter.finishTrace('H:deferredInit.accountInit', 1);
      hilog.error(err.code, TAG, `deferredInit accountInit failed: ${err.message}`);
    });

    this.subscribeDistributedAccountLogout();
    PermissionManager.getInstance().verifyPermissionsAndPushEvent();
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION).then((bundleInfo) => {
      AppStorage.setOrCreate("BundleInfo", bundleInfo);
    });
    AppStorage.setOrCreate("AppPrivacyManageInfoUrl",
      'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=1537746898868267328');
    AppStorage.setOrCreate("AppUserAgreementUrl",
      'https://yylx.duan.red/user-agreement-zh-cn.html');
    fs.access(this.icon_pack_dir).then((res) => {
      if (!res) {
        fs.mkdir(this.icon_pack_dir);
      } else {
        if (TokenIconPacks.aegis_icon_packs.length === 0) {
          this.refreshIconPack();
        }
      }
    });

    // 图标包云端自动恢复：检查云端是否有更新的备份，如有则静默恢复并合并
    this.checkAndRestoreIconPacks();

    // [冷启动优化] FortiToken 证书文件从同步读取改为异步读取，避免阻塞主线程
    let cer_path = this.appCtx.filesDir + "/fmt.ks"
    fs.access(cer_path, fs.AccessModeType.EXIST).then((exist) => {
      if (!exist) {
        fs.open(cer_path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE).then((cer_file) => {
          this.appCtx.resourceManager.getRawFileContent('ftm.ks').then((arr) => {
            fs.write(cer_file.fd, arr.buffer).then(() => {
              hilog.info(0, 'Index', 'store fmt.ks to cache dir')
            }).catch((err: BusinessError) => {
              hilog.error(err.code, 'Index', `${err.message}`)
            }).finally(() => {
              // 确保文件描述符在写入完成或失败后关闭，防止资源泄漏
              fs.close(cer_file);
            })
          }).catch((err: BusinessError) => {
            hilog.error(err.code, 'Index', `getRawFileContent failed: ${err.message}`)
            // 读取失败时也需要关闭文件描述符
            fs.close(cer_file);
          })
        })
      }
    })
    this.GetPrivacyManageInfo();
    // deferredInit 同步部分结束（异步任务仍在后台执行）
    hiTraceMeter.finishTrace('H:deferredInit', 1);
  }

  //region 导入
  private password_input_dialog: CustomDialogController | null = new CustomDialogController({
    systemMaterial: dialogSystemMaterial(),
    builder: EncryptionPassWordDialog({
      cancel: () => {},
      confirm: (password: string) => {
        restoreFromBackup(this.backup_select_uri, true, password).then((backup) => {
          this.updateTokenConfigs(backup.configs).then(() => {
            tkStore.sortTokens();
          });
        });
      },
    }),
    cancel: () => {},
    autoCancel: true,
    onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
      hilog.info(0, 'Index', "reason=" + JSON.stringify(dismissDialogAction.reason))
      hilog.info(0, 'Index', "dialog onWillDismiss")
      if (dismissDialogAction.reason == DismissReason.PRESS_BACK) {
        dismissDialogAction.dismiss()
      }
      if (dismissDialogAction.reason == DismissReason.TOUCH_OUTSIDE) {
        dismissDialogAction.dismiss()
      }
    },
    alignment: DialogAlignment.Center,
    gridCount: 4,
    customStyle: false,
    cornerRadius: $r('sys.float.ohos_id_corner_radius_panel'),
  })

  async refreshIconPack(): Promise<void> {
    TokenIconPacks.addUserIconPack(this.user_icon_dir);
    try {
      const paths = await fs.listFile(this.icon_pack_dir);
      for (const path of paths) {
        try {
          await TokenIconPacks.addAegisIconPack(this.icon_pack_dir + "/" + path);
        } catch (err) {
          hilog.error(0, 'Index', `Failed to load icon pack ${path}: ${JSON.stringify(err)}`);
        }
      }
    } catch (err) {
      hilog.warn(0, 'Index', `Failed to list icon packs: ${JSON.stringify(err)}`);
    }
    if (!AppPreference.hasEnabledPacksMigrated()) {
      const selected = AppPreference.getLegacySelectedPack();
      if (selected === 0) {
        TokenIconPacks.enabled_packs = [BUILTIN_DEFAULT_PACK_ID];
      } else {
        const index = selected - 1;
        if (index >= 0 && index < TokenIconPacks.aegis_icon_packs.length) {
          const uuid = TokenIconPacks.aegis_icon_packs[index].uuid;
          TokenIconPacks.enabled_packs = uuid ? [uuid] : [BUILTIN_DEFAULT_PACK_ID];
        } else {
          TokenIconPacks.enabled_packs = [BUILTIN_DEFAULT_PACK_ID];
        }
      }
      AppPreference.saveEnabledPacks(TokenIconPacks.enabled_packs);
    } else {
      TokenIconPacks.enabled_packs = AppPreference.loadEnabledPacks();
    }
    this.appCtx.eventHub.emit(EVENT_NAMES.ICON_PACK_CHANGED);
  }

  /**
   * 图标包自动恢复入口，委托给 IconPackCloudBackup.checkAndAutoRestore()
   * 内部通过状态机保证不会与备份/清理操作冲突
   */
  private async checkAndRestoreIconPacks(): Promise<void> {
    try {
      await IconPackCloudBackup.getInstance().checkAndAutoRestore();
    } catch (err) {
      hilog.error(0xFF00, 'Index', `checkAndRestoreIconPacks failed: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 主密码兼容性检查.如果用户开启了弹窗告知用户废弃
   *
   */
  private checkMasterKeyDeprecation(): void {
    const acknowledged = AppPreference.getPreference(PREF_KEYS.MASTER_KEY_DEPRECATION_ACKNOWLEDGED) as boolean;
    if (acknowledged || !AppPreference.hasDeprecatedMasterKeyPrefs()) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.master_key_deprecation_title'),
      message: $r('app.string.master_key_deprecation_message'),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.master_key_deprecation_acknowledge'),
          action: () => {
            AppPreference.cleanupDeprecatedMasterKeyPrefs();
          }
        },
      ],
    });
  }

  onDidBuild(): void {
    this.checkMasterKeyDeprecation();
  }

  // 清理 setInterval，防止资源泄漏
  aboutToDisappear(): void {
    if (this.timestampIntervalId !== -1) {
      clearInterval(this.timestampIntervalId);
    }
  }

  onPageHide(): void {
    this.appIsShow = false;
    hilog.info(0, TAG, "onPageHide");
  }

  updateTimestamp(): void {
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (this.appCtx.eventHub != undefined) {
      this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, false);
    }
  }

  onPageShow(): void {
    this.appIsShow = true;
    // 重置防窥蒙层标志，确保页面进入时能再次响应窥视事件
    DlpAntiPeepManager.getInstance().resetMaskFlag();
    const needShowLock = AppStorage.get<boolean>('app_lock_need_show') ?? false;
    const cardConfigFormId = AppStorage.get<string>('card_config_formId') ?? '';
    if (!needShowLock && cardConfigFormId === '') {
      this.pageInfos.clear();
    }
    if (needShowLock && AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
      this.isAppLockOverlayVisible = true;
    }
    AppStorage.setOrCreate('app_lock_need_show', false);
    const timestamp = Math.floor(systemDateTime.getTime() / 1000);
    if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.TIMESTAMP_CHANGED, timestamp, true);
    //页面打开的时候刷新token
    tkStore.LoadTokenByDataBase().then(() => {
      // 接收同步完成后刷新数据（合并 NFC 外部令牌，保证外部令牌不丢失）
      this.refreshDisplayTokens().then(() => {
        this.token_loading = false;
      });
    });

    let context = this.appCtx as common.UIAbilityContext;
    let windowStage = context.windowStage;
    // 防止每次 onPageShow 重复注册 windowStageEvent 监听器
    if (!this.windowStageEventListenerRegistered && windowStage) {
      windowStage.on("windowStageEvent", (data) => {
        this.background_blur_flag = (
          AppPreference.getPreference(PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE) as boolean &&
          data === window.WindowStageEventType.PAUSED
        );
      })
      this.windowStageEventListenerRegistered = true;
    }

    if (AppPreference.getPreference(PREF_KEYS.WANT_QUICK_SCAN)) {
      if (this.appCtx.eventHub!= undefined) this.appCtx.eventHub.emit(EVENT_NAMES.START_QUICK_SCAN);
      AppPreference.setPreference(PREF_KEYS.WANT_QUICK_SCAN, false);
    }

    if (cardConfigFormId !== '') {
      const allPaths = this.pageInfos.getAllPathName();
      if (!allPaths.includes(ROUTE_NAMES.TokenCardConfigPage)) {
        this.pageInfos.pushPathByName(ROUTE_NAMES.TokenCardConfigPage, null);
      }
    }
  }

  /**
   * 合并刷新：本地令牌 + 会话级 NFC 外部令牌。
   * 外部令牌不持久化，所有刷新路径（TOKEN_CHANGED / NFC_EXTERNAL_TOKENS_CHANGED /
   * onPageShow / 删除）统一经此方法，保证外部令牌在本地令牌增删后不丢失、不重复。
   */
  async refreshDisplayTokens(): Promise<void> {
    this.CurrentTokens = [...await tkStore.getTokens(), ...NfcSessionTokens.getInstance().getTokens()];
  }

  async onTokenChanged(): Promise<void> {
    await this.refreshDisplayTokens();
  }

  async updateTokenConfig(conf: TokenConfig, toast: boolean = true): Promise<boolean> {
    try {
      if (!conf.TokenIconPath) {
        const iconPath = TokenIconPacks.getIconByIssuer(conf.TokenIssuer);
        if (iconPath !== '') {
          conf.TokenIconPath = iconPath;
        }
      }
      const isNew = !this.CurrentTokens.some(t => t.TokenUUID === conf.TokenUUID);
      await tkStore.updateToken(conf);
      if (isNew) {
        await this.refreshDisplayTokens();
      }
      if (toast) {
        showSnackBar($r('app.string.toast_token_update', conf.TokenIssuer, conf.TokenName), SnackBarNotifyType.SUCCESS);
      }
      return true;
    } catch (e) {
      hilog.error(0, 'Index', `updateTokenConfig failed: ${e}`);
      return false;
    }
  }

  private async addTestTokens(): Promise<boolean> {
    const tokens: TokenConfig[] = [];
    for (let i = 0; i < 100; i++) {
      const secret = base32Encode(util.generateRandomBinaryUUID()).substring(0, 26);
      const issuer = `Test-${util.generateRandomUUID().substring(0, 8)}`;
      const name = `User-${util.generateRandomUUID().substring(0, 8)}`;
      tokens.push(new TokenConfig(secret, otpType.TOTP, issuer, name));
    }
    const success = await this.updateTokenConfigs(tokens);
    hilog.info(0xFF00, 'DeveloperOptions',
      `Added ${tokens.length} test tokens, result=${success}, storeCount=${(await tkStore.getTokens()).length}`);
    return success;
  }

  async updateTokenConfigs(tokens: Array<TokenConfig>): Promise<boolean> {
    let failCount = 0;
    let hasNew = false;
    const existingUuids = new Set(this.CurrentTokens.map(t => t.TokenUUID));
    for (let i = 0; i < tokens.length; i++) {
      if (tokens[i].TokenUUID === undefined) {
        tokens[i].TokenUUID = util.generateRandomUUID();
      }
      if (!existingUuids.has(tokens[i].TokenUUID)) {
        hasNew = true;
      }
      try {
        await tkStore.updateToken(tokens[i]);
      } catch (e) {
        hilog.error(0, 'Index', `updateTokenConfigs[${i}] failed: ${e}`);
        failCount++;
      }
    }
    if (hasNew) {
      await this.refreshDisplayTokens();
    }
    if (failCount === 0) {
      showSnackBar($r('app.string.toast_multi_token_update', tokens.length), SnackBarNotifyType.SUCCESS);
      return true;
    } else {
      hilog.error(0, 'Index', `updateTokenConfigs: ${failCount}/${tokens.length} failed`);
      showSnackBar($r('app.string.toast_multi_token_update', tokens.length - failCount), SnackBarNotifyType.WARNING);
      return false;
    }
  }

  private subscribeDistributedAccountLogout(): void {
    const subscribeInfo: CommonEventManager.CommonEventSubscribeInfo = {
      events: [
        CommonEventManager.Support.COMMON_EVENT_DISTRIBUTED_ACCOUNT_LOGOUT,
      ],
    };
    CommonEventManager.createSubscriber(subscribeInfo).then((subscriber) => {
      CommonEventManager.subscribe(subscriber, (err) => {
        if (!err) {
          HuaweiAccountManager.getInstance().logout().then(() => {
            // 账号 UI 状态由 SheetCoordinator 持有，广播事件通知其重新同步
            if (this.appCtx.eventHub != undefined) {
              this.appCtx.eventHub.emit(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED);
            }
            AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
            AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
          });
        }
      });
    });
  }

  private openAddTokenMenu(): void {
    const uiContext = this.getUIContext();
    const promptAction = uiContext.getPromptAction();
    const contentNode = new ComponentContent(uiContext, wrapBuilder(TokenAddMenuBuilder), this);
    try {
      promptAction.openMenu(contentNode, { id: this.addTokenMenuTargetId }, {});
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(err.code, 'Index', `openAddTokenMenu failed: ${err.message}`);
    }
  }

  start_quick_scan() {
    ScanBarCode().then((code) => {
      if (code.startsWith('otpauth-migration://offline?data=')) {
        const data = new url.URLParams(url.URL.parseURL(code).search).get('data');
        decodeProtobuf(decodeURIComponent(data ?? '')).then((confs) => {
          this.updateTokenConfigs(confs);
        });
      } else if (code.startsWith('otpauth://')) {
        this.pageInfos.pushPathByName(ROUTE_NAMES.AddTotpTokenPage, new AddTotpRouteParams(code));
      }
    }).catch((err: BusinessError) => {
      // 1000500002: 用户取消扫码, 静默处理
      if (err.code === 1000500002) {
        return;
      }
      hilog.error(0x0000, 'Index', `start_quick_scan failed: ${err.code} ${err.message}`);
      showSnackBar($r('app.string.toast_scan_failed'), SnackBarNotifyType.ERROR);
    });
  }

  openTotpAddPage(): void {
    this.pageInfos.pushPathByName(ROUTE_NAMES.AddTotpTokenPage, new AddTotpRouteParams(''));
  }

  openFortiAddPage(): void {
    this.pageInfos.pushPathByName(ROUTE_NAMES.AddFortiTokenPage, new AddTotpRouteParams(''));
  }

  openSteamAddPage(): void {
    this.pageInfos.pushPathByName(ROUTE_NAMES.AddSteamTokenPage, new AddTotpRouteParams(''));
  }

  openNfcReadDialog(): void {
    // NFC 能力检查不通过：按失败原因分流提示文案并返回，不打开弹窗
    const nfcStatus = NfcOathReader.getInstance().isNfcSupported();
    if (nfcStatus !== NfcSupportStatus.OK) {
      if (nfcStatus === NfcSupportStatus.SWITCH_OFF) {
        showSnackBar($r('app.string.nfc_switch_off'), SnackBarNotifyType.WARNING);
      } else {
        showSnackBar($r('app.string.nfc_unsupported'), SnackBarNotifyType.WARNING);
      }
      return;
    }
    this.dialog_nfc_read = new CustomDialogController({
      builder: NFCReadDialog({
        onSuccess: (result: OathReadResult) => {
          const count = NfcSessionTokens.getInstance().applyResult(result);
          showSnackBar($r('app.string.nfc_read_success', count), SnackBarNotifyType.SUCCESS);
          this.dialog_nfc_read?.close();
        }
      }),
      cancel: () => {},
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      offset: { dx: 0, dy: -20 },
      gridCount: 4,
      customStyle: false,
      cornerRadius: 10,
    });
    this.dialog_nfc_read.open();
  }

  // 准备接入标准化隐私托管
  async GetPrivacyManageInfo(): Promise<void> {
    try {
      let appPrivacyManageInfo: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type: " + appPrivacyManageInfo["type"]);
      let privacyLinkInfoArray : privacyManager.AppPrivacyLink[] = appPrivacyManageInfo.privacyInfo;
      hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo size = " + privacyLinkInfoArray.length);
      for (let i = 0; i < privacyLinkInfoArray.length; i++) {
        hilog.info(0, 'TAG', "Succeeded in getting AppPrivacyManageInfo type = " + privacyLinkInfoArray[i]["type"] + ", version = " + privacyLinkInfoArray[i]["versionCode"] + ", url = " + privacyLinkInfoArray[i]["url"]);

      }
      if (privacyLinkInfoArray.length>0) {
        AppStorage.setOrCreate("AppPrivacyManageInfoUrl", privacyLinkInfoArray[0]["url"]);
      }
      if (privacyLinkInfoArray.length>1) {
        AppStorage.setOrCreate("AppUserAgreementUrl", privacyLinkInfoArray[1]["url"]);
      }

    } catch (error) {
      hilog.error(error.code, 'TAG', "GetAppPrivacyManageInfoPublic exception code: " + error.code + ", exception message: " + error.message);
    }

    hilog.info(0, TAG, "subscribe");
    // 创建订阅者
    CommonEventManager.createSubscriber(this.subscribeInfo).then((commonEventSubscriber) => {
      hilog.info(0, TAG, "createSubscriber");
      this.subscriber = commonEventSubscriber;

      // 订阅公共事件
      try {
        CommonEventManager.subscribe(this.subscriber, (err, data) => {
          if (err) {
            hilog.error(err?.code, TAG, `subscribe failed, code is ${err?.code}, message is ${err?.message}`);
            return;
          }

          let result = JSON.parse(data?.data ?? '{}')?.resultType as number;
          if (result === 1) {
            //向用户申请权限
            //PermissionManager.reqPermissionsFromUser(this.appCtx);
          }
        });
      } catch (error) {
        hilog.error(error.code , TAG, "init createSubscriber failed, exception code: " + error.code + ", exception message: " + error.message);
      }
    });
  }

  // [@LocalBuilder] 作为 @BuilderParam 传给 AppShell 时保持 this 指向 Index,
  // 普通 @Builder 会被调用方(AppShell)重绑定 this,导致 this.window 等状态读取为 undefined 引发崩溃
  @LocalBuilder
  AppLockOverlayBuilder() {
    AppLockOverlay({
      onUnlock: () => {
        this.isAppLockOverlayVisible = false;
        // 认证通过后恢复隐私窗口设置到用户偏好
        const privacyMode = AppPreference.getPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE) as boolean;
        this.window.WindowClass?.setWindowPrivacyMode(privacyMode);
      }
    })
  }

  /**
   * "我的"页签内容(Task 3.1):由 SheetCoordinator 承载全部设置入口与 Sheet
   * [@LocalBuilder] 作为 @BuilderParam 传给 HomeTabs 时保持 this 指向 Index
   */
  @LocalBuilder
  SettingEntryContentBuilder() {
    SheetCoordinator({
      tokens: this.CurrentTokens,
      scrollEffectType: this.currentScrollEffectType,
      scroller: this.settingEntryScroller,
      backupReload: async (conf) => {
        await this.updateTokenConfigs(conf);
        tkStore.sortTokens();
      },
      addTestTokens: () => this.addTestTokens()
    })
  }

  /**
   * 首页内容(Task 3.1):断点 lanes + 双页签,由 HomeTabs 承载。
   * 通过箭头函数传给 AppShell，使 @Builder 保持 Index 的 this 与状态刷新能力。
   */
  @Builder
  HomeContentBuilder() {
    HomeTabs({
      tokens: this.CurrentTokens,
      window: this.window,
      bottomTabsType: this.currentBottomTabsType,
      currentTabIndex: this.currentHomeTabIndex,
      pageInfos: this.pageInfos,
      updateTokenConfig: (conf: TokenConfig, toast?: boolean) => this.updateTokenConfig(conf, toast),
      updateTokenConfigs: (tokens: Array<TokenConfig>) => this.updateTokenConfigs(tokens),
      tokenListScroller: this.tokenListScroller,
      settingEntryScroller: this.settingEntryScroller,
      onTabChange: (index: number) => {
        this.currentHomeTabIndex = index;
      },
      settingEntryContent: this.SettingEntryContentBuilder,
    })
  }

  build() {
    Stack() {
      AppShell({
        pageInfos: this.pageInfos,
        isLoading: this.token_loading as boolean,
        blurFlag: this.background_blur_flag as boolean,
        applockVisible: this.isAppLockOverlayVisible,
        scrollEffectType: this.currentScrollEffectType,
        currentHomeTabIndex: this.currentHomeTabIndex,
        tokenListScroller: this.tokenListScroller,
        settingEntryScroller: this.settingEntryScroller,
        openAddTokenMenu: () => this.openAddTokenMenu(),
        addTokenMenuTargetId: this.addTokenMenuTargetId,
        onDropFile: () => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        },
        onDragEnterFile: () => {
          if (!this.DropFilesDialogIsOpen) {
            this.DropFilesDialogIsOpen = true;
            this.DropFilesDialogController?.open();
          }
        },
        onDragLeaveFile: () => {
          this.DropFilesDialogIsOpen = false;
          this.DropFilesDialogController?.close();
        },
        saveToken: (conf: TokenConfig) => this.updateTokenConfig(conf, true),
        appLockContent: this.AppLockOverlayBuilder,
        homeContent: () => {
          this.HomeContentBuilder();
        },
      })
    }
  }
}
