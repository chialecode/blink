import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/lifecycle.dart';

/// Root Flutter application for the BLINK M2 desktop shell.
class BlinkApp extends StatelessWidget {
  const BlinkApp({
    required this.controller,
    this.themeMode = ThemeMode.system,
    super.key,
  });

  final DesktopLifecycleController controller;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    final buildInfo = controller.buildInfo;

    return MaterialApp(
      title: buildInfo.productName,
      debugShowCheckedModeBanner: false,
      theme: BlinkTheme.day(),
      darkTheme: BlinkTheme.dark(),
      themeMode: themeMode,
      home: BlinkShellPage(controller: controller),
    );
  }
}

/// Desktop main shell displaying product identity, close-button behavior
/// settings, and build/installation About metadata.
class BlinkShellPage extends StatelessWidget {
  const BlinkShellPage({required this.controller, super.key});

  final DesktopLifecycleController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final buildInfo = controller.buildInfo;
        final settings = controller.settings;
        final dataRootPath = controller.paths.dataRoot.path;

        return Scaffold(
          backgroundColor: tokens.canvas,
          appBar: AppBar(
            titleSpacing: 20,
            title: Row(
              children: [
                const BlinkBrandMark(key: Key('brand_mark')),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    buildInfo.productName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BlinkTypography.brandWordmark(tokens),
                  ),
                ),
                const SizedBox(width: 10),
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
    final tokens = BlinkColorTokens.of(context);
    final isProd = buildInfo.isProductionChannel;
    final bgColor = isProd ? tokens.accentSubtle : BlinkBrandColors.devPill;
    final fgColor = isProd
        ? tokens.accentPrimary
        : BlinkBrandColors.devPillText;
    final label = isProd ? '正式通道' : 'DEV 开发通道';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: BlinkTypography.badge(color: fgColor)),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.buildInfo});

  final BlinkBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${buildInfo.productName} 桌面外壳已就绪',
              style: BlinkTypography.heroHeading(tokens),
            ),
            const SizedBox(height: 8),
            Text(
              '当前为 Windows 桌面骨架与双通道安装更新基线，提供按安装身份隔离的单实例控制管道、'
              '系统托盘常驻与安全退出序列。知识库、BFM 编辑器与多端同步将在后续阶段接入。',
              style: BlinkTypography.body(tokens, color: tokens.textSecondary),
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
    final tokens = BlinkColorTokens.of(context);

    return Card(
      key: const Key('settings_section'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('设置', style: BlinkTypography.sectionHeading(tokens)),
            const SizedBox(height: 12),
            Text('点击窗口关闭按钮时', style: BlinkTypography.controlLabel(tokens)),
            const SizedBox(height: 10),
            SegmentedButton<CloseButtonBehavior>(
              key: const Key('close_behavior_toggle'),
              showSelectedIcon: false,
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
              Text(
                '检测到损坏的 desktop.json，已改名保留原文件并恢复默认设置。',
                key: const Key('corrupt_settings_notice'),
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.statusWarn,
                ),
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
    final tokens = BlinkColorTokens.of(context);

    return Card(
      key: const Key('about_section'),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关于', style: BlinkTypography.sectionHeading(tokens)),
            const SizedBox(height: 12),
            _InfoRow(
              label: '版本',
              value: buildInfo.version,
              valueKey: const Key('about_version'),
              valueStyle: BlinkTypography.metaValue(tokens, tabular: true),
            ),
            _InfoRow(
              label: '通道',
              value: buildInfo.channel,
              valueKey: const Key('about_channel'),
              valueStyle: BlinkTypography.metaValue(tokens),
            ),
            _InfoRow(
              label: '安装身份',
              value: buildInfo.displayIdentity,
              valueKey: const Key('about_identity'),
              valueStyle: BlinkTypography.metaValue(tokens),
            ),
            _InfoRow(
              label: '提交',
              value: buildInfo.shortGitSha,
              valueKey: const Key('about_git_sha'),
              valueStyle: BlinkTypography.monoValue(tokens, tabular: true),
            ),
            _InfoRow(
              label: '数据目录',
              value: dataRootPath,
              valueKey: const Key('about_data_root'),
              valueStyle: BlinkTypography.monoValue(tokens),
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
    required this.valueStyle,
  });

  final String label;
  final String value;
  final Key valueKey;
  final TextStyle valueStyle;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(label, style: BlinkTypography.metaLabel(tokens)),
          ),
          Expanded(
            child: SelectableText(value, key: valueKey, style: valueStyle),
          ),
        ],
      ),
    );
  }
}
