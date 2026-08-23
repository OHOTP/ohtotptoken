import { window } from '@kit.ArkUI';

/** 官方一多页面布局建议的单双栏判断阈值。 */
export const RESPONSIVE_SPLIT_MIN_WIDTH_VP: number = 600;
export const RESPONSIVE_SPLIT_MAX_ASPECT_RATIO: number = 1.2;

/** 窗口尺寸对应的响应式布局决策。 */
export class ResponsiveLayoutState {
  widthVp: number = 0;
  heightVp: number = 0;
  heightToWidthRatio: number = 0;
  useSideNavigation: boolean = false;
  allowSplit: boolean = false;
  navigationMode: NavigationMode = NavigationMode.Stack;
}

/**
 * 将物理像素窗口尺寸统一转换为 vp 后计算布局，避免组件各自复制断点逻辑。
 */
export class ResponsiveLayoutPolicy {
  static resolve(uiContext: UIContext, size: window.Size): ResponsiveLayoutState {
    const state = new ResponsiveLayoutState();
    state.widthVp = uiContext.px2vp(size.width);
    state.heightVp = uiContext.px2vp(size.height);
    state.heightToWidthRatio = state.widthVp > 0 ? state.heightVp / state.widthVp : 0;
    state.allowSplit = state.widthVp >= RESPONSIVE_SPLIT_MIN_WIDTH_VP &&
      state.heightToWidthRatio <= RESPONSIVE_SPLIT_MAX_ASPECT_RATIO;
    state.useSideNavigation = state.allowSplit;
    state.navigationMode = state.allowSplit ? NavigationMode.Split : NavigationMode.Stack;
    return state;
  }
}
