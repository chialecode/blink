# 用户待办

核对日期：2026-11-22。

这里集中列出需要你本人处理的全部事项：待你授权的远端或外部操作（`ACT-*`）、待你决定的产品与技术取舍（`Q-*`，每项均写明 Agent 当前采用的可逆默认值），以及人工检查（`H-*`）。Agent 的日常开发不等这一页：未回复的非阻塞决定继续按默认值推进，未执行的人工检查保持 `not-run`、绝不冒充通过。只有列在[阻塞项](#blockers)里的事项才会让 Agent 暂停依赖它的部分。

**怎么回复**：直接在对话里按编号说明即可，例如“授权 ACT-001”“ACT-001、ACT-002 都授权”“Q-001 按推荐”“H-001 已看，通过”。规则见[用户交互规则](docs/dev-rules/workflow.md#user-actions)。

<a id="recommended"></a>
## 推荐你做的

当前处于 **M1（治理、需求与纯 Dart 架构基线，修订 3）**：远端初始根提交（`642e618`）与 `main-protection` 保护规则集已就绪并回读核实；分支 `feat/m1-project-baseline` 已完成纯 Flutter/Dart 五端架构收敛（零容器、零外置数据库、零后端 Python 运行时，单文件夹便携库、BFM v1、M3 统一多端同步、双表面高表现力 HTML、外置 AI CLI/MCP/Skills + 可选内置直连 OpenAI 兼容接口，见[当前计划](docs/delivery/stage-plan.md#scope)与[阶段报告](docs/delivery/stage-report.md#b-delivery)）。

| 顺序 | 事项 | 需要你做什么 | 暂时不做会怎样 |
| --- | --- | --- | --- |
| 1 | [ACT-002](#act-002)：在 `repository-quality` 通过后 squash 合并 PR #1 | 回复“授权 ACT-002” | PR #1 保持打开，M2 若先开工将基于 `feat/m1-project-baseline` 继续 |
| 2 | 本机参考索引尚未建立：已在本机索引目录的 `PROPOSALS.md` 提议登记两个本机治理框架参考项目 | 看一眼提议，同意后回复“参考索引按提议建立” | 参考名泄漏拦截只靠同级仓库目录名，规划时无索引可查 |
| 3 | [H-001](#h-001)：审阅 M1 纯 Dart 产品范围、`FR`/`NFR` 基线与 `M1～M6` 路线 | 按步骤浏览核心正本并反馈要调整的边界 | 保持 `not-run`，不阻塞 PR #1 合并或 M2 启动 |
| 4 | [Q-001](#q-001)、[Q-003](#q-003)、[Q-004](#q-004)、[Q-006](#q-006)、[Q-007](#q-007)：五项非阻塞技术与产品默认做法确认 | 回复“按推荐”或指出要改的条目 | 后续阶段持续按当前推荐的可逆默认值实现 |

<a id="blockers"></a>
## 阻塞项

目前没有。一件事要同时满足两个条件才算阻塞项：缺少你的决定会改变核心数据含义、隐私授权范围或造成不可逆结果；且 Agent 无法先用可逆的默认方案隔离推进。

<a id="authorizations"></a>
## 待你授权的操作

<a id="act-001"></a>
### ACT-001：推送 `feat/m1-project-baseline` 到 `origin` 并创建 PR #1（已完成：2026-11-22 授权并执行）

- **现状与前提**：远端 `chialecode/blink` 的 `main` 分支已有不可变初始根提交 `642e618`，`main-protection` 规则集已生效；本地分支 `feat/m1-project-baseline` 将全部 M1 治理、需求、纯 Dart 选型与架构基线收敛为单个带 DCO 签名的提交，并通过本地 `python scripts/check_docs.py` 与 `git diff --check`。
- **授权后 Agent 做什么**：
  1. 执行 `git push -u origin feat/m1-project-baseline`（仅推送该分支）。
  2. 创建指向 `main` 的 PR #1（标题与正文按 `.github/PULL_REQUEST_TEMPLATE.md` 结构填写，覆盖 M1 治理、需求与纯 Dart 架构基线），查看一次远端 `repository-quality` 状态检查结果。
- **不包括**：合并 PR #1（见 [ACT-002](#act-002)）、创建发布标签或修改远端仓库设置。

<a id="act-002"></a>
### ACT-002：在 CI 通过后 Squash 合并 PR #1 到 `main`（待授权）

- **前提**：[ACT-001](#act-001) 已完成，PR #1 上的必需检查 `repository-quality` 已通过，且无未解决的评审讨论。
- **授权后 Agent 做什么**：
  1. 按 `main-protection` 规则将 PR #1 以 squash 方式合并入 `main`（远端自动清理已合并的 `feat/m1-project-baseline` 分支）。
  2. 本地切回 `main` 执行 `git pull --ff-only` 与 `git fetch --prune`，核对 `main` 线性历史（根提交 + M1 单提交）后汇报最新 SHA。
- **不包括**：创建 `v0.1.*` 发行标签或发布安装包。

<a id="act-003"></a>
### ACT-003：开启远端 Actions「必须固定完整 SHA」强制开关（已完成：2026-11-22 授权并执行）

- **结果**：远端 `sha_pinning_required=true` 已回读确认，白名单仍为 `actions/checkout@*`、`actions/setup-python@*` 且 `github_owned_allowed=false`（设置开关的接口会顺带把 `github_owned_allowed` 置为 `true`，已立即改回并回读）；镜像 [`.github/actions-policy.json`](.github/actions-policy.json) 已同步。授权前远端为 `false`，服务端不拒绝未固定 SHA 的工作流。
- **授权后 Agent 做什么**：
  1. 调用 GitHub API 将仓库 Actions 权限设为 `enabled=true`、`allowed_actions=selected`、`sha_pinning_required=true`（白名单保持 `actions/checkout@*`、`actions/setup-python@*` 不变）。
  2. 回读确认后，把 [`.github/actions-policy.json`](.github/actions-policy.json) 镜像改为 `true`，收敛进当前阶段的单个提交。
- **不包括**：调整白名单、令牌权限或其他仓库设置。随时可用同一 API 改回 `false`。

<a id="decisions"></a>
## 待你决定的事

> 已拍板收口项：原 `Q-002`（采用零容器、零外置数据库、零后端 Python 的纯 Dart 五端架构与单文件夹便携库 `<BLINK_VAULT_DIR>`）与原 `Q-005`（将直连局域网/Tailscale 同步与客户端端到端加密 WebDAV/S3 异步中继统一归入独立同步阶段 M3）均已由用户拍板定案，分别写入 [DEC-022](docs/decisions.md#dec-022)、[DEC-023](docs/decisions.md#dec-023) 与[路线图 M3](docs/delivery/roadmap.md#stages)，不再重复列为待决项。

<a id="q-001"></a>
### Q-001：EPUB 复杂版式回退策略（当前按推荐默认值规划）

- **要决定什么**：流式 EPUB 之外的复杂 CSS 固定版式或内嵌脚本类电子书，在 M4 阅读器阶段如何处理。
- **当前默认（推荐）**：M4 采用纯 Dart 后台 Isolate 解析的统一结构化块 AST（Unified Block AST，双轨并存归一化纯文本 `plain_text` 与经纯 Dart `packages/blink_sanitizer` 净化的受控语义 HTML `html_sanitized`，以 `.runes` Unicode 码点偏移锚定）配合五端一致的 Flutter 原生阅读器（`super_sliver_list` + `flutter_widget_from_html_core` + `SelectableRegion`）渲染流式 EPUB 与清洗后网页长文（[阅读与采集管线](docs/design/agent-and-reader.md#reader-pipeline)），原生保留跨行列合并表格、提示框、上下标与注音排版；重度固定版式 EPUB 的沙盒只读预览回退延后记入 [LOOP-001](docs/delivery/status.md#loop)，遇到强固定版式页面时在界面如实提示并提供调用系统外部阅读器打开原文件。
- **可选**：在 M4 同步为固定版式 EPUB 接入表面 2 沙盒只读视图（需额外维护固定版式坐标与块级选区两套锚定契约，显著增加 M4 复杂度）。
- **推荐时机**：M4 启动前回复即可；未回复前保持默认。

<a id="q-003"></a>
### Q-003：双轨 AI 模式与默认配置策略（当前按推荐默认值规划）

- **要决定什么**：在无内置服务端前提下，外置 AI（CLI/MCP/Skills）与可选端侧直连 OpenAI 兼容接口的默认启用分工。
- **当前默认（推荐）**：采用“外置 AI 优先 + 可选端侧直连”双轨设计（[DEC-025](docs/decisions.md#dec-025)）——日常重度综述、回响、书摘整理与高表现力 HTML 卡片/整页产出优先由外部 AI 代理通过 BLINK 纯 Dart CLI / MCP Server（默认 `--scope normal_only`）与内置 `SKILL.md` 完成；同时在应用内预留轻量的可选直连 `OpenAiCompatClient`（`dio` + SSE，零后端服务），按 `normal` 与 `private_local` 严格双配置档隔离（`#private` 条目与伴读提问强制锁死本机或内网地址，API Key 仅存本设备原生安全密钥库，对话转存笔记遵循 `INV-01`）。
- **可选**：彻底关闭应用内直连 AI 入口（100% 仅保留外置 CLI/MCP/Skills），或全局强制仅允许连接本机/内网本地模型网关。
- **推荐时机**：M5 启动前回复即可；未回复前保持默认。

<a id="q-004"></a>
### Q-004：开放镜像仓（BFM 降级 `.md` 主归档 + 双表面 `insights/*.html`）导出节奏（当前按推荐默认值规划）

- **要决定什么**：桌面端将便携库数据导出为 `<BLINK_VAULT_DIR>/mirror/` 开放镜像目录的触发频率、文件形态与方向。
- **当前默认（推荐）**：由桌面端后台 Dart Isolate 执行单向、**5 秒防抖**增量原子导出——M2 先落地原文层的纯 UTF-8 `.md` 主归档（将 BFM v1 扩展按确定性规则无损降级为 10 年可读标准 Markdown，覆盖闪念、日记、待办、书籍/长文正文与伴读高亮批注），M6 补全 `insights/` 子目录下零脚本、零外链、自适应日/纸/夜主题的独立静态 `.html` 综述与高表现力整页镜像；`#private` 内容单独归入 `0700` 权限 `private/` 子树；全程单向原子写出，不反向监听外部文件覆写数据库正本（双向差异导入归入 [LOOP-002](docs/delivery/status.md#loop)，设计见[开放镜像](docs/design/data-and-sync.md#sync)）。
- **可选**：仅导出纯 `.md` 文件（不生成 `insights/*.html` 伴生富视图），或改为每日手动/定时批量导出一次。
- **推荐时机**：M2 落地基础镜像或 M6 补全富视图镜像前回复即可；未回复前保持默认。

<a id="q-006"></a>
### Q-006：Linux 表面 2 整页 HTML 视图系统弱传染库动态链接登记（当前按推荐默认值规划）

- **要决定什么**：Linux 桌面端表面 2（按需整页高表现力 HTML 视图）是否采用系统动态链接方式调用宿主机自带 WebKitGTK 4.1 引擎。
- **当前默认（推荐）**：批准 [DEC-026](docs/decisions.md#dec-026)——Linux 端通过 Apache-2.0 许可的 `desktop_webview_window` 动态链接宿主机未修改的系统库 `libwebkit2gtk-4.1-0` 与 `libsoup-3.0-0`（`LGPL-2.1+` / BSD，绝不静态链接、绝不修改源码），经 `127.0.0.1` 随机端口一次性令牌回环服务下发严格 HTTP CSP `default-src 'none'; script-src 'none'` 与 `Cache-Control: no-store`，并在 M5 `SPK-06` 执行 `#private` 落盘审计（若有残留则 Linux 私密视图退回纯 Flutter 表面 1）；宿主机缺库时自动优雅降级为纯 Flutter 表面 1 渲染，绝不崩溃。
- **可选**：Linux 端彻底不引入系统 WebView 动态链接，表面 2 整页 HTML 视图在 Linux 上统一呈现纯 Flutter 表面 1 降级视图并提供“用系统默认浏览器打开本地镜像 `.html`”。
- **推荐时机**：M5 启动前回复即可；未回复前保持默认。

<a id="q-007"></a>
### Q-007：MCP 写入面默认权限边界（当前按推荐默认值规划）

- **要决定什么**：外部 AI 代理通过 BLINK MCP Server 连接时，是否默认允许其直接向原文收件箱追加新条目（`blink_capture_entry`）。
- **当前默认（推荐）**：默认关闭 `blink_capture_entry`，MCP 默认仅开放只读查询（受 `--scope normal_only` 硬隔离）与 `ai_*` 派生层写入（标签、回响、待办候选、双表面 HTML 卡片/整页与原则候选），严格守住 `INV-01`；仅当用户在配置中显式追加 `--allow-capture` 标志时才放行只增不改的收件箱捕获工具，且一键导出的第三方 MCP 客户端配置恒定锁定 `--scope normal_only`。
- **可选**：默认开启只增不改的 `blink_capture_entry` 工具，方便外部 AI 代理直接帮用户记录新闪念。
- **推荐时机**：M5 启动前回复即可；未回复前保持默认。

<a id="human-checks"></a>
## 人工检查

<a id="h-001"></a>
### H-001：审阅 M1 纯 Dart 产品范围、`FR`/`NFR` 基线与 `M1～M6` 架构路线（not-run）

- **适用基线**：分支 `feat/m1-project-baseline`（M1 修订 3 纯 Dart 治理、需求与架构基线阶段，尚无运行时安装包；自 M2 产出桌面客户端起，Agent 会在交接前自动将最新 `blink-dev` 静默更新并常驻到本机托盘）。
- **检查步骤与预期**：
  1. 阅读[需求文档](docs/requirements.md#product)与[有效决定 DEC-022～DEC-026](docs/decisions.md#dec-022)：核对 `B·L·I·N·K` 命名语义矩阵、核心产品不变量（原文层不可篡改、单文件夹便携库零明文密钥、`#private` 四层零云端出境、内生柔性待办）、BFM v1 扩展语法、双表面高表现力 HTML 与双轨无服务端 AI 边界是否准确表达长期诉求。
  2. 阅读[纯 Dart 技术选型研究](docs/research/2026-11-22-pure-dart-pivot.md#overview)与[系统架构](docs/design/architecture.md#topology)：核对“纯 Flutter/Dart 五端应用（零容器、零外置数据库、零后端 Python 运行时）+ `<BLINK_VAULT_DIR>` 单文件夹便携库 + M3 统一多端同步（直连 `shelf` 与 E2EE WebDAV/S3）+ `dart build cli` 统一 CLI/MCP/无头同步工具包”路线，以及严格宽松许可与 `DEC-026` 弱传染动态链接登记边界。
  3. 阅读[界面规范](docs/ui.md#layout)（含[双表面受控 HTML 规范](docs/ui.md#semantic-html)）与[路线与验收](docs/delivery/roadmap.md#stages)：核对 BFM v1 文本编辑器与 CJK 输入法保护、桌面分栏伴读、移动端底部瞬时采集流、表面 1 原生组件标签与表面 2 沙盒整页 HTML 交互，以及 `M1～M6`（M2 便携库与编辑器先行、M3 全方案同步、M4 伴读、M5 双表面 HTML 与双轨 AI、M6 语音/视觉采集与性能打包）的阶段切分是否合理。
