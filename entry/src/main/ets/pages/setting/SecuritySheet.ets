import { BusinessError } from '@kit.BasicServicesKit';

import { showSnackBar, SnackBarNotifyType } from 'common';
import { SubItemToggle } from '../../components/SubItemToggle'
import { AppStorageV2, curves } from '@kit.ArkUI';
import { AppPreference, TokenPreference, PREF_KEYS } from 'common';
import { SettingItem } from '../../components/SettingItem';
import { userAuth } from '@kit.UserAuthenticationKit';
import { SubItemDivider } from '../../components/SubItemDivider';
import { AppWindowInfo } from 'common';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { DlpAntiPeepManager } from 'common';
import { common } from '@kit.AbilityKit';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';

@Preview
@ComponentV2
export struct SecuritySheet {
  @Require @Param scrollEffectStyle: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  @Local isDlpAntiPeepSupported: boolean = true;
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;
  aboutToAppear(): void {
    this.isDlpAntiPeepSupported = canIUse('SystemCapability.Security.DlpAntiPeep');
  }
  private sheetScroller: Scroller = new Scroller();

  build() {
    Column() {
      HdsNavigation() {
        Column() {
          List({ scroller: this.sheetScroller, space: 10 }) {
            ListItem() {
              SettingItem({ title: "" }) {
                SubItemToggle({
                  icon: $r('sys.symbol.hand_raised_hexagon'),
                  title: $r('app.string.setting_safety_privacy'),
                  isOn: AppPreference.getPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE) as boolean,
                  description: $r('app.string.setting_safety_privacy_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.SAFETY_PRIVACY_ENABLE, IsOn);
                    try {
                      this.window.WindowClass?.setWindowPrivacyMode(IsOn).catch((err: BusinessError) => {
                        hilog.error(err.code, 'SecuritySheet',
                          `Failed to set the window to privacy mode. Cause code: ${err.code}, message: ${err.message}`);
                      });
                    } catch (exception) {
                      hilog.error(exception.code, 'SecuritySheet',
                        `Failed to set the window to privacy mode. Cause code: ${exception.code}, message: ${exception.message}`);
                    }
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.key_shield'),
                  title: $r('app.string.setting_safety_lock'),
                  isOn: AppPreference.getPreference(PREF_KEYS.SAFETY_LOCK_ENABLE) as boolean,
                  description: $r('app.string.setting_safety_lock_des'),
                  onChange: (IsOn: boolean) => {
                    if (IsOn) {
                      try {
                        userAuth.getAvailableStatus(userAuth.UserAuthType.PIN, userAuth.AuthTrustLevel.ATL1);
                      } catch (err) {
                        const error = err as BusinessError;
                        showSnackBar(error.message, SnackBarNotifyType.ERROR);
                        return;
                      }
                    }
                    AppPreference.setPreference(PREF_KEYS.SAFETY_LOCK_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.face'),
                  title: $r('app.string.auto_unlock'),
                  isOn: AppPreference.getPreference(PREF_KEYS.SAFETY_AUTO_UNLOCK_ENABLE) as boolean,
                  description: $r('app.string.auto_unlock_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.SAFETY_AUTO_UNLOCK_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.eye_slash'),
                  title: $r('app.string.setting_hide_token'),
                  isOn: AppPreference.getPreference(PREF_KEYS.SAFETY_HIDE_TOKEN_ENABLE) as boolean,
                  description: $r('app.string.setting_safety_hide_token_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.SAFETY_HIDE_TOKEN_ENABLE, IsOn);
                    this.token_preference.app_safety_hide_token_enable = IsOn;
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.blur_bar'),
                  title: $r('app.string.setting_background_blur'),
                  isOn: AppPreference.getPreference(PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE) as boolean,
                  description: $r('app.string.setting_background_blur_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.SAFETY_BACKGROUND_BLUR_ENABLE, IsOn);
                  }
                })

                SubItemDivider()

                SubItemToggle({
                  icon: $r('sys.symbol.eye'),
                  title: $r('app.string.setting_dlp_anti_peep'),
                  isOn: this.isDlpAntiPeepSupported && (AppPreference.getPreference(PREF_KEYS.SAFETY_DLP_ANTI_PEEP_ENABLE) as boolean),
                  disable: !this.isDlpAntiPeepSupported,
                  description: this.isDlpAntiPeepSupported ?
                    $r('app.string.setting_dlp_anti_peep_des') :
                    $r('app.string.setting_dlp_anti_peep_unsupported'),
                  descriptionColor: this.isDlpAntiPeepSupported ?
                    $r('sys.color.ohos_id_color_text_secondary') :
                    $r('sys.color.ohos_id_color_text_tertiary'),
                  onChange: (IsOn: boolean) => {
                    if (!this.isDlpAntiPeepSupported) {
                      return;
                    }
                    AppPreference.setPreference(PREF_KEYS.SAFETY_DLP_ANTI_PEEP_ENABLE, IsOn);
                    if (IsOn) {
                      DlpAntiPeepManager.getInstance().start(
                        this.window.WindowClass!,
                        this.appCtx
                      );
                    } else {
                      DlpAntiPeepManager.getInstance().stop();
                    }
                  }
                })
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })
          }
          .clip(false)
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          // 滚动末端抬高底部避让区(导航条/小横条)，避免最后一项被遮挡
          .contentEndOffset(this.window.AvoidBottomHeight)
          // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
          .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
        .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
      }
      .clip(false)
      .backgroundColor(this.embedded ? $r('app.color.window_background') :
        MaterialTheme.surfaceBackground($r('app.color.window_background')))
      .mode(NavigationMode.Stack)
      .bindToScrollable([this.sheetScroller])
      .hideBackButton(this.embedded)
      .titleMode(this.embedded ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.MODAL)
      .titleBar({
        avoidLayoutSafeArea: this.embedded,
        enableComponentSafeArea: true,
        style: {
          originalStyle: {
            contentStyle: {
              titleStyle: {
                mainTitleColor: $r('sys.color.font_primary'),
                subTitleColor: $r('sys.color.font_secondary')
              },
              backIconStyle: {
                iconColor: $r('sys.color.icon_primary')
              }
            },
          },
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: this.scrollEffectStyle
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.setting_safety'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    // 沉浸档透明透出 Sheet 材质(Phase 5.4)，其余档位保持 window_background
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }
}
