/**
 * 弹窗背板材质桥（Phase 5.5）
 *
 * CustomDialogControllerOptions.systemMaterial（API 26 新增）的统一实参入口。
 * API 26 上自定义弹窗背板默认即为 ULTRA_THICK ImmersiveMaterial，无需显式设置；
 * 本桥存在的意义是把"用户材质模式偏好"传递到 uikit/wearable 等无法直接依赖
 * entry 侧 MaterialTheme 的模块：
 * - entry 在启动时注入 provider（MaterialTheme.dialogSystemMaterial）：
 *   用户 SOLID 偏好且设备支持原生材质时返回 uiMaterial.Material.empty
 *   （官方推荐的单独关闭某组件材质的方式），其余情况返回 undefined
 *   （undefined 与弹窗默认材质一致，即保持 ULTRA_THICK 材质）
 * - 手表等未注入环境默认返回 undefined，不触碰任何 API 26 符号
 *
 * 与 SnackBar.ets 相同的运行时注入端口模式：common 只持有函数指针，
 * 具体材质策略（MaterialPolicy × 用户偏好）由 entry 实现并注入。
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
