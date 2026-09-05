import { MaterialTheme } from '../components/MaterialTheme';
import { TokenGroupSidePanel } from '../components/TokenGroupSidePanel';
import { ALL_TOKEN_GROUPS, FAVORITE_TOKEN_GROUP, TokenGroupState, TokenGroupStore, dialogSystemMaterial,
  showSnackBar, SnackBarNotifyType } from 'common';
import { TokenGroupNameDialog } from '../dialogs/TokenGroupNameDialog';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { HdsNavDestination, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, hdsMaterial, HdsSideBar, BottomBuilderShowType } from '@kit.UIDesignKit';
import { AppWindowInfo, ROUTE_NAMES } from 'common';
// [冷启动优化] 以下 NavDestination 页面仅在用户导航时触发评估
import lazy { TokenCardConfigPage } from '../pages/TokenCardConfigPage'
import lazy { WatchSyncPage } from '../pages/WatchSyncPage'
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
import lazy { SheetCoordinator } from './SheetCoordinator';
import { AddTokenPageParams } from '../components/AddTokenForm';
import { TokenConfig } from 'common';
import { ComponentContent } from '@kit.ArkUI';

/** 宽屏主页纵向页签使用 HdsTabs 默认的 96vp 宽度。 */
const HOME_SIDE_TAB_WIDTH: number = 96;
/** 分栏模式下令牌列表内容需要保留的最低可用宽度。 */
const TOKEN_LIST_MIN_CONTENT_WIDTH: number = 320;
/** PC 侧栏最多为令牌列表提供 3 个 400vp lane 的宽度。 */
const PC_TOKEN_LIST_MAX_CONTENT_WIDTH: number = 1200;
/** 手机/平板沿用原导航栏最大宽度。 */
const DEFAULT_NAV_BAR_MAX_WIDTH: number = 560;

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
 * 根 HdsNavigation 骨架:窗口与业务场景驱动的 Stack/Split、NavDestination 路由注册、
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
  @Local groupState: TokenGroupState = TokenGroupStore.getInstance().state;
  @Event onSelectGroup: (id: string) => void = () => {};
  @Param groupSidebarOpen: boolean = false;
  @Param tokenTitleCollapse: number = 0;
  @Event $groupSidebarOpen: (open: boolean) => void = () => {};
  @Require @Param window: AppWindowInfo = new AppWindowInfo();
  @Require @Param businessSplitEnabled: boolean = true;
  @Require @Param tokenListScroller: Scroller = new Scroller();
  @Require @Param settingEntryScroller: Scroller = new Scroller();
  @Require @Param openAddTokenMenu: () => void = () => {};
  @Require @Param addTokenMenuTargetId: string = '';
  @Require @Param openTokenSortMenu: () => void = () => {};
  @Require @Param sortTokenMenuTargetId: string = '';
  @Event onOpenFullScreenRoute: (name: ROUTE_NAMES, param: Object | null) => void = () => {};
  @Event onExitFullScreenRoute: () => void = () => {};
  @Event onCloseResponsiveTokenEdit: () => void = () => {};
  @Event onNavBarVisible: () => void = () => {};
  @Event onNavigationModeChange: (mode: NavigationMode) => void = () => {};
  /** 文件拖放回调(由 Index 提供,控制 DropFilesDialog) */
  @Require @Param onDropFile: () => void = () => {};
  @Require @Param onDragEnterFile: () => void = () => {};
  @Require @Param onDragLeaveFile: () => void = () => {};
  /** 独立添加令牌页面共用的持久化入口，由 Index 注入 */
  @Require @Param saveToken: (conf: TokenConfig) => Promise<boolean> = async () => false;
  @Require @Param tokens: TokenConfig[] = [];
  @Require @Param backupReload: (conf: TokenConfig[]) => Promise<void> = async () => {};
  @Event addTestTokens: () => Promise<boolean> = async () => false;
  @Event removeTestTokens: () => Promise<boolean> = async () => false;

  @BuilderParam appLockContent?: CustomBuilder = EmptyBuilder;
  @BuilderParam homeContent?: CustomBuilder = EmptyBuilder;

  private splitPlaceholder: ComponentContent<Object> =
    new ComponentContent(this.getUIContext(), wrapBuilder(TokenSplitPlaceholder));

  @Computed
  get canShowGroupSidebar(): boolean {
    return this.currentHomeTabIndex === 0 && this.businessSplitEnabled && !this.isLoading && !this.applockVisible;
  }

  @Computed
  get embedGroupSidebar(): boolean {
    // 为纵向页签、令牌列表及详情区保留空间，不在已有分栏中强塞侧栏。
    return this.window.WidthVp >= (this.window.AllowSplit ? 1440 : 840);
  }

  @Computed
  get fixedNavBarWidth(): number {
    const contentWidth = this.window.WidthVp -
      (this.embedGroupSidebar && this.canShowGroupSidebar && this.groupSidebarOpen ? 240 : 0);
    const maxWidth = this.window.IsPc ?
      HOME_SIDE_TAB_WIDTH + PC_TOKEN_LIST_MAX_CONTENT_WIDTH : DEFAULT_NAV_BAR_MAX_WIDTH;
    return Math.min(Math.max(0, contentWidth - 300), maxWidth,
      Math.max(HOME_SIDE_TAB_WIDTH + TOKEN_LIST_MIN_CONTENT_WIDTH,
        contentWidth * (this.window.WidthVp < 1200 ? 0.5 : 0.36)));
  }

  @Computed
  get tokenGroupTitle(): ResourceStr {
    if (this.groupState.selectedId === ALL_TOKEN_GROUPS) {
      return $r('app.string.tab_token');
    }
    if (this.groupState.selectedId === FAVORITE_TOKEN_GROUP) {
      return $r('app.string.token_group_favorites');
    }
    return this.groupState.groups.find(group => group.id === this.groupState.selectedId)?.name ??
      $r('app.string.token_group_ungrouped');
  }

  @Monitor('canShowGroupSidebar', 'embedGroupSidebar')
  onSidebarLayoutChange(): void {
    this.$groupSidebarOpen(this.canShowGroupSidebar && this.embedGroupSidebar);
  }

  aboutToAppear(): void {
    this.$groupSidebarOpen(this.canShowGroupSidebar && this.embedGroupSidebar);
  }

  @LocalBuilder
  TokenTitleBuilder() {
    Text(this.tokenGroupTitle)
      .id('token_group_title')
      .fontSize(35 - 5 * this.tokenTitleCollapse)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('sys.color.font_primary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .height(56 - 8 * this.tokenTitleCollapse)
      .padding({ left: this.window.WidthVp < 600 ? 16 : this.window.WidthVp < 840 ? 24 : 32,
        right: this.window.WidthVp < 600 ? 16 : this.window.WidthVp < 840 ? 24 : 32 })
  }

  @LocalBuilder
  NewGroupDialogBuilder() {
    TokenGroupNameDialog()
  }

  private openNewGroupDialog(): void {
    this.getUIContext().getPromptAction().openCustomDialog({
      systemMaterial: dialogSystemMaterial(),
      builder: () => this.NewGroupDialogBuilder(),
      autoCancel: false,
      alignment: DialogAlignment.Center
    }).catch(() => {
      showSnackBar($r('app.string.token_group_error'), SnackBarNotifyType.ERROR);
    });
  }

  @LocalBuilder
  GroupSidePanelBuilder() {
    Column() {
      TokenGroupSidePanel({
        tokens: this.tokens,
        onAdd: () => this.openNewGroupDialog(),
        onSelect: (id: string) => {
          this.onSelectGroup(id);
          if (!this.embedGroupSidebar) {
            this.$groupSidebarOpen(false);
          }
        }
      })
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: this.window.AvoidBottomHeight })
  }

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
      TokenCardConfigPage({ scrollEffectType: this.scrollEffectType })

    } else if (name === ROUTE_NAMES.TokenSortPage) {
      TokenSortPage({
        scrollEffectType: this.scrollEffectType,
        onExitFullScreen: () => this.onExitFullScreenRoute()
      })
    } else if (name === ROUTE_NAMES.TokenSearchPage) {
      TokenSearchPage({
        scrollEffectType: this.scrollEffectType,
        onExitFullScreen: () => this.onExitFullScreenRoute()
      })
    } else if (name === ROUTE_NAMES.AddTotpTokenPage) {
      AddTotpTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf),
        onExitFullScreen: () => this.onExitFullScreenRoute(),
        onBackToPlaceholder: () => this.onCloseResponsiveTokenEdit()
      })
    } else if (name === ROUTE_NAMES.AddFortiTokenPage) {
      AddFortiTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf),
        onExitFullScreen: () => this.onExitFullScreenRoute(),
        onBackToPlaceholder: () => this.onCloseResponsiveTokenEdit()
      })
    } else if (name === ROUTE_NAMES.AddSteamTokenPage) {
      AddSteamTokenPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as AddTokenPageParams,
        saveToken: (conf: TokenConfig) => this.saveToken(conf),
        onExitFullScreen: () => this.onExitFullScreenRoute(),
        onBackToPlaceholder: () => this.onCloseResponsiveTokenEdit()
      })
    } else if (name === ROUTE_NAMES.IconPickerPage) {
      IconPickerPage({
        scrollEffectType: this.scrollEffectType,
        pageParams: param as IconPickerPageParams
      })
    } else if (name === ROUTE_NAMES.WatchSyncPage) {
      WatchSyncPage({ scrollEffectType: this.scrollEffectType })
    } else if (name.startsWith('setting/')) {
      HdsNavDestination() {
        SheetCoordinator({
          tokens: this.tokens,
          scrollEffectType: this.scrollEffectType,
          scroller: this.settingEntryScroller,
          bottomAvoidHeight: this.window.AvoidBottomHeight,
          wideMode: this.window.AllowSplit,
          active: true,
          pageInfos: this.pageInfos,
          selectedRoute: name as ROUTE_NAMES,
          detailOnlyRoute: name,
          backupReload: this.backupReload,
          addTestTokens: () => this.addTestTokens(),
          removeTestTokens: () => this.removeTestTokens()
        })
      }
      .clip(false)
      .hideTitleBar(true)
      .backgroundColor($r('app.color.window_background'))
    }
  }

  @LocalBuilder
  NavigationBuilder() {
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
    }
    .backgroundColor($r('app.color.window_background'))
    .width('100%')
    .height('100%')
    .hideTitleBar(this.isLoading)
    .mode(this.window.AllowSplit && (this.currentHomeTabIndex === 1 || this.businessSplitEnabled) ?
      NavigationMode.Split : NavigationMode.Stack)
    // lg 的三段式布局先保证主列表可用宽度，超宽窗口再收敛为约 1:2。
    .navBarWidth(this.fixedNavBarWidth)
    // 上下限相同，禁止通过分割线调宽；窗口变化时仍按原比例自适应。
    .navBarWidthRange({
      minWidth: this.fixedNavBarWidth,
      maxWidth: this.fixedNavBarWidth
    })
    .minContentWidth(300)
    .enableDragBar(false)
    .splitPlaceholder(this.splitPlaceholder)
    .onNavBarStateChange((isVisible: boolean) => {
      if (isVisible) {
        this.onNavBarVisible();
      }
    })
    .onNavigationModeChange((mode: NavigationMode) => {
      this.onNavigationModeChange(mode);
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
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary'),
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            },
            menuStyle: {
              iconColor: $r('sys.color.icon_primary'),
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            },
          }
        },
        scrollEffectStyle: {
          contentStyle: {
            backIconStyle: {
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            },
            menuStyle: {
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            }
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: this.scrollEffectType
        },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: MaterialTheme.hdsMaterialLevel()
        }
      },
      content: {
        title: this.currentHomeTabIndex === 0 ? undefined : { mainTitle: $r('app.string.tab_me') },
        bottomBuilder: this.currentHomeTabIndex === 0 ? {
          builder: (): void => this.TokenTitleBuilder(),
          height: 56 - 8 * this.tokenTitleCollapse,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        } : undefined,
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
            },
            {
              content: {
                label: $r('app.string.menu_token_actions'),
                icon: $r('sys.symbol.dot_grid_2x2'),
                isEnabled: true,
                componentId: this.sortTokenMenuTargetId,
                action: () => {
                  this.openTokenSortMenu();
                }
              }
            }
          ] : []
        }
      }
    })
  }

  /** 与侧边栏同级，仅用原生标题栏承载固定开关，保留 HDS 光感材质。 */
  @LocalBuilder
  SidebarTitleBarBuilder() {
    HdsNavigation() {
    }
    .width(96)
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .mode(NavigationMode.Stack)
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .hideToolBar(true)
    .backgroundColor(Color.Transparent)
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          contentStyle: {
            backIconStyle: {
              iconColor: $r('sys.color.icon_primary'),
              backgroundColor: MaterialTheme.hdsMaterialType() === hdsMaterial.MaterialType.NONE ?
                $r('sys.color.comp_background_gray') : undefined
            }
          }
        },
        scrollEffectOpts: { enableScrollEffect: false },
        systemMaterialEffect: {
          materialType: MaterialTheme.hdsMaterialType(),
          materialLevel: MaterialTheme.hdsMaterialLevel()
        }
      },
      content: {
        backIcon: {
          icon: this.groupSidebarOpen ? $r('sys.symbol.open_sidebar') : $r('sys.symbol.close_sidebar'),
          label: this.groupSidebarOpen ? $r('app.string.token_group_close_sidebar') :
            $r('app.string.token_group_open_sidebar'),
          componentId: 'token_group_sidebar_toggle',
          action: () => this.$groupSidebarOpen(!this.groupSidebarOpen)
        }
      }
    })
    .zIndex(1)
  }

  @LocalBuilder
  SidebarBuilder() {
    HdsSideBar({
      sideBarPanelBuilder: (): void => this.GroupSidePanelBuilder(),
      contentPanelBuilder: (): void => this.NavigationBuilder(),
      isShowSideBar: this.canShowGroupSidebar && this.groupSidebarOpen,
      $isShowSideBar: (open: boolean) => this.$groupSidebarOpen(open),
      onChange: (open: boolean) => {
        if (open !== this.groupSidebarOpen) {
          this.$groupSidebarOpen(open);
        }
      },
      sideBarContainerType: this.embedGroupSidebar ? SideBarContainerType.Embed : SideBarContainerType.Overlay,
      sideBarWidth: this.embedGroupSidebar ? 240 : Math.min(380, this.window.WidthVp * 0.78),
      minSideBarWidth: this.embedGroupSidebar ? 240 : Math.min(380, this.window.WidthVp * 0.78),
      maxSideBarWidth: this.embedGroupSidebar ? 240 : Math.min(380, this.window.WidthVp * 0.78),
      autoHide: false,
      minContentWidth: this.embedGroupSidebar ?
        HOME_SIDE_TAB_WIDTH + TOKEN_LIST_MIN_CONTENT_WIDTH + 300 : Math.min(360, this.window.WidthVp),
      contentAreaMask: true,
      scaleContentEnabled: false,
      swipeEnabled: this.canShowGroupSidebar && !this.embedGroupSidebar,
      isSideBarBlur: MaterialTheme.hdsMaterialType() !== hdsMaterial.MaterialType.NONE,
      sideBarColor: $r('app.color.window_background'),
      contentColor: $r('app.color.window_background')
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.SidebarBuilder()
      if (this.canShowGroupSidebar) {
        this.SidebarTitleBarBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .foregroundBlurStyle((this.blurFlag || this.applockVisible) ? BlurStyle.Thin : BlurStyle.NONE, {
      colorMode: ThemeColorMode.SYSTEM,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    .bindContentCover(this.applockVisible, this.appLockContent ? this.appLockContent() : null, {
      modalTransition: ModalTransition.NONE,
      onWillDismiss: (dismissContentCoverAction: DismissContentCoverAction) => {
      },
    })
  }
}
