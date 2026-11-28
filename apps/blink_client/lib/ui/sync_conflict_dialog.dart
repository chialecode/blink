import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';

/// Responsive dual-copy sync conflict resolution dialog (`INV-01`, `INV-05`).
///
/// Renders side-by-side (`>= 600px`) or stacked (`< 600px`) comparison panes
/// and offers:
/// - **保留本机** (`localBodyMd`)
/// - **采用远端** (`remoteBodyMd`)
/// - **合并保存后确认** (custom merged Markdown text)
class BlinkSyncConflictDialog extends StatefulWidget {
  const BlinkSyncConflictDialog({
    required this.sync,
    this.initialConflictId,
    super.key,
  });

  final BlinkSyncController sync;
  final String? initialConflictId;

  @override
  State<BlinkSyncConflictDialog> createState() =>
      _BlinkSyncConflictDialogState();
}

class _BlinkSyncConflictDialogState extends State<BlinkSyncConflictDialog> {
  final TextEditingController _mergeController = TextEditingController();
  String? _loadedConflictId;
  int _selectedIndex = 0;
  bool _resolving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    widget.sync.addListener(_onSyncChanged);
    _syncMergeTextFromCurrentConflict();
  }

  @override
  void didUpdateWidget(covariant BlinkSyncConflictDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sync, widget.sync)) {
      oldWidget.sync.removeListener(_onSyncChanged);
      widget.sync.addListener(_onSyncChanged);
    }
    if (oldWidget.initialConflictId != widget.initialConflictId) {
      _loadedConflictId = null;
      _syncMergeTextFromCurrentConflict();
    }
  }

  @override
  void dispose() {
    widget.sync.removeListener(_onSyncChanged);
    _mergeController.dispose();
    super.dispose();
  }

  void _onSyncChanged() {
    if (!mounted) {
      return;
    }
    _syncMergeTextFromCurrentConflict();
  }

  void _syncMergeTextFromCurrentConflict() {
    final conflicts = widget.sync.openConflicts;
    if (conflicts.isEmpty) {
      _loadedConflictId = null;
      return;
    }
    if (_loadedConflictId == null && widget.initialConflictId != null) {
      final idx = conflicts.indexWhere((c) => c.id == widget.initialConflictId);
      if (idx >= 0) {
        _selectedIndex = idx;
      }
    }
    final safeIndex = _selectedIndex.clamp(0, conflicts.length - 1);
    _selectedIndex = safeIndex;
    final conflict = conflicts[safeIndex];
    if (_loadedConflictId == conflict.id) {
      return;
    }
    _loadedConflictId = conflict.id;
    _mergeController.text =
        '${conflict.localBodyMd}\n\n---\n\n${conflict.remoteBodyMd}';
  }

  Future<void> _resolve(Future<SyncConflict?> Function() action) async {
    if (_resolving) {
      return;
    }
    setState(() {
      _resolving = true;
      _errorText = null;
    });
    try {
      await action();
      if (!mounted) {
        return;
      }
      _loadedConflictId = null;
      if (widget.sync.openConflicts.isEmpty) {
        Navigator.of(context).pop();
      } else {
        setState(() {
          if (_selectedIndex >= widget.sync.openConflicts.length) {
            _selectedIndex = widget.sync.openConflicts.length - 1;
          }
          _syncMergeTextFromCurrentConflict();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorText = '保存冲突处理结果失败：$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _resolving = false);
      }
    }
  }

  static String _formatLocalTime(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final dialogMaxWidth = viewportWidth >= 720 ? 780.0 : viewportWidth - 24;

    return Dialog(
      key: const Key('sync_conflict_dialog'),
      backgroundColor: tokens.canvas,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogMaxWidth,
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: ListenableBuilder(
          listenable: widget.sync,
          builder: (context, _) {
            final conflicts = widget.sync.openConflicts;
            if (conflicts.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '同步冲突处理',
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '当前所有同步冲突均已处理完成。',
                      style: BlinkTypography.body(tokens),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('关闭'),
                      ),
                    ),
                  ],
                ),
              );
            }

            final safeIndex = _selectedIndex.clamp(0, conflicts.length - 1);
            final conflict = conflicts[safeIndex];

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.compare_arrows_rounded,
                        size: 20,
                        color: tokens.statusWarn,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '同步冲突处理（${safeIndex + 1} / ${conflicts.length}）',
                              style: BlinkTypography.sectionHeading(tokens),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '来源设备：${conflict.remoteDeviceName} · 处理前双方全文均完整保留，不会丢失内容',
                              style: BlinkTypography.metaLabel(tokens),
                            ),
                          ],
                        ),
                      ),
                      if (conflicts.length > 1) ...<Widget>[
                        IconButton(
                          tooltip: '上一条冲突',
                          onPressed: safeIndex > 0 && !_resolving
                              ? () => setState(() {
                                  _selectedIndex = safeIndex - 1;
                                  _loadedConflictId = null;
                                  _syncMergeTextFromCurrentConflict();
                                })
                              : null,
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        IconButton(
                          tooltip: '下一条冲突',
                          onPressed:
                              safeIndex < conflicts.length - 1 && !_resolving
                              ? () => setState(() {
                                  _selectedIndex = safeIndex + 1;
                                  _loadedConflictId = null;
                                  _syncMergeTextFromCurrentConflict();
                                })
                              : null,
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                      IconButton(
                        key: const Key('conflict_dialog_close_button'),
                        tooltip: '暂不处理',
                        onPressed: _resolving
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: tokens.borderHairline),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final sideBySide = constraints.maxWidth >= 560;
                        final localCard = _ConflictCopyPane(
                          key: const Key('conflict_local_pane'),
                          title: '本机版本',
                          subtitle: '当前设备保存的内容',
                          body: conflict.localBodyMd,
                          accentColor: tokens.accentPrimary,
                        );
                        final remoteCard = _ConflictCopyPane(
                          key: const Key('conflict_remote_pane'),
                          title: '远端版本（${conflict.remoteDeviceName}）',
                          subtitle: _formatLocalTime(conflict.createdAtUtc),
                          body: conflict.remoteBodyMd,
                          accentColor: tokens.statusWarn,
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (sideBySide)
                              Row(
                                key: const Key('conflict_compare_side_by_side'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Expanded(child: localCard),
                                  const SizedBox(width: 12),
                                  Expanded(child: remoteCard),
                                ],
                              )
                            else
                              Column(
                                key: const Key('conflict_compare_stacked'),
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  localCard,
                                  const SizedBox(height: 10),
                                  remoteCard,
                                ],
                              ),
                            const SizedBox(height: 14),
                            Text(
                              '手动合并内容（点击“合并保存后确认”后将保存为最新内容）',
                              style: BlinkTypography.controlLabel(tokens),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              key: const Key('conflict_merge_editor'),
                              controller: _mergeController,
                              enabled: !_resolving,
                              minLines: 4,
                              maxLines: 8,
                              style: BlinkTypography.editorBody(tokens),
                              decoration: InputDecoration(
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                contentPadding: const EdgeInsets.all(12),
                              ),
                            ),
                            if (_errorText != null) ...<Widget>[
                              const SizedBox(height: 10),
                              Text(
                                _errorText!,
                                style: BlinkTypography.metaLabel(
                                  tokens,
                                  color: tokens.statusErr,
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
                Divider(height: 1, color: tokens.borderHairline),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton(
                        key: const Key('conflict_keep_local_button'),
                        onPressed: _resolving
                            ? null
                            : () => _resolve(
                                () => widget.sync.resolveConflictKeepLocal(
                                  conflict,
                                ),
                              ),
                        child: const Text('保留本机'),
                      ),
                      OutlinedButton(
                        key: const Key('conflict_keep_remote_button'),
                        onPressed: _resolving
                            ? null
                            : () => _resolve(
                                () => widget.sync.resolveConflictKeepRemote(
                                  conflict,
                                ),
                              ),
                        child: const Text('采用远端'),
                      ),
                      FilledButton(
                        key: const Key('conflict_merge_save_button'),
                        onPressed: _resolving
                            ? null
                            : () => _resolve(
                                () => widget.sync.resolveConflictCustomMerge(
                                  conflict,
                                  _mergeController.text,
                                ),
                              ),
                        child: const Text('合并保存后确认'),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ConflictCopyPane extends StatelessWidget {
  const _ConflictCopyPane({
    required this.title,
    required this.subtitle,
    required this.body,
    required this.accentColor,
    super.key,
  });

  final String title;
  final String subtitle;
  final String body;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.borderHairline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.controlLabel(tokens),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: BlinkTypography.metaLabel(tokens)
                .copyWith(fontFeatures: BlinkTypography.tabularFigures),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: tokens.borderHairline),
          const SizedBox(height: 8),
          SelectableText(body, style: BlinkTypography.editorBody(tokens)),
        ],
      ),
    );
  }
}
