import 'package:material_ui/material_ui.dart';

import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/lifecycle.dart';

/// Root Flutter application for the BLINK M2 desktop shell.
class BlinkApp extends StatelessWidget {
  const BlinkApp({required this.controller, super.key});

  final DesktopLifecycleController controller;

  @override
  Widget build(BuildContext context) {
    final buildInfo = controller.buildInfo;
    final accent = buildInfo.isProductionChannel
        ? const Color(0xFF1D4ED8)
        : const Color(0xFFD97706);

    return MaterialApp(
      title: buildInfo.productName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: accent,
          surface: const Color(0xFFF8FAFC),
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F6FA),
      ),
      home: BlinkShellPage(controller: controller),
    );
  }
}

/// Placeholder desktop main shell displaying product identity, close-button
/// behavior settings, and build/installation About metadata.
class BlinkShellPage extends StatelessWidget {
  const BlinkShellPage({required this.controller, super.key});

  final DesktopLifecycleController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final buildInfo = controller.buildInfo;
        final settings = controller.settings;
        final dataRootPath = controller.paths.dataRoot.path;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            titleSpacing: 20,
            title: Row(
              children: [
                Text(
                  buildInfo.productName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(width: 12),
                _ChannelBadge(buildInfo: buildInfo),
              ],
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HeroCard(buildInfo: buildInfo),
                    const SizedBox(height: 16),
                    _SettingsCard(
                      settings: settings,
                      recoveredCorruptSettings:
                          controller.recoveredCorruptSettings,
                      onChanged: controller.updateCloseButtonBehavior,
                    ),
                    const SizedBox(height: 16),
                    _AboutCard(
                      buildInfo: buildInfo,
                      dataRootPath: dataRootPath,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.buildInfo});

  final BlinkBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    final isProd = buildInfo.isProductionChannel;
    final bgColor = isProd ? const Color(0xFFDBEAFE) : const Color(0xFFFEF3C7);
    final fgColor = isProd ? const Color(0xFF1E40AF) : const Color(0xFF92400E);
    final label = isProd ? '正式通道' : 'DEV 开发通道';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: fgColor,
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.buildInfo});

  final BlinkBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${buildInfo.productName} 桌面外壳已就绪',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '当前为 Windows 桌面骨架与双通道安装更新基线，提供按安装身份隔离的单实例控制管道、'
              '系统托盘常驻与安全退出序列。知识库、BFM 编辑器与多端同步将在后续阶段接入。',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.settings,
    required this.recoveredCorruptSettings,
    required this.onChanged,
  });

  final DesktopSettings settings;
  final bool recoveredCorruptSettings;
  final ValueChanged<CloseButtonBehavior> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('settings_section'),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '设置',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '点击窗口关闭按钮时',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
              ),
            ),
            const SizedBox(height: 10),
            SegmentedButton<CloseButtonBehavior>(
              key: const Key('close_behavior_toggle'),
              segments: const [
                ButtonSegment<CloseButtonBehavior>(
                  value: CloseButtonBehavior.hideToTray,
                  label: Text('隐藏到托盘'),
                ),
                ButtonSegment<CloseButtonBehavior>(
                  value: CloseButtonBehavior.exitApp,
                  label: Text('直接退出'),
                ),
              ],
              selected: <CloseButtonBehavior>{settings.closeButtonBehavior},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  onChanged(selection.first);
                }
              },
            ),
            if (recoveredCorruptSettings) ...[
              const SizedBox(height: 12),
              const Text(
                '检测到损坏的 desktop.json，已改名保留原文件并恢复默认设置。',
                key: Key('corrupt_settings_notice'),
                style: TextStyle(fontSize: 12.5, color: Color(0xFFB45309)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.buildInfo, required this.dataRootPath});

  final BlinkBuildInfo buildInfo;
  final String dataRootPath;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('about_section'),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '关于',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 12),
            _InfoRow(
              label: '版本',
              value: buildInfo.version,
              valueKey: const Key('about_version'),
            ),
            _InfoRow(
              label: '通道',
              value: buildInfo.channel,
              valueKey: const Key('about_channel'),
            ),
            _InfoRow(
              label: '安装身份',
              value: buildInfo.displayIdentity,
              valueKey: const Key('about_identity'),
            ),
            _InfoRow(
              label: '提交',
              value: buildInfo.shortGitSha,
              valueKey: const Key('about_git_sha'),
            ),
            _InfoRow(
              label: '数据目录',
              value: dataRootPath,
              valueKey: const Key('about_data_root'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: valueKey,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
