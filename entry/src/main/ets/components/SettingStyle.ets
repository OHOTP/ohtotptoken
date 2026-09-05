/**
 * SettingStyle — 设置分组列表的统一设计规范
 *
 * 统一分组列表的设计数值：普通卡片圆角使用系统 16vp Token、行内边距 16/14、0.5px 系统分隔线
 * （左缩进 16 与文字对齐）、页面级左右留白 16。
 * SettingItem 与 SubItem* 系列统一从这里取值，避免数值散落各处。
 *
 * 分组容器是唯一的卡片背景层，子项保持透明，避免叠加背景。
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
