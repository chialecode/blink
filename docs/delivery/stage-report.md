# 阶段报告：M2（Windows 桌面骨架、打包与开发版自动安装更新）

计划：[BLINK-M2-01](stage-plan.md#scope)（修订 1，2026-11-22）。本报告按[交接模板](../templates/agent-handoff.md)记录 M2 实现交付证据、工作包与必测用例对账、阶段开始四向整理、7 天冷却与 OSV 依赖审计、安装演练与回执，以及给 Agent A 的集中审查 prompt（M1 完整交付报告保留于 PR #1 与提交 `f2baf27`，不另建副本）。

<a id="b-delivery"></a>
## 1. B 交付记录（2026-11-22）

| 信息 | 内容 |
| --- | --- |
| 执行范围与对账 | 按 `BLINK-M2-01`（修订 1）完整交付 `M2-W01`～`M2-W07` 与必测用例 `M2-K01`～`M2-K10`，未缩减任何验收标准、安静测试纪律或安全边界。沿用 [Q-008](../../USER-ACTIONS.md#q-008) 推荐默认（仅 Windows、双通道均产出按用户安装包且仅开发版本机自动更新、暂不代码签名），未新增阻塞项或新 `Q-*`。因 Flutter `3.50.0` 已正式弃用 `flutter/material.dart`，`apps/blink_client` 引入官方维护依赖 **`material_ui 1.11.0`**（pub.dev 认证发布者 `flutter.dev`、`BSD-3-Clause` 许可、发布于 `2026-11-09T20:10:36Z`，满 7 天冷却期），并同步通过 `deps.py --audit` 与 OSV 审计 |
| 版本与工作区 | 分支 `feat/m2-desktop-packaging`，基于 M1 阶段提交 `f2baf27`（PR #1 `repository-quality` 已通过、仍待 [ACT-002](../../USER-ACTIONS.md#act-002) 合并，故尚未变基至新 `main`；待 PR #1 合并后变基）。本阶段规划、实现、文档同步与审查前修复收敛为该分支上的单个 DCO 签名提交 `feat(m2): ...`；按[交接模板 §2](../templates/agent-handoff.md)，**最终收敛提交 SHA 与提交后基于干净工作区（`dirty: false`）复跑产出的最终安装包文件名及 SHA-256 摘要，以 Agent B 交付回复及 `dist/<通道>/{build-info.json,SHA256SUMS.txt}` 为准**（不为写入提交 SHA 反复 amend）。未执行任何远端推送、PR 创建或合并操作，推送与创建 PR #2 等待 [ACT-004](../../USER-ACTIONS.md#act-004) 授权 |
| 可运行产物、本机更新与环境 | 宿主机：Windows 11 x64，Flutter `3.50.0` stable（rev `ab2912035e`，Dart `3.14.0`，位于 `%LOCALAPPDATA%\Programs\flutter`，Windows 开发者模式已开），Visual Studio Build Tools 2026（MSVC x64、CMake、Windows SDK `10.0.26100.0`），Inno Setup `7.1.1`（`%LOCALAPPDATA%\Programs\Inno Setup 7\ISCC.exe`），Python `3.12.16` 标准库。交付前独立复验产物（提交前工作区含 `+dirty`，已通过 PE `ProductVersion` 与独立 SHA-256 核对，每通道仅留最新一份）：`dist/blink-dev/blink-dev-setup-0.1.0-dev.202611221708+dirty.exe`（`10,690,525` B，SHA-256 `5d760d710eef72c657e68efa4517aa21a3f7572d336a69c5c212980923d9df24`）、`dist/blink/blink-setup-0.1.0+dirty.exe`（`10,705,803` B，SHA-256 `47c8730f6b8eaff778c2a51f39c59173000c6b60666c75101b1e88ff65f1c9f2`），均配套 `SHA256SUMS.txt` 与 `build-info.json`（干净提交后将复跑无 `+dirty` 终版包，精确文件名与校验和在交付回复中提供给 [H-002](../../USER-ACTIONS.md#h-002)）。执行 `python -B scripts/package.py --install` 因本机尚未安装 `blink-dev` 如实跳过（退出码 `0`，`artifacts/package/install-dev.json` 记 `status: "skipped"`、`reason: "not_installed"` 并给出 `dist/blink-dev/` 安装包路径）。macOS / Linux / Android / iOS 构建与安装包为 `not-run` |
| 契约、整理与审查前自修 | 桌面安装身份与生命周期契约已同步至[系统架构 §4.3](../design/architecture.md#desktop-lifecycle)（补充 `--quit-for-update` 退出码 `0/2/1`、`--background` 二次启动静默退出 `0`、`invalid_request` 错码、`lifecycle.json` 精确字段及 `TaskbarCreated` MethodChannel）。`scripts/check_docs.py` 豁免 Flutter Git 忽略的 `flutter/ephemeral`、`.symlinks`、`.plugin_symlinks` 与 `flutter_export_environment.sh` 同时保持全部受控文本严格卫生校验（新增 2 条回归用例，共 30 条）。交付前独立复审共定位并闭环修复 3 项局部隐患：① `control_pipe.dart`（6 处）与 `scripts/package.py`（2 处）在 `CancelIoEx` 后统一执行 `GetOverlappedResult(..., true)` 排空异步重叠 I/O，防止内核向已释放/复用缓冲区回写；② `main.dart` 在 `ControlPipeServer.start` 失败时清理已创建的托盘图标与窗口后释放互斥量；③ `scripts/check.py`、`scripts/deps.py` 与 `scripts/test_check.py` 在 Windows 侧统一传入 `CREATE_NO_WINDOW` 避免子进程闪烁控制台窗口。四向整理与依赖盘点见 §2、§3 |

工作包与必测用例对账：

| 工作包 / 用例 | 实现位置 | 实际验证命令与证据 | 状态与限制 |
| --- | --- | --- | --- |
| `M2-W01` 阶段整理、工具链与依赖盘点（`M2-K01`） | `.flutter-version`（`3.50.0`）、`pubspec.yaml`、`pubspec.lock`、`scripts/flutter-checksums.json`、`scripts/deps.py`、`scripts/deps-exceptions.json`、`scripts/test_deps.py`、`.github/dependabot.yml`；阶段整理同步于 `README.md`、`docs/README.md`、`docs/requirements.md`、`docs/dev-rules/engineering.md`、`docs/design/architecture.md`、`docs/delivery/roadmap.md` | 核对 `%LOCALAPPDATA%\Programs\flutter\bin\flutter.bat --version`（`3.50.0` / Dart `3.14.0`）与 `flutter doctor`（Flutter/Windows/VS Build Tools 2026 通过）；`gh pr list --state open` 确认 `0` 个待处理 Dependabot PR；`python -B scripts/deps.py --audit`（`rc=0`，`artifacts/audit/deps.json`：`status=passed`，Windows/Linux 校验和一致、6 个直接依赖冷却判定准确、OSV 47 包 0 漏洞、2 个 Action SHA 与白名单一致）；`python -B scripts/test_deps.py`（`11/11 PASS`，含断网 `not-run` 退出码 `2`） | `passed`（Android SDK 缺失与本阶段无关） |
| `M2-W02` Flutter 工作区与桌面外壳（`M2-K02`） | `apps/blink_client/pubspec.yaml`、`apps/blink_client/lib/main.dart`、`apps/blink_client/lib/app/blink_app.dart`、`apps/blink_client/lib/platform/{build_info,paths,atomic_io,desktop_settings}.dart`、`apps/blink_client/windows/runner/{blink_version.h.in,CMakeLists.txt,Runner.rc,main.cpp,win32_window.cpp,flutter_window.h,flutter_window.cpp}`、原创多尺寸 `.ico`（`windows/runner/resources/{blink,blink-dev,app_icon}.ico` 与 `assets/icons/{blink,blink-dev}.ico`）；`apps/blink_client/test/{build_info_and_paths_test,widget_test}.dart` | `dart format --output=none --set-exit-if-changed .`（`rc=0`）；`flutter analyze --fatal-infos`（`rc=0`，0 告警）；`flutter test`（`33/33 PASS`，覆盖不同 `--dart-define` 组合“关于”展示、源码构建不注册互斥量/管道、`BLINK_DATA_DIR` 覆盖、损坏 `desktop.json` 改名保留并回退默认、`760×560` 最小尺寸）；连续两次更换 `BLINK_PRODUCT_VERSION` 构建验证 PE 版本资源实时更新且零脏工作区 | `passed` |
| `M2-W03` 单实例、控制管道、托盘与生命周期（`M2-K03`～`M2-K05`） | `apps/blink_client/lib/platform/{cli_args,control_protocol,lifecycle,window_adapter,tray}.dart`、`apps/blink_client/lib/platform/windows/{win32_bindings,single_instance,control_pipe}.dart`；`apps/blink_client/test/{cli_and_protocol_test,lifecycle_test,windows_ipc_test}.dart` | `flutter test`（`33/33 PASS`）：`M2-K03` 覆盖参数解析、协议编解码、4096 字节超长行、非法 UTF-8/JSON、未知命令及真实 Win32 命名管道 Isolate + 当前用户受保护 DACL `D:P(A;;GA;;;<sid>)` + `FILE_FLAG_FIRST_PIPE_INSTANCE` + `PIPE_REJECT_REMOTE_CLIENTS` 测试；`M2-K04` 覆盖共享退出序列、原子 `run/lifecycle.json`、默认关闭隐藏、托盘失败最小化回退、`busy` 与 `TaskbarCreated`；`M2-K05` 由安静真实进程冒烟及 `rehearsal.json` 覆盖（无实例 `--quit-for-update` `0.422s` `rc=0`、`ping` 返回 `{"ok":true}`、第二实例转交 `focus`、`--quit-for-update` `0.468s` 内退出并写 `lifecycle.json`） | `passed` |
| `M2-W04` 版本注入与 Inno Setup 安装包（`M2-K06`） | `apps/blink_client/windows/packaging/blink.iss`、`scripts/package.py`、`scripts/test_package.py` | `python -B scripts/package.py --channel blink-dev` 与 `--channel blink --version 0.1.0`（均经完整门禁 `check.py` 实跑，`rc=0`），各通道产出安装包、`SHA256SUMS.txt`、`build-info.json` 且旧包原子替换仅留最新一份，Win32 `GetFileVersionInfoW` 核验 PE `ProductVersion` 与独立 SHA-256 均一致；`python -B scripts/test_package.py` 实测调用 `ISCC.exe` 验证非 7.1.x 编译器版本（`7.0.9`、`7.2.0`、`6.4.0`）被 ISPP `Ver` 拒绝 | `passed` |
| `M2-W05` 本机开发版自动更新与安装演练（`M2-K07`、`M2-K08`、`AC-11`） | `scripts/package.py`（`--install` 五步逻辑与可注入 `DevInstallDeps`、`--rehearsal` 隔离升级演练）、`scripts/test_package.py` | `M2-K07`：`python -B scripts/test_package.py`（`28/28 PASS`，覆盖未安装跳过、未运行直接装并托盘拉起、运行中退出重开、30 秒超时放弃且不强杀、`busy`、安装失败、注册表/PE 版本不符、作业对象脱离回退链与 `inJob=true`、`BLINK_DEV_AUTO_INSTALL=0`、`CI=true`、非 Windows `not-run`、正式版与测试身份卸载键永不读写）；实跑 `python -B scripts/package.py --install` 如实返回 `rc=0`、`status: "skipped"`、`reason: "not_installed"`（`artifacts/package/install-dev.json`）。`M2-K08`：`python -B scripts/package.py --rehearsal`（`rc=0`，`artifacts/package/rehearsal.json`：`blink-dev-test` `0.1.0-dev.202611221707.1+dirty` → `.2+dirty` 全流程通过，`userDataPreserved: true`、`residue: []`、`snapshot_match: true`），且复核宿主机全部 BLINK 卸载键、`%LOCALAPPDATA%\blink*`、开始菜单与桌面与开工基线 100% 一致 | `passed`（自动化闭环与演练全部通过；本机真实 `blink-dev` 首次安装待 [H-002](../../USER-ACTIONS.md#h-002) `not-run`） |
| `M2-W06` 两级门禁与 CI（`M2-K09`） | `scripts/check.py`、`scripts/test_check.py`、`scripts/check_docs.py`、`scripts/test_check_docs.py`、`.github/workflows/ci.yml`、`.githooks/pre-push` | 完整门禁 `python -B scripts/check.py`（`11/11 PASS`：`docs` `0.53s`、`git-diff` `0.16s`、`flutter-version` `1.67s`、`python-tests` `28.69s` [共 82 条：`test_check.py` 13、`test_check_docs.py` 30、`test_deps.py` 11、`test_package.py` 28]、`dart-format` `1.08s`、`flutter-analyze` `13.91s`、`flutter-test` `8.81s` [33/33]、`deps-audit` `27.91s`、`package-dev` `51.25s`、`package-release` `51.42s`、`package-rehearsal` `109.05s`）；快速门禁 `python -B scripts/check.py --quick`（`7/7 PASS`，`54.29s`）；`test_check.py` 覆盖真实隔离反例（格式错误、分析告警、测试失败、`.flutter-version` 不符、Linux Flutter `.tar.xz` SHA-256 校验失败）；核对 `ci.yml` 仅用白名单 40 位 SHA Action 且 `timeout-minutes: 15` | `passed`（本地全部通过；GitHub Actions 云端运行待 [ACT-004](../../USER-ACTIONS.md#act-004) `not-run`） |
| `M2-W07` 正本同步与交付（`M2-K10`） | `docs/dev-rules/engineering.md`、`docs/design/architecture.md`、`docs/requirements.md`、`docs/delivery/roadmap.md`、`docs/delivery/status.md`、`docs/delivery/stage-report.md`、`USER-ACTIONS.md`、`CHANGELOG.md`、`README.md`、`docs/README.md` | `python -B scripts/check_docs.py`（`rc=0`，28 份 Markdown 全过布局、链接、锚点、UTF-8 无 BOM、LF、零本机路径/密钥/参考名）与 `git diff --check`（`rc=0`）；核对长期正本零新增旧阶段标签、命令状态与架构 §4.3 同实际代码一致 | `passed` |

## 2. 阶段开始四向整理记录（M2-W01）

按[阶段整理规则](../dev-rules/workflow.md#stage-cleanup)在开工时对全仓受跟踪文档与工作区执行四向盘点：

| 处置类别 | 目标范围 | 处置结论与依据 |
| --- | --- | --- |
| **原样保留** | `docs/decisions.md`（`DEC-001`～`DEC-026` 历史原文与 `DEC-027`）、`docs/research/2026-11-20-stack.md`、`docs/research/2026-11-22-pure-dart-pivot.md`、`docs/ui.md`、`docs/design/{data-and-sync,agent-and-reader}.md`、`docs/dev-rules/{workflow,sources-and-safety}.md`、`docs/templates/agent-handoff.md`、`AGENTS.md`、`CLAUDE.md`、`CONTRIBUTING.md`、`REVIEW.md`、`SECURITY.md` | 遵 `DEC-027` 保留历史决定原文与带日期选型归档；逐篇扫描确认其余长期正本无过期 M1 修订或阶段标签，未来阶段引用均已顺延至 `M1`～`M7` |
| **精炼压缩（剥离过期标签）** | `README.md`、`docs/README.md`、`docs/requirements.md`、`docs/dev-rules/engineering.md`、`docs/design/architecture.md`、`docs/delivery/roadmap.md` | 剥离 `README.md` 过期的 `M1 基线阶段（修订 3 纯 Dart 架构收敛）`、剥离 `engineering.md`（6 处）与 `architecture.md`（2 处）过期 `M1` / `（M1）` 标签、剥离 `requirements.md` `NFR-DEV-003` 状态列阶段后缀、更新 `docs/README.md` 与 `requirements.md` 决定范围至 `DEC-027`、更新 `roadmap.md` `AC-01` 过期状态表述 |
| **提炼入正本后覆写** | `docs/delivery/stage-report.md` | M1 有效结论已沉淀至 `status.md`、`decisions.md` 与 `USER-ACTIONS.md`，M1 完整报告由 PR #1 与提交 `f2baf27` 归档，本文件直接覆写为 M2 交付报告，不新建阶段后缀副本 |
| **直接删除** | 无 | 文档树与根级 Markdown 零多余草稿或临时文件；`dist/<通道>/` 与 `artifacts/<类别>/` 由 `package.py`、`deps.py` 原子替换保持每类最新单份 |

## 3. 依赖盘点、7 天冷却与漏洞审计结果（M2-W01 / M2-K01）

- **Dependabot PR 盘点**：2026-11-22 运行 `gh pr list --state open`，远端仅见 M1 的 PR #1，`0` 个待处理 Dependabot PR。`.github/dependabot.yml` 已新增根目录工作区 `pub` 生态（每月巡检、7 天冷却、`rebase-strategy: disabled`、分组 `pub`）。
- **工具链与校验和核对**（`python -B scripts/deps.py --audit` → `artifacts/audit/deps.json`，`2026-11-22T17:04:49Z`，`status: "passed"`）：
  - **Flutter / Dart**：锁定 `.flutter-version = 3.50.0`（Dart `3.14.0`），`scripts/flutter-checksums.json` 中 Windows（`35fb843409c80a1c69b64bbae1756bba437222f909622d83540e266e1759aab8`）与 Linux（`6ea2d806fd57269ae783e6788e2a81fc26eaad782f1e0d0ff38623bb765ff9f5`）官方归档校验和与官方发布清单 100% 匹配；上游最新稳定版 `3.50.1` 发布于 `2026-11-20T00:24:27Z`（`2.69` 天，`cooling-down`），按 7 天冷却规则保持 `3.50.0`。
  - **直接依赖（6 项，均为宽松许可、零 GPL/AGPL）**：
    - `ffi 2.2.0`（BSD-3-Clause，2026-02-11，`up-to-date`）
    - `win32 6.4.0`（BSD-3-Clause，2026-08-05，`up-to-date`）
    - `flutter_lints 6.0.0`（dev，BSD-3-Clause，2025-05-27，`up-to-date`）
    - `material_ui 1.11.0`（BSD-3-Clause，pub.dev 认证发布者 `flutter.dev`，2026-11-09 满 7 天冷却；因 Flutter 3.50 弃用 `flutter/material.dart` 引入；最新 `1.11.1` 发布于 2026-11-16、`6.01` 天 `cooling-down`）
    - `tray_manager 0.9.0`（MIT，2026-11-12 满 7 天冷却；最新 `0.9.1` 发布于 2026-11-22、`0.09` 天 `cooling-down`）
    - `window_manager 0.7.0`（MIT，2026-11-12 满 7 天冷却；最新 `0.7.1` 发布于 2026-11-22、`0.09` 天 `cooling-down`）
  - **OSV 漏洞审计**：批量查询 `pubspec.lock` 全部 `47` 个托管依赖，检出 `0` 条漏洞，`scripts/deps-exceptions.json` 校验有效且为空；离线场景返回 `status: "not-run"` 与非零退出码（`2`）已由 `scripts/test_deps.py` 覆验。
  - **GitHub Actions**：`.github/workflows/ci.yml` 仅使用白名单内锁定 40 位 SHA 的 `actions/checkout`（`3d3c42e5aac5ba805825da76410c181273ba90b1`，`v7.0.1`）与 `actions/setup-python`（`6d4fd22b20465ccc0f7354476588e8df7c9ca0e0`，`v7.1.0`），标签解引用、白名单与最新稳定版本均一致（`up-to-date`）。

## 4. 可逆默认决定与 LOOP 边界

- 本阶段沿用 [Q-008](../../USER-ACTIONS.md#q-008) 的推荐可逆默认（仅构建 Windows 安装包、正式版应用内联网更新延至首个正式版前、安装包暂不代码签名），未新增需要用户拍板的 `Q-*` 项。
- 既有 [Q-001 / Q-003 / Q-004 / Q-006 / Q-007](../../USER-ACTIONS.md#decisions) 属于后续 M3～M7 事项，本阶段不受影响。
- 非阻塞深化项（安装器视觉定制、包体精简、差分更新、托盘扩展菜单与开机自启）保持延后边界，不阻塞后续阶段开发与桌面交付闭环。

## 5. not-run 与已知边界

- **macOS / Linux / Android / iOS 构建与安装包 `not-run`**：平台目录随 `flutter create` 生成但不在本阶段构建与打包范围（[Q-008](../../USER-ACTIONS.md#q-008)）。
- **GitHub Actions `repository-quality` 在线运行 `not-run`**：需待用户授权 [ACT-004](../../USER-ACTIONS.md#act-004) 推送 `feat/m2-desktop-packaging` 并开 PR #2 后在 `ubuntu-24.04` 云端触发验证；本地已通过 `test_check.py` 覆验 `--install-linux-flutter` 的 SHA-256 拒绝反例并核对 `ci.yml` 与白名单策略。
- **PR #1 合并与分支变基 `not-run`**：PR #1 尚待 [ACT-002](../../USER-ACTIONS.md#act-002) 合并，本阶段分支仍基于 `f2baf27`；PR #1 合并后再变基至新 `main`。
- **本机真实 `blink-dev` 首次安装与人工实机检查（[H-002](../../USER-ACTIONS.md#h-002)）`not-run`**：本机尚未安装 `blink-dev`，故 `package.py --install` 如实跳过并写入 `artifacts/package/install-dev.json`；等效首装、托盘后台运行、运行中升级、版本双核对、干净卸载与真实宿主快照不变已通过 `blink-dev-test` 演练（`M2-K08`）验证。
- **M1 产品范围人工审阅（[H-001](../../USER-ACTIONS.md#h-001)）`not-run`**：保持独立非阻塞推进。

## 6. 给 A 的集中审查 Prompt

```text
你是 BLINK 的 Agent A，动作：对 M2（Windows 桌面骨架、打包与开发版自动安装更新，计划 BLINK-M2-01 修订 1）执行集中技术审查。

- 计划：docs/delivery/stage-plan.md（BLINK-M2-01 修订 1）；报告：docs/delivery/stage-report.md；审查准则：REVIEW.md；架构契约：docs/design/architecture.md §4.3；本机更新与门禁规则：docs/dev-rules/engineering.md §2.2、§3。
- 分支：feat/m2-desktop-packaging（基点 f2baf27，单提交 SHA 以 B 交付回复与 git rev-parse HEAD 为准；若 PR #1 已按 ACT-002 合并，需核实已变基到新 main）。
- 审查重点：
  1. Win32 单实例互斥量与控制管道（apps/blink_client/lib/platform/windows/{single_instance,control_pipe,win32_bindings}.dart）：核对 FILE_FLAG_FIRST_PIPE_INSTANCE、PIPE_REJECT_REMOTE_CLIENTS、受保护仅当前用户 DACL、4096B 行上限与非法输入处理、60 秒超时回执 busy、CancelIoEx 后 GetOverlappedResult(..., true) 排空，以及 --quit-for-update 退出码 0/2/1 与 --background 二次启动静默退出；
  2. 零闪烁原生启动与桌面生命周期（apps/blink_client/windows/runner/*、lib/main.dart、lib/platform/lifecycle.dart、lib/app/blink_app.dart）：核对无过早 Show()/SetFocus()、TaskbarCreated 托盘重建、BLINK_QUIET=1 零窗口零托盘、settings/desktop.json 原子写与损坏保留、run/lifecycle.json 字段、无脏工作区 CMake/RC 版本与图标注入；
  3. 安装包与自动更新（apps/blink_client/windows/packaging/blink.iss、scripts/package.py、scripts/test_package.py）：核对 Inno Setup 7.1.x ISPP Ver 守卫、按用户安装与卸载保留数据、--install 五步（绝不读写正式版 blink 或测试身份键、绝不强杀、双重版本核对、explorer IShellWindows -> CREATE_BREAKAWAY_FROM_JOB -> inJob=true 回退链）与 --rehearsal 前后真实宿主快照一致；
  4. 门禁、依赖审计与 CI（scripts/{check,deps,check_docs}.py、scripts/flutter-checksums.json、.github/workflows/ci.yml、.github/dependabot.yml、.githooks/pre-push）：核对 ci.yml 仅使用白名单 40 位 SHA Action、Linux Flutter 归档先验 SHA-256 再解压、timeout-minutes <= 15、material_ui 1.11.0 许可与 7 天冷却合规、check_docs.py 对 Flutter ephemeral 的最小豁免边界；
  5. 正本同步与卫生（M2-K10）：复核 engineering.md、architecture.md §4.3、requirements.md、roadmap.md、status.md、stage-report.md、USER-ACTIONS.md（ACT-004、H-002）、CHANGELOG.md 与实际实现一致，长期正本零新增旧阶段标签，全仓零 BOM/CRLF/本机绝对路径/密钥/参考项目名。
- 复验命令：python -B scripts/check.py、python -B scripts/check.py --quick、python -B scripts/check_docs.py、git diff --check、python -B scripts/package.py --install（核对宿主机真实卸载键与目录未受污染）。
- 若发现局部问题，原地修复、复验并 git commit --amend -s 收敛进当前分支单提交，同时在 docs/delivery/stage-report.md 追加 <a id="a-review"></a> 审查章节并严格区分“B 实现交付”“A 技术审查”“产品验收”三类结论；未经用户明确授权严禁执行 git push、gh pr create、gh pr merge 或发布操作。
```

<a id="a-review"></a>
## 7. A 集中审查（2026-11-23）

- **审查基点**：分支 `feat/m2-desktop-packaging`，B 交付提交 `8b7143b`（基于 `f2baf27`；`origin/main` 仍为 `642e618`，PR #1 未合并，无需变基）。A 修复已 `git commit --amend -s` 并入同一阶段提交。
- **核查范围**：按交接 prompt 五项逐文件审读——Win32 单实例与控制管道（`single_instance.dart`、`control_pipe.dart`、`win32_bindings.dart`）、原生 runner 与生命周期（`windows/runner/*`、`main.dart`、`lifecycle.dart`、`window_adapter.dart`、`tray.dart`、`desktop_settings.dart`、`atomic_io.dart`、`paths.dart`）、安装包与本机更新（`blink.iss`、`package.py`、`test_package.py`）、门禁与 CI（`check.py`、`deps.py`、`check_docs.py`、`flutter-checksums.json`、`ci.yml`、`dependabot.yml`、`pre-push`）以及正本同步（工程规则 §2.2/§3、架构 §4.3、状态页、USER-ACTIONS、CHANGELOG）。核实通过的要点：`FILE_FLAG_FIRST_PIPE_INSTANCE` + `nMaxInstances=1`、`PIPE_REJECT_REMOTE_CLIENTS`、`D:P(A;;GA;;;<SID>)`、4096 B 行上限与 `invalid_request`、60 秒 `busy`、`CancelIoEx` 后 `GetOverlappedResult(..., true)` 排空；`--quit-for-update` 退出码 `0/2/1` 与 `--background` 二次启动静默 `0`；runner 不调用 `Show()`、`TaskbarCreated` 经 MethodChannel 重建托盘、`BLINK_QUIET=1` 零窗口零托盘；版本经 CMake 环境变量生成构建期头文件并在打包前清缓存强制重配置；ISPP `Ver` 守卫 7.1.x、`PrivilegesRequired=lowest`、无 `[UninstallDelete]` 保留数据；`--install` 只读 `blink-dev` 卸载键、30 秒不强杀、注册表 + PE 双核对、外壳 → 脱离作业 → `inJob=true` 回退链；CI 仅白名单 40 位 SHA Action、先验 SHA-256 再解压、`timeout-minutes: 15`；`material_ui 1.11.0`（BSD-3-Clause，2026-11-09 发布，开工时满 7 天）。
- **A 复验命令与结果**（宿主机 Windows 11、Flutter `3.50.0`、默认中文区域设置 `cp936`）：
  - 修复前 `python -B scripts/check.py`：`failed`（8 项通过；`package-dev` 因 F-001 崩溃，`package-release`、`package-rehearsal` 记 `not-run`）。B 报告的完整门禁 11/11 在默认环境下不可复现。
  - 修复后 `python -B scripts/check.py`：`passed` 11/11（`7m54s`；`flutter-test` 34 条，Python 单测 4 套）；`artifacts/package/rehearsal.json`：`blink-dev-test` `0.1.0-dev.202611230928.1+dirty` → `.2+dirty`，无实例 `--quit-for-update` `0.469s`、运行中退出 `0.375s` / `0.36s`、`userDataPreserved: true`、`residue: []`、`snapshot_match: true`。
  - `python -B scripts/package.py --install`：`rc=0`、`status: skipped`、`reason: not_installed`；执行前后宿主机 BLINK 卸载键、`%LOCALAPPDATA%\blink*`、`%LOCALAPPDATA%\Programs\blink*`、开始菜单与桌面快照逐项一致（均为 0 项）。
  - 修复后 `python -B scripts/check.py --quick`、`python -B scripts/check_docs.py`、`git diff --check`：均 `passed`（amend 前后各跑一次）。

| 编号 / 严重度 | 触发条件与实际结果 | 预期行为与正本依据 | 代码或文档位置 | 修复验收标准与状态 |
| --- | --- | --- | --- | --- |
| `F-001` / `P1` | 中文区域设置（ANSI 代码页 `cp936`）宿主默认环境下，`package.py` 以 `text=True` 且未指定编码读取子进程输出；`flutter --version` 的 UTF-8 `•` 使读线程 `UnicodeDecodeError`，`stdout` 为 `None`，`read_flutter_version` 抛 `TypeError`：完整门禁 `package-dev` 失败，`--install` 与 `--rehearsal` 同样无法构建 | 门禁证据须如实、可复现（`NFR-DEV-002`、[工程规则 §3](../dev-rules/engineering.md#gates)）；`--install` 是本阶段核心闭环（`NFR-DEV-003`、`AC-11`） | `scripts/package.py`（14 处）、`scripts/check.py`、`scripts/deps.py`、`scripts/test_check.py`、`scripts/test_package.py` | 全部 `text=True` 子进程统一 `encoding="utf-8", errors="replace"`；新增 `SubprocessDecodingTests`（AST 扫描全部脚本 + 非 ASCII 版本输出解析），对 `8b7143b` 原文件失败、修复后通过；完整门禁 11/11。**A 已核实关闭** |
| `F-002` / `P2` | 经 `--install` 以 `--background` 托盘常驻后，用户从开始菜单再次打开，第二实例只转交 `focus` 而未授予前台权限，Windows 前台锁可能只闪烁任务栏而不前置窗口（[H-002](../../USER-ACTIONS.md#h-002) 第 4 步） | 第二实例转交后聚焦已有窗口（[架构 §4.3](../design/architecture.md#desktop-lifecycle)） | `lib/main.dart`、`lib/platform/windows/control_pipe.dart`、`lib/platform/windows/win32_bindings.dart` | 连接管道后以 `GetNamedPipeServerProcessId` 取服务端 PID，只对该进程调用 `AllowSetForegroundWindow`（安静模式不调用）；真实管道测试覆盖 `grantForegroundToServer` 路径；架构 §4.3 同步。实际前置效果并入 H-002 人工检查。**A 已修复，待 H-002 实机确认** |
| `F-003` / `P2` | 保存后退出序列中几何保存、`lifecycle.json` 原子写或托盘移除抛异常时，`_isShuttingDown` 已置位却不退出：托盘“退出”失效，后续 `quit-for-update` 空答 `ok` 而进程不退，`--install` 等满 30 秒后失败 | 共享退出序列必须走完（[架构 §4.3](../design/architecture.md#desktop-lifecycle)、`INV-11` 不伪装成功） | `lib/platform/lifecycle.dart`、`test/lifecycle_test.dart` | 持久化失败只记入 `lastShutdownPersistenceError`，退出照常完成；新增“`lifecycle.json` 目标被目录占用时仍回 `ok` 并退出”用例。**A 已核实关闭** |
| `F-004` / `P2` | `check_docs.py` 对任意名为 `flutter` 的目录下的 `ephemeral`，以及任意位置的 `.symlinks` / `.plugin_symlinks` 一律跳过，受跟踪的同名目录（如 `docs/flutter/ephemeral/`）可逃过卫生检查 | 豁免只限 Flutter 生成且被 Git 忽略的平台目录（M2-K10 最小豁免边界） | `scripts/check_docs.py`、`scripts/test_check_docs.py` | 收窄为 `<windows\|linux\|macos\|ios>/flutter/ephemeral`、平台目录或 `ephemeral` 下的 `.symlinks` / `.plugin_symlinks`；新增反例用例（对原实现失败、修复后通过，共 31 条）。**A 已核实关闭** |

- **建议（不阻塞，未改动）**：① 源码构建（无安装身份）按 `BLINK_CHANNEL` 解析数据根，默认与已安装 `blink-dev` 共用 `%LOCALAPPDATA%\blink-dev`，若以 `--dart-define=BLINK_CHANNEL=blink` 运行则会落到正式版数据根；M3 引入便携库前宜让源码构建默认使用独立的 `.local/` 沙盒根。② `blink.iss` 无 `[InstallDelete]`，覆盖升级不会清除旧版本已删去的文件；待插件或资源文件发生删减时再补。③ 互斥量“已存在”判定依赖紧随其后的 `GetLastError` FFI 调用；即便误判，`FILE_FLAG_FIRST_PIPE_INSTANCE` 也会使重复主实例以退出码 `1` 退出，后果可控。
- **未覆盖（`not-run`）**：GitHub Actions `repository-quality` 云端运行（待 [ACT-004](../../USER-ACTIONS.md#act-004)）；本机真实 `blink-dev` 首装、托盘与前置窗口实机体验（待 [H-002](../../USER-ACTIONS.md#h-002)）；macOS / Linux / 移动端构建（[Q-008](../../USER-ACTIONS.md#q-008)）。

**三类结论**：

- **B 实现交付**：范围完整，`M2-W01`～`W07` 与 `M2-K01`～`K10` 均有实现与测试；但交付时声明的完整门禁 11/11 在宿主默认区域设置下不可复现（F-001），交付证据不完整。
- **A 技术审查**：**通过（A 修复后）**。F-001～F-004 已由 A 原地修复并复验，无未决 `P0` / `P1`，无需交回 B 返工。
- **产品验收**：**未进行**。待用户按 [H-002](../../USER-ACTIONS.md#h-002) 首装并实机检查托盘、关于页、窗口前置与自动更新。
