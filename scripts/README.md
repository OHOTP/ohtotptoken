# 辅助脚本

## 材质策略回归测试

需要 Node.js ≥ 22.13.0（使用 `node:module` 的 `stripTypeScriptTypes` API）。在仓库根目录运行：

```sh
node --test scripts/material-theme.test.mjs
```

脚本加载生产 `MaterialTheme.ets`，通过 SDK mock 验证材质偏好、低 API 防护及 HDS 等级策略委托。偏好 fixture 应与 `common/src/main/ets/utils/AppPreference.ets` 的 `MaterialPreference` 默认值同步。

该脚本尚未接入 CI/钩子，不替代 Hypium LocalUnit / Quality CI，也不验证设备渲染效果。真机或模拟器上的材质开关、五档厚度、交互光感、菜单/弹窗背板与低版本降级仍需单独验证并补充截图。
