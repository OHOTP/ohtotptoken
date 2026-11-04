import { HdsColorPicker } from '@kit.UIDesignKit';
import { HdsColorPickerParams } from './HdsColorPickerTypes';

/**
 * HdsColorPicker 宿主（**只能动态 import**）。
 *
 * `@kit.UIDesignKit` 的 `HdsColorPicker` 仅有 phone / tablet 导出（见 SDK
 * `hms/ets/api/device-define/api-version/UIDesignKit.json` 的 deviceTypes），
 * 2in1(PC) 上该模块缺少这个导出：静态导入会在模块求值阶段抛
 * `SyntaxError: ... does not provide an export name 'HdsColorPicker'` 并直接杀进程。
 *
 * 所以本文件不要被任何文件静态 import —— 调用方（SubItemColor）按设备类型
 * 动态 `import('./HdsColorPickerHost')`，失败则回退到 ColorSelectDialog。
 */
@Builder
export function hdsColorPickerHostBuilder(params: HdsColorPickerParams) {
  Row() {
    HdsColorPicker({
      initialColor: params.color,
      options: { circleRadius: 16 },
      onColorSelected: (selectedColor: string) => {
        params.onSelected(selectedColor);
      }
    })
  }
  .constraintSize({ minWidth: 48, minHeight: 48 })
  .justifyContent(FlexAlign.Center)
  .alignItems(VerticalAlign.Center)
}

/** 供动态 import 后取用的 WrappedBuilder */
export const hdsColorPickerHost: WrappedBuilder<[HdsColorPickerParams]> =
  wrapBuilder(hdsColorPickerHostBuilder);
