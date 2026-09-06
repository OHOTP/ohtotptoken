import {
  common,
  AbilityConstant,
  UIAbility, Want, Configuration,
  ConfigurationConstant,
} from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { AppPreference, AppWindowInfo, TokenStore, WearEngineServer, BleTokenServer } from 'common';
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
   * 手表端初始化链路: TokenStore 初始化 → P2P 接收注册与 BLE GATT Server 并行就绪.
   *
   * 分布式 KV 同步方案已废弃(数据库安全等级 S4 无法同步到 SL1 手表),
   * 令牌改由手机端手动下发: Wear Engine P2P(WatchSyncPage)与 BLE GATT(BleWatchSyncPage)
   * 两条通道并行常驻、互不阻塞, 入库均走 WearEngineTransfer 共享实现.
   */
  private async initDataSync(): Promise<void> {
    // 两通道入库均依赖 TokenStore 就绪(kvMgr/ASSET 回填), 必须先行初始化
    try {
      await TokenStore.getInstance().initTokenStore();
    } catch (err) {
      hilog.error(0x0000, TAG, `initTokenStore failed: ${JSON.stringify(err)}`);
      return;
    }
    // P2P 与 BLE 并行启动, 各自独立 try/catch: 任一通道失败(权限/蓝牙未就绪)不阻塞另一通道
    this.startP2pReceive();
    this.startBleReceive();
  }

  /** P2P 通道: 获取已连接对端(手机)并注册消息接收, 失败仅记日志 */
  private async startP2pReceive(): Promise<void> {
    try {
      const deviceClient: wearEngine.DeviceClient = wearEngine.getDeviceClient(this.context);
      const connected = await deviceClient.getConnectedDevices();
      const randomIds: Array<string> = connected.map((device: wearEngine.Device) => device.randomId);
      await WearEngineServer.getInstance().registerReceiver(randomIds);
    } catch (err) {
      hilog.error(0x0000, TAG, `startP2pReceive failed: ${JSON.stringify(err)}`);
    }
  }

  /** BLE 通道: 启动 GATT Server 与广播(内部含 5 次 × 1s 延时重试), 失败仅记日志 */
  private async startBleReceive(): Promise<void> {
    try {
      await BleTokenServer.getInstance().start();
    } catch (err) {
      hilog.error(0x0000, TAG, `startBleReceive failed: ${JSON.stringify(err)}`);
    }
  }
}
