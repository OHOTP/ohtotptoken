# PC / 平板令牌快速切换性能分析

## 结论

卡顿根因不是数据库、OTP 计算或页面转场动画，而是宽屏分栏中每次选择令牌都调用
`NavPathStack.replacePathByName()`，完整销毁并重建一个包含 `HdsNavDestination`、`List`、多个
`TextInput`、材质表面和图标的编辑页。连续点击会让页面创建/销毁任务持续占用 UI 主线程，
帧任务排队，并因短时间大量对象分配触发长耗时 GC。P0 稳定详情页复用已完成，双虚拟机复测确认该根因已消除。

## 测量方法

新增 `TokenSwitchPerf` 分段打点，使用 `systemDateTime.getUptime(TimeType.ACTIVE)` 单调时钟：

1. `click`：点击回调进入。
2. `routeCommitted`：状态修改及 NavPathStack 操作返回。
3. `aboutToAppear`：新编辑页实例开始初始化。
4. `routeReady`：NavDestination 就绪，同时结束 `H:tokenSwitch.routeReady` Trace。
5. `shown`：NavDestination 进入显示状态。
6. `frameIdle`：对应帧渲染任务结束后首次获得空闲时间，作为 UI 真正完成本轮工作的近似指标。

日志只记录请求编号、路由和 Token UUID 后 8 位，不记录名称、账号或密钥。

## 实测数据

PC 与平板分别使用 100 个测试令牌，执行 10 次约 100ms 间隔的连续点击。

| 设备 | 阶段 | 中位数 | P95 / 最大值 |
|---|---:|---:|---:|
| MateBook Pro | `routeCommitted` | 0ms | 1ms |
| MateBook Pro | `routeReady` | 25.5ms | 51ms |
| MateBook Pro | `shown` | 219ms | 310ms |
| MateBook Pro | `frameIdle` | **446.5ms** | **1846ms** |
| MatePad Pro 13 | `routeCommitted` | 1ms | 4ms |
| MatePad Pro 13 | `routeReady` | 35ms | 51ms |
| MatePad Pro 13 | `shown` | 164.5ms | 328ms |
| MatePad Pro 13 | `frameIdle` | **540ms** | **1118ms** |

原始证据位于：

- `.hvigor/pc-100ms-burst.log`
- `.hvigor/pc-100ms-burst-full.log`
- `.hvigor/tablet-100ms-burst.log`
- `.hvigor/tablet-100ms-burst-full.log`
- `.hvigor/token-switch-stats.json`

## P0 优化后对比

使用相同设备、相同 100 个测试令牌、相同 10 次约 100ms 连续点击脚本复测：

| 设备 | 指标 | 优化前 | P0 优化后 | 变化 |
|---|---:|---:|---:|---:|
| MateBook Pro | `frameIdle` 中位数 | 446.5ms | **59ms** | **-86.8%** |
| MateBook Pro | `frameIdle` P95/最大 | 1846ms | **89ms** | **-95.2%** |
| MateBook Pro | 新建 NavDestination | 10 | **0** | -100% |
| MateBook Pro | Jank 超阈值 | 12 | **0** | -100% |
| MateBook Pro | GC | 1 次 / 112.589ms | **0** | -100% |
| MatePad Pro 13 | `frameIdle` 中位数 | 540ms | **59.5ms** | **-89.0%** |
| MatePad Pro 13 | `frameIdle` P95/最大 | 1118ms | **100ms** | **-91.1%** |
| MatePad Pro 13 | 新建 NavDestination | 10 | **0** | -100% |
| MatePad Pro 13 | GC | 3 次 / 94.328、83.267、73.764ms | **0** | -100% |

优化后 `reuseCommitted` 与 `stateApplied` 均为 0~1ms。两端最终详情页 `TextInput` 内容均与最后一次
点击的令牌一致，说明稳定页面的数据切换正确。优化后原始证据：

- `.hvigor/p0-pc-burst.log`
- `.hvigor/p0-pc-burst-full.log`
- `.hvigor/p0-tablet-burst.log`
- `.hvigor/p0-tablet-burst-full.log`
- `.hvigor/p0-token-switch-stats.json`

## 根因证据链

1. 点击处理与路由提交仅 0~4ms，排除点击回调、Token 查找和 NavPathStack API 调用本身。
2. 系统日志每次都输出 `find in nowhere, navigation stack create new node`，10 次点击创建 10 个新
   `AddTotpTokenPage`，NavDestination ID 持续递增。
3. 系统日志明确输出 `animated: 0, isReplace: 1`，且代码传入 `false`，排除默认路由动画。
4. 连续点击时多个 `frameIdle` 回调在同一时间集中执行：PC 最早请求被推迟 1846ms，平板被推迟
   1118ms，说明帧任务被连续的页面替换工作饿死。
5. PC 记录到 12 次 `JankFrameMonitor` 超阈值事件，并出现一次 112.589ms OldGC；平板在约 3 秒内
   出现 94.328ms、83.267ms、73.764ms 三次 GC。对象分配/回收放大了后半段延迟。
6. 编辑页每次重建都会重新创建表单组件、图标、材质节点及 TextInput 相关 UI 节点；这与系统日志中
   每次新建 NavDestination 和 UIExtension 会话一致。

因此，根因是**高频选择事件被实现成重量级页面生命周期切换**，GC 是该设计造成的次生放大因素。

## 修复方案

### P0：宽屏详情页改为稳定实例（已完成）

- 第一次选择时创建一次详情 NavDestination。
- 同一种编辑器类型内切换令牌时，不再 `replacePathByName()`；通过
  `RESPONSIVE_TOKEN_SELECTION_CHANGED` 事件更新现有编辑页的表单状态。
- `ResponsiveTokenEditStore` 保留最新配置与 Trace，避免首个页面尚未创建时快速选择事件丢失。
- 编辑页维护 `activeEditConfig`，确保切换后保存的是当前令牌 UUID 与 RankScore，而不是首次打开的令牌。
- 仅当编辑器类型真的变化（TOTP/HOTP、Forti、Steam）时才替换 NavDestination。
- 手机全屏添加/编辑与 TokenSearchPage 编辑仍使用原有路由参数，不受宽屏复用逻辑影响。

实测已消除同类型切换时 NavDestination、TextInput、材质和图标的整页重建及其 GC 放大效应。

### P1：快速点击采用 latest-wins 合并

如果仍有必须替换页面的跨类型切换，在一帧内只提交最后一次选择：保存最新 UUID，请求下一帧统一
处理，覆盖中间请求。不要让用户已跳过的令牌继续创建完整页面。

### P2：次要热点

- 缓存用户图标路径校验结果，避免编辑页初始化时重复 `fileIo.accessSync()`。
- 用 ArkUI State Profiler 检查 `selectedTokenUUID` 的依赖范围，确保列表选择只刷新旧/新两项；当前
  LazyForEach 使用稳定 key，列表全量 reload 不是本次主因。
- 诊断完成后将 `hilog`/HiTrace 打点限制在 debug 构建或移除，避免 release 高频日志开销。

TaskPool 不适合解决主因：组件创建、状态刷新和布局必须在 UI 主线程执行；应减少工作，而不是尝试把
ArkUI 节点创建迁移到后台线程。

## 验收指标

- 同类型 10 次快速切换不再出现 `navigation stack create new node`。
- PC/平板连续切换 `frameIdle` P95 < 200ms（实测 PC 89ms、平板 100ms）。
- 10 次快速切换期间无 OldGC/YoungGC 长停顿，无 `JankFrameMonitor` 超阈值事件。
- Profiler ArkUI State 显示详情字段精准刷新，不重新创建整个 NavDestination。

## 鸿蒙官方依据

- [Navigation 页面路由](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-navigation-jump)：Replace
  接口用于替换栈顶 NavDestination；Navigation 默认支持转场，本次系统日志已确认动画关闭。
- [Navigation 分栏开发](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-navigation-split-mode)：
  分栏右侧为由 NavPathStack 切换的 NavDestination。
- [主线程耗时操作优化](https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-time-optimization-of-the-main-thread)：
  高频事件和频繁组件生命周期操作应避免重复耗时工作，否则会阻塞 UI 渲染并丢帧。
- [自定义组件复用开发实践](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-component_reuse)：
  频繁创建/销毁对象会增加计算和内存回收开销；复杂组件树反复切换应优先复用。
- [UI 调优](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-inspector-profiler)：可通过 ArkUI State
  泳道查看状态变量触发的组件创建、测量与布局耗时。
