# 智能与阅读管线设计：无后端双轨 AI（CLI/MCP/Skills 与直连兼容接口）、隐私硬隔离与纯 Dart 多媒体伴读

本文件定义 BLINK 在纯 Flutter/Dart 无后端架构（[DEC-022](../decisions.md#dec-022)～[DEC-026](../decisions.md#dec-026)）下的**双轨解耦 AI 扩展契约**（轨一外置 AI CLI/MCP/Skills 优先 + 轨二可选内置直连 OpenAI 兼容 HTTP 客户端）、**`#private` 全链路零出境硬隔离机制**，以及运行在纯 Dart 后台 `Isolate` 中的网页剪藏、EPUB 重排、PDF 伴读与语音/书页采集管线。系统运行拓扑与单仓库分层见[系统架构设计](architecture.md#topology)，数据表模型、BFM v1 与双表面 HTML 契约见[数据、文档 AST 与同步镜像](data-and-sync.md#layers)。

<a id="dual-speed-agent"></a>
## 1. 无后端双轨解耦 AI 架构（Dual-Track Server-Free AI）

BLINK 保留“写入态轻量整理 + 周期性深度综合 + 伴读即时追问”的双速认知模型（[DEC-011](../decisions.md#dec-011)）与“原文层不可篡改、派生层可全量重建”的铁律（`INV-01`、`INV-09`），但**彻底取消常驻 Python 服务端与强制内置重型推理运行时**（[DEC-025](../decisions.md#dec-025)），将 AI 能力解耦为共享同一 `ai_*` 派生数据层与同一双表面 HTML 渲染器的两条无后端轨道：

| 维度 | 轨一（主轨）：外置 AI 接口（CLI / MCP Server / `agentskills.io` Skills） | 轨二（可选模块化）：内置直连 OpenAI 兼容客户端（`OpenAiCompatClient`） |
| --- | --- | --- |
| 适用场景 | 由外部编码代理（Claude Code、Antigravity、Cursor、Codex、Claude Desktop）、定时脚本或用户自建通用 AI Gateway 驱动晨间简报、周报、单书深度综述、回响计算、语音/OCR 外部回填与批量归类 | 用户在五端应用内直接按需发起阅读划词伴读追问、轻量 AI 对话，以及一键将对话总结固化为派生卡片或新笔记（不依赖任何 BLINK 后端服务） |
| 运行与依赖 | 纯 Dart 独立原生二进制束 `packages/blink_cli`（`dart build cli` 打包，自带 `libsqlite3`）+ `packages/blink_skills`；零 Python、零 Node.js、零 Docker | 位于 `packages/blink_core`，直接复用 `dio` 调用标准 `/v1/chat/completions`（SSE 流式）等 OpenAI 兼容 HTTP 接口，直连云端、本机 Ollama `/v1` 或通用 AI Gateway |
| 允许写入的数据层 | 通过 `ExternalAiRepository` **严格仅写 `ai_*` 派生表**（`ai_entry_enrichments`、`ai_echo_links`、`ai_syntheses`、`ai_user_principles[status='candidate']`、`ai_task_candidates`）；可选追加新建 `raw_entries`（MCP 默认关闭，须 `--allow-capture`） | 伴读问答只增不改追加至 `raw_marginalia_turns`；对话总结转笔记仅写入 `ai_syntheses` 卡片或经用户显式确认后**新建**一条带来源引用的 `raw_entries`，绝不修改既有原文 |
| `#private` 隔离机制 | 4 层默认闭锁防线：默认 `--scope normal_only` 物理视图过滤 + 3 门禁 `local_with_private` 本机提权 + 单向密级污染锁存 | 强制拆分 `normal` 与 `private_local` 双配置档位，`#private` 仅允许解析至环回/RFC1918/Tailscale IP 的本地端点，不可用即闭锁返回 `privacy_blocked` |
| 离线与未配置降级 | 核心应用 100% 离线读写检索不受影响；桌面端关闭时 CLI/MCP 透明退回 `BEGIN IMMEDIATE` 直写 WAL 并在下次启动时同步至移动端 | 未配置端点时核心功能完全独立可用且不弹配置向导；断网或端点不可达时返回结构化错误，不阻塞本地伴读与笔记录入 |

> 向量索引边界：核心 MVP 不在客户端捆绑跨平台原生向量扩展（避免 iOS 动态库加载限制与五端构建膨胀）。默认由外置 AI 按需自行维护向量库并把预计算结果写入 `ai_echo_links` 供五端零延迟展示；若未来需要纯离线端侧语义召回，作为可选 [#15](https://github.com/chialecode/blink/issues/15) 在后台 Dart `Isolate` 中对 `index/vectors.db` 的 `Int8List` 量化 BLOB 执行余弦扫描（[选型研究](../research/2026-11-22-pure-dart-pivot.md#storage-sync)）。

<a id="external-ai-mcp"></a>
### 1.1 轨一：纯 Dart CLI 与 MCP Server（`packages/blink_cli`）

#### 工具链与原生打包（`dart build cli`）
- **核心依赖（全宽松许可）**：命令行解析采用 `args 2.7.0`（BSD-3-Clause）；MCP 协议栈采用 `mcp_dart 2.4.4`（MIT，原生支持 `2025-11-25` 与 `2026-07-28` 无状态协议、`Stdio` + `Streamable HTTP`、Tools/Resources/Prompts、`ToolAnnotations`、`outputSchema`/`structuredContent` 及消息体上限保护），并封装在内部薄适配层 **`BlinkMcpAdapter`** 之后，保留官方 `dart_mcp`（BSD-3-Clause）`0.6.0+` Streamable HTTP 稳定后无缝切换的零锁定通道；环回 IPC、Streamable HTTP 端点与无头同步共用 `shelf 1.4.3`（BSD-3-Clause）+ `shelf_router 1.1.5`（Apache-2.0）。
- **原生资产构建约束**：因 `packages/blink_core` 依赖的 `sqlite3 3.9.1` 使用 Dart 3.10+ 原生构建钩子（`hook/build.dart`）随包分发启用 FTS5 的 SQLite `3.54.0`，命令行程序统一使用 **`dart build cli -t packages/blink_cli/bin/blink.dart -o dist/blink-cli/`** 构建（而非不支持钩子的 `dart compile exe`），输出自包含原生目录束 `bundle/bin/blink[.exe]`（开发通道 `blink-dev[.exe]`）+ 旁置 `bundle/lib/libsqlite3.{dll,so,dylib}`。用户机器无需安装任何 Dart SDK、Python 或 Node.js。

#### 双模并发协议（桌面端运行中 vs 关闭状态）
多进程直接并发写 SQLite 会面临单写锁竞争（`SQLITE_BUSY`）、Drift 内存流 `notifyUpdates()` 无法感知外部进程写入导致桌面界面不实时刷新，以及镜像导出与 `seq_id` 推送竞态三类隐患。BLINK 采用**读直连 WAL、写双模路由**协议彻底根除上述问题：

```text
[外部 AI Agent / 命令行调用 blink-cli 或 blink-mcp]
         │
         ├── 只读查询 (search / list / show / MCP Read Tools & Resources)
         │     └──> 直接以 OpenMode.readOnly + PRAGMA query_only=ON; busy_timeout=5000
         │          零锁并发读取 <BLINK_VAULT_DIR>/db/blink.db (WAL) 与 index/fts.db
         │
         └── 派生写入 (ai_* / 可选 blink add)
               │
               ├── 探测 OS 运行时目录 ipc.json (0600，绝不存入便携库 <BLINK_VAULT_DIR>)
               │     ├─ 桌面端在线 ──> POST http://127.0.0.1:<port>/ipc/v1/...
               │     │                 (带 X-Blink-IPC-Token，硬拒含 Origin 头请求)
               │     │                 桌面端单一 Drift 写者事务落盘 -> 分配 sync_oplog seq_id
               │     │                 -> 触发 Drift notifyUpdates() 实时刷新 UI
               │     │                 -> 合并 5s 防抖 mirror/ 导出 & 推送移动端同步唤醒
               │     │
               │     └─ 桌面端离线 ──> 回退直连 SQLite (WAL + busy_timeout=5000 + BEGIN IMMEDIATE)
               │                       同款 ExternalAiRepository 与 packages/blink_sanitizer 校验
               │                       -> 落盘 ai_* + 追加 sync_oplog seq_id
               │                       -> 原子刷新受影响 mirror/ 文件 (INV-07)
               └───────────────────────────────────────────────────────────────────────────
```

#### 最小外部 AI 契约面（MCP Resources、Tools、Prompts 与 CLI）
所有只读返回均把原文与派生字段物理拆分为 `{ "raw": {...}, "ai_derived": {...} }`，防止外部模型将过往 AI 派生稿误认为用户原话；所有工具声明完整 `inputSchema`、`outputSchema`、`structuredContent`、`ToolAnnotations`、游标分页与 `idempotency_key` 幂等键。

- **只读 MCP Resources（`blink://` URI 模板）**：`blink://meta/policy`（当前密级作用域、HTML 契约版本与 `INV-01` 边界）、`blink://stream/date/{YYYY-MM-DD}`、`blink://entry/{entry_id}`、`blink://source/{source_id}/overview`、`blink://source/{source_id}/chapter/{chapter_id}`、`blink://source/{source_id}/annotations`、`blink://tasks/open`、`blink://insights/principles`、`blink://skills/{skill_name}`（供无本地技能目录的纯 MCP 客户端按需读取 `SKILL.md`）。
- **MCP Tools 清单（14 核心 + 1 可选追加采集）**：

| 工具名 | 类别与注解 | 核心输入 | 行为、三段校验闸门与 `seq_id` OpLog |
| --- | --- | --- | --- |
| `blink_search` | 只读（`readOnly: true`） | `query`, `kinds[]?`, `source_id?`, `date_from?`, `date_to?`, `tags[]?`, `limit`（≤50）, `cursor?` | 基于 `index/fts.db`（`unicode61` + CJK 字符预分词）执行 BM25 全文检索，返回摘要片段与主键 |
| `blink_list_entries` | 只读（`readOnly: true`） | `kinds[]?`, `date_from?`, `date_to?`, `since_seq?`, `include_enrichments?`, `limit`, `cursor?` | 时间窗或基于 **`since_seq`** 的增量轮询（支持外部定时任务仅处理新增条目） |
| `blink_get_entry` | 只读（`readOnly: true`） | `entry_ids[]`（批量 ≤20） | 返回完整 `raw` + `ai_derived`、关联待办与回响 |
| `blink_list_library` | 只读（`readOnly: true`） | `source_kinds[]?`, `ingest_state?`, `limit`, `cursor?` | 列出书库与稍后读文献元数据、阅读进度与批注数 |
| `blink_get_source_annotations` | 只读（`readOnly: true`） | `source_id`, `chapter_id?`, `updated_since?`, `limit`, `cursor?` | 返回全部高亮、精确 `anchor_json`、`quoted_excerpt`、`note_md` 与 `raw_marginalia_turns` |
| `blink_get_source_chapter` | 只读（`readOnly: true`） | `source_id`, `chapter_id`（或 PDF 页范围）, `block_offset?`, `limit?` | 分页返回章节归一化 `plain_text` 块与 `block_id` |
| `blink_list_tasks` | 只读（`readOnly: true`） | `status[]?`, `focus_date?`, `limit`, `cursor?` | 查询内生柔性待办及其 `origin_entry_id` / `origin_annotation_id` 反链 |
| `blink_list_insights` | 只读（`readOnly: true`） | `kind: syntheses\|echoes\|principles`, `period_key?`, `source_id?`, `status?`, `limit`, `cursor?` | 查阅既有综述、回响与原则，避免重复生成并支持跨期演进 |
| `blink_validate_html` | 预检（`readOnly: true`） | `surface: surface1_native\|surface2_sandbox`, `html`, `citations[]?` | 同步执行 `packages/blink_sanitizer` 与 `<blink-ref>` 存在性/密级校验，不落库；返回 `{valid, errors[], warnings[], sanitized_html}` 供外置 AI 自修复 |
| `blink_upsert_enrichment` | 派生写（仅 `ai_entry_enrichments`，`destructive: false`） | `entry_id`, `intent_tags[]?`, `matched_source_ids[]?`, `verbatim_transcript_text?`, `clean_transcript_md?`, `ocr_extracted_quote?`, `model_id` | 校验 `entry_id` 存在于当前作用域并继承其 `privacy_level`（不可降级），写入 `ai_entry_enrichments` 并分配 `seq_id` |
| `blink_upsert_echoes` | 派生写（仅 `ai_echo_links`，`destructive: false`） | `links[{subject_type, subject_id, echo_owner_type, echo_owner_id, similarity, relation_kind, reason_md}]`, `model_id` | 校验双端记录均在作用域内；任一端为 `private` 则自动锁存 `privacy_scope = 'local_with_private'`，分配 `seq_id` |
| `blink_publish_synthesis` | 派生写（仅 `ai_syntheses`，`destructive: false`） | `synth_kind`, `period_key`, `target_source_id?`, `title`, `summary_md`, `render_surface`, `view_html`/`artifact_html`, `citations[]`, `model_id`, `idempotency_key` | **三段原子闸门**：① 提取全部 `<blink-ref>` 与 `citations[]` 逐一核对数据库真实性与密级边界（防幻觉与越权引用）；② 运行 `packages/blink_sanitizer`（遇硬违规拒绝落库并返回结构化诊断码）；③ 原子落盘 `ai_syntheses`、分配 `seq_id` 并更新 `mirror/insights/*.{md,html}` |
| `blink_propose_principle` | 派生写（仅 `ai_user_principles`，`destructive: false`） | `topic_slug`, `statement_md`, `view_html?`, `evidence_ids[]`, `supersedes_id?`, `model_id`, `idempotency_key` | **强制锁定 `status = 'candidate'`**（AI 绝不可自确认、驳回或覆写已确认原则）；校验 `evidence_ids[]` 并净化可选 `view_html`，分配 `seq_id` |
| `blink_suggest_tasks` | 派生写（仅 `ai_task_candidates`，`destructive: false`） | `origin_type: entry\|annotation`, `origin_id`, `suggestions[{title, rationale_md, suggested_focus_date?}]`, `model_id` | 写入派生任务候选表供用户在回顾界面柔性确认（[DEC-012](../decisions.md#dec-012)），绝不静默篡改 `raw_tasks` |
| `blink_capture_entry` *(MCP 默认关闭，须 `--allow-capture` 开启，见 [Q-007](https://github.com/chialecode/blink/issues/8))* | 仅追加新建（`raw_entries`，`destructive: false`） | `body_md`, `entry_kind: blink\|diary`, `tags[]?`, `source_ref_id?`, `idempotency_key` | 仅允许追加全新 UUIDv7 收件箱条目（标 `capture_origin = 'mcp_capture'`），执行 `#private` 扫描并分配 `seq_id`；**不存在任何修改或删除既有原文的 MCP 工具** |

- **MCP Prompts**：暴露 `blink-daily-brief`、`blink-weekly-review`、`blink-book-synthesis`、`blink-echoes-discovery` 四个服务端模板，便于不支持本地技能目录的 MCP 客户端一键触发。
- **对称 CLI 子命令树（`blink` / `blink-dev`）**：全部子命令支持 `--json` 输出结构化结果至 `stdout`，日志与告警严格走 `stderr`（不污染管道与 Stdio MCP 帧）：
  - 采集与检索：`blink add "<text>" [--kind blink|diary] [--private]`、`blink search "<q>" [--json]`、`blink list entries|sources|annotations|tasks|principles|syntheses [--since-seq N] [--json]`、`blink show entry|source|chapter|synthesis <id> [--json]`、`blink status [--json]`；
  - 派生写入与净化自检：`blink ai enrich <id> --stdin`、`blink ai echoes upsert --stdin`、`blink ai synth publish --kind <k> --period <p> --md <f> --html <f> [--surface 1|2]`、`blink ai principle propose --stdin`、`blink html validate --surface 1|2 --file <f|-> [--json]`；
  - 人工治理与运维（不向 MCP 暴露）：`blink principle confirm|reject <id>`、`blink sync serve [--bind ...]`（M4 无头同步节点）、`blink backup <dest.db>`（`VACUUM INTO`）；
  - MCP 与技能管理：`blink mcp serve [--transport stdio|http] [--scope normal_only|local_with_private] [--allow-capture]`、`blink mcp config export --client <target> [--stdout|--write]`、`blink mcp token create|list|revoke`、`blink skills list|inspect|install|verify`。

<a id="skills-management"></a>
### 1.2 Agent Skills（`agentskills.io`）与多客户端 MCP 配置管理

- **开放标准与打包治理**：全部内置技能遵循 `agentskills.io` 开放规范（`<skill-name>/SKILL.md` + `references/` + `assets/`，利用 YAML frontmatter 的 `name` 与 `description` 实现渐进式按需加载），统一源码管理于 `packages/blink_skills/` 并附 `manifest.json`（记录 `name`、`version`、`sha256` 与 `min_protocol_version`）。因 `DEC-003` 禁止普通仓库文档使用 YAML frontmatter，`scripts/check_docs.py` 仅对 `packages/blink_skills/skills/**/SKILL.md` 豁免并执行专有 frontmatter 字段校验；用户自建技能独立存放在 `<channel_data_dir>/skills-custom/`，确保升级不覆盖用户编辑（`INV-12`）。
- **5 项内置核心技能（v1）**：
  1. **`blink-daily-brief`**：读取近 24 小时采集流、待办与新增批注 → 产出 `morning_brief` / `evening_reconcile`（Surface 1 `view_html` + `summary_md`）→ 校验后发布并温和提议待办核销；
  2. **`blink-book-synthesis`**：拉取全书批注、锚点与关键章节 → 生成含跨章对比表、内联 SVG 脉络图、`<details>` 原文抽屉与 `<blink-ref kind="annotation">` 溯源胶囊的单书综述，并按需提议 `candidate` 原则；
  3. **`blink-echoes-review`**：跨月/跨年比对近期记录与历史语料 → 归类 `resonance` / `contrast` / `evolution` 写入 `ai_echo_links` 并发布 `weekly_review`；
  4. **`blink-html-card-author`**：**BLINK 受控 HTML/SVG/CSS 卡片与全页编写权威契约技能**，随包携带 `references/surface1-tags.md`（`<blink-grid|card|metric|timeline|compare|chart|ref>` 标签规范及 Surface 1 SVG 限制）、`references/surface2-css-tokens.md`（强制使用 `var(--blink-*)` 三态主题令牌、零原始 `#hex`/`rgb()`、零 `url(...)`、零脚本与外链）及 `assets/` 黄金模板，并要求外置 AI 在发布前**必须先调用 `blink_validate_html`（或 `blink html validate`）**，按结构化诊断码（`E_DISALLOWED_TAG`、`E_CSS_URL_BLOCKED`、`E_RAW_COLOR_LITERAL`、`E_BROKEN_BLINK_REF`、`E_PRIVACY_SCOPE_VIOLATION`、`W_SURFACE1_SVG_TEXT`）自动修正至零错误；
  5. **`blink-inbox-triage`**（可选）：基于 `blink_list_entries(since_seq=...)` 轮询增量条目，在外部完成意图分类、书目关联、转写规整与待办候选建议并回填 `ai_entry_enrichments` / `ai_task_candidates`。
- **多客户端技能同步与一键 MCP 配置导出**：
  - 技能安装（`blink skills install --target <client>` 或桌面设置页一键操作）优先写入公共开放目录 **`~/.agents/skills/`**（或工作区 `.agents/skills/`，同时被 Cursor、OpenAI Codex CLI 与 Google Antigravity 原生识别），并按需同步至 Claude Code（`~/.claude/skills/`）、Cursor（`~/.cursor/skills/`）、Google Antigravity（`~/.gemini/config/skills/`）与 OpenAI Codex（`~/.codex/skills/`）；全过程走临时目录原子替换与清单托管清理（`INV-07`、`INV-12`）。
  - MCP 配置导出支持 Claude Desktop（`%APPDATA%\Claude\claude_desktop_config.json` / `~/Library/Application Support/Claude/claude_desktop_config.json` / `~/.config/Claude/claude_desktop_config.json`）、Claude Code（`~/.claude.json` / `.mcp.json` 及 `claude mcp add` 命令）、Cursor（`~/.cursor/mcp.json` / `.cursor/mcp.json`）、Google Antigravity（`~/.gemini/config/mcp_config.json` / `.agents/mcp_config.json`）、OpenAI Codex（TOML `~/.codex/config.toml` / `.codex/config.toml` `[mcp_servers.blink]`）及通用 Stdio / Streamable HTTP 片段；正式通道注册键名 `"blink"`、开发通道注册 `"blink-dev"`（`INV-06`）；写入前默认展示差异预览，仅无损合并自有键并生成 `*.blink-bak` 原子替换，且**硬锁 `--scope normal_only`，绝不写入任何 `#private` 凭据**。

<a id="in-app-ai-client"></a>
### 1.3 轨二：可选内置直连 OpenAI 兼容客户端（`OpenAiCompatClient`）

为在不引入 BLINK 后端的前提下保留流畅的应用内按需交互能力（如在手机或桌面阅读时随手问 AI、将一段启发式 AI 对话总结收编进知识库），`packages/blink_core` 提供轻量模块化 `OpenAiCompatClient`（零重型 SDK，直接基于 MIT 许可的 `dio` + SSE 解析实现）：

- **通用接口契约**：支持用户自主配置多组 `{profile_name, scope: normal|private_local, base_url, model_id}`（兼容 OpenAI `/v1/chat/completions` 流式响应及可选 `/v1/audio/transcriptions`、多模态视觉输入），可直连任意主流云端兼容 API、本机/家庭内网 Ollama `/v1` 或用户未来的通用 AI Gateway。
- **核心应用内交互（全部严守 `INV-01`）**：
  1. **伴读上下文追问**：在 PDF 第 `p` 页或块级阅读器选区边注栏发起提问，本地组装“高亮摘录 + 局部前后文窗口 + 同书相关批注”发起流式请求，回答以只增不改方式落盘 `raw_marginalia_turns`（完整记录 `model_id` 与 `privacy_level`）；
  2. **应用内对话总结转笔记 / 卡片**：支持将一次应用内 AI 伴读或对话会话一键总结为两种明确形态——**(a) 派生 HTML 综述卡片**（经 `packages/blink_sanitizer` 净化落入 `ai_syntheses`，带 `✦ AI 派生` 标识与来源引用），或 **(b) 经用户编辑确认后新建一条 `raw_entries` 笔记**（附带源会话引用），严禁静默改写任何已有原文条目。
- **未配置零干扰**：默认关闭不依赖任何端点，全部非 AI 采集、编辑、同步、阅读与检索功能零网络依赖运行。

<a id="privacy-routing"></a>
## 2. `#private` 全链路零出境硬隔离与凭据安全边界

个人日记、心理反思与敏感摘录与常规公开读书笔记共存于同一知识库。BLINK 不依赖“提示词要求模型保密”这类软约束，而是在存储视图、外置 MCP/CLI 边界与内置 HTTP 客户端三处同时实施**默认闭锁的物理级硬隔离**（[DEC-025](../decisions.md#dec-025)、`INV-03`、`INV-08`）。

### 2.1 密级判定与单向传染规则

1. **全入口双重识别与防自动降级**：手写 BFM 提交、外部追加采集（`blink add` / `blink_capture_entry`）与多端同步落盘前，均独立执行词边界 `#private` 正则扫描与界面“私密锁”状态核验；任一命中即置为 `privacy_level = "private"`。外置 AI、后台处理与多端同步绝不自动降级私密状态（并发冲突合并时 `private` 恒胜）；仅允许用户在客户端界面主动取消私密（显式传参 `allowPrivacyDowngrade = true`、清除正文独立 `#private` 标签并将检索索引迁回 `fts_normal`，见 [DEC-034](../decisions.md#dec-034)）。
2. **向下与向内单向传染**：
   - 若某本书籍或网页长文 `raw_sources.privacy_level = "private"`，其名下全部章节、高亮、边注、伴读对话、待办与派生综述自动强制继承 `private`；
   - 若任一派生综述、回响边或原则候选引用了至少一条 `private` 记录，其 `privacy_scope` 自动永久锁存为 `local_with_private`。

### 2.2 轨一（外置 CLI / MCP）四层默认闭锁防线

面向外部云端编码代理（Claude Code、Antigravity、Cursor、Codex、Claude Desktop）时，通过四层防线确保 `#private` 零字节误传云端：

1. **第一层（默认 `normal_only` 与防探测错误）**：所有 `blink mcp serve`、CLI 查询及第三方客户端导出配置均无条件默认 `--scope normal_only`。即使外部代理直接猜测或携带 `#private` UUID 调用 `blink_get_entry` 或 `blink://entry/{id}`，服务端统一返回无差别 `not_found`（与不存在记录完全一致，杜绝存在性侧信道与摘要回显，`INV-08`）。
2. **第二层（SQL 物理视图与分离全文索引隔离）**：`normal_only` 模式下 `CloudSafeRepository` 仅查询内置 `WHERE privacy_level = 'normal'`（含继承密级）的 SQLite 只读视图（`v_normal_entries`、`v_normal_sources`、`v_normal_annotations`、`v_normal_chapters`、`v_normal_tasks`）及独立 `index/fts.db` 中的 `fts_normal` 表；`#private` 行从数据源头就**绝不会载入 Dart 进程内存或进入 BM25 词频统计**。
3. **第三层（三门禁显式本机提权 `local_with_private`）**：仅在用户明确连接本机本地模型（如 Ollama/llama.cpp）或自建 AI Gateway 本地私密路由时，方可解锁 `local_with_private`，且须同时满足全部三项硬门禁：
   - **专属作用域令牌**：在桌面设置页或经 `blink mcp token create --scope local_with_private` 单独签发，数据库仅存 `SHA-256` 哈希，明文仅存系统原生密钥仓，绝不落入 `<BLINK_VAULT_DIR>` 或第三方云客户端配置文件；
   - **网络局域性物理校验**：`Streamable HTTP` 模式强制校验监听地址与客户端对端 IP 均属于 `127.0.0.0/8`、`::1`、RFC1918 或 Tailscale（`100.64.0.0/10`），否则立即拒连；`Stdio` 模式须显式传入 `--scope local_with_private --confirm-local-model-only` 并完成本机密钥解锁，同时向 `stderr` 输出显式本地模型警示；
   - **单向密级污染锁存**：`local_with_private` 会话产出的任何派生内容（除非全部引用经校验均为 `normal` 且显式声明）自动标为 `local_with_private`，仅镜像至 `0700` 权限的 `mirror/private/insights/`，此后对一切 `normal_only` MCP 会话永久不可见。
4. **第四层（脱敏审计与哨兵门禁）**：每次 `local_with_private` 访问在本地写入脱敏审计记录（时间戳、传输方式、令牌标签、工具名、返回条数——零正文片段），在桌面端设置页透明可查；自动化哨兵测试（`SPK-05`）验证默认 `normal_only` 覆盖全部 MCP 工具/资源/报错/日志对合成 `#private` 哨兵字符串的暴露字节数为 `0`。

### 2.3 轨二（可选内置直连 `OpenAiCompatClient`）双档位闭锁与凭据卫生

```text
[应用内按需伴读追问 / 对话总结请求] (携带实测 privacy_level)
                    │
                    ▼
        ┌───────────────────────┐
        │   InAppPrivacyGate    │ (零遥测、零错误回显原文)
        └───────────┬───────────┘
                    │
      ┌─────────────┴─────────────┐
      │ privacy_level == private  │ privacy_level == normal
      ▼                           ▼
[private_local 专属档位]     [normal 配置档位]
DNS 解析后固定校验目标 IP：   按用户设置直连云端 OpenAI 兼容接口、
- 127.0.0.0/8, ::1           本地 Ollama /v1 或通用 AI Gateway
- RFC1918 局域网段
- 100.64.0.0/10 (Tailscale)
      │
      ├─ 档位就绪且 IP 合规 ──> 经固定 IP 发起直连请求 (防 DNS 重绑定)
      └─ 未配置 / 离线 / 公网 IP ──> 立即返回 privacy_blocked (绝不回退 normal 档位！)
```

- **端侧凭据铁律（`INV-08`、`NFR-PRIV-002`）**：用户可选填入的 OpenAI 兼容 API Key、设备同步令牌、WebDAV/S3 E2EE 主密钥与 `local_with_private` MCP 令牌一律独立存储在**每台设备自身的操作系统原生密钥仓**（Windows DPAPI、macOS/iOS Keychain、Linux `libsecret`、Android Keystore），**严禁写入便携库 `<BLINK_VAULT_DIR>`、严禁通过同步通道明文复制、严禁出现在运行日志或崩溃转储中**（[存储与安全](architecture.md#storage-security)）。

<a id="reader-pipeline"></a>
## 3. 纯 Dart 后台 `Isolate` 多媒体采集与伴读解析管线

全部输入模态均在客户端离线先行采集并落盘本机 SQLite 与 `blobs/`，结构化解析全部运行在独立后台 Dart **`Isolate`** 中，绝不阻塞 UI 主线程帧率（`INV-02`、`INV-04`），亦无需任何外部 Python 解析服务（[DEC-023](../decisions.md#dec-023)）：

| 输入模态 | 端侧离线采集表现 | 纯 Dart 后台 `Isolate` 解析管线（`packages/blink_core`） | 落库正本与五端伴读形态 |
| --- | --- | --- | --- |
| **网页长文 URL**（M5） | 系统分享面板或粘贴链接秒存 `raw_sources(ingest_state='queued')`，可附随手批注 | 防 SSRF 抓取 → 基于 `package:html 0.15.7` 的 CJK 调优 Readability 抽正文 → 图片去重入 `blobs/` → `packages/blink_sanitizer` 净化为双轨 Block AST | `super_sliver_list` + `flutter_widget_from_html_core` 纯原生块阅读、合并单元格表格与图文离线复读、`ast_range`（`.runes`）零漂移边注 |
| **重排 EPUB 电子书**（M5） | 选择本地 `.epub` 计算 `sha256` 入 `blobs/`，零等待建档 | `archive 4.6.0` 安全解压（防 Zip-Slip/Zip-Bomb）→ `xml 7.1.0` 读 OPF/NCX/Nav → `html 0.15.7` + `packages/blink_sanitizer` 逐章转双轨 Block AST | 五端像素级一致纯原生虚拟滚动阅读器、目录跳章、跨段划词与锚定伴读 |
| **PDF 文献与书籍**（M5） | 本地立即用 `pdfrx 3.1.0` 打开阅读与划词高亮 | 无 UI 依赖的 `pdfrx_engine 0.9.6` 提取目录大纲、封面缩略图与逐页文本入 `index/fts.db`；扫描无字页诚实标 `missing_ocr` | 五端 `pdfrx` 原生分瓦硬件加速缩放、`pdf_bbox` 归一化矩形高亮、双栏/半屏边注与按需缓存释放 |
| **语音闪念与纸质书页拍照**（M7） | `record 6.2.x` 按住说话离线直录 Opus/AAC；相机拍书页配语音感悟，0ms 入时间流 | 原件字节按 `sha256` 永久只读存入 `blobs/`；转写原稿（`verbatim_transcript_text`）、整理稿（`clean_transcript_md`）与书页 OCR 引文（`ocr_extracted_quote`）由外置 AI 经 CLI/MCP 或可选直连 API 写入派生表 `ai_entry_enrichments` | 离线立即可回放原声与查看原图；派生转写/引文就绪后无感呈现并支持一键对照原声与原图，绝不篡改原文层 |

### 3.1 网页长文剪藏管线（防 SSRF + CJK Readability + `packages/blink_sanitizer`）

1. **防内网探测与 DNS 重绑定（SSRF Guard）**：剪藏专用 `dio` 适配器在首次连接与每一次 HTTP 重定向前（最多跟随 5 跳、响应体上限 15 MiB、仅放行 `https://` 与 `http://`）调用 `InternetAddress.lookup` 校验解析结果，硬性拒绝回环地址（`127.0.0.0/8`、`::1`）、RFC1918 私网段、链路本地与云元数据段（`169.254.0.0/16`、`fe80::/10`）及 Tailscale 地址段（`100.64.0.0/10`），并直接锁定已验 IP 发起请求防 DNS 重绑定；绝不读取系统浏览器 Cookie 数据库。
2. **CJK 调优正文提取与静态资源固化**：在后台 `Isolate` 使用基于 `package:html 0.15.7`（MIT/BSD-3-Clause）的自研 Readability 算法（针对中文标点密度与字符权重调优，规避含 MPL-2.0 组件的第三方提取包）剥离导航与广告并提取标题、作者与正文 DOM；正文图片经同一 SSRF 校验器下载（核验文件头魔数并剥离追踪查询串），按 `sha256` 落入 `<BLINK_VAULT_DIR>/blobs/` 并重写为 `blink-blob://<sha256>`，再经 `packages/blink_sanitizer` 清洗输出 `ast_version: 1` 双轨 Block AST（`plain_text` + `html_sanitized`）。
3. **诚实降级处理（`INV-11`）**：遇到登录墙、付费墙、反机器人验证挑战（严守不绕过验证码与访问控制底线）或依赖重度客户端 JS 动态渲染的 SPA 页面时，立即停止抓取并将 `ingest_state` 标为 `failed`（`anti_bot_or_paywall`），向用户提供“在系统浏览器打开”“粘贴剪贴板正文导入”或由外置 CLI/MCP 投递清洗结果的兜底路径。

### 3.2 EPUB 重排电子书归一化管线（`archive` + `xml` + `html` + `.runes`）

1. **容器防穿越与防炸弹校验**：后台 `Isolate` 使用 `package:archive 4.6.0`（MIT）解压 `.epub` 前，逐条核验归档路径（硬拒 `..`、以 `/` 或盘符开头的绝对路径及符号链接，防 Zip-Slip），并在流式读取阶段强制单书总解压上限 512 MiB 与压缩比上限 100:1（防 Zip-Bomb）。
2. **目录解析与双轨 AST 构建**：经 `package:xml 7.1.0`（MIT）解析 `META-INF/container.xml`、`.opf` 脊柱阅读序及 EPUB 2 NCX / EPUB 3 Nav 目录树；逐章由 `package:html 0.15.7` 与 `packages/blink_sanitizer` 剥离脚本、外链样式与硬编码色值，完整保留跨行列合并表格（`rowspan`/`colspan`）、提示框、上下标、`ruby` 注音与内嵌图片（重写为 `blink-blob://<sha256>`，书内跳转重写为 `blink-anchor://<chapter_id>#<block_id>`），组装为 `raw_source_chapters` 章节 AST。
3. **Dart UTF-16 与 Unicode 码点偏移映射硬规则（`INV-10`）**：因 Dart `String.length` 按 UTF-16 代码单元计数（Emoji 与 CJK 扩展区生僻汉字占 2 单元），`packages/blink_core` 统一使用 **Unicode 标量值（`.runes`）**作为全部 `ast_range` 偏移度量衡，并由共享的 `codePointToUtf16Index()` / `utf16ToCodePointIndex()` 映射器（配合 `characters 1.4.1`）贯通解析器与原生阅读器，彻底消除跨端划词错位。对声明 `rendition:layout="pre-paginated"` 的固定版式绘本，标记 `layout_hint = "fixed_layout"` 并如实提示重排边界（见 [Q-001](https://github.com/chialecode/blink/issues/4) 与[交付状态 LOOP](../delivery/roadmap.md#mvp-loop)）。

### 3.3 PDF 伴读管线（五端统一 `pdfrx` + `pdfrx_engine`）

1. **单引擎全栈统一**：前台五端阅读界面通过 `pdfrx 3.1.0`（MIT，底层 PDFium 为 Apache-2.0/BSD-3-Clause）实现本地零等待打开、硬件加速分瓦缩放、CJK 字体保真渲染与左上角归一化 `[0.0, 1.0]` 矩形框（`pdf_bbox`）伴读高亮；后台 `Isolate` 及 `blink_cli` 直接调用无 Flutter UI 依赖的 `pdfrx_engine 0.9.6`（`PdfDocument.loadOutline()`、`PdfPage.loadText()`、`PdfPage.render()`）提取书签大纲、封面缩略图与逐页文本写入 `index/fts.db`，零额外原生库体积增量，且原始 PDF 字节分毫不改（`INV-01`）。
2. **扫描版无文本层诚实降级与外部回填（`INV-11`）**：当 `PdfPage.loadText()` 在整页位图 PDF 上提取有效字符低于阈值时，诚实将页面索引状态标为 `text_layer = "missing_ocr"`。用户无需等待即可直接在 `pdfrx` 上拉框高亮与写边注；后续可通过外置 OCR 工具经 `blink` CLI/MCP 将识别文字写入派生层恢复全文检索，而不修改原始 PDF 文件。
3. **按需缓存回收（`INV-12`）**：移动端在存储紧张时可一键释放未置顶大体积书籍的本地 `blobs/` 副本，书目元数据与全部历史批注仍 100% 离线可读；再次点击阅读时经 M4 同步通道按 `Range` 断点重新拉取原件并原位恢复全部高亮。

### 3.4 语音闪念与纸质书页拍照采集管线（M7）

1. **离线零等待采集**：移动端按住说话与桌面端录音通过 `record 6.2.x`（BSD-3-Clause）直录单声道 16kHz/24kHz Opus/AAC 音频（每分钟约 200～400 KiB），松手瞬间校验 `sha256` 写入 `blobs/` 并 0ms 创建 `raw_entries(entry_kind = "voice_note")`；拍摄实体纸质书页（可同时附语音感悟）同理原图直存 `blobs/` 并生成 `photo_note` 关联至书库 `book_record`。
2. **派生层转写与 OCR 开放回填槽**：核心五端应用不捆绑数百 MB 的本地语音/OCR 权重，而是为语音与书页在派生表 `ai_entry_enrichments` 中预留标准字段（`verbatim_transcript_text`、`clean_transcript_md`、`ocr_extracted_quote`）：
   - **轨一（外置回填）**：外部语音/OCR 工具或通用 AI Gateway 经 `blink_list_entries(since_seq=...)` 拉取待处理音频/图像引用，处理完成后经 `blink_upsert_enrichment` 写回忠实逐字稿、去口头禅可读稿与书页识别引文，自动经 `seq_id` 同步至全部五端；
   - **轨二（可选内置直连接口）**：用户若配置了支持转写/视觉的兼容 API（`#private` 锁定 `private_local` 本机端点），亦可按需单条触发转写或识别；
   - 未回填前界面诚实显示“已安全保存在本机 · 等待外部或可选接口转写/识别”（`INV-11`），原声回放与原图缩放随时可用，原文层记录永不被修改（`INV-01`）；纯离线端侧轻量化 OCR/STT 列入 [#15](https://github.com/chialecode/blink/issues/15)。
