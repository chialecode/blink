# 当前阶段计划：M2（Windows 桌面骨架、打包与开发版自动安装更新）

- **阶段编号**：M2；计划标识 `BLINK-M2-01`，修订 1（2026-11-22，A 规划）。
- **角色**：A 规划；B 连续实施、自检与修复；A 集中审查（[开发流程](../dev-rules/workflow.md#agent-handoff)）。给 Agent B 的交接 prompt 见[第 9 节](#prompt)。
- **来源**：用户 2026-11-22 指示“下个阶段先把打包和电脑端 dev 自动安装更新做了”，并要求参考本机同类项目；据此插入新 M2、原 M2～M6 顺延为 M3～M7（[DEC-027](../decisions.md#dec-027)）。
- **分支与基点**：`feat/m2-desktop-packaging`，基于 M1 阶段提交 `f2baf27`（PR #1 已通过 `repository-quality`，待 [ACT-002](../../USER-ACTIONS.md#act-002) 合并）。PR #1 合并后，B 在交付前把本阶段提交变基到新的 `main`（M1 内容经 squash 后树一致，变基应无冲突）；本阶段全部规划、实现、返工与审查修复收敛为该分支上的**单个 DCO 签名提交** `feat(m2): ...`。
- **正本依据**：需求 `NFR-DEV-003`（新增）、`NFR-PLAT-002`（Windows 安装身份部分）、`NFR-DEV-002`（工程门禁）、`NFR-PLAT-001`（桌面最小窗口 `760×560`）；验收 [AC-11](roadmap.md#acceptance)；安装身份与生命周期契约 [系统架构 §4.3](../design/architecture.md#desktop-lifecycle)；双通道路径 [工程规则 §2.1](../dev-rules/engineering.md#channels)；本机更新流程 [工程规则 §2.2](../dev-rules/engineering.md#dev-install)；可逆默认 [Q-008](../../USER-ACTIONS.md#q-008)；人工检查 [H-002](../../USER-ACTIONS.md#h-002)。

<a id="scope"></a>
## 1. 目标、范围与退出条件

**本阶段完成后的闭环**：Agent 需要用户检查时执行一条 `python scripts/package.py --install`，即可把当前源码构建成 `blink-dev` 安装包，让本机运行中的 BLINK Dev 保存后退出、静默装上新版本、核对版本，并让它只在托盘里重新运行；用户首次手动安装一次后不再需要自己打包或安装。正式通道 `blink` 同样能产出安装包（不自动安装、不联网更新）。

| 项目 | 约定 |
| --- | --- |
| 本阶段内容 | Flutter 3.50.0 工具链与 Dart Workspace；`apps/blink_client` 最小 Windows 桌面外壳；按安装身份的单实例、控制管道、托盘、`--background`、`--quit-for-update`；编译期通道/版本/身份注入；Inno Setup 7.1.1 按用户安装包；`scripts/package.py`（打包、`--install`、`--rehearsal`）；`scripts/check.py` 两级门禁；`scripts/deps.py` 7 天冷却与 OSV 审计；CI 接入固定版本 Flutter；Dependabot 增加 `pub` 生态 |
| 不在本阶段 | 便携库、数据库、BFM 编辑器与任何业务数据（M3 起）；`packages/*` 共享包（M3 起，本阶段不建空包）；macOS / Linux / Android / iOS 构建与安装包（目录随 `flutter create` 生成但不构建，记 `not-run`）；正式版应用内联网更新、代码签名、开机自启、全局热键（[Q-008](../../USER-ACTIONS.md#q-008)） |
| 可连续执行 | 安装 Flutter SDK 到用户目录并校验 SHA-256；本地实现、测试、打包、测试身份安装演练（临时目录、安静模式）；本机已装 `blink-dev` 时的 `--install`；本地 commit / amend |
| 外部操作与授权 | 已有授权：无（ACT-001 / ACT-003 属 M1，已完成）。**未经授权严禁**：push 本分支、创建/更新 PR、合并、打标签、发布、修改远端设置；交付时由 B 在 USER-ACTIONS 新增 `ACT-004`（推送 M2 分支并创建 PR #2）等待授权 |
| 核心不变量 | `INV-06` 双通道隔离：任何命令都不读写正式版 `blink` 的安装、卸载项与数据目录；测试身份只装进临时目录且演练后卸载干净；`INV-07` 原子写入（`settings/desktop.json`、`run/lifecycle.json`、回执）；安静测试铁律（[工程规则 §3.1](../dev-rules/engineering.md#quiet-tests)）；不强杀用户正在运行的 BLINK Dev |

退出条件：

| 条件 | 判定标准 | 工作包 | 验收 |
| --- | --- | --- | --- |
| 工具链与依赖可复现 | 固定 Flutter 3.50.0 / Dart 3.14.0 记录在 `.flutter-version` 并由门禁核对；`pubspec.lock` 入库；`deps.py` 输出盘点与审计结果 | `M2-W01` | `M2-K01` |
| 桌面外壳与生命周期正确 | 单实例、控制管道、托盘、`--background`、关闭隐藏、保存后退出全部按[架构 §4.3](../design/architecture.md#desktop-lifecycle)工作，单元测试与 Windows 冒烟通过 | `M2-W02`、`M2-W03` | `M2-K02`～`M2-K05` |
| 两通道安装包可产出、可校验 | `package.py --channel blink-dev` 与 `--channel blink` 产出安装包、`SHA256SUMS.txt` 与 `build-info.json`，版本资源与“关于”一致 | `M2-W04` | `M2-K06` |
| 本机开发版自动更新闭环 | `--install` 判断逻辑单测全覆盖；测试身份完整演练通过；本机已装时真实执行并写回执，未装时如实跳过 | `M2-W05` | `M2-K07`、`M2-K08`、`AC-11` |
| 门禁与 CI | `check.py --quick` 与完整门禁可用；CI `repository-quality` 在 Linux 上跑文档、Python 单测、`dart format`、`flutter analyze`、`flutter test` 并在 10 分钟内完成 | `M2-W06` | `M2-K09` |
| 正本同步 | 工程规则命令表与状态、架构、状态页、阶段报告、USER-ACTIONS（`H-002`、`ACT-004`）、CHANGELOG 与实际实现一致，`check_docs.py` 通过 | `M2-W07` | `M2-K10` |

<a id="baseline"></a>
## 2. A 已核对的现场（2026-11-22）

- **Git**：`main @ 642e618`；M1 阶段提交 `f2baf27` 已推送为 `origin/feat/m1-project-baseline` 并开 PR #1（DCO 与 `repository-quality` 通过，可合并）。本分支自 `f2baf27` 切出，工作区仅含本次 A 规划改动。
- **远端**：`sha_pinning_required=true`；Actions 白名单仅 `actions/checkout@*`、`actions/setup-python@*`（`github_owned_allowed=false`）。CI 中安装 Flutter **不得**引入新的 Action，改用官方归档下载 + SHA-256 校验或固定标签的官方 Git 仓库。
- **宿主工具链**：已就绪 `git 2.56`、`gh 2.103`、`winget 1.29`、Python 3.12、VS Build Tools（MSVC x64、CMake、Windows 11 SDK）、WebView2，以及 **Inno Setup 7.1.1**（按用户安装于 `%LOCALAPPDATA%\Programs\Inno Setup 7`，`ISCC.exe` 可用）。**Flutter 3.50.0 stable（Dart 3.14.0）**已于 2026-11-22 按 `S2-01` 安装到用户目录 `%LOCALAPPDATA%\Programs\flutter`（官方归档 SHA-256 一致，用户 `PATH` 已加入 `bin`，分析上报与 CLI 动画已关闭），`flutter doctor` 的 Flutter、Windows、Visual Studio（生成工具 2026，Windows SDK 10.0.26100）项通过；Windows 开发者模式已开启（插件构建所需符号链接）；用户级 `NO_PROXY=localhost,127.0.0.1,::1` 已设置（宿主有 `HTTP_PROXY`）。未使用 `fvm` 等版本管理器，版本以 `.flutter-version` 为准。
- **本机已有开发版**：同机已有其他项目的按用户开发版安装（各自独立卸载键），本阶段只认 `io.github.chialecode.blink-dev_is1` 等 BLINK 自有身份；`blink-dev` 尚未安装，故 B 交付时 `--install` 预期为“跳过：未安装”，由用户按 [H-002](../../USER-ACTIONS.md#h-002) 首次手动安装。
- **本机参考**：本机参考索引尚未建立（`reference/blink/` 只有 `PROPOSALS.md`），A 已按用户点名查阅本机同类项目的“Windows 安装身份与生命周期”“按用户安装包与覆盖升级演练”“开发版本机更新与脱离作业对象启动”“两级门禁与依赖盘点”四个功能领域，结论已写入[架构 §4.3](../design/architecture.md#desktop-lifecycle)与[工程规则 §2.2](../dev-rules/engineering.md#dev-install)。B 如需对照细节，按[本机参考索引规则](../dev-rules/workflow.md#local-reference)查阅同目录提议，仓库内不写项目名。

## 3. 开源查证与技术定案（2026-11-22 查询）

依据 pub.dev API、Flutter 官方发布清单与上游 GitHub 发布页；均为宽松许可，均已满 7 天冷却（Flutter 3.50.1 于 2026-11-20 发布，未满 7 天，本阶段锁 3.50.0；B 开工时若 3.50.1 已满 7 天且无回退报告，可在 `deps.py` 盘点后升级并记录）。

| 定案 | 组件与版本 | 许可 | 发布日期 | 用法与边界 |
| --- | --- | --- | --- | --- |
| `S2-01` | Flutter `3.50.0` stable（Dart `3.14.0`），Windows 归档 `flutter_windows_3.50.0-stable.zip`，SHA-256 `35fb843409c80a1c69b64bbae1756bba437222f909622d83540e266e1759aab8` | BSD-3-Clause | 2026-11-11 | 安装到用户目录（不需管理员），校验 SHA-256 后加入用户 `PATH`；关闭分析上报与 CLI 动画；`.flutter-version` 记录版本，`check.py` 核对 `flutter --version` |
| `S2-02` | `window_manager 0.7.0` | MIT | 2026-11-12 | 窗口显示/隐藏/聚焦、关闭拦截、最小尺寸 `760×560`、跳过任务栏 |
| `S2-03` | `tray_manager 0.9.0` | MIT | 2026-11-12 | 托盘图标、左键与右键菜单（打开 / 退出）；资源管理器重启后重新添加（若库未处理，B 监听 `TaskbarCreated` 补齐） |
| `S2-04` | `win32 6.4.0` + `ffi 2.2.0` | BSD-3-Clause | 2026-08-05 / 2026-02-11 | 命名互斥量、命名管道服务端/客户端（`PIPE_REJECT_REMOTE_CLIENTS`、仅当前用户的安全描述符）、`IsProcessInJob` 等；**自行实现**单实例与控制管道，不用现成单实例插件（现成插件无应答回执、无法与安装器 `AppMutex` 统一命名） |
| `S2-05` | `flutter_lints 6.0.0` | BSD-3-Clause | 2025-05-27 | 开发依赖；`flutter analyze --fatal-infos` 零告警 |
| `S2-06` | Inno Setup `7.1.1`（宿主已装） | Inno Setup License（宽松，允许商业使用，构建期工具，不随产品分发） | 2026-10-28 | `.iss` 内用 ISPP `Ver` 拒绝 7.1.x 以外的编译器；`PrivilegesRequired=lowest`、`DefaultDirName={userpf}\<身份>`、`AppMutex=<身份>-instance`、开始菜单快捷方式写入 AUMID、可选桌面图标默认不勾选；卸载保留数据根。未采用：MSIX（需签名证书）、NSIS（同等能力但需另写静默升级钩子，且本机同类项目已验证 Inno 路线） |
| `S2-07` | Python 3.12 标准库 | PSF | — | `scripts/{package,check,deps}.py` 与测试，仅为仓库工具，不进入产品；Windows 专用部分用 `winreg` / `ctypes`，非 Windows 上对应命令记 `not-run` |

依赖盘点（`deps.py`）：查 pub.dev API 的发布时间判定 7 天冷却，按 `pubspec.lock` 向 OSV（`ecosystem: Pub`）批量查询漏洞，核对 `.flutter-version` 与 Flutter 官方发布清单、`ci.yml` 中 Action SHA 与标签；联网失败记 `not-run` 不伪造通过；例外写入 `scripts/deps-exceptions.json`（带 `reviewBy`）。

## 4. 目录与文件所有权

| 路径 | 内容 |
| --- | --- |
| `pubspec.yaml`（根） | Dart Workspace：`workspace: [apps/blink_client]`，`environment.sdk: ^3.14.0` |
| `.flutter-version` | `3.50.0` |
| `apps/blink_client/` | `flutter create --platforms=windows,macos,linux,android,ios --org io.github.chialecode --project-name blink_client`；`lib/main.dart`、`lib/app/`（外壳与“关于”/设置）、`lib/platform/`（`build_info.dart` 读取编译期常量、`paths.dart` 数据根、`windows/single_instance.dart`、`windows/control_pipe.dart`、`tray.dart`、`lifecycle.dart`）；`test/`；`windows/packaging/blink.iss`；`windows/runner/` 中版本资源与通道图标改为由构建参数注入 |
| `assets/icons/` 或 `apps/blink_client/windows/runner/resources/` | 正式版图标与带 `DEV` 徽标的开发版图标（`.ico`，多尺寸），由脚本或手工生成的原创图形，不使用第三方图标 |
| `scripts/package.py`、`scripts/check.py`、`scripts/deps.py`、`scripts/deps-exceptions.json`、`scripts/test_package.py`、`scripts/test_check.py`、`scripts/test_deps.py` | 打包与本机更新、两级门禁、依赖盘点及其单元测试（零第三方依赖） |
| `.github/workflows/ci.yml`、`.github/dependabot.yml` | CI 增加固定版本 Flutter 与 `check.py --ci`；Dependabot 增加 `pub`（根目录 workspace，按月，7 天冷却，分组） |
| `dist/<通道>/`、`artifacts/package/` | 生成物（Git 忽略），每类只保留最新一份 |

<a id="work-packages"></a>
## 5. 工作包与执行顺序

顺序：`M2-W01 → M2-W02 → M2-W03 → M2-W04 → M2-W05 → M2-W06 → M2-W07`；W06 的 `check.py` 可在 W02 后先搭骨架，随工作包补齐。

| 工作包 | 预期行为与关键失败路径 | 完成证据 |
| --- | --- | --- |
| **M2-W01** 阶段整理、工具链与依赖盘点 | 四向整理：`docs/delivery/stage-report.md` 改为 M2 报告（M1 报告保留于 PR #1 与提交 `f2baf27`，不复制）；剥离长期正本中已过期的“M1 修订 3”类标签。核对宿主已装 Flutter 3.50.0（`flutter --version`；若缺失则按 `S2-01` 安装，SHA-256 不符即中止，不改用其他来源）；`flutter doctor` 中 Windows 桌面项通过（Android / Xcode 缺失记为与本阶段无关）。实现 `deps.py`（冷却、OSV、Flutter 版本、Action SHA）；Dependabot 增加 `pub`；检查待处理 Dependabot PR（当前预期为无） | `M2-K01`；`artifacts/audit/deps.json` |
| **M2-W02** Flutter 工作区与桌面外壳 | 根 workspace 与 `apps/blink_client`；编译期常量 `BLINK_CHANNEL`（缺省 `blink-dev`）、`BLINK_IDENTITY`（缺省为空 = 源码构建）、`BLINK_VERSION`、`BLINK_GIT_SHA`；数据根按身份解析（`BLINK_DATA_DIR` 覆盖，用于测试）；主窗口：产品名占位页、“关于”（版本/通道/身份/提交短哈希）、设置“关闭按钮：隐藏到托盘 / 直接退出”（原子写 `settings/desktop.json`，损坏时改名保留并回到默认）；最小窗口 `760×560`；源码构建不注册单实例与管道 | `M2-K02`；`flutter test` |
| **M2-W03** 单实例、控制管道、托盘与生命周期 | 按[架构 §4.3](../design/architecture.md#desktop-lifecycle)：互斥量 `<身份>-instance`；第二实例转交参数后退出；管道协议（`focus` / `quit-for-update` / `ping`，`busy` / `unknown_command`，超长或非法 JSON 拒绝不崩溃）；管道服务在独立 Isolate；托盘菜单与关闭隐藏；`--background` 只托盘、不抢焦点、托盘失败回退最小化；保存后退出序列写 `run/lifecycle.json`；`BLINK_QUIET=1` 不建窗口与托盘。纯逻辑（参数解析、协议编解码、生命周期状态机）与 Win32 调用分层，前者全单测，后者由 W05 冒烟覆盖 | `M2-K03`～`M2-K05` |
| **M2-W04** 版本注入与 Inno Setup 安装包 | `package.py --channel blink-dev\|blink`（缺省 `blink-dev`）：计算版本（开发 `0.1.0-dev.<UTC 年月日时分>`；正式 `0.1.<n>` 由参数 `--version` 给出，缺省拒绝）→ 注入通道图标与版本资源 → `flutter build windows --release --dart-define=...` → 产物改名为 `<身份>.exe` → ISCC 编译 `blink.iss`（身份、版本、AppId 由 `/D` 传入）→ 写 `dist/<通道>/<身份>-setup-<版本>.exe`、`SHA256SUMS.txt`、`build-info.json`（版本、通道、身份、提交、Flutter 版本、产物哈希），先写临时目录校验后原子替换，旧包只留最新一份。工作区有未提交改动时版本带 `+dirty` 并在回执标明。ISCC 或 Flutter 缺失时明确报错退出 | `M2-K06` |
| **M2-W05** 本机开发版自动更新与安装演练 | `package.py --install`：严格按[工程规则 §2.2](../dev-rules/engineering.md#dev-install)五步（卸载项判断、`--quit-for-update` 与 30 秒等待、`/VERYSILENT` 安装与版本双核对、经 `explorer.exe` 外壳以 `--background` 拉起或脱离作业对象、回执）；`BLINK_DEV_AUTO_INSTALL=0` / `CI=true` 跳过。所有判断经可注入接口（注册表、进程、管道、安装器、启动器）以单测覆盖。`package.py --rehearsal`：用 `blink-dev-test` 身份构建 A、B 两个版本 → 安装 A 到临时目录 → 安静模式 `--background` 启动并 `ping` → 运行中安装 B（经 `quit-for-update`）→ 核对版本与 `lifecycle.json` → 启动后 `ping` → 结束并卸载 → 比对演练前后真实 `blink` / `blink-dev` 卸载项、开始菜单 BLINK 快捷方式、`%LOCALAPPDATA%\blink*` 目录快照一致；结果写 `artifacts/package/rehearsal.json`。演练卸载失败时打印残留清单并以非零退出，不手工删除非本次创建的条目 | `M2-K07`、`M2-K08` |
| **M2-W06** 两级门禁与 CI | `check.py --quick`：`check_docs.py`、`git diff --check`、Python 单测（`scripts/test_*.py`）、`dart format --output=none --set-exit-if-changed`、`flutter analyze --fatal-infos`、`flutter test`、`.flutter-version` 核对。完整（无参数）：在 quick 之上加 `deps.py --audit`、Windows 上 `package.py --channel blink-dev`、`--channel blink --version 0.1.0`（只打包不安装）与 `--rehearsal`；非 Windows 记 `not-run`。`--ci`：Linux 上的 quick 子集。CI：在 `ubuntu-24.04` 上按 `.flutter-version` 下载官方 Linux 归档并核对 SHA-256（哈希写在仓库内、由 `deps.py` 维护），运行 `python scripts/check.py --ci`；job 名仍为 `repository-quality`，`timeout-minutes` ≤ 15，不新增 Action。`.githooks/pre-push` 改为调用 `check.py --quick` | `M2-K09`；PR 上 `repository-quality` 结果（推送授权后） |
| **M2-W07** 正本同步与交付 | 更新[工程规则](../dev-rules/engineering.md#commands)命令状态、[架构 §4.3](../design/architecture.md#desktop-lifecycle)中实现与计划不一致之处、[状态页](status.md#current)、[阶段报告](stage-report.md#b-delivery)、USER-ACTIONS（`ACT-004`、`H-002` 适用版本）、CHANGELOG `Unreleased`；跑完整门禁；执行 `package.py --install`（预期“未安装→跳过”并在报告写明安装包路径供 H-002） | `M2-K10` |

## 6. 安静验证要求

- 所有测试与冒烟用测试身份与 `BLINK_DATA_DIR` 临时目录、`BLINK_QUIET=1`；不打开主窗口、不创建托盘图标、不抢焦点、不弹系统对话框；控制管道只在本机；演练不创建桌面快捷方式（`/MERGETASKS=!desktopicon`），开始菜单项随卸载清除并在快照比对中核实。
- 单轮快速门禁预算约 5～10 分钟；完整门禁中的 Windows 构建与演练预计 10～20 分钟，属阶段交付必跑，不另请授权；若超过 30 分钟，B 先优化（复用同一次 `flutter build` 产出 A、B 两个安装包，只改版本资源与安装器参数）再继续。
- 结果只用 `passed` / `failed` / `blocked` / `not-run`；macOS、Linux、移动端构建统一记 `not-run`。

<a id="cases"></a>
## 7. 必测用例（M2-K01～M2-K10）

| 编号 | 场景与断言 | 工作包 |
| --- | --- | --- |
| `M2-K01` | **工具链与依赖**：`flutter --version` 等于 `.flutter-version`；`pubspec.lock` 中直接依赖版本等于第 3 节定案或经 `deps.py` 记录的升级；`deps.py --audit` 输出冷却判定与 OSV 结果（无未登记漏洞）；断网时记 `not-run` 退出码非 0 | W01 |
| `M2-K02` | **编译期信息与数据根**：不同 `--dart-define` 组合下“关于”显示正确；源码构建不创建互斥量与管道；`BLINK_DATA_DIR` 生效；损坏的 `desktop.json` 被改名保留并回到默认 | W02 |
| `M2-K03` | **参数与协议**：`--background`、`--quit-for-update`、无参数的解析；管道请求/应答编解码；非法 JSON、超长行、未知命令返回错误不崩溃 | W03 |
| `M2-K04` | **生命周期状态机**：托盘退出、关闭设为退出、`quit-for-update` 走同一序列并写 `lifecycle.json`（原子写）；关闭默认隐藏到托盘；`--background` 托盘失败回退最小化；忙碌时 `quit-for-update` 回执 `busy` | W03 |
| `M2-K05` | **Windows 单实例冒烟**（安静模式、测试身份）：首个实例启动后第二个实例转交 `focus` 并退出；`ping` 应答；`--quit-for-update` 使首个实例在 5 秒内退出；无运行实例时 `--quit-for-update` 立即以 0 退出 | W03、W05 |
| `M2-K06` | **安装包产物**：两个通道各产出安装包、`SHA256SUMS.txt`、`build-info.json`；`.exe` 的 `ProductVersion` 等于版本字符串；`.iss` 用非 7.1.x 编译器时编译失败；旧包只留最新一份 | W04 |
| `M2-K07` | **`--install` 判断逻辑单测**：未安装跳过；未运行直接装并托盘拉起；运行中退出后重开；30 秒不退出放弃且不强杀；`busy`；安装失败非零退出；版本不符非零退出；仍在作业对象里记 `inJob=true`；`BLINK_DEV_AUTO_INSTALL=0` 与 `CI=true` 跳过；正式版与测试身份卸载项从不被读取或修改 | W05 |
| `M2-K08` | **测试身份安装演练**：A 安装 → 启动 → 运行中升级到 B → 版本双核对 → `--background` 重启 → 卸载 → 真实安装快照前后一致（`AC-11`） | W05 |
| `M2-K09` | **门禁与 CI**：`check.py --quick` 在本机通过；对格式错误、分析告警、失败测试、`.flutter-version` 不符的隔离反例返回非零；CI 在 Linux 下载的 Flutter 归档 SHA-256 不符时失败 | W06 |
| `M2-K10` | **正本一致**：`check_docs.py` 通过；命令表状态、架构 §4.3、状态页、报告、USER-ACTIONS 与实现一致；本阶段长期正本不新增阶段标签 | W07 |

## 8. MVP 与 LOOP

- 本阶段是 MVP 的工程前置：后续每个阶段需要人工检查时都依赖它把最新版本送到用户桌面。必须贯通的是“构建 → 安装包 → 本机开发版自动更新 → 托盘常驻”与测试身份演练。
- 可延后记入[状态页 LOOP](status.md#loop)的：安装器界面美化、安装包体积优化、增量/差分更新、托盘菜单扩展（如“检查更新”“打开数据目录”）、开机自启。正式版联网更新、代码签名与 macOS / Linux 安装包按 [Q-008](../../USER-ACTIONS.md#q-008) 属于后续阶段范围，不是 LOOP。

<a id="prompt"></a>
## 9. 给 Agent B 的交接 Prompt

```text
你是 BLINK 的 Agent B，动作：连续实施 M2（Windows 桌面骨架、打包与开发版自动安装更新），计划 BLINK-M2-01 修订 1。

- 先读：AGENTS.md；docs/delivery/stage-plan.md（本计划，含定案版本与 M2-K01～K10）；docs/design/architecture.md §4.3（安装身份与生命周期契约）；docs/dev-rules/engineering.md §2.1、§2.2（双通道路径、本机开发版自动安装五步）与 §3（门禁、安静测试）；docs/decisions.md DEC-027；USER-ACTIONS.md Q-008、H-002。
- 分支 feat/m2-desktop-packaging（基于 M1 阶段提交 f2baf27）。全部改动收敛为单个 DCO 提交 feat(m2): ...（git commit --amend -s）；若 PR #1 已合并，交付前变基到新 main。
- 范围：按 M2-W01～W07 顺序连续完成，不逐包请示。宿主已装 Flutter 3.50.0（用户 PATH，开发者模式已开），先用 flutter --version 与 flutter doctor 核对；若当前 shell 找不到 flutter，用 %LOCALAPPDATA%\Programs\flutter\bin 下的完整路径，不要重装。单实例与控制管道用 win32 自行实现；托盘 tray_manager 0.9.0、窗口 window_manager 0.7.0；安装包 Inno Setup 7.1.1 按用户安装；脚本只用 Python 标准库。非阻塞取舍按 Q-008 默认值，新增的可逆取舍登记为新的 Q-*。
- 安静与隔离：测试与演练只用测试身份 blink-test / blink-dev-test、BLINK_DATA_DIR 临时目录、BLINK_QUIET=1；绝不读写正式版 blink 的安装、卸载项与数据；不强杀用户进程；演练后真实安装快照必须前后一致。
- 验证：python scripts/check.py（完整门禁，含 Windows 打包与 --rehearsal）、python scripts/check.py --quick、python -B scripts/check_docs.py、git diff --check；最后执行 python scripts/package.py --install（本机未装 blink-dev 时应如实跳过，并在报告写出供 H-002 首次手动安装的安装包路径）。缺环境的项记 not-run，不靠删减测试制造通过。
- 未授权严禁：git push、创建/更新/合并 PR、打标签、发布、修改远端设置。交付时在 USER-ACTIONS 新增 ACT-004（推送本分支并创建 PR #2）。
- 交付：按 docs/templates/agent-handoff.md 第 2 部分写 docs/delivery/stage-report.md#b-delivery，更新状态页与正本；回复中给出提交 SHA、验证摘要、安装包路径与给 Agent A 的集中审查 prompt。
```
