import { TokenConfig } from 'common';
import { MaterialPolicy } from '../utils/MaterialPolicy';

import { TokenListPage } from '../pages/TokenListPage';
import { AppWindowInfo } from 'common';
import { PageScaffold } from '../components/PageScaffold';
import { ROUTE_NAMES } from 'common';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsNavigation, HdsNavigationTitleMode, HdsTabs, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

@Builder
function EmptyBuilder() {
}

/**
 * 主页签容器(Task 3.1)
 *
 * 承载首页断点 lanes 逻辑(Phase W 后手表端已拆分为独立 wearable HAP):
 *  - (HEIGHT_MD|HEIGHT_SM) + WIDTH_SM(窄屏)→ 单栏 TokenListPage
 *  - 其余 → HdsTabs 双页签(令牌 / 我的)
 * "我的"页签内容由 SheetCoordinator 通过 settingEntryContent 注入。
 */
@ComponentV2
export struct HomeTabs {
  @Require @Param tokens: TokenConfig[] = [];
  @Require @Param window: AppWindowInfo = new AppWindowInfo();
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Require @Param pageInfos: NavPathStack = new NavPathStack();
  @Require @Param updateTokenConfig: (conf: TokenConfig, toast?: boolean) => Promise<boolean> =
    async (conf: TokenConfig, toast?: boolean) => false;
  @Require @Param updateTokenConfigs: (tokens: Array<TokenConfig>) => Promise<boolean> =
    async (tokens: Array<TokenConfig>) => false;
  @Require @Param openAddTokenMenu: () => void = () => {};
  @Require @Param addTokenMenuTargetId: string = '';
  @Require @Param tokenListScroller: Scroller = new Scroller();
  @Require @Param settingEntryScroller: Scroller = new Scroller();

  @Local tab_bar_index: number = 0;
  // [冷启动优化] Setting Tab 懒加载标志,仅在用户首次切换到"我的"Tab 时构建组件树
  @Local settingTabInitialized: boolean = false;

  @BuilderParam settingEntryContent?: CustomBuilder = EmptyBuilder;

  build() {
    if (
      (this.window.HeightBreakpoint === HeightBreakpoint.HEIGHT_MD ||
        this.window.HeightBreakpoint === HeightBreakpoint.HEIGHT_SM) &&
        this.window.WidthBreakpoint === WidthBreakpoint.WIDTH_SM
    ) {
      PageScaffold() {
        TokenListPage({
          Tokens: this.tokens,
          TabBarVisible: false,
          appBottomAvoidHeight: this.window.AvoidBottomHeight,
          appTopAvoidHeight: this.window.AvoidTopHeight,
          appWindowSize: this.window.Size,
          updateTokenConfig: this.updateTokenConfig,
          updateTokenConfigs: this.updateTokenConfigs,
          listScroller: this.tokenListScroller,
        })
      }
    } else {
      Column() {
        HdsTabs({ index: this.tab_bar_index }) {
          TabContent() {
            HdsNavigation() {
              TokenListPage({
                Tokens: this.tokens,
                TabBarVisible: true,
                appBottomAvoidHeight: this.window.AvoidBottomHeight,
                appTopAvoidHeight: this.window.AvoidTopHeight,
                appWindowSize: this.window.Size,
                updateTokenConfig: this.updateTokenConfig,
                updateTokenConfigs: this.updateTokenConfigs,
                listScroller: this.tokenListScroller,
              })
            }
            .mode(NavigationMode.Stack)
            .bindToScrollable([this.tokenListScroller])
            .titleMode(HdsNavigationTitleMode.MINI)
            .hideBackButton(true) // 设置mini类型隐藏后退按钮
            .titleBar({
              avoidLayoutSafeArea: true, // 状态栏安全区沉浸
              enableComponentSafeArea: true,
              style: {
                originalStyle: {
                  contentStyle: {
                    titleStyle: {
                      mainTitleColor: $r('sys.color.font_primary'),
                    },
                    menuStyle: {
                      iconColor: $r('sys.color.icon_primary')
                    },
                  }
                },
                scrollEffectOpts: {
                  enableScrollEffect: true,
                  scrollEffectType: this.scrollEffectType // 渐变模糊
                },
                systemMaterialEffect: {
                  materialType: hdsMaterial.MaterialType.ADAPTIVE,
                  materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
                }
              },
              content: {
                title: {
                  mainTitle: $r('app.string.EntryAbility_label'),
                },
                menu: {
                  value: [
                    {
                      content: {
                        label: $r('app.string.app_ua_search_token'),
                        icon: $r('sys.symbol.magnifyingglass'),
                        isEnabled: true,
                        action: () => {
                          this.pageInfos.pushPathByName(ROUTE_NAMES.TokenSearchPage, null);
                        }
                      }
                    },
                    {
                      content: {
                        label: $r('app.string.app_ua_add_token'),
                        icon: $r('sys.symbol.plus'),
                        isEnabled: true,
                        componentId: this.addTokenMenuTargetId,
                        action: () => {
                          this.openAddTokenMenu();
                        }
                      }
                    }
                  ]
                }
              }
            })
          }
          .backgroundColor($r('app.color.window_background'))
          .tabBar(BottomTabBarStyle.of(
            {
              normal: new SymbolGlyphModifier($r('sys.symbol.key_fill')),
              selected: new SymbolGlyphModifier($r('sys.symbol.key_fill'))
            },
            $r('app.string.tab_token'))
            .verticalAlign(VerticalAlign.Center)
          )
          .tabIndex(0)

          TabContent() {
            // [冷启动优化] Setting Tab 懒加载:仅在用户首次切换到"我的"Tab 时构建组件树,
            // 避免冷启动时一次性构建两个 TabContent 导致首帧 build 耗时增加
            if (this.settingTabInitialized) {
              HdsNavigation() {
                if (this.settingEntryContent) {
                  this.settingEntryContent();
                }
              }
              .mode(NavigationMode.Stack)
              .bindToScrollable([this.settingEntryScroller])
              .titleMode(HdsNavigationTitleMode.MINI)
              .hideBackButton(true)
              .titleBar({
                avoidLayoutSafeArea: true,
                enableComponentSafeArea: true,
                style: {
                  originalStyle: {
                    contentStyle: {
                      titleStyle: {
                        mainTitleColor: $r('sys.color.font_primary'),
                      },
                      menuStyle: {
                        iconColor: $r('sys.color.icon_primary')
                      },
                    }
                  },
                  scrollEffectOpts: {
                    enableScrollEffect: true,
                    scrollEffectType: this.scrollEffectType,
                  },
                  systemMaterialEffect: {
                    materialType: hdsMaterial.MaterialType.ADAPTIVE,
                    materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
                  }
                },
                content: {
                  title: {
                    mainTitle: $r('app.string.tab_me')
                  },
                  menu: {
                    value: []
                  }
                }
              })
            }
          }
          .backgroundColor($r('app.color.window_background'))
          .tabBar(BottomTabBarStyle.of(
            {
              normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
              selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
            },
            $r('app.string.tab_me'))
            .verticalAlign(VerticalAlign.Center)
          )
          .tabIndex(1)
        }
        .barBackgroundColor($r('app.color.tab_bar_bg'))
        .backgroundColor($r('app.color.window_background'))
        .layoutWeight(1)
        .barOverlap(true)
        .barBackgroundColor(Color.Transparent)
        .barBackgroundBlurStyle(BlurStyle.Regular)
        .barPosition(BarPosition.End)
        .barFloatingStyle({
          barBottomMargin: 28,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
          }
        })
        .vertical(false)
        .barMode(BarMode.Fixed)
        .animationDuration(300)
        .onChange((index) => {
          this.tab_bar_index = index;
          // [冷启动优化] 用户首次切换到 Setting Tab 时触发懒加载构建
          if (index === 1 && !this.settingTabInitialized) {
            this.settingTabInitialized = true;
          }
        })
      }
    }
  }
}
