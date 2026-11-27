# BLINK 文档索引

先读[根入口](../README.md)和 [AGENTS](../AGENTS.md)。本仓采用二代精简分层文档（[治理决定](decisions.md#governance)）：产品正本（需求、路线与验收、决定）→ 技术设计与界面 → 选型查证 → 开发规则；进行中的工作在 [Issues](https://github.com/chialecode/blink/issues)，需要用户本人处理的事项是 [`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user)。

| 问题 | 正本 |
| --- | --- |
| 用户要什么、边界在哪 | [需求](requirements.md)（`B·L·I·N·K` 定位、核心不变量、`FR`/`NFR`，状态分已实现、本阶段、待实现） |
| 分几步做、什么算基本可用、怎样验收 | [路线与验收](delivery/roadmap.md)（`M1`～`M7` 阶段划分、MVP 边界、验收场景 `AC-*`、上游风险 `OSS-*`） |
| 已经定下哪些规则、产品与技术取舍 | [有效决定](decisions.md)（`DEC-*` 只增不改号台账） |
| 纯 Dart 单仓拓扑、同步/IPC/CLI/MCP 契约、单文件夹存储安全与不变量是什么 | [系统架构](design/architecture.md) |
| 原文层与派生层、BFM v1 与双轨块 AST、双表面受控 HTML、直连/E2EE 同步与开放镜像怎样工作 | [数据与同步设计](design/data-and-sync.md) |
| 外置 AI（CLI/MCP/Skills）、可选内置直连 AI、`#private` 四层隐私边界与纯 Dart 伴读采集管线怎样工作 | [Agent 与阅读器设计](design/agent-and-reader.md) |
| 五端界面布局、BFM v1 编辑器与中文排版令牌、双表面受控 HTML 视图与交互状态怎样做 | [界面规范](ui.md) |
| 为什么选这套纯 Dart 五端技术栈与外置 AI 扩展方案 | [纯 Dart 架构与技术选型研究（现行正本）](research/2026-11-22-pure-dart-pivot.md)（初版研究归档见[2026-11-20 技术栈研究](research/2026-11-20-stack.md)）；Windows 安装器见[NSIS 安装器选型记录](research/2026-11-24-nsis-installer.md)；M4 同步、OS 密钥库与 Android 适配见[M4 同步与 Android 选型研究](research/2026-11-27-m4-sync-and-android.md) |
| 怎样提需求、开发、审查、合并与每周维护 | [开发流程](dev-rules/workflow.md)、[审查口径](../REVIEW.md)、[教训](../LESSONS.md) |
| 工具链、双通道小写路径、两级门禁、Git 与发布规则是什么 | [工程规则](dev-rules/engineering.md)、[更新日志](../CHANGELOG.md) |
| 开源六维查证、许可证、原文只读、纯 Dart 净化与隐私脱敏红线是什么 | [来源与安全](dev-rules/sources-and-safety.md)、[安全报告](../SECURITY.md) |
| 需要用户本人授权、决定或检查什么 | [`needs-user` issue](https://github.com/chialecode/blink/issues?q=is%3Aissue+label%3Aneeds-user) |
