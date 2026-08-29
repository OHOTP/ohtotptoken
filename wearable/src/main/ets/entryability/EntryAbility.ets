import {
  common,
  AbilityConstant,
  UIAbility, Want, Configuration,
  ConfigurationConstant,
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { AppPreference, AppWindowInfo, TokenStore, WearEngineServer } from 'common';
import { wearEngine } from '@kit.WearEngine';

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

      // 后台初始化: 权限 → TokenStore(ASSET 回填) → BLE 接收服务
      // 不阻塞首帧渲染; BleTokenServer.start() 自带 5 次×1s 重试兜底权限竞态
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
   * 手表端初始化链路: TokenStore 初始化 → Wear Engine P2P 消息接收注册.
   *
   * 分布式 KV 同步方案已废弃(数据库安全等级 S4 无法同步到 SL1 手表),
   * 令牌改由 Wear Engine 应用间消息通信下发(手机 WatchSyncPage → P2P → TokenStore → ASSET).
   */
  private async initDataSync(): Promise<void> {
    try {
      // 必须先初始化 TokenStore(kvMgr/ASSET 回填), 消息入库依赖其就绪
      await TokenStore.getInstance().initTokenStore();
      // 获取已连接对端(手机)设备并注册消息接收
      const deviceClient: wearEngine.DeviceClient = wearEngine.getDeviceClient(this.context);
      const connected = await deviceClient.getConnectedDevices();
      const randomIds: Array<string> = connected.map((device: wearEngine.Device) => device.randomId);
      await WearEngineServer.getInstance().registerReceiver(randomIds);
    } catch (err) {
      hilog.error(0x0000, TAG, `initDataSync failed: ${JSON.stringify(err)}`);
    }
  }
}
