import { AppStorageV2 } from '@kit.ArkUI';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { AppWindowInfo } from 'common';
import { MaterialPolicy } from '../../utils/MaterialPolicy';
import { MaterialTheme } from '../../components/MaterialTheme';
import { SettingItem } from '../../components/SettingItem';
import { SubItemButton } from '../../components/SubItemButton';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';

@ComponentV2
export struct DeveloperOptionsSheet {
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Event addTestTokens: () => Promise<boolean> = async () => false;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;

  private sheetScroller: Scroller = new Scroller();

  private showAddTestTokensConfirmDialog(): void {
    this.getUIContext().showAlertDialog({
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
            this.addTestTokens();
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
            SettingItem({ title: '' }) {
              SubItemButton({
                symbol: $r('sys.symbol.plus_circle'),
                text: $r('app.string.developer_add_test_tokens'),
                description: $r('app.string.developer_add_test_tokens_description')
              })
                .onClick(() => {
                  this.showAddTestTokensConfirmDialog();
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
      .mode(NavigationMode.Stack)
      .bindToScrollable([this.sheetScroller])
      .titleMode(HdsNavigationTitleMode.MODAL)
      .titleBar({
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
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
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
