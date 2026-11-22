# 来源与安全：开源六维选型、原文保护、隐私路由与公开卫生

<a id="oss-policy"></a>
## 1. 开源优先与六维选型查证

触发条件：引入或更换跨端界面框架、列表与双表面 HTML/SVG/图表渲染、纯 Dart HTML/CSS 安全净化、PDF/EPUB/网页解析、本地 SQLite 与加密同步、CLI/MCP 协议栈、直连模型客户端、打包与测试工具，以及升级依赖大版本、维护本地补丁或扩大自研范围。

A 在阶段计划或选型报告中给出推荐前，必须按下表完成六维查证并写入 `docs/research/YYYY-MM-DD-<topic>.md`（现行基线见[纯 Dart 架构选型研究（2026-11-22）](../research/2026-11-22-pure-dart-pivot.md#overview)，初版归档见[2026-11-20-stack.md](../research/2026-11-20-stack.md)）：

| 维度 | 最低查证依据 |
| --- | --- |
| 组件与来源 | 官方代码仓、官方文档与包注册表链接，精确查询日期（UTC+8），所评估的稳定版本号与发布日期 |
| 版本与维护状态 | 仓库是否归档或停维，近期是否有实质性缺陷修复与版本发布；未查实的记为 `unknown`，严禁主观臆造“维护活跃” |
| 许可证 | 源码、传递依赖及原生二进制产物的实际许可证与随包声明义务（见下节许可证红线） |
| 五端/中文/离线适配 | `Windows`、`macOS`、`Linux`、`Android`、`iOS` 五端及 `dart build cli` 功能对等性、中文字体排印与输入法（IME）组合态兼容性、纯离线可用性及移动端内存/电量开销 |
| 集成成本与体积 | 原生 C++/FFI 或 Dart Native Assets Build Hooks 分发复杂度、客户端安装包增量体积、升级破坏性与可替换隔离度 |
| 自研与适配边界 | 严格区分静态资料判断与实机原型运行证据；仅对成熟开源组件明确无法覆盖的缺口自研最小胶水或解析层 |

<a id="license-boundary"></a>
### 1.1 开源许可证红线与弱传染专门登记

- **允许直接引入的依赖许可**：仅限 `MIT`、`Apache-2.0`、`BSD-2-Clause`、`BSD-3-Clause`、`ISC`、`zlib`、`Public Domain` 等宽松开源许可证（正式打包时自动完整收集并附带第三方许可证声明文件，特别包含 `package:html` 的组合 MIT/BSD-3-Clause 原始 `LICENSE` 文本及 PDFium 许可声明）。
- **严禁引入强传染性许可依赖**：**一律拒绝将 `AGPL`、`GPL`（含 `GPL-2.0`/`GPL-3.0`/`AGPL-3.0`）许可的库或构建运行时作为依赖引入**（例如明确拒绝 `AGPL-3.0` 的 PDF/EPUB 库与 `Nuitka`、`GPL-2.0` 的 `PyInstaller`，亦明确避开未登记弱传染包如 `LGPL-2.1` 的 `zeroconf` 与含 `MPL-2.0` 组件的 `reader_mode`，见[拒绝清单](../research/2026-11-22-pure-dart-pivot.md#licenses)）。
- **文件级弱传染动态链接专门登记**：若个别操作系统级可选能力涉及 `LGPL` 或 `MPL-2.0` 弱传染许可，必须先核实**仅动态链接系统未修改共享库**的使用边界并在[有效决定](../decisions.md#stack-decisions)专门登记后方可接入。当前全仓唯一登记项为 **[DEC-026](../decisions.md#dec-026)**：Linux 桌面端 Surface 2 整页视图通过 Apache-2.0 插件 `desktop_webview_window 0.4.3` 动态链接宿主机系统提供的未修改 `libwebkit2gtk-4.1-0` 与 `libsoup-3.0-0`（`LGPL-2.1+` / BSD），绝不静态链接、绝不修改随包分发，且在宿主机缺失对应库时自动平滑降级为纯 Flutter Surface 1。
- **上游风险跟踪**：选型中发现的平台差异、上游已知缺陷或待验证假设，同步登记在[交付状态的开发与上游事项](../delivery/status.md#issues)（`OSS-*`）。

<a id="privacy-hygiene"></a>
## 2. 原文不可篡改、`#private` 四层隐私红线与公开内容卫生

<a id="raw-layer-immutability"></a>
### 2.1 原文层神圣不可篡改（Raw-Layer Immutability）

BLINK 在存储、同步与外置 AI 扩展边界上严格拆分为**原文正本层（Raw Layer）**与**派生智能及视图层（AI Index & Derived View Layer）**（[数据分层设计](../design/data-and-sync.md#layers)）：

- 用户亲手输入的 BFM v1 闪念、日记、书摘高亮、手写边注（`raw_entries.body_md`、`raw_annotations.note_md`）、只增不改伴读问答轮次，以及导入的原始 PDF、EPUB、音频、书页照片与网页归档正本，均归属原文层，享受最高级别只读保护。用户原文中通过 `![[ai:<uuid>|标题]]` 嵌入外置 AI 卡片时仅记录目标 UUID 指针，绝不把 AI 生成 HTML 写入原文列。
- 无论来自**外置 AI（CLI / MCP Server，`ExternalAiRepository`）**还是**可选内置直连 OpenAI 兼容客户端（`OpenAiCompatClient`）**，所有自动标签、语音逐字稿与整理稿（`verbatim_transcript_text`、`clean_transcript_md`）、书页 OCR 引文、`ai_task_candidates` 待办候选、跨时空回响（`ai_echo_links`）、每日简报/周报/单书综述（含可检索 `summary_md`、Surface 1 `view_html` 与 Surface 2 `artifact_html`）以及个人认知原则演进（初始强制为 `status = 'candidate'`）均只能写入独立可重建的 `ai_*` 派生表，并附带经校验的原文溯源引用（`<blink-ref>`）。
- `ExternalAiRepository` 在接口类型上**不提供任何修改或删除 `raw_*` 的方法**（仅在用户显式启用 `--allow-capture` 时开放只增不改的新建收件箱条目 `blink_capture_entry`，见 [Q-007](../../USER-ACTIONS.md#q-007)）；内置 AI“对话总结为笔记”仅创建派生 `ai_*` 卡片或经用户确认的**全新** `raw_entries` 记录（携带对话来源引用），严禁静默改写既有原文。
- 桌面端后台 `Isolate` 负责将数据库正本以 **5 秒防抖**单向增量原子导出至 `<BLINK_VAULT_DIR>/mirror/`（BFM 确定性降级的纯 UTF-8 `.md` 主归档 + `insights/*.html` 独立自适应静态综述视图），绝不反向覆盖数据库正本，保障十年零锁定可读。

<a id="private-routing"></a>
### 2.2 `#private` 四层零云端出境铁律（`INV-03`）

凡带 `#private` 标签或显式开启私密锁的条目、书籍、附件与派生记录，在四个独立平面同步执行物理闭锁，不依赖提示词软约束（[隐私路由设计](../design/agent-and-reader.md#privacy-routing)）：

1. **外置 AI CLI / MCP 边界**：`packages/blink_cli` 与所有一键导出的第三方 Agent 配置硬锁定默认 `--scope normal_only`，底层仅查询 `v_normal_*` SQL 视图与独立 `fts_normal` 索引；命中私密 ID 时统一返回不透明 `not_found`（杜绝存在性探测）；启用 `local_with_private` 须同时满足用户显式设置开启 + OS 密钥库独立私密令牌 + 本地回环运行三道门控；`normal` 原文嵌入 `private` 卡片时自动脱敏占位。
2. **可选内置直连 `OpenAiCompatClient` 边界**：配置强制拆分为 `normal` 与 `private_local` 两套独立端点画像；任何涉及 `#private` 上下文的伴读追问或总结请求物理锁死 `private_local`，并在 DNS 解析与建连层校验目标 IP 仅属 `127.0.0.1` / `::1` / RFC1918 局域网 / `100.64.0.0/10`（Tailscale，绑定已验 IP 防 DNS 重绑定）；未配置合规本地端点或端点离线时立即返回 `privacy_blocked`，严禁回退云端。
3. **双表面 HTML 沙盒边界**：Surface 1 与 Surface 2 均经 `packages/blink_sanitizer` 剥离全部外链与脚本；Surface 2 叠加离线 `default-src 'none'; script-src 'none'; connect-src 'none'` CSP 与无痕/禁缓存配置（Linux `desktop_webview_window` 在 `SPK-06` 实测若 WebKitGTK 仍留 `#private` 磁盘痕迹则自动将 Linux 私密页锁定于纯 Flutter Surface 1）。
4. **多端同步边界**：局域网/Tailscale 直连零第三方经手；若用户启用 WebDAV / S3 异步中继，全量分段与附件强制经客户端 `XChaCha20-Poly1305` E2EE 加密（远端零明文），且提供“禁止经 WebDAV/S3 中继 `#private`”开关让 `#private` 仅走直连私网。
5. **自动化哨兵门禁**：阶段测试必须覆盖三路径 `#private` 哨兵拦截断言（MCP `normal_only`、内置直连 `private_local`、Surface 2 离线 CSP），确认任何非本地云端探针收到 **0 字节**。

<a id="public-scrubbing"></a>
### 2.3 零库内明文凭据、外部抓取边界与仓库公开卫生

- **零库内凭据与单机 OS 原生密钥库（`INV-08`）**：**`<BLINK_VAULT_DIR>` 便携库目录内严禁保存任何明文凭据或会话令牌**。五端及无头端所需的设备同步令牌（`blink.db` 仅存其 `SHA-256` 哈希）、WebDAV/S3 凭据、E2EE 同步主密钥、`local_with_private` MCP 令牌以及可选每设备内置直连 OpenAI 兼容 API Key，全部隔离保存在操作系统原生安全密钥库（Windows DPAPI、macOS/iOS Keychain、Linux `libsecret`、Android Keystore），按 `blink` / `blink-dev` 双通道独立命名空间隔离，绝不明文写入普通配置或同步流；桌面回环 `ipc.json`（`0600`）存于 OS 运行态目录并随重启轮换。
- **外部网页剪藏合规边界**：纯 Dart 后台 `Isolate` 剪藏仅针对用户显式提交的单篇公开 URL 提取正文，实施严格 DNS/IP 防 SSRF 拦截（禁回环、私网、链路本地与 Tailscale 网段，限 5 跳与 15 MiB），绝不读取系统浏览器 Cookie 库；遇到登录墙、付费墙或人机验证挑战时立即停止并如实报错 `anti_bot_or_paywall`，绝不尝试绕过。
- **公开仓库零路径、零密钥、零参考项目名**：所有入库源码、文档、测试夹具、提交说明、PR 正文与阶段报告中，**严禁包含**：
  1. 开发者机器相关的本机绝对路径（包括 Windows 盘符绝对路径与 Unix 用户主目录绝对路径；文档示例统一使用 `<BLINK_VAULT_DIR>`、`%LOCALAPPDATA%\blink`、`${XDG_DATA_HOME}`、`~/Library/...` 等符号化路径模板）；
  2. 真实私钥块、API 密钥、GitHub 令牌、内嵌账号密码的连接串、`.env` 实参文件或 `.sqlite`/`.db` 本地数据库文件；
  3. [本机参考索引](workflow.md#local-reference)（`BLINK_REFERENCE_DIR` 或上级 `reference/blink/`）中登记的任何参考项目名称，以及本机同级目录中的其他本地仓库名称（需要描述参考背景时只写通用功能领域）。
- **门禁脚本与 `SKILL.md` 治理衔接**：`python scripts/check_docs.py` 在本地与 CI 强制执行上述静态扫描；M6 落地 `packages/blink_skills` 时，仅对 `packages/blink_skills/skills/**/SKILL.md` 显式豁免 `DEC-003` 的无 YAML 头限制（以满足 `agentskills.io` 规范）并附带专用 Frontmatter Schema 校验，其余全仓 Markdown 仍严格禁用 YAML 头。

<a id="html-sanitization-safety"></a>
### 2.4 纯 Dart HTML/SVG/CSS 白名单净化与双表面 CSP 安全红线

- **唯一纯 Dart 净化底座（`packages/blink_sanitizer`）**：全部外部网页剪藏、EPUB XHTML 块（`html_sanitized`）与 AI 生成的 Surface 1 `view_html` / Surface 2 `artifact_html` 在 MCP/CLI 入库与五端渲染前均强制通过 `packages/blink_sanitizer`（基于 `package:html 0.15.7` HTML5 DOM 建树重建 + ~400 行 W3C CSS Syntax L3 词法器/安全子集编译器），严禁使用正则过滤或直接透传原始 HTML 字符串（[双表面契约](../design/data-and-sync.md#generative-html)）。
- **零可执行脚本、零外链资源、零 CSS 逃逸绕过**：
  - 彻底清除 `<script>`、`<iframe>`、`<object>`、`<embed>`、`<form>`、`<base>`、`<meta>`、`<link>`、`<template>`、`<foreignObject>`、SVG `<image>` / `<use>` 外链、SMIL `<animate*>` 及一切 `on*` 内联事件属性；
  - CSS 词法器在完整解码 CSS 转义序列后阻断一切 `url(...)`（含大小写与 `\75 rl(...)` 混淆）、`@import`、`expression()`、`behavior`、`javascript:` 与 `data:text/html`；阅读与卡片图像仅允许已核验的本地内容寻址 `blink-blob://<sha256>`（或经本地 `blobs/` 校验封装的离线字节）；
  - 硬性剔除所有硬编码十六进制 / `rgb()` / `hsl()` 前景与背景色值，强制使用宿主注入的 **Day / Sepia / Dark** `var(--blink-*)` 语义颜色令牌。
- **双表面渲染与原生溯源隔离（`INV-13`）**：
  - **Surface 1（内联纯 Flutter）**：由 `flutter_widget_from_html_core` + `fwfh_svg` + `fl_chart` 构建为纯原生 Flutter Widget 树，零脚本执行内核，严格区分用户 BFM 标签与 AI 卡片标签生产边界（禁止 AI HTML 递归输出 `<blink-embed>`）；
  - **Surface 2（按需沙盒全页视图）**：由 `flutter_inappwebview`（Win/macOS/Android/iOS）与 `desktop_webview_window`（Linux，受 [DEC-026](../decisions.md#dec-026) 约束）以**禁用 JavaScript + 强制离线 `Content-Security-Policy: default-src 'none'; script-src 'none'; connect-src 'none';` + 导航拦截器**方式运行；`<blink-ref>` 编译为 `blink-ref://` 链接并由原生导航拦截器无脚本唤起 Flutter 原文溯源浮层，阻断 100% 外部网络请求。
