# 交付状态

更新：2026-11-22（M1 治理、需求与纯 Dart 架构基线修订 3 在分支 `feat/m1-project-baseline` 完成全部文档收敛，等待最终复验与用户远端 PR 授权）。本页只维护当前阶段、已落地基线、已知边界、后续 `LOOP` 与开发及上游事项，不按对话轮次追加流水账。

<a id="current"></a>
## 1. 当前阶段与已落地基线

**M1（治理、需求与纯 Dart 架构基线）**（[当前阶段计划 BLINK-M1-01](stage-plan.md#scope)，[有效决定](../decisions.md#governance)）：分支 `feat/m1-project-baseline`，基点为不可变初始提交 `main @ 642e618`。

- **当前状态**：已完成本地与远端仓库初始化、不可变根提交推送、GitHub 远端安全与主干保护规则集配置回读核验、零依赖文档与公开内容卫生门禁 `scripts/check_docs.py`、CI 工作流 `.github/workflows/ci.yml` 及全部 25 份根级与 `docs/` 正本 Markdown 文档（连同 `.github/PULL_REQUEST_TEMPLATE.md` 全仓共 26 份 Markdown 文档）的纯 Dart 架构修订 3 收敛（详见[阶段报告](stage-report.md#b-delivery)与[纯 Dart 选型研究](../research/2026-11-22-pure-dart-pivot.md#overview)）。治理与规范类需求 `NFR-PRIV-003`、`NFR-DEV-001` 及 `NFR-DEV-002`（Git 与远端保护基线）已实现，`AC-01` 本地检查项就绪；分支已按 [ACT-001](../../USER-ACTIONS.md#act-001) 授权推送并创建 PR #1，Squash 合并等待 [ACT-002](../../USER-ACTIONS.md#act-002) 授权，产品定位与纯 Dart 五端架构人工审阅列于 [H-001](../../USER-ACTIONS.md#human-checks)，五项非阻塞可逆默认登记于 [Q-001、Q-003、Q-004、Q-006、Q-007](../../USER-ACTIONS.md#decisions)（原 `Q-002` 单文件夹便携库形态与 `Q-005` 统一多端同步阶段 M3 已由用户拍板记入 `DEC-022`、`DEC-023`）。
- **已落地能力清单**：
  - **不可变初始提交与 GitHub 远端强治理基线**：`origin/main` 根提交固定为 `642e618`（0 字节 `README.md`，带 DCO 签名，在激活规则集前推送）；远端仓库已关闭 Issues / Wiki / Projects、开启 Discussions、强制仅允许 Squash PR 合并且合并后自动删除分支；激活 `main-protection` 规则集（ID `27720076`，`bypass_actors` 为空）强制线性历史、审查线程解决与 `repository-quality` 状态检查；Actions 限定仅允许 `actions/checkout@*` 与 `actions/setup-python@*`（工作流内固定完整 40 位提交 SHA，`GITHUB_TOKEN` 只读），并已启用漏洞告警、自动安全修复与密钥推送拦截；远端 `sha_pinning_required=true` 已于 2026-11-22 开启并回读（[ACT-003](../../USER-ACTIONS.md#act-003)）。
  - **零依赖文档、链接锚点与隐私卫生门禁（`NFR-PRIV-003`、`NFR-DEV-001`）**：`python scripts/check_docs.py` 零第三方依赖运行（仅作仓库 CI 文档治理工具，BLINK 运行期零 Python），强制检查必需根文件与 `docs/` 目录结构、`CLAUDE.md` 单行 `@AGENTS.md` 契约、UTF-8 无 BOM、零 YAML Frontmatter（M2/M5 落地 `packages/blink_skills/skills/**/SKILL.md` 时将仅对该路径新增专用 Frontmatter 模式校验豁免）、`docs/` 小写 kebab-case 文件名、行内相对正斜杠链接与标题 slug / `<a id>` 锚点存在性、禁用参考式链接、拦截本机绝对路径与敏感密钥特征，并通过动态读取 `BLINK_REFERENCE_DIR`、祖先 `reference/blink/` 索引与同级仓库目录名杜绝外部参考项目名称泄漏；门禁自身由 `scripts/test_check_docs.py` 回归夹具在 CI 与本地 `.githooks/pre-push` 中复验（CI 无同级仓库，名称拦截以本地 hook 为主要执行点）。本机参考索引尚未建立，提议见 [USER-ACTIONS](../../USER-ACTIONS.md#recommended)。
  - **`B·L·I·N·K` 纯 Dart 五端架构与六阶段路线正本（`DEC-001`～`DEC-026`、`M1`～`M6`）**：确立零外部容器、零外置数据库、零 Python 运行时的自包含五端 Flutter/Dart 本地优先架构——以 `<BLINK_VAULT_DIR>` 单文件夹便携库（`drift 2.35.4` + `sqlite3 3.9.1` Native Assets WAL + `index/fts.db` CJK 预分词 + `blobs/` + 实时只读 `mirror/`，库内零明文凭据）、BFM v1 文本编辑器（9 个最小原语 + CJK 输入法保护）、M3 统一多端同步（桌面内嵌 `shelf` LAN/`bonsoir`/Tailscale + `dart build cli` 无头 `blink sync serve` + 客户端 `XChaCha20-Poly1305` E2EE WebDAV/S3 异步中继）、纯 Dart Isolate 网页/EPUB/`pdfrx` PDF 伴读、双表面高表现力 HTML 渲染（`packages/blink_sanitizer` 纯 Dart 净化 + 表面 1 原生 `<blink-*>`/`fl_chart` + 表面 2 按需零脚本离线 CSP 沙盒整页视图与 `DEC-026` Linux 动态链接登记）以及双轨无服务端 AI（轨道一外置 CLI/MCP/Skills 优先 + 轨道二可选端侧直连 OpenAI 兼容 HTTP 客户端）形成完整契约闭环。
- **已知边界与未运行项**：M1 不含运行期业务代码（`packages/{blink_sanitizer,blink_core,blink_skills,blink_cli}` 与 `apps/blink_client/` 按[路线图](roadmap.md#stages)自 M2 起创建；宿主机已就绪 `git`、`gh`、`Python 3.12`、Windows C++ 桌面编译链与 Win11 WebView2，**M2 编码启动前唯一核心前置仅剩安装 `Flutter / Dart` 稳定版 SDK（Dart `>= 3.10`）**，见[阶段计划 §2](stage-plan.md#baseline)）；`AC-02`～`AC-10` 全部为 `待实现`；GitHub Actions `repository-quality` 首次云端运行结果以 PR #1 检查页为准。

<a id="loop"></a>
## 2. 后续 LOOP（Agent 侧非阻塞深化）

以下事项不影响 MVP 核心闭环、原文不可篡改与隐私边界，留待对应阶段跑通基础闭环后按真实使用反馈迭代：

| 编号 | 深化事项 | 当前基线取舍与后继触发条件 |
| --- | --- | --- |
| LOOP-001 | 复杂固定版式画册或重度绝对定位 CSS 类 EPUB 的平台级可选预览层 | M4 默认采用纯 Dart 后台 Isolate 解析的 Unified Block AST（经 `packages/blink_sanitizer` 净化）+ 纯 Flutter 原生阅读器（`super_sliver_list` + `flutter_widget_from_html_core`）覆盖重排型书籍、跨行列合并表格与网页长文（[Q-001](../../USER-ACTIONS.md#q-001)），对极少数固定版式页面提供安全降级块与系统外部阅读器打开原文件；待日常书库出现高频刚需样本后再评估受控只读预览扩展 |
| LOOP-002 | 开放镜像仓外部手工改动的双向差异感知与导入审阅 | M2/M6 默认落地桌面端后台 Dart Isolate 的 **5 秒防抖**单向增量原子导出至 `<BLINK_VAULT_DIR>/mirror/`（BFM 降级纯 UTF-8 `.md` 主归档 + 表面 1/2 `insights/*.html` 独立自适应综述，[Q-004](../../USER-ACTIONS.md#q-004)），确保零锁定只读可用且彻底规避双向文件锁冲突；后续视外部编辑器联动需求评估只读变更扫描与差异导入 |
| LOOP-003 | 纯离线端侧轻量 OCR / 语音转写与可选纯 Dart 轻量嵌入式向量检索 | M5/M6 将语音录音与纸质书页照片原生离线落盘原文层，转写、OCR 与语义向量检索优先由外置 AI 工具（CLI/MCP）或可选端侧直连 OpenAI 兼容 API 完成，避免增大五端基础包体与移动端发热耗电；后续若存在长期断网端侧语义召回或离线 OCR 刚需，再评估纯 Dart `Int8List` BLOB 量化扫描或按需下载端侧轻量模型包 |
| LOOP-004 | 桌面三端跨窗口合成器全局热键速记浮窗（Quick Capture Overlay） | M2 优先保证主应用冷启动直达 BFM v1 输入框与系统分享面板稳定可用；鉴于 Linux Wayland 全局快捷键协议差异与 macOS 辅助功能权限引导成本，独立悬浮速记小窗留入 M2 之后迭代 |
| LOOP-005 | 个人认知与原则账本的多主题专题成册汇编与跨年交互筛选画布 | M5 先交付带版本链、双表面受控 HTML 新旧观念对比卡片、`<blink-ref>` 原文证据胶囊与“待审阅”确认队列的结构化认知原则账本；跨年度多专题自定义成册导出留待积累跨月度真实语料后打磨 |
| LOOP-006 | 表面 2 宿主内置离线微 JS 交互图表运行时与 Linux WPE 内联视图收敛 | M5 表面 2 整页 HTML 视图严格执行零 AI `<script>` + 离线 `default-src 'none'; script-src 'none'` CSP（纯 HTML5 + CSS Grid/Flexbox + 完整浏览器 SVG + 无 JS `<blink-ref>` 导航拦截），Linux 端采用 `desktop_webview_window` 独立窗口；依赖交互式 Mermaid / ECharts 缩放微件（仅允许非执行 `<script type="application/json">` 数据岛 + 宿主内置校验脚本与单次随机 CSP nonce）及 `flutter_inappwebview 6.2.x` Linux WPE 稳定后内联收敛明确延后至 MVP 之外 |

<a id="issues"></a>
## 3. 开发与上游事项（OSS）

跟踪五端框架、原生渲染引擎与操作系统平台限制对后续阶段实现的具体约束：

| 编号 | 上游组件或平台事项 | 架构应对策略与阶段验证安排 |
| --- | --- | --- |
| OSS-001 | 跨五端 WebView 碎片化（`flutter_inappwebview 6.1.5` 稳定版不含 Linux、`6.2.0-beta` 依赖桌面罕见的 WPE WebKit 2.0；`desktop_webview_window 0.4.3` 在 Linux 依赖系统 `libwebkit2gtk-4.1-0` / `libsoup-3.0-0` 且未暴露 Dart 层无痕开关）及移动端重型富文本编辑器中文输入法组合态光标跳动 | **分层拆解与显式登记**：① 采集层与表面 1（时间流、阅读器、快速卡片）坚持纯 Flutter 原生组件树（BFM v1 原生 `TextField` + 5 条 CJK 输入法规则 `SPK-02`、`flutter_widget_from_html_core` + `fl_chart` + `<blink-*>`）；② 表面 2 仅按需单实例承载整页 HTML 视图，Win/macOS/Android/iOS 用 `flutter_inappwebview 6.1.5`（Windows 需通过 `WebViewEnvironmentSettings` 注册 `blink-blob` 协议与通道隔离 `userDataFolder`），Linux 用 `desktop_webview_window 0.4.3`（按 [DEC-026](../decisions.md#dec-026) 登记动态链接，走 `127.0.0.1` 随机端口 HTTP CSP + `Cache-Control: no-store`）；③ M5 `SPK-06` 实测 Linux WebKitGTK `#private` 磁盘残留审计，若有残留则将 Linux `#private` 视图锁定表面 1 渲染，缺库时自动降级表面 1（[Q-006](../../USER-ACTIONS.md#q-006)） |
| OSS-002 | `pdfrx 3.1.0` / `pdfrx_engine 0.9.6` 五端 PDFium 动态库分发、中文字体回退及 `sqlite3 3.9.1` Dart Build Hooks（替代已停止维护的旧封装）在五端与 `dart build cli` 打包中的产物布局与 7 天依赖冷却校验 | 全链路采用宽松许可的 `pdfrx` + `pdfrx_engine`（MIT / PDFium Apache-2.0 & BSD-3-Clause，零 AGPL）与 `drift 2.35.4` + `sqlite3 3.9.1`；M2 依赖锁定前按 `DEC-007` 核验最新补丁满 7 天冷却期，以 `SPK-01`、`SPK-04` 与 `SPK-07` 实测 `dart build cli` 随附动态库打包、PDF 高分屏瓦片释放与生僻汉字渲染 |
| OSS-003 | 野生网页（含纯前端 SPA 渲染页面）与 EPUB 的畸形 XHTML、Zip-Slip 路径穿越及外置 AI 产出的 CSS 大小写/转义绕过（如 `URL(...)`、`\75 rl(...)`）与 SVG `<use>`/`<foreignObject>` 注入面 | 纯 Dart 后台 Isolate 解析管线内置防 SSRF 与 Zip-Slip/压缩炸弹配额，遇到纯 SPA 或付费墙/反爬页面诚实返回错误状态供手动粘贴而绝不绕过；全量 HTML/SVG/CSS 统一经纯 Dart `packages/blink_sanitizer`（`package:html 0.15.7` HTML5 树重建 + W3C CSS Syntax L3 令牌级白名单编译器）净化并叠加表面 2 离线 CSP，M2/M4/M5 以 `SPK-06` 与 `SPK-08` 对抗样本集回归验证 |
| OSS-004 | iOS 与 Android 对后台常驻与长连接的系统回收限制，以及“主力桌面机休眠时手机无法直连同步”的个人场景约束 | 端侧全部读写 0ms 落盘本地 `drift` Outbox（`INV-04`），利用前台活跃态与切回前台窗口触发增量同步；M3 在提供桌面内嵌 `shelf` LAN/`bonsoir`/Tailscale 直连与 `blink sync serve` 无头二进制的同时，一并交付客户端端到端加密（`XChaCha20-Poly1305`）WebDAV/S3 异步中继，使手机与休眠主力机亦可安全异步收敛 |
