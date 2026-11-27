# BLINK 界面规范

本页定义 `Windows + Android + Linux + macOS + iOS` 五端自适应布局、中文深度阅读视觉与排版令牌、**BFM v1 中文输入法（CJK IME）保护编辑器**、**双表面高表现力 HTML（Surface 1 原生组件树 + Surface 2 离线沙盒整页）**，以及核心视图和同步/AI 状态的交互契约。功能范围见[需求](requirements.md#scope)，客户端分层与状态管理见[系统架构](design/architecture.md#topology)，内容模型与标签契约见[数据与同步设计](design/data-and-sync.md#bfm)。

设计总则：

- **打开即写、阅读即沉浸**：移动端打开直接落在带底部瞬时输入栏的采集流，桌面端打开直接聚焦主栏采集框或恢复上次伴读分栏；绝不在首屏放置仪表盘统计图表或繁琐文件夹树。
- **克制分区与单主按钮原则**：依靠页面浅暖/纯白底色对比与 `1px` 细分隔线划分层次，不堆叠多层嵌套卡片阴影；每个局部区域最多只放一个强调色主按钮，次要操作统一收进弹出式“⋯”更多菜单（桌面端为锚定浮层、移动端为底部操作抽屉，危险删除项红字分隔）。
- **原文与 AI 派生层视觉分明**：用户手写 BFM v1 原文、高亮与人工批注采用实底正文样式；外置 AI（CLI/MCP）或可选内置直连 AI 产出的标签、跨时空回响（Echoes）、原则建议与**双表面高表现力 HTML 卡片/整页**统一采用 `surface.aiDerived` 微底色或编辑部信息卡片容器，带明确的 `✦ AI 派生` 来源微标与 `<blink-ref>` 可点击原文溯源胶囊（[DEC-024](decisions.md#dec-024)、[DEC-025](decisions.md#dec-025)），杜绝把机器生成文字混充为用户原话。
- **诚实非阻塞状态**：纯离线暂存、桌面同步对端休眠、E2EE 中继同步中、扫描版 PDF `missing_ocr`、Linux 缺失 WebKitGTK 降级 Surface 1、私密本地闭锁 `privacy_blocked` 与同步冲突全部以安静的顶部/行内状态胶囊呈现，配图标、文字与无障碍名称（不只靠颜色），绝不用全屏转圈遮罩打断输入或阅读。

<a id="layout"></a>
## 1. 五端自适应窗口与布局

单一 Flutter 视图树按视口有效宽度（逻辑像素 `dp` / `px`）分四档自适应切换桌面三栏/伴读分栏与移动流式底栏/半屏抽屉，任何档位严禁出现横向滚动条（`NFR-PLAT-001`）：

| 视口宽度档位 | 典型设备形态 | 主导航区 | 上下文列表栏 | 主工作区与伴读边注区 |
| --- | --- | --- | --- | --- |
| `≥ 1280px` | 桌面宽屏（Windows / macOS / Linux） | 左侧固定图标栏 `56px` | `264px`（采集筛选与文件管理 / 书库目录 / 复盘列表；纯伴读沉浸态可折叠） | 主内容区自适应；伴读模式默认左右分栏：左主阅读视口（约 `62%`）+ 右侧边注与回响栏（`360px～420px`，可拖拽调宽或一键收起）；长日记模式可选开启左右分栏预览 |
| `960px～1279px` | 桌面标准窗 / 横屏大平板 | 左侧固定图标栏 `56px` | `232px`（进入伴读模式时自动折叠为顶部返回与目录抽屉，把宽度让给正文与边注分栏） | 采集流居中限宽；伴读模式为正文视口 + `320px` 右侧边注与回响栏 |
| `600px～959px` | 竖屏平板 / 折叠屏展开态 / 桌面窄窗（最小 `760×560`） | 左侧紧凑图标栏 `52px` | 不常驻，退回为主工作区顶部分段筛选或左侧滑出抽屉 | 单主视口居中展示；伴读模式下点击高亮或回响角标从右侧滑出 `340px` 浮层面板（点正文区或按 `Esc` 收起） |
| `< 600px` | 手机竖屏（Android / iOS） | 底部四项导航栏（采集流 / 书库 / 回顾与待办 / 设置；进入具体书籍伴读或全屏综述时自动收起） | 无侧栏，筛选收进页面顶栏胶囊条 | 全宽流式视图；采集流页底部常驻**瞬时输入栏**（随软键盘平滑顶起，BFM 补全条贴合键盘上沿）；伴读页选中文本或点边注标记从底部弹出**半屏抽屉（Half-Sheet，可上拉至 88% 高）** |

窗口与壳层细节：

- **桌面端（Windows / macOS / Linux）**：图标栏与上下文侧栏固定不随正文滚动；支持全局页内快捷键（`Ctrl/Cmd + N` 聚焦瞬时输入、`Ctrl/Cmd + K` 全局 CJK 全文搜索与跳转、`Ctrl/Cmd + \` 切换伴读右侧边注栏、`Ctrl/Cmd + Shift + P` 切换长日记预览、`Esc` 关闭浮层抽屉）。桌面最小窗口尺寸限制为 `760×560`，支持系统托盘后台常驻承载内嵌同步与定时镜像防抖。
- **移动端（Android / iOS）**：严格遵守状态栏、刘海/灵动岛与底部手势横条安全区（`SafeArea` + `MediaQuery.viewInsetsOf(context).bottom`）；采集流采用反向键盘避让策略，软键盘弹起时输入栏与补全条零抖动贴合键盘上沿。
- **导航项固定四入口**（桌面图标栏自上而下、移动底栏自左向右，末位为设置）：
  1. **采集流（Inbox / Stream）**：BFM v1 瞬时输入、全类型时间线与附件/文件管理。
  2. **书库（Library）**：PDF、EPUB 与剪藏网页长文的统一书架与伴读入口。
  3. **回顾与待办（Review & Intentions）**：晨间简报、内生柔性待办、双表面综述与原则账本（开启直连 AI 时含轻量 AI 对话与笔记提炼面板）。
  4. **设置（Settings）**：单文件夹便携库与镜像、多端同步、外置 AI（CLI/MCP/Skills）、可选直连 OpenAI 兼容接口与版本通道（桌面端固定于图标栏底部，上方紧邻同步状态圆点）。

<a id="tokens"></a>
## 2. 视觉、配色、中文排版与 BFM v1 输入法保护令牌

整体视觉采用低噪耐看的纸感编辑部风格：避免刺眼高饱和色块，保证长时间中文长文阅读与夜间记录的视觉舒适度。所有颜色、字号、圆角与间距集中定义在客户端主题常量层，**同时动态注入为 Surface 2 沙盒 HTML 的 `--blink-*` CSS 自定义属性**，严禁在业务组件或 AI HTML 中硬编码字面色值。

### 2.1 色彩语义令牌（同步映射为 Surface 2 `--blink-*` CSS 变量）

提供**日间清朗（Day）**、**暖纸伴读（Sepia，阅读器与综述可选）**与**夜间低眩光（Dark）**三套语义表面，正文对比度均满足 WCAG AA（`≥ 4.5:1`，核心正文 `≥ 7:1`）：

| 语义令牌（Surface 2 CSS 变量） | 日间值（Day） | 暖纸值（Sepia） | 夜间值（Dark） | 用途边界 |
| --- | --- | --- | --- | --- |
| `surface.canvas`（`--blink-surface-canvas`） | `#FFFFFF` | `#FBF7EE` | `#141619` | 主工作区、阅读视口与输入框底色 |
| `surface.sidebar`（`--blink-surface-sidebar`） | `#F6F7F8` | `#F3EDE0` | `#1B1E23` | 桌面图标栏、上下文侧栏与移动底栏底色 |
| `surface.aiDerived`（`--blink-surface-ai-derived`） | `#F4F6FA` | `#EFE9DC` | `#1F242D` | AI 卡片、回响、原则建议与只读嵌入槽专用浅底（配 `1px` 细描边） |
| `text.primary`（`--blink-text-primary`） | `#1F2328` | `#2B261F` | `#E6EAF0` | 原文正文、标题与主操作文字 |
| `text.secondary`（`--blink-text-secondary`） | `#59636E` | `#665E52` | `#9BA4B0` | 时间戳、章节页码、来源说明与次级元信息 |
| `text.muted`（`--blink-text-muted`） | `#8C959F` | `#918778` | `#6E7781` | 占位符、BFM 弱化 UUID 标识与已归档待办 |
| `border.hairline`（`--blink-border-hairline`） | `#E6E8EB` | `#E2DACB` | `#2B3038` | 栏间分隔线、条目底部分隔细线与卡片描边 |
| `accent.primary`（`--blink-accent-primary`） | `#1E60D5` | `#2457B2` | `#5893F8` | 唯一主按钮、当前选中导航项、焦点环与 `<blink-ref>` 胶囊强调色 |
| `privacy.private`（`--blink-privacy-private`） | `#0F766E` | `#0F766E` | `#2DD4BF` | `#private` 私密锁标与“仅本地隔离”状态提示 |
| `status.ok / warn / err`（`--blink-status-*`） | `#1F883D` / `#BF8700` / `#CF222E` | 同左 | `#3FB950` / `#D29922` / `#F85149` | 已同步 / 离线排队或降级提示 / 冲突或错误提示 |
| `highlight.amber / sage / sky / plum` | `rgba(245,180,0,0.28)` 等四色 | 同系降饱和 | `rgba(210,153,34,0.32)` 等四色 | PDF 包围盒、块级正文划选高亮与 BFM `==mark==` 底色 |

### 2.2 字体、中文排版与 BFM v1 五条 CJK IME 铁律（`SPK-02`）

| 场景 | 字体栈优先级 | 字号与字重 | 行高、版心与输入法保护约束 |
| --- | --- | --- | --- |
| 界面控件与导航 | `Inter` + 系统中文无衬线（Windows `Microsoft YaHei UI`、macOS/iOS `PingFang SC`、Linux `Noto Sans CJK SC`、Android `Roboto / HarmonyOS Sans SC`） | 导航与正文 `14px`（400/500），分栏标题 `16px～18px`（600），微标与元信息 `12px` | 单行标签省略号截断；数字采用 `tabular-nums` 对齐时间、页码与 `@t[mm:ss]` |
| 采集流与 BFM v1 编辑输入 | 同上无衬线栈（代码块与公式降级用 `JetBrains Mono` / 系统等宽字体） | 桌面 `15px`、移动 `16px`（防移动端输入聚焦缩放），字重 `400` | 行高 `1.65`，段间距 `0.65em`；全程采用原生 Flutter `TextField` + 如下五条 CJK IME 保护铁律 |
| 长文与 EPUB 伴读正文 | 用户可在“无衬线屏显体”与“人文衬线宋/明体（`Source Han Serif SC` / `Songti SC` / `Noto Serif CJK SC`）”间切换 | 默认 `17px`（支持 `14px～22px` 无级步进），标题按 `1.25 / 1.5 / 1.8` 倍率缩放 | 默认行高 **`1.80`**（可选 `1.65 / 1.80 / 2.00`），段后距 `0.90em`；桌面与平板正文最大行宽 **`680px～720px`（约每行 34～40 汉字）**，行首尾执行中文避头尾标点挤压 |

**BFM v1 编辑器五条 CJK IME 铁律（跨五端 `Windows / macOS / Linux / Android / iOS`）**：

1. **组合态零改写 `TextEditingValue`**：所有监听器、符号配对与自动补全引擎必须先检查 `value.composing.isValid && !value.composing.isCollapsed`；处于拼音/双拼预编辑期间**严禁**对 `controller.value` 或 `controller.text` 赋值（根治 Android Gboard/搜狗/微信输入法回环吞字与 `TextRange` 异常）。
2. **`buildTextSpan` 严格 1:1 UTF-16 长度保形着色**：自定义 `BlinkSyntaxTextController` 仅对 `#tag`、`#private`、`[[ref|Label]]`、`==mark==`、`> [!insight]` 等语法施加**不改变排版宽度的 `TextStyle` 色彩/透明度弱化**（如淡化 UUID 串），**严禁**在 `TextField` 内插入 `WidgetSpan` 或删减字符长度；并必须显式检查 `withComposing && value.isComposingRangeValid`，为组合态子串保留原生 `TextDecoration.underline` 下划线。
3. **输入法优先按键拦截**：当 `value.isComposingRangeValid && !value.composing.isCollapsed` 时，`Enter`、`Space`、`Tab`、`Esc` 与方向键一律返回 `KeyEventResult.ignored`，由 OS 输入法优先消费选词按键，绝不误触发提交或抢夺候选框。
4. **跨端自适应补全浮层（`[[`、`#`、`@`、`/`）**：
   - 仅在 `selection.isCollapsed` 时执行只读本地 `index/fts.db` 模糊过滤（支持在 `[[` 后直接键入中文关键词即时筛选，绝不修改未提交文本）；
   - **桌面端（Win/macOS/Linux）**：采用 Flutter **`OverlayPortal`** 锚定光标矩形，上下错开偏移以避让系统 IME 候选条，窗口缩放或跨屏 DPI 变化时重算位置；
   - **移动端（Android/iOS）**：不挂易遮挡的浮动气泡，改为固定贴合 `MediaQuery.viewInsetsOf(context).bottom` 上沿的**键盘附属候选条**（热区 `≥ 44dp`）；
   - 用户选中候选项时，通过单次原子 `TextEditingValue(text: ..., selection: ..., composing: TextRange.empty)` 完成替换。
5. **无 WYSIWYG 陷阱的轻量预览**：采集流保持单框 0ms 直录；长日记/笔记详情在桌面端提供可选**左右分栏实时预览**（`150ms` 防抖 BFM → `BlinkHtmlWidgetFactory`）或点击编辑切换，移动端采用简洁的**编辑 / 预览**双页签切换。

圆角与尺寸基准：点击热区移动端不小于 `44×44dp`、桌面端不小于 `32×32px`；主输入胶囊与主按钮圆角 `12px～20px`，边注与回响卡片圆角 `10px`，侧栏条目圆角 `8px`。

<a id="semantic-html"></a>
## 3. 双表面高表现力 HTML 宿主令牌绑定与排版契约

为在保持列表 60/120fps 顺滑体验的同时释放外置/直连 AI 生成杂志级卡片与整页 HTML 报告的表现力，BLINK 执行经纯 Dart `packages/blink_sanitizer` 白名单净化后的**双表面渲染规范**（[DEC-024](decisions.md#dec-024)、[标签与生产者契约](design/data-and-sync.md#generative-html)）：

### 3.1 Surface 1：行内流卡片、伴读块与轻综述（100% 纯 Flutter 原生组件树）

由 `flutter_widget_from_html_core 0.17.4` + `fwfh_svg 0.16.1` + `fl_chart 1.3.1` + `BlinkHtmlWidgetFactory` 在五端纯原生构建（零 WebView 进程开销，适用于时间流、`super_sliver_list` 伴读正文、边注轨与轻卡片）：

- **三态主题令牌动态映射**：`packages/blink_sanitizer` 剥离全部硬编码前景/背景色；`customStylesBuilder` 将标准 HTML5 标签与受控原生组件动态绑定至当前 **Day / Sepia / Dark** 令牌，内联几何 SVG 使用 `currentColor` 与主题调色盘，切主题零闪烁。
- **杂志级原生 `<blink-*>` 组件映射**：
  - **`<blink-grid>` & `<blink-card>`（自适应 Bento 网格）**：在容器宽度 `≥ 640px` 自动排为双栏等距网格，`< 640px` 自动折为单栏纵向堆叠，底色 `surface.aiDerived` 配 `1px` `border.hairline`，零横向溢出；
  - **`<blink-metric>` / `<blink-timeline>` / `<blink-compare>` / `<blink-chart>`**：直接映射为原生数字指标卡（`tabular-nums`）、纵向演进时间轴、观点对照卡与基于 `fl_chart` 的原生折线/柱状/饼图/雷达图；
  - **跨行列合并表格、`Callout` 与 `<details>` 原文抽屉**：完整支持 `rowspan`/`colspan`（窄屏仅在表格容器内部平滑横滑）、`<aside class="callout callout-insight|tension">` 与 `<details>`/`<summary>` 折叠原文引语抽屉；
  - **`<blink-ref>` 内联可点击溯源胶囊**：渲染为紧凑圆角胶囊（`12px`、`tabular-nums`、浅 `accent.primary` 底色，移动端扩展垂直热区）；
  - **`<blink-embed kind="ai">` 只读嵌入槽（用户 BFM 专用）**：若目标为 Surface 1 卡片则原地展开 `surface.aiDerived` 只读卡；若目标为 Surface 2 整页则渲染紧凑预览横幅（标题、`✦ AI 派生` 来源、生成时间、摘要与唯一按钮“打开完整页面”），绝不在滚动列表内嵌套 WebView。

### 3.2 Surface 2：AI 生成整页 HTML 视图（按需零 JS 离线 CSP 沙盒）

仅在用户主动打开整页深度综述、全书视觉报告或专题仪表盘（`render_surface = "surface2_sandbox"`、`artifact_html`）时于全屏/独立窗口按需挂载：

- **五端沙盒引擎与 Linux 优雅降级**：Windows / macOS / Android / iOS 采用 `flutter_inappwebview 6.1.5`（无痕模式、Windows 通道隔离 `userDataFolder`、自定义协议 `blink-blob://` 离线供图）；Linux 采用 `desktop_webview_window 0.4.3` 动态链接系统 `libwebkit2gtk-4.1-0` + `libsoup-3.0-0`（[DEC-026](decisions.md#dec-026)），经临时回环 `127.0.0.1` 单次令牌服务下发 `Cache-Control: no-store` 与离线 CSP；若目标 Linux 宿主机缺少 WebKitGTK，或 `#private` 在 `SPK-06` 审计中未满足零落盘条件，自动优雅降级为 **Surface 1 原生视图（`view_html`）** 并在顶栏提供“在系统浏览器打开本地镜像 `.html`”按钮。
- **零脚本、零外链与实时主题注入**：浏览器强制执行 `default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src blink-blob: data:; font-src 'self' data:`，物理阻断全部外网请求；宿主切换 Day / Sepia / Dark 时通过实时注入 `--blink-*` CSS 变量表瞬间同步配色，无需重新生成 HTML。
- **零 JS `<blink-ref>` 原生回跳**：页面内所有 `<blink-ref>` 已由 `packages/blink_sanitizer` 编译为 `<a class="blink-ref" href="blink-ref://<kind>/<id>?anchor=...">`，由 WebView 导航拦截回调（`shouldOverrideUrlLoading` / `setOnUrlRequestCallback`）直接交回 Flutter 唤起完全一致的**原文预览浮层 / 半屏抽屉**。

<a id="views"></a>
## 4. 核心视图与显式状态交互契约

### 4.1 瞬时采集流、BFM v1 编辑器与文件管理（Inbox / Stream）

- **输入框交互**：
  - **桌面端**：主工作区顶部居中（限宽 `700px`），默认单行高 `48px`，随换行平滑增高（最高占视口 `45%` 后内部滚动）；左下角紧凑排列 `#标签`（含快捷点选 `#private`）、`[[引用]]`、`@书目`、附件/书页图导入与语音录入图标，右下角为唯一主按钮“记录”（`Ctrl/Cmd + Enter` 提交，纯 `Enter` 换行；长日记支持一键展开全屏/分栏预览）。
  - **移动端**：时间线直通底部常驻输入栏；左侧为 BFM 文本输入胶囊，右侧未输入文字时显示**“按住说话”麦克风主按钮**与**“拍书页”相机图标**，输入文字后切换为发送按钮；输入 `[[` / `#` / `@` / `/` 时在软键盘上沿滑出紧凑候选条。
- **采集流卡片类型**（简单文本条走 `package:markdown` AST 直出快速通道，复杂块/表格/嵌入走 `BlinkHtmlWidgetFactory`）：
  - **文本与 BFM 闪念卡片**：顶部一行元信息（相对/精确时间、同步微标、`#private` 青绿锁标），正文展示高亮 `==mark==`、`#标签`、`[[ref]]` 胶囊、可勾选的 `- [ ]`/`- [>]` 内生待办及 `![[ai:...]]` 只读嵌入卡；悬停或“⋯”展开编辑、分栏预览、提取待办、复制、移入 30 天回收站。
  - **语音笔记卡片**：展示原生播放条（播放/暂停、波形进度、时长，支持正文 `@t[mm:ss]` 点击跳转）；若外置/API 已回填 `ai_entry_enrichments` 则默认展示去口头禅整理稿并可一键展开原始逐字稿 `verbatim_transcript_text`；未转写时如实显示“录音已存本机 · 待转写（可经外置 AI 或直连 API 补齐）”。
  - **纸质书页三联卡片**：书页原图缩略图（点开缩放原图）+ 派生 OCR 引文（未识别时安静提示“待识别引文 · 支持外置 OCR 或手动摘录”）+ 用户随附 BFM 感悟/语音 + 书目胶囊。
  - **稍后读长文卡片**：展示纯 Dart Isolate 抽取的文章标题、来源域名、预计阅读时长与附注；点击进入原生块级伴读视图。

### 4.2 原生伴读工作台（PDF & Unified Block AST Reader）

- **统一阅读顶栏**：返回书库、当前书名与章节/页码进度（如 `第 4 章 · 62%` 或 `128 / 412 页`），右侧依次为目录大纲、页内搜索、全书综述入口、排版设置（块级阅读器调字号/行距/日·纸·夜主题；PDF 调适应页宽/裁白边/缩放）与右侧边注栏开关（桌面）或边注计数按钮（移动）。
- **受控语义 HTML 块级渲染与零漂移划选锚定**：
  - 长文与 EPUB 在 `super_sliver_list` 中由 `flutter_widget_from_html_core` 原生渲染复杂表格、提示框、上下标与 `ruby` 注音，外层 `SelectableRegion` 经 Dart `.runes` 映射器生成零漂移 `block_id + char_offset` 锚点；
  - `pdfrx` 渲染 PDF 并在发现扫描无文本层页面时于顶栏下方展示非阻塞 `missing_ocr` 说明条，允许直接框选矩形区域挂载边注；
  - 划选松手后弹出轻量浮动条：**四色高亮圆点**、**写边注**、**复制引文**（开启可选内置直连 AI 时额外显示**问 AI**）。
- **边注轨、跨时空回响与全书综述（Marginalia, Echoes & Book Synthesis）**：
  - 顶部三标签：**本书边注（N）**、**回响（Echoes）**、**全书综述**。
  - **本书边注**：按正文出现顺序排列，摘录引文点击回跳原处并闪烁高亮，中部为用户手写 BFM 批注，下方若有已固化的伴读问答折叠于 `✦ 伴读问答（可展开）`。
  - **回响（Echoes）**：展示外置 AI 写入的 1～5 条跨时空关联卡片（`✦ 回响 · <历史年月>` + 关系标 `共鸣 / 张力 / 演进`），提供“打开原记录”与“插入 `[[ref]]` 到当前边注”；无匹配时安静留白。
  - **全书综述**：默认展示 Surface 1 原生摘要卡片，存在 Surface 2 整页报告（`artifact_html`）时提供单主按钮“展开完整视觉报告”。

### 4.3 回顾、内生待办、双表面综述与可选内置 AI 对话视图

- **上下文侧栏 / 顶部分段**：切换**今日与待办**、**简报与整页综述**、**认知与原则账本**（设置中开启直连 OpenAI 兼容接口时额外显示**AI 对话**入口）。
- **今日与待办**：上半区为《晨间简报》Surface 1 卡片（支持点开 Surface 2 完整页），下半区为“今日聚焦 / 稍后意图 / 待确认 AI 行动建议（`ai_task_candidates`）”简洁列表；每条待办右侧必带来源胶囊点击回跳原处。
- **双表面综述与 `<blink-ref>` 原地核对交互**：
  - 简报、周报与专题页顶部固定展示 `✦ AI 派生 · <来源代理/模型名>`、生成时间、密级范围（`常规范围` 或 `🔒 含 #private · 本地生成`）及右上角 `原生卡片 / 完整整页 / Markdown 摘要` 切换开关。
  - **点击任意 `<blink-ref>`（Surface 1 原生胶囊或 Surface 2 `blink-ref://` 链接）**：不打断当前阅读流，**就地唤起不可篡改原文核对层**——桌面端与横屏平板弹出 `360px` 宽**原文预览浮层（Raw Provenance Popover，`Esc` 或点外部收起）**，手机竖屏弹出**半屏原文核对抽屉（Half-Sheet）**，完整呈现原始 BFM 闪念或原书高亮边注与时间，底部仅提供单一动作“跳至原记录 / 原书位置”；回收站目标呈柔和灰态并如实提示“原记录位于回收站（可查看）”。
- **认知与原则演进账本**：上方展示外置/直连 AI 提交的 `candidate` 原则新旧对比卡（附 `<details>` 证据与 `<blink-ref>` 胶囊），提供**确认纳入**、**编辑后纳入**与**忽略**；下方按主题展示已确认原则与沿 `supersedes_id` 展开的历史演进链。
- **可选内置直连 AI 对话与笔记提炼（Chat-to-Note）**：用户可在独立对话面板自由讨论或引用库内条目（私密上下文强制校验 `private_local` 端点）；对话结束后提供两个显式动作——① **保存为 AI 派生摘要卡**（入 `ai_syntheses`）；② **提炼为新原文笔记**（展示可编辑 BFM 预览，经用户确认后作为 `capture_origin = 'chat_promoted'` 的全新 `raw_entries` 落盘，绝不篡改任何既有笔记）。

### 4.4 设置：便携库、同步、外置 AI 扩展与直连接口页

设置页采用单层扁平细线分组（不套多层卡片），包含五组分类：

1. **单文件夹便携库与开放镜像**：清晰展示通道（`BLINK` 或 `BLINK Dev`）、`便携库目录（用户数据）`（`<BLINK_VAULT_DIR>`，已安装桌面端默认位于系统“文档”目录 `<Documents>\blink[-dev]`，源码构建默认位于 `.local/blink-dev/vault`；桌面端支持选择目录、切换、恢复默认目录与“导出一致性快照（`VACUUM INTO`）”，附“请勿将活态 `db/` 放入第三方网盘同步目录”提示，且当便携库位于 `OneDrive` 路径内时展示温和非阻塞提示而不强制重定向）、移动端已缓存 PDF/EPUB 体积明细与一键释放按钮，以及桌面端实时镜像（`.md` + `insights/*.html`）最近导出时间与“立即全量校对镜像”。
2. **多端同步（直连与异步中继）**：
   - **直连模式**：桌面端内嵌 `shelf` 同步开关、局域网 `mdns_dart` 发现状态、Tailscale 地址、一次性配对码与已配对设备吊销列表（支持接入无头 `blink sync serve` 节点）；
   - **WebDAV / S3 端到端加密中继**：端点配置、主密钥恢复码导出/导入（密钥仅存 OS 安全密钥库）、同步进度与默认开启的**“禁止通过 WebDAV/S3 中继 `#private`”**独立开关。
3. **外置 AI 扩展（CLI / MCP Server / Skills）**：显示内置 `blink` CLI 路径与桌面 loopback IPC 在线状态；提供一键复制或非破坏式写入 MCP 客户端配置（Claude Desktop / Claude Code / Cursor / Antigravity / Codex，默认硬锁 `--scope normal_only`）、一键安装/核验 5 套 `agentskills.io` `SKILL.md` 技能，以及三门限 `local_with_private` 本地令牌与 `--allow-capture` 收件箱开关（默认关闭）。
4. **可选直连 AI 接口（OpenAI 兼容，默认关闭）**：独立配置常规模型端点（`normal`）与私密本地端点（`private_local`，仅接受本机回环/局域网/Tailscale 地址），API Key 仅加密存入系统安全密钥库、永不落入便携库或回显明文；另含“清空并重算全部 AI 派生索引与 `index/fts.db`”二次确认维护按钮。
5. **阅读、BFM 编辑偏好与版本关于**：阅读字体/主题、BFM 自动补全与分栏预览默认行为、版本号、通道、安装身份、Git 短哈希、`应用本地目录`（`%LOCALAPPDATA%\<身份>` 等运行态/设置目录，与“便携库目录（用户数据）”清晰区分）与第三方开源许可清单（含 `DEC-026` Linux 动态系统库声明）。

### 4.5 全局连接、同步、解析与渲染显式状态规范

所有异步、网络与降级边界均按统一状态契约呈现，严禁把异常或未就绪状态伪装成“暂无内容”（`INV-11`）：

| 状态场景 | 界面呈现位置与视觉符号 | 文案与用户可执行动作 |
| --- | --- | --- |
| **纯离线暂存（Offline）** | 桌面图标栏底部 / 移动顶栏右侧琥珀色离线胶囊；新建条目右下角空心小圆环 | 提示“当前离线：新记录已安全保存在本机（N 项待同步），联网后自动同步”；采集、CJK 检索与已缓存伴读 100% 可用 |
| **同步对端休眠（Peer Asleep）** | 顶栏同步胶囊呈柔和琥珀态（仅直连模式桌面离线时） | 提示“主力电脑当前离线：N 项变更已安全排队，电脑唤醒后自动同步”，并提供入口“了解/启用加密 WebDAV/S3 异步中继” |
| **队列同步中（Syncing）** | 顶栏/侧栏轻量旋转同步弧线 | 明确区分通道：“正在经局域网/Tailscale 同步（剩余 N 项）”或“正在经 E2EE 中继同步…”；绝不锁定输入与页面切换 |
| **同步冲突待裁定（Conflict）** | 顶栏“1 条同步冲突待处理”入口，条目带黄色双箭头标 | 左右（桌面）或上下（移动）并排对比差异，提供“保留本机”“采用远端”“合并保存后确认”三项选择，裁定前两份全文完整保留 |
| **私密隔离与本地闭锁（`#private` / `privacy_blocked`）** | 条目头部青绿锁标 `🔒 私密`；触发闭锁时内嵌浅红单行提示 | 常规态说明“仅本机与受控本地模型可访问，对外置默认 MCP 不可见”；若直连本地端点离线或越界直接报 `privacy_blocked`（引导检查 `private_local` 配置，绝不回退云端） |
| **扫描版 PDF 无文本层（`missing_ocr`）** | PDF 阅读顶栏下方浅暖色信息条（可收起） | 提示“当前页面为扫描图像、暂无可检索文本层：你仍可直接框选区域高亮记边注，或交外置 OCR 工具经 CLI/MCP 补齐全文检索” |
| **Linux 缺失 WebKitGTK 降级** | Surface 2 视图顶部浅灰单行提示 | 提示“当前系统未安装 WebKitGTK 4.1，已自动切回纯原生卡片视图（Surface 1）”，右侧提供“在系统浏览器打开本地镜像 `.html`”与安装指引 |
| **抓取 / 解析 / 磁盘错误（Error）** | 条目内嵌浅红底单行说明条（配感叹号图标） | 写明具体错误码与原因（如“目标站点需要登录或依赖动态脚本（`anti_bot_or_paywall`）”“磁盘空间不足”），提供“重试”“系统浏览器打开”或“粘贴正文导入” |
