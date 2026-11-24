# NSIS 安装器选型记录（2026-11-24）

<a id="overview"></a>
## 1. 结论

Windows 安装包由 Inno Setup `7.1.1` 换成 NSIS `3.13`（用户决定见 [DEC-029](../decisions.md#dec-029)）。本记录按[开源选型规则](../dev-rules/sources-and-safety.md#oss-policy)补齐六维查证。构建期从官方下载固定版本的 `nsis-3.13.zip` 并核对 SHA-256，只用于生成安装包，不进入应用本身。安装包压缩用 zlib（见第 3 节）。

<a id="checks"></a>
## 2. 六维查证

查询日期 2026-11-24（UTC+8）。

| 维度 | 结论 |
| --- | --- |
| 组件与来源 | NSIS（Nullsoft Scriptable Install System）。官方网站 `https://nsis.sourceforge.io/`，发布文件在 SourceForge 项目 `nsis` 的 `NSIS 3/3.13/` 目录。所评估版本为 `3.13`，取官方便携包 `nsis-3.13.zip`，SHA-256 `ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8`（这份文件的 MD5 与 SourceForge 页面给出的一致，SHA-256 由同一份文件算出）。发布日期 `unknown`：本次只核对了文件本身，没有找到可引用的官方发布日期 |
| 版本与维护状态 | 包内 `COPYING` 的版权年份写到 2026，`3.13` 是近期版本；仓库是否活跃、缺陷修复节奏没有逐项查证，记为 `unknown` |
| 许可证 | 包内 `COPYING`：NSIS 源码、插件、头文件与安装器存根为 zlib/libpng 许可；zlib 压缩模块为 zlib/libpng；bzip2 模块为 bzip2 许可；LZMA 模块为 CPL-1.0，附“链接到它的代码不受 CPL 约束”的特别例外，但模块本身仍是 CPL。安装包内嵌的是存根加所选压缩模块的解压代码 |
| 五端/中文/离线适配 | 只用于 Windows 桌面端安装包，其他四端不受影响；中文界面用自带的 `SimpChinese` 语言文件，脚本以 UTF-8 编译；构建在首次下载后离线可用（缓存在 Git 忽略的 `.tools/nsis-3.13/`） |
| 集成成本与体积 | 便携包解压即用，不需要安装或管理员权限；`scripts/package.py` 负责下载、校验与调用 `makensis -WX`。同一份 Release 构建（约 28 MiB）实测安装包：solid LZMA 8.76 MiB、solid bzip2 10.8 MiB、solid zlib 11.5 MiB |
| 自研与适配边界 | 自研部分只有 `blink.nsi` 脚本与 `package.py` 里的胶水（文件清单生成、静默安装与回执）；安装、卸载、覆盖升级与运行中实例的处理都由安装演练与本机冒烟实测（见 [#20](https://github.com/chialecode/blink/issues/20) 的 PR） |

<a id="compression"></a>
## 3. 压缩方式

[许可证红线](../dev-rules/sources-and-safety.md#license-boundary)只允许 zlib 等宽松许可直接进入分发物，CPL-1.0 不在其中，弱传染许可也只登记了动态链接系统库的情形。LZMA 模块会随每个安装包分发，所以默认用 zlib：许可与存根相同，代价是安装包大约多 2.7 MiB（约 31%）。若以后要换回 LZMA，需要先在[有效决定](../decisions.md)登记 CPL-1.0 模块的分发义务再改。
