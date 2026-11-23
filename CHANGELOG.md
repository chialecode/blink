# 更新日志

记录 BLINK 正式发行版的变更。正式发行标签按 `v0.1.x` 递增，首个正式版从 `v0.1.1` 起步（首个正式版发布前的开发通道构建统一使用 `0.1.0-dev.<UTC时间>` 版本号，阶段里程碑 `M1`、`M2` 不打 Git 标签）。未来每个正式版以版本号作为二级标题，该节正文直接作为 GitHub Release 发布说明与应用内“更新内容”的唯一正本（[Git 与发布规则](docs/dev-rules/engineering.md#git-ci-release)）。

## Unreleased

M1 仓库治理、产品需求与纯 Dart 架构基线（当前进展见[交付状态](docs/delivery/status.md#current)与[当前计划](docs/delivery/stage-plan.md#scope)）：

- 建立精简二代文档治理结构、远端 `main-protection` 分支保护规则集与零依赖文档门禁 `scripts/check_docs.py`（附回归夹具 `scripts/test_check_docs.py` 与本地 `pre-push` hook）。
- 确立 **BLINK（`B·L·I·N·K`）** 纯 Flutter / Dart 五端本地优先个人知识库、单文件夹便携库、多媒体锚定伴读与双轨无服务端 AI 扩展的产品需求基线（`FR`/`NFR`）与六阶段交付路线（`M1`～`M6`）。
- 完成零容器、零外置数据库、零后端 Python 运行时的纯 Dart 架构六维选型查证与核心设计契约（`DEC-001`～`DEC-026`、`INV-01`～`INV-13`、`SPK-01`～`SPK-09`）：涵盖 `<BLINK_VAULT_DIR>`（`drift` + `sqlite3` Native Assets WAL + CJK `FTS5` + `blobs/` + 实时只读 `mirror/`）、BFM v1 文本编辑器与 CJK 输入法保护、M3 统一多端同步（桌面内嵌 `shelf` LAN/Tailscale 直连与 `XChaCha20-Poly1305` E2EE WebDAV/S3 异步中继）、纯 Dart Isolate 网页/EPUB/`pdfrx` PDF 伴读、`packages/blink_sanitizer` 纯 Dart 净化与双表面高表现力 HTML 渲染，以及 `dart build cli` 统一 CLI/MCP/Skills 外置接口与可选端侧直连 OpenAI 兼容客户端。
