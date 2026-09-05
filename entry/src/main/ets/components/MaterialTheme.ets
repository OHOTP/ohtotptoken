import { MaterialPreference, SettingImmersiveStyle } from 'common';
import { AppStorageV2, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial } from '@kit.UIDesignKit';
import { MaterialPolicy } from '../utils/MaterialPolicy';

/** 只提供材质实参，不包装组件；调用方必须处于官方允许的生效区域。 */
export class MaterialTheme {
  private static materialPref(): MaterialPreference {
    return AppStorageV2.connect(MaterialPreference, () => new MaterialPreference())!;
  }

  /** 按官方组件级兼容方案判断 API，实际材质能力由组件渲染时自适应。
   * 不使用 Ability.onCreate 阶段缓存的材质探测结果否决组件设置。
   */
  static supportsNativeMaterial(): boolean {
    return deviceInfo.sdkApiVersion >= 26;
  }

  static isImmersiveEffective(): boolean {
    return MaterialTheme.materialPref().app_appearance_immersive_enable &&
      MaterialTheme.supportsNativeMaterial();
  }

  /** 仅用于有材质背板的组件及半模态内容，不用于普通内容区卡片。 */
  static surfaceBackground(solidColor: ResourceColor): ResourceColor {
    return MaterialTheme.isImmersiveEffective() ? Color.Transparent : solidColor;
  }

  /** API 23–25 返回 undefined；API 26 关闭必须用 empty，而非恢复默认的 undefined。 */
  static systemMaterial(interactive: boolean = false): SystemUiMaterial | undefined {
    if (!MaterialTheme.supportsNativeMaterial()) {
      return undefined;
    }
    if (!MaterialTheme.isImmersiveEffective()) {
      return uiMaterial.Material.empty;
    }
    return new uiMaterial.ImmersiveMaterial({
      style: MaterialTheme.preferredStyle(),
      colorInvert: true
    });
  }

  private static preferredStyle(): uiMaterial.ImmersiveStyle {
    switch (MaterialTheme.materialPref().app_appearance_immersive_style) {
      case SettingImmersiveStyle.ULTRA_THIN:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      case SettingImmersiveStyle.THIN:
        return uiMaterial.ImmersiveStyle.THIN;
      case SettingImmersiveStyle.THICK:
        return uiMaterial.ImmersiveStyle.THICK;
      case SettingImmersiveStyle.ULTRA_THICK:
        return uiMaterial.ImmersiveStyle.ULTRA_THICK;
      default:
        return uiMaterial.ImmersiveStyle.REGULAR;
    }
  }

  /** HDS 仅提供专属材质接口，不支持 uiMaterial 的五档厚度。性能等级保持自适应。 */
  static hdsMaterialType(): hdsMaterial.MaterialType {
    return MaterialTheme.materialPref().app_appearance_immersive_enable &&
      MaterialPolicy.getInstance().getTier() !== 'solid' ?
      hdsMaterial.MaterialType.IMMERSIVE : hdsMaterial.MaterialType.NONE;
  }

  static dialogSystemMaterial(): SystemUiMaterial | undefined {
    return MaterialTheme.systemMaterial();
  }
}
