# BLINK

**BLINK（`B·L·I·N·K`）** 是一款本地优先、纯 Flutter / Dart 自包含、覆盖五端（`Windows`、`macOS`、`Linux`、`Android`、`iOS`）的个人笔记、闪念小记与深度伴读应用。它不依赖 Docker、外置数据库或后端运行时：桌面端把所有数据收纳在单个可随时拷贝备份的**数据文件夹**（`<BLINK_VAULT_DIR>`）并实时自动导出为通用 Markdown 文件，移动端完全离线可用；日常提供**聊天式闪念小记**、**类 Typora 所见即所得 + 源代码双模式 Markdown 笔记**、从笔记自动汇总的**待办清单**与**附件管理**，桌面采用清爽的**沉浸式无系统标题栏飞书式三栏布局与独立分类设置**，移动端保持单焦点精简体验；后续接入 PDF / EPUB / 网页长文锚定伴读，并在“用户原文永不篡改”和 `#private` 四层隐私隔离的前提下，通过纯 Dart CLI / MCP / Skills（外置 AI 优先）与可选端侧直连兼容接口支持个人知识回顾与演进。

技术架构：五端客户端与共享核心采用纯 Flutter / Dart（`>= 3.10`：`sqlite3 3.9.1` Native Assets SQLite WAL + CJK `FTS5` 全文检索 + `package:markdown` 双模式 CJK 输入法安全编辑器 + 纯 Dart 后台 `Isolate` 多媒体解析与 `pdfrx` PDF 引擎 + `packages/blink_sanitizer` 纯 Dart HTML5/CSS 白名单净化器 + 双表面渲染）；多端同步支持桌面内嵌 `shelf` 局域网（`mdns_dart`）/ Tailscale 直连（含 `dart build cli` 无头命令 `blink sync serve`）与客户端端到端加密（`XChaCha20-Poly1305`）WebDAV / S3 云端异步同步，并由桌面后台 Isolate 实时维护只读 `.md` 与 `insights/*.html` 开放导出目录。选型与核心决定见[有效决定](docs/decisions.md#product-decisions)与[纯 Dart 架构与技术选型研究](docs/research/2026-11-22-pure-dart-pivot.md#overview)。

## 状态

阶段路线、MVP 边界与上游风险见[路线与验收](docs/delivery/roadmap.md#stages)；进行中的需求、缺陷与后续迭代项见 [Issues](https://github.com/chialecode/blink/issues)。工具链与门禁命令以[工程规则](docs/dev-rules/engineering.md#toolchain)记录的实际落地状态为准。

## 入口

- 参与开发：先读 [AGENTS](AGENTS.md)，再看[文档索引](docs/README.md)。
- 需要你处理的事：[`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user)。
- 贡献方式：[CONTRIBUTING](CONTRIBUTING.md)；审查口径：[REVIEW](REVIEW.md)；安全问题：[SECURITY](SECURITY.md)。

## 许可

项目自有源码和文档采用 [Apache-2.0](LICENSE)；第三方依赖保留各自的许可和通知。
