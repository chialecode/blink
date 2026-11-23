# 贡献指南

AI Agent 与程序员遵循同一套协作与工程规则：开工前先读 [AGENTS](AGENTS.md)，再看[文档索引](docs/README.md)、[交付状态](docs/delivery/status.md#current)和[当前计划](docs/delivery/stage-plan.md#scope)。

## 完成一次变更

1. 核对当前计划、[有效决定](docs/decisions.md)和关联需求编号（`FR-*` / `NFR-*`）。局部修复在任务内写明即可；跨模块或改变公共契约（`packages/blink_core` 共享契约、同步与 MCP 协议、文档块 AST、数据库与同步结构）的变更必须先写进阶段计划。
2. 引入或更换通用技术依赖前，按[开源选型规则](docs/dev-rules/sources-and-safety.md#oss-policy)完成六维查证（仅限 `MIT`、`Apache-2.0`、`BSD` 等宽松许可，严禁引入 `AGPL`/`GPL` 依赖），并先查阅[本机参考索引](docs/dev-rules/workflow.md#local-reference)。
3. 按 [A 规划 → B 执行 → A 审查](docs/dev-rules/workflow.md#agent-handoff)闭环推进：完整实现正常流程与关键失败恢复路径，严守原文层只读与 `#private` 零云端出境不变量，同步更新受影响的文档正本。
4. 按[门禁规则](docs/dev-rules/engineering.md#gates)完成安静有界验证，对照 [REVIEW](REVIEW.md) 完成自审后交接。合成测试通过不等于多端实机产品验收通过。
5. 遵守“一个阶段一个分支、一个提交、一个 Squash PR”（人读阶段编号 `M1`、`M2` 大写，分支名与提交 scope 如 `feat/m1-project-baseline`、`feat(m1)` 小写）：push 前将阶段内的规划、实现、返工与审查修复全部 `git commit --amend -s` 收敛进单个带 DCO 签名的提交（严禁改写初始根提交）。push、创建 PR、按 `main-protection` 规则 squash 合并及发布均须用户逐项明确授权（[Git 与远端规则](docs/dev-rules/engineering.md#git-ci-release)）。

需要用户处理的决定、人工检查和外部授权统一且只写进根目录 [USER-ACTIONS](USER-ACTIONS.md)。

## 许可、讨论与安全

项目自有源码和文档采用 [Apache-2.0](LICENSE)，不另签 CLA，每次提交通过 `git commit -s` 附带 DCO（`Signed-off-by`）声明。安全漏洞与凭据风险请按 [SECURITY](SECURITY.md) 私密提交。

为防止垃圾信息，仓库已关闭 GitHub Issues、Wiki 与 Projects，且 Pull Request 仅限协作者创建；外部反馈、问题交流与功能建议请统一使用 [Discussions](https://github.com/chialecode/blink/discussions)。
