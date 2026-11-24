# 教训

开发中踩过、值得后来者避开的坑。每条：**规则** → 原因 → 证据（PR 号或日期）→ 出现次数。出现 3 次的提升进[开发规则](docs/dev-rules/workflow.md#lessons)或 [AGENTS](AGENTS.md)，并从这里删除。对其他项目也适用的教训，去那些仓库开 issue 分享。

## 本机环境

- **Windows 上 Python 调子进程必须显式 `encoding="utf-8", errors="replace"`。** 本机 Python 的 ANSI 代码页可能是 cp936 且 UTF-8 模式关闭，`text=True` 遇到 UTF-8 输出会抛异常并让 `stdout=None`。证据：#2（2026-11-23）。出现 1 次。
- **在 Windows 上用 Python 改文本文件要保留原换行符。** `Path.write_text` 会把 `\n` 写成 `\r\n`，整个文件被改成 CRLF，`check_docs.py` 与源码匹配型测试随之失败。读写用字节（`read_bytes` / `write_bytes`）或 `newline=""`。证据：2026-11-24。出现 1 次。
- **从 Agent 命令里启动常驻程序要先脱离作业对象。** Agent 的命令沙箱结束时会结束作业里的全部进程，托盘常驻的开发版会被一起关掉；先经 `explorer.exe` 的 `Shell.Application.ShellExecute` 启动，不行再 `CREATE_BREAKAWAY_FROM_JOB`（已写进[开发版自动安装](docs/dev-rules/engineering.md#dev-install)）。证据：#2。出现 1 次。

## CI

- **Linux CI 跑 `flutter test` 前要装 GTK 3、X11、Xi 开发包。** 托盘/窗口插件在构建钩子里编译原生代码，缺头文件时 `flutter test` 直接失败（`pkg-config --cflags gtk+-3.0 x11 xi failed`）。证据：#2。出现 1 次。
- **测试里不要写死会过期的日期。** 固定的 Cookie 过期时间、证书有效期或“未来”日期到期后测试会突然失败；用相对当前时间计算。证据：2026-11-24 另一个项目的 CI。出现 1 次。
