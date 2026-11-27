import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/search_controller.dart';
import 'package:blink_client/application/tasks_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/ui/files_page.dart';
import 'package:blink_client/ui/search_modal.dart';
import 'package:blink_client/ui/settings_page.dart';
import 'package:blink_client/ui/stream_page.dart';
import 'package:blink_client/ui/sync_conflict_dialog.dart';
import 'package:blink_client/ui/sync_status_capsule.dart';
import 'package:blink_client/ui/tasks_page.dart';

/// Adaptive 4-breakpoint M3 Desktop/Five-Platform Workspace Shell (`docs/ui.md` §1):
/// - `>= 1280px`: `56px` icon rail + `264px` sidebar + main workspace
/// - `960..1279px`: `56px` icon rail + `232px` sidebar + main workspace
/// - `600..959px`: `52px` icon rail + drawer + main workspace
/// - `< 600px`: bottom 4-tab navigation bar + drawer + main workspace
class BlinkWorkspaceShell extends StatefulWidget {
  const BlinkWorkspaceShell({required this.workspace, super.key});

  final BlinkWorkspaceController workspace;

  @override
  State<BlinkWorkspaceShell> createState() => _BlinkWorkspaceShellState();
}

class _BlinkWorkspaceShellState extends State<BlinkWorkspaceShell>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FocusNode _editorFocusNode = FocusNode();

  late final BlinkEditorController _editorController = BlinkEditorController(
    vaultProvider: () => widget.workspace.vault,
  );
  late final BlinkSearchController _searchController = BlinkSearchController(
    vaultProvider: () => widget.workspace.vault,
  );
  late final BlinkTasksController _tasksController = BlinkTasksController(
    vaultProvider: () => widget.workspace.vault,
  );

  VaultManager? _lastBoundVault;
  bool _searchDialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.workspace.registerDraftFlushHook(_editorController.flushDraftNow);
    widget.workspace.addListener(_onWorkspaceChanged);
    _syncVaultBinding();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.workspace.removeListener(_onWorkspaceChanged);
    widget.workspace.registerDraftFlushHook(null);
    _editorFocusNode.dispose();
    _editorController.dispose();
    _searchController.dispose();
    _tasksController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_editorController.flushDraftNow());
    } else if (state == AppLifecycleState.resumed) {
      widget.workspace.sync.onAppResumed();
    }
  }

  Future<void> _openSyncConflictDialog() async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => BlinkSyncConflictDialog(sync: widget.workspace.sync),
    );
  }

  void _onWorkspaceChanged() {
    _syncVaultBinding();
  }

  void _syncVaultBinding() {
    final current = widget.workspace.vault;
    if (!identical(current, _lastBoundVault)) {
      _lastBoundVault = current;
      _searchController.clear();
      unawaited(_tasksController.bindVault(current));
      unawaited(_editorController.loadInboxDraft(resetIfMissing: true));
    }
  }

  Future<void> _openSearchModal() async {
    if (_searchDialogVisible || !mounted) {
      return;
    }
    _searchDialogVisible = true;
    widget.workspace.setSearchModalOpen(true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return BlinkSearchModal(
            controller: _searchController,
            onClose: () => Navigator.of(dialogContext).pop(),
            onSelectHit: (hit) {
              Navigator.of(dialogContext).pop();
              unawaited(_jumpToSearchHit(hit));
            },
          );
        },
      );
    } finally {
      _searchDialogVisible = false;
      widget.workspace.setSearchModalOpen(false);
    }
  }

  Future<void> _jumpToSearchHit(FtsSearchHit hit) async {
    if (hit.docKind == 'entry') {
      await widget.workspace.openEntryById(hit.docId);
      final entry = await widget.workspace.vault?.raw.getEntryById(
        hit.docId,
        includeDeleted: true,
      );
      if (entry != null && !entry.isDeleted) {
        await _editorController.startEditingEntry(entry);
      }
    } else if (hit.docKind == 'task') {
      widget.workspace.setDestination(BlinkNavDestination.tasks);
    }
  }

  void _focusComposerShortcut() {
    widget.workspace.setDestination(BlinkNavDestination.stream);
    if (widget.workspace.streamFilter == StreamFilterKind.trash) {
      widget.workspace.setStreamFilter(StreamFilterKind.all);
    }
    unawaited(_editorController.startNewEntry());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editorFocusNode.requestFocus();
      }
    });
  }

  void _dismissOverlaysShortcut() {
    if (_editorController.showAutocomplete) {
      _editorController.dismissAutocomplete();
      return;
    }
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }
    widget.workspace.clearBanner();
  }

  Future<void> _attachBlobToNewEntry(MediaBlob blob) async {
    widget.workspace.setDestination(BlinkNavDestination.stream);
    if (widget.workspace.streamFilter == StreamFilterKind.trash) {
      widget.workspace.setStreamFilter(StreamFilterKind.all);
    }
    await _editorController.startNewEntry();
    _editorController.attachBlobSha256(blob.sha256);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editorFocusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _focusComposerShortcut,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _focusComposerShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            unawaited(_openSearchModal()),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            unawaited(_openSearchModal()),
        const SingleActivator(
          LogicalKeyboardKey.keyP,
          control: true,
          shift: true,
        ): widget.workspace.toggleSplitPreview,
        const SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true):
            widget.workspace.toggleSplitPreview,
        const SingleActivator(LogicalKeyboardKey.escape):
            _dismissOverlaysShortcut,
      },
      child: Focus(
        autofocus: false,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            widget.workspace,
            widget.workspace.lifecycle,
          ]),
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isWideDesktop = width >= 1280;
                final isStandardDesktop = width >= 960 && width < 1280;
                final isCompactTablet = width >= 600 && width < 960;
                final isMobile = width < 600;

                final isStream =
                    widget.workspace.destination == BlinkNavDestination.stream;
                final showPersistentSidebar =
                    (isWideDesktop || isStandardDesktop) && isStream;
                final railWidth = isCompactTablet ? 52.0 : 56.0;
                final sidebarWidth = isWideDesktop ? 264.0 : 232.0;

                final workspaceContent = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    BlinkSyncStatusCapsule(
                      sync: widget.workspace.sync,
                      compact: isMobile,
                      onOpenConflicts: () =>
                          unawaited(_openSyncConflictDialog()),
                      onOpenSyncSettings: () => widget.workspace.setDestination(
                        BlinkNavDestination.settings,
                      ),
                    ),
                    if (widget.workspace.bannerMessage != null)
                      _StatusBanner(
                        message: widget.workspace.bannerMessage!,
                        isError: widget.workspace.bannerIsError,
                        onDismiss: widget.workspace.clearBanner,
                      ),
                    if (widget.workspace.vaultErrorMessage != null &&
                        widget.workspace.destination !=
                            BlinkNavDestination.settings)
                      _StatusBanner(
                        message: widget.workspace.vaultErrorMessage!,
                        isError: true,
                        actionLabel: '前往设置',
                        onAction: () => widget.workspace.setDestination(
                          BlinkNavDestination.settings,
                        ),
                        onDismiss: widget.workspace.clearVaultError,
                      ),
                    Expanded(child: _buildActivePage(isMobile: isMobile)),
                  ],
                );

                return Scaffold(
                  key: _scaffoldKey,
                  backgroundColor: tokens.canvas,
                  drawer: (isCompactTablet || isMobile)
                      ? Drawer(
                          backgroundColor: tokens.sidebar,
                          surfaceTintColor: Colors.transparent,
                          child: SafeArea(
                            child: _StreamFilterSidebar(
                              workspace: widget.workspace,
                              onCloseDrawer: () =>
                                  _scaffoldKey.currentState?.closeDrawer(),
                            ),
                          ),
                        )
                      : null,
                  bottomNavigationBar:
                      isMobile && MediaQuery.viewInsetsOf(context).bottom == 0
                      ? _buildMobileBottomBar(tokens)
                      : null,
                  body: SafeArea(
                    top: isMobile,
                    bottom: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        if (!isMobile) ...<Widget>[
                          _buildNavigationRail(
                            tokens,
                            railWidth,
                            showDrawerToggle: isCompactTablet && isStream,
                          ),
                          VerticalDivider(
                            key: const Key('pane_divider_rail'),
                            width: 1,
                            thickness: 1,
                            color: tokens.borderHairline,
                          ),
                        ],
                        if (showPersistentSidebar) ...<Widget>[
                          SizedBox(
                            width: sidebarWidth,
                            child: ColoredBox(
                              color: tokens.sidebar,
                              child: _StreamFilterSidebar(
                                workspace: widget.workspace,
                              ),
                            ),
                          ),
                          VerticalDivider(
                            key: const Key('pane_divider_sidebar'),
                            width: 1,
                            thickness: 1,
                            color: tokens.borderHairline,
                          ),
                        ],
                        Expanded(child: workspaceContent),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildNavigationRail(
    BlinkColorTokens tokens,
    double width, {
    required bool showDrawerToggle,
  }) {
    final active = widget.workspace.destination;

    Widget railAction({
      required Key itemKey,
      required IconData icon,
      required String tooltip,
      required VoidCallback onTap,
      bool selected = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            width: width - 12,
            height: 40,
            margin: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: selected ? tokens.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 20,
              color: selected ? tokens.accentPrimary : tokens.textSecondary,
            ),
          ),
        ),
      );
    }

    Widget railDestination({
      required Key itemKey,
      required BlinkNavDestination destination,
      required IconData icon,
      required String tooltip,
    }) {
      return railAction(
        itemKey: itemKey,
        icon: icon,
        tooltip: tooltip,
        selected: active == destination,
        onTap: () => widget.workspace.setDestination(destination),
      );
    }

    return Container(
      key: const Key('desktop_nav_rail'),
      width: width,
      color: tokens.sidebar,
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: <Widget>[
          if (showDrawerToggle) ...<Widget>[
            railAction(
              itemKey: const Key('open_sidebar_drawer_button'),
              icon: Icons.menu_rounded,
              tooltip: '筛选与标签',
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SizedBox(
                width: 24,
                child: Divider(height: 1, color: tokens.borderHairline),
              ),
            ),
          ],
          railDestination(
            itemKey: const Key('nav_stream'),
            destination: BlinkNavDestination.stream,
            icon: Icons.bolt_rounded,
            tooltip: '采集流与 BFM 编辑器',
          ),
          railDestination(
            itemKey: const Key('nav_files'),
            destination: BlinkNavDestination.files,
            icon: Icons.folder_outlined,
            tooltip: '文件与附件管理',
          ),
          railDestination(
            itemKey: const Key('nav_tasks'),
            destination: BlinkNavDestination.tasks,
            icon: Icons.check_circle_outline_rounded,
            tooltip: '内生待办',
          ),
          const Spacer(),
          railAction(
            itemKey: const Key('open_search_button'),
            icon: Icons.search_rounded,
            tooltip: '全局搜索 (Ctrl+K)',
            onTap: () => unawaited(_openSearchModal()),
          ),
          BlinkSyncRailDot(
            sync: widget.workspace.sync,
            onTap: () {
              if (widget.workspace.sync.openConflictCount > 0) {
                unawaited(_openSyncConflictDialog());
              } else {
                widget.workspace.setDestination(BlinkNavDestination.settings);
              }
            },
          ),
          railDestination(
            itemKey: const Key('nav_settings'),
            destination: BlinkNavDestination.settings,
            icon: Icons.settings_outlined,
            tooltip: '便携库与设置',
          ),
        ],
      ),
    );
  }

  Widget _buildMobileBottomBar(BlinkColorTokens tokens) {
    final active = widget.workspace.destination;

    Widget tab({
      required Key itemKey,
      required BlinkNavDestination destination,
      required IconData icon,
      required String label,
    }) {
      final selected = active == destination;
      final color = selected ? tokens.accentPrimary : tokens.textSecondary;
      return Expanded(
        child: InkWell(
          key: itemKey,
          onTap: () => widget.workspace.setDestination(destination),
          child: SizedBox(
            height: 54,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 20, color: color),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.metaLabel(tokens, color: color),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Container(
        key: const Key('mobile_bottom_nav'),
        decoration: BoxDecoration(
          color: tokens.sidebar,
          border: Border(
            top: BorderSide(color: tokens.borderHairline, width: 1),
          ),
        ),
        child: Row(
          children: <Widget>[
            tab(
              itemKey: const Key('nav_stream'),
              destination: BlinkNavDestination.stream,
              icon: Icons.bolt_rounded,
              label: '采集流',
            ),
            tab(
              itemKey: const Key('nav_files'),
              destination: BlinkNavDestination.files,
              icon: Icons.folder_outlined,
              label: '文件',
            ),
            tab(
              itemKey: const Key('nav_tasks'),
              destination: BlinkNavDestination.tasks,
              icon: Icons.check_circle_outline_rounded,
              label: '待办',
            ),
            tab(
              itemKey: const Key('nav_settings'),
              destination: BlinkNavDestination.settings,
              icon: Icons.settings_outlined,
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivePage({required bool isMobile}) {
    switch (widget.workspace.destination) {
      case BlinkNavDestination.stream:
        return BlinkStreamPage(
          workspace: widget.workspace,
          editor: _editorController,
          editorFocusNode: _editorFocusNode,
          onOpenFilterDrawer: isMobile
              ? () => _scaffoldKey.currentState?.openDrawer()
              : null,
          onOpenSearch: isMobile ? () => unawaited(_openSearchModal()) : null,
        );
      case BlinkNavDestination.files:
        return BlinkFilesPage(
          workspace: widget.workspace,
          onAttachToNewEntry: (blob) => unawaited(_attachBlobToNewEntry(blob)),
        );
      case BlinkNavDestination.tasks:
        return BlinkTasksPage(
          controller: _tasksController,
          onJumpToEntry: (entryId) async {
            await widget.workspace.openEntryById(entryId);
            final entry = await widget.workspace.vault?.raw.getEntryById(
              entryId,
              includeDeleted: true,
            );
            if (entry != null && !entry.isDeleted) {
              await _editorController.startEditingEntry(entry);
            }
          },
        );
      case BlinkNavDestination.settings:
        return BlinkSettingsPage(workspace: widget.workspace);
    }
  }
}

class _StreamFilterSidebar extends StatelessWidget {
  const _StreamFilterSidebar({required this.workspace, this.onCloseDrawer});

  final BlinkWorkspaceController workspace;
  final VoidCallback? onCloseDrawer;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final stats = workspace.stats;
    final sortedTags = workspace.tagCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    Widget navRow({
      required Key itemKey,
      required IconData icon,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      int? count,
      Color? accentOverride,
    }) {
      final fg = selected
          ? (accentOverride ?? tokens.accentPrimary)
          : tokens.textPrimary;
      return InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          onTap();
          onCloseDrawer?.call();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? tokens.accentSubtle : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 16,
                color: selected
                    ? (accentOverride ?? tokens.accentPrimary)
                    : (accentOverride ?? tokens.textSecondary),
              ),
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
              if (count != null)
                Text(
                  '$count',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
                ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
      children: <Widget>[
        Text('视图筛选', style: BlinkTypography.metaLabel(tokens)),
        const SizedBox(height: 6),
        navRow(
          itemKey: const Key('filter_all'),
          icon: Icons.all_inbox_outlined,
          label: '全部记录',
          count: stats?.activeEntries,
          selected: workspace.streamFilter == StreamFilterKind.all,
          onTap: () => workspace.setStreamFilter(StreamFilterKind.all),
        ),
        navRow(
          itemKey: const Key('filter_private'),
          icon: Icons.lock_outline_rounded,
          label: '#private 私密',
          count: stats?.privateEntries,
          accentOverride: tokens.privacyPrivate,
          selected: workspace.streamFilter == StreamFilterKind.privateOnly,
          onTap: () => workspace.setStreamFilter(StreamFilterKind.privateOnly),
        ),
        navRow(
          itemKey: const Key('filter_trash'),
          icon: Icons.delete_outline_rounded,
          label: '30 天回收站',
          count: stats?.trashedEntries,
          selected: workspace.streamFilter == StreamFilterKind.trash,
          onTap: () => workspace.setStreamFilter(StreamFilterKind.trash),
        ),
        const SizedBox(height: 16),
        Text('标签', style: BlinkTypography.metaLabel(tokens)),
        const SizedBox(height: 6),
        if (sortedTags.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              '尚无标签',
              style: BlinkTypography.metaLabel(tokens, color: tokens.textMuted),
            ),
          )
        else
          for (final tagEntry in sortedTags)
            navRow(
              itemKey: Key('filter_tag_${tagEntry.key}'),
              icon: Icons.tag_rounded,
              label: '#${tagEntry.key}',
              count: tagEntry.value,
              selected:
                  workspace.streamFilter == StreamFilterKind.tag &&
                  workspace.selectedTag == tagEntry.key,
              onTap: () => workspace.setStreamFilter(
                StreamFilterKind.tag,
                tag: tagEntry.key,
              ),
            ),
      ],
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.isError,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final bool isError;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final bg = isError ? tokens.statusErrSubtle : tokens.accentSubtle;
    final fg = isError ? tokens.statusErr : tokens.accentPrimary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 16,
            color: fg,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: BlinkTypography.metaLabel(tokens, color: fg),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关闭提示',
            onPressed: onDismiss,
            icon: Icon(Icons.close_rounded, size: 16, color: fg),
          ),
        ],
      ),
    );
  }
}
