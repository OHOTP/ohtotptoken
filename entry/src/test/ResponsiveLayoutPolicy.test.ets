import { describe, it, expect } from '@ohos/hypium';
import {
  RESPONSIVE_SIDE_NAV_MIN_WIDTH_VP,
  RESPONSIVE_SPLIT_MAX_ASPECT_RATIO,
  RESPONSIVE_SPLIT_MIN_WIDTH_VP,
  ResponsiveLayoutPolicy,
  ResponsiveLayoutState,
} from 'common';

/**
 * 响应式布局断点决策测试（纯 vp 数值入口 resolveVp）。
 * 一级导航只看横向断点；业务分栏还需宽高比 < 1.2，二者独立判定。
 */
export default function responsiveLayoutPolicyTest() {
  describe('responsiveLayoutPolicyTest', () => {
    it('breakpoint_constants_match_official_lg_threshold', 0, () => {
      expect(RESPONSIVE_SIDE_NAV_MIN_WIDTH_VP).assertEqual(840);
      expect(RESPONSIVE_SPLIT_MIN_WIDTH_VP).assertEqual(840);
      expect(RESPONSIVE_SPLIT_MAX_ASPECT_RATIO).assertEqual(1.2);
    });

    it('phone_portrait_uses_neither_side_nav_nor_split', 0, () => {
      const state = ResponsiveLayoutPolicy.resolveVp(360, 780);
      expect(state.widthVp).assertEqual(360);
      expect(state.heightVp).assertEqual(780);
      expect(state.useSideNavigation).assertFalse();
      expect(state.allowSplit).assertFalse();
      expect(state.heightToWidthRatio > 2).assertTrue();
    });

    it('side_nav_starts_exactly_at_lg_breakpoint', 0, () => {
      expect(ResponsiveLayoutPolicy.resolveVp(839.9, 900).useSideNavigation).assertFalse();
      expect(ResponsiveLayoutPolicy.resolveVp(840, 900).useSideNavigation).assertTrue();
      expect(ResponsiveLayoutPolicy.resolveVp(1024, 600).useSideNavigation).assertTrue();
    });

    it('split_requires_friendly_aspect_ratio', 0, () => {
      // 达到 lg 但太“瘦高”（比例 ≥ 1.2）→ 不允许分栏
      const tall = ResponsiveLayoutPolicy.resolveVp(840, 1100);
      expect(tall.useSideNavigation).assertTrue();
      expect(tall.allowSplit).assertFalse();

      // 比例 1.071 < 1.2 → 允许
      const wide = ResponsiveLayoutPolicy.resolveVp(840, 900);
      expect(wide.allowSplit).assertTrue();

      // 边界：比例恰为 1.2 → 不允许（严格小于）
      const boundary = ResponsiveLayoutPolicy.resolveVp(1000, 1200);
      expect(boundary.allowSplit).assertFalse();

      // 窄窗口即使比例友好也不分栏
      const narrow = ResponsiveLayoutPolicy.resolveVp(600, 600);
      expect(narrow.allowSplit).assertFalse();
    });

    it('zero_width_avoids_division_by_zero', 0, () => {
      const state: ResponsiveLayoutState = ResponsiveLayoutPolicy.resolveVp(0, 500);
      expect(state.heightToWidthRatio).assertEqual(0);
      expect(state.useSideNavigation).assertFalse();
      expect(state.allowSplit).assertFalse();
    });
  });
}
