# BLINK

**BLINK（`B·L·I·N·K`）** 是一个本地优先、纯 Flutter / Dart 自包含、覆盖五端（`Windows`、`macOS`、`Linux`、`Android`、`iOS`）的个人知识库、多媒体伴读与可演进 AI 认知工作台。它零外部容器、零外置数据库、零后端 Python 运行时：在桌面端以单文件夹便携库 `<BLINK_VAULT_DIR>` 承载全部数据与只读开放镜像，移动端 100% 离线优先；以零延迟 BFM v1 瞬时采集流（文字、语音录音、书页拍照、网页剪藏）承接日常思考，提供五端一致的 PDF、EPUB 与网页长文锚定批注伴读，并在“原文层神圣不可篡改”的前提下，通过纯 Dart CLI / MCP Server / Agent Skills（外置 AI 优先）及可选端侧直连 OpenAI 兼容接口生成跨时空回响、认知原则账本与双表面高表现力 HTML 卡片及整页报告。

技术栈：五端客户端与共享核心采用纯 Flutter / Dart（`>= 3.10`：`flutter_riverpod` + `drift 2.35.4` / `sqlite3 3.9.1` Native Assets SQLite WAL + CJK `FTS5` + `package:markdown` BFM v1 + 纯 Dart Isolate 网页/EPUB 解析 + `pdfrx` 原生 PDF 引擎 + `packages/blink_sanitizer` 纯 Dart HTML5/CSS 净化器 + 表面 1 `flutter_widget_from_html_core`/`fl_chart` 纯原生渲染与表面 2 按需零脚本离线 CSP 沙盒整页 HTML 视图）；多端同步支持桌面内嵌 `shelf` LAN（`bonsoir`）/ Tailscale 直连（含 `dart build cli` 无头命令 `blink sync serve`）与客户端端到端加密（`XChaCha20-Poly1305`）WebDAV/S3 异步中继，并由桌面端后台 Isolate 实时维护纯 UTF-8 Markdown 主归档与 `insights/*.html` 独立自适应开放镜像。选型依据见[纯 Dart 架构与技术选型研究](docs/research/2026-11-22-pure-dart-pivot.md#overview)。

## 状态

阶段路线、MVP 边界与上游风险见[路线与验收](docs/delivery/roadmap.md#stages)；进行中的需求、缺陷与后续迭代项见 [Issues](https://github.com/chialecode/blink/issues)。工具链与门禁命令以[工程规则](docs/dev-rules/engineering.md#toolchain)记录的实际落地状态为准。

## 入口

- 参与开发：先读 [AGENTS](AGENTS.md)，再看[文档索引](docs/README.md)。
- 需要你处理的事：[`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user)。
- 贡献方式：[CONTRIBUTING](CONTRIBUTING.md)；审查口径：[REVIEW](REVIEW.md)；安全问题：[SECURITY](SECURITY.md)。

## 许可

项目自有源码和文档采用 [Apache-2.0](LICENSE)；第三方依赖保留各自的许可和通知。
