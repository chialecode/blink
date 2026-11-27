# BLINK 需求

本页是“用户要什么”的唯一正本。需求状态只分三种：**已实现**、**本阶段**、**待实现**。治理、产品与纯 Dart 技术栈决定见[有效决定](decisions.md#governance)（含 `DEC-022`～`DEC-027`），系统分层与边界见[系统架构](design/architecture.md#topology)，纯 Dart 选型查证见[纯 Dart 架构演进研究](research/2026-11-22-pure-dart-pivot.md#overview)。

表内“已实现”仅表示代码或治理门禁及对应自动化验证已完成，不代表产品人工验收通过（人工复核与待确认决策见 [`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user)）。

核心术语（说明用户界面概念与底层技术契约的对应关系；用户界面采用直觉化笔记词汇，见 [DEC-033](decisions.md#dec-033)）：

- **小记与笔记（Memos & Notes；底层 `raw_entries`）**：用户界面的两大日常写作形态——**小记**以闪念胶囊 / 聊天记录形式承接即时想法、日常流水、语音与拍照记录（映射 `EntryKind.blink` 等）；**笔记**面向结构化长文与日记书写，提供类 Typora 所见即所得与源代码双模式 Markdown 编辑器（映射 `EntryKind.diary`），支持将任意小记一键无损转为关联笔记。底层存储与镜像归档仍保持统一时间流模型，零强制文件夹负担。
- **单文件夹便携库（界面称“数据文件夹”，`<BLINK_VAULT_DIR>`）**：桌面端零 Docker、零外部数据库服务、零 Python 运行时的单一自包含知识库目录，统一容纳 SQLite3 WAL 主库（`db/blink.db`）、可重建检索索引（`index/fts.db`）、内容寻址附件仓（`blobs/`）与实时只读 Markdown 自动导出镜像（`mirror/`），目录内严禁存放任何明文密钥或同步凭据，复制单个文件夹即可完整备份与迁移；移动端以完全一致的纯 Dart 数据内核运行于应用私有存储（[运行拓扑](design/architecture.md#topology)、[DEC-022](decisions.md#dec-022)）。
- **原文层（Raw Layer）与派生智能层（AI Index Layer）**：原文层保存用户亲手撰写的小记与笔记 Markdown 正文（底层兼容 BFM v1 扩展语法）、高亮选区、人工批注，以及原始录音、书页原图与原书二进制，具备神圣不可篡改性；派生智能层保存外置 AI（CLI/MCP）或可选内置直连 AI 产出的分类标签、语音逐字稿与整理稿、书页 OCR 引文、待办候选、跨时空回响，以及兼具 `summary_md` 与双表面高表现力 HTML（Surface 1 原生卡片 `view_html` / Surface 2 沙盒整页 `artifact_html`）的简报、复盘、全书综述与认知原则候选，支持随时清空并基于原文层重算（[数据分层](design/data-and-sync.md#layers)）。
- **Markdown 扩展格式（底层代号 BFM v1）与双表面高表现力 HTML（Two-Tier Expressive HTML）**：手写小记、笔记与批注采用轻量、零锁定、对中文输入法（CJK IME）友好的 Markdown 扩展语法（底层技术规范称 BFM v1，含 `[[ref]]`、`#tag`/`#private`、`- [ ]` 待办清单、`@book`/`@t`、提示框、折叠块、`==高亮==`、脚注及 `![[ai:<uuid>]]` 只读 AI 卡片嵌入槽；界面统称“Markdown”），由纯 Dart 单一解析器 `packages/blink_core` 解析，并由桌面端实时导出为十年可读的标准 `.md` 文件；外部阅读与 AI 派生输出经纯 Dart 白名单净化器 `packages/blink_sanitizer` 清洗后分两级渲染——**Surface 1**（列表、伴读正文、轻卡片）全程由纯 Flutter 原生组件树渲染，**Surface 2**（AI 生成的杂志级整页报告与复杂布局页）按需在零脚本、离线 CSP 沙盒视图中呈现（[DEC-024](decisions.md#dec-024)、[DEC-033](decisions.md#dec-033)、[双表面 HTML 规范](ui.md#semantic-html)）。
- **统一块级语法树（Unified Block AST）**：由纯 Dart 后台 Isolate 将网页剪藏长文与重排型 EPUB 归一化生成的双轨结构化块序列，每块并存归一化纯文本 `plain_text`（供 FTS5 索引与基于 Dart `.runes` Unicode 标量码点偏移的确定性批注锚定）与经 `packages/blink_sanitizer` 净化的受控语义 HTML `html_sanitized`，由五端纯原生阅读器渲染（[文档语法树](design/data-and-sync.md#document-ast)）。
- **双轨无服务端 AI 协同（Dual-Track Server-Free AI）**：应用本体不内置重型后端服务或本地模型进程——**主轨（外置 AI 优先）**通过 `dart build cli` 产出的纯 Dart 原生 CLI、MCP Server 与 `agentskills.io` `SKILL.md` 技能包，让任意外部 AI 编程/知识助手安全读取知识并回写派生卡片与整页 HTML；**辅轨（可选内置直连）**允许用户在设置中按需接入 OpenAI 兼容 HTTP 接口（支持常规与私密本地双配置），在端内进行伴读追问与自由对话，并将对话结论经用户确认保存为新笔记或派生卡片（[DEC-025](decisions.md#dec-025)）。
- **锚定边注（Contextual Marginalia）**：阅读 PDF、EPUB 或长文时，与精确页码包围盒（`page + bbox`）或块内字符区间（`block_id + char_offset`）永久绑定的高亮、用户批注及页内上下文伴读问答。
- **跨时空回响（Echoes）**：伴读或写作时，展示从过往数周至数年的历史记录与书摘中关联召回的呼应、补充或前后观点张力片段。
- **个人认知与原则账本（User Memory & Principles Ledger）**：从长期记录中提炼、附带 `<blink-ref>` 原文反向链接、仅经用户审阅确认方生效且沿 `supersedes_id` 保留思想演化脉络的个人命题与原则账本。

<a id="product"></a>
## 1. 产品定位

BLINK（`B·L·I·N·K`）是面向长期个人思考、深度伴读与自我认知演进的本地优先、纯 Flutter/Dart 自包含个人笔记与知识系统，完整覆盖 `Windows + Android + Linux + macOS + iOS` 五端（[产品决定](decisions.md#product-decisions)、[DEC-022](decisions.md#dec-022)、[DEC-033](decisions.md#dec-033)）。传统重目录与插件的本地笔记工具（如 Obsidian）在移动端启动慢、中文输入与排版摩擦大，迫使用户耗费精力维护文件夹与文件名；而云端画布或轻笔记工具（如 Muse、Dots）将私人长期思考锁入厂商托管云端，牺牲数据主权与长期可迁移性。BLINK 作为零历史包袱、零 Docker、零外部数据库、零 Python 运行时的全新起点，把“像发消息一样无负担的小记闪念胶囊与类 Typora 所见即所得/源代码双模式 Markdown 笔记”“单文件夹数据目录与全方案多端同步”“跨介质纯 Dart 原生深度伴读与精确边注”“双表面高表现力 AI HTML 卡片/整页渲染”以及“外置 CLI/MCP/Skills 优先 + 可选端内直连 AI”合为一体，并由桌面端实时写出通用 `.md` 与零外链 `insights/*.html` 开放导出目录。

`B·L·I·N·K` 名称与语义矩阵：

| 字母 | 核心展开 | 产品语义与覆盖域 |
| --- | --- | --- |
| `B` | **Blink** | 软件本名：灵光一闪、瞬时无感记录；打开即输入，摒弃重型目录层级与预命名分类负担 |
| `L` | **Library / Literature / Logs / Learning / Life** | 书库阅读（PDF、EPUB）/ 文献与网页长文 / 日记流水 / 学习成长 / 生活全记录 |
| `I` | **Ideas / Insights / Inbox / Intentions** | 思考灵感 / 伴读洞察 / 统一收集箱 / 内生待办意图 |
| `N` | **Notes / Next-actions / Narratives / Network** | 读书与日常 BFM 笔记 / 待办行动 / 长文叙事 / 跨时空知识关联网络（观点回响与认知演进） |
| `K` | **Keeper / Kernel / Knowledgebase / Keep / Keystone** | 开放守护接口（CLI / MCP / Skills 与可选直连 AI）/ 纯 Dart 认知内核 / 本地优先知识库 / 单文件夹便携主堡（数据主权自持） |

核心产品不变量（7 条硬约束）：

1. **零摩擦瞬时记录。** 五端启动或唤醒后直达小记底部胶囊输入框，任何小记均不强制要求标题、文件夹或分类标签；小记与长笔记统一采用原生 `TextField` + 五条 CJK IME 保护铁律（支持所见即所得与源代码双模式），离线状态下 `< 16 ms` 写入本机 SQLite 与发送队列（Outbox），绝不因网络或同步状态阻塞输入。
2. **原文神圣不可篡改（Raw-Layer Immutability，`INV-01`）。** 用户亲手撰写的 BFM v1 原文、高亮选区、手写批注及原始录音/图片/书稿只存入原文层；用户在笔记中引用 AI 卡片仅存不可变 ID 指针（`![[ai:<uuid>]]`）；外置 AI（CLI/MCP）与可选内置直连 AI 严禁修改、润色覆盖或删除既有原文，对话结论转为正式笔记须以新建条目并经用户显式确认方式完成（[架构不变量](design/architecture.md#invariants)）。
3. **隐私分级与 `#private` 四重零出境防线（`INV-03`）。** 凡含 `#private` 标签或标记为私密的条目、附件与伴读记录受四重硬隔离保护：① MCP/CLI 默认硬锁 `--scope normal_only`（独立 SQL 视图与隔离 FTS 索引，跨隐私引用自动脱敏）；② 可选内置直连 AI 强制锁定回环/局域网/Tailscale `private_local` 端点，离线即闭锁返回 `privacy_blocked`；③ 双表面 HTML 渲染强制离线 `default-src 'none'` CSP 与无痕隔离；④ WebDAV/S3 异步同步强制客户端 `XChaCha20-Poly1305` E2EE 且可选禁传 `#private`（[隐私路由](design/agent-and-reader.md#privacy-routing)）。
4. **状态真实与可恢复（`INV-11`）。** 纯离线暂存、桌面同步对端休眠排队、E2EE 中继同步中、扫描版 PDF 无文本层（`missing_ocr`）、网页反爬/SPA 抓取受限、Linux 缺少 WebKitGTK 自动回退 Surface 1、本地模型离线 `privacy_blocked` 与磁盘空间不足必须分别如实说明并提供恢复操作，绝不静默丢稿或伪装为空列表。
5. **批注锚点永久可回跳（`INV-10`）。** 每条伴读高亮、边注与上下文伴读问答均持久化绑定 `{source, chapter/page, block_id/bbox, quoted_excerpt, chat_context, user_thought}` 六元锚点（统一使用 Dart `.runes` Unicode 标量码点偏移或 PDF 归一化包围盒）；字号缩放、跨端切换或重建索引后，点击任意书摘或 AI 综述内的 `<blink-ref>` 溯源胶囊仍能精确预览或跳回原书原处。
6. **数据主权、单文件夹便携与零锁定开放镜像。** 桌面端全部数据收敛于单个 `<BLINK_VAULT_DIR>` 便携目录（目录内零明文密钥 `INV-08`），拷贝一个目录即可备份与迁移；桌面端 Dart 后台 Isolate 按 5 秒防抖原子单向导出 BFM 降级标准 UTF-8 `.md` 归档与零外链自适应主题的 `insights/*.html` 综述页，离开软件十年后仍可直接阅读检索。
7. **不碰非登记文件与双通道严格隔离（`INV-06` / `INV-12`）。** 应用与 CLI 仅管理自身清单登记的库文件、缓存、镜像与技能目录；正式版 `blink` 与开发版 `blink-dev` 在五端的应用标识、`vault.json` 通道标记、OS 运行期 `ipc.json`、CLI/MCP 键名、WebView2 数据目录、缓存、文件锁与系统密钥库完全隔离（[存储与安全](design/architecture.md#storage-security)）。

明确不做（Non-Goals）：

- **不做强制目录树维护与全局力导向图谱炫技**：不迫使用户手工整理多层文件夹、维护复杂属性表，也不做缺乏行动价值的全局球形关系图。
- **不做依赖第三方重型单画布富文本插件的编辑器**：长笔记采用纯 Flutter 实现的类 Typora 块级所见即所得 + 源代码双模式编辑（[DEC-033](decisions.md#dec-033)），所有活动编辑域均坚守原生 `TextField` 与五条 CJK IME 组合态保护铁律，从根源规避重型富文本插件在移动端中文输入法与软键盘升降时的吞字跳光标陷阱。
- **不在应用本体内捆绑 Docker、外部数据库、Python/Node 运行时或重型本地大模型权重**：保持单应用开箱即用与移动端低耗电，重型 AI 合成、向量化、本地语音转写与离线版面 OCR 通过外置 CLI/MCP/Skills 或可选直连 HTTP API 解耦执行（[DEC-022](decisions.md#dec-022)、[DEC-025](decisions.md#dec-025)）。
- **不在 AI 卡片与整页 HTML 渲染中允许任意未授权脚本执行或外部网络回连**：Surface 1 严格限定在纯 Flutter 原生组件树，Surface 2 严格限定在零 `<script>`、离线 `default-src 'none'` CSP 沙盒与 `blink-ref://` 原生桥接内；内置交互微件脚本延后至 [#18](https://github.com/chialecode/blink/issues/18) 审慎评估。
- **不做企业级复杂项目管理（GTD / 看板 / 甘特图）与厂商托管多租户公网云服务**：系统专为单人长期私密认知积累构建，不做多人协同看板或公网社交广场。

<a id="scope"></a>
## 2. 功能需求

<a id="cap-scope"></a>
### 2.1 小记、笔记与 Markdown 所见即所得编辑（FR-CAP）

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| FR-CAP-001 | 五端统一小记（闪念胶囊 / 聊天记录形式）与笔记（类 Typora 所见即所得 + 源代码双模式 Markdown 编辑器）：启动即达小记底部胶囊输入框，支持零延迟离线记录与一键转为关联长笔记；笔记提供非聚焦块原生渲染 + 聚焦块原位编辑 + `Ctrl/Cmd + /` 无损切换源代码模式，完整兼容 9 项 Markdown 扩展语法（`[[ref\|标题]]`、`#标签`、`#private`、`- [ ]`/`- [x]`/`- [>]`/`- [-]`、`@book:`/`@t[mm:ss]`、提示框、折叠块、`==高亮==`/脚注、可选 `$...$` 与 `![[ai:<uuid>\|说明]]` 只读 AI 卡片嵌入槽）；双模式均严格执行五条 CJK IME 组合态保护铁律，提供 `[[` / `#` / `@` / `/` 跨端安全补全；提交后 `< 16 ms` 本地落盘并上屏，未提交草稿按防抖写入崩溃恢复槽（[DEC-024](decisions.md#dec-024)、[DEC-033](decisions.md#dec-033)） | 已实现（桌面与移动端飞书式/精简外壳、聊天式小记、Typora 风格所见即所得 + 源代码双模式编辑器、五条 CJK IME 保护、跨端补全与崩溃恢复草稿） |
| FR-CAP-002 | 按住说话离线语音采集与派生转写槽：移动端底栏提供“按住说话”（上滑取消、松手立即入队），桌面端支持录音按钮与快捷键；通过 `record` 离线录制成低体积 Opus/AAC 写入内容寻址只读 `blobs/` 并立即可回放；语音逐字稿（`verbatim_transcript_text`）与去口头禅整理稿（`clean_transcript_md`）属于派生层（`ai_entry_enrichments`），支持由外置 AI 工具经 CLI/MCP 或可选直连 OpenAI 兼容语音转写接口异步回填，**严禁篡改原录音与用户手写正文**；尚未转写时如实提示“录音已安全保存 · 待转写”并支持一键回放或手动补录（[阅读与采集管线](design/agent-and-reader.md#reader-pipeline)） | 待实现 |
| FR-CAP-003 | 纸质书页拍照采集与视觉 OCR 派生槽：支持直接拍摄或选入纸质书页图像写入不可变 `blobs/`，并可在同一采集动作中附带一段语音口述或 BFM 感悟；书页引文识别（`ocr_extracted_quote`）与书目/页码关联作为派生富化项，由外置 AI/OCR 工具经 CLI/MCP 或可选直连视觉接口写入 `ai_entry_enrichments`，合成为“书页原图 + 识别引文 + 个人感悟”三联卡片；未执行 OCR 或识别低置信度时完整保留原图与个人感悟并如实标“引文待识别/待校对” | 待实现 |
| FR-CAP-004 | 系统分享面板与纯 Dart 后台 Isolate 网页长文剪藏：Android / iOS 系统分享面板（Share Sheet）及桌面端链接投递入口支持一键收入网页 URL（可附当下简评）；客户端先落盘本地队列条目，随后在纯 Dart 后台 Isolate 中执行防 SSRF IP 校验抓取、CJK 调优 Readability（`package:html`）正文抽取、正文图片去重入 `blobs/`（重写为 `blink-blob://<sha256>`）及 `packages/blink_sanitizer` 白名单净化，归一化为统一块级语法树进入稍后读列表；遇到登录墙、反爬挑战或重前端渲染 SPA 站时如实标记 `anti_bot_or_paywall` 并保留原链接与简评，提供“系统浏览器打开”“粘贴正文导入”与 CLI/MCP 外部投递兜底 | 待实现 |
| FR-CAP-005 | 附件管理、CJK 全文检索、修订与回收站恢复：小记、笔记与附件管理视图支持按类型（小记 / 笔记 / 语音 / 书摘 / 稍后读 / 附件）、日期区间、`#标签` 与 `index/fts.db`（SQLite `unicode61 remove_diacritics 2` + CJK 预分词 BM25，支持单字/双字/长词与中英混排）即时过滤；编辑既有条目递增 `revision` 并保留修订时间；删除默认移入 30 天回收站（可一键还原），仅在手动彻底清除或到期清理时回收无引用附件（`INV-12`） | 已实现（桌面与移动端小记/笔记/附件管理、CJK FTS5 检索、修订递增与 30 天回收站） |

<a id="read-scope"></a>
### 2.2 多媒体伴读与锚定批注（FR-READ）

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| FR-READ-001 | 书库导入、内容寻址去重与跨端进度同步：支持导入本地 PDF、EPUB 书籍并汇总已剪藏的网页长文；纯 Dart 后台 Isolate 按 `SHA-256` 写入 `blobs/` 去重并提取封面、目录、作者与页数/章节元数据；五端书库按“正在阅读 / 未读 / 已读完”与来源筛选，自动同步精确阅读位置（PDF 页码与视口坐标、块级阅读器的 `chapter + block_id + char_offset`）；损坏文件或受 DRM 加密文件在导入时直接说明原因并拒收 | 待实现 |
| FR-READ-002 | 五端原生 PDF 伴读与统一文本提取引擎：基于 `pdfrx` 与纯 Dart `pdfrx_engine`（PDFium FFI）在五端统一提供硬件加速分瓦渲染、连续/单页阅读、目录大纲跳转、文本层与字符坐标提取、页内搜索与双栏裁白边；支持跨行文本选区并持久化 `page_index + normalized_bbox[]` 高亮；纯扫描无文本层页面诚实标记 `text_layer = "missing_ocr"`，允许用户立即框选矩形区域挂载边注，并开放外置 OCR/AI 工具经 CLI/MCP 回填检索文本，原始 PDF 字节分毫不改（`INV-01`） | 待实现 |
| FR-READ-003 | 长文与 EPUB 统一块级受控语义 HTML 原生阅读器：纯 Dart 后台 Isolate 通过 `package:archive`（Zip-Slip/Zip-Bomb 防护）+ `package:xml` + `package:html` + `packages/blink_sanitizer` 将重排型 EPUB XHTML 与剪藏网页统一归一化为双轨 Block AST（`plain_text` 基于 Dart `.runes` Unicode 标量码点偏移 + `html_sanitized` 完整保留 `rowspan`/`colspan` 表格、提示框、上下标与 `ruby` 注音）；五端共用 `super_sliver_list` + `flutter_widget_from_html_core` + `fwfh_svg` + `SelectableRegion` 纯原生虚拟列表渲染；调节字号、行距、版心宽度或日/纸/夜主题后全部高亮零漂移；遇到极少数固定版式页面如实提示并提供系统外部阅读器打开兜底（[Q-001](https://github.com/chialecode/blink/issues/4)） | 待实现 |
| FR-READ-004 | 锚定边注与页内上下文伴读：在 PDF 或块级阅读器中划选正文后浮出紧凑操作条（四色高亮、写边注、复制引文及启用直连 AI 时的“问 AI”）；桌面端在右侧分栏展开锚定边注轨，移动端弹出半屏/全屏伴读抽屉；手写批注以 BFM v1 存入原文层；若用户启用可选内置直连 OpenAI 兼容接口，可携带选中引文、局部章节上下文与本书既有批注进行流式问答并固化至只增不改的 `raw_marginalia_turns`；外置 AI 亦可经 MCP 完整读取六元锚点与边注上下文 | 待实现 |

<a id="agt-scope"></a>
### 2.3 双轨 AI 协同、外置接口与双表面生成式视图（FR-AGT）

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| FR-AGT-001 | 原文层与派生层硬隔离及全量重算：存储层、CLI/MCP 契约与界面将用户原文（`RawRepository`）与 AI 派生产出（`AiIndexRepository` / `ExternalAiRepository`）物理分表分接口隔离；界面对全部 AI 产出标注 `✦ AI 派生` 与模型/来源标识；设置页提供“清空并重算全部派生索引（`ai_*` 与 `index/fts.db`）”，全程零改动原文层（[双轨 AI 设计](design/agent-and-reader.md#dual-speed-agent)） | 待实现 |
| FR-AGT-002 | 外置 AI 一等公民接口——纯 Dart 原生 CLI、MCP Server 与 `agentskills.io` 技能管理：`packages/blink_cli` 通过 `dart build cli` 产出零 Python/Node/Dart SDK 依赖的原生二进制包（含捆绑 `libsqlite3`），同时暴露 `blink` 命令行与支持 Stdio / Streamable HTTP 的 MCP Server（`mcp_dart` 封装于 `BlinkMcpAdapter` 后）；桌面端运行时写入走 loopback IPC 实时刷新 UI 并推进 `seq_id`，关闭时无缝回退 `BEGIN IMMEDIATE` WAL；读取走零阻塞只读 WAL；内置管理 5 套 `agentskills.io` `SKILL.md` 技能（含指导外部 AI 生成合规卡片的 `blink-html-card-author`）及一键非破坏式 MCP 配置导出（Claude Desktop / Claude Code / Cursor / Antigravity / Codex），默认硬锁 `--scope normal_only` 且默认关闭原始条目写入（[DEC-025](decisions.md#dec-025)、[Q-007](https://github.com/chialecode/blink/issues/8)） | 待实现 |
| FR-AGT-003 | 派生富化回写与跨时空观点回响（Echoes）：外置 AI 代理或外部网关可按 `since_seq` 增量拉取新增记录，经 MCP/CLI 回写意图标签、关联书目、语音清洗稿、书页 OCR 引文、待办候选（`ai_task_candidates`）以及标记为 `resonance`（共鸣）/ `contrast`（张力）/ `evolution`（演进）的跨时空观点回响（`ai_echo_links`）；所有派生写入同步落入 `sync_oplog` 分配 `seq_id` 自动同步至全部设备；在伴读侧栏与写作视图静默呈现 1～5 条高相关回响，无匹配时保持留白 | 待实现 |
| FR-AGT-004 | 双表面高表现力 HTML 卡片与整页综述视图（Surface 1 + Surface 2）：外置 AI 或可选内置直连 AI 产出的晨间简报、周度复盘、单书深度综述与专题页面统一双轨存储 `summary_md` 与经 `packages/blink_sanitizer` 白名单净化的 `view_html`（Surface 1）/ `artifact_html`（Surface 2）——**Surface 1** 在列表与侧栏由 `flutter_widget_from_html_core` + `fwfh_svg` + `fl_chart` 及 `<blink-grid\|card\|metric\|timeline\|compare\|chart\|ref>` 纯原生渲染；**Surface 2** 在独立全屏/详页按需由零 JS、离线 `default-src 'none'` CSP 沙盒视图渲染完整 CSS Grid/SVG 杂志页面（Linux 缺 WebKitGTK 时自动回退 Surface 1）；用户在 BFM 日记中可通过 `![[ai:<uuid>\|说明]]` 只读嵌入任意 Surface 1 卡片或 Surface 2 预览横幅；全部 `<blink-ref>` 入库前强制校验目标存在性与隐私范围（[DEC-024](decisions.md#dec-024)、[双表面 HTML 规范](ui.md#semantic-html)） | 待实现 |
| FR-AGT-005 | 个人认知原则账本与可选内置直连 OpenAI 兼容对话（Chat-to-Note）：外置或内置 AI 提炼的个人判断准则严格以 `status = 'candidate'` 写入 `ai_user_principles`（可附新旧对照 `view_html` 与 `<blink-ref>` 证据），仅经用户显式点击“确认纳入”才升格 `confirmed` 并沿 `supersedes_id` 保留演化链；此外，用户可在设置页按需启用零后端直连 `OpenAiCompatClient`（基于 `dio` + SSE，拆分 `normal` 与 `private_local` 配置，API Key 仅存于 OS 安全密钥库），在应用内与 AI 对话讨论并在对话结束后一键提炼为派生卡片，或经用户确认保存为一条**全新的**原文层 BFM 笔记（保留对话溯源、绝不覆写既有笔记，[DEC-025](decisions.md#dec-025)、[Q-003](https://github.com/chialecode/blink/issues/5)） | 待实现 |

<a id="task-scope"></a>
### 2.4 待办清单（FR-TASK）

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| FR-TASK-001 | 从小记、笔记与边注自动汇总待办：用户在小记、笔记或边注中写下显式清单语法（`- [ ]` / `- [x]` / `- [>]` / `- [-]`）时客户端本地 0ms 映射为 `raw_tasks`；外置 AI 或直连 AI 从自然语言提取的隐含行动意图严格写入派生表 `ai_task_candidates`，供用户在回顾页一键采纳或忽略；每条待办强制保留指向源条目（`origin_entry_id`）或源批注（`origin_annotation_id`）的反向链接，点击直达对应小记或笔记 | 已实现（基础：小记/笔记 `- [ ]`/`- [x]`/`- [>]`/`- [-]` 双向同步、待办分类视图与源条目回跳）；AI 候选待办待 M6 |
| FR-TASK-002 | 晨间简报聚焦与晚间日记柔性对账：提供轻量“今日聚焦 / 稍后处理 / 已完成”清单视图（不引入多级子项目、看板列或强制逾期红标），当日聚焦项汇入晨间简报顶部；支持勾选完成、顺延、取消或退回纯笔记；外置 AI 或直连 AI 在晚间回顾时交叉比对当日笔记给出温和的勾选对账建议 | 待实现 |

<a id="sync-scope"></a>
### 2.5 单文件夹便携库、全方案多端同步与实时开放镜像（FR-SYNC）

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| FR-SYNC-001 | 统一 `SyncTransport`、本地 Outbox 与因果 OpLog 收敛：五端所有写操作先在单事务内落盘本地 `drift` SQLite 并追加带不可变 UUIDv7 `client_op_id` 与混合逻辑时钟 `hlc_ts` 的 `outbox_ops`；统一因果操作信封同时驱动直连单调 `seq_id` 拉取与对象存储分段重放（覆盖 `raw_*` 与 `ai_*` 两层）；网络中断随时续传；多设备离线并发编辑同一条 `body_md`/`note_md` 时强制**双本保留**并生成显式冲突待裁定副本，`privacy_level = 'private'` 单向锁存，绝不静默丢字（[同步契约](design/data-and-sync.md#sync)） | 待实现 |
| FR-SYNC-002 | 全方案多端同步（直连 LAN/Tailscale + 无头同步节点 + E2EE WebDAV/S3 异步中继）：M4 统一交付两种互补同步通道——① **直连模式**：桌面端托盘后台 Isolate 内嵌纯 Dart `shelf` 同步服务，局域网通过 MIT 许可 `bonsoir` 自动发现，跨外网经 Tailscale 虚拟私网直连，同一代码经 `dart build cli` 输出无头 `blink sync serve` 供常驻 Mini-PC/NAS 运行，配一次性配对码与单设备吊销；② **异步中继模式**：面向主力电脑休眠时的手机同步，支持用户自选 WebDAV 或 S3 兼容存储，仅上传按设备隔离的追加式加密分段与去重密文附件（强制客户端 `XChaCha20-Poly1305` E2EE，永不上传活态 `blink.db`），支持二维码/恢复码分发主密钥及“禁止通过 WebDAV/S3 中继 `#private`”物理过滤开关（[DEC-023](decisions.md#dec-023)） | 待实现 |
| FR-SYNC-003 | 单文件夹便携迁移与移动端大文件按需缓存：桌面端所有持久化数据统一收敛于 `<BLINK_VAULT_DIR>`（`vault.json`、`db/blink.db`、`index/fts.db`、`blobs/`、`mirror/`），退出时执行 `wal_checkpoint(TRUNCATE)`，复制单个文件夹即可无损备份或迁移至新电脑/NAS，且目录内零明文凭据；移动端全量离线同步全部文本、AST 与批注，体积较大的 PDF/EPUB 原件默认按需 `Range` 断点拉取到本地缓存并支持设置页一键释放未置顶副本（`INV-12`） | 待实现 |
| FR-SYNC-004 | 桌面端 Dart 后台 Isolate 实时开放镜像（BFM 降级 `.md` + 独立自适应 `insights/*.html`）：监听 `sync_oplog` 与派生视图水位线，默认在写入静止 **5 秒防抖**后由纯 Dart `MirrorExporter` 原子单向写出 UTF-8 `.md` 主归档（将 BFM v1 的 `[[ref]]`、`:::fold`、`==mark==`、`![[ai:...]]` 无损降级为标准相对链接、`<details>`、`<mark>` 与标准 GFM），并在 `insights/` 下同步输出零 `<script>`、零外链、自适应日夜主题的独立 `.html` 综述页（支持 Surface 1/2 视图）；`#private` 物理分置于 `0700` `private/` 子树；同目录临时文件 + `flush()` + 原子改名，绝不反向覆盖数据库正本（[DEC-024](decisions.md#dec-024)、[Q-004](https://github.com/chialecode/blink/issues/6)） | 已实现（基础：桌面端 5 秒防抖与退出刷盘的 BFM 降级纯 UTF-8 `.md` 开放镜像与手动立即导出）；`insights/*.html` 综述镜像待 M6～M7 |

<a id="nfr"></a>
## 3. 非功能需求

| 编号 | 需求 | 状态 |
| --- | --- | --- |
| NFR-PLAT-001 | 五端原生体验与双表面渲染对等性：单一 Flutter/Dart 代码库覆盖 `Windows`、`Android`、`Linux`、`macOS`、`iOS` 五端；桌面三端提供飞书式三栏无横向溢出缩放（最小 `760×560`，含全模块资源栏与分类设置）、键盘导航与托盘常驻，移动双端提供精简四项底栏、安全区与软键盘平滑避让、全屏笔记编辑、分级设置页与系统分享面板；Surface 1（列表、长文/EPUB 伴读、轻卡片）全程纯 Flutter 原生组件树渲染（零 WebView 开销），Surface 2（AI 整页 HTML）在四端用 `flutter_inappwebview`、在 Linux 用 `desktop_webview_window` 动态链接系统 WebKitGTK 4.1 并在缺失系统库时优雅回退 Surface 1（[DEC-024](decisions.md#dec-024)、[DEC-026](decisions.md#dec-026)、[DEC-033](decisions.md#dec-033)） | 已实现（Windows 桌面飞书式三栏布局 + Android 精简四端自适应外壳、日/纸/夜三态主题与键盘快捷键）；其余三端与双表面阅读/沙盒待后续阶段 |
| NFR-PLAT-002 | 正式版与开发版双通道完全隔离：五端正式版 `blink` 与开发版 `blink-dev` 使用独立的应用标识、安装目录、默认 `<BLINK_VAULT_DIR>` 与 `vault.json` 通道守卫、OS 运行期 `ipc.json`、CLI/MCP 键名、Windows WebView2 `userDataFolder`、缓存目录、系统安全存储项与单实例文件锁，全路径小写命名，两通道可同机并行且互不污染（[存储与安全](design/architecture.md#storage-security)） | 已实现（Windows 安装身份、双通道数据根、单实例、安装包与便携库 `vault.json` 通道锁隔离）；其余四端待实现 |
| NFR-PRIV-001 | `#private` 四重零云端出境硬隔离：① CLI/MCP 默认硬锁 `--scope normal_only`（只读 `v_normal_*` SQL 视图与隔离 `fts_normal`，不透明返回 `not_found` 并脱敏跨隐私 BFM 引用，进入 `local_with_private` 须经三门限本地授权）；② 可选内置直连 `OpenAiCompatClient` 对 `#private` 强制锁定仅解析为回环/RFC1918/Tailscale 地址的 `private_local` 配置，未就绪或地址越界立即返回 `privacy_blocked`；③ HTML 双表面离线 `default-src 'none'` CSP + 无痕模式与 Linux 落盘审计门禁；④ WebDAV/S3 同步强制 `XChaCha20-Poly1305` E2EE 且支持禁传 `#private`（`INV-03`） | 待实现 |
| NFR-PRIV-002 | 凭据严格仅存 OS 原生密钥库与便携库零密钥卫生：设备同步令牌、WebDAV/S3 凭据、E2EE 同步主密钥、`local_with_private` 本地 MCP 令牌以及可选内置直连 OpenAI 兼容 API Key 仅加密保存在各设备 OS 原生安全密钥库（Windows DPAPI、macOS/iOS Keychain、Linux `libsecret`、Android Keystore），**严禁**写入 `<BLINK_VAULT_DIR>`、`vault.json`、`db/blink.db`、同步队列、导出配置或日志；数据库仅存配对设备令牌的 `SHA-256` 哈希；loopback `ipc.json` 仅存于 OS 运行期目录（`0600` 权限，每次重启轮换）（`INV-08`） | 待实现 |
| NFR-PRIV-003 | 仓库公开内容与参考源卫生门禁：版本库严禁追踪 `.env`、`.sqlite`/`.db`、密钥文件，且所有受控文本严禁包含本机绝对路径、硬编码密钥或外部参考索引及同级仓库名称；由 `scripts/check_docs.py` 与 CI 自动强制检查（[信息源与安全](dev-rules/sources-and-safety.md#privacy-hygiene)） | 已实现 |
| NFR-PRIV-004 | 纯 Dart 白名单 HTML/SVG/CSS 净化与零脚本离线沙盒：纯 Dart `packages/blink_sanitizer`（基于 `package:html` HTML5 树重建 + W3C CSS Syntax L3 词法编译器 + `<blink-ref>` 数据库存在性与密级校验）在 CLI/MCP 入库与客户端渲染前双向执行严格白名单清洗，彻底阻断 `<script>`、`<iframe>`、`<foreignObject>`、SMIL、`on*` 事件、CSS `url(...)`（含大小写与十六进制转义绕过）及硬编码前景/背景色值；Surface 2 额外叠加浏览器原生 `default-src 'none'; script-src 'none'` CSP 与外部网络硬拦截（`INV-13`） | 已实现（`packages/blink_sanitizer` 核心净化、CSS L3 词法器与对抗测试）；Surface 2 沙盒挂载待实现 |
| NFR-DATA-001 | 原子文件写入、`VACUUM INTO` 热备份与版本守卫：全部非数据库文件写出（配置、`blobs/`、`mirror/` `.md` 与 `insights/*.html`）遵循纯 `dart:io` 同目录临时文件 + `RandomAccessFile.flush()` + 原子重命名（Windows 含文件锁退避重试，`INV-07`）；SQLite 模式迁移前自动执行 `VACUUM INTO` 一致性快照并保留备份；旧版程序遇到更高 `vault.json` / `schema_version` 明确拒写 | 已实现（`packages/blink_core` 原子写入、`VACUUM INTO` 热备份、版本/通道守卫与损坏保留，及桌面端设置页与便携库切换接入） |
| NFR-DATA-002 | 崩溃不丢字与全派生层确定性可重建：本地写入经 SQLite WAL + `BEGIN IMMEDIATE` 持久化，桌面正常退出执行 `wal_checkpoint(TRUNCATE)` 确保单文件夹冷拷贝完整性；清空 `index/fts.db`、`ai_*` 与 `mirror/` 后仅凭 `raw_*` 与 `blobs/` 即可完整恢复用户资产并重建索引与镜像（`INV-09`） | 已实现（`packages/blink_core` SQLite WAL、`BEGIN IMMEDIATE`、`wal_checkpoint(TRUNCATE)` 与 `rebuildDerivedStores()`，及桌面端退出草稿/镜像/WAL 刷盘与设置页接入） |
| NFR-PERF-001 | 瞬时采集响应与大规模语料流畅渲染：冷启动至输入框可键入目标耗时桌面端 `≤ 800 ms`、主流移动端 `≤ 1200 ms`，本地 BFM 落盘 `< 16 ms`，`db/blink.db` `VACUUM INTO` 热快照 `< 1 s`；在 `50,000` 条合成流式条目（简单条目走 `package:markdown` AST 直出快速通道）、`1,000` 页 PDF 及 3,000+ 块长篇 EPUB 下虚拟化流畅滚动，后台解析与镜像导出均在独立 Isolate 执行、不卡 UI 帧 | 待实现 |
| NFR-DEV-001 | 精简正本文档体系与零依赖校验门禁：单源正本精简文档（禁止 YAML frontmatter、禁用引用式链接、强制相对正斜杠链接与显式锚点校验，`CLAUDE.md` 单行指向 `@AGENTS.md`），由 `python scripts/check_docs.py` 在本地与 CI 一键校验；自 M6 引入 `agentskills.io` 技能包时仅对 `packages/blink_skills/skills/**/SKILL.md` 豁免 frontmatter 并增加专用字段模式校验（[工程规则](dev-rules/engineering.md#gates)） | 已实现 |
| NFR-DEV-002 | 小 PR 治理、纯 Dart Monorepo 门禁与宽松许可冷却：执行“一个 issue 一个小 PR、DCO 签名、Squash 合并”与 `main-protection` 保护；依赖升级遵循 7 天冷却期与宽松许可红线（弱传染系统动态库须如 `DEC-026` 显式登记）；自 M2 起采用统一纯 Dart/Flutter 门禁（`dart analyze` / `dart test` / `flutter test` / `dart build cli`），无跨语言契约生成债务；全部测试安静、无焦点、仅监听 `127.0.0.1` 与临时隔离目录 | 已实现（治理、两级门禁、`packages/*` 分析/测试与 `INV-02` 检查、依赖审计与 CI；`dart build cli` 扩展待实现） |
| NFR-DEV-003 | 桌面打包、版本与开发版自动安装更新：Windows 桌面端以 NSIS 产出 `blink` / `blink-dev` 两通道按用户（无需管理员）安装包（卸载项按应用标识，[DEC-029](decisions.md#dec-029)），开发通道版本 `0.1.0-dev.<UTC 年月日时分>` 注入可执行文件版本资源与“关于”页；按安装身份的单实例与本用户控制管道支持 `--background` 托盘常驻、`focus` 与 `--quit-for-update` 保存后退出；需要人工检查时 Agent 一条命令完成构建、静默安装（首次也自动，窗口开着时推迟）、版本双核对与托盘后台拉起，全程不触碰正式版与测试身份；正式版应用内签名联网更新（[#43](https://github.com/chialecode/blink/issues/43)）与 macOS / Linux 安装包按已确认的 [DEC-027](decisions.md#dec-027)（[#9](https://github.com/chialecode/blink/issues/9)）在首个正式版 `v0.1.1` 发布前落地（暂不做商业代码签名） | 已实现 |

## 4. 验收场景索引

全部可复现黑盒验收场景（`AC-01～AC-11`）及其与本页 `FR`/`NFR` 的映射见[路线与验收 §4](delivery/roadmap.md#acceptance)；涉及人工体验复核与待确认决策的事项统一用 [`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user) 跟踪。
