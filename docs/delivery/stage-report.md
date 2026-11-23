# 阶段报告：M1（治理、需求与纯 Dart 架构基线）

计划：[BLINK-M1-01](stage-plan.md#scope)（修订 3，2026-11-22）。本报告按[交接模板](../templates/agent-handoff.md)记录 M1 基线交付证据、工作包与必测用例映射、可逆默认决定及集中审查结论。

<a id="b-delivery"></a>
## 1. B 交付记录（2026-11-20 初版 / 2026-11-22 修订 3 纯 Dart 收敛）

| 信息 | 内容 |
| --- | --- |
| 执行范围 | 按 `BLINK-M1-01`（修订 3）完整交付 `M1-W01～M1-W05` 与必测用例 `M1-K01～M1-K06`，未缩减任何门禁规则或架构契约范围；在保留初版仓库治理与安全红线基础上，完成用户拍板的 **纯 Flutter/Dart 自包含五端架构转型**（单文件夹便携库 `<BLINK_VAULT_DIR>`、BFM v1 文本编辑器、M3 统一多端同步、纯 Dart 净化与双表面高表现力 HTML、外置 AI CLI/MCP/Skills 优先 + 可选端侧直连 OpenAI 兼容接口，见 [DEC-022～DEC-026](../decisions.md#dec-022)）。原 `Q-002` 与 `Q-005` 已由用户拍板收口，剩余 5 项非阻塞取舍按 [USER-ACTIONS](../../USER-ACTIONS.md#decisions) 中的 `Q-001、Q-003、Q-004、Q-006、Q-007` 可逆默认值写入正本 |
| 版本与工作区 | 不可变根提交 `main @ 642e618`（`642e6181df59c9badf647cbb7c99e34414b232e6`，`chore: initialize repository`，含 DCO `Signed-off-by`，树内严格为 0 字节 `README.md`）已于规则集启用前推送至 `origin/main`；当前工作分支为 `feat/m1-project-baseline`，M1 全部新增与更新文件收敛为该分支上的单个 DCO 签名提交（完整提交 SHA 以交接说明与 `git rev-parse HEAD` 为准）；2026-11-22 经 [ACT-001](../../USER-ACTIONS.md#act-001) 授权推送该分支并创建 PR #1，合并等待 [ACT-002](../../USER-ACTIONS.md#act-002) |
| 可运行门禁与配置产物 | 零依赖文档与卫生门禁 `scripts/check_docs.py`（Python 3 标准库实现，仅作仓库 CI 文档治理工具，支持 `--root`、`--ref-dir`、`--no-layout-check`）；GitHub Actions 工作流 `.github/workflows/ci.yml`（固定 40 位 SHA：`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` v7.0.1、`actions/setup-python@6d4fd22b20465ccc0f7354476588e8df7c9ca0e0` v7.1.0，执行 `repository-quality` 检查）；远端 `main-protection` 规则集 ID `27720076`（`active`）及仓库内一致镜像 `.github/{repository-settings.json,rulesets/main.json,actions-policy.json,dependabot.yml,CODEOWNERS,PULL_REQUEST_TEMPLATE.md}`；25 份根级与 `docs/` 正本 Markdown 文档（连同 `.github/PULL_REQUEST_TEMPLATE.md` 全仓共 26 份 Markdown 文档） |
| 关键变更与恢复边界 | 确立 `B·L·I·N·K` 纯 Flutter/Dart 五端本地优先架构（`packages/{blink_sanitizer,blink_core,blink_skills,blink_cli}` + `apps/blink_client`，零容器、零外置数据库、零后端 Python 运行时）：`drift 2.35.4` + `sqlite3 3.9.1` Native Assets 单文件夹便携库 `<BLINK_VAULT_DIR>`、`index/fts.db` CJK 预分词、BFM v1 文本编辑器与 CJK 输入法保护、M3 统一多端同步（桌面内嵌 `shelf` + `bonsoir`/Tailscale + `blink sync serve` 与 `XChaCha20-Poly1305` E2EE WebDAV/S3 异步中继）、纯 Dart Isolate 网页/EPUB/`pdfrx` PDF 伴读、双表面高表现力 HTML 渲染与四层 `#private` 零云端出境硬隔离（`INV-01～INV-13`）。本阶段不含运行期业务代码，不改动宿主机全局工具链或应用安装目录 |

工作包与必测用例映射：

| 工作包 / 用例 | 交付位置 | 实际验证与证据 | 状态与限制 |
| --- | --- | --- | --- |
| `M1-W01` 仓库初始化与远端治理加固（`M1-K01`、`M1-K02`） | `origin/main @ 642e618`；`.gitattributes`、`.gitignore`、`LICENSE`（`Apache-2.0`）；`.github/repository-settings.json`、`.github/rulesets/main.json`、`.github/actions-policy.json`、`.github/CODEOWNERS`、`.github/PULL_REQUEST_TEMPLATE.md`、`.github/dependabot.yml` | `M1-K01`：核验 `642e618` 树对象仅含 0 字节 `README.md`（blob `e69de29bb2d1d6434b8b29ae775ad8c2e48c5391`）且带 DCO 签名，本地配置 `core.autocrlf=false`、`pull.ff=only`、`fetch.prune=true`。`M1-K02`：GitHub REST API 回读确认默认分支 `main`、仅允许 Squash 合并（`PR_TITLE` / `PR_BODY`、`delete_branch_on_merge=true`）、`has_issues=false`、`has_wiki=false`、`has_projects=false`、`has_discussions=true`、Actions 仅放行 `actions/checkout@*` 与 `actions/setup-python@*` 且默认令牌只读、漏洞告警与自动安全更新及密钥推送保护开启、规则集 `main-protection`（ID `27720076`）处于 `active` 且 `bypass_actors=[]`、必过检查为 `repository-quality`（`integration_id: 15368`） | `passed` |
| `M1-W02` 零依赖文档与卫生门禁（`M1-K03`～`M1-K05`） | `scripts/check_docs.py`、`scripts/test_check_docs.py`、`.githooks/pre-push`、`.editorconfig`、`.github/workflows/ci.yml` | 构造正向与反向隔离临时夹具验证：缺必需文件、`CLAUDE.md` 非单行 `@AGENTS.md`、UTF-8 BOM、YAML Frontmatter、非 kebab-case 文件名、参考式链接、断链、缺失 `#anchor`、Windows/Unix 本机绝对路径、敏感密钥串及外部参考/同级仓库名均返回退出码 `1`；门禁代码自身通过动态目录与环境变量扫描，零硬编码外部项目名；2026-11-22 复审将上述反例固化为 `scripts/test_check_docs.py`（28 条，CI 同步执行） | `passed` |
| `M1-W03` 根级治理入口与开发规范（`M1-K03`、`M1-K06`） | `README.md`、`AGENTS.md`、`CLAUDE.md`、`USER-ACTIONS.md`、`CONTRIBUTING.md`、`REVIEW.md`、`SECURITY.md`、`CHANGELOG.md`、`docs/README.md`、`docs/dev-rules/{workflow,engineering,sources-and-safety}.md`、`docs/templates/agent-handoff.md` | 核对 `CLAUDE.md` 精确 11 字节（`@AGENTS.md\n`），`AGENTS.md` 区分仓库开发 Agent A/B 与外置/内置 AI，`engineering.md` 更新为纯 Dart 工具链与 `dart build cli` 基线（M2 唯一核心前置为 Flutter/Dart `>= 3.10`），`sources-and-safety.md` 覆盖 `DEC-026` 弱传染动态链接与四层 `#private` 边界，`USER-ACTIONS.md` 准确维护 `ACT-001/002`、`Q-001/003/004/006/007`（记录 `Q-002`/`Q-005` 已拍板）与 `H-001` | `passed` |
| `M1-W04` 产品需求、五端界面与交付路线（`M1-K04`、`M1-K06`） | `docs/requirements.md`、`docs/ui.md`、`docs/delivery/roadmap.md`、`docs/delivery/status.md`、`docs/delivery/stage-plan.md` | 核对 `B·L·I·N·K` 语义矩阵、7 条硬不变量、明确不做项、`FR-CAP/READ/AGT/TASK/SYNC` 与 `NFR-PLAT/PRIV/DATA/PERF/DEV` 三态表、BFM v1 编辑器与 5 条 CJK 输入法规则、表面 1/2 受控 HTML（`#semantic-html`）令牌、`M1～M6` 路线、MVP/LOOP 表、`AC-01～AC-10`、`LOOP-001..006` 与 `OSS-001..004` 全部显式锚点就位 | `passed` |
| `M1-W05` 决定台账、纯 Dart 选型研究、架构契约与阶段报告（`M1-K03`～`M1-K06`） | `docs/decisions.md`、`docs/research/2026-11-22-pure-dart-pivot.md`、`docs/research/2026-11-20-stack.md`（保留归档并加替代头）、`docs/design/architecture.md`、`docs/design/data-and-sync.md`、`docs/design/agent-and-reader.md`、`docs/delivery/stage-report.md` | 核对 `DEC-001～DEC-026`、2026-11-22 纯 Dart 六维依赖与许可查证（零 GPL/AGPL，显式登记 `DEC-026`）、`SPK-01～SPK-09`、纯 Dart 单仓拓扑与 `INV-01～INV-13`、单文件夹存储与双轨同步、BFM v1 与双表面 HTML 契约、CLI/MCP/Skills 与可选直连 AI 边界，配合全仓 `python -B scripts/check_docs.py` 与 `git diff --check` 复验 | `passed` |

## 2. 阶段开始整理记录

- 本阶段从全新空仓库起步：根提交 `642e618` 严格保持单一 0 字节 `README.md`，无历史遗留阶段标签、废弃脚本或多余构建残留。
- `.gitattributes` 已统一设定文本文件 LF 换行（Windows `.bat`/`.cmd` 除外），`.gitignore` 已前置覆盖 `.local/`、`.env*`（保留 `!.env.example`）、`*.sqlite*`、`*.db*`、`*.pem`、`*.key`、Flutter/Dart 构建缓存及编辑器私有目录。

## 3. 依赖与动作安全基线

- **运行期依赖**：M1 为治理与架构基线阶段，尚未引入 `pubspec.lock`；计划在 `M2～M6` 引入的全部纯 Dart / Flutter 开源依赖已在[纯 Dart 选型研究](../research/2026-11-22-pure-dart-pivot.md#licenses)完成六维与许可证查证，全部满足 MIT / Apache-2.0 / BSD-3-Clause 宽松许可红线（零 GPL/AGPL），Linux 表面 2 所需的系统动态链接库 `libwebkit2gtk-4.1-0` 与 `libsoup-3.0-0`（`LGPL-2.1+` / BSD）已按规则专门登记于 [DEC-026](../decisions.md#dec-026)。M2 锁定 `pubspec.lock` 前将按 `DEC-007` 复核 2026 年 11 月新发小版本的 7 天冷却期。
- **CI 与自动化依赖**：`.github/workflows/ci.yml` 仅引用 `actions/checkout`（`3d3c42e5aac5ba805825da76410c181273ba90b1`，v7.0.1）与 `actions/setup-python`（`6d4fd22b20465ccc0f7354476588e8df7c9ca0e0`，v7.1.0）两个完整 40 位提交 SHA；`.github/dependabot.yml` 已配置每月检查 GitHub Actions 更新并强制执行 **7 天发布冷却期**（`default-days: 7`）与禁用自动变基（`rebase-strategy: disabled`）。`scripts/check_docs.py` 仅调用 Python 3 标准库，零外部供应链风险。

## 4. 可逆默认决定（Q-001、Q-003、Q-004、Q-006、Q-007）

原 `Q-002`（纯 Dart 零容器单文件夹便携库形态）与 `Q-005`（直连与 E2EE 异步中继统一归入 M3 同步阶段）已由用户拍板定案并记入 [DEC-022](../decisions.md#dec-022)、[DEC-023](../decisions.md#dec-023) 与[路线图](roadmap.md#stages)。剩余 5 项非阻塞事项已按可逆默认值写入架构与路线文档，并集中登记在 [USER-ACTIONS](../../USER-ACTIONS.md#decisions)：

1. **`Q-001`（重排与复杂版式 EPUB 渲染边界）**：默认在 M4 由纯 Dart 后台 Isolate 经 `packages/blink_sanitizer` 将主流重排型 EPUB 与网页长文统一转为双轨 Unified Block AST（`.runes` 偏移），交纯 Flutter 原生阅读器五端一致渲染；极少数固定版式画册提供安全降级块与系统外部阅读器打开，可选只读预览层归入 `LOOP-001`。
2. **`Q-003`（双轨 AI 默认分工与配置策略）**：默认以轨道一（外置 AI 经纯 Dart CLI/MCP Server 与 `SKILL.md`，默认 `--scope normal_only`）为主，同时预留轨道二（可选端侧直连 OpenAI 兼容 HTTP 客户端，严格拆分 `normal` 与 `private_local` 配置档，`#private` 物理锁死本机/内网地址且 API Key 仅存本设备系统安全密钥库）。
3. **`Q-004`（开放镜像导出节奏与内容范围）**：默认由桌面端后台 Dart Isolate 按 **5 秒防抖**单向增量原子导出至 `<BLINK_VAULT_DIR>/mirror/`，包含 BFM 确定性降级的纯 UTF-8 `.md` 主归档（M2 先行落地）与 `insights/*.html` 零脚本自适应主题独立综述（M6 补齐），`#private` 单独落入 `0700` `private/` 子树，不反向覆写数据库正本（双向差异导入归入 `LOOP-002`）。
4. **`Q-006`（Linux 表面 2 弱传染系统库动态链接登记 `DEC-026`）**：默认批准 Linux 端表面 2 按需整页 HTML 视图经 Apache-2.0 `desktop_webview_window` 动态链接未修改的宿主机系统库 `libwebkit2gtk-4.1-0` 与 `libsoup-3.0-0`（`LGPL-2.1+`/BSD），配套回环随机端口 HTTP CSP 沙盒、`SPK-06` `#private` 落盘审计与缺库自动降级表面 1。
5. **`Q-007`（MCP 写入面默认权限边界）**：默认导出给第三方 MCP 客户端的配置硬锁 `--scope normal_only` 且仅开放 `ai_*` 派生层写入，`blink_capture_entry`（向原文收件箱只增追加条目）默认关闭，须显式传入 `--allow-capture` 开启。

## 5. not-run 与已知边界

- **产品运行期功能与性能验收（`AC-02～AC-10`）`not-run`**：M1 仅交付治理配置、门禁脚本、需求规范、纯 Dart 选型查证与设计契约；客户端与纯 Dart 共享包业务代码按路线图在 `M2～M6` 实施。
- **宿主机 M2+ 待装工具链 `not-run`**：只读环境核验已确认 `git`、`gh`、`Python 3.12.16`（文档 CI）、VS C++ 桌面编译工具链与 Win11 WebView2 就绪；M2 编码启动前**仅需补装 Flutter / Dart 稳定版 SDK（Dart `>= 3.10`）**，JDK + Android SDK、Tailscale 与 Linux 构建头文件按对应平台与里程碑补齐（[阶段计划 §2](stage-plan.md#baseline)）。
- **GitHub Actions 在线 PR 检查 `not-run`**：远端 `repository-quality` 工作流需等用户授权 [ACT-001](../../USER-ACTIONS.md#act-001) 推送 `feat/m1-project-baseline` 并开启 PR #1 后由 GitHub Actions 触发验证。
- **人工范围与架构复核（`H-001`）`not-run`**：已按非阻塞双轨原则列于 [USER-ACTIONS](../../USER-ACTIONS.md#h-001)，用户可在任意时间审阅反馈。

## 6. 给 A 的集中审查 Prompt

```text
你是 BLINK 的 Agent A，动作：对 M1（治理、需求与纯 Dart 架构基线，修订 3）执行集中技术审查。

- 计划：docs/delivery/stage-plan.md（BLINK-M1-01 修订 3）；报告：docs/delivery/stage-report.md；审查准则：REVIEW.md。
- 分支：feat/m1-project-baseline（基点为不可变根提交 main @ 642e618）。
- 审查重点：
  1. 核对 Git 状态、分支拓扑与根提交 642e618 未被改动，.github/* 声明文件与远端已激活的 main-protection（ID 27720076）及安全策略完全一致；
  2. 实跑 python -B scripts/check_docs.py 与 git diff --check，确认全仓 26 份 Markdown 文档通过布局、链接、锚点与卫生门禁；
  3. 逐篇核对根级治理文件、docs/requirements.md、docs/ui.md、docs/decisions.md（DEC-001～DEC-026）、docs/research/2026-11-22-pure-dart-pivot.md（及 2026-11-20-stack.md 归档头）、docs/design/* 与 docs/delivery/* 的术语、编号（FR/NFR/AC/DEC/INV/Q/H/ACT/LOOP/OSS/SPK）及 M1～M6 路线完全对齐，无旧架构残留表述；
  4. 核对全仓零本机绝对路径、零密钥特征、零同级或外部参考项目名称泄漏。
- 若发现局部问题，直接修复并收敛进当前分支的单个 DCO 提交（git commit --amend -s），更新本报告 §7 审查结论；未经用户授权严禁执行 git push、gh pr create 或 gh pr merge。
```

<a id="a-review"></a>
## 7. A 集中审查结论（2026-11-20 初审 / 2026-11-22 修订 3 纯 Dart 复审）

- **审查基点与范围**：对照 `BLINK-M1-01`（修订 3）、[审查准则](../../REVIEW.md)与 `scripts/check_docs.py` 对 `feat/m1-project-baseline`（父提交 `main @ 642e618`）全仓 26 份 Markdown 文档、四路独立纯 Dart 选型研究证据与 GitHub 远端在线配置执行交叉核验：
  1. 核验 `main @ 642e618` 唯一根提交（0 字节 `README.md` + DCO `Signed-off-by`）未被改动；远端在线配置与 `.github/*` 声明镜像 100% 一致；
  2. 核验 2026-11-22 四路纯 Dart 补充研究全部六维开源与许可证事实（零 GPL/AGPL，独立核实 `archive 4.6.0` 为 MIT、`shelf_router 1.1.5` 为 Apache-2.0、`desktop_webview_window` 正本仓库及 `libwebkit2gtk-4.1-0`/`libsoup-3.0-0` 动态链接登记至 `DEC-026`、`dart build cli` 适配 Native Assets、运行期 `ipc.json` 迁出 `<BLINK_VAULT_DIR>` 至操作系统运行期目录保障零密钥便携库）；
  3. 逐篇交叉核对全部稳定编号域（`DEC-001～026`、`FR-*`、`NFR-*`、`M1～M6`、`AC-01～10`、`INV-01～13`、`Q-001/003/004/006/007`、`ACT-001～002`、`H-001`、`LOOP-001～006`、`OSS-001～004`、`M1-W01～05`、`M1-K01～06`、`SPK-01～09`）并执行全仓 `python -B scripts/check_docs.py`、`git diff --check` 与旧架构残留词项检索。
- **三项独立判定**：
  - **B 实现交付**：`passed`
  - **A 集中技术审查**：`passed`（修订 1/2 累计 `F-001～F-009` 与修订 3 纯 Dart 架构收敛复审 `F-010～F-014` 全部闭环修复，0 未决缺陷）
  - **产品人工验收**：`not-run`（待 [H-001](../../USER-ACTIONS.md#h-001)，不阻塞远端 PR 流程）

审查发现与闭环修复记录（修订 1/2 `F-001～F-009` 与修订 3 `F-010～F-014` 均已关闭）：

| 编号 / 严重度 | 审查发现与跨文档偏差 | 统一规范与修复位置 | 复验与状态 |
| --- | --- | --- | --- |
| `F-001～F-009`（修订 1/2 归档） | 初版与修订 2 基线审查中检出的 9 项跨文档一致性问题（`2 P1 / 7 P2`：凭据边界对齐、开放镜像 5 秒防抖与范围统一、路径占位符一致、`INV-01` 写入边界细化、文档总数核对、`<blink-ref>` 属性名与受控语义类名统一、锚点精确定位与入口文案同步） | 已在 2026-11-20 全部修复关闭，并作为基线口径平滑继承进修订 3 纯 Dart 正本 | 已修复关闭 |
| `F-010` / `P1` | 修订 3 选型查证中，部分研究初稿误将原生资产打包写成单文件命令（在 `sqlite3 3.9.1` Native Assets 下不可用），且将运行期 `ipc.json` 放在 `<BLINK_VAULT_DIR>` 内存在复制库时带出活会话令牌的风险 | 统一规范为 `dart build cli` 输出自带动态库的单一原生工具包，并将 `ipc.json` 迁至 `0600` 权限操作系统运行期目录，保证 `<BLINK_VAULT_DIR>` 零凭据零会话令牌；已同步写入 `architecture.md`、`data-and-sync.md`、`agent-and-reader.md`、`engineering.md`、`SECURITY.md` 与 `2026-11-22-pure-dart-pivot.md` | 跨文档复核与门禁通过；**已修复关闭** |
| `F-011` / `P1` | 许可抽检发现三处上游事实需精确修正：`archive 4.6.0` 实为 MIT、`shelf_router 1.1.5` 实为 Apache-2.0、`desktop_webview_window` 在 Linux 除 `libwebkit2gtk-4.1-0` 外同时动态链接 `libsoup-3.0-0`（同为 `LGPL-2.1+`/BSD） | 已在 `docs/research/2026-11-22-pure-dart-pivot.md`、`docs/decisions.md`（`DEC-026`）、`docs/dev-rules/sources-and-safety.md`、`docs/delivery/status.md` 与 `USER-ACTIONS.md`（`Q-006`）全部精确对齐 | 跨文档复核与门禁通过；**已修复关闭** |
| `F-012` / `P2` | BFM 与双表面受控 HTML 间存在自定义标签归属边界风险（外置 AI 若可输出 `<blink-embed>` 可能触发递归嵌入），且表面枚举名需跨存储、净化与渲染三处一致 | 锁定渲染表面枚举 `surface1_native` / `surface2_sandbox` 与生产者隔离表（`<blink-embed|tag|time>` 仅限用户 BFM，`<blink-grid|card|metric|timeline|compare|chart>` 仅限 AI 表面 1，`<blink-ref|math>` 共用）；已同步至 `data-and-sync.md`、`ui.md`、`agent-and-reader.md` 与 `2026-11-22-pure-dart-pivot.md` | 跨文档复核与门禁通过；**已修复关闭** |
| `F-013` / `P2` | `scripts/check_docs.py` 全仓禁止 YAML Frontmatter，但 M5 规划的 `agentskills.io` `SKILL.md` 规范要求 YAML Frontmatter | 已在 `engineering.md`、`requirements.md`（`NFR-DEV-001`）、`stage-plan.md` 与 `status.md` 明确约定：M1 保持全仓零 Frontmatter，待 M2/M5 落地 `packages/blink_skills/skills/**/SKILL.md` 时仅对该目录新增专用 Frontmatter 模式校验豁免 | 跨文档复核与门禁通过；**已修复关闭** |
| `F-014` / `P2` | 用户拍板将 M2 聚焦于单文件夹库与 BFM v1 编辑器、将直连与 E2EE 中继统一合并为 M3 同步阶段并调整路线为 `M1～M6`，需确保全仓 26 份文档零旧阶段号与旧服务端术语残留 | 已全仓统一升级为 `M1～M6`、`DEC-001～DEC-026`、`SPK-01～SPK-09` 及纯 Dart 架构表述，保留 `DEC-013～DEC-021` 历史原文与 `2026-11-20-stack.md` 归档供追溯 | 跨文档检索与门禁通过；**已修复关闭** |

2026-11-22 框架对照复审（对照本机同类项目的治理骨架与远端配置，逐项回读 GitHub API；新增发现 `F-015～F-018`，均已在本地修复或登记授权）：

| 编号 / 严重度 | 审查发现 | 修复位置 | 复验与状态 |
| --- | --- | --- | --- |
| `F-015` / `P1` | 参考名/同级仓库名拦截的右边界把句点视为名称的一部分，名称后紧跟句末 `.` 时漏报；此前的正反例夹具未入库，无法复现 | `scripts/check_docs.py` 边界改为“`.` 后接标识字符才算延续”；新增 `scripts/test_check_docs.py`（28 条）并接入 CI 与 `.githooks/pre-push` | 回归夹具与全仓门禁通过；**已修复关闭** |
| `F-016` / `P2` | `M1-K03` 要求 LF 行尾，但门禁未检查 CRLF；`.gitignore`、`CODEOWNERS`、hook 等无扩展名文本不在扫描范围 | `scripts/check_docs.py` 增加 CRLF 检查（`.bat`/`.cmd` 例外）与无扩展名文本扫描；新增 `.editorconfig` | 夹具与全仓门禁通过；**已修复关闭** |
| `F-017` / `P2` | 规则集镜像缺少远端回读字段 `require_extra_approval_for_unattributed_changes=true` 与 `required_reviewers=[]`，与“镜像 100% 一致”的结论不符 | `.github/rulesets/main.json` 按 API 回读同步 | 回读一致；**已修复关闭** |
| `F-018` / `P2` | 文档称工作流只允许固定 SHA 的 Action，但远端 `sha_pinning_required=false`，服务端并不强制；`ci.yml` 现有两处 SHA 已与标签核对一致 | 用户授权 [ACT-003](../../USER-ACTIONS.md#act-003) 后远端开启 `sha_pinning_required=true`，同步 `.github/actions-policy.json` 与 `engineering.md` | 远端回读一致；**已修复关闭** |

**下一步建议**：将修订 3（纯 Flutter/Dart 架构收敛、`DEC-022～DEC-026` 与 `M1～M6` 路线）全仓受控改动通过 `git commit --amend -s` 收敛为 `feat/m1-project-baseline` 上的单个 DCO 签名提交，随后请用户在 [USER-ACTIONS](../../USER-ACTIONS.md#authorizations) 审阅并按序授权 `ACT-001`（推送分支并创建 PR #1）与 `ACT-002`（待 `repository-quality` 检查通过后 Squash 合并至 `main`）。
