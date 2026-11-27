import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/application/wysiwyg_document.dart';
import 'package:blink_client/ui/markdown_editor.dart';

/// Feishu-style contextual resource sidebar for Long-Form Notes (`笔记`).
class BlinkNotesSidebar extends StatelessWidget {
  const BlinkNotesSidebar({
    required this.workspace,
    this.isDrawer = false,
    this.onItemSelected,
    this.onCollapse,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final bool isDrawer;
  final VoidCallback? onItemSelected;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        final notes = workspace.noteEntries;
        final sortedTags = workspace.noteTagCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

        return Column(
          key: const Key('notes_sidebar'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '笔记',
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                  ),
                  if (!isDrawer && onCollapse != null)
                    IconButton(
                      key: const Key('notes_sidebar_collapse_button'),
                      tooltip: '收起侧边栏 (Ctrl+\\)',
                      visualDensity: VisualDensity.compact,
                      onPressed: onCollapse,
                      icon: Icon(
                        Icons.keyboard_double_arrow_left_rounded,
                        size: 18,
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                key: const Key('new_note_button'),
                onPressed: workspace.hasOpenVault
                    ? () async {
                        final created = await workspace.createNote();
                        if (created != null) {
                          onItemSelected?.call();
                        }
                      }
                    : null,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('新建笔记'),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  _FilterPill(
                    pillKey: const Key('notes_filter_all'),
                    label: '全部',
                    count: workspace.totalNoteCount,
                    selected:
                        workspace.selectedNoteFilter == NoteFilterKind.all,
                    onTap: () => workspace.selectNoteFilter(NoteFilterKind.all),
                  ),
                  _FilterPill(
                    pillKey: const Key('notes_filter_private'),
                    label: '私密',
                    icon: Icons.lock_outline_rounded,
                    count: workspace.privateNoteCount,
                    accentOverride: tokens.privacyPrivate,
                    selected:
                        workspace.selectedNoteFilter ==
                        NoteFilterKind.privateOnly,
                    onTap: () =>
                        workspace.selectNoteFilter(NoteFilterKind.privateOnly),
                  ),
                  _FilterPill(
                    pillKey: const Key('notes_filter_trash'),
                    label: '回收站',
                    count: workspace.trashNoteCount,
                    selected:
                        workspace.selectedNoteFilter == NoteFilterKind.trash,
                    onTap: () =>
                        workspace.selectNoteFilter(NoteFilterKind.trash),
                  ),
                ],
              ),
            ),
            if (workspace.selectedNoteFilter == NoteFilterKind.tag &&
                workspace.selectedNoteTag != null) ...<Widget>[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    label: Text('#${workspace.selectedNoteTag}'),
                    backgroundColor: tokens.accentSubtle,
                    side: BorderSide(color: tokens.accentPrimary),
                    labelStyle: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.accentPrimary,
                    ),
                    onDeleted: () =>
                        workspace.selectNoteFilter(NoteFilterKind.all),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Divider(height: 1, color: tokens.borderHairline),
            Expanded(
              child: notes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _emptySidebarMessage(workspace.selectedNoteFilter),
                          textAlign: TextAlign.center,
                          style: BlinkTypography.metaLabel(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                      itemCount: notes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final entry = notes[index];
                        final selected = workspace.selectedNoteId == entry.id;
                        return _NoteListTile(
                          entry: entry,
                          selected: selected,
                          onTap: () {
                            workspace.selectNote(entry.id);
                            onItemSelected?.call();
                          },
                        );
                      },
                    ),
            ),
            if (sortedTags.isNotEmpty) ...<Widget>[
              Divider(height: 1, color: tokens.borderHairline),
              _NoteTagsSection(
                tags: sortedTags,
                selectedTag: workspace.selectedNoteFilter == NoteFilterKind.tag
                    ? workspace.selectedNoteTag
                    : null,
                onSelectTag: (tag) {
                  workspace.selectNoteFilter(NoteFilterKind.tag, tag: tag);
                },
              ),
            ],
          ],
        );
      },
    );
  }

  static String _emptySidebarMessage(NoteFilterKind filter) => switch (filter) {
    NoteFilterKind.privateOnly => '暂无私密笔记',
    NoteFilterKind.trash => '回收站为空',
    NoteFilterKind.tag => '该标签下暂无笔记',
    NoteFilterKind.all => '暂无笔记，点击上方新建',
  };
}

/// Main Long-Form Notes workspace:
/// - Desktop/Tablet (`!isMobile`): renders [BlinkMarkdownEditor] for the active
///   note or a calm empty state.
/// - Mobile (`isMobile`): renders a clean minimal 44px header and full-width
///   note list, pushing [BlinkMobileNoteEditorScreen] on selection or creation.
class BlinkNotesPage extends StatefulWidget {
  const BlinkNotesPage({
    required this.workspace,
    this.isMobile = false,
    this.onOpenDrawer,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    this.onOpenSearch,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final bool isMobile;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;
  final VoidCallback? onOpenSearch;

  @override
  State<BlinkNotesPage> createState() => _BlinkNotesPageState();
}

class _BlinkNotesPageState extends State<BlinkNotesPage> {
  bool _mobileEditorPushed = false;
  bool _autoOpenScheduled = false;
  bool _creatingMobileNote = false;

  @override
  void initState() {
    super.initState();
    widget.workspace.addListener(_onWorkspaceChanged);
    _schedulePendingMobileNoteOpen();
  }

  @override
  void didUpdateWidget(covariant BlinkNotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      oldWidget.workspace.removeListener(_onWorkspaceChanged);
      widget.workspace.addListener(_onWorkspaceChanged);
    }
    _schedulePendingMobileNoteOpen();
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_onWorkspaceChanged);
    super.dispose();
  }

  void _onWorkspaceChanged() {
    _schedulePendingMobileNoteOpen();
  }

  void _schedulePendingMobileNoteOpen() {
    if (!widget.isMobile ||
        _mobileEditorPushed ||
        _autoOpenScheduled ||
        _creatingMobileNote ||
        widget.workspace.pendingMobileNoteOpenId == null) {
      return;
    }
    _autoOpenScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoOpenScheduled = false;
      if (!mounted ||
          !widget.isMobile ||
          _mobileEditorPushed ||
          _creatingMobileNote) {
        return;
      }
      final pendingId = widget.workspace.consumePendingMobileNoteOpenId();
      if (pendingId == null) {
        return;
      }
      unawaited(_pushMobileNoteEditor(context, pendingId));
    });
  }

  Future<void> _pushMobileNoteEditor(
    BuildContext context,
    String entryId,
  ) async {
    if (_mobileEditorPushed || !mounted) {
      return;
    }
    _mobileEditorPushed = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BlinkMobileNoteEditorScreen(
            workspace: widget.workspace,
            initialEntryId: entryId,
          ),
        ),
      );
    } finally {
      _mobileEditorPushed = false;
    }
  }

  Future<void> _openMobileNoteEditor(
    BuildContext context,
    RawEntry entry,
  ) async {
    widget.workspace.clearPendingMobileNoteOpen();
    widget.workspace.selectNote(entry.id);
    await _pushMobileNoteEditor(context, entry.id);
  }

  Future<void> _createAndOpenMobileNote(BuildContext context) async {
    if (_creatingMobileNote) {
      return;
    }
    _creatingMobileNote = true;
    try {
      final created = await widget.workspace.createNote();
      if (created != null && context.mounted) {
        widget.workspace.clearPendingMobileNoteOpen();
        await _pushMobileNoteEditor(context, created.id);
      }
    } finally {
      _creatingMobileNote = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: widget.workspace,
      builder: (context, _) {
        if (widget.isMobile) {
          return _buildMobileNotesList(context, tokens);
        }

        final selected = widget.workspace.selectedNote;
        if (selected != null) {
          return BlinkMarkdownEditor(
            workspace: widget.workspace,
            entry: selected,
            isMobile: false,
            onOpenEntry: (id) => unawaited(widget.workspace.openEntryById(id)),
            onTagTap: (tag) =>
                widget.workspace.selectNoteFilter(NoteFilterKind.tag, tag: tag),
            onExpandSidebar: widget.onExpandSidebar,
            showExpandSidebarButton: widget.showExpandSidebarButton,
          );
        }

        return _buildDesktopEmptyState(tokens);
      },
    );
  }

  Widget _buildDesktopEmptyState(BlinkColorTokens tokens) {
    final isTrash = widget.workspace.selectedNoteFilter == NoteFilterKind.trash;
    final hasAnyInList = widget.workspace.noteEntries.isNotEmpty;

    return ColoredBox(
      color: tokens.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.showExpandSidebarButton && widget.onExpandSidebar != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.centerLeft,
              child: IconButton(
                key: const Key('notes_sidebar_expand_button'),
                tooltip: '展开侧边栏 (Ctrl+\\)',
                visualDensity: VisualDensity.compact,
                onPressed: widget.onExpandSidebar,
                icon: Icon(
                  Icons.menu_open_rounded,
                  size: 18,
                  color: tokens.textSecondary,
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        isTrash
                            ? Icons.delete_outline_rounded
                            : Icons.article_outlined,
                        size: 40,
                        color: tokens.textMuted,
                      ),
                      const SizedBox(height: 14),
                      Text(
                        isTrash
                            ? (hasAnyInList ? '选择一条已删除的笔记查看或还原' : '回收站为空')
                            : (hasAnyInList ? '选择一篇笔记开始写作' : '还没有笔记'),
                        textAlign: TextAlign.center,
                        style: BlinkTypography.heroHeading(tokens),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isTrash ? '删除的笔记会在回收站保留 30 天，可随时还原。' : '也可以把小记一键转为长笔记',
                        textAlign: TextAlign.center,
                        style: BlinkTypography.body(
                          tokens,
                          color: tokens.textSecondary,
                        ),
                      ),
                      if (!isTrash) ...<Widget>[
                        const SizedBox(height: 18),
                        FilledButton.icon(
                          key: const Key('empty_new_note_button'),
                          onPressed: widget.workspace.hasOpenVault
                              ? () => unawaited(widget.workspace.createNote())
                              : null,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(hasAnyInList ? '新建笔记' : '新建第一篇笔记'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileNotesList(BuildContext context, BlinkColorTokens tokens) {
    final notes = widget.workspace.noteEntries;
    final filter = widget.workspace.selectedNoteFilter;
    final filterSuffix = switch (filter) {
      NoteFilterKind.all => null,
      NoteFilterKind.privateOnly => '私密',
      NoteFilterKind.trash => '回收站',
      NoteFilterKind.tag => '#${widget.workspace.selectedNoteTag ?? ''}',
    };

    return ColoredBox(
      color: tokens.canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            key: const Key('mobile_notes_header'),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: tokens.canvas,
              border: Border(
                bottom: BorderSide(color: tokens.borderHairline, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: widget.onOpenDrawer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '笔记',
                          style: BlinkTypography.sectionHeading(tokens),
                        ),
                        if (filterSuffix != null) ...<Widget>[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: filter == NoteFilterKind.privateOnly
                                  ? tokens.privacySubtle
                                  : tokens.accentSubtle,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              filterSuffix,
                              style: BlinkTypography.badge(
                                color: filter == NoteFilterKind.privateOnly
                                    ? tokens.privacyPrivate
                                    : tokens.accentPrimary,
                              ),
                            ),
                          ),
                        ],
                        if (widget.onOpenDrawer != null) ...<Widget>[
                          const SizedBox(width: 2),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: tokens.textSecondary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                if (widget.onOpenSearch != null)
                  IconButton(
                    key: const Key('mobile_notes_search_button'),
                    tooltip: '搜索',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: widget.onOpenSearch,
                    icon: Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: tokens.textSecondary,
                    ),
                  ),
                IconButton(
                  key: const Key('mobile_new_note_button'),
                  tooltip: '新建笔记',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: widget.workspace.hasOpenVault
                      ? () => unawaited(_createAndOpenMobileNote(context))
                      : null,
                  icon: Icon(
                    Icons.add_rounded,
                    size: 22,
                    color: tokens.accentPrimary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: notes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            filter == NoteFilterKind.trash
                                ? Icons.delete_outline_rounded
                                : Icons.article_outlined,
                            size: 36,
                            color: tokens.textMuted,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            filter == NoteFilterKind.trash ? '回收站为空' : '还没有笔记',
                            style: BlinkTypography.sectionHeading(tokens),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            filter == NoteFilterKind.trash
                                ? '删除的笔记会在回收站保留 30 天。'
                                : '也可以把小记一键转为长笔记',
                            textAlign: TextAlign.center,
                            style: BlinkTypography.body(
                              tokens,
                              color: tokens.textSecondary,
                            ),
                          ),
                          if (filter != NoteFilterKind.trash) ...<Widget>[
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              key: const Key('empty_new_note_button'),
                              onPressed: widget.workspace.hasOpenVault
                                  ? () => unawaited(
                                      _createAndOpenMobileNote(context),
                                    )
                                  : null,
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('新建第一篇笔记'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                    itemCount: notes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final entry = notes[index];
                      return _NoteListTile(
                        entry: entry,
                        selected: widget.workspace.selectedNoteId == entry.id,
                        isCard: true,
                        onTap: () =>
                            unawaited(_openMobileNoteEditor(context, entry)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen distraction-free mobile Markdown editor pushed from [BlinkNotesPage].
class BlinkMobileNoteEditorScreen extends StatelessWidget {
  const BlinkMobileNoteEditorScreen({
    required this.workspace,
    this.initialEntryId,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final String? initialEntryId;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Scaffold(
      key: const Key('mobile_note_editor_screen'),
      backgroundColor: tokens.canvas,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: workspace,
          builder: (context, _) {
            RawEntry? active = workspace.selectedNote;
            if (active == null && initialEntryId != null) {
              for (final item in workspace.noteEntries) {
                if (item.id == initialEntryId) {
                  active = item;
                  break;
                }
              }
            }
            return BlinkMarkdownEditor(
              workspace: workspace,
              entry: active,
              isMobile: true,
              onBack: () => Navigator.of(context).maybePop(),
              onOpenEntry: (id) async {
                await workspace.openEntryById(id);
                if (!context.mounted) {
                  return;
                }
                if (workspace.destination != BlinkNavDestination.notes) {
                  await Navigator.of(context).maybePop();
                } else {
                  workspace.clearPendingMobileNoteOpen();
                }
              },
              onTagTap: (tag) {
                workspace.selectNoteFilter(NoteFilterKind.tag, tag: tag);
                unawaited(Navigator.of(context).maybePop());
              },
            );
          },
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.pillKey,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.icon,
    this.accentOverride,
  });

  final Key pillKey;
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? accentOverride;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final accent = accentOverride ?? tokens.accentPrimary;
    final bg = selected
        ? (accentOverride != null ? tokens.privacySubtle : tokens.accentSubtle)
        : tokens.canvas;
    final fg = selected ? accent : tokens.textSecondary;

    return InkWell(
      key: pillKey,
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? accent : tokens.borderHairline,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: fg),
              const SizedBox(width: 3),
            ],
            Text(label, style: BlinkTypography.metaLabel(tokens, color: fg)),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: BlinkTypography.metaLabel(
                tokens,
                color: selected ? fg : tokens.textMuted,
              ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteListTile extends StatelessWidget {
  const _NoteListTile({
    required this.entry,
    required this.selected,
    required this.onTap,
    this.isCard = false,
  });

  final RawEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final bool isCard;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final title = WysiwygDocument.extractTitle(entry.bodyMd);
    final snippet = WysiwygDocument.extractSnippet(entry.bodyMd);
    final timestamp = _formatRelativeTime(entry.updatedAtUtc);

    return Material(
      color: selected
          ? tokens.accentSubtle
          : isCard
          ? tokens.sidebar
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: isCard
            ? BorderSide(color: tokens.borderHairline, width: 1)
            : BorderSide.none,
      ),
      child: InkWell(
        key: Key('note_list_item_${entry.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isCard ? 14 : 10,
            vertical: isCard ? 12 : 9,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BlinkTypography.controlLabel(tokens).copyWith(
                        color: selected
                            ? tokens.accentPrimary
                            : tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (entry.isPrivate) ...<Widget>[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 13,
                      color: tokens.privacyPrivate,
                    ),
                  ],
                ],
              ),
              if (snippet.isNotEmpty) ...<Widget>[
                const SizedBox(height: 3),
                Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                timestamp,
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textMuted,
                ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatRelativeTime(DateTime utc) {
    final local = utc.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(local.year, local.month, local.day);
    final diffDays = today.difference(entryDay).inDays;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');

    if (diffDays == 0) {
      final diffMins = now.difference(local).inMinutes;
      if (diffMins >= 0 && diffMins < 1) {
        return '刚刚';
      }
      return '$hh:$mm';
    }
    if (diffDays == 1) {
      return '昨天 $hh:$mm';
    }
    if (local.year == now.year) {
      return '${local.month}月${local.day}日';
    }
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  }
}

class _NoteTagsSection extends StatefulWidget {
  const _NoteTagsSection({
    required this.tags,
    required this.selectedTag,
    required this.onSelectTag,
  });

  final List<MapEntry<String, int>> tags;
  final String? selectedTag;
  final ValueChanged<String> onSelectTag;

  @override
  State<_NoteTagsSection> createState() => _NoteTagsSectionState();
}

class _NoteTagsSectionState extends State<_NoteTagsSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 16,
                    color: tokens.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '标签',
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...<Widget>[
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 112),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final tagEntry in widget.tags)
                      InkWell(
                        key: Key('notes_filter_tag_${tagEntry.key}'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => widget.onSelectTag(tagEntry.key),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: widget.selectedTag == tagEntry.key
                                ? tokens.accentSubtle
                                : tokens.canvas,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: widget.selectedTag == tagEntry.key
                                  ? tokens.accentPrimary
                                  : tokens.borderHairline,
                            ),
                          ),
                          child: Text(
                            '#${tagEntry.key} (${tagEntry.value})',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: widget.selectedTag == tagEntry.key
                                  ? tokens.accentPrimary
                                  : tokens.textSecondary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
