# M4 多端同步、OS 安全密钥库与 Android 适配六维选型研究（2026-11-27）

本记录按[开源选型规则](../dev-rules/sources-and-safety.md#oss-policy)补齐 M4 阶段落地前的实测六维查证（查询日期：2026-11-27 UTC+8，7 天依赖冷却基线 `<= 2026-11-20`，全量包经 pub.dev 与 OSV 漏洞库实时核验，0 已知漏洞），细化并更新 [DEC-023](../decisions.md#dec-023) 的具体包落位，对应有效决定见 [DEC-032](../decisions.md#dec-032)。

<a id="overview"></a>
## 1. 结论总览

在不引入任何未登记弱传染（`MPL-2.0`/`LGPL`）依赖、不新增第三方原生 Flutter 插件、不改动 Linux CI 依赖环境的前提下，M4 采用最精简的 5 个纯 Dart 宽松许可包叠加既有 `win32 6.4.0` 与零插件 Android `MethodChannel`：

1. **局域网 mDNS 发现用 `mdns_dart 2.2.2`（MIT，0 依赖）替代 `bonsoir`**：实时拆解传递依赖树发现 `bonsoir 7.1.6` 经 `bonsoir_linux 7.1.1` 拖入未登记的 `MPL-2.0` 包 `dbus 0.8.1`，且 `bonsoir` 强绑定 Flutter 无法用于纯 Dart 无头 `blink sync serve`；`mdns_dart 2.2.2` 纯 Dart 零依赖、同时支持广播与发现，可在 Windows、Android 与 `dart build cli` 统一复用。
2. **OS 原生安全密钥库（`INV-08`）采用 Win32 DPAPI + Android Keystore `MethodChannel` 替代 `flutter_secure_storage`**：`flutter_secure_storage 11.2.0` 的 Linux 子包在 CMake 中强依赖系统 `libsecret-1-dev`（直接破坏现有 Linux CI）并拖入 `path_provider` / `jni` 构建钩子；Windows 直接复用已锁定的 `win32 6.4.0` 调用 `CryptProtectData` / `CryptUnprotectData` 附通道专属熵存至 `<dataRoot>/credentials/*.dpapi`，Android 在 `MainActivity.kt` 通过系统内置 `AndroidKeyStore` AES-256-GCM 加密存至 `<noBackupFilesDir>/blink[-dev]/credentials/*.enc`，Linux/macOS 提供通道隔离的 `0600` 作用域回退。
3. **E2EE WebDAV / S3 异步中继采用纯 Dart `dart:io` `HttpClient` + `xml 7.1.0` + `crypto 3.0.8`**：跳过拖入 `dio` 的 `webdav_client_plus 3.0.0` 与拖入 16 个以上 `aws_common` 传递包的 `aws_signature_v4 0.6.13`，以约 300 行纯 Dart 实现 WebDAV 与 AWS SigV4 客户端，精确掌控超时、脱敏与 `#private` 零出境校验。
4. **Android 离线基线与动态 NDK 选择**：在 `apps/blink_client/android/app/build.gradle.kts` 动态选取 `flutter.installedNdkVersions` 中最高已装 NDK 版本，绕开 Flutter 3.50 默认硬编码缺失 NDK 28 引发的 CMake 报错；通过 `blink` / `blinkDev` Gradle Flavors 与 `android:allowBackup="false"` 实现双通道隔离，并经统一 `MethodChannel("io.github.chialecode.blink/platform")` 提供沙盒路径、SAF 文件选择、`WifiManager.MulticastLock` 与 Keystore 能力。

<a id="sync-deps"></a>
## 2. M4 同步与加密依赖六维查证

全部条目于 2026-11-27 UTC+8 通过官方 pub.dev API 与 OSV 数据库核验，满足 `DEC-007` 满 7 天冷却期与宽松许可要求：

| 组件与来源 | 评估版本与发布日期（UTC） | 维护状态与 OSV | 许可证（直接 / 传递） | 五端 / CLI / 离线适配 | 集成成本与结论 |
| --- | --- | --- | --- | --- | --- |
| `shelf`（`pub.dev/packages/shelf`，Dart 官方团队） | `1.4.3`（2026-10-16，41 天） | 活跃，0 OSV 漏洞 | BSD-3-Clause / 全宽松 | 五端 + `dart build cli` 全纯 Dart 离线可用 | 已锁定于 `pubspec.lock`；**采用**（直连同步 HTTP/SSE 服务端） |
| `shelf_router`（`pub.dev/packages/shelf_router`，Dart 官方团队） | `1.1.5`（2026-10-16，41 天） | 活跃，0 OSV 漏洞 | Apache-2.0 / `http_methods 1.1.1` Apache-2.0 | 五端 + CLI 全纯 Dart | 零原生构建成本；**采用**（REST 路由分发） |
| `cryptography`（`pub.dev/packages/cryptography`） | `2.9.0`（2025-11-21，370 天） | 稳定维护，0 OSV 漏洞 | Apache-2.0 / 全已锁定宽松依赖 | 五端 + CLI 纯 Dart `DartXchacha20.poly1305Aead` 与 `Hkdf`（不引入 `cryptography_flutter`） | 零原生插件，包体增量极小；**采用**（Channel B E2EE AEAD 与 HKDF） |
| `xml`（`pub.dev/packages/xml`） | `7.1.0`（2026-09-27，60 天） | 活跃，0 OSV 漏洞 | MIT / `petitparser 7.1.0` MIT（60 天） | 五端 + CLI 纯 Dart | 同时服务于 WebDAV `PROPFIND`、S3 `ListObjectsV2` 及后续 M5 EPUB；**采用** |
| `mdns_dart`（`pub.dev/packages/mdns_dart`） | `2.2.2`（2026-08-14，104 天） | 稳定维护，0 OSV 漏洞 | **MIT / 0 传递依赖** | Windows / Android / macOS / Linux / iOS / `dart build cli` 全纯 Dart，同时支持广播与发现 | 零原生插件、零 `MPL-2.0`；**采用并替代 `bonsoir`** |
| `args`（`pub.dev/packages/args`，Dart 官方团队） | `2.7.0`（2025-03-12，624 天） | 活跃，0 OSV 漏洞 | BSD-3-Clause / 0 传递依赖 | 纯 Dart CLI | 已锁定于 `pubspec.lock`；**采用**（`packages/blink_cli` `blink sync serve`） |
| `bonsoir`（`pub.dev/packages/bonsoir`） | `7.1.6`（2026-10-25，32 天） | 活跃，0 OSV 漏洞 | MIT 直接 / **`bonsoir_linux 7.1.1` 传递 `dbus 0.8.1`（`MPL-2.0`）** | 强绑定 Flutter，无法用于纯 Dart CLI，且 Windows 含原生 C++ 插件 | **拒绝（`DEC-007` 许可红线与 CLI 不兼容）** |
| `flutter_secure_storage`（`pub.dev/packages/flutter_secure_storage`） | `11.2.0`（2026-09-16，71 天） | 活跃，0 OSV 漏洞 | BSD-3-Clause / Linux 依赖系统 `libsecret-1` CMake + `path_provider` / `jni` | Linux CI 缺少 `libsecret-1-dev` 时直接编译失败 | **跳过**，改用 Win32 DPAPI + Android Keystore `MethodChannel` |
| `webdav_client_plus`（`pub.dev/packages/webdav_client_plus`） | `3.0.0`（2026-10-19，38 天） | 活跃，0 OSV 漏洞 | Apache-2.0 / 拖入 `dio 5.11.1` + `xml` | 纯 Dart | 仅需 6 个 WebDAV 动词，自写约 180 行 `dart:io` + `xml` 更可控且零 `dio` 冗余；**跳过** |
| `aws_signature_v4`（`pub.dev/packages/aws_signature_v4`） | `0.6.13`（2026-07-31，118 天） | 活跃，0 OSV 漏洞 | Apache-2.0 / 经 `aws_common 0.7.16` 拖入 16+ 传递包 | 纯 Dart | 自写约 120 行纯 Dart SigV4 复用既有 `crypto 3.0.8` 并通过官方测试向量校验；**跳过** |
| `path_provider` / `file_picker` | `2.1.6` / `13.4.0`（`13.4.1` 未满 7 天） | 活跃，0 OSV 漏洞 | BSD-3-Clause / MIT（拖入 `jni`、`jni_flutter` 或 8 个联邦插件） | 仅 Flutter | Android 侧约 15 行路径 + 70 行 SAF `MethodChannel` 零额外插件；**跳过** |

<a id="os-keystore"></a>
## 3. OS 原生安全密钥库架构边界（`INV-08`）

为保证 `<BLINK_VAULT_DIR>` 单文件夹便携库内绝对零明文凭据，同时避免引入破坏 Linux CI 的原生插件，`apps/blink_client/lib/platform/secret_store.dart` 定义统一 `BlinkSecretStore` 接口（`read` / `write` / `delete` / `deleteAllForChannel`）：

| 平台 | 实现方案 | 加密与隔离机制 | 密文落盘位置（严禁位于 `<BLINK_VAULT_DIR>` 内） |
| --- | --- | --- | --- |
| **Windows** | `WindowsDpapiSecretStore`（复用已锁定 `win32 6.4.0` `CryptProtectData` / `CryptUnprotectData`） | 当前用户范围 DPAPI + `CRYPTPROTECT_UI_FORBIDDEN` + 通道与键名绑定熵 `blink-dpapi-v1:<channel>:<key>`；错误通道熵解封必败；原生缓冲区释放前清零并调用 `LocalFree` | `<dataRoot>/credentials/<key>.dpapi`（同目录 `.blink-tmp` + `flushSync` + 原子重命名） |
| **Android** | `AndroidKeystoreSecretStore` + `MainActivity.kt` `MethodChannel("io.github.chialecode.blink/platform")` | 系统内置 `AndroidKeyStore` 硬件支持 AES-256-GCM 密钥（别名 `blink_secret_key_<channel>`），随机 12 字节 IV + AAD 绑定 `<channel>:<key>` | `<noBackupFilesDir>/<channel>/credentials/<key>.enc`（排除系统自动云备份且独立于 `<AppFilesDir>/blink[-dev]` 沙盒库） |
| **Linux / macOS** | `ScopedFileFallbackSecretStore` | 通道与键名校验封装 + POSIX `0700`/`0600` 权限硬化，零 `libsecret-1-dev` 构建依赖，保证 Linux CI 100% 绿灯 | `<dataRoot>/credentials/<key>.secret` |
| **安静测试 / 冒烟** | `InMemoryBlinkSecretStore`（`BLINK_QUIET=1` 或测试注入） | 纯内存通道隔离映射，绝不触碰宿主机真实密钥库 | 无磁盘落盘 |

<a id="android-baseline"></a>
## 4. Android 构建链与插件兼容性实测记录

1. **既有已锁定依赖在 Android 上的实测结论**：
   - `sqlite3 3.9.1`：Native Assets 钩子默认下载经 SHA-256 校验的预编译 `libsqlite3.*.android.so`，无需本地编译 CMake/NDK。
   - `window_manager 0.7.0` / `tray_manager 0.9.0`（传递 `cnativeapi 0.6.2`）：无 Android Gradle 插件，由 `native_toolchain_c` 直接调用 NDK `clang++` 编译，零 CMake 依赖。
   - `win32 6.4.0` / `ffi 2.2.0`：全部 `DynamicLibrary.open` 惰性初始化且业务调用点均已由 `Platform.isWindows` 守卫，Android 构建无符号冲突。
2. **动态 NDK 选择与双通道 Flavors**：
   - `apps/blink_client/android/app/build.gradle.kts` 从 `flutter.installedNdkVersions` 中选择已安装的最高 NDK 版本（回退 `flutter.ndkVersion`），避免 Flutter 3.50 硬编码未装 NDK 版本时触发 `sdkmanager` 下载或无 CMake 报错。
   - 定义 `blink`（`io.github.chialecode.blink` / `BLINK`）与 `blinkDev`（`io.github.chialecode.blink.dev` / `BLINK Dev`）双风味，配合 `AndroidManifest.xml` 中 `android:allowBackup="false"` 与 `CHANGE_WIFI_MULTICAST_STATE` 权限，实现 Android 双通道应用与数据彻底隔离。
   - 移动端按[数据设计](../design/data-and-sync.md#layers)关闭桌面 `MirrorExporter`，仅在主动扫描局域网同步节点期间按需获取并立即释放 `WifiManager.MulticastLock`。
