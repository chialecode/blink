# 工程规则：工具链、通道路径、门禁、Git 与发布

现行技术选型依据见[纯 Dart 架构选型研究（2026-11-22）](../research/2026-11-22-pure-dart-pivot.md#overview)，进程拓扑、目录结构与架构不变量见[系统架构](../design/architecture.md#repo-layout)。

<a id="toolchain"></a>
## 1. 工具链与跨端工程基线

本节区分 **M1 已落地状态**、**开发机实测就绪基线**与 **M2+ 工程实施基线**，不把后续阶段才初始化的工程目录或待装工具写成已存在：

| 层级 | 组件与版本基线 | 锁定与契约约束 | 当前状态 |
| --- | --- | --- | --- |
| 仓库治理门禁（仅 CI/开发治理） | Python `3.12+` 标准库（`scripts/check_docs.py`） | 零第三方依赖；CI 固定使用 `ubuntu-24.04` 与 Python `3.12`；**仅服务于仓库文档卫生门禁，BLINK 运行时产品零 Python 依赖** | **已实现（M1）** |
| 纯 Dart 共享核心与净化器（`packages/blink_core`、`packages/blink_sanitizer`） | Dart `>= 3.10`（Dart Workspace 统一管理） | `pubspec.lock` 精确锁定；`drift 2.35.4` + `sqlite3 3.9.1` Native Assets（Build Hooks 自动打包原生库）、`package:markdown 7.3.1`（BFM v1 唯一解析器）、`package:html 0.15.7` + W3C CSS Syntax L3 词法器、`package:archive 4.6.0` + `package:xml 7.1.0`、`pdfrx_engine 0.9.6`、`shelf 1.4.3` / `shelf_router 1.1.5`、`dio 5.5+`、`cryptography 2.9.0` + `aws_signature_v4 0.6.13`；严禁引入 `package:flutter/*`（`INV-02`） | 待实现（M2+） |
| 五端客户端（`apps/blink_client/`） | Flutter / Dart 稳定版（需 Dart `>= 3.10`），目标平台：`Windows`、`macOS`、`Linux`、`Android`、`iOS` | `flutter_riverpod`、`drift_flutter 0.3.1`、`pdfrx 3.1.0`、`super_sliver_list`、`flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `fl_chart 1.3.1`（Surface 1）、`flutter_inappwebview 6.1.5` + `desktop_webview_window 0.4.3`（Surface 2，Linux 动态链接受 [DEC-026](../decisions.md#dec-026) 约束）、`bonsoir 7.1.6`、`record 6.2.x`、`flutter_secure_storage`。手写层坚持 BFM v1 原生 `TextField`（禁重型 WYSIWYG） | 待实现（M2+） |
| 原生 CLI / MCP / 无头同步与技能包（`packages/blink_cli`、`packages/blink_skills`） | Dart `>= 3.10` + **`dart build cli`** | `mcp_dart 2.4.4`（封装于 `BlinkMcpAdapter`，可无缝切换 `dart_mcp`）、`args 2.7.0`、`shelf 1.4.3` / `shelf_router 1.1.5`；由 `dart build cli` 产出含 `libsqlite3` 的统一自包含目录包，同时承载 CLI、MCP Server 与无头 `blink sync serve`；`packages/blink_skills` 遵循 `agentskills.io` 开放规范 | 待实现（M3 同步 / M5 完整） |

### 1.1 开发环境工具链核验状态（2026-11-22 核对）

经纯 Dart 零后端收敛后，**Docker、外置数据库服务与任何 Python 后端运行工具链均已从 M2 及全产品 MVP 前置清单彻底移除**；M2 编码开工前仅需补齐 **Flutter / Dart 稳定版 SDK（Dart `>= 3.10`）**：

| 工具类别 | 组件与用途 | 当前实测状态 | 阶段准入节点与处置说明 |
| --- | --- | --- | --- |
| 版本控制与包管理基础 | `git 2.56.x`、`gh 2.103.x`、`winget 1.29.x` | **已就绪** | 支撑 M1+ 分支治理、远端规则核验与非交互式工具安装 |
| 仓库文档门禁脚本运行时 | `Python 3.12.16` 标准库 | **已就绪** | 仅用于运行零外部依赖的 `scripts/check_docs.py` 与仓内编排脚本，不进入 BLINK 运行时产物 |
| Windows 桌面 C++ 与系统 WebView 底座 | Visual Studio C++ Build Tools（MSVC `x64 19.51`、内置 `CMake 4.3`、`Windows 11 SDK 10.0.26100`）与 Windows 11 WebView2 Runtime | **已就绪** | 满足 M2 `flutter build windows`、`sqlite3` / PDFium FFI 及 M5 Surface 2 WebView2 运行前置条件 |
| Flutter / Dart 客户端与 CLI 工具链 | `fvm` + Flutter `stable` SDK（要求内置 **Dart `>= 3.10`** 以支持 `dart build cli` Build Hooks） | **M2 前唯一核心待安装项** | M2 开工创建 Dart Workspace（`packages/blink_core`、`packages/blink_sanitizer`、`apps/blink_client`）及运行 `dart analyze` / `dart test` / `flutter test` 前安装并加入环境变量 |
| Android 移动端构建链 | JDK `17`/`21` + Android SDK（`platform-tools`、`build-tools`、`platforms`） | **M2 移动端打包前待安装** | 不阻塞核心库与桌面端先行编码；构建 M2 Android `blink-dev` 安装包与联调前补齐 |
| 异地虚拟私网（可选外部工具） | Tailscale 客户端 | **M3 跨设备 WAN 联调前** | M3 自动化门禁均通过 `127.0.0.1` 回环与模拟桩运行；跨设备外网同步实测前装妥 |
| Linux Surface 2 构建开发库（仅 Linux 宿主机/CI） | `libwebkit2gtk-4.1-dev`、`libsoup-3.0-dev` | **M5 Linux Surface 2 构建前** | 仅在 Linux 桌面构建机或 Linux CI runner 安装；目标机运行期动态链接未修改的系统共享库（[DEC-026](../decisions.md#dec-026)），缺失时自动降级 Surface 1 |

<a id="commands"></a>
## 2. 标准命令与双通道隔离

从仓库根目录执行：

| 命令 | 作用 | 状态 |
| --- | --- | --- |
| `python scripts/check_docs.py` | 零依赖检查必需文档布局、`CLAUDE.md` 单行引用、无 YAML 头（M5 起仅对 `packages/blink_skills/skills/**/SKILL.md` 豁免并做 Schema 校验）、相对链接与显式/标题锚点可达、禁止引用式链接、UTF-8 无 BOM 与 LF 行尾（仅 `.bat`/`.cmd` 允许 CRLF）、拦截本机绝对路径/敏感凭据/本机参考项目名与同级仓库名（含 `.githooks/`、`.gitignore` 等无扩展名文本） | **已实现（M1）** |
| `python -B scripts/test_check_docs.py` | 门禁自身的零依赖回归夹具（`unittest`，全部在系统临时目录构造正反例，不写工作区）：断链、缺锚点、引用式链接、YAML 头、BOM、CRLF、非 kebab-case、`CLAUDE.md` 契约、本机路径、密钥特征、禁止文件与参考/同级仓库名拦截 | **已实现（M1）** |
| `git config --local core.hooksPath .githooks` | 每个新克隆执行一次，启用 [`.githooks/pre-push`](../../.githooks/pre-push)：推送前运行上面两条命令。CI 上没有同级仓库与本机参考索引，参考名拦截只有在开发机上才有实际词表，因此本地 hook 是该项检查的主要执行点；hook 可被跳过，不能替代远端规则集 | **已实现（M1）** |
| `git diff --check HEAD` | 检查受跟踪文件的尾随空白、行尾符与冲突标记（新增文件先 `git add`） | **已实现（M1）** |
| `dart format --output=none --set-exit-if-changed .` | 全纯 Dart 工作区（`packages/*` 与 `apps/blink_client`）统一代码格式校验 | 待实现（M2） |
| `dart analyze --fatal-infos` | 全工作区静态分析与类型安全校验（零警告零 info） | 待实现（M2） |
| `dart test` / `flutter test` | 纯 Dart 核心包/净化器/CLI 单元测试与 Flutter 组件/离线交互测试 | 待实现（M2） |
| `dart build cli -t packages/blink_cli/bin/blink.dart -o dist/blink-cli/` | 构建包含原生 `libsqlite3` Build Hooks 的统一自包含 CLI / MCP / 无头同步捆绑目录包（**禁用旧命令 `dart compile exe`**） | 待实现（M3/M5） |
| `python scripts/check.py --quick` | 日常快速门禁（预算 ≤ 5～10 分钟）：运行 `check_docs.py`、`git diff --check`、增量 `dart analyze` 与改动关联的 `dart test` / `flutter test` | 待实现（M2） |
| `python scripts/check.py` | 完整阶段门禁：串行执行全工作区格式/分析、单向依赖方向校验（`INV-02`）、全量纯 Dart 与 Flutter 单元/回环集成测试、安静进程冒烟、OSV 依赖漏洞审计、`check_docs.py` 与 `git diff --check` | 待实现（M2） |
| `python scripts/deps.py [--audit]` | [7 天冷却期依赖盘点与 OSV 漏洞审计](workflow.md#dependency-inventory) | 待实现（M2） |
| `python scripts/package.py [--install \| --cli]` | 构建开发通道客户端包（`dist/blink-dev/`，并随包产出 `blink-dev` CLI）、可选静默更新本机 `blink-dev` 并在托盘后台拉起，或单独产出跨平台无头 `dist/blink-cli/` 捆绑包 | 待实现（M2+） |

<a id="channels"></a>
### 2.1 全小写 `blink` / `blink-dev` 双通道路径隔离

所有机器侧标识符——可执行文件名、CLI 命令与 MCP 键名、安装目录、默认 `<BLINK_VAULT_DIR>` 与 `vault.json` 通道戳、OS 运行态 `ipc.json`、缓存目录、Windows WebView2 `userDataFolder`、包名 / Bundle ID、单实例锁与系统密钥库命名空间——一律采用全小写 **`blink`**（正式版通道）与 **`blink-dev`**（开发版通道），界面展示标题可保留 `BLINK` / `BLINK Dev`。两个通道完全隔离，绝不共享或互相修改便携库、离线队列与凭据（[存储与安全](../design/architecture.md#storage-security)）：

| 平台 / 端 | 正式通道（`blink`） | 开发通道（`blink-dev`） |
| --- | --- | --- |
| Windows | 安装 `%LOCALAPPDATA%\Programs\blink`；默认便携库 `%LOCALAPPDATA%\blink\vault`；运行态 `%LOCALAPPDATA%\blink\run`；WebView2 `%LOCALAPPDATA%\blink\webview2` | 安装 `%LOCALAPPDATA%\Programs\blink-dev`；默认便携库 `%LOCALAPPDATA%\blink-dev\vault`；运行态 `%LOCALAPPDATA%\blink-dev\run`；WebView2 `%LOCALAPPDATA%\blink-dev\webview2` |
| macOS | 默认便携库 `~/Library/Application Support/blink/vault`；运行态/缓存 `~/Library/Caches/blink` | 默认便携库 `~/Library/Application Support/blink-dev/vault`；运行态/缓存 `~/Library/Caches/blink-dev` |
| Linux | 默认便携库 `${XDG_DATA_HOME:-~/.local/share}/blink/vault`；运行态 `$XDG_RUNTIME_DIR/blink`；缓存 `${XDG_CACHE_HOME:-~/.cache}/blink` | 默认便携库 `${XDG_DATA_HOME:-~/.local/share}/blink-dev/vault`；运行态 `$XDG_RUNTIME_DIR/blink-dev`；缓存 `${XDG_CACHE_HOME:-~/.cache}/blink-dev` |
| Android | Application ID `io.github.chialecode.blink`（私有目录 `<AppFilesDir>/blink`） | Application ID `io.github.chialecode.blink.dev`（私有目录 `<AppFilesDir>/blink-dev`） |
| iOS | Bundle ID `io.github.chialecode.blink`（沙盒 `<ApplicationSupport>/blink`） | Bundle ID `io.github.chialecode.blink.dev`（沙盒 `<ApplicationSupport>/blink-dev`） |
| 无头 `blink sync serve` / CLI | `$BLINK_VAULT_DIR`（`vault.json` 通道戳 `blink`）；MCP 服务键 `"blink"` | `$BLINK_VAULT_DIR`（本地默认 `.local/blink-dev/vault`，Git 忽略，通道戳 `blink-dev`）；MCP 服务键 `"blink-dev"` |

Windows 端严禁在 `%APPDATA%` 或用户主目录根部散落配置文件夹；`<BLINK_VAULT_DIR>` 内严禁存放任何明文凭据与 `ipc.json`；所有非数据库状态文件均采用“同目录临时文件 + `flush` + 原子重命名”写入。

<a id="dev-install"></a>
### 2.2 开发版自动安装到本机托盘（M2+ 桌面端生效）

每当需要用户做 `H-*` 实机检查时（B 交付整个阶段、A 审查修复后、按用户反馈修复后），交接 Agent 自动执行 `python scripts/package.py --install`（仅做自动验证的构建不带 `--install`；设 `BLINK_DEV_AUTO_INSTALL=0` 或 `CI=true` 时自动跳过）：

1. 仅检测并更新本机已安装的开发通道 `blink-dev`（含随包分发的 `blink-dev` CLI 捆绑目录），绝不读写正式版 `blink`。
2. 若 `blink-dev` 正在运行，通过 `--quit-for-update` 通知现有实例安全刷盘离线队列、完成 `mirror/` 末次防抖写出、执行 `PRAGMA wal_checkpoint(TRUNCATE)` 并清理运行态 `ipc.json` 后自行退出（最多等待 30 秒，超时则放弃本次安装并说明原因，不强杀进程）。
3. 静默覆盖安装并核对卸载项版本号一致后，**总是以 `--background` 参数在系统托盘后台拉起 `blink-dev`**（脱离当前命令沙箱作业对象，防止命令结束连带关闭常驻进程），将安装回执写入 `artifacts/package/install-dev.json`。

<a id="gates"></a>
## 3. 两级质量门禁与安静有界验证

- **两级门禁（Two-Tier Gate）**：
  1. **快速门禁（Quick Gate，日常编码与局部修复，单轮约 5～10 分钟）**：验证受改动包的 `dart format`、`dart analyze --fatal-infos`、相关 `dart test` / `flutter test`、`python scripts/check_docs.py` 与 `git diff --check HEAD`。只修改文档时仅需运行 `python scripts/check_docs.py` 与 `git diff --check HEAD`；改动门禁脚本时追加 `python -B scripts/test_check_docs.py`。
  2. **完整阶段门禁（Full Stage Gate，B 阶段交付与 A 集中审查收尾必跑）**：串行运行全工作区 `dart format --output=none --set-exit-if-changed .`、`dart analyze --fatal-infos`、向下依赖方向静态校验（禁止 `packages/*` 引用 Flutter UI，`INV-02`）、全量纯 Dart 与 Flutter 测试（含 `ExternalAiRepository` 原文层只读断言、BFM v1 一致性夹具、CJK `unicode61` 检索、离线 Outbox 与 E2EE WebDAV/S3 幂等收敛、`packages/blink_sanitizer` HTML/SVG/CSS 对抗净化与零外链/零硬编码色值断言、四层 `#private` 零出境哨兵断言、`VACUUM INTO` 热备份与冷拷贝断言）、安静进程冒烟、OSV 依赖漏洞审计、`check_docs.py` 与 `git diff --check HEAD`。
- **有界验证与真实状态记录**：日常单轮验证控制在约 10 分钟内，预计超出的压力或大数据量长测须先请用户授权。验证结果如实区分 `passed`、`failed`、`blocked`、`not-run`；缺平台工具链或硬件环境时记为 `not-run`，严禁靠删除、跳过或弱化断言来换取门禁通过。源码或契约变更后，旧构建包与旧跑次结果失效。

<a id="quiet-tests"></a>
### 3.1 安静回环测试铁律

所有自动化测试、组件截图、原型与进程冒烟均不得干扰用户前台工作：

- **零弹窗、零抢焦点**：Flutter 界面测试在内存无头测试器中运行；桌面端真实进程冒烟固定开启安静模式（`BLINK_QUIET=1`），窗口隐藏或无激活后台创建，不调用置顶或聚焦 API，不闪烁子进程控制台窗口，禁用真实 LAN mDNS 广播弹窗。
- **零音频外放与零系统对话框**：录音与播放测试统一注入合成样本流与静音桩，不打开真实麦克风、摄像头、系统音频设备、外部浏览器、资源管理器或系统通知弹窗。
- **仅限本机回环地址（Loopback-Only）**：集成测试与冒烟中的内嵌 `shelf` 同步服务、桌面回环 IPC 端点、MCP Streamable HTTP、假 WebDAV/S3 桩、假 OpenAI 兼容模型桩与假网页源一律只绑定 `127.0.0.1` 随机端口，杜绝触发操作系统防火墙授权弹窗；测试环境默认阻断公网出站请求，不调用真实第三方云端大模型或外部网站。
- **完全临时目录隔离**：测试与冒烟将 `<BLINK_VAULT_DIR>`、OS 运行态目录、缓存、密钥桩与单实例锁全部重定向至独立临时目录，绝不触碰本机真实 `blink` 或 `blink-dev` 目录。

<a id="git-ci-release"></a>
## 4. Git、远端保护、CI 与发布约定

- **分支、提交与 DCO**：默认分支为 `main`，远端仓库为 [chialecode/blink](https://github.com/chialecode/blink)，本地固定配置 `core.autocrlf=false`、`pull.ff=only`、`fetch.prune=true`（行尾统一由 `.gitattributes` 约束为 LF）。初始根提交 `642e618`（空 `README.md` + DCO 签名）永久不可改写。每个阶段遵循[单阶段单提交规则](workflow.md#git-stage)，采用 Conventional Commits 格式（如 `feat(m1): ...`），每次提交与 amend 均附带 DCO 签名（`git commit -s` / `git commit --amend -s`）。push、创建 PR、合并与发布均须用户逐项明确授权，严禁使用 `--all`、`--mirror` 或无授权强推，严禁轮询式长挂命令（如 `gh pr checks --watch`）。
- **远端 `main-protection` 规则集与仓库治理**：`main` 激活仓库规则集 `main-protection`（无旁路豁免）：禁止直接推送、强推与删除，要求线性历史、全部评审讨论解决、仅允许 squash 合并（合并提交使用 PR 标题与正文，合并后自动删除源分支），必需状态检查固定为 `repository-quality`。仓库关闭 Issues、Wiki 与 Projects，仅开放 [Discussions](https://github.com/chialecode/blink/discussions)，PR 仅限协作者创建。
- **CI 与 Actions 最小权限**：[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) 的必需 job 名固定为 `repository-quality`（无路径过滤，保证纯文档阶段 PR 同样产出必需检查），顶层权限 `contents: read`；工作流仅允许引用仓库白名单内锁定 40 位完整提交 SHA 的官方 Action（远端 `sha_pinning_required=true` 在服务端强制，见 [ACT-003](../../USER-ACTIONS.md#act-003)；修改选定白名单时须一并回读 `github_owned_allowed=false`）（当前为 `actions/checkout` 与 `actions/setup-python`，M2 起按需补齐锁定 SHA 的官方 Flutter/Dart 动作），不引入第三方未审计 Action；外部贡献者 Fork PR 运行工作流前须维护者批准。Dependabot（[`.github/dependabot.yml`](../../.github/dependabot.yml)）设置 7 天版本冷却期并禁用自动 rebase，告警与自动安全更新处于开启状态。

<a id="outputs"></a>
### 4.1 版本号与生成物目录

- **版本号与发布标签**：不创建 `M1`、`M2` 等阶段标签；正式发行版从 `v0.1.1` 起递增（首个正式版前的开发包统一标为 `0.1.0-dev.<UTC年月日时分>`），开发通道与正式通道互不跨通道检查更新；正式发布说明唯一对应 [CHANGELOG](../../CHANGELOG.md) 中同名版本小节。
- **生成物归口与单份保留**：所有构建缓存与运行输出只写入 `.gitignore` 忽略目录——`build/`、`.dart_tool/`、`tmp/` 随时可重建；`dist/<通道>/`（`blink-dev`、`blink`、`blink-cli`）与 `artifacts/<类别>/`（`smoke`、`uishots`、`package`、`audit`、`review`）每次采用临时目录校验后再原子替换，每类只保留最新一份；`.local/` 存放本机开发私密配置与测试沙盒库，不清理、不入库。
