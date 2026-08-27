import { window } from '@kit.ArkUI';

/** 官方一多页面布局的 lg 断点：从此宽度开始使用左侧一级导航。 */
export const RESPONSIVE_SIDE_NAV_MIN_WIDTH_VP: number = 840;
/** 三段式“一级导航 + 主列表 + 详情”需要 lg 宽度，避免 md 窗口内容过窄。 */
export const RESPONSIVE_SPLIT_MIN_WIDTH_VP: number = 840;
export const RESPONSIVE_SPLIT_MAX_ASPECT_RATIO: number = 1.2;

/** 窗口尺寸对应的响应式布局决策。 */
export class ResponsiveLayoutState {
  widthVp: number = 0;
  heightVp: number = 0;
  heightToWidthRatio: number = 0;
  useSideNavigation: boolean = false;
  allowSplit: boolean = false;
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
    // 一级导航位置只取决于横向断点；业务分栏还需满足宽高比，二者不能共用同一布尔值。
    state.useSideNavigation = state.widthVp >= RESPONSIVE_SIDE_NAV_MIN_WIDTH_VP;
    state.allowSplit = state.widthVp >= RESPONSIVE_SPLIT_MIN_WIDTH_VP &&
      state.heightToWidthRatio < RESPONSIVE_SPLIT_MAX_ASPECT_RATIO;
    return state;
  }
}
