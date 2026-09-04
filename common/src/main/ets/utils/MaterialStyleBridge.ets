/**
 * 将手机端材质开关与厚度传给弹窗、菜单和 Toast 的官方 systemMaterial 接口。
 * 每次调用读取最新偏好；关闭返回 Material.empty，低版本或未注入的手表端
 * 返回 undefined，保留系统默认行为。common 不直接引用 API 26 材质符号。
 */
export type DialogSystemMaterialProvider = () => SystemUiMaterial | undefined;

/** 默认 provider：不传 systemMaterial 字段（保持弹窗默认行为） */
let provider: DialogSystemMaterialProvider = () => undefined;

/**
 * 注入弹窗材质 provider（entry 在 EntryAbility.onCreate 中调用）
 * @param fn 材质实参提供者
 */
export function setDialogSystemMaterialProvider(fn: DialogSystemMaterialProvider): void {
  provider = fn;
}

/**
 * 获取 CustomDialogControllerOptions.systemMaterial 的实参
 * @returns 当前材质档位下弹窗应使用的材质；undefined 表示不传该字段
 */
export function dialogSystemMaterial(): SystemUiMaterial | undefined {
  return provider();
}
