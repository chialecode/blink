# 工程规则：工具链、通道路径、门禁、Git 与发布

现行技术选型依据见[纯 Dart 架构选型研究（2026-11-22）](../research/2026-11-22-pure-dart-pivot.md#overview)，进程拓扑、目录结构与架构不变量见[系统架构](../design/architecture.md#repo-layout)。

<a id="toolchain"></a>
## 1. 工具链与跨端工程基线

本节区分**已实现基线**、**开发机实测就绪基线**与**后续规划基线**，不把后续阶段才初始化的工程目录或待装工具写成已存在：

| 层级 | 组件与版本基线 | 锁定与契约约束 | 当前状态 |
| --- | --- | --- | --- |
| 仓库治理、门禁与打包脚本（仅 CI/开发治理） | Python `3.12+` 标准库（`scripts/check_docs.py`、`check.py`、`deps.py`、`package.py` 与回归测试） | 零第三方依赖；CI 固定使用 `ubuntu-24.04` 与 Python `3.12`；**仅服务于仓库文档卫生、两级门禁、依赖审计与打包编排，BLINK 运行时产品零 Python 依赖** | **已实现** |
| 纯 Dart 共享核心与净化器（`packages/blink_core`、`packages/blink_sanitizer`） | Dart `>= 3.10`（Dart Workspace 统一管理） | `pubspec.lock` 精确锁定；`packages/blink_sanitizer` 已锁定 `html 0.15.7`、`meta 1.19.0`、`lints 6.1.0`、`test 1.32.0` 与自研 W3C CSS Syntax L3 词法编译器；`packages/blink_core` 已锁定 `sqlite3 3.9.1`（Native Assets，见 [DEC-030](../decisions.md#dec-030)）、`markdown 7.3.1`、`crypto 3.0.8`、`path 1.9.1`、`characters 1.4.1`、`collection 1.19.1`、`meta 1.19.0`、`lints 6.1.0`、`test 1.32.0`，提供便携库 `VaultManager`、`RawRepository` / `ExternalAiRepository`、隔离 CJK FTS5 `index/fts.db`、`BlobStore`、BFM v1 引擎与 5 秒防抖 `MirrorExporter`（同步与文档解析待后续阶段扩展）；严禁引入 `package:flutter/*`（`INV-02`） | **`packages/blink_sanitizer` 与 `packages/blink_core`（M3 核心存储/BFM/FTS5/镜像）已实现**；同步与文档解析待实现（M4～M5） |
| 五端客户端（`apps/blink_client/`） | Flutter `3.50.0` / Dart `3.14.0`（根目录 `.flutter-version` 固定、Dart Workspace 统一管理），目标平台：`Windows`、`macOS`、`Linux`、`Android`、`iOS` | 已接入工作区包 `blink_core` 与 `blink_sanitizer`（严禁直接引用 `sqlite3`，`INV-02`），状态管理采用纯 Flutter `ChangeNotifier` + `ListenableBuilder`，原生文件/目录选择通过 `BlinkFilePicker` 封装现有 `win32 6.4.0` COM 对话框（安静测试零弹窗）；已锁定 `material_ui 1.11.0`（Flutter 3.50 替代已弃用的 `flutter/material.dart`）、`window_manager 0.7.0`、`tray_manager 0.9.0`、`win32 6.4.0`、`ffi 2.2.0` 与 `flutter_lints 6.0.0`（`pubspec.lock` 入库）；后续阶段按需接入 `pdfrx 3.1.0`、`super_sliver_list`、`flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `fl_chart 1.3.1`（Surface 1）、`flutter_inappwebview 6.1.5` + `desktop_webview_window 0.4.3`（Surface 2，Linux 动态链接受 [DEC-026](../decisions.md#dec-026) 约束）、`bonsoir 7.1.6`、`record 6.2.x`、`flutter_secure_storage`。手写层坚持 BFM v1 原生 `TextField`（禁重型 WYSIWYG） | **已实现（Windows M3 自适应桌面工作区、BFM v1 编辑器、便携库/文件/待办管理、退出刷盘与按用户打包）**；同步、伴读、AI 与其余四端待实现 |
| 原生 CLI / MCP / 无头同步与技能包（`packages/blink_cli`、`packages/blink_skills`） | Dart `>= 3.10` + **`dart build cli`** | `mcp_dart 2.4.4`（封装于 `BlinkMcpAdapter`，可无缝切换 `dart_mcp`）、`args 2.7.0`、`shelf 1.4.3` / `shelf_router 1.1.5`；由 `dart build cli` 产出含 `libsqlite3` 的统一自包含目录包，同时承载 CLI、MCP Server 与无头 `blink sync serve`；`packages/blink_skills` 遵循 `agentskills.io` 开放规范 | 待实现（M4 同步 / M6 完整） |

### 1.1 开发环境工具链核验状态（2026-11-22 核对）

经纯 Dart 零后端收敛后，**Docker、外置数据库服务与任何 Python 后端运行工具链均已从全产品 MVP 前置清单彻底移除**；当前开发机已完成 Windows 桌面构建、打包与升级演练所需的全部核心工具链就绪核验：

| 工具类别 | 组件与用途 | 当前实测状态 | 阶段准入节点与处置说明 |
| --- | --- | --- | --- |
| 版本控制与包管理基础 | `git 2.56.x`、`gh 2.103.x`、`winget 1.29.x` | **已就绪** | 支撑分支治理、远端规则核验与非交互式工具安装 |
| 仓库门禁与打包脚本运行时 | `Python 3.12.16` 标准库 | **已就绪** | 仅用于运行零外部依赖的 `scripts/{check_docs,check,deps,package}.py` 及测试，不进入 BLINK 运行时产物 |
| Windows 桌面 C++ 与系统 WebView 底座 | Visual Studio Build Tools 2026（MSVC `x64`、内置 `CMake`、`Windows 11 SDK 10.0.26100`）与 Windows 11 WebView2 Runtime | **已就绪** | 满足 `flutter build windows`、`sqlite3` / PDFium FFI 及 Surface 2 WebView2 运行前置条件 |
| Flutter / Dart 客户端与 CLI 工具链 | Flutter `3.50.0` stable（内置 Dart `3.14.0`），按用户安装于 `%LOCALAPPDATA%\Programs\flutter`，由 `.flutter-version` 固定（不使用 `fvm`） | **已就绪** | 官方归档 SHA-256 核验通过（`scripts/flutter-checksums.json`），分析上报与 CLI 动画已关闭，Windows 开发者模式已开启；`flutter doctor` Flutter/Windows/Visual Studio 项通过，门禁自动核对 `.flutter-version` |
| Windows 按用户安装包编译器 | NSIS `3.13`（`scripts/package.py` 首次使用时下载官方 `nsis-3.13.zip`，核对固定的 SHA-256 后解压到 Git 忽略的 `.tools/nsis-3.13/`；也可用 `BLINK_MAKENSIS` 指向同版本的 `makensis.exe`） | **已就绪** | `apps/blink_client/windows/packaging/blink.nsi` 以 `!if "${NSIS_VERSION}" != "v3.13"` 拒绝其他版本，`makensis -WX` 把警告当错误；下载失败或校验不符时明确失败；仅构建期工具，不随产品分发（[DEC-029](../decisions.md#dec-029)） |
| Android 移动端构建链 | JDK `17`/`21` + Android SDK（`platform-tools`、`build-tools`、`platforms`） | **M3 移动端打包前待安装** | 不阻塞核心库与桌面端先行编码；构建 Android `blink-dev` 安装包与联调前补齐 |
| 异地虚拟私网（可选外部工具） | Tailscale 客户端 | **M4 跨设备 WAN 联调前** | 自动化门禁均通过 `127.0.0.1` 回环与模拟桩运行；跨设备外网同步实测前装妥 |
| Linux Surface 2 构建开发库（仅 Linux 宿主机/CI） | `libwebkit2gtk-4.1-dev`、`libsoup-3.0-dev` | **M6 Linux Surface 2 构建前** | 仅在 Linux 桌面构建机或 Linux CI runner 安装；目标机运行期动态链接未修改的系统共享库（[DEC-026](../decisions.md#dec-026)），缺失时自动降级 Surface 1 |

<a id="commands"></a>
## 2. 标准命令与双通道隔离

从仓库根目录执行：

| 命令 | 作用 | 状态 |
| --- | --- | --- |
| `python scripts/check_docs.py` | 零依赖检查必需文档布局、`CLAUDE.md` 单行引用、无 YAML 头（M6 起仅对 `packages/blink_skills/skills/**/SKILL.md` 豁免并做 Schema 校验）、相对链接与显式/标题锚点可达、禁止引用式链接、UTF-8 无 BOM 与 LF 行尾（仅 `.bat`/`.cmd` 允许 CRLF）、拦截本机绝对路径/敏感凭据/本机参考项目名与同级仓库名（自动跳过 Flutter Git 忽略的 `ephemeral`/`.symlinks`/`flutter_export_environment.sh`，覆盖 `.githooks/`、`.gitignore` 等无扩展名受控文本） | **已实现** |
| `python -B scripts/test_check_docs.py` | 文档门禁自身的零依赖回归夹具（`unittest`，30 条，全部在系统临时目录构造正反例，不写工作区）：断链、缺锚点、引用式链接、YAML 头、BOM、CRLF、非 kebab-case、`CLAUDE.md` 契约、本机路径、Flutter 临时生成物豁免边界、密钥特征、禁止文件与参考/同级仓库名拦截 | **已实现** |
| `git config --local core.hooksPath .githooks` | 每个新克隆执行一次，启用 [`.githooks/pre-push`](../../.githooks/pre-push)：推送前运行 `python -B scripts/check.py --quick`。CI 上没有同级仓库与本机参考索引，参考名拦截只有在开发机上才有实际词表，因此本地 hook 是该项检查的主要执行点；hook 可被跳过，不能替代远端规则集 | **已实现** |
| `git diff --check HEAD` | 检查受跟踪文件的尾随空白、行尾符与冲突标记（新增文件先 `git add`） | **已实现** |
| `dart format --output=none --set-exit-if-changed .` | 全纯 Dart / Flutter 工作区（`apps/blink_client` 及后续 `packages/*`）统一代码格式校验 | **已实现** |
| `flutter analyze --fatal-infos` 与 `dart analyze --fatal-infos` | 静态分析与类型安全校验（零警告零 info；由 `check.py` 自动发现 `packages/*` 并与 `apps/blink_client` 统一编排） | **已实现** |
| `flutter test` 与 `dart test` | 纯 Dart 共享包（`packages/*`）单元测试、对抗安全测试与 Flutter 桌面外壳、生命周期与原生通道单元/组件测试 | **已实现** |
| `dart build cli -t packages/blink_cli/bin/blink.dart -o dist/blink-cli/` | 构建包含原生 `libsqlite3` Build Hooks 的统一自包含 CLI / MCP / 无头同步捆绑目录包（**禁用旧命令 `dart compile exe`**） | 待实现（M4/M6） |
| `python scripts/check.py --quick` | 日常快速门禁（预算 ≤ 5～10 分钟，10 项）：`check_docs.py`、`git diff --check`、`.flutter-version` 核对、`scripts/test_*.py` 全量 Python 单测、`INV-02` 单向依赖检查、`dart format`、`packages/*` `dart analyze --fatal-infos` 与 `dart test`、`flutter analyze --fatal-infos` 与 `flutter test`；另支持 `--ci`（Linux CI 子集）与 `--install-linux-flutter <dir>`（按 `scripts/flutter-checksums.json` 先验 SHA-256 再解压） | **已实现** |
| `python scripts/check.py` | 完整阶段门禁（14 项）：在 `--quick` 之上追加 `deps.py --audit`，并在 Windows 上执行 `package.py --channel blink-dev`、`--channel blink --version 0.1.0` 与 `--rehearsal`（非 Windows 对应打包项记 `not-run`） | **已实现** |
| `python scripts/deps.py [--audit]` | [7 天冷却期依赖盘点与 OSV 漏洞审计](workflow.md#dependency-inventory)：核对 pub.dev 直接依赖冷却期、`pubspec.lock` 全量托管包 OSV 漏洞（例外表 `scripts/deps-exceptions.json`）、`.flutter-version` 与官方 Windows/Linux 校验和、`.github/workflows/ci.yml` Action SHA 与白名单策略，结果原子写 `artifacts/audit/deps.json`；断网记 `not-run` 并以非零退出 | **已实现** |
| `python scripts/package.py [--channel blink-dev\|blink] [--version <ver>] [--install] [--rehearsal]` | 构建 Windows 桌面客户端并用 NSIS `3.13` 产出按用户安装包（`dist/<通道>/`，附 `SHA256SUMS.txt` 与 `build-info.json`，单份留新原子替换）；`--install` 按 [§2.2](#dev-install) 静默安装或更新本机 `blink-dev`（首次也自动安装）并写 `artifacts/package/install-dev.json`；`--rehearsal` 以测试身份 `blink-dev-test` 在临时目录执行安装/运行中升级/退出/卸载与宿主快照比对并写 `artifacts/package/rehearsal.json` | **已实现** |
| `python scripts/package.py --cli` | 单独产出跨平台无头 `dist/blink-cli/` 捆绑包（随 CLI/同步阶段落地） | 待实现（M4/M6） |

<a id="channels"></a>
### 2.1 全小写 `blink` / `blink-dev` 双通道路径隔离

所有机器侧标识符——可执行文件名、CLI 命令与 MCP 键名、安装目录、默认 `<BLINK_VAULT_DIR>` 与 `vault.json` 通道戳、OS 应用本地状态目录（`settings/`、`run/`、`ipc.json`、缓存、`credentials/`、Windows WebView2 `userDataFolder`）、包名 / Bundle ID、单实例锁与系统密钥库命名空间——一律采用全小写 **`blink`**（正式版通道）与 **`blink-dev`**（开发版通道），界面展示标题可保留 `BLINK` / `BLINK Dev`。桌面端执行**三根存储布局**（[DEC-031](../decisions.md#dec-031)）：应用本地状态留存 OS 应用本地目录，已安装端的默认单文件夹便携库位于系统“文档”目录，源码构建隔离在 Git 忽略的 `.local/blink-dev/` 沙盒中；双通道及测试身份完全隔离，绝不共享或互相修改便携库、离线队列与凭据（[存储与安全](../design/architecture.md#storage-security)）：

| 平台 / 端 | 正式通道（`blink`） | 开发通道（`blink-dev`） |
| --- | --- | --- |
| Windows（已安装） | 安装 `%LOCALAPPDATA%\Programs\blink`；应用本地态 `%LOCALAPPDATA%\blink`（`settings/`、`run/`、`webview2/`、`credentials/`、`logs/`、`cache/`）；默认便携库 `<Documents>\blink`（经 Win32 `SHGetKnownFolderPath(FOLDERID_Documents)` 解析，回退 `%USERPROFILE%\Documents\blink`、再回退 `<dataRoot>\vault`） | 安装 `%LOCALAPPDATA%\Programs\blink-dev`；应用本地态 `%LOCALAPPDATA%\blink-dev`；默认便携库 `<Documents>\blink-dev` |
| macOS（已安装） | 应用本地态 `~/Library/Application Support/blink`；运行态/缓存 `~/Library/Caches/blink`；默认便携库 `~/Documents/blink` | 应用本地态 `~/Library/Application Support/blink-dev`；运行态/缓存 `~/Library/Caches/blink-dev`；默认便携库 `~/Documents/blink-dev` |
| Linux（已安装） | 应用本地态 `${XDG_DATA_HOME:-~/.local/share}/blink`；运行态 `$XDG_RUNTIME_DIR/blink`；缓存 `${XDG_CACHE_HOME:-~/.cache}/blink`；默认便携库 `${XDG_DOCUMENTS_DIR:-~/Documents}/blink` | 应用本地态 `${XDG_DATA_HOME:-~/.local/share}/blink-dev`；运行态 `$XDG_RUNTIME_DIR/blink-dev`；缓存 `${XDG_CACHE_HOME:-~/.cache}/blink-dev`；默认便携库 `${XDG_DOCUMENTS_DIR:-~/Documents}/blink-dev` |
| 桌面源码构建（无安装身份） | 默认拒绝启动；仅当同时显式设置 `BLINK_ALLOW_SOURCE_PROD=1` 与隔离的 `BLINK_DATA_DIR`（且规范化路径不与真实 `blink` 目录重叠）时放行 | 应用本地态 `<repoRoot>/.local/blink-dev/app`；默认便携库 `<repoRoot>/.local/blink-dev/vault`（仓库外回退 `<systemTemp>/blink-source-dev/{app,vault}`） |
| Android | Application ID `io.github.chialecode.blink`（私有目录 `<AppFilesDir>/blink`） | Application ID `io.github.chialecode.blink.dev`（私有目录 `<AppFilesDir>/blink-dev`） |
| iOS | Bundle ID `io.github.chialecode.blink`（沙盒 `<ApplicationSupport>/blink`） | Bundle ID `io.github.chialecode.blink.dev`（沙盒 `<ApplicationSupport>/blink-dev`） |
| 无头 `blink sync serve` / CLI | `$BLINK_VAULT_DIR`（`vault.json` 通道戳 `blink`）；MCP 服务键 `"blink"` | `$BLINK_VAULT_DIR`（本地默认 `.local/blink-dev/vault`，Git 忽略，通道戳 `blink-dev`）；MCP 服务键 `"blink-dev"` |

桌面端便携库解析优先级固定为：`BLINK_VAULT_DIR`（锁定设置页切换） > `settings/desktop.json` `customVaultPath` > 显式 `BLINK_DATA_DIR` 下的 `<dataRoot>/vault` > 源码构建 `<repoRoot>/.local/blink-dev/vault` > `<BLINK_DOCUMENTS_DIR 或系统 Documents>/<身份>` > `<dataRoot>/vault`。Windows 端严禁在 `%APPDATA%` 或用户主目录根部散落配置文件夹；`<BLINK_VAULT_DIR>` 内严禁存放任何明文凭据与 `ipc.json`；所有非数据库状态文件均采用“同目录临时文件 + `flush` + 原子重命名”写入。

<a id="packaging"></a>
<a id="dev-install"></a>
### 2.2 安装包与开发版自动安装到本机托盘（M2+ Windows 桌面端生效）

**安装包**（[DEC-029](../decisions.md#dec-029)）：`apps/blink_client/windows/packaging/blink.nsi` 由 `scripts/package.py` 用 NSIS `3.13` 编译，按用户安装（不需要管理员），中文界面，用 zlib 压缩（选型与许可证见[NSIS 安装器选型记录](../research/2026-11-24-nsis-installer.md)）。

- **位置与卸载项**：默认装到 `%LOCALAPPDATA%\Programs\<身份>`；卸载项写在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\<应用标识>`（如 `io.github.chialecode.blink-dev`），含 `DisplayName`、`DisplayVersion`、`DisplayIcon`、`Publisher`、`InstallLocation`、`UninstallString`、`QuietUninstallString`、`EstimatedSize`、`NoModify`、`NoRepair`。
- **目录**：首次交互安装可选目录；已安装时不再显示目录页，更新装回卸载项里的 `InstallLocation`。`/D=` 指向另一个目录时先完整卸载原目录里的旧副本再装到新目录，始终只有一份安装与一个卸载项。目录里已有不属于本身份的 `Uninstall.exe`（别的程序或另一通道；本身份的副本丢了卸载项但 `<身份>.exe` 还在时照常原地更新）时拒绝安装：交互安装留在目录页提示换目录，静默安装以退出码 `7` 结束，不运行也不覆盖那个卸载程序。
- **命令行**：`/S` 静默；`/D=<目录>` 指定目录（放在最后、不加引号，路径有空格也不加；`package.py` 因此拼命令行字符串而不是参数列表）；`/RELAUNCH` 静默更新完成后启动 BLINK；`/NODESKTOP` 让静默安装（包括首次安装与开发版覆盖安装）不建桌面快捷方式（安装演练用）。
- **快捷方式**：开始菜单快捷方式只在首次安装（以及 `/D=` 换目录重装，先完整卸载原副本）时创建；覆盖安装（含开发版自动重装）不创建、不覆写也不触碰开始菜单快捷方式（用户删掉的不会重新生成，保留的原样不动）。桌面快捷方式在交互安装时由完成页的勾选框决定（默认不勾）；静默安装未带 `/NODESKTOP` 时，首次安装（及 `/D=` 换目录重装）自动创建，覆盖安装按编译期参数 `BLINK_DESKTOP_ON_UPDATE` 决定——开发版身份（`blink-dev` / `blink-dev-test` 为 `1`）会创建，正式版身份（`blink` / `blink-test` 为 `0`）不增不删。完整卸载同时清理开始菜单与桌面快捷方式（已不存在时同样正常完成）。
- **运行中的实例**：安装器与卸载器发现 `<身份>-instance` 互斥量时，调用已安装的 `<身份>.exe --quit-for-update` 请其保存后退出，最多等 30 秒；忙碌、超时或无法请求（请求没送达且它仍在运行）时放弃并以退出码 `3`（忙碌）、`4`（超时）、`5`（无法请求）结束，从不强杀。交互安装会先询问。互斥量在进程真正结束、放开自己的文件之前就没了，没有互斥量的副本（还在退出或卡住）也占着文件：所以之后（同一个 30 秒内）还要等到已安装的 `<身份>.exe` 能以写方式打开（运行中的映像以共享冲突拒绝），等不到同样以 `4` 结束；只读、没有权限等别的拒绝不等，交给后面的写入处理。
- **覆盖升级清理**：每个版本的卸载器只删除自己安装的文件（构建时生成文件清单）。覆盖安装先以 `/S /UPDATE` 原地运行旧版本的卸载器，删掉旧版本的文件后再写入新文件，所以新版本去掉的文件不会残留；完整卸载再删快捷方式、卸载项与 `Uninstall.exe`，安装目录只在为空时删除，用户放进去的文件与数据根都不动。
- **文件没写全**：静默安装时 NSIS 遇到写不进去的文件（被别的程序占用、没有写权限）只记错误、不中断；安装器因此在写入后检查，有文件没写进去就以退出码 `8` 结束，不写新的卸载程序、快捷方式与卸载项，卸载项保持原样（覆盖安装时仍是旧版本）。关掉占用的程序后重新安装即可：旧卸载器还在，会照常先清掉旧文件再写入。首次安装或用 `/D=` 换目录时遇到这种情况，目录里会留下部分文件而没有卸载项，用同一个目录重新安装会补齐。交互安装时 NSIS 先弹出自己的“中止/重试/忽略”，选“忽略”最后同样以退出码 `8` 结束。

**开发版自动安装**：凡需要用户审核或实机测试的 PR（尤其是高风险、打包安装或界面/行为改动），在请用户审核前先从 PR 分支执行 `python -B scripts/package.py --install` 更新本机开发版并在 PR 正文或评论记录回执；每次合并进 `main` 后（本机拉取 `main` 后）再同步执行一次（仅做自动验证的构建不带 `--install`；设 `BLINK_DEV_AUTO_INSTALL=0` 或 `CI=true` 时自动跳过）：

1. **只碰开发版且支持 PR 分支**：允许在干净的 PR 分支与 `main` 上直接构建安装，并在回执记录 `branch` 与 `gitSha`；读 `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\io.github.chialecode.blink-dev` 的 `InstallLocation` 与 `DisplayVersion`；没有卸载项就是首次安装，同样静默完成（装到默认目录）。只接受 `blink-dev` 通道产物，绝不读写正式版 `blink` 与测试身份 `blink-test` / `blink-dev-test` 的安装。
2. **窗口开着时推迟**：`blink-dev` 在运行且已安装的 `blink-dev.exe` 有可见的顶层窗口（最小化也算，隐藏到托盘不算）时，说明用户正在使用，每 2 秒检查一次，等窗口关闭或隐藏到托盘；最多等 10 分钟，仍开着就跳过这次安装（跳过不算失败），回执记 `reason=window_open` 并提示关窗后重新运行。
3. **请托盘中的实例保存后退出**：用已安装的 `blink-dev.exe --quit-for-update` 启动第二个实例，经单实例控制管道 `\\.\pipe\blink-dev-control`（只接受本机同一用户、拒绝远程客户端）把请求转给运行中的实例；实例走与托盘“退出”相同的生命周期序列（后续阶段再扩展为刷盘离线队列、末次镜像写出与 `PRAGMA wal_checkpoint(TRUNCATE)`），记下“为本机更新而退出”后退出，忙碌时回执 `busy`。工具最多等 30 秒，未退出即放弃本次安装、不强杀，并说明原因。单实例互斥量没了还要等已安装 `blink-dev.exe` 的进程真正结束（同一个 30 秒内，按完整程序路径匹配）：互斥量在进程放开文件之前就释放，不等就会撞上退出码 `8`；没有互斥量却仍在运行的 `blink-dev.exe` 同样等，等不到记 `reason=process_running`，不强杀。
4. **静默安装并核对**：以 `/S` 安装（安装器 10 分钟仍未结束时结束安装器进程并按失败记 `installer_failed_exit_-1`，这时安装目录可能只复制了一部分，重新运行即可），从卸载项与已安装可执行文件的版本资源双重核对版本等于新包。安装或核对失败时，若它是被这次安装请退出的，且安装目录是完整的（安装器在动文件之前就停下，即退出码 `3`、`4`、`5`、`7`；或文件已写完、只是核对没过），再以 `--background` 把现在装着的版本在托盘打开（回执 `relaunched=true`）；退出码 `8`、超时与其他退出码时目录可能只写了一部分，不再打开，回执提示重新运行 `--install`。
5. **总是在托盘后台拉起**：安装成功后，不论原先是否在运行，**总是以 `--background` 启动 `blink-dev`**（只显示托盘图标、不开主窗口、不抢焦点；托盘不可用时回退为最小化到任务栏）。工具自身在作业对象里时（Agent 命令沙箱结束会连带结束作业内进程），先经桌面外壳 `explorer.exe`（`Shell.Application.ShellExecute`）启动，使其成为外壳的子进程；外壳不可用再请求 `CREATE_BREAKAWAY_FROM_JOB`；都不行则照常启动，在回执记 `inJob=true` 并提示从开始菜单打开一次。
6. **回执**：写 `artifacts/package/install-dev.json`，字段统一为 camelCase：`identity`、`installed`、`skipped`、`reason`、`error`、`firstInstall`、`oldVersion`、`newVersion`、`installLocation`、`wasRunning`、`windowOpen`、`deferred`、`deferMs`、`quitMs`、`relaunched`、`background`、`inJob`、`elapsedMs`、`at`，另有 `branch`、`gitSha`、`dirty`、`installer`、`verifiedRegistryVersion`、`verifiedExeVersion`、`launchMethod`、`runningInTray`、`guidance`；构建失败时也写全部字段（`reason=build_failed`）。窗口检测按已安装的 `blink-dev.exe` 路径匹配，从构建目录直接运行的 `blink_client.exe` 不算。安装失败以非零退出；跳过不算失败。判断逻辑由注入假卸载项、假进程、假窗口与假安装器的单元测试覆盖：未安装（自动首次安装）、PR 分支预装、未运行、窗口开着（推迟后安装）、窗口一直开着（跳过）、托盘中运行（退出后装并重开）、30 秒不退出、互斥量没了进程还在（等它结束；一直不结束则放弃）、没有互斥量的 `blink-dev.exe` 在运行、`busy`、安装失败（请退出过的在目录完整时重新打开，目录可能只写了一部分时不打开）、安装后卸载项缺失、版本不符、仍在作业对象里、正式版与测试身份不受影响。

<a id="gates"></a>
## 3. 两级质量门禁与安静有界验证

- **两级门禁（Two-Tier Gate）**：
  1. **快速门禁（Quick Gate，日常编码与局部修复，单轮约 5～10 分钟）**：验证受改动包的 `dart format`、`dart analyze --fatal-infos`、相关 `dart test` / `flutter test`、`python scripts/check_docs.py` 与 `git diff --check HEAD`。只修改文档时仅需运行 `python scripts/check_docs.py` 与 `git diff --check HEAD`；改动门禁脚本时追加 `python -B scripts/test_check_docs.py`。
  2. **完整门禁（Full Gate，发布前以及改到打包、安装、更新、签名或发布链路时必跑）**：串行运行全工作区 `dart format --output=none --set-exit-if-changed .`、`dart analyze --fatal-infos`、向下依赖方向静态校验（禁止 `packages/*` 引用 Flutter UI，`INV-02`）、全量纯 Dart 与 Flutter 测试（含 `ExternalAiRepository` 原文层只读断言、BFM v1 一致性夹具、CJK `unicode61` 检索、离线 Outbox 与 E2EE WebDAV/S3 幂等收敛、`packages/blink_sanitizer` HTML/SVG/CSS 对抗净化与零外链/零硬编码色值断言、四层 `#private` 零出境哨兵断言、`VACUUM INTO` 热备份与冷拷贝断言）、安静进程冒烟、OSV 依赖漏洞审计、`check_docs.py` 与 `git diff --check HEAD`。
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

- **分支、提交与 DCO**：默认分支为 `main`，远端仓库为 [chialecode/blink](https://github.com/chialecode/blink)，本地固定配置 `core.autocrlf=false`、`pull.ff=only`、`fetch.prune=true`（行尾统一由 `.gitattributes` 约束为 LF）。初始根提交 `642e618` 永久不可改写。一个 issue 一个小 PR，分支 `<type>/<issue号>-<简短描述>`，Conventional Commits，每个提交 `git commit -s`（DCO）；PR 合并时 squash 成一个提交（[每次改动的流程](workflow.md#change-loop)）。push 与建 PR 长期授权；低风险 PR 由 Agent 在 CI 与独立审查通过后用 `gh pr merge <号> --squash --match-head-commit <头提交>` 合并，[高风险](workflow.md#high-risk) PR 由用户合并。严禁 `--all`、`--mirror`、强推与轮询式长挂命令（如 `gh pr checks --watch`）。
- **远端 `main-protection` 规则集与仓库治理**：`main` 激活仓库规则集 `main-protection`（无旁路豁免）：禁止直接推送、强推与删除，要求线性历史、全部评审讨论解决、仅允许 squash 合并（合并提交使用 PR 标题与正文，合并后自动删除源分支），必需状态检查固定为 `repository-quality`。仓库开启 [Issues](https://github.com/chialecode/blink/issues)（只允许协作者创建）与 [Discussions](https://github.com/chialecode/blink/discussions)，关闭 Wiki 与 Projects；PR 只允许协作者创建；允许自动合并与更新分支；网页提交要求 DCO 签名。远端设置的镜像是 [`.github/repository-settings.json`](../../.github/repository-settings.json)、[`.github/rulesets/main.json`](../../.github/rulesets/main.json) 与 [`.github/actions-policy.json`](../../.github/actions-policy.json)，改远端设置时同步回读并更新镜像。
- **CI 与 Actions 最小权限**：[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) 的必需 job 名固定为 `repository-quality`（无路径过滤，保证纯文档阶段 PR 同样产出必需检查；`runs-on: ubuntu-24.04`，`timeout-minutes: 15`），顶层权限 `contents: read`；工作流仅允许引用仓库白名单内锁定 40 位完整提交 SHA 的官方 Action（远端 `sha_pinning_required=true` 在服务端强制；修改选定白名单时须一并回读 `github_owned_allowed=false`），当前仅使用 `actions/checkout` 与 `actions/setup-python`，由 `python -B scripts/check.py --install-linux-flutter` 按 `.flutter-version` 与 `scripts/flutter-checksums.json` 下载并核对官方 Linux Flutter 归档 SHA-256 后运行 `python -B scripts/check.py --ci`，不新增第三方或未审计 Action；外部贡献者 Fork PR 运行工作流前须维护者批准。Dependabot（[`.github/dependabot.yml`](../../.github/dependabot.yml)）覆盖 `github-actions` 与根目录工作区 `pub`，设置 7 天版本冷却期并禁用自动 rebase，告警与自动安全更新处于开启状态。

<a id="outputs"></a>
### 4.1 版本号与生成物目录

- **版本号与发布标签**：不创建 `M1`、`M3` 等阶段标签；正式发行版从 `v0.1.1` 起递增（首个正式版前的开发包统一标为 `0.1.0-dev.<UTC年月日时分>`），开发通道与正式通道互不跨通道检查更新；正式发布说明唯一对应 [CHANGELOG](../../CHANGELOG.md) 中同名版本小节。
- **生成物归口与单份保留**：所有构建缓存与运行输出只写入 `.gitignore` 忽略目录——`build/`、`.dart_tool/`、`tmp/` 随时可重建；`dist/<通道>/`（`blink-dev`、`blink`、`blink-cli`）与 `artifacts/<类别>/`（`smoke`、`uishots`、`package`、`audit`、`review`）每次采用临时目录校验后再原子替换，每类只保留最新一份；`.local/` 存放本机开发私密配置与测试沙盒库，不清理、不入库。
