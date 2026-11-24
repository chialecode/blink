# 更新日志

记录 BLINK 正式发行版的变更。正式发行标签按 `v0.1.x` 递增，首个正式版从 `v0.1.1` 起步（首个正式版发布前的开发通道构建统一使用 `0.1.0-dev.<UTC时间>` 版本号，阶段里程碑 `M1`、`M2` 不打 Git 标签）。未来每个正式版以版本号作为二级标题，该节正文直接作为 GitHub Release 发布说明与应用内“更新内容”的唯一正本（[Git 与发布规则](docs/dev-rules/engineering.md#git-ci-release)）。

## Unreleased

仓库治理、产品需求、纯 Dart 架构基线与 Windows 桌面打包自动化：

- 建立精简二代文档治理结构、远端 `main-protection` 分支保护规则集与零依赖文档门禁 `scripts/check_docs.py`（附回归夹具 `scripts/test_check_docs.py` 与本地 `pre-push` hook）。
- 确立 **BLINK（`B·L·I·N·K`）** 纯 Flutter / Dart 五端本地优先个人知识库、单文件夹便携库、多媒体锚定伴读与双轨无服务端 AI 扩展的产品需求基线（`FR`/`NFR`）与七阶段交付路线（`M1`～`M7`，`M2` 按 `DEC-027` 插入桌面打包与开发版自动安装更新）。
- 完成零容器、零外置数据库、零后端 Python 运行时的纯 Dart 架构六维选型查证与核心设计契约（`DEC-001`～`DEC-027`、`INV-01`～`INV-13`、`SPK-01`～`SPK-09`）：涵盖 `<BLINK_VAULT_DIR>`（`drift` + `sqlite3` Native Assets WAL + CJK `FTS5` + `blobs/` + 实时只读 `mirror/`）、BFM v1 文本编辑器与 CJK 输入法保护、M4 统一多端同步（桌面内嵌 `shelf` LAN/Tailscale 直连与 `XChaCha20-Poly1305` E2EE WebDAV/S3 异步中继）、纯 Dart Isolate 网页/EPUB/`pdfrx` PDF 伴读、`packages/blink_sanitizer` 纯 Dart 净化与双表面高表现力 HTML 渲染，以及 `dart build cli` 统一 CLI/MCP/Skills 外置接口与可选端侧直连 OpenAI 兼容客户端。
- 落地 Dart Workspace（固定 `.flutter-version` 为 Flutter `3.50.0` / Dart `3.14.0`）与 `apps/blink_client` Windows 最小桌面外壳：主窗口占位、“关于”版本/通道/身份/提交信息、关闭隐藏到托盘原子设置（`settings/desktop.json` 含损坏改名保留）、最小尺寸 `760×560`、原创多尺寸正式/开发通道图标与零脏工作区 CMake/RC 版本资源注入。
- 实现 Windows 按安装身份单实例互斥量、受保护仅当前用户 DACL 控制管道（`focus` / `quit-for-update` / `ping`）、零闪烁后台启动（`--background`）、资源管理器重启托盘重建（`TaskbarCreated`）、安静模式（`BLINK_QUIET=1`）及共享保存后退出序列（原子写 `run/lifecycle.json`）。
- 落地 NSIS `3.13` 按用户安装脚本（`apps/blink_client/windows/packaging/blink.nsi`，固定版本与 SHA-256，卸载项按应用标识，覆盖升级清掉旧版本多余文件，[DEC-029](docs/decisions.md#dec-029)；最初为 Inno Setup `7.1.1`）与 `scripts/package.py`：`blink-dev` / `blink` 双通道产包与 `SHA256SUMS.txt`/`build-info.json` 单份留新原子替换、`--install` 本机开发版静默安装更新（首次也自动、窗口开着时推迟、camelCase 回执）与作业对象脱离拉起，以及 `--rehearsal` 隔离测试身份（`blink-dev-test`）端到端升级演练与宿主机快照比对。
- 落地两级工程门禁 `scripts/check.py`（`--quick` / 完整 / `--ci` / Linux Flutter SHA-256 校验安装）、7 天冷却与 OSV 漏洞审计 `scripts/deps.py`、Dependabot `pub` 生态配置，以及 `.github/workflows/ci.yml` 固定校验版 Flutter CI 接入。
