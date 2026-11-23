# BLINK 安全策略与漏洞报告

可能涉及用户私人原文或 `#private` 条目越界外发、每端设备令牌/E2EE 同步密钥/AI 接口 API 密钥或运行期 IPC 令牌泄露、纯 Dart HTML/SVG/CSS 净化器或表面 2 离线 CSP 沙盒绕过（脚本注入或外链探测）、MCP/CLI 越权读写原文层或私密条目、路径遍历、任意代码执行或用户数据损坏的问题，请通过 [GitHub 私密安全通告](https://github.com/chialecode/blink/security/advisories/new)私下提交。不要在公开的 [Discussions](https://github.com/chialecode/blink/discussions) 或 Pull Request 中披露可利用的细节、真实密钥、连接配置或个人笔记内容。

提交报告请说明受影响的分支或提交 SHA（或本地安装包目录名与 `SHA256SUMS.txt` 摘要）、运行平台与同步模式、复现前提与步骤、影响范围，以及不含真实隐私的合成复现样本。

## 凭据与私密原文隔离规则

- **每端原生安全密钥库隔离与 `<BLINK_VAULT_DIR>` 零明文凭据（`INV-08`）**：设备同步配对令牌（`device_token`）、WebDAV/S3 客户端端到端加密主密钥、外置 MCP `local_with_private` 本地令牌以及可选应用内直连 OpenAI 兼容接口的 API Key，一律仅保存在对应设备操作系统原生安全密钥库（Windows DPAPI、macOS/iOS Keychain、Linux `libsecret` / Secret Service、Android Keystore）中，按 `blink` / `blink-dev` 双通道严格隔离；桌面运行期回环 IPC 会话令牌（`ipc.json`）仅存放在 `0600` 权限的系统运行期目录中。**严禁**将任何密钥、令牌或会话文件写入 `<BLINK_VAULT_DIR>` 便携库、明文设置文件、同步载荷、日志、崩溃记录、前端状态快照或 Git 仓库（[存储与安全](docs/design/architecture.md#storage-security)）。
- **`#private` 四层零云端出境硬隔离（`INV-03`）**：① **外置 CLI / MCP 层**：默认强制锁定 `--scope normal_only`，底层仅查询 `v_normal_*` SQL 视图与物理拆分的 `fts_normal`，私密条目对默认外部代理一律返回不透明 `not_found`，跨私密嵌入自动脱敏，访问私密条目须显式通过三道本地门禁与单向私密传染锁存；② **可选应用内直连 AI 层**：严格拆分 `normal` 与 `private_local` 两套配置档，`#private` 条目与伴读追问强制解析并锁死为 `127.0.0.1` / `::1` / RFC1918 / `100.64.0.0/10` 本地或内网端点（防 DNS 重绑定），未就绪时直接熔断返回 `privacy_blocked`，绝不回退云端；③ **受控 HTML 渲染层**：纯 Dart 净化 + 表面 2 离线 `default-src 'none'` CSP + 无痕上下文，零字节网络出站；④ **多端同步层**：直连局域网/Tailscale 点对点加密，WebDAV/S3 异步中继强制客户端 `XChaCha20-Poly1305` 端到端加密并提供“禁止 `#private` 经云端中继”开关（[隐私路由](docs/design/agent-and-reader.md#privacy-routing)、[隐私与公开卫生](docs/dev-rules/sources-and-safety.md#privacy-hygiene)）。
- **纯 Dart 净化与双表面受控 HTML/SVG 零脚本零外链红线（`INV-13`）**：外部网页剪藏、EPUB 富排块（`html_sanitized`）与外置/内置 AI 产出的表面 1 卡片（`view_html`）及表面 2 整页视图（`artifact_html`），在写入与渲染双端必须经纯 Dart `packages/blink_sanitizer`（`package:html` HTML5 树重建 + W3C CSS Syntax L3 令牌级白名单编译器）净化，硬性剥离 `<script>`、`<iframe>`、`<foreignObject>`、SMIL 动画、`on*` 事件、全部 CSS `url(...)`（含大小写与十六进制转义绕过）及硬编码色值；表面 1 由纯 Flutter 原生组件树渲染，表面 2 在按需单实例沙盒整页视图中叠加离线 `default-src 'none'; script-src 'none'` CSP、无痕隔离与无 JS 导航拦截，从根源阻断富视图 XSS 与外链追踪像素回传（[文档 AST 与生成式视图](docs/design/data-and-sync.md#document-ast)、[来源与安全规则](docs/dev-rules/sources-and-safety.md#html-sanitization-safety)）。

## 凭据泄露应急轮换

如果有效的 AI 接口 API 密钥、设备同步配对令牌、WebDAV/S3 凭据、E2EE 主密钥、MCP 本地令牌或虚拟局域网节点密钥已经泄露，请立即按以下顺序处置：

1. **先在源头吊销与轮换**：前往对应模型服务商后台吊销泄露的 API Key；在 BLINK 设备管理中吊销泄露的同步配对设备（作废其 `device_token`）；更换 WebDAV/S3 访问凭据并轮换 E2EE 同步密钥；重启桌面端刷新系统运行期 `ipc.json` 令牌并轮换本地 MCP 令牌；或在 Tailscale / Headscale 控制台注销受影响的设备密钥。仅删除 Git 记录、配置文件或聊天文本**不能**使已泄露的凭据失效。
2. **核查受影响窗口**：检查对应服务商或中继桶在泄露时间窗内的访问记录与调用审计计数，确认是否有未授权读取。
3. **根因修复与回归**：按 [REVIEW](REVIEW.md) `P0` 级别封堵泄露路径并补充脱敏哨兵断言。

## 维护范围

项目当前处于早期基线建设阶段，尚无正式发行版。安全修复仅面向 `main` 分支最新代码维护，暂不承诺历史版本回溯支持或固定响应时限。
