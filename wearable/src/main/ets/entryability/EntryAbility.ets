import {
  common,
  AbilityConstant,
  UIAbility, Want, Configuration,
  ConfigurationConstant,
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { AppPreference, AppWindowInfo, PermissionManager, TokenStore } from 'common';
import { startReceiveChannels } from '../utils/ReceiveChannels';

const TAG: string = 'WearableEntry';

export default class EntryAbility extends UIAbility {
  private uiContext?: UIContext;
  private onWindowSizeChange: (windowSize: window.Size) => void = (windowSize: window.Size) => {
    let win: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
    win.WidthBreakpoint = this.uiContext!.getWindowWidthBreakpoint();
    win.HeightBreakpoint = this.uiContext!.getWindowHeightBreakpoint();
    win.Size = windowSize;
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate("appContext", this.context);
    hilog.info(0x0000, TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    AppPreference.saveSettings();
    hilog.info(0x0000, TAG, 'Ability onDestroy');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    try {
      let win: AppWindowInfo = AppStorageV2.connect(AppWindowInfo, () => new AppWindowInfo())!;
      win.ColorMode = this.context.config.colorMode ?? -1;
      win.Context = this.context;

      await AppPreference.loadSettings();

      // 后台初始化: TokenStore(ASSET 回填) → P2P 接收注册与 BLE GATT Server 并行就绪
      // 不阻塞首帧渲染; 失败仅记日志(initDataSync 内部 catch)
      this.initDataSync();

      windowStage.loadContent('pages/ArcTokenListPage', (err) => {
        if (err.code) {
          hilog.error(0x0000, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
          return;
        }

        let windowClass: window.Window = windowStage.getMainWindowSync();
        this.uiContext = windowClass.getUIContext();
        win.uiContext = this.uiContext;
        win.WindowClass = windowClass;

        windowClass.setWindowLayoutFullScreen(true);

        const avoidAreaTop = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const avoidAreaBottom = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        win.AvoidTopHeight = this.uiContext!.px2vp(avoidAreaBottom.topRect.height);
        win.AvoidBottomHeight = this.uiContext!.px2vp(avoidAreaTop.bottomRect.height);

        windowClass.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            win.AvoidBottomHeight = this.uiContext!.px2vp(data.area.bottomRect.height);
          }
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            win.AvoidTopHeight = this.uiContext!.px2vp(data.area.topRect.height);
          }
        });

        win.Size = windowClass.getWindowProperties().windowRect;
        win.WidthBreakpoint = this.uiContext!.getWindowWidthBreakpoint();
        win.HeightBreakpoint = this.uiContext!.getWindowHeightBreakpoint();
        windowClass.on('windowSizeChange', this.onWindowSizeChange);

        hilog.info(0x0000, TAG, 'Succeeded in loading the content.');
      });
    } catch (err) {
      hilog.error(0x0000, TAG, `onWindowStageCreate: ${err}`);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    let win: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
    win.ColorMode = newConfig.colorMode ?? -1;
  }

  /**
   * 手表端初始化链路: TokenStore 初始化 → （已授权时）静默拉起接收通道.
   *
   * 分布式 KV 同步方案已废弃(数据库安全等级 S4 无法同步到 SL1 手表),
   * 令牌改由手机端手动下发: Wear Engine P2P(WatchSyncPage)与 BLE GATT(BleWatchSyncPage)
   * 两条通道并行常驻、互不阻塞, 入库均走 WearEngineTransfer 共享实现.
   *
   * 合规约束(审核 7.17/7.19): 启动阶段**不得**申请权限或弹框。
   * 这里只做「检查是否已授权」——已授权则静默启动，未授权则保持关闭，
   * 由用户在页面上主动点击「从手机接收令牌」时再申请并启动。
   */
  private async initDataSync(): Promise<void> {
    // 两通道入库均依赖 TokenStore 就绪(kvMgr/ASSET 回填), 必须先行初始化
    try {
      await TokenStore.getInstance().initTokenStore();
    } catch (err) {
      hilog.error(0x0000, TAG, `initTokenStore failed: ${JSON.stringify(err)}`);
      return;
    }
    try {
      const granted: boolean =
        await PermissionManager.getInstance().checkPermissionGrantBool('ohos.permission.ACCESS_BLUETOOTH');
      if (granted) {
        await startReceiveChannels(this.context);
      }
    } catch (err) {
      // 查询权限失败按未授权处理：不申请、不启动，等用户主动触发
      hilog.warn(0x0000, TAG, `silent receive start skipped: ${JSON.stringify(err)}`);
    }
  }
}
