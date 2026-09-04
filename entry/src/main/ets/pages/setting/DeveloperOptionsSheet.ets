import { dialogSystemMaterial } from 'common';
import { AppStorageV2 } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { AppPreference, AppWindowInfo, PREF_KEYS, showSnackBar, SnackBarNotifyType } from 'common';
import { MaterialTheme } from '../../components/MaterialTheme';
import { SettingItem } from '../../components/SettingItem';
import { SubItemButton } from '../../components/SubItemButton';
import { SubItemDivider } from '../../components/SubItemDivider';
import { SubItemToggle } from '../../components/SubItemToggle';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';

@ComponentV2
export struct DeveloperOptionsSheet {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Event debugModeChanged: (isOn: boolean) => void = () => {};
  @Event addTestTokens: () => Promise<boolean> = async () => false;
  @Event removeTestTokens: () => Promise<boolean> = async () => false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private sheetScroller: Scroller = new Scroller();

  private showAddTestTokensConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.developer_add_test_tokens_confirm_title'),
      message: $r('app.string.developer_add_test_tokens_confirm_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            this.addTestTokens().catch((reason: BusinessError) => {
              showSnackBar(reason.message, SnackBarNotifyType.ERROR);
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

  private showRemoveTestTokensConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
      systemMaterial: dialogSystemMaterial(),
      title: $r('app.string.developer_remove_test_tokens_confirm_title'),
      message: $r('app.string.developer_remove_test_tokens_confirm_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      gridCount: 4,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.dialog_btn_confirm'),
          action: () => {
            this.removeTestTokens().catch((reason: BusinessError) => {
              showSnackBar(reason.message, SnackBarNotifyType.ERROR);
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

  build() {
    Column() {
      HdsNavigation() {
        List({ scroller: this.sheetScroller, space: 10 }) {
          ListItem() {
            SettingItem({ title: $r('app.string.setting_group_general') }) {
              SubItemToggle({
                icon: $r('sys.symbol.gearshape'),
                title: $r('app.string.debug_mode'),
                isOn: AppPreference.getPreference(PREF_KEYS.DEBUG_MODE_ON) as boolean,
                description: $r('app.string.debug_mode_des'),
                onChange: (isOn: boolean) => {
                  AppPreference.setPreference(PREF_KEYS.DEBUG_MODE_ON, isOn);
                  this.debugModeChanged(isOn);
                }
              })
            }
          }
          .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

          ListItem() {
            SettingItem({ title: $r('app.string.setting_group_token_operations') }) {
              SubItemButton({
                symbol: $r('sys.symbol.plus_circle'),
                text: $r('app.string.developer_add_test_tokens'),
                description: $r('app.string.developer_add_test_tokens_description')
              })
                .onClick(() => {
                  this.showAddTestTokensConfirmDialog();
                })

              SubItemDivider()

              SubItemButton({
                symbol: $r('sys.symbol.trash'),
                text: $r('app.string.developer_remove_test_tokens'),
                description: $r('app.string.developer_remove_test_tokens_description')
              })
                .onClick(() => {
                  this.showRemoveTestTokensConfirmDialog();
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
        .contentEndOffset(this.window.AvoidBottomHeight)
        .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
        .layoutWeight(1)
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
            scrollEffectType: this.scrollEffectType
          },
          systemMaterialEffect: {
            materialType: MaterialTheme.hdsMaterialType(),
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        content: {
          title: {
            mainTitle: $r('app.string.setting_group_developer_options'),
          },
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(MaterialTheme.surfaceBackground($r('app.color.window_background')))
  }
}
