import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/application/wysiwyg_document.dart';
import 'package:blink_client/ui/desktop_window_chrome.dart';

/// Obsidian/Feishu-style `44px` multi-tab bar placed at the top of the desktop
/// Notes workspace, aligned pixel-for-pixel with the `44px` sidebar header and
/// immersive top-right window caption buttons.
class BlinkNoteTabBar extends StatefulWidget {
  const BlinkNoteTabBar({
    required this.workspace,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    this.onBeforeSwitchOrCloseTab,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;
  final Future<void> Function()? onBeforeSwitchOrCloseTab;

  @override
  State<BlinkNoteTabBar> createState() => _BlinkNoteTabBarState();
}

class _BlinkNoteTabBarState extends State<BlinkNoteTabBar> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _tabKeys = <String, GlobalKey>{};
  String? _lastRevealedActiveId;
  int _lastTabCount = 0;
  double? _lastMaxTabsWidth;
  bool _revealScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.workspace.selectedNoteId != null) {
      _scheduleRevealActiveTab();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  GlobalKey _keyForTab(String noteId) =>
      _tabKeys.putIfAbsent(noteId, GlobalKey.new);

  void _pruneClosedTabKeys(List<RawEntry> tabs) {
    final openIds = <String>{for (final tab in tabs) tab.id};
    _tabKeys.removeWhere((id, _) => !openIds.contains(id));
  }

  void _scheduleRevealActiveTab() {
    if (_revealScheduled) {
      return;
    }
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      _revealActiveTabNow();
    });
  }

  void _revealActiveTabNow() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    final activeId = widget.workspace.selectedNoteId;
    if (activeId == null) {
      return;
    }
    final tabContext = _tabKeys[activeId]?.currentContext;
    if (tabContext == null || !tabContext.mounted) {
      return;
    }
    final renderObject = tabContext.findRenderObject();
    if (renderObject == null || !renderObject.attached) {
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    if (viewport == null) {
      return;
    }
    final position = _scrollController.position;
    final revealStart = viewport
        .getOffsetToReveal(renderObject, 0.0)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final revealEnd = viewport
        .getOffsetToReveal(renderObject, 1.0)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);

    if (revealEnd > revealStart) {
      // Tab is wider than viewport: keep leading edge (title start) visible.
      if (position.pixels != revealStart) {
        unawaited(
          Scrollable.ensureVisible(
            tabContext,
            alignment: 0.0,
            alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
            duration: Duration.zero,
          ),
        );
      }
    } else if (position.pixels < revealEnd) {
      unawaited(
        Scrollable.ensureVisible(
          tabContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          duration: Duration.zero,
        ),
      );
    } else if (position.pixels > revealStart) {
      unawaited(
        Scrollable.ensureVisible(
          tabContext,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          duration: Duration.zero,
        ),
      );
    }
  }

  void _handleTabStripPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) {
      return;
    }
    // Native horizontal scroll deltas are handled by SingleChildScrollView;
    // translate standard vertical mouse-wheel deltas into horizontal scrolling.
    if (event.scrollDelta.dx != 0 || event.scrollDelta.dy == 0) {
      return;
    }
    final delta = event.scrollDelta.dy;
    GestureBinding.instance.pointerSignalResolver.register(event, (
      PointerSignalEvent resolved,
    ) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final pos = _scrollController.position;
      final target = (pos.pixels + delta).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if (target != pos.pixels) {
        pos.jumpTo(target);
      }
    });
  }

  Future<void> _flushBeforeTabAction() async {
    final hook =
        widget.onBeforeSwitchOrCloseTab ?? widget.workspace.flushPendingDrafts;
    try {
      await hook();
    } catch (_) {}
  }

  Future<void> _activateTab(String noteId) async {
    if (widget.workspace.selectedNoteId == noteId) {
      return;
    }
    await _flushBeforeTabAction();
    widget.workspace.openNoteTab(noteId, activate: true);
  }

  Future<void> _closeTab(String noteId) async {
    await _flushBeforeTabAction();
    widget.workspace.closeNoteTab(noteId);
  }

  Future<void> _closeOtherTabs(String keepNoteId) async {
    await _flushBeforeTabAction();
    widget.workspace.closeOtherNoteTabs(keepNoteId);
  }

  Future<void> _closeTabsToRight(String noteId) async {
    await _flushBeforeTabAction();
    widget.workspace.closeNoteTabsToRight(noteId);
  }

  Future<void> _createNewTab() async {
    if (!widget.workspace.hasOpenVault) {
      return;
    }
    await _flushBeforeTabAction();
    await widget.workspace.createNote();
  }

  Future<void> _showTabContextMenu(
    BuildContext context,
    Offset globalPosition, {
    required RawEntry entry,
    required int index,
    required int totalCount,
  }) async {
    final tokens = BlinkColorTokens.of(context);
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final overlaySize = overlayBox?.size ?? const Size(1280, 800);
    final selected = await showMenu<String>(
      context: context,
      color: tokens.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        (overlaySize.width - globalPosition.dx).clamp(0.0, overlaySize.width),
        (overlaySize.height - globalPosition.dy).clamp(0.0, overlaySize.height),
      ),
      items: <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          key: Key('note_tab_menu_close'),
          value: 'close',
          child: Text('关闭标签页'),
        ),
        PopupMenuItem<String>(
          key: const Key('note_tab_menu_close_others'),
          value: 'close_others',
          enabled: totalCount > 1,
          child: const Text('关闭其他标签页'),
        ),
        PopupMenuItem<String>(
          key: const Key('note_tab_menu_close_right'),
          value: 'close_right',
          enabled: index < totalCount - 1,
          child: const Text('关闭右侧标签页'),
        ),
      ],
    );
    if (!mounted || selected == null) {
      return;
    }
    switch (selected) {
      case 'close':
        await _closeTab(entry.id);
      case 'close_others':
        await _closeOtherTabs(entry.id);
      case 'close_right':
        await _closeTabsToRight(entry.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final trailingInset = BlinkWindowChromeScope.trailingInsetOf(context);

    return ListenableBuilder(
      listenable: widget.workspace,
      builder: (context, _) {
        final tabs = widget.workspace.openNoteTabs;
        final activeId = widget.workspace.selectedNoteId;
        final hasExpand =
            widget.showExpandSidebarButton && widget.onExpandSidebar != null;
        _pruneClosedTabKeys(tabs);

        return ColoredBox(
          key: const Key('note_tab_bar'),
          color: tokens.sidebar,
          child: SizedBox(
            height: kBlinkWindowChromeHeaderHeight,
            child: BlinkWindowDragArea(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: 1,
                    child: IgnorePointer(
                      child: ColoredBox(color: tokens.borderHairline),
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final expandWidth = hasExpand ? 40.0 : 8.0;
                      const newButtonWidth = 40.0;
                      const minDragSpace = 36.0;
                      final maxTabsWidth =
                          (constraints.maxWidth -
                                  expandWidth -
                                  newButtonWidth -
                                  minDragSpace -
                                  trailingInset)
                              .clamp(0.0, double.infinity);

                      if (activeId != _lastRevealedActiveId ||
                          tabs.length != _lastTabCount ||
                          maxTabsWidth != _lastMaxTabsWidth) {
                        _lastRevealedActiveId = activeId;
                        _lastTabCount = tabs.length;
                        _lastMaxTabsWidth = maxTabsWidth;
                        if (activeId != null && tabs.isNotEmpty) {
                          _scheduleRevealActiveTab();
                        }
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (hasExpand)
                            Padding(
                              padding: const EdgeInsets.only(left: 6, right: 2),
                              child: Center(
                                child: IconButton(
                                  key: const Key('notes_sidebar_expand_button'),
                                  tooltip: '展开侧边栏 (Ctrl+\\)',
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: widget.onExpandSidebar,
                                  icon: Icon(
                                    Icons.menu_open_rounded,
                                    size: 18,
                                    color: tokens.textSecondary,
                                  ),
                                ),
                              ),
                            )
                          else
                            const SizedBox(width: 8),
                          if (tabs.isNotEmpty && maxTabsWidth > 0)
                            Listener(
                              key: const Key('note_tab_strip_scroll_listener'),
                              onPointerSignal: _handleTabStripPointerSignal,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: maxTabsWidth,
                                ),
                                child: SingleChildScrollView(
                                  controller: _scrollController,
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: <Widget>[
                                      for (var i = 0; i < tabs.length; i++)
                                        _NoteTabItem(
                                          key: _keyForTab(tabs[i].id),
                                          entry: tabs[i],
                                          isActive: tabs[i].id == activeId,
                                          showTrailingDivider:
                                              i < tabs.length - 1 &&
                                              tabs[i].id != activeId &&
                                              tabs[i + 1].id != activeId,
                                          onSelect: () => unawaited(
                                            _activateTab(tabs[i].id),
                                          ),
                                          onClose: () =>
                                              unawaited(_closeTab(tabs[i].id)),
                                          onSecondaryTapDown: (details) =>
                                              unawaited(
                                                _showTabContextMenu(
                                                  context,
                                                  details.globalPosition,
                                                  entry: tabs[i],
                                                  index: i,
                                                  totalCount: tabs.length,
                                                ),
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Padding(
                            padding: EdgeInsets.only(
                              left: 4,
                              top: tabs.isEmpty ? 0 : 6,
                            ),
                            child: Center(
                              child: IconButton(
                                key: const Key('note_tab_new_button'),
                                tooltip: '新建笔记 (Ctrl+N)',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 32,
                                  minHeight: 32,
                                ),
                                onPressed: widget.workspace.hasOpenVault
                                    ? () => unawaited(_createNewTab())
                                    : null,
                                icon: Icon(
                                  Icons.add_rounded,
                                  size: 18,
                                  color: tokens.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          const Expanded(
                            child: SizedBox.expand(
                              key: Key('note_tab_bar_drag_space'),
                            ),
                          ),
                          if (trailingInset > 0) SizedBox(width: trailingInset),
                        ],
                      );
                    },
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

class _NoteTabItem extends StatefulWidget {
  const _NoteTabItem({
    required this.entry,
    required this.isActive,
    required this.showTrailingDivider,
    required this.onSelect,
    required this.onClose,
    required this.onSecondaryTapDown,
    super.key,
  });

  final RawEntry entry;
  final bool isActive;
  final bool showTrailingDivider;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  State<_NoteTabItem> createState() => _NoteTabItemState();
}

class _NoteTabItemState extends State<_NoteTabItem> {
  bool _hovered = false;
  bool _closeHovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final title = WysiwygDocument.extractTitle(widget.entry.bodyMd);
    final showClose = widget.isActive || _hovered;

    final backgroundColor = widget.isActive
        ? tokens.canvas
        : _hovered
        ? tokens.canvas.withValues(alpha: 0.55)
        : Colors.transparent;

    final border = widget.isActive
        ? Border(
            top: BorderSide(color: tokens.borderHairline, width: 1),
            left: BorderSide(color: tokens.borderHairline, width: 1),
            right: BorderSide(color: tokens.borderHairline, width: 1),
          )
        : null;

    final textColor = widget.isActive
        ? tokens.textPrimary
        : _hovered
        ? tokens.textPrimary
        : tokens.textSecondary;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _closeHovered = false;
          }),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              if ((event.buttons & kMiddleMouseButton) != 0) {
                widget.onClose();
              }
            },
            child: GestureDetector(
              key: Key('note_tab_${widget.entry.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onSelect,
              onSecondaryTapDown: widget.onSecondaryTapDown,
              child: Container(
                constraints: const BoxConstraints(minWidth: 108, maxWidth: 200),
                height: widget.isActive ? 36 : 35,
                margin: EdgeInsets.only(
                  top: 8,
                  bottom: widget.isActive ? 0 : 1,
                ),
                padding: const EdgeInsets.only(left: 10, right: 6),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(8),
                  ),
                  border: border,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (widget.entry.isPrivate) ...<Widget>[
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 12,
                              color: tokens.privacyPrivate,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Flexible(
                            child: Tooltip(
                              message: title,
                              waitDuration: const Duration(milliseconds: 500),
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    BlinkTypography.metaLabel(
                                      tokens,
                                      color: textColor,
                                    ).copyWith(
                                      fontSize: 12.5,
                                      fontWeight: widget.isActive
                                          ? FontWeight.w500
                                          : FontWeight.w400,
                                    ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    IgnorePointer(
                      ignoring: !showClose,
                      child: Opacity(
                        opacity: showClose ? 1.0 : 0.0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          onEnter: (_) => setState(() => _closeHovered = true),
                          onExit: (_) => setState(() => _closeHovered = false),
                          child: GestureDetector(
                            key: Key('note_tab_close_${widget.entry.id}'),
                            behavior: HitTestBehavior.opaque,
                            onTap: widget.onClose,
                            child: Tooltip(
                              message: '关闭标签页 (Ctrl+W)',
                              waitDuration: const Duration(milliseconds: 500),
                              child: Container(
                                width: 20,
                                height: 20,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _closeHovered
                                      ? tokens.borderHairline.withValues(
                                          alpha: 0.75,
                                        )
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 13,
                                  color: _closeHovered
                                      ? tokens.textPrimary
                                      : tokens.textMuted,
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
            ),
          ),
        ),
        if (widget.showTrailingDivider)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: 1,
              height: 16,
              child: ColoredBox(color: tokens.borderHairline),
            ),
          ),
      ],
    );
  }
}
