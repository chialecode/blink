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
import 'package:blink_client/ui/desktop_window_chrome.dart';
import 'package:blink_client/ui/files_page.dart';
import 'package:blink_client/ui/memos_page.dart';
import 'package:blink_client/ui/notes_page.dart';
import 'package:blink_client/ui/search_modal.dart';
import 'package:blink_client/ui/settings_page.dart';
import 'package:blink_client/ui/sync_conflict_dialog.dart';
import 'package:blink_client/ui/sync_status_capsule.dart';
import 'package:blink_client/ui/tasks_page.dart';

/// Feishu-style 4-breakpoint adaptive workspace shell (`docs/ui.md` §1):
/// - `>= 1280px`: `60px` icon rail + collapsible `260px` resource sidebar + main panel
/// - `960..1279px`: `60px` icon rail + collapsible `232px` resource sidebar + main panel
/// - `600..959px`: `52px` icon rail + contextual sidebar drawer + main panel
/// - `< 600px`: minimal `52px` 4-tab bottom nav (`小记`/`笔记`/`待办`/`设置`) + drawer
class BlinkWorkspaceShell extends StatefulWidget {
  const BlinkWorkspaceShell({required this.workspace, super.key});

  final BlinkWorkspaceController workspace;

  @override
  State<BlinkWorkspaceShell> createState() => _BlinkWorkspaceShellState();
}

class _BlinkWorkspaceShellState extends State<BlinkWorkspaceShell>
    with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FocusNode _memoComposerFocusNode = FocusNode();

  late final BlinkEditorController _memoEditorController =
      BlinkEditorController(vaultProvider: () => widget.workspace.vault);
  late final BlinkSearchController _searchController = BlinkSearchController(
    vaultProvider: () => widget.workspace.vault,
  );
  late final BlinkTasksController _tasksController = BlinkTasksController(
    vaultProvider: () => widget.workspace.vault,
  );
  late final BlinkFilesController _filesController = BlinkFilesController();

  VaultManager? _lastBoundVault;
  bool _searchDialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.workspace.addDraftFlushHook(_memoEditorController.flushDraftNow);
    widget.workspace.addListener(_onWorkspaceChanged);
    _syncVaultBinding();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.workspace.removeListener(_onWorkspaceChanged);
    widget.workspace.removeDraftFlushHook(_memoEditorController.flushDraftNow);
    _memoComposerFocusNode.dispose();
    _memoEditorController.dispose();
    _searchController.dispose();
    _tasksController.dispose();
    _filesController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_memoEditorController.flushDraftNow());
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
      unawaited(_memoEditorController.loadInboxDraft(resetIfMissing: true));
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
            workspace: widget.workspace,
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
      await _jumpToEntryId(hit.docId);
    } else if (hit.docKind == 'task') {
      widget.workspace.setDestination(BlinkNavDestination.tasks);
    }
  }

  Future<void> _jumpToEntryId(String entryId) async {
    await widget.workspace.openEntryById(entryId);
  }

  void _handleNewShortcut() {
    if (widget.workspace.destination == BlinkNavDestination.notes) {
      unawaited(widget.workspace.createNote());
      return;
    }
    widget.workspace.setDestination(BlinkNavDestination.memos);
    if (widget.workspace.selectedMemoFilter == MemoFilterKind.trash) {
      widget.workspace.selectMemoFilter(MemoFilterKind.all);
    }
    unawaited(_memoEditorController.startNewEntry());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _memoComposerFocusNode.requestFocus();
      }
    });
  }

  void _handleToggleNoteEditorModeShortcut() {
    if (widget.workspace.destination != BlinkNavDestination.notes) {
      return;
    }
    widget.workspace.toggleNoteEditorMode();
  }

  void _dismissOverlaysShortcut() {
    if (_memoEditorController.showAutocomplete) {
      _memoEditorController.dismissAutocomplete();
      return;
    }
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }
    widget.workspace.clearBanner();
  }

  Future<void> _attachBlobToNewNote(MediaBlob blob) async {
    final created = await widget.workspace.createNote(
      imageBlobSha256s: <String>[blob.sha256],
    );
    if (created != null) {
      widget.workspace.setDestination(BlinkNavDestination.notes);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _handleNewShortcut,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
            _handleNewShortcut,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            unawaited(_openSearchModal()),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            unawaited(_openSearchModal()),
        const SingleActivator(LogicalKeyboardKey.backslash, control: true):
            widget.workspace.toggleSidebarCollapsed,
        const SingleActivator(LogicalKeyboardKey.backslash, meta: true):
            widget.workspace.toggleSidebarCollapsed,
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            _handleToggleNoteEditorModeShortcut,
        const SingleActivator(LogicalKeyboardKey.slash, meta: true):
            _handleToggleNoteEditorModeShortcut,
        const SingleActivator(LogicalKeyboardKey.escape):
            _dismissOverlaysShortcut,
      },
      child: Focus(
        autofocus: true,
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            widget.workspace,
            widget.workspace.lifecycle,
            widget.workspace.sync,
          ]),
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final isWideDesktop = width >= 1280;
                final isStandardDesktop = width >= 960 && width < 1280;
                final isCompactTablet = width >= 600 && width < 960;
                final isMobile = width < 600;

                final isDesktopWithSidebar = isWideDesktop || isStandardDesktop;
                final showPersistentSidebar =
                    isDesktopWithSidebar && !widget.workspace.sidebarCollapsed;
                final showExpandSidebarButton =
                    isDesktopWithSidebar && widget.workspace.sidebarCollapsed;
                final railWidth = isCompactTablet ? 52.0 : 60.0;
                final sidebarWidth = isWideDesktop ? 260.0 : 232.0;

                final lifecycle = widget.workspace.lifecycle;
                final useImmersiveChrome =
                    !isMobile && lifecycle.useImmersiveWindowChrome;
                final showTrailingCaptionButtons =
                    useImmersiveChrome &&
                    lifecycle.showTrailingWindowCaptionButtons;
                final trailingCaptionInset = showTrailingCaptionButtons
                    ? kBlinkWindowCaptionWidth
                    : 0.0;
                final leadingTrafficLightInset =
                    useImmersiveChrome &&
                        lifecycle.usesLeadingSystemWindowControls
                    ? kBlinkMacTrafficLightTopInset
                    : 0.0;

                final showGlobalSyncBanner =
                    BlinkSyncStatusCapsule.shouldShowGlobalBanner(
                      widget.workspace.sync.uiStatus,
                    );
                final showBannerMessage =
                    widget.workspace.bannerMessage != null;
                final showVaultErrorBanner =
                    widget.workspace.vaultErrorMessage != null &&
                    (widget.workspace.destination !=
                            BlinkNavDestination.settings ||
                        widget.workspace.selectedSettingsCategory !=
                            SettingsCategory.storage);
                final hasTopGlobalBanner =
                    showGlobalSyncBanner ||
                    showBannerMessage ||
                    showVaultErrorBanner;

                final syncBannerAtTop = showGlobalSyncBanner;
                final statusBannerAtTop =
                    !showGlobalSyncBanner && showBannerMessage;
                final vaultErrorBannerAtTop =
                    !showGlobalSyncBanner &&
                    !showBannerMessage &&
                    showVaultErrorBanner;

                final onStartDrag = useImmersiveChrome
                    ? () => unawaited(lifecycle.startWindowDrag())
                    : null;
                final onToggleMaximize = useImmersiveChrome
                    ? () => unawaited(lifecycle.toggleMaximizeWindow())
                    : null;
                final onShowSystemMenu = useImmersiveChrome
                    ? (Offset position) =>
                          unawaited(lifecycle.showWindowSystemMenu(position))
                    : null;

                final activePage = _buildActivePage(
                  isMobile: isMobile,
                  isCompactTablet: isCompactTablet,
                  showPersistentSidebar: showPersistentSidebar,
                  showExpandSidebarButton: showExpandSidebarButton,
                );

                final workspaceContent = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (showGlobalSyncBanner)
                      BlinkSyncStatusCapsule(
                        sync: widget.workspace.sync,
                        compact: isMobile,
                        trailingChromeInset: syncBannerAtTop
                            ? trailingCaptionInset
                            : 0.0,
                        enableWindowDrag: syncBannerAtTop && useImmersiveChrome,
                        onOpenConflicts: () =>
                            unawaited(_openSyncConflictDialog()),
                        onOpenSyncSettings: () => widget.workspace
                            .openSettingsCategory(SettingsCategory.sync),
                      ),
                    if (showBannerMessage)
                      _StatusBanner(
                        message: widget.workspace.bannerMessage!,
                        isError: widget.workspace.bannerIsError,
                        onDismiss: widget.workspace.clearBanner,
                        trailingChromeInset: statusBannerAtTop
                            ? trailingCaptionInset
                            : 0.0,
                        enableWindowDrag:
                            statusBannerAtTop && useImmersiveChrome,
                      ),
                    if (showVaultErrorBanner)
                      _StatusBanner(
                        message: widget.workspace.vaultErrorMessage!,
                        isError: true,
                        actionLabel: '前往设置',
                        onAction: () => widget.workspace.openSettingsCategory(
                          SettingsCategory.storage,
                        ),
                        onDismiss: widget.workspace.clearVaultError,
                        trailingChromeInset: vaultErrorBannerAtTop
                            ? trailingCaptionInset
                            : 0.0,
                        enableWindowDrag:
                            vaultErrorBannerAtTop && useImmersiveChrome,
                      ),
                    Expanded(
                      child: hasTopGlobalBanner && showTrailingCaptionButtons
                          ? BlinkWindowChromeScope(
                              enabled: useImmersiveChrome,
                              trailingCaptionInset: 0.0,
                              onStartDrag: onStartDrag,
                              onToggleMaximize: onToggleMaximize,
                              onShowSystemMenu: onShowSystemMenu,
                              child: activePage,
                            )
                          : activePage,
                    ),
                  ],
                );

                return BlinkWindowChromeScope(
                  enabled: useImmersiveChrome,
                  trailingCaptionInset: trailingCaptionInset,
                  leadingTrafficLightInset: leadingTrafficLightInset,
                  onStartDrag: onStartDrag,
                  onToggleMaximize: onToggleMaximize,
                  onShowSystemMenu: onShowSystemMenu,
                  onMaximizeButtonBoundsChanged: showTrailingCaptionButtons
                      ? lifecycle.updateMaximizeButtonBounds
                      : null,
                  child: Scaffold(
                    key: _scaffoldKey,
                    backgroundColor: tokens.canvas,
                    drawer: (isCompactTablet || isMobile)
                        ? Drawer(
                            backgroundColor: tokens.sidebar,
                            surfaceTintColor: Colors.transparent,
                            child: SafeArea(
                              child: _buildContextualSidebar(isDrawer: true),
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
                      child: Stack(
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (!isMobile) ...<Widget>[
                                _buildNavigationRail(
                                  tokens,
                                  railWidth,
                                  isCompactTablet: isCompactTablet,
                                  leadingTrafficLightInset:
                                      leadingTrafficLightInset,
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
                                  key: const Key('resource_sidebar_pane'),
                                  width: sidebarWidth,
                                  child: ColoredBox(
                                    color: tokens.sidebar,
                                    child: _buildContextualSidebar(
                                      isDrawer: false,
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
                          if (showTrailingCaptionButtons)
                            Positioned(
                              top: 0,
                              right: 0,
                              height: kBlinkWindowChromeHeaderHeight,
                              child: BlinkWindowCaptionButtons(
                                isMaximized: lifecycle.isWindowMaximized,
                                onMinimize: () =>
                                    unawaited(lifecycle.minimizeWindow()),
                                onToggleMaximize: () =>
                                    unawaited(lifecycle.toggleMaximizeWindow()),
                                onClose: () => unawaited(
                                  lifecycle.handleCloseButtonPressed(),
                                ),
                              ),
                            ),
                        ],
                      ),
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

  Widget _buildContextualSidebar({required bool isDrawer}) {
    void closeDrawerIfNeeded() {
      if (isDrawer) {
        _scaffoldKey.currentState?.closeDrawer();
      }
    }

    final onCollapse = isDrawer
        ? null
        : () => widget.workspace.setSidebarCollapsed(true);

    switch (widget.workspace.destination) {
      case BlinkNavDestination.memos:
        return BlinkMemosSidebar(
          workspace: widget.workspace,
          isDrawer: isDrawer,
          onItemSelected: isDrawer ? closeDrawerIfNeeded : null,
          onCollapse: onCollapse,
        );
      case BlinkNavDestination.notes:
        return BlinkNotesSidebar(
          workspace: widget.workspace,
          isDrawer: isDrawer,
          onItemSelected: isDrawer ? closeDrawerIfNeeded : null,
          onCollapse: onCollapse,
        );
      case BlinkNavDestination.tasks:
        return BlinkTasksSidebar(
          controller: _tasksController,
          isDrawer: isDrawer,
          onItemSelected: isDrawer ? closeDrawerIfNeeded : null,
          onCollapse: onCollapse,
        );
      case BlinkNavDestination.files:
        return BlinkFilesSidebar(
          workspace: widget.workspace,
          controller: _filesController,
          isDrawer: isDrawer,
          onItemSelected: isDrawer ? closeDrawerIfNeeded : null,
          onCollapse: onCollapse,
        );
      case BlinkNavDestination.settings:
        return BlinkSettingsSidebar(
          workspace: widget.workspace,
          isDrawer: isDrawer,
          onItemSelected: isDrawer ? closeDrawerIfNeeded : null,
          onCollapse: onCollapse,
        );
    }
  }

  Widget _buildNavigationRail(
    BlinkColorTokens tokens,
    double width, {
    required bool isCompactTablet,
    required double leadingTrafficLightInset,
  }) {
    final active = widget.workspace.destination;
    final itemWidth = width - (isCompactTablet ? 8 : 10);

    Widget railIconAction({
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
            width: itemWidth,
            height: 36,
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: selected ? tokens.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              icon,
              size: 19,
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
      required String label,
    }) {
      final selected = active == destination;
      final fg = selected ? tokens.accentPrimary : tokens.textSecondary;
      return Tooltip(
        message: label,
        child: InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(8),
          onTap: () => widget.workspace.setDestination(destination),
          child: Container(
            width: itemWidth,
            padding: const EdgeInsets.symmetric(vertical: 6),
            margin: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: selected ? tokens.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(icon, size: 19, color: fg),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: fg,
                  ).copyWith(fontSize: 10.5, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('desktop_nav_rail'),
      width: width,
      color: tokens.sidebar,
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: <Widget>[
          BlinkWindowDragArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (leadingTrafficLightInset > 0)
                  SizedBox(height: leadingTrafficLightInset),
                const SizedBox(
                  height: kBlinkWindowChromeHeaderHeight,
                  width: double.infinity,
                  child: Center(
                    child: IgnorePointer(
                      child: BlinkBrandMark(
                        key: Key('rail_brand_mark'),
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          if (isCompactTablet) ...<Widget>[
            railIconAction(
              itemKey: const Key('open_sidebar_drawer_button'),
              icon: Icons.menu_rounded,
              tooltip: '展开侧边栏',
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                width: 24,
                child: Divider(height: 1, color: tokens.borderHairline),
              ),
            ),
          ],
          railDestination(
            itemKey: const Key('nav_memos'),
            destination: BlinkNavDestination.memos,
            icon: Icons.bolt_rounded,
            label: '小记',
          ),
          railDestination(
            itemKey: const Key('nav_notes'),
            destination: BlinkNavDestination.notes,
            icon: Icons.description_outlined,
            label: '笔记',
          ),
          railDestination(
            itemKey: const Key('nav_tasks'),
            destination: BlinkNavDestination.tasks,
            icon: Icons.check_circle_outline_rounded,
            label: '待办',
          ),
          railDestination(
            itemKey: const Key('nav_files'),
            destination: BlinkNavDestination.files,
            icon: Icons.attach_file_rounded,
            label: '附件',
          ),
          const Spacer(),
          railIconAction(
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
                widget.workspace.openSettingsCategory(SettingsCategory.sync);
              }
            },
          ),
          railDestination(
            itemKey: const Key('nav_settings'),
            destination: BlinkNavDestination.settings,
            icon: Icons.settings_outlined,
            label: '设置',
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
          onTap: () {
            if (destination == BlinkNavDestination.notes) {
              widget.workspace.clearPendingMobileNoteOpen();
            }
            widget.workspace.setDestination(destination);
          },
          child: SizedBox(
            height: 52,
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
              itemKey: const Key('nav_memos'),
              destination: BlinkNavDestination.memos,
              icon: Icons.bolt_rounded,
              label: '小记',
            ),
            tab(
              itemKey: const Key('nav_notes'),
              destination: BlinkNavDestination.notes,
              icon: Icons.description_outlined,
              label: '笔记',
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

  Widget _buildActivePage({
    required bool isMobile,
    required bool isCompactTablet,
    required bool showPersistentSidebar,
    required bool showExpandSidebarButton,
  }) {
    final openDrawer = (isMobile || isCompactTablet)
        ? () => _scaffoldKey.currentState?.openDrawer()
        : null;
    void expandSidebar() => widget.workspace.setSidebarCollapsed(false);
    void openSearch() => unawaited(_openSearchModal());

    switch (widget.workspace.destination) {
      case BlinkNavDestination.memos:
        return BlinkMemosPage(
          workspace: widget.workspace,
          isMobile: isMobile,
          onOpenDrawer: openDrawer,
          onExpandSidebar: expandSidebar,
          showExpandSidebarButton: showExpandSidebarButton,
          onOpenSearch: openSearch,
          composerFocusNode: _memoComposerFocusNode,
          editor: _memoEditorController,
        );
      case BlinkNavDestination.notes:
        return BlinkNotesPage(
          workspace: widget.workspace,
          isMobile: isMobile,
          onOpenDrawer: openDrawer,
          onExpandSidebar: expandSidebar,
          showExpandSidebarButton: showExpandSidebarButton,
          onOpenSearch: openSearch,
        );
      case BlinkNavDestination.tasks:
        return BlinkTasksPage(
          controller: _tasksController,
          workspace: widget.workspace,
          onJumpToEntry: (entryId) => unawaited(_jumpToEntryId(entryId)),
          showInlineFilters: !showPersistentSidebar,
          isMobile: isMobile,
          onOpenDrawer: openDrawer,
          onOpenSearch: openSearch,
          onExpandSidebar: expandSidebar,
          showExpandSidebarButton: showExpandSidebarButton,
        );
      case BlinkNavDestination.files:
        return BlinkFilesPage(
          workspace: widget.workspace,
          controller: _filesController,
          onAttachToNewEntry: (blob) => unawaited(_attachBlobToNewNote(blob)),
          showInlineFilters: !showPersistentSidebar,
          isMobile: isMobile,
          onOpenDrawer: openDrawer,
          onExpandSidebar: expandSidebar,
          showExpandSidebarButton: showExpandSidebarButton,
        );
      case BlinkNavDestination.settings:
        return BlinkSettingsPage(
          workspace: widget.workspace,
          isMobile: isMobile,
          showCompactCategorySwitcher: isCompactTablet,
          onOpenDrawer: isCompactTablet ? openDrawer : null,
          onExpandSidebar: expandSidebar,
          showExpandSidebarButton: showExpandSidebarButton,
        );
    }
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.message,
    required this.isError,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
    this.trailingChromeInset = 0.0,
    this.enableWindowDrag = false,
  });

  final String message;
  final bool isError;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;
  final double trailingChromeInset;
  final bool enableWindowDrag;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final bg = isError ? tokens.statusErrSubtle : tokens.accentSubtle;
    final fg = isError ? tokens.statusErr : tokens.accentPrimary;

    return Container(
      constraints: BoxConstraints(
        minHeight: trailingChromeInset > 0 ? kBlinkWindowChromeHeaderHeight : 0,
      ),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: BlinkWindowDragArea(
        enabled: enableWindowDrag,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            8,
            trailingChromeInset > 0 ? 8 + trailingChromeInset : 16,
            8,
          ),
          child: Row(
            children: <Widget>[
              IgnorePointer(
                child: Icon(
                  isError
                      ? Icons.error_outline_rounded
                      : Icons.info_outline_rounded,
                  size: 16,
                  color: fg,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: IgnorePointer(
                  child: Text(
                    message,
                    style: BlinkTypography.metaLabel(tokens, color: fg),
                  ),
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
        ),
      ),
    );
  }
}
