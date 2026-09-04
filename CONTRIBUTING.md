# 贡献指南

感谢你对 OHOTP / OTP Token 的关注！欢迎以任何形式参与本项目：提交 Pull Request、报告 Issue、完善文档或参与讨论。

在开始之前，请**完整阅读本指南**，尤其是 [分支策略](#分支策略) 部分——这是保证 PR 能被顺利合入的关键。

---

## 分支策略

> ⚠️ **最重要的一条：所有 Pull Request 必须提交到 [`dev`](https://github.com/OHOTP/ohtotptoken/tree/dev) 分支，禁止直接提交到 `main`。**

| 分支 | 用途 | 接收提交 |
|------|------|----------|
| `dev` | 日常开发与集成分支 | ✅ 所有功能、修复、重构类 PR |
| `main` | 发布分支，仅包含经过验证的稳定版本 | ❌ 不接收外部 PR，仅由维护者从 `dev` 合入 |

**为什么？**

- `main` 与自动发布流水线（`.github/workflows/build.yaml`）绑定：一旦有 PR 合并进 `main`，CI 会自动构建 HAP 并发布 Release。
- `dev` 用于汇集各方改动，合并前有完整的测试与回归周期，避免不稳定代码直接进入发布版本。
- 直接向 `main` 提 PR 会导致：① 触发非预期的发布；② 与 `dev` 最新进度产生冲突（`dev` 往往领先 `main` 若干提交）；③ 维护者只能关闭并请重新提交。

如果不确定分支是否选对，参考 git 历史：`main` 上的提交几乎全部是 `Merge pull request #xxx ... from .../dev`，这正反映了「dev → main」的单向流动。

---

## 开发环境

| 依赖 | 版本要求 |
|------|----------|
| DevEco Studio | 6.1.1+ |
| HarmonyOS SDK | API 26（`targetSdkVersion: "26.0.0"`） |
| ohpm | 随 DevEco Studio 附带 |

> 本项目已升级到 API 26，部分能力（如 `uiMaterial` 沉浸式材质）依赖 API 26 符号，使用更低版本 SDK 将无法编译。

首次拉取代码后请执行：

```bash
# 安装所有模块依赖
ohpm install --all
```

---

## 工程架构

本项目采用 **三层模块架构**，提交代码前请确认改动落在正确的模块：

```
ohtotptoken/
├── entry/      # 应用入口模块（手机端 Ability、页面、业务编排）
├── common/     # 公共能力层（UI 无关的工具类、模型、加密、存储、云同步）
├── uikit/      # 基础特性层（手机/手表共享的 ArkUI 组件、弹窗、图标资源）
└── wearable/   # 手表端入口模块（独立 HAP）
```

**放置原则：**

- 纯逻辑、无 UI 依赖的工具类 → `common/src/main/ets/utils/`
- 可在手机与手表复用的 UI 组件、Dialog → `uikit/src/main/ets/`
- 仅手机端使用的页面、Ability 编排 → `entry/src/main/ets/`
- 共享图标资源 → `uikit/src/main/resources/rawfile/icons/`

> 在过时的 `entry/src/main/ets/` 下直接新增工具类或共享组件，会与最新架构冲突。提交前请先 `git pull` 获取最新 `dev`。

---

## 测试与 CI 门禁

项目使用 Hypium 作为单元测试框架,单元测试(LocalUnit)在 PC 上运行,无需设备。

### 运行测试

```bash
hvigorw test -p module=entry@default --no-daemon
```

- 测试代码位于 `entry/src/test/`,结果写入 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`,末行 `Tests run: N, Failure: N, ...` 为汇总。
- 注意:`hvigorw test` 在断言失败时构建仍显示成功(退出码 0),请以 `Tests run` 汇总或结果文件为准。
- 依赖系统能力(cryptoFramework、文件、蓝牙等)或原生库(.so)的代码不适用 LocalUnit,这类验证通过 `entry/src/ohosTest/`(需真机/模拟器)进行。

### 编写测试

- 测试文件放在 `entry/src/test/`,命名为 `<被测单元名>.test.ets`,并在 `entry/src/test/List.test.ets` 中注册(测试套名全局唯一)。
- 只通过被测单元的公共 API 断言行为;禁止读取源码/工作流/文档文本做断言。
- 优先使用标准向量(RFC 4226/6238/4648 等);对实现的可疑行为按现状固化并注释,行为变更走独立修复。
- 系统能力在 LocalUnit 中不可用(`url.URL`、`util.TextDecoder`、`util.generateRandomUUID`、`cryptoFramework` 均已验证),相关逻辑应拆分为可独立测试的纯函数。

### CI 门禁

PR 会触发 `Quality` 工作流(GitHub Actions)执行全部 LocalUnit 测试,**检查通过后 PR 才能合并**,解析逻辑见 `.github/workflows/quality.yml`。

---

## 提交规范

本项目遵循 [Conventional Commits](https://www.conventionalcommits.org/) 规范。每个 commit 的 message 格式：

```
<type>(<scope>): <subject>

<可选正文>
```

**type 取值：**

| type | 含义 | 示例 |
|------|------|------|
| `feat` | 新功能 | `feat: 支持从 NFC 读取 OATH 令牌` |
| `fix` | Bug 修复 | `fix(icon): 修复自定义图标按钮阴影截断` |
| `refactor` | 重构（不改变外部行为） | `refactor: 拆分 Index.ets 为 AppShell/HomeTabs` |
| `style` | 格式调整（不改逻辑） | `style: 统一分组列表扁平化设计` |
| `docs` | 文档 | `docs: 完善贡献指南` |
| `chore` | 构建、依赖、配置等杂项 | `chore: 升级版本号至 1.2.6` |

**要点：**
- subject 用简短的祈使句（中文或英文均可，但同一 PR 内保持一致）
- 如修改了具体模块，建议加 `scope`，例如 `fix(icon):`、`feat(nfc):`
- 避免一个 PR 混入多个不相关改动，请拆分为多个 PR

---

## 提交前检查清单

在发起 PR 前，请逐项确认：

- [ ] 已基于**最新 `dev` 分支**创建工作分支（`git checkout dev && git pull upstream dev`）
- [ ] **PR 目标分支（base）选择的是 `dev`**，不是 `main`
- [ ] 本地构建通过：`hvigorw assembleHap` 或在 DevEco Studio 中 Build
- [ ] `hvigorw test` 全绿(`Tests run: N, Failure: 0, Error: 0`)
- [ ] 涉及功能已在真机或模拟器上测试
- [ ] commit message 符合 [提交规范](#提交规范)
- [ ] 没有提交 `build-profile.json5` 的本地签名配置（每位开发者的签名路径不同）
- [ ] 没有提交 IDE 缓存、`.preview/`、`oh_modules/` 等本地产物

---

## Pull Request 流程

1. **Fork & Clone**：Fork 本仓库到自己账号，clone 到本地。
2. **建立上游**（仅需一次）：
   ```bash
   git remote add upstream https://github.com/OHOTP/ohtotptoken.git
   ```
3. **从最新 dev 切分支**：
   ```bash
   git checkout dev
   git pull upstream dev
   git checkout -b feat/your-feature
   ```
4. **开发与提交**：保持每个 commit 聚焦，遵循提交规范。
5. **rebase 检查**（推荐）：开发过程中如有新提交进入 `dev`，及时 rebase 避免冲突：
   ```bash
   git fetch upstream
   git rebase upstream/dev
   ```
6. **推送并发起 PR**：
   - **base repository**: `OHOTP/ohtotptoken`
   - **base branch**: `dev` ← 务必确认
   - **compare branch**: 你 fork 仓库里的工作分支
7. **填写 PR 模板**：按模板描述改动内容、动机，并勾选检查清单。UI 改动请附截图或录屏。
8. **等待 Review**：维护者会在 CODEOWNERS 机制下被自动请求评审，可能提出修改建议。
9. **合并**：通过 review 后由维护者合入 `dev`；下次 `dev → main` 合并时随版本一起发布。

---

## 行为准则

请保持友善、尊重的交流态度。对代码而非个人进行讨论，对新手贡献者给予耐心引导。任何形式的人身攻击、歧视或骚扰行为均不被接受，违反者将被屏蔽。

---

## 联系与讨论

- 💬 [GitHub Discussions](https://github.com/OHOTP/ohtotptoken/discussions)：功能设想、设计讨论、使用提问
- 🐛 [GitHub Issues](https://github.com/OHOTP/ohtotptoken/issues)：Bug 报告、具体功能请求
- 📧 QQ 群：1060812974

再次感谢你的贡献！🎉
