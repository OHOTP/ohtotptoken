import { BusinessError } from '@kit.BasicServicesKit';
import { MaterialPolicy } from '../../utils/MaterialPolicy';

import { showSnackBar, SnackBarNotifyType } from 'common';
import { SubItemToggle } from '../../components/SubItemToggle'
import { AppStorageV2 } from '@kit.ArkUI';
import { AppPreference, SettingColorMode, SettingTopEffectType, SettingBottomTabsType, TokenPreference, MaterialPreference, AVAILABLE_TOP_EFFECT_TYPES, AVAILABLE_BOTTOM_TABS_TYPES, AVAILABLE_IMMERSIVE_STYLES, EVENT_NAMES, PREF_KEYS, ROUTE_NAMES } from 'common';
import { SubItemButton } from '../../components/SubItemButton';
import { SettingItem } from '../../components/SettingItem';
import { SubItemDivider } from '../../components/SubItemDivider';
import { SubItemSelect } from '../../components/SubItemSelect';
import { SubItemEnumSelect } from '../../components/SubItemEnumSelect';
import { SubItemIconManager } from '../../components/SubItemIconManager';
import { AppWindowInfo } from 'common';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { throttle } from 'common';
import { AppearancePage } from '../AppearancePage';
import { hdsMaterial, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { SETTING_PAGE_INSET } from '../../components/SettingStyle';
import { MaterialTheme } from '../../components/MaterialTheme';

@Preview
@ComponentV2
export struct AppearanceSheet {
  pageInfos: NavPathStack = new NavPathStack();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Param embedded: boolean = false;
  @Local token_preference: TokenPreference = AppStorageV2.connect(TokenPreference) as TokenPreference;
  @Local material_preference: MaterialPreference = AppStorageV2.connect(MaterialPreference) as MaterialPreference;
  @Local window: AppWindowInfo = AppStorageV2.connect(AppWindowInfo) as AppWindowInfo;
  private sheetScroller: Scroller = new Scroller();
  private appCtx = AppStorage.get<common.UIAbilityContext>('appContext') as common.UIAbilityContext;

  @Builder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.AppearancePage) {
      AppearancePage({scrollEffectType: this.scrollEffectType})
    }
  }

  build() {
    Column() {
      HdsNavigation(this.pageInfos) {
        Column() {
          List({ scroller: this.sheetScroller, space: 10 }) {
            // 通用分组
            ListItem() {
              SettingItem({ title: $r('app.string.setting_group_general') }) {
                SubItemToggle({
                  icon: $r('sys.symbol.chevron_up_2_circle'),
                  title: $r('app.string.show_next_token'),
                  isOn: AppPreference.getPreference(PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE) as boolean,
                  description: $r('app.string.show_next_token_des'),
                  onChange: (IsOn: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_SHOW_NEXT_TOKEN_ENABLE, IsOn);
                    this.token_preference.app_appearance_show_next_token_enable = IsOn;
                  }
                })

                if (!this.window.IsPc) {
                  SubItemDivider()

                  SubItemToggle({
                    icon: $r('sys.symbol.rectangle_stack'),
                    title: $r('app.string.chain_animation'),
                    isOn: this.token_preference.app_appearance_chain_animation_enable,
                    description: $r('app.string.chain_animation_des'),
                    onChange: (IsOn: boolean) => {
                      AppPreference.setPreference(PREF_KEYS.APPEARANCE_CHAIN_ANIMATION_ENABLE, IsOn);
                      this.token_preference.app_appearance_chain_animation_enable = IsOn;
                    }
                  })
                }
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            // 外观分组
            ListItem() {
              SettingItem({ title: $r('app.string.setting_group_appearance') }) {
                SubItemSelect({
                  icon: $r('sys.symbol.dark'),
                  title: $r('app.string.setting_color_mode'),
                  values: [$r('app.string.setting_color_mode_system'), $r('app.string.setting_color_mode_dark'),
                    $r('app.string.setting_color_mode_light'),],
                  description: $r('app.string.setting_color_mode_desc'),
                  selected: AppPreference.getPreference(PREF_KEYS.APPEARANCE_COLOR_MODE) as number ??
                    SettingColorMode.System,
                  onChange: (index: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_COLOR_MODE, index);
                    const color_map: Map<SettingColorMode, ConfigurationConstant.ColorMode> = new Map([
                      [SettingColorMode.System, ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET],
                      [SettingColorMode.Dark, ConfigurationConstant.ColorMode.COLOR_MODE_DARK],
                      [SettingColorMode.Light, ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT],
                    ]);
                    this.appCtx.getApplicationContext().setColorMode(color_map.get(index));
                  }
                })

                SubItemDivider()

                SubItemEnumSelect({
                  icon: $r('sys.symbol.slider_horizontal_2'),
                  title: $r('app.string.setting_top_effect_type'),
                  options: AVAILABLE_TOP_EFFECT_TYPES,
                  description: $r('app.string.setting_top_effect_type_desc'),
                  selected: AppPreference.getPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE) as number ??
                    SettingTopEffectType.IMMERSIVE_GRADIENT_BLUR,
                  onChange: (value: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_TOP_EFFECT_TYPE, value);
                    if (this.appCtx.eventHub != undefined) {
                      this.appCtx.eventHub.emit(EVENT_NAMES.TOP_EFFECT_TYPE_CHANGED);
                    }
                  }
                })

                SubItemDivider()

                if (!this.window.IsPcOrTablet) {
                  SubItemEnumSelect({
                    icon: $r('sys.symbol.blur_bar'),
                    title: $r('app.string.setting_bottom_tabs_type'),
                    options: AVAILABLE_BOTTOM_TABS_TYPES,
                    description: $r('app.string.setting_bottom_tabs_type_desc'),
                    selected: AppPreference.getPreference(PREF_KEYS.APPEARANCE_BOTTOM_TABS_TYPE) as number ??
                      SettingBottomTabsType.SUSPENSION,
                    onChange: (value: number) => {
                      AppPreference.setPreference(PREF_KEYS.APPEARANCE_BOTTOM_TABS_TYPE, value);
                      if (this.appCtx.eventHub != undefined) {
                        this.appCtx.eventHub.emit(EVENT_NAMES.BOTTOM_TABS_TYPE_CHANGED);
                      }
                    }
                  })

                  SubItemDivider()
                }

                SubItemIconManager()

                SubItemDivider()

                SubItemButton({
                  symbol: $r("sys.symbol.paintpalette"),
                  text: $r('app.string.customize_appearance')
                })
                  .onClick(throttle((event) => {
                    this.pageInfos.pushPathByName(ROUTE_NAMES.AppearancePage, null);
                  }, 1000))
              }
            }
            .padding({ left: SETTING_PAGE_INSET, right: SETTING_PAGE_INSET })

            // 光感材质分组
            ListItem() {
              SettingItem({ title: $r('app.string.setting_group_material') }) {
                SubItemToggle({
                  icon: $r('sys.symbol.rectangle_stack'),
                  title: $r('app.string.setting_immersive_enable'),
                  description: $r('app.string.setting_immersive_enable_desc'),
                  isOn: this.material_preference.app_appearance_immersive_enable,
                  disable: !MaterialTheme.supportsNativeMaterial() &&
                    MaterialPolicy.getInstance().getTier() === 'solid',
                  onChange: (value: boolean) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_IMMERSIVE_ENABLE, value);
                    this.material_preference.app_appearance_immersive_enable = value;
                  }
                })

                SubItemDivider()

                SubItemEnumSelect({
                  icon: $r('sys.symbol.rectangle_split_3x1'),
                  title: $r('app.string.setting_immersive_style'),
                  options: AVAILABLE_IMMERSIVE_STYLES,
                  description: $r('app.string.setting_immersive_style_desc'),
                  selected: this.material_preference.app_appearance_immersive_style,
                  disable: !this.material_preference.app_appearance_immersive_enable ||
                    !MaterialTheme.supportsNativeMaterial(),
                  onChange: (value: number) => {
                    AppPreference.setPreference(PREF_KEYS.APPEARANCE_IMMERSIVE_STYLE, value);
                    this.material_preference.app_appearance_immersive_style = value;
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
          .edgeEffect(EdgeEffect.Spring, {alwaysEnabled: true})
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
      .navDestination(this.navDestinationBuilder)
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
            mainTitle: $r('app.string.app_appearance'),
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
