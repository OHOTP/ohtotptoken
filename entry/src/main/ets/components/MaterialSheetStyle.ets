import { MaterialTheme } from './MaterialTheme';

/** 半模态通过官方 SheetOptions.systemMaterial 应用当前开关与厚度。 */
export class MaterialSheetStyle {
  static options(detent: SheetSize = SheetSize.LARGE): SheetOptions {
    return {
      detents: [detent],
      preferType: SheetType.BOTTOM,
      dragBar: true,
      backgroundColor: MaterialTheme.surfaceBackground($r('app.color.window_background')),
      systemMaterial: MaterialTheme.systemMaterial()
    };
  }
}
