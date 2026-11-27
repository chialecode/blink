# 数据设计：单文件夹便携库、BFM v1、统一文档 AST、双表面 HTML 与全方案同步镜像

本文件定义 BLINK 的纯 Dart 单文件夹便携存储（`drift 2.35.4` + `sqlite3 3.9.1` Native Assets + 隔离 `index/fts.db`）、原文/派生双层实体、**BLINK 扩展 Markdown（BFM v1）**、跨五端共享的统一文档块级 AST（`.runes` 码点偏移）与伴读锚点、双表面受控 HTML 与锁定 `<blink-*>` 标签契约，以及统一 `SyncTransport`（直连 `shelf` LAN/Tailscale + 客户端 `XChaCha20-Poly1305` E2EE WebDAV/S3 异步中继）、并发冲突保护和桌面端 Dart 后台 Isolate 实时开放镜像。系统拓扑与接口见[系统架构设计](architecture.md#topology)，双轨无服务端 AI 与纯 Dart 阅读管线见[AI 扩展与阅读管线设计](agent-and-reader.md#dual-speed-agent)，选型查证见[纯 Dart 架构演进研究](../research/2026-11-22-pure-dart-pivot.md#storage-sync)。

<a id="layers"></a>
## 1. 单文件夹便携库与原文/派生双层数据模型

### 1.1 单文件夹便携库布局（`<BLINK_VAULT_DIR>`）与 SQLite 事务纪律

BLINK 采用零 Docker、零外部数据库服务、零 Python 运行时的纯 Dart 自包含架构（[DEC-022](../decisions.md#dec-022)、[DEC-031](../decisions.md#dec-031)）。桌面三端（`Windows / macOS / Linux`）将全部用户知识资产收敛于单个用户可控的便携目录 `<BLINK_VAULT_DIR>`（已安装端默认位于系统“文档”目录：Windows 经 `SHGetKnownFolderPath(FOLDERID_Documents)` 解析的 `<Documents>\blink`、macOS `~/Documents/blink`、Linux `${XDG_DOCUMENTS_DIR:-~/Documents}/blink`，开发通道为 `blink-dev`；源码构建默认隔离于 `<repoRoot>/.local/blink-dev/vault`），应用本地设置、运行期 `ipc.json`、缓存与凭据独立存放于 OS 应用本地目录（如 `%LOCALAPPDATA%\blink[-dev]`），**复制这一个便携目录即可完成 100% 知识资产备份与跨机/NAS 迁移**；移动端（`Android / iOS`）在应用私有沙盒中运行完全一致的 `packages/blink_core` SQLite 模式并按需 LRU 缓存大体积 `blobs/`（不产出桌面 `mirror/`）：

```text
<BLINK_VAULT_DIR>/                               # 复制单个文件夹即可备份与迁移全部知识资产
├── vault.json                                   # format_version、vault_id (UUIDv7)、channel ("blink"|"blink-dev")
├── db/
│   ├── blink.db                                 # SQLite3 WAL 主库：raw_*、ai_*、sync_oplog、outbox_ops、media_blobs
│   └── backups/                                 # 迁移前与手动导出的原子 VACUUM INTO 热快照
├── index/                                       # 100% 可清空重建的派生索引层（INV-09）
│   └── fts.db                                   # 隔离 CJK FTS5 库（拆分为 fts_normal / fts_private，保证 blink.db 快照 < 1s）
├── blobs/<sha256[0:2]>/<sha256[2:4]>/<sha256>   # 内容寻址只读媒体仓（原书 PDF/EPUB、图片、原始录音）
└── mirror/                                      # 桌面端 Dart 后台 Isolate 5 秒防抖原子写出的只读开放镜像（.md + insights/*.html）
```

**存储安全与工程纪律**：

1. **便携库零明文凭据（`INV-08`）**：设备同步令牌、WebDAV/S3 凭据、E2EE 同步主密钥、`local_with_private` 本地 MCP 令牌及可选内置直连 OpenAI 兼容 API Key **严禁**存入 `<BLINK_VAULT_DIR>`、`vault.json`、`db/blink.db` 或 `mirror/`，全部仅存于各设备 OS 原生安全密钥库；桌面端运行期 loopback IPC 令牌文件 `ipc.json`（`0600` 权限，每次启动轮换）亦存放于 OS 运行期目录（`%LOCALAPPDATA%/blink[-dev]/run/ipc.json`、`$XDG_RUNTIME_DIR/blink[-dev]/ipc.json`、`~/Library/Caches/blink[-dev]/run/ipc.json`），确保热拷贝便携库绝不夹带任何活态会话令牌。
2. **统一 SQLite Pragmas 与单写者串行**：`packages/blink_core`（`drift 2.35.4` + `sqlite3 3.9.1` Native Assets，经 Dart Build Hooks 自动随五端与 CLI 随包分发原生 SQLite 库）每次建连强制执行：`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=15000; PRAGMA foreign_keys=ON; PRAGMA temp_store=MEMORY; PRAGMA cache_size=-32000;`。全部写事务采用 `BEGIN IMMEDIATE` 避免读写锁升级死锁；模式迁移与“导出备份”执行 `VACUUM INTO <tmp>` + `flush` + 原子重命名（`INV-07`）；桌面正常退出执行 `PRAGMA wal_checkpoint(TRUNCATE)` 将 `-wal`/`-shm` 折叠回 `blink.db`，保证冷拷贝零损坏。
3. **禁止将活态 `db/blink.db` 置于外部网盘实时目录**：OneDrive / iCloud / Dropbox 的文件级块同步会撕裂 SQLite WAL 与 `-shm`；若系统“文档”目录已被重定向至 OneDrive，设置页展示温和非阻塞提示但不强制改写默认位置，建议多机实时同步一律走 BLINK 内置 `SyncTransport`（§5）或将便携库切至非网盘目录，外部云盘仅可备份 `db/backups/` 快照或只读 `mirror/`。
4. **双层权限隔离（`INV-01`、`INV-09`）**：

| 维度 | 原文正本层（Raw Layer，`raw_*` / `media_blobs`） | 派生智能层（AI Index Layer，`ai_*` / `index/fts.db`） |
| --- | --- | --- |
| 数据性质 | 用户亲手输入的 **BFM v1** 闪念、日记、划词高亮、手写批注、原始录音/图片与原书二进制 | 外置 AI（CLI/MCP）或可选直连 AI 产出的意图标签、语音逐字稿与整理稿、书页 OCR 引文、待办候选、回响、双表面 HTML 综述与原则候选 |
| 写入主体 | 用户本地事务（`RawRepository`）、纯 Dart 后台 Isolate 确定性文档解析（`raw_sources` / `raw_source_chapters` AST）、用户触发的只增不改伴读轮次（`raw_marginalia_turns`），及可选显式开启的只追加收件箱命令（`blink_capture_entry`，默认关闭） | 派生仓储（`AiIndexRepository` / `ExternalAiRepository`，对 `raw_*` 零 `UPDATE`/`DELETE` 接口），及用户对原则候选/待办候选的确认操作 |
| 可变与删除策略 | 严禁任何 AI 流程覆写、润色替换或删除；用户删除采用带时间戳墓碑（`deleted_at`）与 30 天回收站 | 允许随时一键清空（`TRUNCATE` `ai_*`、删除重建 `index/fts.db` 与 `mirror/`）而不损失任何原文正本 |
| 隐私隔离 | 每行显式携带不可降级的 `privacy_level`（`normal` \| `private`） | 严格继承源记录 `privacy_level`，配 `v_normal_*` 只读视图与分离 `fts_normal` / `fts_private` 物理阻断跨密级混排召回（`INV-03`） |

### 1.2 原文正本层核心实体（`raw_*` 与 `media_blobs`）

跨端业务主键统一采用离线生成的 **RFC 9562 UUIDv7**（存为规范 36 位小写 `TEXT`，天然按毫秒时间序排序且零多端碰撞）；JSON 字段存为带 `CHECK(json_valid(col))` 约束的 `TEXT`，时间戳采用 UTC ISO-8601 或毫秒整数：

| 表名 | 核心列与 SQLite 类型契约 | 约束与职责说明 |
| --- | --- | --- |
| `raw_entries` | `id TEXT PK`、`entry_kind TEXT`（`blink` \| `diary` \| `voice_note` \| `photo_note`）、`body_md TEXT NOT NULL`、`audio_blob_sha256 TEXT NULL`、`image_blob_sha256s TEXT NOT NULL DEFAULT '[]'`、`source_ref_id TEXT NULL`、`capture_origin TEXT NOT NULL`（`app_ui` \| `share_sheet` \| `cli_capture` \| `mcp_capture` \| `chat_promoted`）、`privacy_level TEXT NOT NULL`（`normal` \| `private`）、`revision INTEGER NOT NULL`、`hlc_ts TEXT NOT NULL`、`created_at TEXT`、`updated_at TEXT`、`deleted_at TEXT NULL` | 统一承载文字闪念、长篇日记、按住说话语音条原件及纸质书随拍原图；`body_md` 存储用户手写 **BFM v1**；语音逐字稿移入派生层 `ai_entry_enrichments.verbatim_transcript_text`，使本表保持 100% 用户创作纯度（`INV-01`） |
| `raw_sources` | `id TEXT PK`、`source_kind TEXT`（`web_article` \| `epub` \| `pdf` \| `book_record`）、`title TEXT`、`authors_json TEXT`、`origin_url TEXT NULL`、`file_blob_sha256 TEXT NULL`、`cover_blob_sha256 TEXT NULL`、`ast_version INTEGER NOT NULL DEFAULT 1`、`ingest_state TEXT`（`queued` \| `parsing` \| `ready` \| `failed`）、`ingest_error TEXT NULL`、`text_layer TEXT NOT NULL DEFAULT 'not_applicable'`（`embedded` \| `missing_ocr` \| `not_applicable`）、`reading_progress_json TEXT`、`privacy_level TEXT NOT NULL`、`revision INTEGER`、`hlc_ts TEXT`、`created_at TEXT`、`updated_at TEXT`、`deleted_at TEXT NULL` | 书库与稍后读文献元数据正本；原书 PDF/EPUB 二进制通过 `file_blob_sha256` 指向 `blobs/`；扫描无文本层 PDF 诚实标记 `text_layer = 'missing_ocr'`（`INV-11`） |
| `raw_source_chapters` | `source_id TEXT`、`chapter_id TEXT`（联合主键）、`order_index INTEGER`、`chapter_title TEXT`、`ast_json TEXT NOT NULL`、`plain_text_len INTEGER`、`ast_sha256 TEXT` | 存放纯 Dart 后台 Isolate 归一化产出的确定性双轨章节块级 AST（`plain_text` + 经 `packages/blink_sanitizer` 净化的 `html_sanitized`；网页长文为单章 `ch-001`，EPUB 按脊柱分章） |
| `raw_annotations` | `id TEXT PK`、`source_id TEXT FK`、`anchor_kind TEXT`（`ast_range` \| `pdf_bbox` \| `book_page`）、`anchor_json TEXT NOT NULL`、`quoted_excerpt TEXT NOT NULL`、`note_md TEXT NOT NULL`、`style_token TEXT`、`anchor_status TEXT`（`exact` \| `reanchored` \| `orphan`）、`privacy_level TEXT NOT NULL`、`revision INTEGER`、`hlc_ts TEXT`、`created_at TEXT`、`updated_at TEXT`、`deleted_at TEXT NULL` | 阅读划词高亮与上下文边注正本（`note_md` 采用 BFM v1）；一旦所属 `raw_sources` 为 `private`，本表强制继承 `private` |
| `raw_marginalia_turns` | `id TEXT PK`、`annotation_id TEXT FK`、`turn_index INTEGER`、`role TEXT`（`user` \| `assistant`）、`content_md TEXT NOT NULL`、`model_id TEXT NULL`、`privacy_level TEXT NOT NULL`、`created_at TEXT` | 永久保存围绕某处高亮摘录展开的就地伴读问答上下文（[DEC-010](../decisions.md#dec-010)），只增不改，绝不修改 `raw_annotations.note_md` |
| `raw_tasks` | `id TEXT PK`、`title TEXT NOT NULL`、`status TEXT`（`open` \| `done` \| `deferred` \| `dropped`）、`origin_entry_id TEXT NULL`、`origin_annotation_id TEXT NULL`、`focus_date TEXT NULL`、`completed_at TEXT NULL`、`privacy_level TEXT NOT NULL`、`revision INTEGER`、`hlc_ts TEXT`、`created_at TEXT`、`updated_at TEXT`、`deleted_at TEXT NULL` | 内生柔性待办正本（[DEC-012](../decisions.md#dec-012)），与 BFM `- [ ]`/`- [x]`/`- [>]`/`- [-]` 一一对应，强制保留 `origin_*` 反向链接 |
| `media_blobs` | `sha256 TEXT PK`、`mime_type TEXT NOT NULL`、`byte_size INTEGER NOT NULL`、`width INTEGER NULL`、`height INTEGER NULL`、`duration_ms INTEGER NULL`、`storage_rel_path TEXT NOT NULL`、`created_at TEXT` | 内容寻址去重媒体清单；磁盘路径按 `blobs/<sha256[0:2]>/<sha256[2:4]>/<sha256>` 分桶只读存储 |

### 1.3 派生智能层核心实体（`ai_*`）、隔离 `index/fts.db` 与同步辅助表

| 表名 | 核心列与索引契约 | 派生语义与重建规则 |
| --- | --- | --- |
| `ai_entry_enrichments` | `entry_id TEXT PK`、`intent_tags_json TEXT`、`matched_source_ids_json TEXT`、`verbatim_transcript_text TEXT NULL`、`clean_transcript_md TEXT NULL`、`ocr_extracted_quote TEXT NULL`、`model_id TEXT`、`source_agent TEXT`、`privacy_level TEXT NOT NULL`、`computed_at TEXT` | 承载外置 AI（CLI/MCP）或直连 API 写入的分类标签、书目关联、语音原始逐字稿 `verbatim_transcript_text`、去口头禅整理稿 `clean_transcript_md` 与书页 OCR 识别引文；界面默认展示整理稿并保留一键展开逐字稿与回放原录音 |
| `ai_task_candidates` | `id TEXT PK`、`origin_type TEXT`（`entry` \| `annotation`）、`origin_id TEXT`、`title TEXT NOT NULL`、`rationale_md TEXT`、`suggested_focus_date TEXT NULL`、`status TEXT`（`pending` \| `accepted` \| `dismissed`）、`privacy_level TEXT NOT NULL`、`model_id TEXT`、`computed_at TEXT` | 统一承载外置或直连 AI 从闪念与批注中识别出的柔性待办候选，仅在用户确认后才在 `raw_tasks` 新建正式待办，绝不静默篡改用户待办清单 |
| `ai_echo_links` | `id TEXT PK`、`subject_type TEXT`、`subject_id TEXT`、`echo_owner_type TEXT`、`echo_owner_id TEXT`、`similarity REAL`、`relation_kind TEXT`（`resonance` \| `contrast` \| `evolution`）、`reason_md TEXT`、`privacy_scope TEXT NOT NULL`、`model_id TEXT`、`computed_at TEXT` | 由外置 AI 写入的“跨时空观点回响”关联边（语义向量检索交由外置 AI 自持；若未来 [#15](https://github.com/chialecode/blink/issues/15) 开启离线语义检索，可按需在 `index/vectors.db` 增加纯 Dart Isolate `Int8List` 量化扫描，不影响本表） |
| `ai_syntheses` | `id TEXT PK`、`synth_kind TEXT`（`morning_brief` \| `evening_reconcile` \| `weekly_review` \| `book_synthesis` \| `topic_page` \| `chat_summary`）、`period_key TEXT`、`target_source_id TEXT NULL`、`title TEXT NOT NULL`、`privacy_scope TEXT`（`normal_only` \| `local_with_private`）、`render_surface TEXT NOT NULL`（`surface1_native` \| `surface2_sandbox`）、`summary_md TEXT NOT NULL`、`view_html TEXT NOT NULL`、`artifact_html TEXT NULL`、`citations_json TEXT NOT NULL`、`model_id TEXT`、`source_agent TEXT`、`computed_at TEXT` | 双表面高表现力综述与整页产物：必含可检索 `summary_md` 与 Surface 1 原生回退/预览 `view_html`，当 `render_surface = 'surface2_sandbox'` 时额外携带经 `packages/blink_sanitizer` 净化的整页 `artifact_html`；入库时强制校验全部 `<blink-ref>` 与 `citations_json` 命中当前 `privacy_scope` 真实原文 ID |
| `ai_user_principles` | `id TEXT PK`、`topic_slug TEXT`、`statement_md TEXT NOT NULL`、`view_html TEXT NULL`、`status TEXT`（`candidate` \| `confirmed` \| `superseded` \| `rejected`）、`evidence_ids_json TEXT NOT NULL`、`supersedes_id TEXT NULL`、`privacy_level TEXT NOT NULL`、`updated_at TEXT` | 个人认知与原则演进账本；外置/内置 AI 仅允许写入 `status = 'candidate'`，仅用户确认后升格 `confirmed`，演进时经 `supersedes_id` 链接旧条目 |
| `ai_bfm_links` | `id TEXT PK`、`src_type TEXT`、`src_id TEXT`、`target_kind TEXT`（`entry` \| `annotation` \| `source` \| `ai` \| `title_query`）、`target_id TEXT NULL`、`anchor TEXT NULL`、`privacy_level TEXT NOT NULL` | 从 BFM v1 解析出的结构化引用与 AI 嵌入关系边表，支撑反向链接查询、跨隐私脱敏检查与 `INV-09` 全量重算 |

**隔离全文索引库（`index/fts.db`）与本地/同步辅助表**：

- **`index/fts.db`（零扩展 CJK FTS5）**：拆分为 `fts_normal` 与 `fts_private` 两张 FTS5 虚表，采用 SQLite 内置 **`tokenize = 'unicode61 remove_diacritics 2'`** 配合 `packages/blink_core` 内约 25 行确定性 CJK 字符分隔预分词器 `cjk_fts_pretokenize(bfm_to_plain_text(...))`（遍历 `.runes` 在中日韩表意文字与假名/谚文两侧插入空格、保持拉丁字母与数字连续词完整，查询端对连续汉字自动转为相邻短语查询如 `"系 统 思 考"`），在五端与 `dart build cli` 零外部扩展支持单字、双字、长词及中英混排 BM25 检索，并使 `db/blink.db` 保持轻量、`VACUUM INTO` `< 1 s`。
- **同步与缓存辅助表**：`sync_oplog`（全局单调 `seq_id INTEGER PRIMARY KEY AUTOINCREMENT` + 因果字段 `device_id`、`client_op_id`、`hlc_ts`、`entity_layer`、`op_origin`、`payload_json`）、`outbox_ops`（端侧离线待推队列）、`sync_devices`（仅存配对设备令牌的 `SHA-256` 哈希）、`sync_state`（直连游标与 WebDAV/S3 分段水位线）、`media_cache_index`（移动端大体积原书 LRU 缓存清单，`INV-12`）。

<a id="bfm"></a>
## 2. BLINK 扩展 Markdown（BFM v1）内容模型与检索降解

为兼顾日常在 BLINK 内部高效记录与阅读的表达力、移动端 0ms 中文输入法稳定性及十年后脱离软件的纯文本可读性，手写原文层（`raw_entries.body_md`、`raw_annotations.note_md`）统一采用 **BFM v1**（[DEC-024](../decisions.md#dec-024)）。全仓仅由纯 Dart 单一解析包 **`packages/blink_core`**（基于官方 `package:markdown 7.3.1`，BSD-3-Clause，零 Flutter 依赖）统一解析，彻底消除跨语言解析漂移，并由 `packages/blink_core/test/fixtures/bfm_conformance.json` 黄金夹具在 `dart test` 门禁校验。

**语法基线**：CommonMark + GFM（标题、粗斜体、删除线、列表、引用、围栏代码块、管道表格、链接、分隔线），并在 `packages/blink_core` 内补齐 **CJK 友好强调边界规则**（对齐 CommonMark `#650` 提案，修复 `这是**“中文”**测试` 与 `**结论。**下句` 无空格紧邻全角标点时强调不闭合的缺陷）。用户手写原始 HTML 仅放行 `<details>` / `<summary>`，其余尖括号标签均在解析期转义，杜绝输入层注入。

### 2.1 BFM v1 九项克制扩展语法契约

| 类别 | BFM v1 语法 | 编译语义 HTML 目标（进入 `BlinkHtmlWidgetFactory`） | `bfm_to_plain_text()` 索引提取规则 |
| --- | --- | --- | --- |
| **1. 链接与引用** | `[[entry:<uuidv7>\|显示标题]]`<br>`[[ann:<uuidv7>\|批注名]]`<br>`[[book:<uuidv7>\|《书名》]]`<br>`[[book:<uuidv7>#p42\|P.42]]`<br>`[[book:<uuidv7>#ch-003/b-0001-9f2a1c04\|§3]]`<br>未绑定模糊名：`[[标题]]` | `<blink-ref id="<uuid>" kind="entry\|annotation\|source" anchor="...">Label</blink-ref>`（无前缀时 `kind="title_query"`，绝不静默改写原文） | 仅保留 `显示标题` / `《书名》`，剥离 UUID 与 `#anchor`；关系边写入 `ai_bfm_links` |
| **2. 层级标签** | `#标签`、`#parent/child`（Unicode 中英文/数字/`_`/`-`） | `<blink-tag name="parent/child">#parent/child</blink-tag>` | 保留语义词 `parent child` 入 FTS5；忽略 URL 片段、十六进制色值与代码内 `#` |
| **3. 隐私边界令牌** | `#private`（大小写不敏感独立词边界） | `<blink-tag name="private" data-privacy="private">🔒 #private</blink-tag>` | **从检索正文剥离**，单向锁存 `privacy_level = 'private'`（`INV-03`） |
| **4. 内生待办** | `- [ ]`（`open`）\| `- [x]`（`done`）\| `- [>]`（`deferred`）\| `- [-]`（`dropped`） | `<li class="task-item" data-task-status="open\|done\|deferred\|dropped">...</li>` | 剥离复选符号，正文入 FTS5，同步映射 `raw_tasks` |
| **5. 书目与时间绑定** | `@book:<uuidv7>\|《书名》`（可选 `#p84`/`#ch-003`）<br>`@t[14:25]` 或 `@t[01:12:08]` | `<blink-ref id="<uuid>" kind="source" anchor="..." data-bind="context">《书名》</blink-ref>`<br>`<blink-time sec="865">14:25</blink-time>` | `@book:` 保留书名并写入 `source_ref_id`；`@t[...]` 从语义正文剥离，供语音跳转 |
| **6. 提示块（Callout）** | `> [!note\|insight\|tension\|quote\|warning] 标题`<br>折叠态：`> [!insight]- 标题`（默认收起）/ `> [!insight]+` | `<aside class="callout callout-insight">...</aside>` 或 `<details class="callout callout-insight"><summary>标题</summary>...</details>` | 剥离 `[!insight]` 标记，保留标题与正文 |
| **7. 折叠块** | `:::fold 折叠标题`<br>`内容...`<br>`:::`（兼容 `<details><summary>`） | `<details><summary>折叠标题</summary>...</details>` | 剥离 `:::fold` 围栏，保留标题与内容 |
| **8. 高亮与脚注** | `==重点高亮==`<br>`正文[^1]` + `[^1]: 注释` | `<mark>重点高亮</mark>`<br>`<sup><a href="#fn-1">[1]</a></sup>` + `<section class="footnotes">` | 剥离 `==` 与角标，脚注正文归入末尾可检索段落 |
| **9. 可选数学与只读 AI 嵌入槽** | 数学（v1 保留语法，M5/LOOP 可选原生排版）：`$E=mc^2$`（严格非空白边界，不误触 `$5`）/ `$$...$$`<br>AI 只读嵌入槽：`![[ai:<uuidv7>\|可选说明]]` | `<blink-math display="inline\|block">...</blink-math>`<br>`<blink-embed kind="ai" id="<uuid>">可选说明</blink-embed>` | 数学剥离 `$` 保留表达式；**`![[ai:...]]` 严禁把 AI 生成内容混入原文层 FTS/向量块**，仅登记指针边，防止派生反馈污染与守护 `INV-01`/`INV-09` |

**手写原文与外置/直连 AI 产物的不可逾越边界（`INV-01` & `INV-03`）**：

- 用户点击“将 AI 卡片钉入日记”时，仅由客户端在 `raw_entries.body_md` 写入不可变指针 `![[ai:<uuidv7>|说明]]`（绝不拷贝 AI HTML 正文进原文层）；若派生层清空重建（`INV-09`），原文分毫不损，渲染层显示非破坏占位提示。
- 跨隐私引用保护：当 `normal` 条目含 `[[entry:<private_uuid>]]` 或 `![[ai:<private_uuid>]]` 时，`normal_only` MCP/CLI 查询、直连常规模型上下文与公开镜像导出均**绝不解引用**私密目标，统一脱敏为 `[private-ref]` / `[标题 (私密条目)]`。

<a id="document-ast"></a>
## 3. 统一文档块级 AST 与伴读批注锚点

网页剪藏长文与重排式 EPUB 统一在纯 Dart 后台 Isolate 中由 `package:html 0.15.7`（CJK Readability + SSRF 防护）、`package:archive 4.6.0`（Zip-Slip/Zip-Bomb 防护）、`package:xml 7.1.0` 与 `packages/blink_sanitizer` 归一化为 **`ast_version: 1` 双轨文档块级 AST**，交由客户端 `super_sliver_list` + `flutter_widget_from_html_core` + `fwfh_svg` + `SelectableRegion` 五端纯原生渲染（[DEC-023](../decisions.md#dec-023)、[DEC-024](../decisions.md#dec-024)）。

### 3.1 统一章节双轨块级 AST JSON 结构（`plain_text` + `html_sanitized`）

- **双轨字段分工**：每个内容块同时携带归一化纯文本 `plain_text`（按 `html_sanitized` 的 DOM 文本节点先序拼接生成，供确定性 `block_id` 哈希、`ast_range` 码点锚定与 `index/fts.db` 检索）与经 `packages/blink_sanitizer` 净化的语义 HTML 片段 `html_sanitized`（保留 `rowspan`/`colspan` 跨行列合并表格、提示框 `<aside class="callout">`、折叠块 `<details>`、上下标 `<sub>`/`<sup>`、东亚注音 `<ruby><rt>` 及行内强调）。
- **确定性 `block_id` 生成规则**：对章节内第 `i` 个顶层块（从 `0` 起计），取其归一化 `plain_text`（图像块取 `blob_sha256`）计算 `SHA-256` 前 8 位十六进制，编码为 `b-<4位零填充序号>-<hash8>`（如 `b-0014-9f2a1c04`）。
- **Dart `.runes` Unicode 标量码点统一度量衡（`INV-10`）**：Dart 的 `String.length` 按 UTF-16 代码单元计数（生僻汉字 CJK 扩展 B 区与 Emoji 代理对占 2 单元），因此所有 `offset` 一律定义为块内 `plain_text` 的 **Unicode 标量值索引（`.runes`，从 `0` 起计，左闭右开 `[start, end)`）**。`packages/blink_core` 统一提供经测试验证的 `codePointToUtf16Index()` 与 `utf16ToCodePointIndex()`（结合 `package:characters 1.4.1`），由解析器与 `SelectableRegion` 选区映射共用，彻底消除代理对与内联标签导致的划词漂移。

```json
{
  "ast_version": 1,
  "source_id": "019349c8-7c10-7b22-9a11-4058c2e90101",
  "chapter_id": "ch-003",
  "order_index": 2,
  "chapter_title": "第三章 记忆的外部化与工具边界",
  "blocks": [
    {
      "block_id": "b-0000-3c81e04a",
      "type": "heading",
      "level": 2,
      "plain_text": "第三章 记忆的外部化与工具边界",
      "html_sanitized": "<h2>第三章 记忆的外部化与工具边界</h2>"
    },
    {
      "block_id": "b-0001-9f2a1c04",
      "type": "paragraph",
      "plain_text": "真正持久的笔记系统首先必须尊重原始语境，而不是强迫作者在灵光闪现的那一秒先去发明分类目录。",
      "html_sanitized": "<p>真正持久的笔记系统首先必须尊重<strong>原始语境</strong>，而不是强迫作者在灵光闪现的那一秒先去发明分类目录。</p>"
    },
    {
      "block_id": "b-0002-5e94a110",
      "type": "table",
      "plain_text": "层级\t载体格式\t核心约束\n采集层\tBFM v1\t0ms 录入与原文只读\n阅读与综述层\t双表面受控 HTML\t纯 Dart 白名单净化与主题令牌绑定",
      "html_sanitized": "<table><thead><tr><th>层级</th><th>载体格式</th><th>核心约束</th></tr></thead><tbody><tr><td>采集层</td><td>BFM v1</td><td>0ms 录入与原文只读</td></tr><tr><td>阅读与综述层</td><td>双表面受控 HTML</td><td>纯 Dart 白名单净化与主题令牌绑定</td></tr></tbody></table>"
    },
    {
      "block_id": "b-0003-71d0b512",
      "type": "image",
      "plain_text": "",
      "html_sanitized": "<figure><img src=\"blink-blob://e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\" alt=\"认知循环示意\"><figcaption>图 3-1 瞬时采集与外置 AI 整合</figcaption></figure>",
      "blob_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "width": 1280,
      "height": 720,
      "alt": "认知循环示意",
      "caption": "图 3-1 瞬时采集与外置 AI 整合"
    }
  ]
}
```

受支持的顶层 `block.type` 集合为：`heading`（`level: 1..6`）、`paragraph`、`blockquote`、`callout`、`code_block`（`language`、`plain_text`）、`list_item`、`image`（`blob_sha256`、`width`、`height`、`alt`、`caption`）、`table`（完整支持 `thead`/`tbody` 与 `rowspan`/`colspan`）、`footnote_def` 与 `thematic_break`。书内跳转统一归一化为 `blink-anchor://<chapter_id>#<block_id>`，内嵌图片统一重写为 `blink-blob://<sha256>`。

### 3.2 上下文伴读批注锚点契约（`anchor_json`）与重锚保底

1. **长文与 EPUB 块区间锚点（`anchor_kind = "ast_range"`）**：支持单段内与跨连续块划词，携带前后各 32 个 Unicode 标量码点的上下文指纹：

```json
{
  "kind": "ast_range",
  "chapter_id": "ch-003",
  "start": { "block_id": "b-0001-9f2a1c04", "offset": 15 },
  "end": { "block_id": "b-0001-9f2a1c04", "offset": 19 },
  "quote": {
    "exact": "原始语境",
    "prefix": "真正持久的笔记系统首先必须尊重",
    "suffix": "，而不是强迫作者在灵光闪现的那一秒"
  }
}
```

2. **PDF 归一化几何锚点（`anchor_kind = "pdf_bbox"`）**：客户端 `pdfrx` / `pdfrx_engine` 将 PDF 原生左下角原点坐标统一转为**页面左上角 `(0, 0)`、宽高归一化至 `[0.0, 1.0]` 闭区间**的与分辨率无关矩形数组：

```json
{
  "kind": "pdf_bbox",
  "page_index": 41,
  "coord_space": "top_left_normalized_0_1",
  "rects": [
    { "x": 0.1420, "y": 0.3185, "w": 0.7150, "h": 0.0238 },
    { "x": 0.1420, "y": 0.3460, "w": 0.4210, "h": 0.0238 }
  ],
  "page_char_range": [184, 239],
  "quote": {
    "exact": "Externalized memory must outlive the application binary."
  }
}
```

3. **三级确定性重锚与防丢保底（`INV-10`）**：一级精确命中 `chapter_id + block_id + offset` 且子串等于 `quote.exact`（`exact`）；二级按同章 `quote.exact` 与前后 32 码点上下文最长公共子串唯一命中后更新坐标（`reanchored`）；三级无法唯一定位时置 `orphan`，在章节及全书批注栏顶部/末尾显式展示 `quoted_excerpt`、手写批注与伴读轮次，绝不静默丢弃。

<a id="generative-html"></a>
## 4. 双表面高表现力 HTML、纯 Dart 净化器与锁定 `<blink-*>` 标签契约

由纯 Dart 共享包 **`packages/blink_sanitizer`**（基于 `package:html 0.15.7` HTML5 树重建 + ~400 行自研 W3C CSS Syntax L3 词法白名单编译器 + `<blink-ref>` 数据库存在性与密级校验，被 Flutter 应用与 `dart build cli` CLI/MCP 共同调用）与客户端双表面渲染器共同执行 `INV-13`（视觉映射见[界面规范](../ui.md#semantic-html)）：

### 4.1 双表面枚举（`render_surface`）与净化边界

| 渲染表面 | 枚举值与存储列 | 渲染引擎与适用场景 | 净化配置与安全硬红线（`INV-13`、`INV-03`） |
| --- | --- | --- | --- |
| **Surface 1（行内原生卡片与阅读块）** | `surface1_native`<br>存储列：`view_html`（AI 卡片 / Surface 2 降级回退）及 `html_sanitized`（阅读块） | 五端 100% 纯 Flutter 原生组件树：`flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `fl_chart 1.3.1` + `BlinkHtmlWidgetFactory`；专用于时间流、伴读正文、边注轨与轻综述卡片（60/120fps，零 WebView 内存开销） | HTML5 DOM 重建放行结构语义标签、`rowspan`/`colspan`、`<details>`/`<summary>`、`<mark>`、纯几何内联 `<svg>` 及下表 Surface 1 原生 `<blink-*>` 组件；剥离 `<script>`/`<iframe>`/`<foreignObject>`/SMIL/`on*`/外链与硬编码字面色值 |
| **Surface 2（整页沙盒 HTML 视图）** | `surface2_sandbox`<br>存储列：`artifact_html`（必配 `view_html` 作为预览卡片与回退） | 按需在独立全屏/详页打开的零 JS 离线沙盒视图（Win/macOS/Android/iOS 用 `flutter_inappwebview 6.1.5`；Linux 用 `desktop_webview_window 0.4.3` 动态链接系统 `libwebkit2gtk-4.1-0` + `libsoup-3.0-0`，[DEC-026](../decisions.md#dec-026)，缺库自动降级 Surface 1）；承接复杂 CSS Grid / Flexbox / 渐变 / 完整 SVG 杂志页 | 在 DOM 净化基础上放行受控 `<style>` 块（经 W3C CSS Syntax L3 词法器过滤，彻底阻断 `url(...)` 含大小写与 `\75 rl` 十六进制转义、`@import`、`expression()` 及硬编码前背景色，仅允许 `var(--blink-*)` 宿主主题变量）；叠加浏览器强制离线 CSP `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src blink-blob: data:; font-src 'self' data:`、无痕模式及外部网络硬拦截 |

**结构化入库诊断（External-AI 自修复闭环）**：外置 AI 通过 CLI/MCP 调用 `blink_validate_html` 或 `blink_publish_synthesis` 时，`packages/blink_sanitizer` 同步返回结构化错误/告警码（`E_DISALLOWED_TAG`、`E_CSS_URL_BLOCKED`、`E_RAW_COLOR_LITERAL`、`E_BROKEN_BLINK_REF`、`E_PRIVACY_SCOPE_VIOLATION`、`W_SURFACE1_SVG_TEXT`），拒绝不合规 HTML 并指导外置 AI 立即自修。

### 4.2 锁定自定义 `<blink-*>` HTML 标签与生产者契约

本表为 `packages/blink_core`（BFM 编译器）、`packages/blink_sanitizer`、`BlinkHtmlWidgetFactory` 与外置 `blink-html-card-author` 技能共用的唯一权威契约：

| 自定义标签 | 允许属性与校验规则 | 允许生产者 | 子节点约束 | Surface 1 渲染 / Surface 2 与镜像映射 |
| --- | --- | --- | --- | --- |
| **`<blink-ref>`** | `id`（除 `title_query` 外必填：小写 UUIDv7）；`kind`（必填枚举：`entry` \| `annotation` \| `source` \| `title_query`）；`anchor`（可选：`^p[1-9][0-9]*$` 或 `^ch-[a-zA-Z0-9_-]+(?:/b-[0-9]{4}-[0-9a-f]{8})?$`）；`data-bind`（可选 BFM 专用：`context`） | **用户 BFM** 与 **AI 派生视图**（共享） | 仅纯文本标签（剥离嵌套 HTML） | Surface 1：`InlineCustomWidget` 溯源胶囊 → 唤起原文预览浮层/半屏抽屉；Surface 2：编译为 `<a class="blink-ref" href="blink-ref://<kind>/<id>?anchor=...">` 由导航拦截原生回跳（零 JS）；镜像：标准相对 `.md` 链接 |
| **`<blink-embed>`** | `kind`（必填枚举：`ai`）；`id`（必填小写 UUIDv7，指向 `ai_syntheses` / `ai_user_principles`） | **仅用户 BFM**（**严禁**外置 AI 输出，杜绝递归嵌入循环） | 仅纯文本说明 | Surface 1 目标：行内渲染 `surface.aiDerived` 只读卡；Surface 2 目标：行内渲染紧凑预览横幅 + “打开完整页面”按钮；镜像：`> ✦ AI 派生视图：[说明](../../insights/<path>.html)（[纯文本摘要](../../insights/<path>.md)）` |
| **`<blink-tag>`** | `name`（必填 1～64 字符路径，无空白/控制符）；`data-privacy`（仅当 `name == "private"` 时输出 `private`） | **仅用户 BFM** | 仅纯文本 `#<name>` | 原生标签胶囊（私密态采用 `privacy.private` 青绿锁标）；镜像原样保留 `#<name>` |
| **`<blink-time>`** | `sec`（必填非负整数 `^[0-9]{1,7}$`） | **仅用户 BFM** | 仅纯文本 `mm:ss`/`hh:mm:ss` | `tabular-nums` 时间胶囊（语音条点击跳转播放进度）；镜像降级为行内代码 `` `14:25` `` |
| **`<blink-math>`** | `display`（必填枚举：`inline` \| `block`） | **用户 BFM** 与 **AI 派生视图**（共享） | HTML 转义后的纯 LaTeX 文本 | M3～M5 呈现等宽 `<code class="math">`；可选后续接入纯 Dart 原生公式排版（`val_latex_flutter` / `flutter_math_fork_fork`）；镜像原样保留 `$...$` / `$$...$$` |
| **`<blink-grid>` / `<blink-card>` / `<blink-metric>` / `<blink-timeline>` / `<blink-compare>` / `<blink-chart>`** | 受控布局与数据属性（如 `cols`、`tone`、`label`、`value`、`chart-type`、`data-json` 经严格数值/结构校验） | **仅 AI Surface 1 `view_html`**（不从用户手写 BFM 解析） | 按对应原生组件子结构约束 | 由 `BlinkHtmlWidgetFactory` 直接映射为自适应双栏 Bento 网格、指标卡、演进时间轴、对比卡与原生 `fl_chart` 图表（零 WebView、动态绑定三态主题令牌） |

<a id="sync"></a>
## 5. 全方案多端同步（`SyncTransport`）、冲突保护与 Dart 实时开放镜像

### 5.1 统一因果 OpLog 信封与双模并发写入

无论写入来自端侧 UI、桌面端内嵌同步服务，还是外置 CLI/MCP 写入 `ai_*`（桌面在线走 loopback IPC，桌面离线退回 `BEGIN IMMEDIATE` WAL），均落入同一张 `sync_oplog` 表并携带统一的因果操作信封 `(device_id, client_op_id, hlc_ts, base_revision, entity_layer, op_origin, payload_json)`：

- 端侧操作 `< 16 ms` 在本地 SQLite 单事务同时写入业务表与 `outbox_ops`（`INV-04`）；
- M4 在同一 `SyncTransport` 抽象下统一落地两种互补通道（[DEC-023](../decisions.md#dec-023)、[DEC-032](../decisions.md#dec-032)），用户可按场景单选或混用：

```text
[五端本地写操作 (raw_* / ai_*)] ──> 本地 SQLite 单事务 (< 16ms) + outbox_ops (UUIDv7 client_op_id + hlc_ts)
                                              │
                     ┌────────────────────────┴────────────────────────┐
                     ▼                                                 ▼
      [通道 A：直连纯 Dart shelf 同步]                 [通道 B：端到端加密 WebDAV / S3 异步中继]
  - 桌面端内嵌 shelf 1.4.3 + shelf_router 1.1.5     - 面向主力电脑休眠时的手机异步同步
  - 局域网 mdns_dart (MIT) 800ms 探测 → Tailscale   - 永不上传活态 blink.db！仅按设备前缀追加不可变密文分段：
  - 同源 dart build cli 无头 blink sync serve         oplogs/<device_id>/<batch_uuidv7>.enc
  - 强幂等 sync/push + 单调 seq_id sync/pull          blobs/<hmac_id>.enc
  - Range 断点大文件流 + SSE 实时唤醒               - cryptography 2.9.0 XChaCha20-Poly1305 AEAD + HKDF
                                                    - 纯 Dart WebDAV / S3 SigV4 (dart:io + xml 7.1.0)
                                                    - 按 (hlc_ts, device_id, client_op_id) 确定性因果重放
                                                    - 默认开启“禁止通过 WebDAV/S3 中继 #private”物理过滤开关
```

**端到端加密（E2EE）与 `#private` 边界（通道 B）**：

- 主同步密钥（Vault Sync Master Key）与设备同步令牌、WebDAV/S3 凭据全部仅保存于各设备 OS 原生安全密钥库（Windows DPAPI `<dataRoot>/credentials/*.dpapi`、Android Keystore AES-256-GCM `<noBackupFilesDir>/blink[-dev]/credentials/*.enc`，`INV-08`），通过本地配对或可打印恢复码在设备间安全导入，WebDAV/S3 服务商全程见到 `0` 字节明文；
- 默认开启“禁止通过 WebDAV/S3 中继 `#private`”后，所有 `privacy_level = 'private'` 的操作与附件被物理排除出中继上传队列，仅经局域网或 Tailscale 直连通道 A 同步（`INV-03`）。

### 5.2 确定性并发冲突保护策略

当两台设备在同步收敛前离线修改了同一实体时，直连通道 A 与中继通道 B 执行完全一致的确定性合并规则，**严禁以后写覆盖（LWW）静默吞掉用户写下的任何文字（`INV-01`、`INV-05`）**：

| 实体与操作类型 | 离线并发冲突判定 | 确定性合并与保护动作 |
| --- | --- | --- |
| 新建闪念、语音、剪藏、新批注、新伴读轮次 | 各端独立生成 UUIDv7，主键互不重叠 | 零冲突并集入库，按创建时间与 `hlc_ts` 稳定排序 |
| 同一条 `raw_entries.body_md` 或 `raw_annotations.note_md` 双端同时编辑 | `base_revision < 当前 revision` 且正文哈希不同 | **双本保留**：按确定性全序 `(hlc_ts, device_id, client_op_id)` 接纳胜出分支为新 `revision`，同时将另一分支自动另存为带关联引用的冲突保护副本（首行标注 `[离线冲突副本 · <设备名> <UTC时间>]`），并在顶栏温和提示一键比对合并 |
| `privacy_level` 密级变更 | 一端为 `normal`、另一端设为 `private`（或含 `#private`） | **高密级单向锁存（`private` 恒胜）**：合并结果必为 `private`，同时立即将其从公开中继队列与 `fts_normal` 中剔除 |
| 阅读进度 `reading_progress_json` 与待办状态 `raw_tasks.status` | 标量状态并发变更 | 按 `hlc_ts` 取最新状态；阅读器若检测到远端进度领先超过 1 页/5 块，底部弹出非阻塞“跳至另一设备最新位置”提示条 |
| 删除墓碑 vs 正文编辑 | 一端删除，另一端离线新增编辑或批注 | **有新内容则复活保留**：编辑端胜出（清除 `deleted_at`），防止误删另一端刚写完的心得 |
| 派生层 `ai_*`（综述、回响、富化）并发写入 | 同业务键并发重算 | 按 `(computed_at, hlc_ts)` 幂等覆盖派生投影，不产生干扰性正文冲突副本 |

### 5.3 桌面端 Dart 后台 Isolate 实时开放镜像（BFM 降级 `.md` + 独立自适应 `insights/*.html`）

为确保十年后即便不再运行本软件，用户的全部思考、书摘、批注与 AI 综述依然是任何文本编辑器与本地浏览器可直接阅读检索的开放资产（[DEC-024](../decisions.md#dec-024)、[Q-004](https://github.com/chialecode/blink/issues/6)），`packages/blink_core` 内置纯 Dart `MirrorExporter`（桌面端运行于独立后台 Isolate，亦可经 `blink mirror sync` 手动触发）：

- **触发节奏与纯 Dart 原子落盘（`INV-07`）**：监听 `sync_oplog` 推进事件，在最近一次写入静止 **5 秒防抖**后增量重写受影响文件（启动时比对 `mirror_watermark_seq` 补齐差额）。每次写出严格执行纯 `dart:io` 原子流程：写入同目录 `.<filename>.<micros>.blink-tmp` → `RandomAccessFile.writeFrom()` → `await raf.flush()` → `close()` → `File.rename()`（Windows 捕获 `FileSystemException` 文件锁并执行有界退避重试，中断不留残缺文件）。
- **BFM v1 → 十年可读标准 GFM 无损降级规则（`bfm_to_mirror_md()`）**：
  - 每条导出记录头部写入轻量锚点 `<a id="entry-<uuid8>"></a>`，使跨文件相对链接可直接跳转；
  - `[[entry|ann|book:<uuid>#anchor|标签]]` 与 `@book:...` 解析为镜像仓标准相对链接（如 `[记忆外部化](../../stream/2026/11/2026-11-22.md#entry-019349c8)`）；若 `normal` 条目引用了 `private` 目标，降级为 `[标签 (私密条目)]`，零路径泄露；
  - `#tag`、`#private`、`- [ ]`、`- [x]`、`[^1]` 与 `$...$` / `$$...$$` 原样保留；`- [>]` 降级为 `- [ ] [顺延]`，`- [-]` 降级为 `- [x] ~~[放弃]~~`，`@t[14:25]` 降级为 `` `14:25` ``；
  - `> [!insight] 标题` 降级为标准引用/告警块（`> **💡 洞察 · 标题**`）；`:::fold 标题 ... :::` 编译为标准 `<details><summary>标题</summary>...</details>`；`==高亮==` 编译为 `<mark>高亮</mark>`；
  - `![[ai:<uuid>|说明]]` 降级为指向独立综述归档的清晰链接：`> ✦ AI 派生视图：[说明](../../insights/<path>.html)（[纯文本摘要](../../insights/<path>.md)）`，绝不将冗长 HTML 塞入纯文本笔记。
- **双形态无锁定归档与隐私隔离**：`insights/` 同步导出纯文本 `.md` 摘要与单文件自包含 `.html`（内嵌 `@media (prefers-color-scheme: dark)` 与 `--blink-*` 变量轻量 `<style>`、净化后的 Surface 1/2 内容及指向同仓 `.md` 的相对链接；**零 `<script>`、零外链请求**）。用户删除的镜像文件移入 `.archived/`（`INV-12`）；`#private` 条目与 `local_with_private` 综述物理分置于 `0700` 权限的 `private/` 子树。

```text
<BLINK_VAULT_DIR>/mirror/
├── markdown/
│   ├── stream/
│   │   └── 2026/11/2026-11-22.md                        # 当日非私密 BFM 降级标准 Markdown 时间流
│   ├── sources/
│   │   ├── books/2026-thinking-in-systems-9a1f2c08.md   # 书目信息 + 章节/页码高亮、批注与伴读问答
│   │   └── articles/2026-11-22-local-first-4b82d190.md  # 网页剪藏清洗后的 Markdown 正文 + 边注列表
│   ├── tasks/
│   │   └── open-tasks.md                                # 当前待办与近期已完成记录（附来源相对链接）
│   └── private/                                         # 目录权限 0700：仅存放 privacy_level = private 的 .md 镜像
│       ├── stream/2026/11/2026-11-22.md
│       └── sources/...
├── insights/
│   ├── briefs/2026-11-22-brief.md                       # 晨间简报纯文本主归档
│   ├── briefs/2026-11-22-brief.html                     # 晨间简报独立自适应静态 HTML（零脚本/零外链）
│   ├── reviews/2026-W47-review.md                       # 周度认知复盘纯文本主归档
│   ├── reviews/2026-W47-review.html                     # 周度认知复盘高表现力整页静态 HTML
│   ├── books/2026-thinking-in-systems-9a1f2c08.html     # 单书深度综述独立 HTML（配同名 .md 摘要）
│   ├── principles.md                                    # 已确认个人认知与原则账本（Markdown 正本）
│   └── principles.html                                  # 个人原则演进对比卡片独立 HTML 视图
├── private/                                             # 目录权限 0700：仅存放 local_with_private 的独立 HTML 综述
│   └── insights/...
└── .archived/                                           # 已删除记录的软归档副本（不直接物理抹除，INV-12）
```
