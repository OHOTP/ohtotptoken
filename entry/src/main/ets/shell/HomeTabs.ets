import { TokenConfig, SettingBottomTabsType } from 'common';
import { MaterialPolicy } from '../utils/MaterialPolicy';

import { TokenListPage } from '../pages/TokenListPage';
import { AppWindowInfo } from 'common';
import { PageScaffold } from '../components/PageScaffold';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';

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
  /** 底部页签类型（悬浮/平铺），由 Index 监听 BOTTOM_TABS_TYPE_CHANGED 事件驱动更新 */
  @Require @Param bottomTabsType: SettingBottomTabsType = SettingBottomTabsType.SUSPENSION;
  @Require @Param currentTabIndex: number = 0;
  @Require @Param pageInfos: NavPathStack = new NavPathStack();
  @Require @Param updateTokenConfig: (conf: TokenConfig, toast?: boolean) => Promise<boolean> =
    async (conf: TokenConfig, toast?: boolean) => false;
  @Require @Param updateTokenConfigs: (tokens: Array<TokenConfig>) => Promise<boolean> =
    async (tokens: Array<TokenConfig>) => false;
  @Require @Param tokenListScroller: Scroller = new Scroller();
  @Require @Param settingEntryScroller: Scroller = new Scroller();
  @Param selectedTokenUUID: string = '';
  @Event onSelectToken: (conf: TokenConfig) => void = () => {};
  @Event onTabChange: (index: number) => void = () => {};

  // [冷启动优化] Setting Tab 懒加载标志,仅在用户首次切换到"我的"Tab 时构建组件树
  @Local settingTabInitialized: boolean = false;

  @BuilderParam settingEntryContent?: CustomBuilder = EmptyBuilder;

  /** PC/2in1 与平板不允许用户偏好切换为平铺式。 */
  @Computed
  get effectiveBottomTabsType(): SettingBottomTabsType {
    return this.window.IsPcOrTablet ? SettingBottomTabsType.SUSPENSION : this.bottomTabsType;
  }

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
          pageInfos: this.pageInfos,
          updateTokenConfig: this.updateTokenConfig,
          updateTokenConfigs: this.updateTokenConfigs,
          listScroller: this.tokenListScroller,
          splitSelectionMode: false,
          selectedTokenUUID: this.selectedTokenUUID,
          onSelectToken: (conf: TokenConfig) => this.onSelectToken(conf)
        })
      }
    } else {
      Column() {
        HdsTabs({ index: this.currentTabIndex }) {
          TabContent() {
            TokenListPage({
              Tokens: this.tokens,
              TabBarVisible: !this.window.UseSideNavigation,
              appBottomAvoidHeight: this.window.AvoidBottomHeight,
              appTopAvoidHeight: this.window.AvoidTopHeight,
              appWindowSize: this.window.Size,
              pageInfos: this.pageInfos,
              updateTokenConfig: this.updateTokenConfig,
              updateTokenConfigs: this.updateTokenConfigs,
              listScroller: this.tokenListScroller,
              splitSelectionMode: this.window.AllowSplit,
              selectedTokenUUID: this.selectedTokenUUID,
              onSelectToken: (conf: TokenConfig) => this.onSelectToken(conf)
            })
          }
          .clip(false)
          .backgroundColor($r('app.color.window_background'))
          .tabBar(BottomTabBarStyle.of(
            {
              normal: new SymbolGlyphModifier($r('sys.symbol.key_fill')),
              selected: new SymbolGlyphModifier($r('sys.symbol.key_fill'))
            },
            $r('app.string.tab_token'))
            // 悬浮：56vp 胶囊内居中；平铺：内容区顶对齐 + 4vp 顶部安全间距
            // (设计指南平铺式上下安全间距 4vp)，按钮热区落在 48vp 内容区内，
            // 整体高度向下扩展避让导航条(下方 barHeight)
            .verticalAlign(this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
              VerticalAlign.Center : VerticalAlign.Top)
            .padding(this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
              { left: 4, right: 4, top: 0, bottom: 0 } :
              { left: 4, right: 4, top: 4, bottom: 0 })
          )
          .tabIndex(0)

          TabContent() {
            // [冷启动优化] Setting Tab 懒加载:仅在用户首次切换到"我的"Tab 时构建组件树,
            // 避免冷启动时一次性构建两个 TabContent 导致首帧 build 耗时增加
            if (this.settingTabInitialized && this.settingEntryContent) {
              this.settingEntryContent();
            }
          }
          .clip(false)
          .backgroundColor($r('app.color.window_background'))
          .tabBar(BottomTabBarStyle.of(
            {
              normal: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
              selected: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill_1')),
            },
            $r('app.string.tab_me'))
            // 悬浮：56vp 胶囊内居中；平铺：内容区顶对齐 + 4vp 顶部安全间距
            // (设计指南平铺式上下安全间距 4vp)，按钮热区落在 48vp 内容区内，
            // 整体高度向下扩展避让导航条(下方 barHeight)
            .verticalAlign(this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
              VerticalAlign.Center : VerticalAlign.Top)
            .padding(this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
              { left: 4, right: 4, top: 0, bottom: 0 } :
              { left: 4, right: 4, top: 4, bottom: 0 })
          )
          .tabIndex(1)
        }
        .clip(false)
        .backgroundColor($r('app.color.window_background'))
        .layoutWeight(1)
        .barOverlap(!this.window.UseSideNavigation)
        .barBackgroundColor(Color.Transparent)
        .barBackgroundBlurStyle(this.window.UseSideNavigation ? BlurStyle.NONE : BlurStyle.Regular)
        .barPosition(this.window.UseSideNavigation ? BarPosition.Start : BarPosition.End)
        // 纵向 BottomTabBarStyle 使用官方默认 96vp 侧栏宽度并占满高度；
        // 窄窗口仍使用原底部安全区与悬浮/平铺样式。
        .barHeight(this.window.UseSideNavigation ? '100%' :
          (this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
            56 : 48 + this.window.AvoidBottomHeight))
        .barFloatingStyle(!this.window.UseSideNavigation &&
          this.effectiveBottomTabsType === SettingBottomTabsType.SUSPENSION ?
          {
            barBottomMargin: 28,
            systemMaterialEffect: {
              materialType: hdsMaterial.MaterialType.ADAPTIVE,
              materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
            }
          } : undefined)
        .vertical(this.window.UseSideNavigation)
        // 侧边一级导航仅允许点击页签，避免在内容空白区上下拖动时误切换页面。
        .scrollable(!this.window.UseSideNavigation)
        .barMode(BarMode.Fixed)
        // HDS 的 BottomTabBarStyle 在侧边一级导航下默认不使用内容切换动效，
        // 避免宽屏主内容切换时出现整页缩放/翻页感；窄屏暂时保持现有体验。
        .animationDuration(this.window.UseSideNavigation ? 0 : 300)
        .onChange((index) => {
          this.onTabChange(index);
          // [冷启动优化] 用户首次切换到 Setting Tab 时触发懒加载构建
          if (index === 1 && !this.settingTabInitialized) {
            this.settingTabInitialized = true;
          }
        })
      }
    }
  }
}
