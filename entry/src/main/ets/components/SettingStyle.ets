/**
 * SettingStyle — 设置分组列表的统一设计规范
 *
 * 统一分组列表的设计数值：普通卡片圆角使用系统 16vp Token、行内边距 16/14、0.5px 系统分隔线
 * （左缩进 16 与文字对齐）、页面级左右留白 16。
 * SettingItem 与 SubItem* 系列统一从这里取值，避免数值散落各处。
 *
 * 材质化契约（Phase 4.2 MaterialTheme / Phase 3 MaterialSurface 的对接点）：
 * - 分组容器（SettingItem）是分组列表唯一的不透明背景层，SubItem* 子项背景
 *   必须保持透明 —— 不透明子背景会盖住 ImmersiveMaterial 材质层（官方 FAQ 明确）
 * - 分组卡片不使用阴影，阴影与材质表面视觉冲突
 * - 后续 MaterialTheme 将接管本文件的数值，并补充材质模式下的背景/边框映射
 */
export const SETTING_GROUP_RADIUS: Length = $r('sys.float.corner_radius_level8');

export const SETTING_ROW_PADDING: Padding = { left: 16, right: 16, top: 14, bottom: 14 };

/**
 * 行最小高度，取官方 UX 规范效率型列表单行档 56vp（通用高度档：48/56/64/72/96）。
 * 高度按内容分档而非完全等高：无副标题的单行补齐到 56 档（内容垂直居中）；
 * 带副标题的行内容高约 73vp，自然落入官方双行 72 档，不做强制约束。
 */
export const SETTING_ROW_MIN_HEIGHT: number = 56;

export const SETTING_PAGE_INSET: number = 16;

export const SETTING_DIVIDER_INSET_LEFT: number = 16;

export const SETTING_DIVIDER_INSET_RIGHT: number = 16;

export const SETTING_TITLE_INSET_LEFT: number = 16;

export const SETTING_TITLE_INSET_VERTICAL: number = 8;
