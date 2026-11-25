import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/search_controller.dart';
import 'package:blink_client/application/tasks_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/ui/files_page.dart';
import 'package:blink_client/ui/search_modal.dart';
import 'package:blink_client/ui/settings_page.dart';
import 'package:blink_client/ui/stream_page.dart';
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

class _BlinkWorkspaceShellState extends State<BlinkWorkspaceShell> {
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
    widget.workspace.registerDraftFlushHook(_editorController.flushDraftNow);
    widget.workspace.addListener(_onWorkspaceChanged);
    _syncVaultBinding();
  }

  @override
  void dispose() {
    widget.workspace.removeListener(_onWorkspaceChanged);
    widget.workspace.registerDraftFlushHook(null);
    _editorFocusNode.dispose();
    _editorController.dispose();
    _searchController.dispose();
    _tasksController.dispose();
    super.dispose();
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
    final buildInfo = widget.workspace.lifecycle.buildInfo;

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

                final showPersistentSidebar =
                    (isWideDesktop || isStandardDesktop) &&
                    widget.workspace.destination == BlinkNavDestination.stream;
                final railWidth = isCompactTablet ? 52.0 : 56.0;
                final sidebarWidth = isWideDesktop ? 264.0 : 232.0;

                return Scaffold(
                  key: _scaffoldKey,
                  backgroundColor: tokens.canvas,
                  appBar: _buildAppBar(
                    tokens,
                    buildInfo,
                    showDrawerToggle:
                        (isCompactTablet || isMobile) &&
                        widget.workspace.destination ==
                            BlinkNavDestination.stream,
                    isCompactWidth: isMobile,
                  ),
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
                  bottomNavigationBar: isMobile
                      ? _buildMobileBottomBar(tokens)
                      : null,
                  body: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
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
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (!isMobile)
                              _buildNavigationRail(tokens, railWidth),
                            if (showPersistentSidebar)
                              SizedBox(
                                width: sidebarWidth,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: tokens.sidebar,
                                    border: Border(
                                      right: BorderSide(
                                        color: tokens.borderHairline,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                  child: _StreamFilterSidebar(
                                    workspace: widget.workspace,
                                  ),
                                ),
                              ),
                            Expanded(child: _buildActivePage()),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    BlinkColorTokens tokens,
    BlinkBuildInfo buildInfo, {
    required bool showDrawerToggle,
    required bool isCompactWidth,
  }) {
    return AppBar(
      automaticallyImplyLeading: false,
      titleSpacing: isCompactWidth ? 12 : 16,
      leading: showDrawerToggle
          ? IconButton(
              key: const Key('open_sidebar_drawer_button'),
              tooltip: '筛选与标签',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: Icon(Icons.menu_rounded, color: tokens.textPrimary),
            )
          : null,
      title: Row(
        children: <Widget>[
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
      actions: <Widget>[
        IconButton(
          key: const Key('open_search_button'),
          tooltip: '全局 CJK 搜索 (Ctrl+K)',
          onPressed: () => unawaited(_openSearchModal()),
          icon: Icon(
            Icons.search_rounded,
            size: 20,
            color: tokens.textSecondary,
          ),
        ),
        if (widget.workspace.destination == BlinkNavDestination.stream)
          IconButton(
            key: const Key('toggle_preview_button'),
            tooltip: '分栏实时预览 (Ctrl+Shift+P)',
            onPressed: widget.workspace.toggleSplitPreview,
            icon: Icon(
              Icons.vertical_split_outlined,
              size: 20,
              color: widget.workspace.splitPreviewEnabled
                  ? tokens.accentPrimary
                  : tokens.textSecondary,
            ),
          ),
        const SizedBox(width: 6),
      ],
    );
  }

  Widget _buildNavigationRail(BlinkColorTokens tokens, double width) {
    final active = widget.workspace.destination;

    Widget railItem({
      required Key itemKey,
      required BlinkNavDestination destination,
      required IconData icon,
      required String tooltip,
    }) {
      final selected = active == destination;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(8),
          onTap: () => widget.workspace.setDestination(destination),
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

    return Container(
      key: const Key('desktop_nav_rail'),
      width: width,
      decoration: BoxDecoration(
        color: tokens.sidebar,
        border: Border(
          right: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: <Widget>[
          railItem(
            itemKey: const Key('nav_stream'),
            destination: BlinkNavDestination.stream,
            icon: Icons.bolt_rounded,
            tooltip: '采集流与 BFM 编辑器',
          ),
          railItem(
            itemKey: const Key('nav_files'),
            destination: BlinkNavDestination.files,
            icon: Icons.folder_outlined,
            tooltip: '文件与附件管理',
          ),
          railItem(
            itemKey: const Key('nav_tasks'),
            destination: BlinkNavDestination.tasks,
            icon: Icons.check_circle_outline_rounded,
            tooltip: '内生待办',
          ),
          const Spacer(),
          railItem(
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

  Widget _buildActivePage() {
    switch (widget.workspace.destination) {
      case BlinkNavDestination.stream:
        return BlinkStreamPage(
          workspace: widget.workspace,
          editor: _editorController,
          editorFocusNode: _editorFocusNode,
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
      padding: const EdgeInsets.all(12),
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
