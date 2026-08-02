import { AppPreference, PREF_KEYS, SettingImmersiveStyle, SettingMaterialMode } from 'common';
import { MaterialPolicy, MaterialTier } from '../utils/MaterialPolicy';
import { SETTING_GROUP_RADIUS } from './SettingStyle';

/**
 * 材质厚度档位
 *
 * 与 uiMaterial.ImmersiveStyle 五档一一映射。自定义枚举而非直接暴露
 * uiMaterial.ImmersiveStyle，避免 API 23~25 设备在默认值求值时引用
 * uiMaterial 符号（低 API 设备上该符号不存在）。
 */
export enum MaterialThickness {
  ULTRA_THIN,
  THIN,
  REGULAR,
  THICK,
  ULTRA_THICK
}

/**
 * MaterialTheme — 统一材质模式样式规则（Phase 4.2）
 *
 * 集中定义材质模式下的视觉规则，业务组件不各自判断：
 * - 有效材质档位：MaterialPolicy 设备能力 × SettingMaterialMode 用户偏好
 *   （SOLID 强制实体背景；AUTO/IMMERSIVE 尽力而为，按设备能力三级回退）
 * - 材质模式下表面背景必须为透明（不透明背景会盖住材质层，官方 FAQ 明确）；
 *   solid 模式下的原实体背景色映射由调用方传入（如 SettingItem 的 item_bg）
 * - 圆角档位：接管 SettingStyle 数值（RADIUS_GROUP 即 SETTING_GROUP_RADIUS，
 *   单一数据源，SettingStyle 中预留的对接点注释对应本类）
 * - 边框规则：材质化表面不设 border（材质自带高光描边；borderWidth 会被
 *   systemMaterial 重置为无边框，官方明确）
 * - 阴影规则：材质化表面禁止额外叠 shadow，使用材质自带阴影
 *   （applyShadow 默认 true；需自定义 shadow 时先把 applyShadow 置 false）
 * - 深浅色/反色：依赖 ImmersiveMaterial 自带 colorInvert（薄材质子树自动
 *   反色）。已逐文件 grep colorMode 确认：现有引用均为外观自定义的深浅色
 *   token 颜色（TokenItem/SnackBar/ThemeColorMode），与材质无关，无需删除
 *
 * 注意：读取偏好的方法在运行期调用，组件应在 build 中调用以便
 * EVENT_NAMES.MATERIAL_MODE_CHANGED 广播后重建时取到新值。
 */
export class MaterialTheme {
  /** 材质模式下表面背景色：透明（透出 ImmersiveMaterial 材质层） */
  static readonly MATERIAL_SURFACE_BG: ResourceColor = Color.Transparent;

  /** 分组卡片圆角档位（接管 SettingStyle.ets 数值，单一数据源） */
  static readonly RADIUS_GROUP: number = SETTING_GROUP_RADIUS;

  /**
   * 解析用户材质模式偏好后的有效材质档位
   *
   * @returns SOLID 偏好强制 'solid'；AUTO/IMMERSIVE 返回 MaterialPolicy 设备能力档位
   */
  static effectiveTier(): MaterialTier {
    const mode = AppPreference.getPreference(PREF_KEYS.APPEARANCE_MATERIAL_MODE) as number;
    if (mode === SettingMaterialMode.SOLID) {
      return 'solid';
    }
    // AUTO 与 IMMERSIVE 均为尽力而为：设备支持什么用什么
    //（IMMERSIVE 偏好无法在仅支持 HDS/实体的设备上凭空产生原生材质）
    return MaterialPolicy.getInstance().getTier();
  }

  /**
   * 有效档位是否为原生沉浸材质
   * @returns 可有效使用 ImmersiveMaterial 时返回 true
   */
  static isImmersiveEffective(): boolean {
    return MaterialTheme.effectiveTier() === 'immersive';
  }

  /**
   * 用户偏好的材质厚度（默认 REGULAR）
   * @returns MaterialThickness 档位
   */
  static preferredThickness(): MaterialThickness {
    const style = AppPreference.getPreference(PREF_KEYS.APPEARANCE_IMMERSIVE_STYLE) as number;
    switch (style) {
      case SettingImmersiveStyle.ULTRA_THIN:
        return MaterialThickness.ULTRA_THIN;
      case SettingImmersiveStyle.THIN:
        return MaterialThickness.THIN;
      case SettingImmersiveStyle.THICK:
        return MaterialThickness.THICK;
      case SettingImmersiveStyle.ULTRA_THICK:
        return MaterialThickness.ULTRA_THICK;
      case SettingImmersiveStyle.REGULAR:
      default:
        return MaterialThickness.REGULAR;
    }
  }

  /**
   * 表面背景色映射：材质档位透明，其余档位返回传入的实体背景色
   *
   * @param solidColor solid/hds 档位的实体背景色（如 $r('app.color.item_bg')）
   * @returns 当前有效档位下的表面背景色
   */
  static surfaceBackground(solidColor: ResourceColor): ResourceColor {
    return MaterialTheme.isImmersiveEffective() ? MaterialTheme.MATERIAL_SURFACE_BG : solidColor;
  }

  /**
   * 表面边框宽度规则：材质化表面不设边框（材质自带高光描边，
   * 且 borderWidth 会被 systemMaterial 重置为无边框）
   *
   * @returns 恒为 0
   */
  static surfaceBorderWidth(): number {
    return 0;
  }

  /**
   * 表面阴影规则：材质化表面使用材质自带阴影（applyShadow 默认 true），
   * 禁止额外叠加 shadow；需自定义 shadow 时先把 applyShadow 置 false
   *
   * @returns 材质自带阴影默认开启
   */
  static materialApplyShadow(): boolean {
    return true;
  }
}
