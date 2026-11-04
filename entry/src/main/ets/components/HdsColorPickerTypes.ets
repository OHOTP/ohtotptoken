/**
 * HdsColorPicker 的入参类型与宿主模块形状。
 *
 * 单独成文件的原因：`HdsColorPickerHost.ets` 里静态导入了 `@kit.UIDesignKit`，
 * 该模块在 2in1(PC) 上不导出 `HdsColorPicker`，一旦被静态加载就会抛
 * `SyntaxError: ... does not provide an export name 'HdsColorPicker'` 并杀掉进程；
 * 因此调用方只允许静态依赖本文件（纯数据，无 HMS 依赖），宿主必须动态 import。
 */
export class HdsColorPickerParams {
  color: string = '#00000000';

  onSelected: (selectedColor: string) => void = () => {};
}

/** 动态 import('./HdsColorPickerHost') 的模块形状（显式类型，避免落入 any） */
export interface HdsColorPickerHostModule {
  hdsColorPickerHost: WrappedBuilder<[HdsColorPickerParams]>;
}
