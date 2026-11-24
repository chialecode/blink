# 贡献指南

AI Agent 与程序员遵循同一套规则：开工前先读 [AGENTS](AGENTS.md)，再看[文档索引](docs/README.md)与[有效决定](docs/decisions.md)。

## 完成一次改动

1. 从 [Issues](https://github.com/chialecode/blink/issues) 找到对应需求或缺陷；跨模块或改公共契约（`packages/blink_core` 共享契约、同步与 MCP 协议、文档块 AST、数据库与同步结构）的改动，先在 issue 里写清方案。
2. 引入或更换通用技术依赖前，按[开源选型规则](docs/dev-rules/sources-and-safety.md#oss-policy)查证（只用 `MIT`、`Apache-2.0`、`BSD` 等宽松许可，严禁 `AGPL`/`GPL` 依赖），并先查[本机参考索引](docs/dev-rules/workflow.md#local-reference)。
3. 按[每次改动的流程](docs/dev-rules/workflow.md#change-loop)推进：一个 issue 一个小 PR，分支 `<type>/<issue号>-<简短描述>`，Conventional Commits，每个提交 `git commit -s`（DCO）。
4. 按[门禁规则](docs/dev-rules/engineering.md#gates)安静验证，PR 里写清验证证据；由非作者按 [REVIEW](REVIEW.md) 审查后合并。合成测试通过不等于多端实机产品验收通过。

## 许可、讨论与安全

项目自有源码和文档采用 [Apache-2.0](LICENSE)，不另签 CLA，每次提交通过 `git commit -s` 附带 DCO（`Signed-off-by`）声明。安全漏洞与凭据风险请按 [SECURITY](SECURITY.md) 私密报告。

Issues 与 Pull Request 只允许协作者创建；外部反馈、问题交流与功能建议请用 [Discussions](https://github.com/chialecode/blink/discussions)。
