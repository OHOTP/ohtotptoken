import { common } from '@kit.AbilityKit';
import { TokenConfig } from 'common';
// [冷启动优化] 各 Sheet 仅在用户点击对应入口时触发模块评估
import lazy { BackupAndMigrationSheet } from '../pages/setting/BackupAndMigrationSheet'
import lazy { SecuritySheet } from '../pages/setting/SecuritySheet'
import lazy { AppearanceSheet } from '../pages/setting/AppearanceSheet'
import lazy { DeveloperOptionsSheet } from '../pages/setting/DeveloperOptionsSheet'
import lazy { DataSyncSheet } from '../pages/setting/DataSyncSheet'
import lazy { AgreementSheet } from '../pages/setting/AgreementSheet'
import lazy { AboutSheet } from '../pages/setting/AboutSheet'
import lazy { FeedbackSheet } from '../pages/setting/FeedbackSheet'
import { showSnackBar, SnackBarNotifyType } from 'common';
import { AppPreference, TokenPreference, EVENT_NAMES, PREF_KEYS } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { ScrollEffectType } from '@kit.UIDesignKit';
import lazy { HuaweiAccountManager, HuaweiUserInfo, HuaweiAccountLoginError } from 'common';
import { MaterialSheetStyle } from '../components/MaterialSheetStyle';
import { SettingItem } from '../components/SettingItem';
import { SubItemButton } from '../components/SubItemButton';
import { SubItemDivider } from '../components/SubItemDivider';
import { SETTING_PAGE_INSET, SETTING_ROW_PADDING } from '../components/SettingStyle';

/**
 * Sheet 协调器(Task 3.1)
 *
 * 承载"我的"页签的全部内容:华为账号卡片 + 8 个设置入口,
 * 以及 9 个 bindSheet(账号/备份/安全/外观/开发者选项/数据同步/协议/反馈/关于)的可见性状态与内容。
 * 华为账号 UI 状态与登录/登出流程内聚在本组件;
 * Index 侧在账号初始化完成、分布式登出等时机通过 EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED 广播,
 * 本组件监听后重新同步,保证 SheetCoordinator 懒构建时序下状态依然正确。
 */
@ComponentV2
export struct SheetCoordinator {
  @Require @Param tokens: TokenConfig[] = [];
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Require @Param scroller: Scroller = new Scroller();
  @Require @Param bottomAvoidHeight: number = 0;
  /** 备份恢复完成回调(由 Index 提供:批量更新 Token 并重新排序) */
  @Require @Param backupReload: (conf: TokenConfig[]) => Promise<void> = async (conf: TokenConfig[]) => {};
  /** 开发者选项：生成并持久化 100 个随机测试令牌 */
  @Event addTestTokens: () => Promise<boolean> = async () => false;
  /** 开发者选项：移除生成的测试令牌 */
  @Event removeTestTokens: () => Promise<boolean> = async () => false;

  @Local isBackupSheetVisible: boolean = false;
  @Local isSafetySheetVisible: boolean = false;
  @Local isAppearanceSheetVisible: boolean = false;
  @Local isDeveloperOptionsSheetVisible: boolean = false;
  @Local isDataSyncSheetVisible: boolean = false;
  @Local isAgreementSheetVisible: boolean = false;
  @Local isAboutSheetVisible: boolean = false;
  @Local isFeedbackSheetVisible: boolean = false;
  @Local isAccountSheetVisible: boolean = false;
  @Local isHuaweiLoggedIn: boolean = false;
  @Local huaweiUser: HuaweiUserInfo | null = null;
  @Local debug_mode_is_on: boolean = AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;

  private appCtx: common.UIAbilityContext = AppStorage.get('appContext') as common.UIAbilityContext;
  private onAccountStateChanged: () => void = () => {};

  aboutToAppear(): void {
    // 初始同步一次(华为账号管理器为单例,可能尚未 init 完成,后续靠事件再同步)
    this.syncHuaweiAccountState();
    this.onAccountStateChanged = () => {
      this.syncHuaweiAccountState();
    };
    this.appCtx.eventHub?.on(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED, this.onAccountStateChanged);
  }

  aboutToDisappear(): void {
    this.appCtx.eventHub?.off(EVENT_NAMES.HUAWEI_ACCOUNT_STATE_CHANGED, this.onAccountStateChanged);
  }

  private syncHuaweiAccountState(): void {
    this.isHuaweiLoggedIn = HuaweiAccountManager.getInstance().userLogin;
    this.huaweiUser = HuaweiAccountManager.getInstance().userAccount;
  }

  private updateDebugMode(isOn: boolean): void {
    this.debug_mode_is_on = isOn;
    this.appCtx.eventHub?.emit(EVENT_NAMES.DEBUG_MODE_CHANGED, isOn);
    if (!isOn) {
      this.isDeveloperOptionsSheetVisible = false;
    }
  }

  private async triggerHuaweiLogin(): Promise<void> {
    try {
      await HuaweiAccountManager.getInstance().login(this.getUIContext());
      this.syncHuaweiAccountState();
      this.isAccountSheetVisible = true;
    } catch (error) {
      this.syncHuaweiAccountState();
      const loginError = error as HuaweiAccountLoginError;
      if (HuaweiAccountManager.isUserCancel(loginError.code)) {
        return;
      }
      const errorMsg = HuaweiAccountManager.getLoginErrorResource(loginError.code);
      if (errorMsg) {
        showSnackBar(errorMsg, SnackBarNotifyType.ERROR);
      }
    }
  }

  private confirmHuaweiLogin(): void {
    HuaweiAccountManager.getInstance().selectHuaweiAccountToLogin();
    this.syncHuaweiAccountState();
    this.isAccountSheetVisible = false;
    showSnackBar($r('app.string.huawei_account_login_success'), SnackBarNotifyType.SUCCESS);
  }

  private showLogoutConfirmDialog(): void {
    const cloudBackupEnabled = AppPreference.getPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE) as boolean;
    const msg = cloudBackupEnabled
      ? $r('app.string.huawei_account_logout_cloud_backup_msg')
      : $r('app.string.huawei_account_logout_confirm_msg');
    this.getUIContext().showAlertDialog({
      title: $r('app.string.huawei_account_logout_confirm_title'),
      message: msg,
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      gridCount: 4,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            HuaweiAccountManager.getInstance().logout().then(() => {
              this.syncHuaweiAccountState();
              this.isAccountSheetVisible = false;
              AppPreference.setPreference(PREF_KEYS.APPEARANCE_HUAWEI_CLOUD_SYNC_ENABLE, false);
              AppPreference.setPreference(PREF_KEYS.CLOUD_SYNC_LAST_TIME, '0');
            });
          }
        },
        {
          value: $r('app.string.dialog_btn_cancel'),
          action: () => {}
        },
      ],
      cancel: () => {},
    });
  }

  @Builder
  BackupAndMigrationSheetBuilder() {
    BackupAndMigrationSheet({
      Tokens: this.tokens,
      scrollEffectStyle: this.scrollEffectType,
      backupReload: this.backupReload
    })
      .height('100%')
  }

  @Builder
  SecuritySheetBuilder() {
    SecuritySheet({
      scrollEffectStyle: this.scrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AppearanceSheetBuilder() {
    AppearanceSheet({
      scrollEffectType: this.scrollEffectType,
    })
      .height('100%')
  }

  @Builder
  DeveloperOptionsSheetBuilder() {
    DeveloperOptionsSheet({
      scrollEffectType: this.scrollEffectType,
      debugModeChanged: (isOn: boolean) => this.updateDebugMode(isOn),
      addTestTokens: () => this.addTestTokens(),
      removeTestTokens: () => this.removeTestTokens()
    })
      .height('100%')
  }

  @Builder
  DataSyncSheetBuilder() {
    DataSyncSheet({
      scrollEffectType: this.scrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AgreementSheetBuilder() {
    AgreementSheet({
      scrollEffectType: this.scrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AboutSheetBuilder() {
    AboutSheet({
      scrollEffectStyle: this.scrollEffectType,
      debugModeChanged: (isOn: boolean) => this.updateDebugMode(isOn)
    })
      .height('100%')
  }

  @Builder
  FeedbackSheetBuilder() {
    FeedbackSheet({
      scrollEffectType: this.scrollEffectType,
    })
      .height('100%')
  }

  @Builder
  AccountSheetBuilder() {
    Column() {
      Column() {
        SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1'))
          .fontSize($r('sys.float.Display_L'))
          .fontColor([$r('sys.color.icon_emphasize')])
          .aspectRatio(1)

        Text(this.isHuaweiLoggedIn ?
          $r('app.string.huawei_account_current') :
          $r('app.string.huawei_account_select_title'))
          .fontSize($r('sys.float.Title_M'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .margin({ top: $r('sys.float.padding_level10') })

        if (this.huaweiUser) {
          if (this.huaweiUser.avatarUri !== '') {
            Image(this.huaweiUser.avatarUri)
              .draggable(false)
              .width(85)
              .height(85)
              .borderRadius(42.5)
              .margin({ top: 40 })
          } else if (this.huaweiUser.nickname !== '') {
            Text(this.huaweiUser.nickname.length > 0 ?
              this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
              .width(85)
              .height(85)
              .borderRadius(42.5)
              .backgroundColor($r('sys.color.ohos_id_color_tertiary'))
              .linearGradient({
                colors: [
                  [$r('sys.color.ohos_id_color_tertiary'), 0.0],
                  [$r('sys.color.ohos_id_color_foreground_contrary'), 1.0]
                ]
              })
              .fontColor($r('sys.color.font_on_primary'))
              .fontSize($r('sys.float.Title_M'))
              .fontWeight(FontWeight.Bold)
              .textAlign(TextAlign.Center)
              .margin({ top: 40 })
          }

          Text(this.huaweiUser.nickname)
            .margin({ top: $r('sys.float.padding_level12') })
            .fontSize($r('sys.float.Body_L'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('sys.color.font_primary'))
        }
      }
      .margin({ top: $r('sys.float.padding_level16') })

      Blank();

      Button(this.isHuaweiLoggedIn ?
        $r('app.string.huawei_account_logout') :
        $r('app.string.huawei_account_select_to_login'))
        .type(ButtonType.Capsule)
        .fontSize($r('sys.float.Body_L'))
        .role(this.isHuaweiLoggedIn ? ButtonRole.ERROR : ButtonRole.NORMAL)
        .buttonStyle(this.isHuaweiLoggedIn ? ButtonStyleMode.NORMAL : ButtonStyleMode.EMPHASIZED)
        .width('100%')
        .margin({ bottom: $r('sys.float.padding_level24') })
        .onClick(() => {
          if (this.isHuaweiLoggedIn) {
            this.showLogoutConfirmDialog();
          } else {
            this.confirmHuaweiLogin();
          }
        })
    }
    .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })
    .width('100%')
    .height('100%')
  }

  build() {
    List({ space: 10, scroller: this.scroller }) {
      // 华为账号登录卡片：与设置子项共用 SettingItem 分组卡片表面
      ListItem() {
        SettingItem({ title: '' }) {
          Row({ space: 16 }) {
            if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.avatarUri !== '') {
              Image(this.huaweiUser.avatarUri)
                .draggable(false)
                .width(48)
                .height(48)
                .borderRadius(24)
            } else if (this.isHuaweiLoggedIn && this.huaweiUser && this.huaweiUser.nickname !== '') {
              Text(this.huaweiUser.nickname.length > 0 ?
                this.huaweiUser.nickname.substring(this.huaweiUser.nickname.length - 1) : '')
                .width(48)
                .height(48)
                .borderRadius(24)
                .backgroundColor($r('sys.color.ohos_id_color_tertiary'))
                .linearGradient({
                  colors: [
                    [$r('sys.color.ohos_id_color_tertiary'), 0.0],
                    [$r('sys.color.ohos_id_color_foreground_contrary'), 1.0]
                  ]
                })
                .fontColor($r('sys.color.font_on_primary'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .textAlign(TextAlign.Center)
            } else {
              SymbolGlyph($r('sys.symbol.person_crop_circle_fill_1'))
                .fontSize(48)
                .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
            }

            Column({ space: 4 }) {
              Text(this.isHuaweiLoggedIn && this.huaweiUser ?
                this.huaweiUser.nickname : $r('app.string.huawei_account_login'))
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text(this.isHuaweiLoggedIn ?
                $r('app.string.huawei_account_current') :
                $r('app.string.huawei_account_login_desc'))
                .fontSize(14)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(SETTING_ROW_PADDING)
          .alignItems(VerticalAlign.Center)
          // PC/2in1 光标悬浮时提供系统高亮反馈
          .hoverEffect(HoverEffect.Highlight)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
          .onClick(() => {
            if (!this.isHuaweiLoggedIn) {
              this.triggerHuaweiLogin();
            } else {
              this.isAccountSheetVisible = true;
            }
          })
          .bindSheet($$this.isAccountSheetVisible, this.AccountSheetBuilder(),
            MaterialSheetStyle.options(SheetSize.MEDIUM))
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 数据管理：备份与迁移、数据同步属于同一数据生命周期分类
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_data_management') }) {
          SubItemButton({
            symbol: $r('sys.symbol.save'),
            text: $r('app.string.setting_backup')
          })
            .onClick(() => {
              this.isBackupSheetVisible = true;
            })
            .bindSheet($$this.isBackupSheetVisible, this.BackupAndMigrationSheetBuilder(),
              MaterialSheetStyle.options())

          SubItemDivider()

          SubItemButton({
            symbol: $r('sys.symbol.link'),
            text: $r('app.string.data_sync')
          })
            .onClick(() => {
              this.isDataSyncSheetVisible = true;
            })
            .bindSheet($$this.isDataSyncSheetVisible, this.DataSyncSheetBuilder(),
              MaterialSheetStyle.options())
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 应用设置
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_app_settings') }) {
          SubItemButton({
            symbol: $r('sys.symbol.staroflife_rectangle'),
            text: $r('app.string.setting_safety')
          })
            .onClick(() => {
              this.isSafetySheetVisible = true;
            })
            .bindSheet($$this.isSafetySheetVisible, this.SecuritySheetBuilder(),
              MaterialSheetStyle.options())

          SubItemDivider()

          SubItemButton({
            symbol: $r('sys.symbol.chevron_up_2_circle'),
            text: $r('app.string.app_appearance')
          })
            .onClick(() => {
              this.isAppearanceSheetVisible = true;
            })
            .bindSheet($$this.isAppearanceSheetVisible, this.AppearanceSheetBuilder(),
              MaterialSheetStyle.options())

          if (this.debug_mode_is_on) {
            SubItemDivider()

            SubItemButton({
              symbol: $r('sys.symbol.wrench_and_screwdriver'),
              text: $r('app.string.setting_group_developer_options')
            })
              .onClick(() => {
                this.isDeveloperOptionsSheetVisible = true;
              })
              .bindSheet($$this.isDeveloperOptionsSheetVisible, this.DeveloperOptionsSheetBuilder(),
                MaterialSheetStyle.options())
          }
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

      // 支持与关于
      ListItem() {
        SettingItem({ title: $r('app.string.setting_group_support_about') }) {
          SubItemButton({
            symbol: $r('sys.symbol.person_shield'),
            text: $r('app.string.setting_agreement_statement')
          })
            .onClick(() => {
              this.isAgreementSheetVisible = true;
            })
            .bindSheet($$this.isAgreementSheetVisible, this.AgreementSheetBuilder(),
              MaterialSheetStyle.options())

          SubItemDivider()

          SubItemButton({
            symbol: $r('sys.symbol.envelope'),
            text: $r('app.string.setting_feedback')
          })
            .onClick(() => {
              this.isFeedbackSheetVisible = true;
            })
            .bindSheet($$this.isFeedbackSheetVisible, this.FeedbackSheetBuilder(),
              MaterialSheetStyle.options())

          SubItemDivider()

          SubItemButton({
            symbol: $r('sys.symbol.info_circle'),
            text: $r('app.string.setting_about')
          })
            .onClick(() => {
              this.isAboutSheetVisible = true;
            })
            .bindSheet($$this.isAboutSheetVisible, this.AboutSheetBuilder(),
              MaterialSheetStyle.options())
        }
      }
      .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
    }
    .clip(false)
    // 与令牌列表使用相同的页签栏末端避让，确保最后一组可滚动至 HdsTabs 上方
    .contentEndOffset(80 + this.bottomAvoidHeight)
    .chainAnimation(this.token_preference.app_appearance_chain_animation_enable)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor($r('app.color.window_background'))
  }
}
