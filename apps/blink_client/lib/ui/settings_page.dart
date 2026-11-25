import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';

/// Flat hairline Settings page (`docs/ui.md` §4.4):
/// 1. Single-Folder Portable Vault & Open Mirror controls (including honest
///    `channel_mismatch` diagnostics, `VACUUM INTO` hot backup, FTS5 rebuild,
///    and immediate `.md` mirror export).
/// 2. Theme surface switcher (Day / Sepia / Dark / System) & close-button policy
///    preserving `Key('close_behavior_toggle')` and `Key('corrupt_settings_notice')`.
/// 3. About metadata card preserving `Key('about_*')`.
class BlinkSettingsPage extends StatefulWidget {
  const BlinkSettingsPage({required this.workspace, super.key});

  final BlinkWorkspaceController workspace;

  @override
  State<BlinkSettingsPage> createState() => _BlinkSettingsPageState();
}

enum _SurfaceChoice { system, day, sepia, dark }

class _BlinkSettingsPageState extends State<BlinkSettingsPage> {
  final TextEditingController _vaultPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _vaultPathController.text = widget.workspace.effectiveVaultDir.path;
  }

  @override
  void dispose() {
    _vaultPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.workspace,
        widget.workspace.lifecycle,
      ]),
      builder: (context, _) {
        final lifecycle = widget.workspace.lifecycle;
        final buildInfo = lifecycle.buildInfo;
        final settings = lifecycle.settings;
        final stats = widget.workspace.stats;
        final mirrorStatus = widget.workspace.mirrorStatus;
        final vaultMeta = widget.workspace.vault?.metadata;

        final currentSurface = switch (settings.surfaceMode) {
          null => _SurfaceChoice.system,
          DesktopSurfacePreference.day => _SurfaceChoice.day,
          DesktopSurfacePreference.sepia => _SurfaceChoice.sepia,
          DesktopSurfacePreference.dark => _SurfaceChoice.dark,
        };

        return SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Card(
                    key: const Key('settings_section'),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '设置',
                            style: BlinkTypography.sectionHeading(tokens),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            '界面主题表面（日间 / 暖纸 / 夜间 / 跟随系统）',
                            style: BlinkTypography.controlLabel(tokens),
                          ),
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: SegmentedButton<_SurfaceChoice>(
                              key: const Key('surface_mode_toggle'),
                              showSelectedIcon: false,
                              segments: const <ButtonSegment<_SurfaceChoice>>[
                                ButtonSegment<_SurfaceChoice>(
                                  value: _SurfaceChoice.system,
                                  label: Text('跟随系统'),
                                ),
                                ButtonSegment<_SurfaceChoice>(
                                  value: _SurfaceChoice.day,
                                  label: Text('日间'),
                                ),
                                ButtonSegment<_SurfaceChoice>(
                                  value: _SurfaceChoice.sepia,
                                  label: Text('暖纸'),
                                ),
                                ButtonSegment<_SurfaceChoice>(
                                  value: _SurfaceChoice.dark,
                                  label: Text('夜间'),
                                ),
                              ],
                              selected: <_SurfaceChoice>{currentSurface},
                              onSelectionChanged: (selection) {
                                if (selection.isEmpty) {
                                  return;
                                }
                                final next = switch (selection.first) {
                                  _SurfaceChoice.system => null,
                                  _SurfaceChoice.day =>
                                    DesktopSurfacePreference.day,
                                  _SurfaceChoice.sepia =>
                                    DesktopSurfacePreference.sepia,
                                  _SurfaceChoice.dark =>
                                    DesktopSurfacePreference.dark,
                                };
                                widget.workspace.setSurfaceMode(next);
                              },
                            ),
                          ),
                          const SizedBox(height: 18),
                          Divider(height: 1, color: tokens.borderHairline),
                          const SizedBox(height: 16),
                          Text(
                            '点击窗口关闭按钮时',
                            style: BlinkTypography.controlLabel(tokens),
                          ),
                          const SizedBox(height: 10),
                          SegmentedButton<CloseButtonBehavior>(
                            key: const Key('close_behavior_toggle'),
                            showSelectedIcon: false,
                            segments:
                                const <ButtonSegment<CloseButtonBehavior>>[
                                  ButtonSegment<CloseButtonBehavior>(
                                    value: CloseButtonBehavior.hideToTray,
                                    label: Text('隐藏到托盘'),
                                  ),
                                  ButtonSegment<CloseButtonBehavior>(
                                    value: CloseButtonBehavior.exitApp,
                                    label: Text('直接退出'),
                                  ),
                                ],
                            selected: <CloseButtonBehavior>{
                              settings.closeButtonBehavior,
                            },
                            onSelectionChanged: (selection) {
                              if (selection.isNotEmpty) {
                                lifecycle.updateCloseButtonBehavior(
                                  selection.first,
                                );
                              }
                            },
                          ),
                          if (lifecycle.recoveredCorruptSettings) ...<Widget>[
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
                  ),
                  const SizedBox(height: 16),
                  Card(
                    key: const Key('vault_settings_section'),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '单文件夹便携库与开放镜像',
                            style: BlinkTypography.sectionHeading(tokens),
                          ),
                          const SizedBox(height: 10),
                          if (widget.workspace.vaultErrorMessage !=
                              null) ...<Widget>[
                            Container(
                              key: const Key('vault_error_banner'),
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: tokens.statusErrSubtle,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: tokens.statusErr),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    Icons.error_outline_rounded,
                                    size: 18,
                                    color: tokens.statusErr,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      widget.workspace.vaultErrorMessage!,
                                      style: BlinkTypography.body(
                                        tokens,
                                        color: tokens.statusErr,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          _InfoRow(
                            label: '便携库目录',
                            value: widget.workspace.effectiveVaultDir.path,
                            valueKey: const Key('vault_path_value'),
                            valueStyle: BlinkTypography.monoValue(tokens),
                          ),
                          _InfoRow(
                            label: '通道锁',
                            value: vaultMeta == null
                                ? '${widget.workspace.expectedChannel.wireValue}（未打开）'
                                : '${vaultMeta.channel.wireValue} · v${vaultMeta.formatVersion}/${vaultMeta.schemaVersion}',
                            valueKey: const Key('vault_channel_lock'),
                            valueStyle: BlinkTypography.metaValue(
                              tokens,
                              tabular: true,
                            ),
                          ),
                          if (stats != null)
                            _InfoRow(
                              label: '资产概况',
                              value:
                                  '${stats.activeEntries} 条记录（含 ${stats.privateEntries} 条私密）· '
                                  '${stats.openTasks} 项待办 · ${stats.totalBlobs} 份附件（${formatByteSize(stats.totalBlobBytes)}）· '
                                  '${stats.trashedEntries} 条回收站',
                              valueKey: const Key('vault_stats_summary'),
                              valueStyle: BlinkTypography.metaValue(
                                tokens,
                                tabular: true,
                              ),
                            ),
                          _InfoRow(
                            label: '开放镜像',
                            value: mirrorStatus == null
                                ? '尚未导出'
                                : mirrorStatus.lastExportedAtUtc == null
                                ? '已就绪 · 水位线 seq ${mirrorStatus.lastExportedSeq}'
                                : 'seq ${mirrorStatus.lastExportedSeq} · '
                                      '${mirrorStatus.lastExportedAtUtc!.toLocal().toIso8601String().substring(0, 19)}',
                            valueKey: const Key('vault_mirror_status'),
                            valueStyle: BlinkTypography.metaValue(
                              tokens,
                              tabular: true,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: TextField(
                                  key: const Key('vault_path_input'),
                                  controller: _vaultPathController,
                                  style: BlinkTypography.monoValue(tokens),
                                  decoration: InputDecoration(
                                    labelText: '切换便携库路径',
                                    isDense: true,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: const Key('vault_pick_button'),
                                onPressed: () async {
                                  final ok = await widget.workspace
                                      .pickAndSwitchVaultDirectory();
                                  if (ok && mounted) {
                                    _vaultPathController.text =
                                        widget.workspace.effectiveVaultDir.path;
                                  }
                                },
                                child: const Text('选择目录'),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                key: const Key('vault_switch_button'),
                                onPressed: () async {
                                  final ok = await widget.workspace
                                      .switchVaultDirectory(
                                        _vaultPathController.text,
                                      );
                                  if (ok && mounted) {
                                    _vaultPathController.text =
                                        widget.workspace.effectiveVaultDir.path;
                                  }
                                },
                                child: const Text('切换'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              OutlinedButton.icon(
                                key: const Key('vault_backup_button'),
                                onPressed: widget.workspace.hasOpenVault
                                    ? () => widget.workspace.createHotBackup()
                                    : null,
                                icon: const Icon(
                                  Icons.backup_outlined,
                                  size: 16,
                                ),
                                label: const Text('VACUUM INTO 热备份'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('vault_rebuild_button'),
                                onPressed: widget.workspace.hasOpenVault
                                    ? () => widget.workspace
                                          .rebuildDerivedStores()
                                    : null,
                                icon: const Icon(
                                  Icons.refresh_rounded,
                                  size: 16,
                                ),
                                label: const Text('重建 FTS5 索引'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('vault_mirror_button'),
                                onPressed: widget.workspace.hasOpenVault
                                    ? () => widget.workspace.flushMirrorNow()
                                    : null,
                                icon: const Icon(
                                  Icons.drive_file_move_outlined,
                                  size: 16,
                                ),
                                label: const Text('立即导出 .md 镜像'),
                              ),
                              if (settings.customVaultPath != null)
                                TextButton(
                                  key: const Key('vault_reset_button'),
                                  onPressed: () async {
                                    final ok = await widget.workspace
                                        .resetToDefaultVault();
                                    if (ok && mounted) {
                                      _vaultPathController.text = widget
                                          .workspace
                                          .effectiveVaultDir
                                          .path;
                                    }
                                  },
                                  child: const Text('恢复默认目录'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '提示：请勿将运行中的 db/ 目录放入第三方网盘同步盘；网盘归档请使用 db/backups/ 热快照或 mirror/ 开放镜像。',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: tokens.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _AboutCard(
                    buildInfo: buildInfo,
                    dataRootPath: lifecycle.paths.dataRoot.path,
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
          children: <Widget>[
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
        children: <Widget>[
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
