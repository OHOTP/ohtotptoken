import {
  common,
  AbilityConstant,
  UIAbility, Want, Configuration,
  ApplicationStateChangeCallback,
  ConfigurationConstant,
} from '@kit.AbilityKit';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import { AppStorageV2, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppPreference, SettingColorMode, PREF_KEYS, EVENT_NAMES, AppWindowInfo, setDialogSystemMaterialProvider } from 'common';
import { relationalStore  } from '@kit.ArkData';
import { DeviceInfoHelper } from 'common';
import { MaterialPolicy } from '../utils/MaterialPolicy';
import { MaterialTheme } from '../components/MaterialTheme';
import { DlpAntiPeepManager } from 'common';
import { registerHdsSnackBar } from '../utils/HdsSnackBarUtils';
import { formInfo } from '@kit.FormKit';

//单版本分布式键值数据库
let rdbStore: relationalStore.RdbStore | null = null;

export default class EntryAbility extends UIAbility {
  private uiContext?: UIContext;
  private onWindowSizeChange: (windowSize: window.Size) => void = (windowSize: window.Size) => {
    let win: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
    let widthBp: WidthBreakpoint = this.uiContext!.getWindowWidthBreakpoint();
    let heightBp: HeightBreakpoint = this.uiContext!.getWindowHeightBreakpoint();
    win.WidthBreakpoint = widthBp;
    win.HeightBreakpoint = heightBp;
    win.Size = windowSize;
  };

  private selectPage: string = '';

  private handleCardAction(want: Want): void {
    hilog.info(0x0000, 'EntryAbility', `handleCardAction parameters: ${JSON.stringify(want?.parameters)}`);

    let formId = '';
    let formName = '';
    let isCardConfig = false;

    const sysFormId = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    if (sysFormId) {
      formId = String(sysFormId);
      formName = String(want.parameters?.[formInfo.FormParam.NAME_KEY] ?? '');
      hilog.info(0x0000, 'EntryAbility', `card router event, formId: ${formId}, formName: ${formName}`);
    }

    if (want?.parameters?.params !== undefined) {
      try {
        const outerParams: Record<string, string> = JSON.parse(String(want.parameters.params));
        hilog.info(0x0000, 'EntryAbility', `card custom params: ${JSON.stringify(outerParams)}`);
        let innerParams: Record<string, string> = outerParams;
        if (outerParams['params']) {
          try {
            innerParams = JSON.parse(outerParams['params']);
          } catch (_) {}
        }
        if (innerParams['action'] === 'card_config') {
          isCardConfig = true;
          if (!formId) formId = innerParams['formId'] ?? '';
          if (!formName) formName = innerParams['formName'] ?? '';
        }
      } catch (e) {
        hilog.error(0, 'EntryAbility', `parse card params error: ${(e as BusinessError).message}`);
      }
    }

    if (isCardConfig || formId) {
      AppStorage.setOrCreate('card_config_formId', formId);
      AppStorage.setOrCreate('card_config_formName', formName);
      hilog.info(0x0000, 'EntryAbility', `emit START_CARD_CONFIG, formId: ${formId}`);
      if (this.context.eventHub) {
        this.context.eventHub.emit(EVENT_NAMES.START_CARD_CONFIG);
      }
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate("appContext", this.context);
    registerHdsSnackBar();
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onCreate');

    if ((want.parameters!['action'] as string) == 'quick_scan') {
      AppPreference.setPreference(PREF_KEYS.WANT_QUICK_SCAN, true);
      AppPreference.setPreference(PREF_KEYS.WANT_URI, want.uri!);
    }
    this.handleCardAction(want);

    // 初始化设备信息（根据华为文档，建议只调用一次）
    DeviceInfoHelper.getInstance().init();
    // 初始化材质策略（API 26 沉浸光感能力检测与回退档位判定）
    MaterialPolicy.getInstance().init();
    // 注入弹窗背板材质 provider（Phase 5.5：用户 SOLID 偏好时单独关闭弹窗默认材质）
    setDialogSystemMaterialProvider(() => MaterialTheme.dialogSystemMaterial());

    //监听前后台变化
    let applicationStateChangeCallback: ApplicationStateChangeCallback = {
      onApplicationForeground() {
        hilog.info(0x0000, 'testTag', 'applicationStateChangeCallback onApplicationForeground');
      },
      onApplicationBackground() {
        hilog.info(0x0000, 'testTag', 'applicationStateChangeCallback onApplicationBackground');
        if (AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
          AppStorage.setOrCreate('app_lock_need_show', true);
        }
      }
    }

    // 1.获取applicationContext
    let applicationContext = this.context.getApplicationContext();
    try {
      // 2.通过applicationContext注册应用前后台状态监听
      applicationContext.on('applicationStateChange', applicationStateChangeCallback);
    } catch (paramError) {
      hilog.error((paramError as BusinessError).code, 'testTag', `error: ${(paramError as BusinessError).code}, ${(paramError as BusinessError).message}`);
    }
  }

  onDestroy(): void {
    AppPreference.saveSettings();
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  // [性能打点] onWindowStageCreate 整体耗时 + loadSettings/loadContent 子阶段耗时
  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    try {
      // 异步打点：覆盖 onWindowStageCreate 入口到 loadContent 回调完成
      hiTraceMeter.startTrace('H:onWindowStageCreate', 1);
      let win: AppWindowInfo = AppStorageV2.connect(AppWindowInfo, () => new AppWindowInfo())!;

      win.ColorMode = this.context.config.colorMode ?? -1;
      win.Context = this.context;

      hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

      hiTraceMeter.startTrace('H:onWindowStageCreate.loadSettings', 1);
      await AppPreference.loadSettings();
      hiTraceMeter.finishTrace('H:onWindowStageCreate.loadSettings', 1);

      if (AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
        AppStorage.setOrCreate('app_lock_need_show', true);
      }

      // 异步打点：loadContent 触发 Index 页面构建，回调中完成窗口初始化
      hiTraceMeter.startTrace('H:onWindowStageCreate.loadContent', 1);
      windowStage.loadContent('pages/Index', (err) => {
        hiTraceMeter.finishTrace('H:onWindowStageCreate.loadContent', 1);
        if (err.code) {
          hilog.error(0x0000, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err) ?? '');
          hiTraceMeter.finishTrace('H:onWindowStageCreate', 1);
          return;
        }

        let windowClass: window.Window = windowStage.getMainWindowSync();
        this.uiContext = windowClass.getUIContext();

        win.uiContext = this.uiContext;
        win.WindowClass = windowClass;

        windowClass.setWindowLayoutFullScreen(true)

        const avoidAreaTop = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        const avoidAreaBottom = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);

        win.AvoidTopHeight = this.uiContext.px2vp(avoidAreaBottom.topRect.height);
        win.AvoidBottomHeight = this.uiContext.px2vp(avoidAreaTop.bottomRect.height);

        windowClass.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR)
            win.AvoidBottomHeight = this.uiContext!.px2vp(data.area.bottomRect.height);
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM)
            win.AvoidTopHeight = this.uiContext!.px2vp(data.area.topRect.height);
        });

        const widthBp: WidthBreakpoint = this.uiContext.getWindowWidthBreakpoint();
        const heightBp: HeightBreakpoint = this.uiContext.getWindowHeightBreakpoint();
        win.Size = windowClass.getWindowProperties().windowRect;
        win.WidthBreakpoint = widthBp;
        win.HeightBreakpoint = heightBp;
        windowClass.on('windowSizeChange', this.onWindowSizeChange);

        this.applySettings(windowClass);

        if (AppPreference.getPreference(PREF_KEYS.SAFETY_DLP_ANTI_PEEP_ENABLE)) {
          DlpAntiPeepManager.getInstance().start(windowClass, this.context);
        }

        hiTraceMeter.finishTrace('H:onWindowStageCreate', 1);
        hilog.info(0x0000, 'testTag', 'Succeeded in loading the content.');
      });
    }
    catch (err) {
      hilog.error(0x0000, 'onWindowStageCreate', `${err}`);
    }

  }

  onWindowStageRestore(windowStage: window.WindowStage): void {
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if ((want.parameters!['action'] as string) == 'quick_scan') {
      AppPreference.setPreference(PREF_KEYS.WANT_QUICK_SCAN, true);
      AppPreference.setPreference(PREF_KEYS.WANT_URI, want.uri!);
    }
    this.handleCardAction(want);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    let window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
    window.ColorMode = newConfig.colorMode ?? -1;
  }
  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(0x0000, 'testTag', '%{public}s', 'Ability onBackground');
    // 开启隐私窗口防止返回前台时系统缓存帧泄露令牌明文
    if (AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE)) {
      const win = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
      win.WindowClass?.setWindowPrivacyMode(true);
    }
  }

  applySettings(windowClass: window.Window): void {
    // Color Mode
    const color_mode = AppPreference.getPreference(PREF_KEYS.APPEARANCE_COLOR_MODE) as number;
    const color_map: Map<SettingColorMode, ConfigurationConstant.ColorMode> = new Map([
      [SettingColorMode.System, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET],
      [SettingColorMode.Dark, ConfigurationConstant.ColorMode.COLOR_MODE_DARK],
      [SettingColorMode.Light, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT],
    ]);
    this.context.getApplicationContext().setColorMode(color_map.get(color_mode ?? 0));

    // 设置隐私模式
    let privacy_mode = AppPreference.getPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE) as boolean;
    if (privacy_mode) {
      try {
        windowClass.setWindowPrivacyMode(true).catch((err: BusinessError) => {
          hilog.error(err.code, 'testTag', `Failed to set the window to privacy mode. Cause code: ${err.code}, message: ${err.message}`);
        });
      } catch (exception) {
        hilog.error(exception.code, 'testTag', `Failed to set the window to privacy mode. Cause code: ${exception.code}, message: ${exception.message}`);
      }
    }
  }

  //初始化RDB数据库
  initRdbStore(): void{
    const STORE_CONFIG: relationalStore.StoreConfig = {
      name: "main_rdb_store.db",
      encrypt: true,//加密
      securityLevel: relationalStore.SecurityLevel.S3
    };
    relationalStore.getRdbStore(this.context, STORE_CONFIG, (err: BusinessError, __rdbStore: relationalStore.RdbStore) => {
      rdbStore = __rdbStore;
      if (err) {
        hilog.error(err.code, 'testTag', `Get RdbStore failed, code is ${err.code},message is ${err.message}`);
        return;
      }
      hilog.info(0x0000, 'testTag', 'Get RdbStore successfully.');
    })
  }

}
