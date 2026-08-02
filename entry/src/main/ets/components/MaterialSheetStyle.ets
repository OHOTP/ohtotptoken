import { uiMaterial } from '@kit.ArkUI';
import { MaterialTheme, MaterialThickness } from './MaterialTheme';

/**
 * MaterialSheetStyle — MaterialAware 半模态配置工厂（Phase 3.2）
 *
 * 统一 8 个 bindSheet 的 SheetOptions（高度档位 / preferType / dragBar /
 * 背景与材质），消除 SheetCoordinator 中重复散落的 options 字面量。
 *
 * 按 MaterialTheme.effectiveTier()（设备能力 × 用户材质模式偏好）分档：
 * - immersive：SheetOptions.systemMaterial（API 26 新增）设 ImmersiveMaterial，
 *   背板 backgroundColor 必须透明 —— 不透明背板会盖住材质层
 *   （官方半模态示例10：systemMaterial + backgroundColor: Color.Transparent）
 * - hds / solid：不设置材质与背板色，保持 API 26 之前的既有表现
 *
 * 材质化契约（与 MaterialSurface 相同，官方性能规则）：
 * 1. 设置了 systemMaterial 的 Sheet 不再叠加 borderWidth/borderColor/shadow/
 *    blurStyle（官方明确不建议与 systemMaterial 同用；材质自带模糊与阴影）
 * 2. Sheet 内容根节点背景须透明才能透出材质；当前各 Sheet 内容根仍刷
 *    window_background 实体色，材质被遮盖但表现与之前一致，透明度清理
 *    在 Phase 5.4 统一处理
 * 3. 材质参数一次性确定，勿在 Sheet 显示期间频繁变更
 */
export class MaterialSheetStyle {
  /**
   * 底部半模态统一配置
   *
   * @param detent 高度档位，默认 SheetSize.LARGE（账号 Sheet 用 MEDIUM）
   * @param thickness Sheet 材质厚度，默认 ULTRA_THICK（官方半模态材质示例档位）。
   *   使用自定义 MaterialThickness 枚举而非 uiMaterial.ImmersiveStyle，
   *   避免低 API 设备在默认参数求值时引用 uiMaterial 符号
   * @returns 按当前材质档位生成的 SheetOptions
   */
  static options(detent: SheetSize = SheetSize.LARGE,
    thickness: MaterialThickness = MaterialThickness.ULTRA_THICK): SheetOptions {
    if (MaterialTheme.isImmersiveEffective()) {
      return {
        detents: [detent],
        preferType: SheetType.BOTTOM,
        dragBar: true,
        backgroundColor: Color.Transparent,
        systemMaterial: MaterialSheetStyle.createSheetMaterial(thickness)
      };
    }
    return {
      detents: [detent],
      preferType: SheetType.BOTTOM,
      dragBar: true
    };
  }

  /**
   * 构造 Sheet 材质对象。仅在 immersive 档位（API >= 26）调用；
   * 异常时返回 undefined（清除材质），保证 Sheet 可用。
   */
  private static createSheetMaterial(thickness: MaterialThickness): SystemUiMaterial | undefined {
    try {
      return new uiMaterial.ImmersiveMaterial({
        style: MaterialSheetStyle.mapThickness(thickness)
      });
    } catch (e) {
      return undefined;
    }
  }

  /** MaterialThickness → uiMaterial.ImmersiveStyle（仅 immersive 档位调用） */
  private static mapThickness(thickness: MaterialThickness): uiMaterial.ImmersiveStyle {
    switch (thickness) {
      case MaterialThickness.ULTRA_THIN:
        return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      case MaterialThickness.THIN:
        return uiMaterial.ImmersiveStyle.THIN;
      case MaterialThickness.REGULAR:
        return uiMaterial.ImmersiveStyle.REGULAR;
      case MaterialThickness.THICK:
        return uiMaterial.ImmersiveStyle.THICK;
      case MaterialThickness.ULTRA_THICK:
      default:
        return uiMaterial.ImmersiveStyle.ULTRA_THICK;
    }
  }
}
