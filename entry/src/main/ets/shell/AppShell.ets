import { uniformTypeDescriptor } from '@kit.ArkData';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';
import { AppWindowInfo, ROUTE_NAMES } from 'common';
import { MaterialPolicy } from '../utils/MaterialPolicy';
// [冷启动优化] 以下 NavDestination 页面仅在用户导航时触发评估
import lazy { TokenCardConfigPage } from '../pages/TokenCardConfigPage'
import lazy { TokenSortPage } from '../pages/TokenSortPage'
import lazy { TokenSearchPage } from '../pages/TokenSearchPage'
import lazy { ShowDataSyncDetailsPage } from '../pages/ShowDataSyncDetailsPage';
import lazy { ShowCloudSyncDetailsPage } from '../pages/ShowCloudSyncDetailsPage';
import lazy { ShowCloudBackupHistoryPage } from '../pages/ShowCloudBackupHistoryPage';
import lazy { ShowCodePage } from '../pages/ShowCodePage';
// [冷启动优化] WebPage 导入 @kit.ArkWeb (libwebview_napi.z.so ~10ms)，延迟到用户实际访问网页时
import lazy { WebPage, WebPageParams } from '../pages/WebPage';
import lazy { AddTotpTokenPage } from '../pages/AddTotpTokenPage';
import lazy { AddFortiTokenPage } from '../pages/AddFortiTokenPage';
import lazy { AddSteamTokenPage } from '../pages/AddSteamTokenPage';
import lazy { IconPickerPage, IconPickerPageParams } from '../pages/IconPickerPage';
import { AddTokenPageParams } from '../components/AddTokenForm';
import { TokenConfig } from 'common';
import { ComponentContent } from '@kit.ArkUI';

@Builder
function EmptyBuilder() {
}

@Builder
function TokenSplitPlaceholder() {
  Column({ space: 12 }) {
    SymbolGlyph($r('sys.symbol.square_and_pencil'))
      .fontSize(52)
      .fontColor([$r('sys.color.icon_secondary')])
    Text($r('app.string.responsive_token_placeholder_title'))
      .fontSize(22)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .textAlign(TextAlign.Center)
    Text($r('app.string.responsive_token_placeholder_description'))
      .fontSize(14)
      .fontColor($r('sys.color.font_secondary'))
      .textAlign(TextAlign.Center)
  }
  .padding(32)
  .width('100%')
  .height('100%')
  .justifyContent(FlexAlign.Center)
  .backgroundColor($r('app.color.window_background'))
}

/**
 * 应用外壳(Task 3.1)
 *
 * 根 HdsNavigation 骨架:窗口级导航(强制 Stack)、NavDestination 路由注册、
 * 全局 Loading 遮罩、文件拖入导入(allowDrop/onDragEnter)、
 * 安全模糊(后台模糊 + 应用锁)与 AppLockOverlay 全屏覆盖。
 * 主页内容通过 homeContent 注入(HomeTabs),应用锁覆盖层通过 appLockContent 注入。
 */
@ComponentV2
export struct AppShell {
  @Require @Param pageInfos: NavPathStack = new NavPathStack();
  @Require @Param isLoading: boolean = true;
  /** 后台模糊标志(安全设置开启且窗口 PAUSED 时为 true) */
  @Require @Param blurFlag: boolean = false;
  /** 应用锁覆盖层是否可见(单向即可,关闭由覆盖层 onUnlock 回调驱动) */
  @Require @Param applockVisible: boolean = false;
  /** 顶部滚动效果类型(传递给各 NavDestination 页面并配置主页标题栏) */
  @Require @Param scrollEffectType: ScrollEffectType = ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  @Require @Param currentHomeTabIndex: number = 0;
  @Require @Param window: AppWindowInfo = new AppWindowInfo();
  @Require @Param businessSplitEnabled: boolean = true;
  @Require @Param tokenListScroller: Scroller = new Scroller();
  @Require @Param settingEntryScroller: Scroller = new Scroller();
  @Require @Param openAddTokenMenu: () => void = () => {};
  @Require @Param addTokenMenuTargetId: string = '';
  @Event onOpenFullScreenRoute: (name: ROUTE_NAMES, param: Object | null) => void = () => {};
  @Event onNavBarVisible: () => void = () => {};
  /** 文件拖放回调(由 Index 提供,控制 DropFilesDialog) */
  @Require @Param onDropFile: () => void = () => {};
  @Require @Param onDragEnterFile: () => void = () => {};
  @Require @Param onDragLeaveFile: () => void = () => {};
  /** 独立添加令牌页面共用的持久化入口，由 Index 注入 */
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;

  @BuilderParam appLockContent?: CustomBuilder = EmptyBuilder;
  @BuilderParam homeContent?: CustomBuilder = EmptyBuilder;

  private splitPlaceholder: ComponentContent<Object> =
    new ComponentContent(this.getUIContext(), wrapBuilder(TokenSplitPlaceholder));

  @LocalBuilder
  navDestinationBuilder(name: string, param: Object) {
    if (name === ROUTE_NAMES.ShowDataSyncDetailsPage) {
      ShowDataSyncDetailsPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCloudSyncDetailsPage) {
      ShowCloudSyncDetailsPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCloudBackupHistoryPage) {
      ShowCloudBackupHistoryPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.ShowCodePage) {
      ShowCodePage()
    } else if (name === ROUTE_NAMES.WebPage) {
      WebPage({ scrollEffectType: this.scrollEffectType, pageParams: param as WebPageParams })
    } else if (name === ROUTE_NAMES.TokenCardConfigPage) {
      TokenCardConfigPage()
    } else if (name === ROUTE_NAMES.TokenSortPage) {
      TokenSortPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.TokenSearchPage) {
      TokenSearchPage({ scrollEffectType: this.scrollEffectType })
    } else if (name === ROUTE_NAMES.AddTotpTokenPage) {
      AddTotpTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf)
      })
    } else if (name === ROUTE_NAMES.AddFortiTokenPage) {
      AddFortiTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf)
      })
    } else if (name === ROUTE_NAMES.AddSteamTokenPage) {
      AddSteamTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf)
      })
    } else if (name === ROUTE_NAMES.IconPickerPage) {
      IconPickerPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as IconPickerPageParams
      })
    }
  }

  build() {
    HdsNavigation(this.pageInfos) {
      Stack() {
        if (this.isLoading) {
          Column() {
            LoadingProgress()
              .color(Color.White)
              .width(80).height(80)
            Text('Loading..')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .width('100%')
          .height('100%')
          .backgroundColor('#40000000')
          .justifyContent(FlexAlign.Center)
        } else {
          if (this.homeContent) {
            this.homeContent();
          }
        }
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .allowDrop([uniformTypeDescriptor.UniformDataType.FILE])
      .onDrop(() => {
        this.onDropFile();
      })
      .onDragEnter(() => {
        this.onDragEnterFile();
      })
      .onDragLeave(() => {
        this.onDragLeaveFile();
      })
      .foregroundBlurStyle((this.blurFlag || this.applockVisible) ? BlurStyle.Thin : BlurStyle.NONE, {
        colorMode: ThemeColorMode.SYSTEM,
        adaptiveColor: AdaptiveColor.DEFAULT
      })
    }
    .backgroundColor($r('app.color.window_background'))
    .hideTitleBar(this.isLoading)
    .mode(this.window.AllowSplit && this.currentHomeTabIndex === 0 && this.businessSplitEnabled ?
      NavigationMode.Split : NavigationMode.Stack)
    .navBarWidth(this.window.WidthVp < 840 ? '50%' : '36%')
    .navBarWidthRange({ minWidth: 320, maxWidth: 560 })
    .minContentWidth(300)
    .enableDragBar(this.window.AllowSplit && this.currentHomeTabIndex === 0 && this.businessSplitEnabled)
    .splitPlaceholder(this.splitPlaceholder)
    .onNavBarStateChange((isVisible: boolean) => {
      if (isVisible) {
        this.onNavBarVisible();
      }
    })
    .navDestination(this.navDestinationBuilder)
    .bindToScrollable([
      this.currentHomeTabIndex === 0 ? this.tokenListScroller : this.settingEntryScroller
    ])
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
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: MaterialPolicy.getInstance().getHdsAdaptiveMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: this.currentHomeTabIndex === 0 ?
            $r('app.string.tab_token') : $r('app.string.tab_me'),
        },
        menu: {
          value: this.currentHomeTabIndex === 0 ? [
            {
              content: {
                label: $r('app.string.app_ua_search_token'),
                icon: $r('sys.symbol.magnifyingglass'),
                isEnabled: true,
                action: () => {
                  this.onOpenFullScreenRoute(ROUTE_NAMES.TokenSearchPage, null);
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
          ] : []
        }
      }
    })
    .bindContentCover(this.applockVisible, this.appLockContent ? this.appLockContent() : null, {
      modalTransition: ModalTransition.NONE,
      onWillDismiss: (dismissContentCoverAction: DismissContentCoverAction) => {
      },
    })
  }
}
