# 系统架构设计：运行拓扑、仓库分层、接口契约与安全不变量

技术设计正本按职责拆分为三份：本页规定纯 Flutter/Dart 五端自包含运行拓扑、单一仓库（Monorepo）分层、跨端与外置 AI 契约、单文件夹便携库与密钥隔离及架构不变量；数据结构、BFM v1、统一块级 AST 与混合同步镜像见[数据模型、文档 AST 与同步镜像](data-and-sync.md)；双轨无服务端 AI、隐私路由与多媒体解析见[外置 AI 扩展、隐私路由与阅读管线](agent-and-reader.md)。现行技术选型依据见[纯 Dart 架构选型研究（2026-11-22）](../research/2026-11-22-pure-dart-pivot.md#overview)，有效决定见[有效决定](../decisions.md#stack-decisions)。

<a id="topology"></a>
## 1. 运行时进程与网络拓扑

BLINK 采用**“纯 Flutter/Dart 五端自包含本地优先应用 + 单文件夹便携知识库 + 双轨多端同步 + 外置优先/内置直连无服务端 AI”**架构（[DEC-022](../decisions.md#dec-022)～[DEC-025](../decisions.md#dec-025)），**运行时零容器编排、零外置数据库进程、零 Python 运行时**：

- **五端 100% 离线优先闭环**：桌面端（`Windows / macOS / Linux`）与移动端（`Android / iOS`）共享同一套纯 Dart `packages/blink_core`（`drift 2.35.4` + `sqlite3 3.9.1` Native Assets），全部 BFM v1 流式录入、日记书写、待办核销、CJK `unicode61` 全文检索、网页/EPUB/PDF 后台 `Isolate` 解析及划词伴读均在本地单事务内 0ms 完成，完全不依赖任何远端服务器。
- **单文件夹便携知识库（`<BLINK_VAULT_DIR>`）**：桌面端将全部资产收敛在单个目录（`vault.json`、`db/blink.db`、`db/backups/`、`index/fts.db`、`blobs/`、`mirror/`），拷贝该目录即完成整库备份与跨机迁移；桌面后台 `Isolate` 以 **5 秒防抖**单向增量导出纯文本 UTF-8 Markdown 与独立自适应 `insights/*.html` 只读开放镜像。移动端在应用沙盒内运行完全一致的 SQLite 结构与按需 LRU 媒体缓存池。
- **统一混合多端同步（`SyncTransport`，M4 已落地，[DEC-032](../decisions.md#dec-032)）**：
  1. **直连高速同步（`DirectShelfTransport`）**：桌面端内嵌纯 Dart `shelf` HTTP/SSE 同步服务，通过局域网纯 Dart `mdns_dart`（MIT，零传递依赖）自动发现优先高速直连，离家后无缝回退 Tailscale / Headscale（WireGuard，`100.64.0.0/10`）虚拟私网；若需 24/7 无头节点，可直接将同一套 `packages/blink_cli` 以 `dart build cli` 编译为单一原生目录包运行 `blink sync serve` 挂载便携库；
  2. **端到端加密异步中继（`EncryptedRelayTransport`）**：当主力电脑休眠时，支持经纯 Dart WebDAV 或 S3（SigV4）兼容存储同步不可变、按设备分前缀的追加式密文 OpLog 段与去重密文附件（客户端 `cryptography` `XChaCha20-Poly1305` 强制 E2EE，远端零明文，且默认开启“禁止经云中继同步 `#private`”）。
- **双轨无服务端 AI 扩展（M6 交付）**：
  1. **Track 1 外置 AI 主轨（CLI / MCP Server / `agentskills.io` Skills）**：由统一原生捆绑包 `packages/blink_cli`（`dart build cli` + `mcp_dart`）对外提供命令行、MCP Stdio 与回环 Streamable HTTP 接口；桌面运行态经 OS 运行目录 `0600` 令牌 `ipc.json` 向桌面回环端点提交衍生写入（毫秒级驱动 `drift.watch()` 刷新 UI 并分配单调 `seq_id`），桌面关闭态经 `BEGIN IMMEDIATE` WAL 冷写落库；默认强制 `--scope normal_only`；
  2. **Track 2 可选内置直连 OpenAI 兼容客户端（`OpenAiCompatClient`）**：在 `packages/blink_core` 基于既有 `dio` 预留轻量 `/v1/chat/completions` SSE 客户端，不依赖任何 BLINK 服务端即可从五端直连外部云 API、本地 `Ollama /v1` 或通用 AI 网关，按 `normal` / `private_local` 分流配置严格守卫 `#private`（`INV-03`）。

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ 五端自包含本地优先应用 apps/blink_client (Windows · Android · Linux · macOS · iOS)       │
│                                                                                        │
│  [ui 层: 自适应外壳 · BFM v1 CJK安全编辑器 · Surface 1 原生阅读/卡片 · Surface 2 沙盒页] │
│         │ (只读状态订阅 + 显式动作命令)                                                 │
│         ▼                                                                              │
│  [application 层: Riverpod 控制器 · IME 组合态保护 · 双表面视图切换 · 诚实状态表达]       │
│         │                                                                              │
│         ▼                                                                              │
│  [packages/blink_core + packages/blink_sanitizer (纯 Dart，零 Flutter UI 依赖)]         │
│   ├─ RawRepository / AiIndexRepository / ExternalAiRepository (drift + sqlite3 WAL)    │
│   ├─ 后台 Isolate 管线: BFM v1 · CJK Readability(SSRF) · EPUB(.runes) · pdfrx_engine   │
│   ├─ 桌面后台 Isolate: 5s 防抖开放镜像导出 (.md + insights/*.html)                      │
│   ├─ 桌面内嵌 shelf 同步服务 (LAN mdns_dart + Tailscale) & 后续回环 IPC 端点             │
│   └─ 可选直连 OpenAiCompatClient (normal / private_local 硬分流)                        │
└───────────────────┬──────────────────────────────────────────────┬─────────────────────┘
                    │                                              │
     [本地单文件夹便携库 <BLINK_VAULT_DIR>]             [双轨多端同步 & 外置 AI 接入]
     ├─ vault.json (通道戳)                             ├─ 直连: 桌面 shelf / 无头 blink sync serve
     ├─ db/blink.db (WAL + backups/)                    │        (LAN mdns_dart <-> Tailscale)
     ├─ index/fts.db (fts_normal / fts_private)         ├─ 中继: E2EE XChaCha20-Poly1305 WebDAV/S3
     ├─ blobs/<sha256 分桶原件>                         └─ 外置 AI: packages/blink_cli (CLI/MCP)
     └─ mirror/ (.md + insights/*.html + 0700 private/)    + packages/blink_skills (SKILL.md)
```

**分层依赖硬规则（`INV-02`）**：
1. 包间依赖严格单向向下：`packages/blink_sanitizer` ← `packages/blink_core` ← `packages/blink_cli` 与 `apps/blink_client`；`packages/*` 严禁导入 `package:flutter/*` 或任何界面组件包。
2. 客户端内部分层严格自上而下：`lib/ui` → `lib/application` → `packages/blink_core` ← `lib/platform`；业务逻辑、同步、解析、净化与数据库仓储全部收敛于纯 Dart 包中，确保 Flutter 应用与原生命令行/无头服务 100% 复用同一套行为与测试。
3. 全部 CPU/IO 密集型解析（网页抓取与 CJK Readability、EPUB 解压与 AST 构建、`pdfrx_engine` 文本/目录/缩略图提取、大型 HTML 净化、开放镜像原子写出与 `VACUUM INTO` 快照）必须在后台 `Isolate` 执行，严禁阻塞 UI 渲染帧。

<a id="repo-layout"></a>
## 2. 单一仓库目录结构（Monorepo Layout）

全项目采用单一纯 Dart/Flutter 仓库（Dart Workspace）管理治理正本、共享核心包、净化器、外置技能包、CLI/MCP 捆绑包与五端客户端（各目录按[阶段路线](../delivery/roadmap.md#stages)逐步落位，当前已落地状态以 `main` 上的代码与[工程规则](../dev-rules/engineering.md#toolchain)为准）：

```text
blink/
├── README.md                          # 项目总览、纯 Dart 核心能力、技术栈入口与阶段状态
├── AGENTS.md                          # 开发者与 AI Agent 工作入口（工具中立）
├── CLAUDE.md                          # 单行指针：@AGENTS.md
├── LESSONS.md                         # 教训循环：踩过的坑与次数
├── CONTRIBUTING.md                    # 贡献方式：issue → 小 PR → 审查 → 合并
├── REVIEW.md                          # 审查顺序、严重度与结论写法
├── SECURITY.md                        # 私密漏洞报告、#private 四层边界与密钥轮换规程
├── CHANGELOG.md                       # 正式版发布变更记录（v0.1.1 起）
├── LICENSE                            # Apache-2.0 许可证正本
├── .flutter-version                   # 固定 Flutter 稳定版本（3.50.0，已实现）
├── pubspec.yaml                       # Dart Workspace 根配置与锁文件 pubspec.lock（已实现）
├── docs/                              # 二代精简文档体系（需求、决定、界面、设计、研究、交付、规则）
├── scripts/
│   ├── check_docs.py                  # 零第三方依赖 Python 标准库文档与公开卫生门禁（已实现，仅 CI 治理工具）
│   ├── check.py                       # 统一质量门禁入口：--quick、完整门禁、--ci 与 --install-linux-flutter（已实现）
│   ├── deps.py                        # 7 天冷却期依赖盘点、OSV 漏洞审计与校验和核对，附 flutter-checksums.json / deps-exceptions.json（已实现）
│   ├── package.py                     # Windows 双通道打包、--install 静默更新本机 blink-dev 与 --rehearsal 演练（已实现；--cli 待实现）
│   └── test_*.py                      # 上述门禁、依赖与打包脚本的零依赖 unittest 回归测试（已实现）
├── packages/
│   ├── blink_sanitizer/               # 纯 Dart HTML5/SVG + W3C CSS Syntax L3 净化与诊断包（M3 核心已实现 / M6 完整）
│   ├── blink_core/                    # 纯 Dart 唯一核心与契约包：sqlite3 WAL、BFM v1、CJK FTS5、BlobStore、Mirror、M4 因果同步/直连/E2EE 中继（M3～M4 已实现；文档解析 M5 待实现）
│   ├── blink_cli/                     # 统一原生 CLI / 无头同步 (blink sync serve，M4 已实现) / MCP Server（M6 待实现），由 dart build cli 捆绑 libsqlite3
│   └── blink_skills/                  # agentskills.io 规范的 5 项标准 SKILL.md、manifest.json 与多客户端一键安装/导出器（M6）
└── apps/
    └── blink_client/                  # 五端 Flutter 本地优先应用（Windows + Android 工作区、OS 原生密钥库与 M4 同步/冲突界面已实现；伴读、AI 与其余三端待实现）
        ├── pubspec.yaml
        ├── assets/icons/              # 运行期托盘多尺寸 .ico（blink.ico、blink-dev.ico）
        ├── lib/
        │   ├── app/                   # 应用入口、日/纸/夜视觉令牌、品牌标识与壳层装配（已实现）
        │   ├── ui/                    # 四档自适应外壳、BFM v1 编辑器与分栏预览、CJK 搜索、文件/附件、内生待办、设置页与 M4 同步状态胶囊/设置/冲突裁定界面（M3～M4 已实现；伴读与双表面 AI 视图待实现）
        │   ├── application/           # 纯 Flutter ChangeNotifier 控制器、CJK IME 保护与自动补全、BlinkSyncController 同步编排（M3～M4 已实现）
        │   └── platform/              # 编译期信息、双通道路径与便携库解析、原子写入、桌面设置、原生文件选择、Windows DPAPI / Android Keystore 密钥库、单实例锁、控制管道、托盘与生命周期（Windows + Android 已实现，其余平台待实现）
        ├── windows/ macos/ linux/ android/ ios/   # windows/packaging/blink.nsi 为 NSIS 3.13 按用户安装脚本（已实现，DEC-029）
        └── test/                      # 单元、组件、CJK IME 保护、Win32 IPC 与无焦点生命周期测试（已实现）
```

<a id="contracts"></a>
## 3. 跨端同步、回环 IPC、外置 AI 与直连接口契约

双端与无头节点同属纯 Dart 工作区，所有同步、IPC、CLI、MCP 与阅读 AST 数据结构**唯一定义于 `packages/blink_core` 强类型 Dart 模型与 JSON Schema 夹具**，无需跨语言代码生成工具，编译期直接杜绝契约漂移（[工程规则](../dev-rules/engineering.md#gates)）。

### 3.1 核心通信与扩展接口契约表

| 协议与接口分组 | 载体与鉴权边界 | 幂等与数据边界 | 契约摘要与离线/降级行为 |
| --- | --- | --- | --- |
| **直连同步服务（桌面 `shelf` / 无头 `blink sync serve`）**<br>`GET /api/v1/health`, `/capabilities`<br>`POST /api/v1/auth/pair`, `DELETE /auth/devices/{id}`<br>`POST /api/v1/sync/push`, `GET /sync/pull`<br>`GET /api/v1/events/stream` (SSE)<br>`HEAD`/`PUT`/`GET /api/v1/media/blobs/{sha256}` | 仅绑定回环、局域网或 Tailscale（`100.64.0.0/10`）；除健康探针与一次性配对外均须 `Authorization: Bearer <device_token>` 与 `X-Blink-Protocol: 2` | `sync/push` 按 `(device_id, client_op_id)` 强幂等并分配严格单调 `seq_id`；媒体流按 `sha256` 校验并支持 `Range` 断点续传 | 桌面端休眠或离线时客户端顶栏诚实展示“同步节点未在线 · 本地待传 N 项”（`peer_asleep`），绝不阻塞本地 0ms 读写；重连自动按游标续传 |
| **E2EE 对象存储异步中继（WebDAV / S3）**<br>`oplogs/<device_id>/<uuidv7>.enc`<br>`blobs/<hmac_id>.enc` | 用户自备 WebDAV 或 S3 兼容存储；凭据与主同步密钥仅存 OS 密钥库；全量 `XChaCha20-Poly1305` 客户端 AEAD 加密 | 设备仅向自有前缀追加不可变密文段，零覆盖冲突；重放按 `(hlc_ts, device_id, client_op_id)` 确定性收敛并保留双本冲突 | 严禁直接上传活库 `blink.db`；提供“禁止经云中继同步 `#private`”开关，使 `#private` 零密文出网 |
| **桌面回环 IPC 端点（本地派生写入）**<br>`POST http://127.0.0.1:<port>/ipc/v1/*`（含 `/ipc/v1/derived/*` 与显式启用的 `/ipc/v1/capture`） | 严格绑定 `127.0.0.1` 随机端口；每次桌面启动生成随机高熵令牌写入 OS 运行目录 `0600` 的 `ipc.json`（不在 `<BLINK_VAULT_DIR>` 内），请求须携带 `X-Blink-IPC-Token` 且硬性拒绝任何带 HTTP `Origin` 头的跨源请求 | 仅暴露 `ExternalAiRepository` 派生写入（`ai_*`）、校验动作及显式启用的只增收件箱采集；单事务 `BEGIN IMMEDIATE` 写入并分配 `seq_id`、实时刷新 UI | 桌面未运行时，`packages/blink_cli` 自动切换冷库 WAL `BEGIN IMMEDIATE` 直写路径，行为与安全校验 100% 一致 |
| **外置 AI CLI 与 MCP Server（`packages/blink_cli`）**<br>Stdio & `POST http://127.0.0.1:<port>/mcp`（Streamable HTTP） | 默认硬锁定 `--scope normal_only`（查询 `v_normal_*` 视图与 `fts_normal`）；`local_with_private` 须经用户显式开启 + OS 密钥库独立令牌 + 本地回环三道门控 | 对 `raw_*` 严格只读（`blink_capture_entry` 仅在 `--allow-capture` 显式开启时允许只增不改）；写入 HTML 必经 `packages/blink_sanitizer` 净化与 `<blink-ref>` 校验，失败返回结构化诊断码供 AI 自修 | `normal_only` 模式下查询私密 ID 统一返回不透明 `not_found`，防止存在性侧信道探测（`INV-03`） |
| **可选内置直连 OpenAI 兼容接口（`OpenAiCompatClient`）**<br>`POST <BaseURL>/v1/chat/completions`（SSE） | 客户端 `dio` 直接请求外部 API、内网 `Ollama /v1` 或通用网关；API Key 仅存单机 OS 密钥库 | 按 `normal` 与 `private_local` 两套独立端点画像分流；对话总结仅生成 `ai_*` 卡片或经用户确认的新建 `raw_entries` | `#private` 请求若未配置合规局域网/回环 `private_local` 端点，立即闭锁返回 `privacy_blocked`，绝不回退云端 |

### 3.2 统一错误分类（Error Taxonomy）

全仓模块与界面统一使用结构化错误模型 `{code, message, retryable, diagnostics?}`，严禁将异常吞没为空列表或伪装成功（`INV-11`）：
- `auth_required` / `device_revoked`：设备令牌缺失或已被吊销，停止同步并提示重新配对；
- `protocol_mismatch` / `channel_mismatch`：跨端协议版本不兼容或尝试用错误通道打开异通道 `vault.json`；
- `privacy_blocked`：涉及 `#private` 的内置直连请求目标非受控内网地址、外置 MCP 作用域未放行，或策略阻断云中继；
- `peer_asleep`：直连同步对端（如休眠中的主力电脑）暂时离线，本地变更已安全排队等待唤醒或中继；
- `missing_ocr`：扫描版 PDF 无内嵌文本层，可正常框选批注并等待外置 OCR 补全派生文本；
- `anti_bot_or_paywall` / `unsupported_media`：外部网页需登录/触发反爬挑战（遵守不绕过挑战红线，立即停止）或文档加密损坏；
- `webview_unavailable`：Linux 宿主机缺失 `libwebkit2gtk-4.1-0`，Surface 2 自动平滑降级至纯 Flutter Surface 1 展示并温和提示；
- `html_sanitize_rejected`：外置 AI 写入的 HTML/SVG 触犯白名单、存在外联 URL、硬编码色值或伪造 `<blink-ref>`，附带精确诊断码供自修；
- `conflict_preserved`：离线并发编辑同一正文产生冲突，已完整保留双本并生成冲突副本供用户比对合并；
- `storage_full` / `io_error`：磁盘空间不足或底层文件/SQLite 读写异常。

<a id="storage-security"></a>
## 4. 双通道存储路径、单文件夹便携库与密钥隔离

### 4.1 五端与无头模式 `blink` / `blink-dev` 物理隔离（`INV-06`）

所有构建产物在编译期注入通道常量 `BLINK_CHANNEL`（正式版 `blink`，开发版 `blink-dev`）。双通道可在同机同时安装并并行运行，便携库、缓存、锁文件、WebView 数据目录、OS 运行态 IPC 文件、CLI 命令名与系统密钥仓完全隔离：

| 运行平台 / 形态 | 正式通道（`blink`）默认便携库（用户数据） | 开发通道（`blink-dev`）默认便携库（用户数据） | 应用本地态与 OS 运行态（`settings/` / `ipc.json` / 锁 / WebView） | 敏感凭据与密钥存储（绝不落入 `<BLINK_VAULT_DIR>`） |
| --- | --- | --- | --- | --- |
| **Windows（已安装）** | `<Documents>\blink`（经 Win32 `SHGetKnownFolderPath(FOLDERID_Documents, KF_FLAG_DONT_VERIFY, null)` 查询真实目录，回退 `%USERPROFILE%\Documents\blink`，再回退 `<dataRoot>\vault`；程序装于 `%LOCALAPPDATA%\Programs\blink`） | `<Documents>\blink-dev`（装于 `%LOCALAPPDATA%\Programs\blink-dev`） | `%LOCALAPPDATA%\blink[-dev]`（`settings/`、`run/ipc.json`、`run/lifecycle.json`、`app.lock`、`webview2/`、`logs/`、`cache/`） | `%LOCALAPPDATA%\blink[-dev]\credentials\`，经当前用户范围 Windows DPAPI（`CryptProtectData`）加通道专属熵加密；不写 `%APPDATA%` 与主目录 `.blink` |
| **macOS（已安装）** | `~/Documents/blink`（支持自定义便携目录） | `~/Documents/blink-dev` | 应用本地态 `~/Library/Application Support/blink[-dev]`；运行态/缓存 `~/Library/Caches/blink[-dev]` | macOS Keychain，按独立 Bundle ID `io.github.chialecode.blink` 与 `io.github.chialecode.blink.dev` 隔离 |
| **Linux（已安装）** | `${XDG_DOCUMENTS_DIR:-~/Documents}/blink` | `${XDG_DOCUMENTS_DIR:-~/Documents}/blink-dev` | 应用本地态 `${XDG_DATA_HOME:-~/.local/share}/blink[-dev]`；运行态 `$XDG_RUNTIME_DIR/blink[-dev]/ipc.json`（权限 `0600`）、`app.lock` | `<dataRoot>/credentials/` 通道隔离作用域存储（`0700`/`0600`，避免引入 `libsecret-1-dev` 依赖，见 [DEC-032](../decisions.md#dec-032)） |
| **桌面源码构建** | 默认拒绝；仅当同时设置 `BLINK_ALLOW_SOURCE_PROD=1` 与隔离的 `BLINK_DATA_DIR`（不与真实 `blink` 根目录重叠）时放行至 `<BLINK_DATA_DIR>/vault` | `<repoRoot>/.local/blink-dev/vault`（仓库外回退 `<systemTemp>/blink-source-dev/vault`） | `<repoRoot>/.local/blink-dev/app`（仓库外回退 `<systemTemp>/blink-source-dev/app`）；不注册单实例互斥量与控制管道 | 仅存于独立沙盒 `<dataRoot>/credentials/` 或安静测试内存桩，绝不触碰本机已安装的 `blink` / `blink-dev` |
| **Android** | 私有沙盒 `<AppFilesDir>/blink`（包名 `io.github.chialecode.blink`），LRU 媒体缓存 `<AppCacheDir>/media` | 私有沙盒 `<AppFilesDir>/blink-dev`（包名 `io.github.chialecode.blink.dev`） | 沙盒内应用独占运行（无桌面 IPC，`android:allowBackup="false"`） | Android Keystore AES-256-GCM 硬件支持密钥（`blink_secret_key_<channel>`）加密存至 `<noBackupFilesDir>/blink[-dev]/credentials/`，双包名与通道隔离（[DEC-032](../decisions.md#dec-032)） |
| **iOS** | 沙盒 `Application Support/blink`（Bundle ID `io.github.chialecode.blink`），缓存 `Library/Caches/media` 标 `isExcludedFromBackup = true` | 沙盒 `Application Support/blink-dev`（Bundle ID `io.github.chialecode.blink.dev`） | 沙盒内应用独占运行 | iOS Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），按独立 Bundle ID 隔离 |
| **无头 `blink sync serve` / CLI** | `--vault <BLINK_VAULT_DIR>`（或 `$BLINK_VAULT_DIR`） | `--vault` 默认 `.local/blink-dev/vault`（通道戳强制为 `blink-dev`） | `$XDG_RUNTIME_DIR/blink[-dev]/`（`0600`） | 设备令牌仅存 `SHA-256` 哈希于 `blink.db`；凭据经 OS 密钥库或独立权限 `0600` 宿主机外部密钥文件提供，严禁放入 `<BLINK_VAULT_DIR>` |

- **Windows 文档目录解析与通道隔离硬守卫（[DEC-031](../decisions.md#dec-031)）**：Windows 端一律优先调用 Win32 `SHGetKnownFolderPath(FOLDERID_Documents, KF_FLAG_DONT_VERIFY, null)`（配合 `CoTaskMemFree`）解析真实“文档”目录，正确支持自定义磁盘路径与 OneDrive 目录重定向，绝不硬编码 `%USERPROFILE%\Documents` 越过 Known Folder API；所有非正式构建（源码构建、开发通道与 `*-test` 测试身份）在启动与目录切换前规范化解析目标路径（含符号链接/目录联接与 `..`），拒绝与真实正式通道 `%LOCALAPPDATA%\blink` 或 `<Documents>\blink` 重叠，源码构建与 `*-test` 测试身份同时拒绝与已安装的 `blink-dev` 真实目录重叠。
- **`vault.json` 通道硬守卫**：每个 `<BLINK_VAULT_DIR>/vault.json` 显式写入 `channel`（`blink` 或 `blink-dev`）与 `format_version`；任一客户端或 CLI 试图跨通道打开库目录时立即拒绝并报 `channel_mismatch`。
- **单文件夹拷贝卫生（`INV-08`）**：设备同步令牌、WebDAV/S3 凭据、E2EE 同步主密钥、本地 `local_with_private` MCP 令牌及可选内置直连 OpenAI 兼容 API Key **全部仅存于各设备 OS 原生安全密钥库，绝不写入 `<BLINK_VAULT_DIR>`、绝不随同步流明文传输**；因此用户可随时放心拷贝或备份整个 `<BLINK_VAULT_DIR>` 而零泄漏凭据。
- **活库防网盘冲突提示**：文档与设置界面明确提示切勿将正在运行的 `<BLINK_VAULT_DIR>/db/` 直接置于网盘同步盘（避免双机写 SQLite WAL 损坏）；当 `<Documents>` 被系统重定向至 `OneDrive` 目录时，设置页展示温和非阻塞提示但不强制改写用户目录。多机实时同步走 BLINK 同步协议，网盘备份仅针对 `mirror/` 或 `db/backups/` 中的 `VACUUM INTO` 原子快照。

### 4.2 原子落盘、热快照备份与日志脱敏

1. **临时文件 + `flush` + 原子重命名（`INV-07`）**：所有配置文件、开放镜像（`.md` 与 `insights/*.html`）、媒体仓二进制文件及 `packages/blink_skills` / MCP 配置补丁，一律先写入同目录 `.blink-tmp` / `.part` 临时文件并执行 `RandomAccessFile.flush()`（二进制同时校验长度与 `sha256`）后原子改名；桌面退出与 `--quit-for-update` 时执行 `PRAGMA wal_checkpoint(TRUNCATE)` 确保 `-wal`/`-shm` 合并入 `blink.db`。
2. **迁移前原子热快照与损坏保留**：每次 `drift` 模式升级或手动备份均先执行 SQLite `VACUUM INTO`（或 `db.backup()`）生成 `< 1 s` 自包含一致性快照写入 `db/backups/`；检测到损坏文件先改名为 `<filename>.corrupt-<utc时间戳>` 保留现场再恢复；遇到高于当前程序版本的 `schema_version` 立即拒绝写入并提示升级。
3. **日志与诊断脱敏（`INV-08`）**：统一日志清洗层严禁输出 `Authorization` 头、配对码、E2EE 主密钥、API Key、带签名参数 URL 及任何 `privacy_level = "private"` 正文与摘录。

<a id="desktop-lifecycle"></a>
### 4.3 Windows 安装身份与桌面生命周期（`DEC-027`、`DEC-031`）

安装身份在构建期经 `--dart-define=BLINK_IDENTITY=<身份>` 与 `BLINK_CHANNEL`、`BLINK_VERSION`、`BLINK_GIT_SHA` 一并注入；`flutter run` 等源码构建不带安装身份，不注册互斥量与控制管道，并默认隔离在仓库内 Git 忽略的 `.local/blink-dev/` 沙盒中（与已安装的 `blink`、`blink-dev` 完全互不干扰）。测试身份只用于门禁安装演练，产物不分发。

| 安装身份 | 通道 | 应用标识 / 卸载键（`HKCU\...\Uninstall\<应用标识>`） | 可执行文件 | 默认安装目录 | 单实例互斥量 / 控制管道 | 应用本地根（`dataRoot`） | 默认便携库根（`defaultVaultDir`） |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `blink` | 正式 | `io.github.chialecode.blink` | `blink.exe` | `%LOCALAPPDATA%\Programs\blink` | `blink-instance` / `\\.\pipe\blink-control` | `%LOCALAPPDATA%\blink` | `<Documents>\blink` |
| `blink-dev` | 开发 | `io.github.chialecode.blink-dev` | `blink-dev.exe` | `%LOCALAPPDATA%\Programs\blink-dev` | `blink-dev-instance` / `\\.\pipe\blink-dev-control` | `%LOCALAPPDATA%\blink-dev` | `<Documents>\blink-dev` |
| `blink-test` / `blink-dev-test` | 门禁演练 | `io.github.chialecode.blink-test` / `io.github.chialecode.blink-dev-test` | `blink-test.exe` / `blink-dev-test.exe` | 演练临时目录（安装器 `/D=`） | `<身份>-instance` / `\\.\pipe\<身份>-control` | 演练临时目录（`BLINK_DATA_DIR`） | `<BLINK_DATA_DIR>\vault`（同时传隔离 `BLINK_DOCUMENTS_DIR`） |
| 源码构建（空身份） | 开发（默认；正式通道须 `BLINK_ALLOW_SOURCE_PROD=1` + 隔离 `BLINK_DATA_DIR`） | 无 | 构建产物 `blink_client.exe` | 未安装 | 无 | `<repoRoot>\.local\blink-dev\app`（仓库外 `<temp>\blink-source-dev\app`） | `<repoRoot>\.local\blink-dev\vault`（仓库外 `<temp>\blink-source-dev\vault`） |

- **单实例**：已安装身份启动时创建命名互斥量 `<身份>-instance`（安装器与卸载器据此发现运行中的实例，先请其 `--quit-for-update`，见[工程规则 §2.2](../dev-rules/engineering.md#packaging)）。第二个进程根据启动参数决定行为后退出：无参数时经控制管道转交 `focus`（转交前以 `GetNamedPipeServerProcessId` + `AllowSetForegroundWindow` 把前台权限只授予该管道服务端进程，使托盘常驻的主实例能真正前置窗口，安静模式不调用；成功退出码 `0`，管道或协议错误退出码 `1`）；带 `--background` 时直接以退出码 `0` 退出、不聚焦已有窗口；带 `--quit-for-update` 时，若无运行中实例则直接以 `0` 退出，有运行中实例则经控制管道请求保存后退出（接受 `{"ok": true}` 退出码 `0`，对端忙碌 `{"ok": false, "reason": "busy"}` 退出码 `2`，其他管道或协议错误退出码 `1`，并在存在附加标准输出时尽力写出 JSON 应答行）。
- **控制管道**：`\\.\pipe\<身份>-control` 使用 `FILE_FLAG_FIRST_PIPE_INSTANCE`（`nMaxInstances = 1`）与 `PIPE_REJECT_REMOTE_CLIENTS`，安全描述符仅授予当前用户受保护 DACL（`D:P(A;;GA;;;<当前用户SID>)`）；单行上限 `4096` 字节 UTF-8，每个连接一行 JSON 请求 `{"cmd": "focus" | "quit-for-update" | "ping"}`，一行应答 `{"ok": true}` 或 `{"ok": false, "reason": "busy" | "unknown_command" | "invalid_request"}`（超长行、非法 UTF-8、畸形 JSON 或缺失 `cmd` 均返回 `invalid_request` 而不崩溃）。管道服务在独立 Isolate 中运行，命令交给 UI Isolate 执行，60 秒内无应答回执 `busy`；取消重叠 I/O 时统一执行 `CancelIoEx` + `GetOverlappedResult(..., true)` 排空后再释放或复用缓冲区。
- **托盘与关闭**：原生窗口启动保持隐藏（零闪烁、不抢焦点），交互运行期间始终显示托盘图标（开发版图标带 `DEV` 徽标），左键或右键菜单“打开”恢复并聚焦主窗口，“退出”走保存后退出序列；关闭按钮默认隐藏到托盘，可在设置中改为直接退出（`<数据根>\settings\desktop.json`，原子写入；损坏时改名为 `desktop.json.corrupt-<UTC时间戳>` 保留现场并回退默认）。资源管理器重启时由原生窗口拦截 `TaskbarCreated` 并经 MethodChannel `io.github.chialecode.blink/desktop_shell` 通知 Dart 重新注册托盘图标。
- **`--background`**：只显示托盘图标，不创建任务栏项、不打开主窗口、不抢焦点；托盘不可用时回退为最小化到任务栏。
- **保存后退出**：`quit-for-update`、托盘“退出”与关闭设为退出时共用一个生命周期序列：检查忙碌（当前无常驻后台业务任务，默认空闲；后续接入离线队列刷盘、镜像末次写出与 `PRAGMA wal_checkpoint(TRUNCATE)`）→ 保存窗口几何与状态 → 原子写入 `<数据根>\run\lifecycle.json`（字段 `exitReason`、`windowWasVisible`、`version`、`identity`、`timestampUtc`）→ 移除托盘图标 → 释放控制管道与互斥量并退出（几何、`lifecycle.json` 或托盘移除失败只记入 `lastShutdownPersistenceError`、不阻断退出，避免进程卡在“退出中”而让后续 `quit-for-update` 空答 `ok`）（`quit-for-update` 预留 `80ms` 短暂延迟确保管道 Isolate 刷出 `{"ok": true}` 应答）。
- **安静模式**：`BLINK_QUIET=1` 时不显示窗口、不创建托盘图标、不调用任何聚焦 API，供冒烟与安装演练使用。
- **版本与外壳**：开发通道 `0.1.0-dev.<UTC 年月日时分>`、正式通道 `0.1.<n>`（工作区含未提交改动时带 `+dirty` 后缀）；完整版本字符串经 CMake 环境变量注入构建期生成头文件写入可执行文件 `ProductVersion`（不污染受跟踪源码）与安装器 `AppVersion`（卸载项 `DisplayVersion`），数值 `FileVersion` 固定为 `0.1.<n>.0`（开发通道 `0.1.0.0`）；最小桌面外壳位于 `apps/blink_client/lib/app/`，“关于”页显示版本、通道、安装身份与提交短哈希。

<a id="invariants"></a>
## 5. 架构与数据不变量（`INV-01` ～ `INV-13`）

以下 13 条核心不变量贯穿规划、实现与自动化门禁检查，任何阶段迭代与性能优化均不得违反：

| 编号 | 不变量定义 |
| --- | --- |
| <a id="inv-01"></a>`INV-01` | **原文层不可篡改（Raw-Layer Immutability）**：用户创作的 BFM v1 原文资产（`raw_entries.body_md`、`raw_annotations.quoted_excerpt`/`note_md`、`media_blobs` 及只增不改伴读轮次）对一切后台任务、外置 AI（`ExternalAiRepository`）与可选内置 AI 严格只读；外置 AI 仅允许写入 `ai_*` 派生表（含语音逐字稿 `verbatim_transcript_text`、整理稿、OCR 引文、`ai_task_candidates`、回响、简报、富 HTML 视图及强制 `status = 'candidate'` 的认知原则；`blink_capture_entry` 仅在显式授权时允许只增不改）；内置 AI“对话总结为笔记”仅创建派生 `ai_*` 卡片或经用户显式确认的**新建** `raw_entries`（附对话来源引用），严禁静默修改既有原文；用户原文内 `![[ai:<uuid>]]` 仅存 ID 指针。 |
| <a id="inv-02"></a>`INV-02` | **严格单向依赖（Downward-Only Dependency）**：纯 Dart 仓库分层严格为 `packages/blink_sanitizer` ← `packages/blink_core` ← `packages/blink_cli` 与 `apps/blink_client`；`packages/*` 严禁依赖 Flutter UI 组件；客户端 `ui` → `application` → `packages/blink_core` ← `platform` 单向流动；全部数据契约唯一源自 `packages/blink_core` 强类型模型。 |
| <a id="inv-03"></a>`INV-03` | **`#private` 四层零云端出境硬隔离（Four-Surface Zero Cloud Egress）**：① 外置 AI CLI/MCP 默认硬锁定 `--scope normal_only`（读取 `v_normal_*` 视图与 `fts_normal`、越界返回不透明 `not_found`，`local_with_private` 须三道门控，且跨密级 BFM 嵌入自动脱敏）；② 可选内置直连 `OpenAiCompatClient` 对 `#private` 强制锁死 `private_local` 画像（仅允许解析至 `127.0.0.1`/`::1`/RFC1918/`100.64.0.0/10` 并防 DNS 重绑定，不合规立即报 `privacy_blocked`）；③ 双表面 HTML 净化器与 Surface 2 离线 `default-src 'none'` CSP + 无痕模式阻断一切外联与私密缓存残留；④ 多端同步默认局域网/Tailscale 直连，启用 WebDAV/S3 时强制 `XChaCha20-Poly1305` E2EE 并支持物理排除 `#private` 上云。 |
| <a id="inv-04"></a>`INV-04` | **端侧写入零网络等待（Zero-Latency Offline Write）**：五端新建、编辑 BFM、划词高亮与待办状态变更均在本地 SQLite WAL 单事务内 `< 16 ms` 落盘业务表与 `outbox_ops` 并即时更新界面，绝不因网络离线、对端电脑休眠或外置 AI 不可达阻塞输入。 |
| <a id="inv-05"></a>`INV-05` | **幂等推送与因果确定性收敛（Idempotent Push & Deterministic Convergence）**：每条变更绑定不可变 UUIDv7 `client_op_id` 与混合逻辑时钟 `hlc_ts`；直连同步（含桌面运行态 IPC 与关闭态冷 WAL 写入）按 `(device_id, client_op_id)` 去重并分配严格单调递增 `sync_oplog.seq_id`（`INTEGER PRIMARY KEY AUTOINCREMENT`）；WebDAV/S3 异步中继通过按设备分前缀的不可变密文段按 `(hlc_ts, device_id, client_op_id)` 确定性重放；并发编辑同一文本双本保留、绝不静默丢字。 |
| <a id="inv-06"></a>`INV-06` | **双通道完全隔离（Channel Isolation）**：`blink`（正式通道）与 `blink-dev`（开发通道）在五端与无头服务使用独立的应用标识、便携库目录与 `vault.json` 通道戳、OS 运行态 `ipc.json`、Windows WebView2 `userDataFolder`、CLI/MCP 键名、文件锁与系统密钥项，严禁跨通道读写。 |
| <a id="inv-07"></a>`INV-07` | **原子写入、热快照与哈希核验（Atomic Write, Hot Snapshot & Content Verification）**：所有配置、开放镜像（`.md` 与 `insights/*.html`）、媒体仓原件、技能包同步与 MCP 配置补丁必须先写临时文件、执行 `flush()` 及长度/`sha256` 核验后原子改名；活库热备份统一走 `VACUUM INTO` / `db.backup()`，干净退出执行 `wal_checkpoint(TRUNCATE)`；损坏文件改名保留现场，绝不静默覆盖。 |
| <a id="inv-08"></a>`INV-08` | **零库内明文凭据与私密脱敏（Zero-Secret Vault & Private Scrubbing）**：`<BLINK_VAULT_DIR>` 内严禁存放任何明文凭据或会话令牌；设备同步令牌、WebDAV/S3 凭据、E2EE 主同步密钥、`local_with_private` MCP 令牌及可选每设备直连 AI API Key 全部严格保存在各设备 OS 原生安全密钥库，绝不明文同步、绝不入日志与崩溃转储；`ipc.json` 置于 OS 运行态目录（`0600`）。 |
| <a id="inv-09"></a>`INV-09` | **派生层可完整重建（Recomputable Derived Stores）**：独立 `index/fts.db`（`fts_normal` / `fts_private`）、全部 `ai_*` 派生表（含 Surface 1 `view_html` 与 Surface 2 `artifact_html`）以及磁盘开放镜像 `mirror/` 均为原文正本的派生投影；任一派生存储清空或重建后零丢失用户原始资产。 |
| <a id="inv-10"></a>`INV-10` | **确定性批注锚点与失锚保底（Deterministic Anchoring & Orphan Fallback）**：长文/EPUB 批注基于 Dart `.runes` Unicode 标量值记录 `{chapter_id, block_id, offset, quote}`，PDF 批注记录 `{page_index, rects_norm, quote}`；文档重解析偏移时先按上下文文本精确重锚，仍无法定位时归入章节/全书末尾“未定位批注”展示，绝不丢失批注。 |
| <a id="inv-11"></a>`INV-11` | **诚实状态与错误暴露（Honest State & Error Reporting）**：离线待传、直连对端休眠（`peer_asleep`）、扫描页待识别（`missing_ocr`）、反爬受阻、Linux 缺少 WebKitGTK 降级 Surface 1、隐私阻断（`privacy_blocked`）与磁盘空间不足须以独立枚举如实呈现，绝不将失败伪装为“无内容”或“已完成”。 |
| <a id="inv-12"></a>`INV-12` | **仅操作自有登记文件（Owned-File-Only Cleanup & Patching）**：端侧媒体缓存淘汰、桌面开放镜像更新、`blink skills` 目录安装卸载与一键 MCP 配置合并只允许读写自身清单登记或明确声明的 `"blink"` / `"blink-dev"` 条目（改写外部配置前自动留存 `.blink-bak`），严禁无白名单递归删除或破坏用户外部配置。 |
| <a id="inv-13"></a>`INV-13` | **纯 Dart 净化、双表面沙盒与主题令牌硬契约（Pure-Dart Sanitization, Two-Tier Sandbox & Theme Binding）**：手写原文层采用 BFM v1（除 `<details>`/`<summary>` 外原生 HTML 一律转义）；所有外部阅读块 `html_sanitized` 与 AI 派生 `view_html` / `artifact_html` 落库及渲染前必经纯 Dart `packages/blink_sanitizer`（`package:html` HTML5 重建 + W3C CSS Syntax L3 词法器）白名单净化，物理阻断 `<script>`、`<iframe>`、`<foreignObject>`、`on*` 事件、CSS `url(...)`/转义绕过、外部网络资源及硬编码色值；Surface 1 由纯 Flutter 原生组件树高速渲染，Surface 2 在按需零脚本离线 CSP 沙盒视图中渲染且强制绑定宿主 Day/Sepia/Dark `var(--blink-*)` 语义令牌。 |
