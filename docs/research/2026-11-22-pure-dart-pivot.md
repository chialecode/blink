# 技术选型补充研究：纯 Flutter/Dart 零后端单文件夹便携架构与外置 AI 生态

查询日期：2026-11-22（UTC+8）。本文是 BLINK 核心技术栈的现行查证正本，取代[初版技术选型研究（2026-11-20）](2026-11-20-stack.md#routes)中的容器化 Python 中枢、PostgreSQL/`pgvector`、单表面纯原生 HTML 与集中式后端 AI 编排路线，对应有效决定 [DEC-022](../decisions.md#dec-022)～[DEC-026](../decisions.md#dec-026)。全部选型严格执行[开源六维查证与宽松许可红线](../dev-rules/sources-and-safety.md#oss-policy)（仅放行 MIT / Apache-2.0 / BSD / Public Domain，零 GPL/AGPL，唯一系统级弱传染动态链接已登记于 [DEC-026](../decisions.md#dec-026)）。

<a id="overview"></a>
## 1. 架构收敛总览：零 Docker / 零 PostgreSQL / 零 Python 运行时

经多轮架构收口，BLINK 确立为**“纯 Flutter/Dart 五端自包含本地优先应用 + 单文件夹便携知识库 + BFM v1 扩展语法 + 双表面高表现力 HTML + 外置优先/内置直连双轨 AI”**架构（[系统架构设计](../design/architecture.md#topology)）：

| 维度 | 现行纯 Dart/Flutter 架构（2026-11-22 定案） | 被替代的初版架构（2026-11-20 归档） | 收敛收益 |
| --- | --- | --- | --- |
| **运行与部署形态** | 桌面端/移动端单一自包含原生应用，配单文件夹便携库 `<BLINK_VAULT_DIR>`；无头 Mini-PC/NAS 可选单个 `dart build cli` 原生捆绑包（[DEC-022](../decisions.md#dec-022)） | 必装 Docker Desktop + PostgreSQL 17/`pgvector` + Python FastAPI 家庭中枢 | 彻底消除 Docker、数据库服务与 Python 运行时前置门槛，拷贝单个文件夹即完成完整备份与迁移 |
| **多端离线同步** | 统一 `SyncTransport` 因果 OpLog（M3 一次性交付）：桌面托盘内嵌 `shelf` 局域网（`bonsoir`）/ Tailscale 直连 + 无头 `blink sync serve`，叠加客户端 `XChaCha20-Poly1305` 端到端加密（E2EE）WebDAV/S3 追加式异步中继（[DEC-023](../decisions.md#dec-023)） | 单一家庭服务器单调 `seq_id` 直连（依赖 24/7 开机服务器） | 既支持在家局域网/Tailscale 零第三方高速直连，又支持主力电脑休眠时经 E2EE WebDAV/S3 异步收敛 |
| **采集语言与阅读解析** | 原文层升级为 9 项克制扩展的 **BLINK Flavored Markdown（BFM v1）**（单一纯 Dart `package:markdown`）；网页剪藏、EPUB 与 PDF 全部在纯 Dart 后台 `Isolate` 本地完成（[DEC-023](../decisions.md#dec-023)、[DEC-024](../decisions.md#dec-024)） | Python `trafilatura` / `lxml` / `pypdfium2` 服务端解析 + 仅基础纯文本/轻量 Markdown | 消除跨语言 OpenAPI 代码生成与双端解析漂移；断网即可完成网页正文解析、EPUB 与 PDF 入库 |
| **HTML 净化与双表面渲染** | 纯 Dart `packages/blink_sanitizer`（`package:html` + W3C CSS Syntax L3 白名单编译器）；Surface 1 纯 Flutter 高速流与阅读器（含 `<blink-*>` 原生卡片与 `fl_chart`）+ Surface 2 按需零脚本离线 CSP 沙盒整页视图（[DEC-024](../decisions.md#dec-024)、[DEC-026](../decisions.md#dec-026)） | Python `nh3` + 全场景强制零 WebView 单表面渲染 | 突破纯 Flutter 组件在 CSS Grid / 渐变阴影 / 复杂中文 SVG 图解上的表达天花板，同时保持流式列表 60/120fps 与零脚本离线安全 |
| **AI 协同模式** | **双轨无服务端 AI**（[DEC-025](../decisions.md#dec-025)）：① 主轨外置 AI（原生 `packages/blink_cli` CLI + MCP Server + `packages/blink_skills` 技能包，4 层 `#private` 隔离）；② 预留可选内置直连 `OpenAiCompatClient`（纯 `dio` + SSE，零后端依赖，支持 `normal` / `private_local` 分流与对话转笔记） | 内置 Python `PydanticAI` + `LiteLLM` + 必装本地 `Ollama` + 强制 `faster-whisper`/`RapidOCR` | 核心知识库轻量化、可随时无缝对接任意外部 AI Agent 或通用 AI 网关，内置对话不绑定任何 BLINK 专属后端 |

<a id="storage-sync"></a>
## 2. 单文件夹便携存储、纯 Dart 同步与文档解析（六维查证）

### 2.1 纯 Dart 共享核心存储与便携目录（`packages/blink_core`）

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 五端 + CLI / 中文 / 离线适配 | 集成成本与体积 | 自研与适配边界 |
| --- | --- | --- | --- | --- | --- | --- |
| **类型安全 SQLite ORM**：`drift`（[pub.dev](https://pub.dev/packages/drift)、[GitHub](https://github.com/simolus3/drift)） | `2.35.4`（2026-11） | 活跃维护，未归档 | **MIT** | 纯 Dart 共享于五端 Flutter 与 `dart build cli` 无头捆绑包；WAL 并发读与后台 `Isolate` 100% 离线运行 | 纯 Dart 代码生成，零额外原生体积 | 在 `packages/blink_core` 统一定义 `raw_*`、`ai_*`、`sync_oplog`、`outbox_ops`、`media_blobs` 与隔离仓储边界（`INV-01`） |
| **底层 SQLite3 FFI 与 Native Assets**：`sqlite3`（[pub.dev](https://pub.dev/packages/sqlite3)、[GitHub](https://github.com/simolus3/sqlite3.dart)） | `3.9.1`（2026-11；`3.7.0` 于 2026-10-12） | 活跃维护，未归档 | **MIT**（底层 SQLite 为 **Public Domain**） | **Dart Native Assets / Build Hooks** 自动为五端 Flutter 与 `dart build cli` 捆绑原生 `libsqlite3`（内置 WAL、FTS5、JSON1、`VACUUM INTO`、`db.backup()`） | 单端约 1.2～2.0 MiB；**已彻底替代官方弃用的 `sqlite3_flutter_libs 0.6.0+eol`** | 强制开启 `journal_mode=WAL`、`synchronous=NORMAL`、`busy_timeout=15000`、`foreign_keys=ON`；写入统一走 `BEGIN IMMEDIATE`；迁移前用 `VACUUM INTO` 生成原子快照（`< 1 s`） |
| **Flutter 路径与后台 Isolate 桥接**：`drift_flutter`（[pub.dev](https://pub.dev/packages/drift_flutter)） | `0.3.1`（2026-07） | 活跃维护，未归档 | **MIT** | 封装 Flutter 五端路径与后台 Isolate；仅限 `apps/blink_client` 引入，`packages/blink_core` 保持零 Flutter 依赖（`INV-02`） | 纯 Dart 薄包装 | 桌面端将数据库路径重定向至单文件夹 `<BLINK_VAULT_DIR>/db/blink.db` |
| **标识与内容寻址**：`uuid`（[pub.dev](https://pub.dev/packages/uuid)）+ `crypto`（[pub.dev](https://pub.dev/packages/crypto)）+ `path`（[pub.dev](https://pub.dev/packages/path)）+ `characters`（[pub.dev](https://pub.dev/packages/characters)） | `uuid 4.6.0`、`crypto 3.0.8`、`path 1.9.1`、`characters 1.4.1`（2026 稳定线） | 官方 / 社区活跃维护 | `uuid`：**MIT**；其余：**BSD-3-Clause** | 纯 Dart，全平台一致；支持 RFC 9562 时间序 UUIDv7、SHA-256 哈希与 Unicode 簇/码点映射 | 纯 Dart，体积极小 | 支撑离线防冲突主键（`INV-05`）、`blobs/` 内容寻址（`INV-07`）与 CJK `.runes` 偏移锚定（`INV-10`） |

- **单文件夹便携与零敏感凭据边界（`INV-06`、`INV-08`）**：桌面端核心资产收敛于单一 `<BLINK_VAULT_DIR>`（`vault.json`、`db/blink.db`、`db/backups/`、`index/fts.db`、`blobs/`、`mirror/`）；独立 `index/fts.db` 拆分 `fts_normal` 与 `fts_private` 两张内置 `unicode61 remove_diacritics 2` 外部内容表，配合 ~25 行纯 Dart CJK 字符间距预分词器（兼顾单字、二字词、多字词与中英混排 BM25，零原生扩展依赖），既让 `db/blink.db` 保持轻量（`VACUUM INTO < 1 s`），又可随时清空重建（`INV-09`）。**`<BLINK_VAULT_DIR>` 内严禁存放任何明文凭据或会话令牌**——设备令牌、E2EE 同步主密钥、本地 MCP 令牌及可选 AI API 密钥全部隔离在操作系统原生安全密钥库，本地 IPC 令牌文件 `ipc.json`（`0600`）仅存于系统临时/运行目录（如 `%LOCALAPPDATA%/blink[-dev]/run/ipc.json`、`$XDG_RUNTIME_DIR/blink[-dev]/ipc.json`、`~/Library/Caches/blink[-dev]/run/ipc.json`）。

### 2.2 纯 Dart 多端同步栈（M3 统一交付直连 + E2EE 异步中继）

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 五端 + CLI / 网络适配 | 集成成本与体积 | 自研与适配边界 |
| --- | --- | --- | --- | --- | --- | --- |
| **内嵌与无头 HTTP 同步服务**：`shelf`（[pub.dev](https://pub.dev/packages/shelf)）+ `shelf_router`（[pub.dev](https://pub.dev/packages/shelf_router)、[GitHub](https://github.com/dart-lang/shelf)） | `shelf 1.4.3`（2026-10-17）、`shelf_router 1.1.5`（2026-10-17） | Dart 官方团队活跃维护 | `shelf`：**BSD-3-Clause**；`shelf_router`：**Apache-2.0** | 桌面端运行于后台 Isolate 承接 LAN/Tailscale 同步与回环 IPC；同一代码经 `dart build cli` 输出无头 `blink sync serve` 供 Mini-PC/NAS 使用 | ~80 KiB 纯 Dart，零外部进程 | 统一承载 `/api/v1/sync/*`、`Range` 媒体分块流、SSE 唤醒及回环衍生写入接口 |
| **五端局域网 mDNS 发现**：`bonsoir`（[pub.dev](https://pub.dev/packages/bonsoir)、[GitHub](https://github.com/Skyost/Bonsoir)）+ `multicast_dns`（[pub.dev](https://pub.dev/packages/multicast_dns)） | `bonsoir 7.1.6`（2026-10）；`multicast_dns 0.3.3+1` | 活跃维护，未归档 | `bonsoir`：**MIT**；`multicast_dns`：**BSD-3-Clause** | 覆盖 Android NSD、Apple Bonjour、Windows DNS-SD 及 Linux Avahi（经 **D-Bus IPC**，零 LGPL 动态链接）；彻底替代 LGPL-2.1 的 Python `zeroconf` | 轻量平台通道薄包装 | 实现在家局域网 800ms 探测优先直连、离家自动回退 Tailscale（BSD-3-Clause）虚拟私网 |
| **HTTP 同步与媒体传输客户端**：`dio`（[pub.dev](https://pub.dev/packages/dio)、[GitHub](https://github.com/cfug/dio)） | `5.5.0+`（2026 持续活跃） | CFUG 长期维护 | **MIT** | 纯 Dart，支持 `Range` 断点续传、SSE 流读取、WebDAV/S3 传输及可选直连 OpenAI 兼容接口 | 纯 Dart | 统一封装 `DirectShelfTransport`、`EncryptedObjectStoreTransport` 与 `OpenAiCompatClient` |
| **客户端 E2EE 异步中继加密**：`cryptography`（[pub.dev](https://pub.dev/packages/cryptography)） | `2.9.0`（2025/2026 稳定线） | 活跃维护，未归档 | **Apache-2.0** | 覆盖五端与 CLI；提供 `Xchacha20.poly1305Aead()`、`AesGcm.with256bits()`、`Argon2id`、`Hkdf` | 纯 Dart（可选平台加速） | 对 WebDAV/S3 追加式 OpLog 分段与去重附件实施强制端到端加密（192-bit 随机 Nonce + HMAC 混淆文件名），远端存储零明文（`INV-03`） |
| **S3 / WebDAV 兼容适配**：`aws_signature_v4`（[pub.dev](https://pub.dev/packages/aws_signature_v4)）+ `webdav_client_plus`（[pub.dev](https://pub.dev/packages/webdav_client_plus)） | `aws_signature_v4 0.6.13`（2026 中期）；`webdav_client_plus 3.0.0`（2026 末） | AWS Amplify / 社区活跃维护 | `aws_signature_v4`：**Apache-2.0**；`webdav_client_plus`：**BSD-3-Clause** | 纯 Dart 配合 `dio`（亦可复用 `dio` + `package:xml` 实现 ~180 行零额外依赖 WebDAV 客户端），避开停维的 `minio 3.5.8` 与 AGPL MinIO 服务端 | 纯 Dart，轻量可替换 | 每台设备仅追加自身前缀下的不可变密文段 `oplogs/<device_id>/<uuidv7>.enc`，按 `(hlc_ts, device_id, client_op_id)` 确定性重放且保留双本冲突（`INV-05`），并提供“禁止通过 WebDAV/S3 中继 `#private`”物理开关 |

### 2.3 纯 Dart 后台 `Isolate` 文档解析栈（网页 / EPUB / PDF）

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 五端 + CLI / 中文 / 离线适配 | 集成成本与体积 | 自研与适配边界 |
| --- | --- | --- | --- | --- | --- | --- |
| **HTML5 DOM 解析**：`package:html`（[pub.dev](https://pub.dev/packages/html)、[GitHub](https://github.com/dart-lang/tools/tree/main/pkgs/html)） | `0.15.7`（2026-09） | Dart 官方团队活跃维护 | **MIT / BSD-3-Clause**（仓库 BSD-3-Clause，移植自 MIT `html5lib`；打包随附完整 `LICENSE` 文本） | 完整 HTML5 规范建树器（统一实体解码与 SVG 命名空间），五端与 CLI 100% 离线一致 | 纯 Dart，< 150 KiB | 同时作为网页剪藏正文抽取、EPUB XHTML 归一化与 `packages/blink_sanitizer` 唯一解析底座 |
| **网页长文正文抽取**：自研 ~500 行 CJK 调优 Readability（基于 `package:html 0.15.7`） | 仓内自研（`packages/blink_core`） | 随 BLINK 演进 | **Apache-2.0**（本仓协议） | 针对中文标点（`，。！？；`）与汉字密度修正 Readability 评分；避开 `reader_mode 0.2.3` 的 MPL-2.0 组件与 `html_readability 0.1.0` 的早期成熟度风险 | 零新增第三方依赖 | 后台 `Isolate` 运行 + DNS 解析层防 SSRF（禁回环/RFC1918/链路本地/Tailscale 网段、限 5 跳与 15 MiB）+ 诚实失败 `anti_bot_or_paywall` 与剪贴板/MCP 补录 |
| **EPUB 解析**：`package:archive`（[pub.dev](https://pub.dev/packages/archive)）+ `package:xml`（[pub.dev](https://pub.dev/packages/xml)） | `archive 4.6.0`（2026-11）、`xml 7.1.0`（2026-09） | 均非常活跃，未归档 | `archive`：**MIT**；`xml`：**MIT** | 纯 Dart 解析 ZIP、OPF `<spine>` 与 NCX/Nav 目录，100% 离线运行于五端与 CLI | 纯 Dart，零原生 C 库 | 自研 Zip-Slip 路径校验、512 MiB/100:1 压缩炸弹配额拦截；**强制按 Dart `.runes` Unicode 标量值计算 `ast_range` 偏移**（规避 UTF-16 代理对错位，`INV-10`） |
| **五端 PDF 渲染与纯 Dart 提取**：`pdfrx`（[pub.dev](https://pub.dev/packages/pdfrx)）+ `pdfrx_engine`（[pub.dev](https://pub.dev/packages/pdfrx_engine)、[GitHub](https://github.com/espresso3389/pdfrx)） | `pdfrx 3.1.0`（2026-11）、`pdfrx_engine 0.9.6`（2026-11） | 持续高频维护，未归档 | **MIT**（底层 PDFium：**Apache-2.0 / BSD-3-Clause**） | `pdfrx_engine` **零 Flutter UI 依赖**，覆盖五端与 CLI；直接提供 `loadOutline()` 目录、`loadText()` 逐字坐标文本与 `render()` 缩略图 | 复用客户端已有 PDFium，**零额外包体增量** | 彻底替代 Python `pypdfium2` / `pypdf`；无文本层扫描页诚实标为 `missing_ocr`（`INV-11`），支持框选批注及外置 AI/OCR 经 CLI/MCP 写入派生文本 |

<a id="bfm"></a>
## 3. BLINK Flavored Markdown（BFM v1）与 CJK 输入法保护

为平衡手写零摩擦录入、多年纯文本可读性与结构化知识连接，BLINK 原文层采用克制的 9 项扩展语法 **BFM v1**（完整语法与 10 年镜像降级规范见[数据模型与文档 AST 契约](../design/data-and-sync.md#document-ast)与[界面规范](../ui.md#views)），全栈仅保留一套纯 Dart 解析器，彻底消除跨语言解析漂移：

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 适配与角色 |
| --- | --- | --- | --- | --- |
| **`package:markdown`**（[pub.dev](https://pub.dev/packages/markdown)、[GitHub](https://github.com/dart-lang/tools/tree/main/pkgs/markdown)） | `7.3.1`（2026-04-04） | Dart 官方团队活跃维护 | **BSD-3-Clause** | `packages/blink_core` 唯一 BFM v1 解析器：通过自定义 `BlockSyntax`/`InlineSyntax` 与 CJK 标点强调规则（如 `这是**“中文”**测试`），产出统一 AST 供时间流 `Text.rich` 快路径、富预览 HTML、`bfm_to_plain_text()` 与 10 年开放镜像 `bfm_to_mirror_md()` 共用 |
| **可选数学渲染（M5 / `LOOP`）**：`val_latex_flutter`（[pub.dev](https://pub.dev/packages/val_latex_flutter)）或 `flutter_math_fork_fork`（[pub.dev](https://pub.dev/packages/flutter_math_fork_fork)） | `val_latex_flutter 0.1.4`（2026-11）；`flutter_math_fork_fork 0.7.3` | 活跃维护 | **BSD-3-Clause** / **Apache-2.0** | 挂载在 `<blink-math>` 自定义标签后；M2～M4 默认以清晰样式化代码块兜底，不增早期依赖 |

- **9 项核心原语与安全边界**：`[[entry|source|ann:<uuid>#anchor|Label]]` 稳定 ID 实体引用、`@book:<uuid>` 语境绑定、`#tag/subtag` 与 `#private`、`- [ ]` / `- [x]` / `- [>]` / `- [-]` 内生柔性待办、`@t[mm:ss]` 音频时间戳、`> [!insight|question|tension|quote]` 语义提示框、`:::fold 标题 ... :::` 折叠块、`==高亮==`、`[^1]` 脚注与 `$...$` / `$$...$$` 数学公式，以及 **`![[ai:<uuid>|标题]]` 只读外置 AI 卡片嵌入槽**（原文仅存 UUID 指针，严禁回填 AI 生成 HTML，严格遵守 `INV-01` / `INV-09`；`normal` 原文嵌入 `private` 卡片时跨密级降级脱敏，遵守 `INV-03`）。
- **CJK IME 组合态安全**：手写采集坚持 Flutter 原生 `TextField` + 自定义 `BlinkSyntaxTextController`（仅在 `value.composing` 区间外做只读高亮、保留组合下划线与回车上屏语义），配合桌面 `OverlayPortal` / 移动端键盘顶部吸附栏提供 `[[` / `#` / `@` 零抢焦点自动补全（`SPK-02`）；手写文本中除 `<details>`/`<summary>` 外的任意原生 HTML 一律转义。

<a id="html-rendering"></a>
## 4. 纯 Dart HTML/SVG/CSS 净化器与双表面高表现力渲染

### 4.1 既有纯原生渲染天花板与双表面定案（[DEC-024](../decisions.md#dec-024)）

经实证审计，`flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `flutter_svg 2.4.0` 在流式列表滚动与划词锚定上表现优异，但存在明确表达上限：不支持 CSS Grid、`<style>` 样式块、`var(--*)`、`box-shadow` 与背景渐变；`display: flex` 嵌套易在滚动视口触发布局异常；`flutter_svg` 对中文 `<text>`/`<tspan>` 回退字体与多行折行、`<marker>` 箭头及 `<filter>` 阴影支持不足。因此 BLINK 升级为**双表面渲染架构**：

1. **Surface 1（内联纯 Flutter 高速表面：`render_surface = "surface1_native"`）**：承载采集流、EPUB/长文伴读器与轻量 AI 卡片（`view_html`），保持 100% 纯 Flutter 60/120fps 渲染与确定性 `.runes` 划词锚点；扩展受控原生语义标签 `<blink-grid>`、`<blink-card>`、`<blink-metric>`、`<blink-timeline>`、`<blink-compare>`、`<blink-chart>`（由 MIT `fl_chart` 绘制）及 `<blink-ref>` 原文溯源胶囊。
2. **Surface 2（按需零脚本离线 CSP 沙盒整页视图：`render_surface = "surface2_sandbox"`）**：承载用户显式点开的周度复盘、单书深度综述与信息图长页（`artifact_html`），完整解锁 HTML5 + CSS Grid/Flexbox + 浏览器原生中文 SVG 图解 + 宿主注入的 Day/Sepia/Dark CSS 变量（`var(--blink-*)`）；**严禁任何 AI `<script>`**，强制执行 `Content-Security-Policy: default-src 'none'; script-src 'none'; connect-src 'none'; style-src 'unsafe-inline'; img-src blink-blob: data:; font-src 'self';`，点击 `<blink-ref>` 改写后的 `blink-ref://` 链接由原生导航拦截器无脚本唤起 Flutter 原文浮层。

### 4.2 净化器与双表面渲染依赖六维查证（2026-11-22 UTC+8）

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 五端适配与安全/技术边界 | 集成成本 | BLINK 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| **纯 Dart HTML/SVG/CSS 净化器**：`packages/blink_sanitizer`（基于 `package:html 0.15.7` + 自研 ~400 行 W3C CSS Syntax L3 白名单编译器） | `html 0.15.7`（2026-09）+ 仓内自研 | Dart 官方 + 本仓维护 | **MIT / BSD-3-Clause** + **Apache-2.0** | 零 Flutter 依赖，同时运行于五端客户端与 `packages/blink_cli`；HTML5 建树重序列化根除实体走私/mXSS；CSS L3 词法器阻断 `url(...)` / `\75 rl(...)` 大小写及转义绕过、`@import`、硬编码十六进制/RGB 色值及 SVG `<use>`/`<foreignObject>`/SMIL/`on*` 事件；输出结构化诊断码供外置 AI 自修 | 零 FFI/Rust 跨端构建税，< 150 KiB | **PRIMARY（取代 Python `nh3` 与 Rust `ammonia` FFI）** |
| **Surface 1 原生 HTML/SVG/图表**：`flutter_widget_from_html_core`（[pub.dev](https://pub.dev/packages/flutter_widget_from_html_core)）+ `fwfh_svg`（[pub.dev](https://pub.dev/packages/fwfh_svg)）+ `flutter_svg`（[pub.dev](https://pub.dev/packages/flutter_svg)）+ `fl_chart`（[pub.dev](https://pub.dev/packages/fl_chart)） | `fwfh_core 0.17.4`（2026-09）、`fwfh_svg 0.16.1`、`flutter_svg 2.4.0`（2026-11-13）、`fl_chart 1.3.1`（2026） | 均活跃维护 | 全部 **MIT**（可选 `graphic 2.6.0` 同为 MIT） | 五端纯 Flutter 离线一致；显式不引入 `fwfh_webview` | 纯 Dart/Flutter | **PRIMARY（Surface 1）** |
| **Surface 2 四端沙盒渲染**：`flutter_inappwebview`（[pub.dev](https://pub.dev/packages/flutter_inappwebview)、[GitHub](https://github.com/pichillilorenzo/flutter_inappwebview)） | `6.1.5`（2026 稳定线） | 活跃维护，未归档 | **Apache-2.0** | 覆盖 **Windows（WebView2）/ macOS（WKWebView）/ Android / iOS**；支持禁 JS、`incognito: true`、`shouldOverrideUrlLoading` 拦截 `blink-ref://`、自定义协议离线响应 `blink-blob://`（Windows 需启动注册 `CustomSchemeRegistration` 并按 `blink`/`blink-dev` 隔离 `userDataFolder`） | 复用 OS 系统 WebView，安装包增量极小 | **PRIMARY（Surface 2 非 Linux 四端）** |
| **Surface 2 Linux 桌面渲染**：`desktop_webview_window`（[pub.dev](https://pub.dev/packages/desktop_webview_window)、[GitHub](https://github.com/MixinNetwork/flutter-plugins)） | `0.4.3`（2026 稳定线） | 社区维护，未归档 | 插件 **Apache-2.0**；运行期动态链接未修改的系统 **`libwebkit2gtk-4.1-0`** 与 **`libsoup-3.0-0`**（**`LGPL-2.1+` / BSD**，已在 [DEC-026](../decisions.md#dec-026) 专门登记） | Linux GTK 独立轻量窗口；因插件未直接暴露全套内存协议与临时上下文开关，采用 `127.0.0.1` 随机端口 + 每会话令牌一次性回环 HTTP 响应（强制 `CSP: default-src 'none'; script-src 'none'` 与 `Cache-Control: no-store`）并用 `setOnUrlRequestCallback` 拦截 `blink-ref://`；**`SPK-06` 实测若 WebKitGTK 仍留 `#private` 磁盘痕迹则 Linux 私密页自动降级至 Surface 1**；缺 WebKitGTK 时平滑降级至 Surface 1（零崩溃） | 零内嵌浏览器体积膨胀 | **PRIMARY（Surface 2 Linux 适配器，受 [DEC-026](../decisions.md#dec-026) 与 [Q-006](../../USER-ACTIONS.md#q-006) 约束）** |

<a id="cli-mcp-skills"></a>
## 5. 纯 Dart 原生 CLI、MCP Server 与 `agentskills.io` 技能包（Track 1 外置 AI）

BLINK 通过 `packages/blink_cli` 与 `packages/blink_skills` 将知识库开放给 Claude Code、Antigravity、Cursor、OpenAI Codex CLI 或用户自建通用 AI 网关，严格坚持 `INV-01`（`ExternalAiRepository` 对 `raw_*` 只读，仅可写入 `ai_*` 且原则强制为 `candidate`，追加型 `blink_capture_entry` 默认关闭并受 `--allow-capture` 门控，见 [Q-007](../../USER-ACTIONS.md#q-007)）与 `INV-03`（默认 `--scope normal_only` 查询 `v_normal_*` 视图与 `fts_normal`、越界返回不透明 `not_found`、三道门控才可显式启用 `local_with_private`）：

| 组件与来源 | 稳定版本与发布日期 | 维护状态 | 许可证 | 适配与技术关键点 | 集成边界与结论 |
| --- | --- | --- | --- | --- | --- |
| **MCP Server SDK（主选）**：`mcp_dart`（[pub.dev](https://pub.dev/packages/mcp_dart)、[GitHub](https://github.com/leehack/mcp_dart)） | `2.4.4`（2026-11 中旬；需 Dart `>= 3.4`） | 2026 活跃维护（单维护者，已做适配隔离） | **MIT**（生产传递依赖 `crypto`/`http`/`meta` 均为 BSD-3-Clause） | 当前唯一稳定 `2.x` 纯 Dart SDK，同时完整支持 **2025-11-25** 与 **2026-07-28** MCP 规范的 **Stdio + Streamable HTTP**、Tools/Resources/Prompts、`ToolAnnotations`、`outputSchema`/`structuredContent` 与消息体积/僵尸流防护 | **PRIMARY（封装在 `BlinkMcpAdapter` 后）**：待官方 `dart_mcp 0.6.0` 转正后可无缝替换 |
| **官方 MCP SDK（替补目标）**：`dart_mcp`（[pub.dev](https://pub.dev/packages/dart_mcp)、[GitHub](https://github.com/dart-lang/ai)） | 稳定 `0.5.2`（2026-07）；测试 `0.6.0-beta.0` | Google Dart 官方团队活跃维护（`0.x` 实验线） | **BSD-3-Clause**（`json_rpc_2 4.1.0` + `stream_channel 2.1.4` 均为 BSD-3-Clause） | `0.5.2` 仅支持 Stdio，`0.6.0-beta.0` 起新增 Streamable HTTP | **DROP-IN 替补**：若 M5 初期仅需 Stdio 或 `0.6.0` 已稳定，可直接切入 `BlinkMcpAdapter` |
| **CLI 参数解析**：`args`（[pub.dev](https://pub.dev/packages/args)） | `2.7.0`（2025-03） | Dart 官方团队维护 | **BSD-3-Clause** | 支撑 `blink` / `blink-dev` 统一子命令树（`add`、`search`、`list`、`ai`、`html`、`mcp`、`skills`、`sync`、`backup`） | **PRIMARY** |
| **原生可执行捆绑命令**：`dart build cli`（Dart `>= 3.10` 稳定 Build Hooks） | Dart SDK `>= 3.10` | 官方工具链 | **BSD-3-Clause** | **关键实证**：含 Native Assets 钩子（如 `sqlite3 3.9.1`）的包执行旧命令 `dart compile exe` 会失败；必须使用 **`dart build cli`** 产出统一自包含目录 `bundle/bin/blink[.exe]` + `bundle/lib/libsqlite3.{dll,so,dylib}`，目标机零 Dart SDK 即可运行 CLI、MCP 与无头 `blink sync serve` | **唯一标准打包命令** |
| **外置 Agent 技能目录**：`packages/blink_skills`（遵循 [agentskills.io](https://agentskills.io) 开放规范） | M5 随包分发 5 项标准 `SKILL.md` | 本仓自研 | **Apache-2.0** | 覆盖检索、`blink-html-card-author`（配 `blink_validate_html` 自修循环）、单书综述、周期复盘与隐私规范；支持一键同步至 `~/.agents/skills/` 及各主流 Agent 配置目录，非破坏性原子合并仅操作 `"blink"` / `"blink-dev"` 键且强制 `--scope normal_only` | `scripts/check_docs.py` 将在 M5 仅对 `packages/blink_skills/skills/**/SKILL.md` 豁免 YAML 头并附专用 Schema 校验 |

- **双态零冲突数据库访问**：桌面端运行时，CLI/MCP 自动通过 OS 运行目录 `0600` 的 `ipc.json` 向桌面回环端点提交衍生写操作（毫秒级刷新 Flutter `drift.watch()` 视图并分配单调 `seq_id`）；桌面端关闭时，CLI/MCP 直接复用 `packages/blink_core` 以 WAL + `BEGIN IMMEDIATE`（`busy_timeout=15000`）写库并触发 `mirror/` 原子刷新。

<a id="in-app-ai"></a>
## 6. 预留可选内置直连 OpenAI 兼容接口（Track 2）与向量检索延后决策

1. **零服务端内置直连接口（`packages/blink_core` `OpenAiCompatClient`）**：
   - 基于既有 `dio`（MIT）实现轻量 OpenAI 兼容客户端（`POST /v1/chat/completions` + SSE 流式响应，零额外重型 SDK、零 BLINK 后端服务器），五端可直连用户自配的云端接口、内网 `Ollama /v1` 或用户自建通用 AI 网关，用于阅读边注即时问答、内置轻量对话及“对话总结为笔记/卡片”。
   - **安全与不变量对齐**：配置强制拆分为 `normal` 与 `private_local` 两套独立端点画像——涉及 `#private` 上下文时物理锁死 `private_local` 且校验解析 IP 仅属 `127.0.0.1` / `::1` / RFC1918 / `100.64.0.0/10`（防 DNS 重绑定），不合规立即返回 `privacy_blocked`（`INV-03`）；所有 API Key 仅存于单机 OS 原生密钥库、绝不落入 `<BLINK_VAULT_DIR>` 或同步流（`INV-08`）；对话转笔记仅生成派生 `ai_*` 卡片或经用户确认的新建 `raw_entries`（附源对话引用），绝不覆写既有原文（`INV-01`）。
2. **嵌入式向量检索延后策略**：
   - AI 推理与语义召回移至外置后，核心应用 MVP（`M2`～`M6`）**不捆绑跨五端原生向量 C 扩展**（外置 AI 自行维护向量索引并通过 MCP/CLI 写入预计算 `ai_echo_links`）。
   - 若未来 `LOOP-003` 需要纯离线端内语义检索，首选在独立 `index/vectors.db` 以 SQLite BLOB 存储 `int8` 量化向量并由纯 Dart 后台 `Isolate`（`Int8List` / `Float32x4List` SIMD）执行精确余弦扫描（50k～100k 分块约 30～120 ms，零原生打包债）；原生 C 扩展（如 `sqlite-vec` 缺少五端官方 `pub.dev` Build Hooks 且 iOS 限制动态 `dlopen`，或 Apache-2.0 的 `sqlite_vector 1.2.0`）仅作远期备选。

<a id="licenses"></a>
## 7. 许可证合规总表、拒绝清单与 7 天冷却期核验

### 7.1 许可证合规结论与弱传染专门登记
- **零 GPL / AGPL 依赖**：全部运行时、同步、解析、渲染、CLI 与 MCP 依赖均为 `MIT`、`Apache-2.0`、`BSD-3-Clause` 或 `Public Domain`。
- **唯一弱传染动态链接登记（[DEC-026](../decisions.md#dec-026)）**：Linux 桌面端 Surface 2 整页视图通过 Apache-2.0 插件 `desktop_webview_window 0.4.3` 动态链接操作系统预装的未修改 **`libwebkit2gtk-4.1-0`** 与 **`libsoup-3.0-0`**（`LGPL-2.1+` / BSD），绝不静态链接、绝不随包篡改分发，缺失时自动回退纯 Flutter Surface 1。
- **随包版权声明义务**：正式发行版自动收集全部第三方 `LICENSE` 文本，特别包含 `package:html` 的组合 MIT/BSD-3-Clause 原始声明文件与 PDFium 许可声明。

### 7.2 本次明确拒绝的方案

| 类别 | 被拒绝方案 | 许可或状态 | 拒绝原因 | 现行替代 |
| --- | --- | --- | --- | --- |
| 容器与外置数据库栈 | Docker Desktop、`PostgreSQL 17`、`pgvector`、Python `FastAPI`/`SQLAlchemy`/`nh3`/`trafilatura` 后端 | 宽松许可（但违背产品零运维约束） | 引入重型容器、双语言契约与独立数据库运维，违背单文件夹便携与零后端方向 | 纯 Dart `packages/blink_core`（`drift` + `sqlite3` WAL）+ 单文件夹 `<BLINK_VAULT_DIR>` |
| 已弃用 Flutter 插件 | `sqlite3_flutter_libs`（`0.6.0+eol`）、`flutter_markdown`（已停维） | MIT / BSD | 官方已终止维护，且前者与 Dart Native Assets 冲突 | `drift 2.35.4` + `sqlite3 3.9.1` Build Hooks；`package:markdown 7.3.1` + `fwfh_core` |
| 弱/强传染性网络与解析包 | Python `zeroconf`（`LGPL-2.1`）、Dart `reader_mode`（含 `MPL-2.0`）、`Nuitka`（`AGPL-3.0`）、`PyInstaller`（`GPL-2.0`）、`minio` 服务端（`AGPL-3.0`） | LGPL / MPL / GPL / AGPL | 触碰许可红线或引入不必要弱传染边界 | `bonsoir 7.1.6`（MIT）、自研 `package:html` Readability、`dart build cli`、`aws_signature_v4`（Apache-2.0） |
| 高成本跨语言 FFI / 过重内嵌浏览器 | Rust `ammonia 4.2.4` + `flutter_rust_bridge`、`webview_cef`、`flutter_inappwebview 6.2.0-beta` Linux WPE、`package:csslib 1.0.2`、`dart_mcp_server` | MIT / Apache-2.0 / BSD | Rust 增五端 NDK/XCFramework 编译税且无法替代 CSS/引用校验；`webview_cef` 膨胀 >200 MiB；Linux WPE 桌面普及度极低；`csslib` 遇现代 CSS 报错；`dart_mcp_server` 是 IDE 研发工具非嵌入式 SDK | `packages/blink_sanitizer`（`html 0.15.7` + W3C CSS L3 词法器）、`flutter_inappwebview 6.1.5` + `desktop_webview_window 0.4.3`、`mcp_dart 2.4.4`（adapter 隔离） |

### 7.3 `DEC-007` 7 天发布冷却期锁定核验表（基准日：2026-11-22）

以下 2026-11 新发版本在 M2～M5 写入 `pubspec.lock` 前，须核对距精确发布时间戳已满 7 天（未满 7 天时锁定上一满 7 天补丁版，见[依赖盘点规则](../dev-rules/workflow.md#dependency-inventory)）：

| 候选包 | 2026-11 查证版本 | 查证发布窗口 | M2+ 锁定前核验动作 |
| --- | --- | --- | --- |
| `drift` / `sqlite3` | `2.35.4` / `3.9.1` | 2026-11（`sqlite3 3.9.1` 约 2026-11-10） | M2 初始化前用 `pub.dev` API 核实满 7 天；`sqlite3 3.9.1` 已满 7 天 |
| `archive` / `flutter_svg` | `4.6.0` / `2.4.0` | 2026-11（`flutter_svg 2.4.0` 为 2026-11-13） | `flutter_svg 2.4.0` 已满 7 天；`archive 4.6.0` 锁定前核实精确日期 |
| `pdfrx` / `pdfrx_engine` | `3.1.0` / `0.9.6` | 2026-11 | M4 锁定前核实已满 7 天并复核 PDFium 预编译哈希 |
| `mcp_dart` | `2.4.4` | 2026-11 中旬 | M5 锁定前核实已满 7 天并确认 `dart_mcp 0.6.0` 是否转正 |
| `val_latex_flutter`（可选） | `0.1.4` | 2026-11 | M5/`LOOP` 按需引入前核实满 7 天 |

<a id="spikes"></a>
## 8. M2 ～ M5 关键技术原型验证边界（`SPK-01` ～ `SPK-09`）

本节统一收口全部去重后的运行期原型验证判据，与 [M1～M6 阶段路线](../delivery/roadmap.md#stages) 一一对应：

| 编号 | 所属阶段 | 验证事项 | 通过判据与受控回退边界 |
| --- | --- | --- | --- |
| `SPK-01` | `M2` | 纯 Dart `packages/blink_core`（`drift 2.35.4` + `sqlite3 3.9.1` Native Assets）单文件夹便携库、CJK `unicode61` 检索与 `VACUUM INTO` 热快照 | 单条 BFM 写入 `< 16 ms`；单字/二字/多字中文与中英混排 BM25 命中准确；`VACUUM INTO` 热备份 `< 1 s`；冷拷贝 `<BLINK_VAULT_DIR>` 至新目录 100% 启动恢复且库目录内零明文凭据（`INV-08`），`vault.json` 通道守卫准确拦截跨通道打开（`INV-06`） |
| `SPK-02` | `M2` | 五端 CJK 输入法组合态（`withComposing`）、BFM 自动补全浮层与 `blink` / `blink-dev` 双通道并行隔离 | 拼音/双拼组合态按回车或空格仅上屏候选词；桌面 `OverlayPortal` 与移动键盘吸附补全零抢焦点零遮挡；同机双通道并发运行目录、锁文件、WebView2 目录与密钥完全隔离 |
| `SPK-03` | `M4` | 纯 Flutter 块级阅读器（`super_sliver_list` + `fwfh_core` + `SelectableRegion`）长书滚动帧率与 `.runes` 跨块重锚 | 单章 3,000+ 不等高块流畅滚动、跳章无回弹；跨段含生僻汉字与 Emoji 划词生成 `ast_range`（`.runes` 码点），切换字号/旋转屏幕零偏移复位（`INV-10`） |
| `SPK-04` | `M4` | `pdfrx 3.1.0` + `pdfrx_engine 0.9.6` 五端 PDFium 打包、文本/目录/缩略图提取与 `pdf_bbox` 边注双向跳转 | 五端离线流畅渲染多栏与扫描版 PDF；`loadText()`/`loadOutline()`/`render()` 不阻塞 UI 帧；扫描页诚实标 `missing_ocr`；释放本机 PDF 缓存后元数据与边注完好且按需恢复（`INV-10`、`INV-12`） |
| `SPK-05` | `M5` | 三路径 `#private` 零出境综合哨兵验证（MCP `normal_only` + 内置直连 `private_local` + Surface 2 离线 CSP） | 回环云端探针收到 **0 字节**：① MCP 默认 `normal_only` 对所有工具/资源零泄漏私密哨兵并返回不透明 `not_found`；② 内置 `OpenAiCompatClient` 对 `#private` 强制 `private_local` 私网 IP 并防 DNS 重绑定，不合规直接返回 `privacy_blocked`；③ Surface 2 离线 CSP 阻断 100% 外部外联请求（`INV-03`） |
| `SPK-06` | `M4 / M5` | `packages/blink_sanitizer` 对抗样本净化与双表面（Surface 1 原生标签 + Surface 2 四端/Linux 沙盒）闭环 | 拦截 `\75 rl(...)`、`URL(...)`、SVG `<use>`/`<foreignObject>`、HTML 实体走私与硬编码色值；Surface 1 正确渲染 `<blink-grid|card|metric|timeline|compare|chart|ref>` 与 `fl_chart`；Surface 2 验证 Windows `CustomSchemeRegistration` + 双通道 `userDataFolder` 隔离，以及 Linux `desktop_webview_window` 回环 CSP、`blink-ref://` 无脚本回跳、`#private` 零磁盘痕迹审计与缺 WebKitGTK 时平滑降级至 Surface 1 |
| `SPK-07` | `M3` | 全方案多端同步验证：内嵌 `shelf` + `bonsoir`（MIT）LAN/Tailscale 同步、无头 `blink sync serve` 与 E2EE WebDAV/S3 异步中继 | 安静模式（`BLINK_QUIET=1`）零弹窗拉起桌面同步 Isolate；模拟飞行模式 200 条离线变更与并发冲突双本保留 100% 收敛（`INV-05`）；`dart build cli` 无头 `blink sync serve` 挂载冷拷贝库正常同步；`cryptography` `XChaCha20-Poly1305` WebDAV/S3 回环桩零明文落盘且“不中继 `#private`”开关生效 |
| `SPK-08` | `M2 / M4` | BFM `bfm_conformance.json` 与 50k 流式快路径性能、Windows 原子 `.md` 镜像（M2）及纯 Dart 后台 `Isolate` 网页/EPUB 解析（M4） | 9 项 BFM 原语与 CJK 强调全过一致性夹具；50,000 条合成流式条目首屏与滚动达标；Windows 原子替换 `.md` 零残留；网页剪藏 SSRF 拦截回环/私网 IP，EPUB 拦截 Zip-Slip 与压缩炸弹 |
| `SPK-09` | `M5` | `dart build cli` 统一 `blink` 捆绑包、双态 IPC/冷 WAL 并发、MCP 互操作与内置直连 `OpenAiCompatClient` | 零 Dart SDK 目标机运行 `bundle/bin/blink` 正常加载 `libsqlite3`；桌面运行态经 OS 运行目录 `ipc.json` 写 `ai_*` 后 Flutter `.watch()` 毫秒级刷新且 `seq_id` 单调递增，关闭态 `BEGIN IMMEDIATE` 冷写安全落盘；Claude Code / Antigravity / Cursor / Codex Stdio 与 Streamable HTTP 互操作及 `blink_validate_html` 自修循环通过；直连 `OpenAiCompatClient` SSE 流式与对话转笔记恪守 `INV-01` |
