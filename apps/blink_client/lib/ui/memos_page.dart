import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/ui/bfm_preview_view.dart';

/// Feishu-style contextual resource sidebar for Quick Memos (`小记`).
class BlinkMemosSidebar extends StatelessWidget {
  const BlinkMemosSidebar({
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
        final activeFilter = workspace.selectedMemoFilter;
        final activeTag = workspace.selectedMemoTag;
        final sortedTags = workspace.memoTagCounts.entries.toList()
          ..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            if (byCount != 0) {
              return byCount;
            }
            return a.key.compareTo(b.key);
          });

        Widget navRow({
          required Key itemKey,
          required IconData icon,
          required String label,
          required bool selected,
          required VoidCallback onTap,
          int? count,
          Color? accentOverride,
        }) {
          final activeColor = accentOverride ?? tokens.accentPrimary;
          final fg = selected ? activeColor : tokens.textPrimary;
          final iconColor = selected
              ? activeColor
              : (accentOverride ?? tokens.textSecondary);

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: InkWell(
              key: itemKey,
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                onTap();
                onItemSelected?.call();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: selected ? tokens.accentSubtle : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 16, color: iconColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.controlLabel(tokens)
                            .copyWith(color: fg),
                      ),
                    ),
                    if (count != null) ...<Widget>[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style:
                            BlinkTypography.metaLabel(
                              tokens,
                              color: selected ? activeColor : tokens.textMuted,
                            ).copyWith(
                              fontFeatures: BlinkTypography.tabularFigures,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }

        return ColoredBox(
          color: tokens.sidebar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                height: 44,
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: tokens.borderHairline, width: 1),
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '小记',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.sectionHeading(tokens),
                      ),
                    ),
                    if (!isDrawer && onCollapse != null)
                      IconButton(
                        key: const Key('sidebar_collapse_button'),
                        tooltip: '收起侧边栏 (Ctrl+\\)',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
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
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                  children: <Widget>[
                    navRow(
                      itemKey: const Key('filter_all'),
                      icon: Icons.chat_bubble_outline_rounded,
                      label: '全部小记',
                      count: workspace.totalMemoCount,
                      selected: activeFilter == MemoFilterKind.all,
                      onTap: () =>
                          workspace.selectMemoFilter(MemoFilterKind.all),
                    ),
                    navRow(
                      itemKey: const Key('filter_today'),
                      icon: Icons.today_rounded,
                      label: '今天',
                      count: workspace.todayMemoCount,
                      selected: activeFilter == MemoFilterKind.today,
                      onTap: () =>
                          workspace.selectMemoFilter(MemoFilterKind.today),
                    ),
                    navRow(
                      itemKey: const Key('filter_private'),
                      icon: Icons.lock_outline_rounded,
                      label: '私密',
                      count: workspace.privateMemoCount,
                      accentOverride: tokens.privacyPrivate,
                      selected: activeFilter == MemoFilterKind.privateOnly,
                      onTap: () => workspace.selectMemoFilter(
                        MemoFilterKind.privateOnly,
                      ),
                    ),
                    navRow(
                      itemKey: const Key('filter_trash'),
                      icon: Icons.delete_outline_rounded,
                      label: '回收站',
                      count: workspace.trashMemoCount,
                      selected: activeFilter == MemoFilterKind.trash,
                      onTap: () =>
                          workspace.selectMemoFilter(MemoFilterKind.trash),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 12,
                      ),
                      child: Divider(height: 1, color: tokens.borderHairline),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                      child: Text(
                        '标签',
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.textMuted,
                        ),
                      ),
                    ),
                    if (sortedTags.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        child: Text(
                          '输入 #标签 即可自动归类',
                          style: BlinkTypography.metaLabel(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      )
                    else
                      for (final tagEntry in sortedTags)
                        navRow(
                          itemKey: Key('filter_tag_${tagEntry.key}'),
                          icon: Icons.tag_rounded,
                          label: tagEntry.key,
                          count: tagEntry.value,
                          selected:
                              activeFilter == MemoFilterKind.tag &&
                              activeTag == tagEntry.key,
                          onTap: () => workspace.selectMemoFilter(
                            MemoFilterKind.tag,
                            tag: tagEntry.key,
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Chat-timeline / thought-capsule Quick Memos workspace (`小记`).
class BlinkMemosPage extends StatefulWidget {
  const BlinkMemosPage({
    required this.workspace,
    this.isMobile = false,
    this.onOpenDrawer,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    this.onOpenSearch,
    this.composerFocusNode,
    this.editor,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final bool isMobile;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;
  final VoidCallback? onOpenSearch;
  final FocusNode? composerFocusNode;
  final BlinkEditorController? editor;

  @override
  State<BlinkMemosPage> createState() => _BlinkMemosPageState();
}

class _BlinkMemosPageState extends State<BlinkMemosPage>
    with WidgetsBindingObserver {
  static const BfmEngine _markdown = BfmEngine();

  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _composerLayerLink = LayerLink();
  final ScrollController _scrollController = ScrollController();

  BlinkEditorController? _ownedEditor;
  FocusNode? _ownedFocusNode;
  VaultManager? _lastBoundVault;
  Future<void> Function()? _ownedFlushHook;
  bool _composerHasFocus = false;

  BlinkEditorController get _editor => widget.editor ?? _ownedEditor!;
  FocusNode get _focusNode => widget.composerFocusNode ?? _ownedFocusNode!;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.editor == null) {
      _ownedEditor = BlinkEditorController(
        vaultProvider: () => widget.workspace.vault,
      );
    }
    if (widget.composerFocusNode == null) {
      _ownedFocusNode = FocusNode();
    }
    _attachEditorListeners(_editor);
    _attachFocusNode(_focusNode);
    if (_ownedEditor != null) {
      _attachOwnedFlushHook(widget.workspace);
    }

    widget.workspace.addListener(_onWorkspaceChanged);
    _lastBoundVault = widget.workspace.vault;
    if (_ownedEditor != null) {
      unawaited(_ownedEditor!.loadInboxDraft(resetIfMissing: true));
    }
  }

  @override
  void didUpdateWidget(covariant BlinkMemosPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.workspace != widget.workspace) {
      oldWidget.workspace.removeListener(_onWorkspaceChanged);
      _detachOwnedFlushHook(oldWidget.workspace);
      widget.workspace.addListener(_onWorkspaceChanged);
      if (_ownedEditor != null) {
        _attachOwnedFlushHook(widget.workspace);
      }
    }

    if (oldWidget.editor != widget.editor) {
      final previous = oldWidget.editor ?? _ownedEditor;
      if (previous != null) {
        previous.removeListener(_syncOverlayVisibility);
      }
      if (widget.editor != null && _ownedEditor != null) {
        _detachOwnedFlushHook(widget.workspace);
        final editorToDispose = _ownedEditor!;
        _ownedEditor = null;
        unawaited(editorToDispose.flushDraftNow());
        editorToDispose.dispose();
      } else if (widget.editor == null && _ownedEditor == null) {
        if (oldWidget.editor != null) {
          unawaited(oldWidget.editor!.flushDraftNow());
        }
        _ownedEditor = BlinkEditorController(
          vaultProvider: () => widget.workspace.vault,
        );
        _attachOwnedFlushHook(widget.workspace);
        unawaited(_ownedEditor!.loadInboxDraft(resetIfMissing: true));
      }
      _attachEditorListeners(_editor);
    }

    if (oldWidget.composerFocusNode != widget.composerFocusNode) {
      final previousNode = oldWidget.composerFocusNode ?? _ownedFocusNode;
      if (previousNode != null) {
        _detachFocusNode(previousNode);
      }
      if (widget.composerFocusNode != null && _ownedFocusNode != null) {
        _ownedFocusNode!.dispose();
        _ownedFocusNode = null;
      } else if (widget.composerFocusNode == null && _ownedFocusNode == null) {
        _ownedFocusNode = FocusNode();
      }
      _attachFocusNode(_focusNode);
    }

    if (oldWidget.isMobile != widget.isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncOverlayVisibility();
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.workspace.removeListener(_onWorkspaceChanged);
    _detachOwnedFlushHook(widget.workspace);
    _editor.removeListener(_syncOverlayVisibility);
    _detachFocusNode(_focusNode);

    if (_ownedEditor != null) {
      final editorToDispose = _ownedEditor!;
      _ownedEditor = null;
      unawaited(editorToDispose.flushDraftNow());
      editorToDispose.dispose();
    } else if (widget.editor != null) {
      unawaited(widget.editor!.flushDraftNow());
    }
    _ownedFocusNode?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_editor.flushDraftNow());
    }
  }

  Future<void> _flushOwnedDraft() async {
    final target = _ownedEditor;
    if (!mounted || target == null) {
      return;
    }
    await target.flushDraftNow();
  }

  void _attachOwnedFlushHook(BlinkWorkspaceController workspace) {
    if (_ownedFlushHook != null) {
      workspace.removeDraftFlushHook(_ownedFlushHook!);
    }
    _ownedFlushHook = _flushOwnedDraft;
    workspace.addDraftFlushHook(_ownedFlushHook!);
  }

  void _detachOwnedFlushHook(BlinkWorkspaceController workspace) {
    final hook = _ownedFlushHook;
    if (hook != null) {
      workspace.removeDraftFlushHook(hook);
      _ownedFlushHook = null;
    }
  }

  void _attachEditorListeners(BlinkEditorController controller) {
    controller.addListener(_syncOverlayVisibility);
  }

  void _attachFocusNode(FocusNode node) {
    node.onKeyEvent = _handleEditorKeyEvent;
    node.addListener(_onFocusChanged);
    _composerHasFocus = node.hasFocus;
  }

  void _detachFocusNode(FocusNode node) {
    if (node.onKeyEvent == _handleEditorKeyEvent) {
      node.onKeyEvent = null;
    }
    node.removeListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!mounted) {
      return;
    }
    final nextHasFocus = _focusNode.hasFocus;
    if (nextHasFocus != _composerHasFocus) {
      setState(() => _composerHasFocus = nextHasFocus);
    }
  }

  void _onWorkspaceChanged() {
    final currentVault = widget.workspace.vault;
    if (!identical(currentVault, _lastBoundVault)) {
      _lastBoundVault = currentVault;
      if (_ownedEditor != null) {
        unawaited(_ownedEditor!.loadInboxDraft(resetIfMissing: true));
      }
    }
    if (widget.workspace.selectedMemoFilter == MemoFilterKind.trash &&
        _editor.showAutocomplete) {
      _editor.dismissAutocomplete();
    }
    _syncOverlayVisibility();
  }

  void _syncOverlayVisibility() {
    if (!mounted) {
      return;
    }
    final isTrash = widget.workspace.selectedMemoFilter == MemoFilterKind.trash;
    final isComposing = BlinkSyntaxTextController.isValueComposing(
      _editor.textController.value,
    );
    final shouldShow =
        !widget.isMobile &&
        !isTrash &&
        _editor.showAutocomplete &&
        !isComposing;
    if (shouldShow && !_overlayController.isShowing) {
      _overlayController.show();
    } else if (!shouldShow && _overlayController.isShowing) {
      _overlayController.hide();
    }
  }

  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    final value = _editor.textController.value;
    return BlinkSyntaxTextController.handleImeFirstKeyEvent(
      value,
      event,
      hasOverlay:
          _editor.showAutocomplete &&
          !BlinkSyntaxTextController.isValueComposing(value),
      onSubmit: () {
        if (!BlinkSyntaxTextController.isValueComposing(
          _editor.textController.value,
        )) {
          unawaited(_submitComposer());
        }
      },
      onDismissOverlay: _editor.dismissAutocomplete,
      onSelectNextCandidate: _editor.selectNextCandidate,
      onSelectPreviousCandidate: _editor.selectPreviousCandidate,
      onAcceptCandidate: () {
        if (!BlinkSyntaxTextController.isValueComposing(
          _editor.textController.value,
        )) {
          _editor.acceptSelectedCandidate();
        }
      },
    );
  }

  Future<void> _submitComposer() async {
    if (BlinkSyntaxTextController.isValueComposing(
      _editor.textController.value,
    )) {
      return;
    }
    final wasEditing = _editor.isEditingExisting;
    try {
      final saved = await _editor.submit();
      if (saved != null) {
        if (wasEditing) {
          widget.workspace.selectMemo(saved.id);
          await _editor.startNewEntry();
        }
        await widget.workspace.refreshAll();
        if (!wasEditing &&
            _scrollController.hasClients &&
            _scrollController.offset > 0) {
          unawaited(
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      }
    } on BlinkException catch (error) {
      widget.workspace.showBanner('保存小记失败：${error.message}', isError: true);
    } catch (error) {
      widget.workspace.showBanner('保存小记失败：$error', isError: true);
    }
  }

  void _insertSnippet(String snippet) {
    if (BlinkSyntaxTextController.isValueComposing(
      _editor.textController.value,
    )) {
      return;
    }
    _editor.textController.insertSnippetIfNotComposing(snippet);
    _focusNode.requestFocus();
  }

  void _insertTaskSnippet() {
    final value = _editor.textController.value;
    if (BlinkSyntaxTextController.isValueComposing(value)) {
      return;
    }
    final text = value.text;
    final offset = value.selection.isValid
        ? value.selection.start.clamp(0, text.length)
        : text.length;
    final needsNewline = offset > 0 && text[offset - 1] != '\n';
    _insertSnippet(needsNewline ? '\n- [ ] ' : '- [ ] ');
  }

  Future<void> _attachFileToComposer() async {
    final blob = await widget.workspace.importFileFromPicker();
    if (blob != null) {
      _editor.attachBlobSha256(blob.sha256);
    }
  }

  Future<void> _startEditingMemo(RawEntry entry) async {
    widget.workspace.selectMemo(entry.id);
    await _editor.startEditingEntry(entry);
    if (mounted) {
      _focusNode.requestFocus();
    }
  }

  Future<void> _cancelEditingMemo() async {
    await _editor.startNewEntry();
    widget.workspace.selectMemo(null);
    if (mounted) {
      _focusNode.requestFocus();
    }
  }

  Future<void> _promoteMemoToNote(RawEntry entry) async {
    await widget.workspace.promoteMemoToNote(entry);
  }

  Future<void> _copyMemoBody(RawEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.bodyMd));
    widget.workspace.showBanner('已复制小记内容。');
  }

  Future<void> _softDeleteMemo(RawEntry entry) async {
    await _editor.resetIfEditingEntry(entry.id);
    await widget.workspace.softDeleteEntry(entry.id);
  }

  Future<void> _confirmAndPurgeMemo(RawEntry entry) async {
    if (!mounted) {
      return;
    }
    final tokens = BlinkColorTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: tokens.canvas,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: tokens.borderHairline, width: 1),
          ),
          title: Text(
            '彻底删除这条小记？',
            style: BlinkTypography.sectionHeading(tokens),
          ),
          content: Text(
            '彻底删除后将无法恢复，未被引用的附件也会一并清理。',
            style: BlinkTypography.body(tokens, color: tokens.textSecondary),
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('trash_purge_cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('trash_purge_confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: tokens.statusErr,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('彻底删除'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await _editor.resetIfEditingEntry(entry.id);
      await widget.workspace.purgeEntryPermanently(entry.id);
    }
  }

  Future<void> _handlePreviewLinkTap(BfmParsedLink link) async {
    if (link.targetKind == BfmLinkTargetKind.entry &&
        link.targetId != null &&
        link.targetId!.isNotEmpty) {
      await widget.workspace.openEntryById(link.targetId!);
    }
  }

  Future<void> _handleEntryCheckboxToggle(
    RawEntry entry,
    int lineIndex,
    TaskStatus nextStatus,
  ) async {
    final updated = await widget.workspace.toggleEntryTaskLine(
      entry,
      lineIndex: lineIndex,
      nextStatus: nextStatus,
    );
    if (updated != null && _editor.editingEntryId == entry.id) {
      await _editor.startEditingEntry(updated);
    }
  }

  String _activeFilterTitle() {
    return switch (widget.workspace.selectedMemoFilter) {
      MemoFilterKind.all => '全部小记',
      MemoFilterKind.today => '今天',
      MemoFilterKind.privateOnly => '私密',
      MemoFilterKind.tag => '#${widget.workspace.selectedMemoTag ?? ''}',
      MemoFilterKind.trash => '回收站',
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.workspace, _editor]),
      builder: (context, _) {
        final filter = widget.workspace.selectedMemoFilter;
        final isTrash = filter == MemoFilterKind.trash;
        final entries = widget.workspace.memoEntries;
        final blobsBySha = <String, MediaBlob>{
          for (final blob in widget.workspace.blobs) blob.sha256: blob,
        };

        return ColoredBox(
          color: tokens.canvas,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.isMobile)
                _buildMobileHeader(tokens, filter: filter)
              else
                _buildDesktopHeader(
                  tokens,
                  filter: filter,
                  count: entries.length,
                ),
              if (widget.isMobile && isTrash) _buildMobileTrashBanner(tokens),
              Expanded(
                child: entries.isEmpty
                    ? _buildEmptyState(tokens, filter: filter)
                    : isTrash
                    ? _buildTrashList(
                        tokens,
                        entries: entries,
                        blobsBySha: blobsBySha,
                      )
                    : _buildTimelineStream(
                        tokens,
                        entries: entries,
                        blobsBySha: blobsBySha,
                      ),
              ),
              if (!isTrash)
                _MemoCapsuleComposer(
                  editor: _editor,
                  focusNode: _focusNode,
                  hasFocus: _composerHasFocus,
                  hasOpenVault: widget.workspace.hasOpenVault,
                  isMobile: widget.isMobile,
                  blobsBySha: blobsBySha,
                  layerLink: _composerLayerLink,
                  overlayController: _overlayController,
                  onSubmit: _submitComposer,
                  onCancelEdit: _cancelEditingMemo,
                  onInsertTag: () => _insertSnippet('#'),
                  onInsertTask: _insertTaskSnippet,
                  onAttachFile: _attachFileToComposer,
                  onTogglePrivate: () =>
                      _editor.setPrivacyLocked(!_editor.privacyLocked),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDesktopHeader(
    BlinkColorTokens tokens, {
    required MemoFilterKind filter,
    required int count,
  }) {
    final isTrash = filter == MemoFilterKind.trash;
    final isPrivate = filter == MemoFilterKind.privateOnly;
    final titleColor = isPrivate ? tokens.privacyPrivate : tokens.textPrimary;

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          if (widget.showExpandSidebarButton &&
              widget.onExpandSidebar != null) ...<Widget>[
            IconButton(
              key: const Key('sidebar_expand_button'),
              tooltip: '展开侧边栏 (Ctrl+\\)',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: widget.onExpandSidebar,
              icon: Icon(
                Icons.menu_rounded,
                size: 18,
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (isPrivate) ...<Widget>[
            Icon(
              Icons.lock_outline_rounded,
              size: 15,
              color: tokens.privacyPrivate,
            ),
            const SizedBox(width: 5),
          ] else if (isTrash) ...<Widget>[
            Icon(
              Icons.delete_outline_rounded,
              size: 15,
              color: tokens.textSecondary,
            ),
            const SizedBox(width: 5),
          ],
          Text(
            _activeFilterTitle(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: BlinkTypography.controlLabel(tokens)
                .copyWith(color: titleColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: tokens.sidebar,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: BlinkTypography.metaLabel(
                tokens,
                color: tokens.textMuted,
              ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
            ),
          ),
          if (filter == MemoFilterKind.tag) ...<Widget>[
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () =>
                  widget.workspace.selectMemoFilter(MemoFilterKind.all),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  '查看全部',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.accentPrimary,
                  ),
                ),
              ),
            ),
          ],
          if (isTrash) ...<Widget>[
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '删除的小记保留 30 天，可随时还原',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              key: const Key('trash_purge_expired_button'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                side: BorderSide(color: tokens.borderHairline, width: 1),
              ),
              onPressed: widget.workspace.hasOpenVault
                  ? () => unawaited(widget.workspace.purgeExpiredTrash())
                  : null,
              icon: const Icon(Icons.delete_sweep_outlined, size: 15),
              label: const Text('清理已过期'),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }

  Widget _buildMobileHeader(
    BlinkColorTokens tokens, {
    required MemoFilterKind filter,
  }) {
    final isPrivate = filter == MemoFilterKind.privateOnly;
    final subLabel = switch (filter) {
      MemoFilterKind.all => null,
      MemoFilterKind.today => '今天',
      MemoFilterKind.privateOnly => '私密',
      MemoFilterKind.tag => '#${widget.workspace.selectedMemoTag ?? ''}',
      MemoFilterKind.trash => '回收站',
    };

    return Container(
      height: 45,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                key: const Key('open_sidebar_drawer_button'),
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onOpenDrawer,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '小记',
                          style: BlinkTypography.sectionHeading(tokens),
                        ),
                        if (subLabel != null) ...<Widget>[
                          const SizedBox(width: 6),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isPrivate
                                    ? tokens.privacySubtle
                                    : tokens.accentSubtle,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (isPrivate) ...<Widget>[
                                    Icon(
                                      Icons.lock_outline_rounded,
                                      size: 12,
                                      color: tokens.privacyPrivate,
                                    ),
                                    const SizedBox(width: 3),
                                  ],
                                  Flexible(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 160,
                                      ),
                                      child: Text(
                                        subLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: BlinkTypography.badge(
                                          color: isPrivate
                                              ? tokens.privacyPrivate
                                              : tokens.accentPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 2),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: tokens.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('mobile_search_button'),
            tooltip: '搜索',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: widget.onOpenSearch,
            icon: Icon(
              Icons.search_rounded,
              size: 20,
              color: tokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileTrashBanner(BlinkColorTokens tokens) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '删除的小记保留 30 天，可随时还原',
              style: BlinkTypography.metaLabel(
                tokens,
                color: tokens.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const Key('trash_purge_expired_button'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: widget.workspace.hasOpenVault
                ? () => unawaited(widget.workspace.purgeExpiredTrash())
                : null,
            child: const Text('清理已过期'),
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineStream(
    BlinkColorTokens tokens, {
    required List<RawEntry> entries,
    required Map<String, MediaBlob> blobsBySha,
  }) {
    final items = _buildReverseTimelineItems(entries);
    final horizontalPadding = widget.isMobile ? 12.0 : 20.0;

    return ListView.builder(
      key: const Key('memos_timeline_list'),
      controller: _scrollController,
      reverse: true,
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        16,
        horizontalPadding,
        12,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final child = switch (item) {
          _DateSeparatorTimelineItem(:final localDate) => _DateSeparatorPill(
            label: _formatDateSeparator(localDate),
          ),
          _MemoTimelineItem(:final entry) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _MemoCapsuleBubble(
              entry: entry,
              parsed: _markdown.parse(entry.bodyMd),
              blobsBySha: blobsBySha,
              isMobile: widget.isMobile,
              selected: widget.workspace.selectedMemoId == entry.id,
              isBeingEdited: _editor.editingEntryId == entry.id,
              onSelect: () => widget.workspace.selectMemo(entry.id),
              onEdit: () => unawaited(_startEditingMemo(entry)),
              onPromote: () => unawaited(_promoteMemoToNote(entry)),
              onCopy: () => unawaited(_copyMemoBody(entry)),
              onSoftDelete: () => unawaited(_softDeleteMemo(entry)),
              onTapLink: (link) => unawaited(_handlePreviewLinkTap(link)),
              onTapTag: (tag) => widget.workspace.selectMemoFilter(
                MemoFilterKind.tag,
                tag: tag,
              ),
              onToggleTaskLine: (lineIndex, nextStatus) => unawaited(
                _handleEntryCheckboxToggle(entry, lineIndex, nextStatus),
              ),
              onExportBlob: (blob) =>
                  unawaited(widget.workspace.exportBlobToPicker(blob)),
            ),
          ),
        };

        if (widget.isMobile) {
          return child;
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildTrashList(
    BlinkColorTokens tokens, {
    required List<RawEntry> entries,
    required Map<String, MediaBlob> blobsBySha,
  }) {
    final horizontalPadding = widget.isMobile ? 12.0 : 20.0;

    return ListView.separated(
      key: const Key('memos_trash_list'),
      padding: EdgeInsets.fromLTRB(
        horizontalPadding,
        14,
        horizontalPadding,
        24,
      ),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final card = _TrashMemoCard(
          entry: entry,
          blobsBySha: blobsBySha,
          onRestore: () => unawaited(widget.workspace.restoreEntry(entry.id)),
          onPurge: () => unawaited(_confirmAndPurgeMemo(entry)),
        );
        if (widget.isMobile) {
          return card;
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: card,
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(
    BlinkColorTokens tokens, {
    required MemoFilterKind filter,
  }) {
    final (
      IconData icon,
      Color iconColor,
      String title,
      String subtitle,
    ) = switch (filter) {
      MemoFilterKind.today => (
        Icons.wb_sunny_outlined,
        tokens.textMuted,
        '今天还没有新小记',
        '在下方输入框随时记下此刻的闪念',
      ),
      MemoFilterKind.privateOnly => (
        Icons.lock_outline_rounded,
        tokens.privacyPrivate,
        '还没有私密小记',
        '点按下方锁形图标或输入 #private，私密小记仅保存在本机',
      ),
      MemoFilterKind.tag => (
        Icons.tag_rounded,
        tokens.textMuted,
        '标签 #${widget.workspace.selectedMemoTag ?? ''} 下还没有小记',
        '在新小记中输入该标签即可自动归入这里',
      ),
      MemoFilterKind.trash => (
        Icons.delete_outline_rounded,
        tokens.textMuted,
        '回收站为空',
        '删除的小记会保留 30 天，期间可随时还原',
      ),
      MemoFilterKind.all => (
        Icons.chat_bubble_outline_rounded,
        tokens.textMuted,
        '像发消息一样，随时记下此刻的想法',
        '支持 #标签 归类、- [ ] 待办与 [[关联笔记]]',
      ),
    };

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 32, color: iconColor),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: BlinkTypography.controlLabel(tokens)
                    .copyWith(color: tokens.textSecondary),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds items in reverse-visual order (bottom -> top) for `ListView(reverse: true)`:
  /// newest memo at index `0`, with each day's date separator placed visually ABOVE
  /// the earliest memo of that day.
  static List<_TimelineItem> _buildReverseTimelineItems(
    List<RawEntry> entries,
  ) {
    final items = <_TimelineItem>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      items.add(_MemoTimelineItem(entry));
      final currentLocal = entry.createdAtUtc.toLocal();
      final isOldestOfDay =
          i == entries.length - 1 ||
          !_isSameLocalDay(currentLocal, entries[i + 1].createdAtUtc.toLocal());
      if (isOldestOfDay) {
        items.add(_DateSeparatorTimelineItem(currentLocal));
      }
    }
    return items;
  }

  static bool _isSameLocalDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _formatDateSeparator(DateTime local) {
    final now = DateTime.now();
    if (_isSameLocalDay(local, now)) {
      return '今天';
    }
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (_isSameLocalDay(local, yesterday)) {
      return '昨天';
    }
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    if (local.year == now.year) {
      return '$m月$d日';
    }
    return '${local.year}年$m月$d日';
  }
}

sealed class _TimelineItem {
  const _TimelineItem();
}

class _MemoTimelineItem extends _TimelineItem {
  const _MemoTimelineItem(this.entry);

  final RawEntry entry;
}

class _DateSeparatorTimelineItem extends _TimelineItem {
  const _DateSeparatorTimelineItem(this.localDate);

  final DateTime localDate;
}

class _DateSeparatorPill extends StatelessWidget {
  const _DateSeparatorPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tokens.borderHairline, width: 1),
          ),
          child: Text(
            label,
            style: BlinkTypography.metaLabel(
              tokens,
              color: tokens.textMuted,
            ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
          ),
        ),
      ),
    );
  }
}

enum _MemoBubbleAction { edit, promote, copy, delete }

class _MemoCapsuleBubble extends StatefulWidget {
  const _MemoCapsuleBubble({
    required this.entry,
    required this.parsed,
    required this.blobsBySha,
    required this.isMobile,
    required this.selected,
    required this.isBeingEdited,
    required this.onSelect,
    required this.onEdit,
    required this.onPromote,
    required this.onCopy,
    required this.onSoftDelete,
    required this.onTapLink,
    required this.onTapTag,
    required this.onToggleTaskLine,
    required this.onExportBlob,
  });

  final RawEntry entry;
  final BfmDocument parsed;
  final Map<String, MediaBlob> blobsBySha;
  final bool isMobile;
  final bool selected;
  final bool isBeingEdited;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onPromote;
  final VoidCallback onCopy;
  final VoidCallback onSoftDelete;
  final BfmLinkTapCallback onTapLink;
  final ValueChanged<String> onTapTag;
  final BfmTaskLineToggleCallback onToggleTaskLine;
  final ValueChanged<MediaBlob> onExportBlob;

  @override
  State<_MemoCapsuleBubble> createState() => _MemoCapsuleBubbleState();
}

class _MemoCapsuleBubbleState extends State<_MemoCapsuleBubble> {
  bool _hovered = false;

  void _handleAction(_MemoBubbleAction action) {
    switch (action) {
      case _MemoBubbleAction.edit:
        widget.onEdit();
      case _MemoBubbleAction.promote:
        widget.onPromote();
      case _MemoBubbleAction.copy:
        widget.onCopy();
      case _MemoBubbleAction.delete:
        widget.onSoftDelete();
    }
  }

  Future<void> _openMobileActionSheet(BuildContext context) async {
    final tokens = BlinkColorTokens.of(context);
    final entryId = widget.entry.id;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.canvas,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: Key('memo_edit_$entryId'),
                leading: Icon(Icons.edit_outlined, color: tokens.textPrimary),
                title: Text('编辑', style: BlinkTypography.controlLabel(tokens)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onEdit();
                },
              ),
              ListTile(
                key: Key('memo_promote_$entryId'),
                leading: Icon(
                  Icons.article_outlined,
                  color: tokens.accentPrimary,
                ),
                title: Text(
                  '转为笔记',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                subtitle: Text(
                  '生成一篇长笔记并保留原小记',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onPromote();
                },
              ),
              ListTile(
                key: Key('memo_copy_$entryId'),
                leading: Icon(Icons.copy_outlined, color: tokens.textPrimary),
                title: Text('复制', style: BlinkTypography.controlLabel(tokens)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onCopy();
                },
              ),
              ListTile(
                key: Key('memo_delete_$entryId'),
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: tokens.statusErr,
                ),
                title: Text(
                  '移入回收站',
                  style: BlinkTypography.controlLabel(tokens)
                      .copyWith(color: tokens.statusErr),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  widget.onSoftDelete();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final entry = widget.entry;
    final hasOpenTask = widget.parsed.tasks.any(
      (task) =>
          task.status == TaskStatus.open || task.status == TaskStatus.deferred,
    );
    final stripeColor = entry.isPrivate
        ? tokens.privacyPrivate
        : hasOpenTask
        ? tokens.statusWarn
        : tokens.accentPrimary.withValues(alpha: 0.45);
    final highlighted = widget.selected || widget.isBeingEdited;
    final borderColor = highlighted
        ? (entry.isPrivate ? tokens.privacyPrivate : tokens.accentPrimary)
        : tokens.borderHairline;

    final cardContent = Material(
      key: Key('memo_bubble_${entry.id}'),
      color: tokens.sidebar,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: borderColor, width: highlighted ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onSelect,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(color: stripeColor),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  BfmPreviewView(
                    bodyMd: entry.bodyMd,
                    compact: true,
                    onTapLink: widget.onTapLink,
                    onTapTag: widget.onTapTag,
                    onToggleTaskLine: widget.onToggleTaskLine,
                  ),
                  if (entry.imageBlobSha256s.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final sha in entry.imageBlobSha256s)
                          _AttachmentChip(
                            sha256: sha,
                            blob: widget.blobsBySha[sha],
                            onTap: widget.blobsBySha[sha] == null
                                ? null
                                : () => widget.onExportBlob(
                                    widget.blobsBySha[sha]!,
                                  ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  _buildFooter(context, tokens),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.isMobile) {
      return cardContent;
    }
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) {
          setState(() => _hovered = true);
        }
      },
      onExit: (_) {
        if (_hovered) {
          setState(() => _hovered = false);
        }
      },
      child: cardContent,
    );
  }

  Widget _buildFooter(BuildContext context, BlinkColorTokens tokens) {
    final entry = widget.entry;
    final showDesktopHoverActions =
        !widget.isMobile &&
        (_hovered || widget.selected || widget.isBeingEdited);

    Widget desktopActionButton({
      required Key buttonKey,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
      Color? color,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          key: buttonKey,
          borderRadius: BorderRadius.circular(6),
          onTap: onPressed,
          child: SizedBox(
            width: 26,
            height: 26,
            child: Icon(icon, size: 15, color: color ?? tokens.textSecondary),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        Text(
          _formatTimeOfDay(entry.createdAtUtc),
          style: BlinkTypography.metaLabel(
            tokens,
            color: tokens.textMuted,
          ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
        ),
        if (entry.isPrivate) ...<Widget>[
          const SizedBox(width: 8),
          if (widget.parsed.hasPrivateToken)
            Tooltip(
              message: '私密 · 仅存本机',
              child: Icon(
                Icons.lock_outline_rounded,
                key: Key('memo_private_badge_${entry.id}'),
                size: 12,
                color: tokens.privacyPrivate,
              ),
            )
          else
            Container(
              key: Key('memo_private_badge_${entry.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: tokens.privacySubtle,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 11,
                    color: tokens.privacyPrivate,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    '私密',
                    style: BlinkTypography.badge(color: tokens.privacyPrivate)
                        .copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
        if (widget.isBeingEdited) ...<Widget>[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: tokens.accentSubtle,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '编辑中',
              style: BlinkTypography.badge(color: tokens.accentPrimary)
                  .copyWith(fontSize: 11),
            ),
          ),
        ],
        const Spacer(),
        if (widget.isMobile)
          InkWell(
            key: Key('memo_more_${entry.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => unawaited(_openMobileActionSheet(context)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 36, minHeight: 28),
              child: Icon(
                Icons.more_horiz_rounded,
                size: 18,
                color: tokens.textMuted,
              ),
            ),
          )
        else ...<Widget>[
          IgnorePointer(
            ignoring: !showDesktopHoverActions,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 120),
              opacity: showDesktopHoverActions ? 1.0 : 0.0,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  desktopActionButton(
                    buttonKey: Key('memo_edit_${entry.id}'),
                    tooltip: '编辑',
                    icon: Icons.edit_outlined,
                    onPressed: widget.onEdit,
                  ),
                  const SizedBox(width: 2),
                  desktopActionButton(
                    buttonKey: Key('memo_promote_${entry.id}'),
                    tooltip: '转为笔记',
                    icon: Icons.article_outlined,
                    color: tokens.accentPrimary,
                    onPressed: widget.onPromote,
                  ),
                  const SizedBox(width: 2),
                  desktopActionButton(
                    buttonKey: Key('memo_copy_${entry.id}'),
                    tooltip: '复制',
                    icon: Icons.copy_outlined,
                    onPressed: widget.onCopy,
                  ),
                  const SizedBox(width: 2),
                  desktopActionButton(
                    buttonKey: Key('memo_delete_${entry.id}'),
                    tooltip: '移入回收站',
                    icon: Icons.delete_outline_rounded,
                    onPressed: widget.onSoftDelete,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),
          PopupMenuButton<_MemoBubbleAction>(
            key: Key('memo_more_${entry.id}'),
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            color: tokens.canvas,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: tokens.borderHairline, width: 1),
            ),
            onSelected: _handleAction,
            icon: Icon(
              Icons.more_horiz_rounded,
              size: 16,
              color: showDesktopHoverActions
                  ? tokens.textSecondary
                  : tokens.textMuted,
            ),
            itemBuilder: (menuContext) => <PopupMenuEntry<_MemoBubbleAction>>[
              PopupMenuItem<_MemoBubbleAction>(
                key: Key('memo_menu_edit_${entry.id}'),
                value: _MemoBubbleAction.edit,
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: tokens.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    const Text('编辑'),
                  ],
                ),
              ),
              PopupMenuItem<_MemoBubbleAction>(
                key: Key('memo_menu_promote_${entry.id}'),
                value: _MemoBubbleAction.promote,
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.article_outlined,
                      size: 16,
                      color: tokens.accentPrimary,
                    ),
                    const SizedBox(width: 8),
                    const Text('转为笔记'),
                  ],
                ),
              ),
              PopupMenuItem<_MemoBubbleAction>(
                key: Key('memo_menu_copy_${entry.id}'),
                value: _MemoBubbleAction.copy,
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.copy_outlined,
                      size: 16,
                      color: tokens.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    const Text('复制'),
                  ],
                ),
              ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem<_MemoBubbleAction>(
                key: Key('memo_menu_delete_${entry.id}'),
                value: _MemoBubbleAction.delete,
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 16,
                      color: tokens.statusErr,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '移入回收站',
                      style: BlinkTypography.body(
                        tokens,
                        color: tokens.statusErr,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _formatTimeOfDay(DateTime utc) {
    final local = utc.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class _TrashMemoCard extends StatelessWidget {
  const _TrashMemoCard({
    required this.entry,
    required this.blobsBySha,
    required this.onRestore,
    required this.onPurge,
  });

  final RawEntry entry;
  final Map<String, MediaBlob> blobsBySha;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final timestamp = entry.deletedAtUtc ?? entry.updatedAtUtc;

    return Container(
      key: Key('trash_card_${entry.id}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.borderHairline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          BfmPreviewView(bodyMd: entry.bodyMd, compact: true),
          if (entry.imageBlobSha256s.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final sha in entry.imageBlobSha256s)
                  _AttachmentChip(sha256: sha, blob: blobsBySha[sha]),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Text(
                _formatFullDateTime(timestamp),
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textMuted,
                ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
              ),
              if (entry.isPrivate) ...<Widget>[
                const SizedBox(width: 8),
                Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: tokens.privacyPrivate,
                ),
                const SizedBox(width: 2),
                Text(
                  '私密',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.privacyPrivate,
                  ),
                ),
              ],
              const Spacer(),
              TextButton(
                key: Key('trash_restore_${entry.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onRestore,
                child: const Text('还原'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: Key('trash_purge_${entry.id}'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: tokens.statusErr,
                ),
                onPressed: onPurge,
                child: const Text('彻底删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatFullDateTime(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

class _MemoCapsuleComposer extends StatelessWidget {
  const _MemoCapsuleComposer({
    required this.editor,
    required this.focusNode,
    required this.hasFocus,
    required this.hasOpenVault,
    required this.isMobile,
    required this.blobsBySha,
    required this.layerLink,
    required this.overlayController,
    required this.onSubmit,
    required this.onCancelEdit,
    required this.onInsertTag,
    required this.onInsertTask,
    required this.onAttachFile,
    required this.onTogglePrivate,
  });

  final BlinkEditorController editor;
  final FocusNode focusNode;
  final bool hasFocus;
  final bool hasOpenVault;
  final bool isMobile;
  final Map<String, MediaBlob> blobsBySha;
  final LayerLink layerLink;
  final OverlayPortalController overlayController;
  final Future<void> Function() onSubmit;
  final Future<void> Function() onCancelEdit;
  final VoidCallback onInsertTag;
  final VoidCallback onInsertTask;
  final Future<void> Function() onAttachFile;
  final VoidCallback onTogglePrivate;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final hasPrivate =
        editor.privacyLocked || editor.parsedPreviewDoc.hasPrivateToken;
    final isComposing = BlinkSyntaxTextController.isValueComposing(
      editor.textController.value,
    );

    if (isMobile) {
      return _buildMobileComposer(
        context,
        tokens,
        hasPrivate: hasPrivate,
        isComposing: isComposing,
      );
    }
    return _buildDesktopComposer(context, tokens, hasPrivate: hasPrivate);
  }

  Widget _buildDesktopComposer(
    BuildContext context,
    BlinkColorTokens tokens, {
    required bool hasPrivate,
  }) {
    final borderColor = hasPrivate
        ? tokens.privacyPrivate
        : hasFocus
        ? tokens.accentPrimary
        : tokens.borderHairline;

    Widget actionPill({
      required Key buttonKey,
      required IconData icon,
      required String label,
      required VoidCallback? onTap,
      bool active = false,
      Color? activeColor,
      Color? activeBg,
    }) {
      final fg = active
          ? (activeColor ?? tokens.accentPrimary)
          : tokens.textSecondary;
      return InkWell(
        key: buttonKey,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? (activeBg ?? tokens.accentSubtle)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 4),
              Text(label, style: BlinkTypography.metaLabel(tokens, color: fg)),
            ],
          ),
        ),
      );
    }

    final capsule = Container(
      key: const Key('desktop_memo_composer'),
      decoration: BoxDecoration(
        color: tokens.canvas,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: borderColor,
          width: (hasFocus || hasPrivate) ? 1.5 : 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (editor.isEditingExisting)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
              decoration: BoxDecoration(
                color: hasPrivate ? tokens.privacySubtle : tokens.accentSubtle,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16.5),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: hasPrivate
                        ? tokens.privacyPrivate
                        : tokens.accentPrimary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '正在编辑小记',
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: hasPrivate
                          ? tokens.privacyPrivate
                          : tokens.accentPrimary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const Key('memo_edit_cancel_button'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => unawaited(onCancelEdit()),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          if (editor.attachedBlobSha256s.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final sha in editor.attachedBlobSha256s)
                    _AttachmentChip(
                      sha256: sha,
                      blob: blobsBySha[sha],
                      onDelete: () => editor.detachBlobSha256(sha),
                    ),
                ],
              ),
            ),
          TextField(
            key: const Key('editor_text_field'),
            controller: editor.textController,
            focusNode: focusNode,
            minLines: 1,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            style: BlinkTypography.editorBody(tokens),
            decoration: InputDecoration(
              hintText: editor.isEditingExisting
                  ? '编辑小记内容…（Ctrl+Enter 保存）'
                  : '记一条想法…（#标签 · [[关联笔记]] · Ctrl+Enter 发送）',
              hintStyle: BlinkTypography.body(tokens, color: tokens.textMuted),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Wrap(
                    spacing: 2,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      actionPill(
                        buttonKey: const Key('composer_tag_button'),
                        icon: Icons.tag_rounded,
                        label: '标签',
                        onTap: onInsertTag,
                      ),
                      actionPill(
                        buttonKey: const Key('composer_task_button'),
                        icon: Icons.check_box_outlined,
                        label: '待办',
                        onTap: onInsertTask,
                      ),
                      actionPill(
                        buttonKey: const Key('composer_attach_button'),
                        icon: Icons.attach_file_rounded,
                        label: '附件',
                        onTap: hasOpenVault
                            ? () => unawaited(onAttachFile())
                            : null,
                      ),
                      actionPill(
                        buttonKey: const Key('composer_private_toggle'),
                        icon: hasPrivate
                            ? Icons.lock_rounded
                            : Icons.lock_open_rounded,
                        label: '私密',
                        active: hasPrivate,
                        activeColor: tokens.privacyPrivate,
                        activeBg: tokens.privacySubtle,
                        onTap: onTogglePrivate,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('editor_submit_button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.accentPrimary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    minimumSize: const Size(64, 34),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: hasOpenVault && !editor.isSaving
                      ? () => unawaited(onSubmit())
                      : null,
                  child: Text(editor.isEditingExisting ? '保存' : '发送'),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(top: BorderSide(color: tokens.borderHairline, width: 1)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: CompositedTransformTarget(
            link: layerLink,
            child: OverlayPortal(
              controller: overlayController,
              overlayChildBuilder: (overlayContext) {
                return CompositedTransformFollower(
                  link: layerLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.topLeft,
                  followerAnchor: Alignment.bottomLeft,
                  offset: const Offset(0, -8),
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: _MemoAutocompletePopup(
                      candidates: editor.candidates,
                      selectedIndex: editor.selectedCandidateIndex,
                      onSelect: editor.acceptCandidate,
                      onDismiss: editor.dismissAutocomplete,
                    ),
                  ),
                );
              },
              child: capsule,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileComposer(
    BuildContext context,
    BlinkColorTokens tokens, {
    required bool hasPrivate,
    required bool isComposing,
  }) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final showStatusStrip =
        editor.isEditingExisting ||
        hasPrivate ||
        editor.attachedBlobSha256s.isNotEmpty;
    final pillBorderColor = hasPrivate
        ? tokens.privacyPrivate
        : hasFocus
        ? tokens.accentPrimary
        : tokens.borderHairline;

    return SafeArea(
      top: false,
      left: false,
      right: false,
      child: Padding(
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (editor.showAutocomplete && !isComposing)
              _MobileAutocompleteBar(
                candidates: editor.candidates,
                selectedIndex: editor.selectedCandidateIndex,
                onSelect: editor.acceptCandidate,
                onDismiss: editor.dismissAutocomplete,
              ),
            Container(
              key: const Key('mobile_bottom_composer'),
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  top: BorderSide(
                    color: hasPrivate
                        ? tokens.privacyPrivate
                        : tokens.borderHairline,
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (showStatusStrip)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (editor.isEditingExisting)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.accentSubtle,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    '正在编辑小记',
                                    style: BlinkTypography.metaLabel(
                                      tokens,
                                      color: tokens.accentPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  InkWell(
                                    key: const Key('memo_edit_cancel_button'),
                                    onTap: () => unawaited(onCancelEdit()),
                                    child: Text(
                                      '取消',
                                      style: BlinkTypography.metaLabel(
                                        tokens,
                                        color: tokens.textSecondary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (hasPrivate)
                            InkWell(
                              key: const Key('composer_private_toggle'),
                              borderRadius: BorderRadius.circular(999),
                              onTap: onTogglePrivate,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: tokens.privacySubtle,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Icon(
                                      Icons.lock_outline_rounded,
                                      size: 12,
                                      color: tokens.privacyPrivate,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '私密',
                                      style: BlinkTypography.badge(
                                        color: tokens.privacyPrivate,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          for (final sha in editor.attachedBlobSha256s)
                            _AttachmentChip(
                              sha256: sha,
                              blob: blobsBySha[sha],
                              onDelete: () => editor.detachBlobSha256(sha),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        IconButton(
                          key: const Key('mobile_composer_more'),
                          tooltip: '更多输入选项',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          onPressed: () => unawaited(
                            _openMobileMoreSheet(
                              context,
                              tokens,
                              hasPrivate: hasPrivate,
                            ),
                          ),
                          icon: Icon(
                            Icons.add_circle_outline_rounded,
                            size: 24,
                            color: tokens.textSecondary,
                          ),
                        ),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: tokens.sidebar,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: pillBorderColor,
                                width: 1,
                              ),
                            ),
                            child: TextField(
                              key: const Key('editor_text_field'),
                              controller: editor.textController,
                              focusNode: focusNode,
                              minLines: 1,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              style: BlinkTypography.editorBody(tokens)
                                  .copyWith(fontSize: 16),
                              decoration: InputDecoration(
                                hintText: editor.isEditingExisting
                                    ? '编辑小记…'
                                    : '记一条小记…',
                                hintStyle: BlinkTypography.body(
                                  tokens,
                                  color: tokens.textMuted,
                                ),
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Semantics(
                          button: true,
                          label: editor.isEditingExisting ? '保存' : '发送',
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Material(
                                color: hasOpenVault && !editor.isSaving
                                    ? tokens.accentPrimary
                                    : tokens.borderHairline,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  key: const Key('editor_submit_button'),
                                  onTap: hasOpenVault && !editor.isSaving
                                      ? () => unawaited(onSubmit())
                                      : null,
                                  child: SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Icon(
                                      editor.isEditingExisting
                                          ? Icons.check_rounded
                                          : Icons.arrow_upward_rounded,
                                      size: 20,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openMobileMoreSheet(
    BuildContext context,
    BlinkColorTokens tokens, {
    required bool hasPrivate,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.canvas,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const Key('mobile_more_tag'),
                leading: Icon(Icons.tag_rounded, color: tokens.accentPrimary),
                title: Text(
                  '插入标签 (#)',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onInsertTag();
                },
              ),
              ListTile(
                key: const Key('mobile_more_task'),
                leading: Icon(
                  Icons.check_box_outlined,
                  color: tokens.accentPrimary,
                ),
                title: Text(
                  '插入待办 (- [ ])',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onInsertTask();
                },
              ),
              ListTile(
                key: const Key('mobile_more_attach'),
                enabled: hasOpenVault,
                leading: Icon(
                  Icons.attach_file_rounded,
                  color: tokens.textPrimary,
                ),
                title: Text(
                  '添加附件',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(onAttachFile());
                },
              ),
              ListTile(
                key: const Key('mobile_more_private'),
                leading: Icon(
                  hasPrivate ? Icons.lock_rounded : Icons.lock_open_rounded,
                  color: tokens.privacyPrivate,
                ),
                title: Text(
                  hasPrivate ? '已设为私密' : '设为私密',
                  style: BlinkTypography.controlLabel(tokens).copyWith(
                    color: hasPrivate
                        ? tokens.privacyPrivate
                        : tokens.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '私密内容仅存本机，不上传云端',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onTogglePrivate();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({
    required this.sha256,
    this.blob,
    this.onTap,
    this.onDelete,
  });

  final String sha256;
  final MediaBlob? blob;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final (IconData icon, String label) = _describeAttachment(blob, sha256);

    return Material(
      color: tokens.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 14, color: tokens.textSecondary),
              const SizedBox(width: 5),
              Text(
                label,
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textSecondary,
                ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
              ),
              if (onDelete != null) ...<Widget>[
                const SizedBox(width: 4),
                InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: onDelete,
                  child: Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: tokens.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static (IconData, String) _describeAttachment(MediaBlob? blob, String sha) {
    if (blob == null) {
      final short = sha.length > 6 ? sha.substring(0, 6) : sha;
      return (Icons.attach_file_rounded, '附件 $short');
    }
    final size = formatByteSize(blob.byteSize);
    final mime = blob.mimeType.toLowerCase();
    if (mime.startsWith('image/')) {
      return (Icons.image_outlined, '图片 · $size');
    }
    if (mime.startsWith('audio/')) {
      return (Icons.audiotrack_outlined, '音频 · $size');
    }
    if (mime == 'application/pdf') {
      return (Icons.picture_as_pdf_outlined, 'PDF · $size');
    }
    if (mime.startsWith('text/')) {
      return (Icons.description_outlined, '文档 · $size');
    }
    return (Icons.attach_file_rounded, '附件 · $size');
  }
}

/// Keyboard-attached horizontal autocomplete bar for mobile viewports (`< 600px`)
/// with `>= 44dp` touch targets.
class _MobileAutocompleteBar extends StatelessWidget {
  const _MobileAutocompleteBar({
    required this.candidates,
    required this.selectedIndex,
    required this.onSelect,
    required this.onDismiss,
  });

  final List<AutocompleteCandidate> candidates;
  final int selectedIndex;
  final ValueChanged<AutocompleteCandidate> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Container(
      key: const Key('mobile_autocomplete_bar'),
      height: 56,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(top: BorderSide(color: tokens.borderHairline, width: 1)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              itemCount: candidates.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final item = candidates[index];
                final isSelected = index == selectedIndex;
                final fg = item.isPrivate
                    ? tokens.privacyPrivate
                    : isSelected
                    ? tokens.accentPrimary
                    : tokens.textPrimary;
                return Material(
                  color: isSelected ? tokens.accentSubtle : tokens.canvas,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: item.isPrivate
                          ? tokens.privacyPrivate
                          : isSelected
                          ? tokens.accentPrimary
                          : tokens.borderHairline,
                      width: 1,
                    ),
                  ),
                  child: InkWell(
                    key: Key('mobile_autocomplete_candidate_$index'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onSelect(item),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 44,
                        minWidth: 44,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Center(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BlinkTypography.controlLabel(tokens)
                                .copyWith(color: fg),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            key: const Key('mobile_autocomplete_dismiss'),
            tooltip: '关闭补全条',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            onPressed: onDismiss,
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: tokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemoAutocompletePopup extends StatelessWidget {
  const _MemoAutocompletePopup({
    required this.candidates,
    required this.selectedIndex,
    required this.onSelect,
    required this.onDismiss,
  });

  final List<AutocompleteCandidate> candidates;
  final int selectedIndex;
  final ValueChanged<AutocompleteCandidate> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Material(
      key: const Key('memo_autocomplete_overlay'),
      color: tokens.canvas,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 240),
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: candidates.length,
          separatorBuilder: (_, _) =>
              Divider(height: 1, color: tokens.borderHairline),
          itemBuilder: (context, index) {
            final item = candidates[index];
            final isSelected = index == selectedIndex;
            return InkWell(
              key: Key('autocomplete_candidate_$index'),
              onTap: () => onSelect(item),
              child: Container(
                color: isSelected ? tokens.accentSubtle : Colors.transparent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BlinkTypography.controlLabel(tokens).copyWith(
                        color: item.isPrivate
                            ? tokens.privacyPrivate
                            : isSelected
                            ? tokens.accentPrimary
                            : tokens.textPrimary,
                      ),
                    ),
                    if (item.subtitle.isNotEmpty)
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
