# 当前阶段计划：M1（治理、需求与纯 Dart 架构基线）

- **阶段编号**：M1；计划标识 `BLINK-M1-01`，修订 3（2026-11-22）。
- **角色**：A 规划与现场核验；B 连续实施与门禁自检；A 集中技术审查（[开发流程](../dev-rules/workflow.md#agent-handoff)）。给 Agent B 的可复制交接 Prompt 见[第 9 节](#prompt)。
- **分支**：`feat/m1-project-baseline`，基于 `origin/main` 不可变根提交 `642e618`（完整哈希 `642e6181df59c9badf647cbb7c99e34414b232e6`）创建。本阶段全部工程配置、门禁脚本、治理与纯 Dart 架构正本文档及审查修正均收敛为该分支上的**单个 DCO 签名提交**（`feat(m1): ...`）。
- **决定与需求**：[有效决定 DEC-001～DEC-026](../decisions.md#governance)；产品需求基线 `FR-CAP`、`FR-READ`、`FR-AGT`、`FR-TASK`、`FR-SYNC` 与本阶段落地的治理类非功能需求 `NFR-PRIV-003`、`NFR-DEV-001`、`NFR-DEV-002`（[需求](../requirements.md#scope)）；验收场景 [AC-01](roadmap.md#acceptance)；架构不变量 `INV-01～INV-13`（[系统架构](../design/architecture.md#invariants)）；可逆默认决策 [Q-001、Q-003、Q-004、Q-006、Q-007](../../USER-ACTIONS.md#decisions)（原 `Q-002` 与 `Q-005` 已由用户拍板记入 `DEC-022`、`DEC-023` 与 M3）；人工复核 [H-001](../../USER-ACTIONS.md#human-checks)；远端动作授权 [ACT-001、ACT-002](../../USER-ACTIONS.md#authorizations)。

<a id="scope"></a>
## 1. 范围与退出条件

| 项目 | 约定 |
| --- | --- |
| 阶段内容 | 建立仓库不可变根提交与本地 Git 规范（`M1-W01`）；完成 GitHub 远端安全策略与 `main-protection` 规则集加固并落盘 `.github/*` 镜像（`M1-W01`）；实现零依赖文档、链接锚点与公开内容卫生门禁 `scripts/check_docs.py` 及 CI 工作流（`M1-W02`）；编写根级治理入口、宿主工具链工程基线与 `USER-ACTIONS.md`（`M1-W03`）；建立 `B·L·I·N·K` 需求基线、BFM v1 与双表面受控 HTML 界面规范及 `M1～M6` 路线状态（`M1-W04`）；完成 2026-11-22 纯 Dart 六维开源技术栈查证（保留 2026-11-20 初版归档）、有效决定台账（`DEC-001～DEC-026`）、三份核心架构设计契约（含 `INV-01～INV-13` 与 `SPK-01～SPK-09`）及 M1 阶段报告（`M1-W05`） |
| 不在本阶段 | 纯 Dart 共享核心包（`packages/{blink_sanitizer,blink_core,blink_skills,blink_cli}`）、Flutter 五端客户端代码（`apps/blink_client/`）、数据库迁移实现、宿主缺失 Flutter/Dart SDK 安装与五端安装包构建（全部按[路线图](roadmap.md#stages)自 M2 起分阶段实施） |
| 可连续执行 | 本地文档与门禁脚本编写、只读宿主工具链核验、正反向隔离夹具自测、全仓链接与锚点完整性校验、路径与参考源零泄漏扫描、本地单提交组装与 `--amend -s` 收敛 |
| 外部操作与授权 | 不可变根提交 `642e618` 与远端 `main-protection` 规则集已在建仓初始化时完成并回读确认；**未经显式授权严禁执行**：将 `feat/m1-project-baseline` 推送至 `origin`、创建 PR #1（待 `ACT-001`）、Squash 合并 PR #1（待 `ACT-002`）或创建任何发布标签 |
| 核心不变量 | 根提交 `642e618` 永不改写；全仓 `.md` 零 YAML Frontmatter（M2/M5 落地 `packages/blink_skills/skills/**/SKILL.md` 时另行定向豁免校验）、UTF-8 无 BOM、LF 换行；`CLAUDE.md` 严格单行 `@AGENTS.md`；仅使用行内正斜杠相对链接且全部 `#anchor` 可达；全仓零本机绝对路径、零真实凭证、零外部参考索引及同级仓库名 |

退出条件：

| 条件 | 判定标准 | 工作包 | 验收 |
| --- | --- | --- | --- |
| 根提交与远端主干保护就绪 | `origin/main` 唯一根提交为 0 字节 `README.md`（DCO 签名）；远端 Issues/Wiki/Projects 关闭、Discussions 开启、仅允许 Squash PR、`main-protection`（`27720076`）激活且 `bypass_actors=[]`、强制 `repository-quality` 状态检查 | `M1-W01` | `AC-01`、`M1-K01`、`M1-K02` |
| 零依赖文档与卫生门禁闭环 | `python scripts/check_docs.py` 对工作区返回退出码 `0`；对断链、缺锚点、YAML 头、本机路径、密钥与同级参考名的隔离反例夹具全部返回非零并指明行列 | `M1-W02` | `AC-01`、`M1-K03`～`M1-K05` |
| 治理、开发规则与用户台账齐备 | 根级 8 个必需文件与 `docs/dev-rules/*`、`docs/templates/agent-handoff.md` 完整一致；宿主开发工具链就绪项与 M2 唯一核心前置（Flutter/Dart `>= 3.10`）如实登记；`USER-ACTIONS.md` 准确登记 `ACT-001/002`、`Q-001/003/004/006/007`（注明 `Q-002`/`Q-005` 已拍板）、`H-001` | `M1-W03` | `M1-K03`、`M1-K06` |
| 产品需求、界面与交付路线闭环 | `B·L·I·N·K` 定位、7 条硬不变量、明确不做项、`FR-*`/`NFR-*` 三态表、五端布局与 BFM v1 / 双表面受控 HTML（`#semantic-html`）排版令牌、`M1～M6` 路线与 `AC-01～AC-10` 前后一致 | `M1-W04` | `M1-K04`、`M1-K06` |
| 纯 Dart 技术栈六维查证与架构契约冻结 | 2026-11-22 纯 Dart 选型研究（与 2026-11-20 归档替代说明）、宽松许可核验与 `DEC-026` 弱传染动态链接登记、`DEC-001～DEC-026`、系统拓扑/数据同步/双轨 AI 与阅读管线三份设计契约及 `INV-01～INV-13`、`SPK-01～SPK-09` 无歧义落盘 | `M1-W05` | `M1-K04`、`M1-K06` |

<a id="baseline"></a>
## 2. A 已核对的现场与初始基线（2026-11-20 核验 / 2026-11-22 纯 Dart 修订）

- **本地 Git 与根提交**：仓库已在本地初始化为主干 `main`，配置 `core.autocrlf=false`、`pull.ff=only`、`fetch.prune=true` 及规范提交身份；Commit #1 `642e618`（`chore: initialize repository`，含 `Signed-off-by` DCO 尾注，树内仅含 0 字节 `README.md`，blob `e69de29bb2d1d6434b8b29ae775ad8c2e48c5391`）已在启用分支保护前推送至 `origin/main`，并切出当前工作分支 `feat/m1-project-baseline`。
- **GitHub 远端实况（已回读确认）**：`chialecode/blink` 默认分支 `main`，`allow_squash_merge=true`、`allow_merge_commit=false`、`allow_rebase_merge=false`、`delete_branch_on_merge=true`、`squash_merge_commit_title="PR_TITLE"`、`squash_merge_commit_message="PR_BODY"`；`has_issues=false`、`has_wiki=false`、`has_projects=false`、`has_discussions=true`、`pull_request_creation_policy="collaborators_only"`；Actions 仅允许选定白名单 `actions/checkout@*` 与 `actions/setup-python@*` 且默认令牌权限 `read`；Dependabot 告警、自动安全更新、密钥扫描与推送保护全部开启；规则集 `main-protection`（ID `27720076`）处于 `active` 状态。
- **宿主开发环境只读实测基线（纯 Dart 架构大幅简化前置）**：
  - **已安装就绪**：① 版本控制与包管理：`git 2.56.0.windows.4`、`gh 2.103.3`、`winget v1.29.380`；② 仓库 CI 文档门禁运行时：`Python 3.12.16`（零第三方包运行 `scripts/check_docs.py`，仅用于仓库治理，BLINK 应用运行期零 Python 依赖）；③ Windows 桌面 C++ 编译链：Visual Studio Build Tools `18.11.3`（已含 `Workload.VCTools`、`x64` MSVC `19.51.36260.0`、`CMake 4.3.1-msvc1` 与 Windows 11 SDK `10.0.26100.0`，直接支撑 M2 `flutter build windows`）与 Windows 11 WebView2 Runtime；④ 可选外置本地推理硬件底座：WSL2 `3.0.5.0` 与独立显卡及 `64 GB` 内存（供用户自选外置本地 AI 端点，非 BLINK 核心运行前置）。
  - **M2 启动前唯一核心前置待安装**：**Flutter / Dart 稳定版 SDK（Dart `>= 3.10`，启用稳定 Build Hooks 与 `dart build cli`）**（推荐经 `fvm` 管理，当前宿主机未安装 `flutter`、`dart`、`fvm`）。**不再需要安装任何容器引擎、外置数据库服务或后端 Python 工具链。**
  - **按后续平台与子目标分步补齐（不阻塞 M2 启动）**：① **JDK 17/21 + Android SDK**（M2/M3 编译 Android 安装包前补齐）；② **Tailscale 客户端**（M3 跨外网私网同步实测前补齐）；③ **Linux 开发头文件 `libwebkit2gtk-4.1-dev` 与 `libsoup-3.0-dev`**（仅 Linux 构建机在 M5 表面 2 适配前补齐）。

## 3. 依据、开源查证与阶段技术定案（S-01～S-10）

本阶段已完成 2026-11-22 纯 Dart 路线六维开源查证与许可核验（完整证据见[纯 Dart 架构选型研究](../research/2026-11-22-pure-dart-pivot.md#overview)与[有效决定](../decisions.md#stack-decisions)），M2 起直接按以下 10 项定案实施，不再重复摇摆选型：

| 定案编号 | 领域 | 已锁定方案与边界 |
| --- | --- | --- |
| `S-01` | 文档治理标准 | 采用精简二代文档标准：单一追加式 `docs/decisions.md`、固定路径 `stage-plan.md` / `stage-report.md`、`scripts/check_docs.py` 零依赖门禁（M2/M5 新增 `packages/blink_skills/skills/**/SKILL.md` Frontmatter 专用白名单校验） |
| `S-02` | 纯 Dart 五端单仓架构 | 全面采用 **Flutter / Dart（`>= 3.10`）** 统一交付 `Windows / macOS / Linux / Android / iOS` 与统一原生 CLI/MCP/无头同步工具包；单仓分层为 `packages/{blink_sanitizer,blink_core,blink_skills,blink_cli}` 与 `apps/blink_client`，零容器、零外置数据库、零后端 Python 运行时（[DEC-022](../decisions.md#dec-022)） |
| `S-03` | 单文件夹便携库与 CJK 检索 | 桌面端单一便携目录 `<BLINK_VAULT_DIR>`（`vault.json`、`db/blink.db`、`index/fts.db`、`blobs/`、`mirror/`），复制整夹即可完成备份与跨机迁移；底层采用 `drift 2.35.4` + `sqlite3 3.9.1` Native Assets（WAL + `BEGIN IMMEDIATE` + `VACUUM INTO` 热备份）与 `unicode61 remove_diacritics 2` + CJK 字符预分词；库内严禁存放任何明文密钥或运行期令牌（`INV-08`） |
| `S-04` | M3 统一多端同步架构 | 将全部多端同步能力统一收口于 M3（[DEC-023](../decisions.md#dec-023)）：共享因果 OpLog 与双本冲突保护（`INV-05`），同步落地 ① 桌面端内嵌 `shelf 1.4.3`/`shelf_router 1.1.5` 局域网（`bonsoir 7.1.6`）/ Tailscale 直连同步与 `dart build cli` 无头命令 `blink sync serve`；② 客户端 `XChaCha20-Poly1305`（`cryptography 2.9.0`）端到端加密 WebDAV/S3 异步中继（含“禁止 `#private` 经云端中继”开关） |
| `S-05` | BFM v1 与 CJK 输入法保护 | 手写采集层采用 **BFM v1（BLINK Flavored Markdown）**，基于 `package:markdown 7.3.1` 扩展 9 个最小原语（含 `[[wikilink]]`、`![[ai:<uuid>]]`、`==高亮==`、`> [!callout]`、内生 `- [ ]` 等）；坚持原生 `TextField` + 5 条 CJK 输入法组合态保护规则 + 桌面 `OverlayPortal`/移动键盘贴顶补全，并按确定性规则降级输出 10 年可读标准 `.md` 镜像（[DEC-024](../decisions.md#dec-024)） |
| `S-06` | 纯 Dart 伴读解析与原生 PDF | 网页剪藏（`package:html 0.15.7` CJK Readability + 防 SSRF）与 EPUB 解析（`archive 4.6.0` + `xml 7.1.0` + `.runes` 偏移 + Zip-Slip 防护）全部在后台 Dart Isolate 执行产出双轨 Unified Block AST；PDF 五端统一采用 MIT 许可的 `pdfrx 3.1.0` + `pdfrx_engine 0.9.6`（零 AGPL），扫描版显式标注 `missing_ocr`（[DEC-023](../decisions.md#dec-023)） |
| `S-07` | 纯 Dart 净化与双表面受控 HTML | 纯 Dart `packages/blink_sanitizer`（`package:html 0.15.7` HTML5 树重建 + W3C CSS Syntax L3 令牌级白名单编译器）在写入与渲染双端防线拦截全部脚本、外链、CSS `url(...)` 绕过与硬编码色值；表面 1（时间流/阅读器/快卡）坚持 100% 纯 Flutter（`flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `fl_chart 1.3.1` + `<blink-*>` 原生标签）；表面 2 按需单实例承载零脚本离线 CSP 整页 HTML 视图（`flutter_inappwebview 6.1.5` 覆盖四端 + Linux `desktop_webview_window 0.4.3` 遵循 [DEC-026](../decisions.md#dec-026) 并带表面 1 优雅降级） |
| `S-08` | 双轨无服务端 AI 扩展 | 轨道一优先支持外置 AI 通过 `packages/blink_cli`（`dart build cli` 统一打包、`mcp_dart 2.4.4` 封装于 `BlinkMcpAdapter`、双模式 IPC/冷 WAL）与 `packages/blink_skills`（5 项 `agentskills.io` `SKILL.md` 与一键 MCP 配置导出）读写知识库；轨道二预留可选端侧直连 `OpenAiCompatClient`（`dio` + SSE，零后端服务，对话转存笔记遵循 `INV-01`）（[DEC-025](../decisions.md#dec-025)） |
| `S-09` | 原文只读与 `#private` 四层隔离 | `ExternalAiRepository` 对 `raw_*` 无任何修改删除方法；`#private` 执行四层硬隔离：① MCP/CLI 默认 `--scope normal_only`（`v_normal_*` 视图 + `fts_normal`，不透明 `not_found`）；② 端侧直连 AI 锁死 `private_local` 本机/内网地址且故障闭锁 `privacy_blocked`；③ 双表面 HTML 净化 + `default-src 'none'` 离线 CSP + 无痕视图；④ E2EE 中继外加禁传 `#private` 开关；全部密钥仅存每台设备原生安全密钥库（`INV-03`、`INV-08`） |
| `S-10` | 开放镜像与双通道全路径隔离 | 桌面端 Dart Isolate 5 秒防抖原子导出 BFM 降级纯 `.md` 主归档与表面 1/2 `insights/*.html` 独立综述（私密归入 `0700` `private/`）；`blink` 与 `blink-dev` 全小写路径、数据目录、`vault.json` 通道锁、运行期 `ipc.json`、CLI/MCP 键名、Windows WebView2 `userDataFolder` 与系统密钥库完全隔离（`INV-06`、`INV-07`） |

## 4. 目录布局与文档职责边界

M1 建立的仓库受控结构与职责划分如下（M2+ 纯 Dart 单仓业务目录见[系统架构](../design/architecture.md#repo-layout)）：

| 路径 | 单一职责边界 |
| --- | --- |
| `.github/`、`.gitattributes`、`.gitignore`、`LICENSE` | 远端仓库设置/规则集/Actions 策略声明镜像、CI `repository-quality` 工作流、7 天冷却 Dependabot 配置、LF 行尾与忽略规则、`Apache-2.0` 许可证 |
| `scripts/check_docs.py` | 零依赖门禁脚本：校验文件布局、`CLAUDE.md`、无 BOM/Frontmatter、相对链接与锚点、路径/密钥/参考仓库名零泄漏 |
| `README.md`、`AGENTS.md`、`CLAUDE.md`、`USER-ACTIONS.md`、`CONTRIBUTING.md`、`REVIEW.md`、`SECURITY.md`、`CHANGELOG.md` | 项目总览、AI/开发者启动入口、用户待办与授权唯一台账、协作与审查标准、安全披露与版本记录 |
| `docs/README.md`、`docs/dev-rules/*`、`docs/templates/agent-handoff.md` | “问题 → 唯一正本”路由表、连续执行工作流、纯 Dart 工具链与门禁工程规则、开源与隐私卫生规则、A/B 交接模板 |
| `docs/requirements.md`、`docs/ui.md`、`docs/delivery/*` | `B·L·I·N·K` 功能/非功能需求正本、五端界面与 BFM v1 / 双表面受控 HTML 排版规范、`M1～M6` 路线与验收、当前状态、本阶段计划与阶段报告 |
| `docs/decisions.md`、`docs/research/2026-11-22-pure-dart-pivot.md`、`docs/research/2026-11-20-stack.md`、`docs/design/*` | 追加式有效决定台账（`DEC-001～DEC-026`）、现行纯 Dart 六维技术栈研究与初版研究归档、系统架构/数据同步/双轨 AI 与阅读管线设计契约 |

<a id="work-packages"></a>
## 5. 工作包（M1-W01～M1-W05）与执行顺序

按 **M1-W01 → M1-W02 →（M1-W03 ∥ M1-W04 ∥ M1-W05）→ 全仓门禁收敛** 顺序执行，各工作包严格遵守文件所有权边界：

| 工作包 | 预期产出与关键失败防御路径 | 完成证据 |
| --- | --- | --- |
| **M1-W01** 仓库初始化与远端治理加固 | 初始化本地 `main`、推送 0 字节 `README.md` DCO 根提交 `642e618`；配置远端 Squash-only、关闭 Issues/Wiki/Projects、开启 Discussions、锁定 Actions SHA 白名单与只读权限、开启安全告警与 `main-protection` 规则集（`27720076`）；在 `feat/m1-project-baseline` 落盘 `.gitattributes`、`.gitignore`、`LICENSE` 与 `.github/*` 全部镜像配置 | `M1-K01`、`M1-K02`；远端 `GET` 回读与 `.github/*` 一致 |
| **M1-W02** 零依赖文档与卫生门禁 | 实现 `scripts/check_docs.py`、其回归夹具 `scripts/test_check_docs.py`、本地 `.githooks/pre-push`、`.editorconfig` 与 `.github/workflows/ci.yml`（任务名 `repository-quality` 对齐规则集，依次运行门禁与回归夹具）；支持 `--root`、`--ref-dir`、`--no-layout-check` 供隔离夹具测试；动态加载外部参考索引与同级仓库目录名，脚本源码自身零硬编码敏感名 | `M1-K03`～`M1-K05`；`python -B scripts/test_check_docs.py` 全部通过 |
| **M1-W03** 根级入口与开发治理规范 | 完成 `README.md`、`AGENTS.md`、`CLAUDE.md`、`USER-ACTIONS.md`（`ACT-001/002`、`Q-001/003/004/006/007`、`H-001`，注明 `Q-002`/`Q-005` 已拍板）、`CONTRIBUTING.md`、`REVIEW.md`、`SECURITY.md`、`CHANGELOG.md`、`docs/README.md`、`docs/dev-rules/{workflow,engineering,sources-and-safety}.md`（更新为纯 Dart 工具链与 `DEC-026` 登记边界）、`docs/templates/agent-handoff.md` | `M1-K03`、`M1-K04`、`M1-K06` |
| **M1-W04** 产品需求、五端界面与交付文档 | 完成 `docs/requirements.md`（纯 Dart 单文件夹库、BFM v1、M3 统一多端同步、双轨 AI 与双表面 HTML）、`docs/ui.md`（BFM v1 编辑器与 5 条 CJK 输入法规则、表面 1/2 受控 HTML `#semantic-html`、显式诚实状态）、`docs/delivery/roadmap.md`（`M1～M6`、MVP/LOOP 表、`AC-01～AC-10`）、`docs/delivery/status.md`（M1 修订 3 基线、`LOOP-001..006`、`OSS-001..004`）与本计划 | `M1-K04`、`M1-K06` |
| **M1-W05** 决定台账、纯 Dart 选型研究、架构契约与阶段报告 | 完成 `docs/decisions.md`（追加 `DEC-022～DEC-026` 并注明对 `DEC-013～DEC-021` 的替代关系）、`docs/research/2026-11-22-pure-dart-pivot.md`（六维查证、许可审计、`SPK-01～SPK-09`）与 `2026-11-20-stack.md` 归档头、`docs/design/{architecture,data-and-sync,agent-and-reader}.md`（纯 Dart 拓扑、单仓目录、单文件夹存储与同步、BFM v1 与双表面 HTML、CLI/MCP/Skills 与可选直连 AI、`INV-01～INV-13`）及 `docs/delivery/stage-report.md`，跑通全仓 `check_docs.py` | `M1-K03`～`M1-K06`；`python scripts/check_docs.py` 退出码 `0` |

## 6. 安静验证、路径小写与门禁要求

- **一条命令零依赖验证**：在仓库根目录或任意目录执行 `python scripts/check_docs.py`，必须在数秒内静默完成全部校验（无网络请求、无弹窗、不写受控工作区文件）。
- **隔离反例自检**：验证门禁拦截有效性时，必须在系统临时目录或仓库忽略区构造反例夹具并通过 `--root <temp_dir>` 调用，严禁污染工作区受控文件。
- **大小写与路径铁律**：人类可读阶段标签与编号大写（`M1`、`M1-W01`、`M1-K01`、`BLINK-M1-01`）；分支名（`feat/m1-project-baseline`）、提交作用域（`feat(m1)`）、文档文件名（kebab-case）以及架构规范中定义的五端应用与数据路径标识（`blink`、`blink-dev`）一律小写；描述操作系统目录模板时只用符号占位符（如 `%LOCALAPPDATA%/blink`、`$XDG_DATA_HOME/blink`、`<BLINK_VAULT_DIR>`），严禁写入真实盘符或用户主目录路径。

<a id="cases"></a>
## 7. 必测用例（M1-K01～M1-K06）

| 编号 | 测试场景与断言标准 | 对应工作包与验收 |
| --- | --- | --- |
| `M1-K01` | **不可变根提交与分支拓扑核验**：`git log main` 仅含根提交 `642e618`，`git show --stat 642e618` 确认为单个 0 字节 `README.md` 且提交说明含 `Signed-off-by`；当前分支为 `feat/m1-project-baseline` 且父提交为 `642e618` | `M1-W01`、`AC-01` |
| `M1-K02` | **GitHub 远端策略与 `main-protection` 规则集核验**：远端 API 回读确认默认分支 `main`、仅开启 Squash 合并（`PR_TITLE` / `PR_BODY`、合并删分支）、Issues/Wiki/Projects 关闭、Discussions 开启、Actions 仅选定白名单且默认只读、`main-protection`（`27720076`）状态 `active`、`bypass_actors=[]`、必过检查为 `repository-quality`（`integration_id: 15368`），并与 `.github/*` 声明文件一致 | `M1-W01`、`AC-01` |
| `M1-K03` | **文件树完整性、`CLAUDE.md` 与编码格式校验**：运行 `python scripts/check_docs.py` 验证 8 个根级必需文件、11 个 `docs/` 必需文件及带日期的 `docs/research/2026-11-22-pure-dart-pivot.md`（与归档 `2026-11-20-stack.md`）全部存在，`README.md` 非空，`CLAUDE.md` 严格为 `@AGENTS.md`，全部文本 UTF-8 无 BOM、LF 行尾、零 YAML Frontmatter 且 `docs/` 子目录与文件名符合规范 | `M1-W02`～`M1-W05`、`AC-01` |
| `M1-K04` | **全仓相对链接与显式 HTML 锚点可达性校验**：全仓 26 份 Markdown 文档（25 份根级与 `docs/` 正本及 `.github/PULL_REQUEST_TEMPLATE.md`）中的所有行内相对链接均使用正斜杠、不越出仓库根且目标文件存在，所有 `#fragment` 均在目标文件的标题 slug 或 `<a id="..."></a>` 中精确命中，零参考式链接 `[text][id]`；隔离夹具注入断链与缺失锚点时门禁准确报错退出码 `1` | `M1-W02`～`M1-W05`、`AC-01` |
| `M1-K05` | **路径、凭证与外部参考名称零泄漏反例测试**：隔离夹具分别注入 Windows 盘符绝对路径、Unix 用户目录路径、伪造 API 密钥以及同级/参考项目名称，`check_docs.py` 全部准确拦截（固化为 `scripts/test_check_docs.py`，含句末标点紧跟名称的边界）；对真实工作区运行门禁输出 `PASS` 且零泄漏告警 | `M1-W02`、`AC-01` |
| `M1-K06` | **跨正本契约与编号一致性核对**：核对 `requirements.md`（`FR-*`/`NFR-*` 三态与 7 条硬不变量）、`ui.md`（BFM v1 与 `#semantic-html`）、`roadmap.md`（`M1～M6` 与 `AC-01～AC-10`）、`status.md`（`LOOP-001..006`、`OSS-001..004`）、`decisions.md`（`DEC-001～DEC-026`）、`research/2026-11-22-pure-dart-pivot.md`（`SPK-01～SPK-09`）、`design/*`（`INV-01～INV-13`）与 `USER-ACTIONS.md`（`ACT-001/002`、`Q-001/003/004/006/007`、`H-001`）口径完全对齐，且全仓现行正本无旧后端/旧路线残余表述 | `M1-W03`～`M1-W05` |

## 8. MVP 与 LOOP 边界

- 本阶段（M1）的交付目标是**治理、需求、纯 Dart 选型与架构契约的完整闭环基线**，确保自 M2 进入纯 Dart 单文件夹便携库与 BFM v1 编码前，所有平台陷阱（移动端 CJK 输入法、Linux 表面 2 WebView 动态链接与沙盒回退、外部 HTML/SVG/CSS 注入绕过、AGPL 许可污染、休眠主机同步与移动端后台回收）已在架构层前置化解，M2 唯一前置工具链（Flutter/Dart `>= 3.10`）清晰无冗余，且主干保护与自动化文档隐私门禁从第一天生效。
- 产品运行期的非阻塞打磨项已归入[交付状态 §2](status.md#loop)（`LOOP-001～LOOP-006`）；本阶段门禁检查规则本身不允许留任何未修复断链、缺失锚点或卫生豁免。

<a id="prompt"></a>
## 9. 给 Agent B 的交接 Prompt

```text
你是 BLINK 的 Agent B，动作：连续实施并收敛 M1（治理、需求与纯 Dart 架构基线，修订 3）。

- 计划：docs/delivery/stage-plan.md（BLINK-M1-01 修订 3）；需求正本 docs/requirements.md；界面规范 docs/ui.md；现行技术栈研究 docs/research/2026-11-22-pure-dart-pivot.md；系统与领域设计 docs/design/{architecture,data-and-sync,agent-and-reader}.md；有效决定 docs/decisions.md（DEC-001～DEC-026）；用户待办 USER-ACTIONS.md（ACT-001/002、Q-001/003/004/006/007、H-001）。
- 分支 feat/m1-project-baseline，父提交为不可变根提交 main @ 642e618（0 字节 README.md，严禁改动 main 或根提交）。M1 全部改动收敛进当前分支的单个 DCO 签名提交（git commit -s / git commit --amend -s）。
- 范围：按 M1-W01～M1-W05 与必测用例 M1-K01～M1-K06 连续完成全部治理配置、scripts/check_docs.py 门禁、根级入口与 docs/ 全部 26 份 Markdown 文档（含 2026-11-22 纯 Dart 架构收敛）、隔离反例自检与阶段报告 docs/delivery/stage-report.md，不逐包停顿请示；非阻塞决策按 Q-001/003/004/006/007 可逆默认值落盘。
- 硬性卫生约束：零 YAML Frontmatter；UTF-8 无 BOM、LF 换行；CLAUDE.md 严格单行 @AGENTS.md；只用正斜杠行内相对链接且全部 #anchor 真实可达，禁用参考式链接；全仓严禁出现本机绝对路径、真实密钥凭证、外部参考索引或同级仓库名称。
- 验证：运行 python scripts/check_docs.py 确认全仓 PASS（退出码 0），核对 git status 与 git diff --check 干净无多余未跟踪文件。
- 未授权严禁执行：git push（除已完成的根提交外）、创建或合并 PR、打标签或修改远端设置（等待 USER-ACTIONS.md 中 ACT-001、ACT-002 授权）。
- 完成后给出分支提交 SHA、验证摘要与给 Agent A 的集中审查 Prompt。
```
