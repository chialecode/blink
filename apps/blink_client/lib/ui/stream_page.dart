import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/ui/bfm_preview_view.dart';

/// Main Stream / BFM v1 Text Editor & 30-day Trash view (`docs/ui.md` §4.1).
class BlinkStreamPage extends StatefulWidget {
  const BlinkStreamPage({
    required this.workspace,
    required this.editor,
    required this.editorFocusNode,
    this.onOpenFilterDrawer,
    this.onOpenSearch,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final BlinkEditorController editor;
  final FocusNode editorFocusNode;
  final VoidCallback? onOpenFilterDrawer;
  final VoidCallback? onOpenSearch;

  @override
  State<BlinkStreamPage> createState() => _BlinkStreamPageState();
}

class _BlinkStreamPageState extends State<BlinkStreamPage> {
  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _editorLayerLink = LayerLink();
  static const BfmEngine _bfm = BfmEngine();
  bool _isMobileViewport = false;
  bool _mobilePreviewMode = false;

  @override
  void initState() {
    super.initState();
    widget.editor.addListener(_syncOverlayVisibility);
    widget.editorFocusNode.onKeyEvent = _handleEditorKeyEvent;
  }

  @override
  void didUpdateWidget(covariant BlinkStreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) {
      oldWidget.editor.removeListener(_syncOverlayVisibility);
      widget.editor.addListener(_syncOverlayVisibility);
    }
    if (oldWidget.editorFocusNode != widget.editorFocusNode) {
      oldWidget.editorFocusNode.onKeyEvent = null;
      widget.editorFocusNode.onKeyEvent = _handleEditorKeyEvent;
    }
  }

  @override
  void dispose() {
    widget.editor.removeListener(_syncOverlayVisibility);
    widget.editorFocusNode.onKeyEvent = null;
    super.dispose();
  }

  void _syncOverlayVisibility() {
    if (!mounted) {
      return;
    }
    // On mobile viewports (< 600px), autocomplete is rendered inside the
    // keyboard-attached horizontal bar instead of a floating OverlayPortal
    // (`docs/ui.md` §2.2 Rule 4).
    final shouldShow = !_isMobileViewport && widget.editor.showAutocomplete;
    if (shouldShow && !_overlayController.isShowing) {
      _overlayController.show();
    } else if (!shouldShow && _overlayController.isShowing) {
      _overlayController.hide();
    }
  }

  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    return BlinkSyntaxTextController.handleImeFirstKeyEvent(
      widget.editor.textController.value,
      event,
      hasOverlay: widget.editor.showAutocomplete,
      onSubmit: () {
        unawaited(_submitEditor());
      },
      onDismissOverlay: widget.editor.dismissAutocomplete,
      onSelectNextCandidate: widget.editor.selectNextCandidate,
      onSelectPreviousCandidate: widget.editor.selectPreviousCandidate,
      onAcceptCandidate: () {
        widget.editor.acceptSelectedCandidate();
      },
    );
  }

  Future<void> _submitEditor() async {
    final wasNewEntry = !widget.editor.isEditingExisting;
    try {
      final saved = await widget.editor.submit();
      if (saved != null) {
        if (wasNewEntry && _mobilePreviewMode && mounted) {
          setState(() => _mobilePreviewMode = false);
        }
        await widget.workspace.refreshAll();
      }
    } on BlinkException catch (error) {
      widget.workspace.showBanner(
        '保存条目失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
    } catch (error) {
      widget.workspace.showBanner('保存条目失败：$error', isError: true);
    }
  }

  void _insertBfmSnippet(String snippet) {
    if (_mobilePreviewMode) {
      setState(() => _mobilePreviewMode = false);
    }
    widget.editor.textController.insertSnippetIfNotComposing(snippet);
    widget.editorFocusNode.requestFocus();
  }

  Future<void> _attachFileToEditor() async {
    final blob = await widget.workspace.importFileFromPicker();
    if (blob != null) {
      widget.editor.attachBlobSha256(blob.sha256);
    }
  }

  Future<void> _handlePreviewLinkTap(BfmParsedLink link) async {
    if (link.targetKind == BfmLinkTargetKind.entry &&
        link.targetId != null &&
        link.targetId!.isNotEmpty) {
      await widget.workspace.openEntryById(link.targetId!);
      final entry = await widget.workspace.vault?.raw.getEntryById(
        link.targetId!,
        includeDeleted: true,
      );
      if (entry != null && !entry.isDeleted) {
        await widget.editor.startEditingEntry(entry);
      }
    }
  }

  Future<void> _handleEntryCheckboxToggle(
    RawEntry entry,
    int lineIndex,
    TaskStatus nextStatus,
  ) async {
    final nextBody = _bfm.toggleTaskLine(
      entry.bodyMd,
      lineIndex: lineIndex,
      newStatus: nextStatus,
    );
    await widget.workspace.updateEntry(id: entry.id, bodyMd: nextBody);
    if (widget.editor.editingEntryId == entry.id) {
      final refreshed = await widget.workspace.vault?.raw.getEntryById(
        entry.id,
      );
      if (refreshed != null) {
        await widget.editor.startEditingEntry(refreshed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.workspace,
        widget.editor,
      ]),
      builder: (context, _) {
        final isTrash = widget.workspace.streamFilter == StreamFilterKind.trash;
        final entries = widget.workspace.entries;

        return LayoutBuilder(
          builder: (context, constraints) {
            final isMobileViewport = constraints.maxWidth < 600;
            if (_isMobileViewport != isMobileViewport) {
              _isMobileViewport = isMobileViewport;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _syncOverlayVisibility();
              });
            }

            final sideBySidePreview =
                widget.workspace.splitPreviewEnabled &&
                constraints.maxWidth >= 720;

            final showMobileActions =
                widget.onOpenFilterDrawer != null ||
                widget.onOpenSearch != null;

            if (isMobileViewport) {
              final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (showMobileActions) _buildMobileInlineActionRow(tokens),
                  if (isTrash) _buildTrashHeader(tokens, entries.length),
                  Expanded(
                    child: entries.isEmpty
                        ? _buildEmptyState(
                            tokens,
                            isTrash: isTrash,
                            isMobileViewport: true,
                          )
                        : _buildEntriesList(
                            entries,
                            isTrash: isTrash,
                            horizontalPadding: 12,
                          ),
                  ),
                  if (!isTrash)
                    SafeArea(
                      top: false,
                      left: false,
                      right: false,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: keyboardInset),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (widget.editor.showAutocomplete &&
                                !_mobilePreviewMode)
                              _MobileAutocompleteBar(
                                candidates: widget.editor.candidates,
                                selectedIndex:
                                    widget.editor.selectedCandidateIndex,
                                onSelect: widget.editor.acceptCandidate,
                                onDismiss: widget.editor.dismissAutocomplete,
                              ),
                            _buildMobileBottomComposer(context, tokens),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (showMobileActions) _buildMobileInlineActionRow(tokens),
                if (!isTrash)
                  _buildComposerSection(
                    context,
                    tokens,
                    sideBySidePreview: sideBySidePreview,
                    compactTopPadding: showMobileActions,
                  )
                else
                  _buildTrashHeader(tokens, entries.length),
                Expanded(
                  child: entries.isEmpty
                      ? _buildEmptyState(
                          tokens,
                          isTrash: isTrash,
                          isMobileViewport: false,
                        )
                      : _buildEntriesList(
                          entries,
                          isTrash: isTrash,
                          horizontalPadding: 20,
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildEntriesList(
    List<RawEntry> entries, {
    required bool isTrash,
    required double horizontalPadding,
  }) {
    return ListView.separated(
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
        final selected =
            widget.workspace.selectedEntryId == entry.id ||
            widget.editor.editingEntryId == entry.id;
        return _EntryCard(
          entry: entry,
          selected: selected,
          isTrash: isTrash,
          onSelect: () async {
            widget.workspace.selectEntry(entry.id);
            if (!isTrash) {
              if (_mobilePreviewMode && mounted) {
                setState(() => _mobilePreviewMode = false);
              }
              await widget.editor.startEditingEntry(entry);
            }
          },
          onSoftDelete: () async {
            await widget.editor.resetIfEditingEntry(entry.id);
            await widget.workspace.softDeleteEntry(entry.id);
          },
          onRestore: () => widget.workspace.restoreEntry(entry.id),
          onPurge: () async {
            await widget.editor.resetIfEditingEntry(entry.id);
            await widget.workspace.purgeEntryPermanently(entry.id);
          },
          onTapLink: _handlePreviewLinkTap,
          onToggleTaskLine: (lineIndex, nextStatus) =>
              _handleEntryCheckboxToggle(entry, lineIndex, nextStatus),
        );
      },
    );
  }

  Widget _buildMobileBottomComposer(
    BuildContext context,
    BlinkColorTokens tokens,
  ) {
    final editor = widget.editor;
    final hasPrivate =
        editor.privacyLocked || editor.parsedPreviewDoc.hasPrivateToken;

    Widget modeTab({
      required Key tabKey,
      required String label,
      required bool active,
      required VoidCallback onTap,
    }) {
      return InkWell(
        key: tabKey,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56, minHeight: 44),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? tokens.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: active ? tokens.accentPrimary : tokens.borderHairline,
                width: 1,
              ),
            ),
            child: Text(
              label,
              style: BlinkTypography.metaLabel(
                tokens,
                color: active ? tokens.accentPrimary : tokens.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    Widget toolButton({
      required Key buttonKey,
      required String tooltip,
      required IconData icon,
      required VoidCallback? onPressed,
      Color? color,
    }) {
      return IconButton(
        key: buttonKey,
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: onPressed,
        icon: Icon(icon, size: 20, color: color ?? tokens.textSecondary),
      );
    }

    return Container(
      key: const Key('mobile_bottom_composer'),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          top: BorderSide(
            color: hasPrivate ? tokens.privacyPrivate : tokens.borderHairline,
            width: 1,
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (editor.isEditingExisting || hasPrivate)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              color: hasPrivate ? tokens.privacySubtle : tokens.sidebar,
              child: Row(
                children: <Widget>[
                  if (editor.isEditingExisting)
                    Text(
                      '编辑已有条目',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.accentPrimary,
                      ),
                    ),
                  if (hasPrivate) ...<Widget>[
                    if (editor.isEditingExisting) const SizedBox(width: 8),
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 14,
                      color: tokens.privacyPrivate,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '仅本地隔离（#private）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.privacyPrivate,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (editor.isEditingExisting)
                    TextButton(
                      key: const Key('editor_new_button'),
                      onPressed: () {
                        widget.workspace.selectEntry(null);
                        setState(() => _mobilePreviewMode = false);
                        unawaited(editor.startNewEntry());
                      },
                      child: const Text('切回新建'),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              key: const Key('mobile_composer_mode_toggle'),
              children: <Widget>[
                modeTab(
                  tabKey: const Key('mobile_tab_edit'),
                  label: '编辑',
                  active: !_mobilePreviewMode,
                  onTap: () {
                    if (_mobilePreviewMode) {
                      setState(() => _mobilePreviewMode = false);
                    }
                  },
                ),
                const SizedBox(width: 8),
                modeTab(
                  tabKey: const Key('mobile_tab_preview'),
                  label: '预览',
                  active: _mobilePreviewMode,
                  onTap: () {
                    if (!_mobilePreviewMode) {
                      editor.dismissAutocomplete();
                      setState(() => _mobilePreviewMode = true);
                    }
                  },
                ),
                const Spacer(),
                Text(
                  'BFM v1',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (_mobilePreviewMode)
            Container(
              key: const Key('mobile_bfm_preview'),
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(minHeight: 64, maxHeight: 180),
              decoration: BoxDecoration(
                color: tokens.sidebar,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: tokens.borderHairline, width: 1),
              ),
              child: editor.textController.text.trim().isEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '暂无内容可预览，切回「编辑」即可书写 BFM 笔记。',
                        style: BlinkTypography.body(
                          tokens,
                          color: tokens.textMuted,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: BfmPreviewView(
                        bodyMd: editor.textController.text,
                        compiledHtml: editor.compiledPreviewHtml,
                        onTapLink: _handlePreviewLinkTap,
                      ),
                    ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Container(
                decoration: BoxDecoration(
                  color: tokens.sidebar,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: hasPrivate
                        ? tokens.privacyPrivate
                        : tokens.borderHairline,
                    width: 1,
                  ),
                ),
                child: TextField(
                  key: const Key('bfm_editor_input'),
                  controller: editor.textController,
                  focusNode: widget.editorFocusNode,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  // Mobile 16px per `docs/ui.md` §2.2 to prevent focus zoom.
                  style: BlinkTypography.editorBody(tokens)
                      .copyWith(fontSize: 16),
                  decoration: InputDecoration(
                    hintText: editor.isEditingExisting
                        ? '正在编辑记录… 支持 [[、#、@、/'
                        : '此刻想到什么… 输入 [[ 引用、#标签、@时间、/模板',
                    hintStyle: BlinkTypography.body(
                      tokens,
                      color: tokens.textMuted,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
            ),
          if (editor.attachedBlobSha256s.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final sha in editor.attachedBlobSha256s)
                    InputChip(
                      label: Text('附件 ${sha.substring(0, 10)}…'),
                      backgroundColor: tokens.sidebar,
                      side: BorderSide(color: tokens.borderHairline),
                      labelStyle: BlinkTypography.metaLabel(tokens),
                      onDeleted: () => editor.detachBlobSha256(sha),
                    ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 12, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        toolButton(
                          buttonKey: const Key('editor_tag_button'),
                          tooltip: '插入 #标签',
                          icon: Icons.tag_rounded,
                          onPressed: () => _insertBfmSnippet('#'),
                        ),
                        toolButton(
                          buttonKey: const Key('editor_link_button'),
                          tooltip: '插入 [[引用]]',
                          icon: Icons.link_rounded,
                          onPressed: () => _insertBfmSnippet('[['),
                        ),
                        toolButton(
                          buttonKey: const Key('editor_mention_button'),
                          tooltip: '插入 @书目/时间',
                          icon: Icons.alternate_email_rounded,
                          onPressed: () => _insertBfmSnippet('@'),
                        ),
                        toolButton(
                          buttonKey: const Key('editor_slash_button'),
                          tooltip: '插入 /块模板',
                          icon: Icons.code_rounded,
                          onPressed: () => _insertBfmSnippet('/'),
                        ),
                        toolButton(
                          buttonKey: const Key('editor_private_toggle'),
                          tooltip: hasPrivate
                              ? '已启用 #private 隔离'
                              : '设为 #private 私密',
                          icon: hasPrivate
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          color: hasPrivate
                              ? tokens.privacyPrivate
                              : tokens.textSecondary,
                          onPressed: () =>
                              editor.setPrivacyLocked(!editor.privacyLocked),
                        ),
                        toolButton(
                          buttonKey: const Key('editor_attach_button'),
                          tooltip: '导入并关联本地附件',
                          icon: Icons.attach_file_rounded,
                          onPressed: widget.workspace.hasOpenVault
                              ? _attachFileToEditor
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('bfm_submit_button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  onPressed: widget.workspace.hasOpenVault && !editor.isSaving
                      ? _submitEditor
                      : null,
                  child: Text(editor.isEditingExisting ? '保存' : '记录'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileInlineActionRow(BlinkColorTokens tokens) {
    final filterLabel = switch (widget.workspace.streamFilter) {
      StreamFilterKind.all => '全部记录',
      StreamFilterKind.privateOnly => '#private 私密',
      StreamFilterKind.trash => '30 天回收站',
      StreamFilterKind.tag => '#${widget.workspace.selectedTag ?? ''}',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Row(
        children: <Widget>[
          if (widget.onOpenFilterDrawer != null)
            IconButton(
              key: const Key('open_sidebar_drawer_button'),
              tooltip: '筛选与标签',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onOpenFilterDrawer,
              icon: Icon(
                Icons.menu_rounded,
                size: 20,
                color: tokens.textPrimary,
              ),
            ),
          Expanded(
            child: Text(
              filterLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BlinkTypography.controlLabel(tokens),
            ),
          ),
          if (widget.onOpenSearch != null)
            IconButton(
              key: const Key('open_search_button'),
              tooltip: '全局搜索 (Ctrl+K)',
              visualDensity: VisualDensity.compact,
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

  Widget _buildComposerSection(
    BuildContext context,
    BlinkColorTokens tokens, {
    required bool sideBySidePreview,
    required bool compactTopPadding,
  }) {
    final editor = widget.editor;
    final showPreview = widget.workspace.splitPreviewEnabled;
    final hasPrivate =
        editor.privacyLocked || editor.parsedPreviewDoc.hasPrivateToken;

    final editorBox = CompositedTransformTarget(
      link: _editorLayerLink,
      child: OverlayPortal(
        controller: _overlayController,
        overlayChildBuilder: (overlayContext) {
          return CompositedTransformFollower(
            link: _editorLayerLink,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomLeft,
            followerAnchor: Alignment.topLeft,
            offset: const Offset(0, 6),
            child: Align(
              alignment: Alignment.topLeft,
              child: _AutocompletePopup(
                candidates: editor.candidates,
                selectedIndex: editor.selectedCandidateIndex,
                onSelect: editor.acceptCandidate,
                onDismiss: editor.dismissAutocomplete,
              ),
            ),
          );
        },
        child: TextField(
          key: const Key('bfm_editor_input'),
          controller: editor.textController,
          focusNode: widget.editorFocusNode,
          minLines: showPreview ? 5 : 2,
          maxLines: showPreview ? 10 : 8,
          keyboardType: TextInputType.multiline,
          style: BlinkTypography.editorBody(tokens),
          decoration: InputDecoration(
            hintText: editor.isEditingExisting
                ? '正在编辑记录… 输入 [[ 引用、# 标签、/ 块模板，Ctrl+Enter 保存'
                : '此刻想到什么… 输入 [[ 引用、#标签、#private、- [ ] 待办、/模板（Ctrl+Enter 记录）',
            hintStyle: BlinkTypography.body(tokens, color: tokens.textMuted),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
      ),
    );

    final previewBox = Container(
      key: const Key('bfm_split_preview'),
      constraints: const BoxConstraints(minHeight: 120, maxHeight: 260),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.sidebar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.borderHairline, width: 1),
      ),
      child: SingleChildScrollView(
        child: BfmPreviewView(
          bodyMd: editor.textController.text,
          compiledHtml: editor.compiledPreviewHtml,
          onTapLink: _handlePreviewLinkTap,
        ),
      ),
    );

    return Container(
      padding: EdgeInsets.fromLTRB(20, compactTopPadding ? 8 : 16, 20, 14),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: showPreview ? 1120 : 760),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.canvas,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hasPrivate
                    ? tokens.privacyPrivate
                    : tokens.borderHairline,
                width: 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (editor.isEditingExisting || hasPrivate)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: hasPrivate ? tokens.privacySubtle : tokens.sidebar,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(11),
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        if (editor.isEditingExisting)
                          Text(
                            '编辑已有条目',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: tokens.accentPrimary,
                            ),
                          ),
                        if (hasPrivate) ...<Widget>[
                          if (editor.isEditingExisting)
                            const SizedBox(width: 8),
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 14,
                            color: tokens.privacyPrivate,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '仅本地隔离（#private）',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: tokens.privacyPrivate,
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (editor.isEditingExisting)
                          TextButton(
                            key: const Key('editor_new_button'),
                            onPressed: () {
                              widget.workspace.selectEntry(null);
                              unawaited(editor.startNewEntry());
                            },
                            child: const Text('切回新建'),
                          ),
                      ],
                    ),
                  ),
                if (showPreview && sideBySidePreview)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(child: editorBox),
                          const SizedBox(width: 10),
                          Expanded(child: previewBox),
                        ],
                      ),
                    ),
                  )
                else if (showPreview)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        editorBox,
                        const SizedBox(height: 8),
                        previewBox,
                      ],
                    ),
                  )
                else
                  editorBox,
                if (editor.attachedBlobSha256s.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final sha in editor.attachedBlobSha256s)
                          InputChip(
                            label: Text('附件 ${sha.substring(0, 10)}…'),
                            backgroundColor: tokens.sidebar,
                            side: BorderSide(color: tokens.borderHairline),
                            labelStyle: BlinkTypography.metaLabel(tokens),
                            onDeleted: () => editor.detachBlobSha256(sha),
                          ),
                      ],
                    ),
                  ),
                Divider(height: 1, color: tokens.borderHairline),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: <Widget>[
                      Wrap(
                        spacing: 2,
                        runSpacing: 4,
                        children: <Widget>[
                          IconButton(
                            key: const Key('editor_tag_button'),
                            tooltip: '插入 #标签',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              editor.textController.insertSnippetIfNotComposing(
                                '#',
                              );
                              widget.editorFocusNode.requestFocus();
                            },
                            icon: Icon(
                              Icons.tag_rounded,
                              size: 18,
                              color: tokens.textSecondary,
                            ),
                          ),
                          IconButton(
                            key: const Key('editor_link_button'),
                            tooltip: '插入 [[引用]]',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              editor.textController.insertSnippetIfNotComposing(
                                '[[',
                              );
                              widget.editorFocusNode.requestFocus();
                            },
                            icon: Icon(
                              Icons.link_rounded,
                              size: 18,
                              color: tokens.textSecondary,
                            ),
                          ),
                          IconButton(
                            key: const Key('editor_private_toggle'),
                            tooltip: hasPrivate
                                ? '已启用 #private 隔离'
                                : '设为 #private 私密',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                editor.setPrivacyLocked(!editor.privacyLocked),
                            icon: Icon(
                              hasPrivate
                                  ? Icons.lock_rounded
                                  : Icons.lock_open_rounded,
                              size: 18,
                              color: hasPrivate
                                  ? tokens.privacyPrivate
                                  : tokens.textSecondary,
                            ),
                          ),
                          IconButton(
                            key: const Key('editor_attach_button'),
                            tooltip: '导入并关联本地附件',
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.workspace.hasOpenVault
                                ? _attachFileToEditor
                                : null,
                            icon: Icon(
                              Icons.attach_file_rounded,
                              size: 18,
                              color: tokens.textSecondary,
                            ),
                          ),
                          IconButton(
                            key: const Key('editor_preview_toggle'),
                            tooltip: '切换分栏实时预览 (Ctrl+Shift+P)',
                            visualDensity: VisualDensity.compact,
                            onPressed: widget.workspace.toggleSplitPreview,
                            icon: Icon(
                              Icons.vertical_split_outlined,
                              size: 18,
                              color: showPreview
                                  ? tokens.accentPrimary
                                  : tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      FilledButton(
                        key: const Key('bfm_submit_button'),
                        onPressed:
                            widget.workspace.hasOpenVault && !editor.isSaving
                            ? _submitEditor
                            : null,
                        child: Text(editor.isEditingExisting ? '保存修改' : '记录'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrashHeader(BlinkColorTokens tokens, int count) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '30 天回收站（$count）',
                style: BlinkTypography.heroHeading(tokens),
              ),
              const SizedBox(height: 2),
              Text(
                '删除的条目先进入回收站保留 30 天，支持随时还原或手动彻底清除并回收无引用附件。',
                style: BlinkTypography.metaLabel(tokens),
              ),
            ],
          ),
          OutlinedButton.icon(
            key: const Key('trash_purge_expired_button'),
            onPressed: widget.workspace.hasOpenVault
                ? () => widget.workspace.purgeExpiredTrash()
                : null,
            icon: const Icon(Icons.delete_sweep_outlined, size: 16),
            label: const Text('清理 30 天过期条目'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    BlinkColorTokens tokens, {
    required bool isTrash,
    required bool isMobileViewport,
  }) {
    final text = isTrash
        ? '回收站为空。删除条目后可在此保留 30 天并随时还原。'
        : switch (widget.workspace.streamFilter) {
            StreamFilterKind.privateOnly =>
              '暂无 #private 私密记录。在输入时加上 #private 或点击锁标即可创建仅本地隔离的私密条目。',
            StreamFilterKind.tag =>
              '标签 #${widget.workspace.selectedTag ?? ''} 下暂无记录。',
            _ =>
              isMobileViewport
                  ? '采集流为空。在下方直接书写第一条 BFM v1 闪念或待办，无需预先整理文件夹。'
                  : '采集流为空。在上方直接书写第一条 BFM v1 闪念或待办，无需预先整理文件夹。',
          };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: BlinkTypography.body(tokens, color: tokens.textMuted),
        ),
      ),
    );
  }
}

/// Keyboard-attached horizontal BFM autocomplete bar for mobile viewports
/// (`< 600px`, `docs/ui.md` §2.2 Rule 4) with `>= 44dp` touch targets.
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

class _AutocompletePopup extends StatelessWidget {
  const _AutocompletePopup({
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
      key: const Key('bfm_autocomplete_overlay'),
      color: tokens.canvas,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
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

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.selected,
    required this.isTrash,
    required this.onSelect,
    required this.onSoftDelete,
    required this.onRestore,
    required this.onPurge,
    required this.onTapLink,
    required this.onToggleTaskLine,
  });

  final RawEntry entry;
  final bool selected;
  final bool isTrash;
  final VoidCallback onSelect;
  final VoidCallback onSoftDelete;
  final VoidCallback onRestore;
  final VoidCallback onPurge;
  final BfmLinkTapCallback onTapLink;
  final BfmTaskLineToggleCallback onToggleTaskLine;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Card(
          key: Key('entry_card_${entry.id}'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: selected ? tokens.accentPrimary : tokens.borderHairline,
              width: 1,
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: isTrash ? null : onSelect,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            Text(
                              _formatTimestamp(entry.updatedAtUtc),
                              style:
                                  BlinkTypography.metaLabel(
                                    tokens,
                                    color: tokens.textSecondary,
                                  ).copyWith(
                                    fontFeatures:
                                        BlinkTypography.tabularFigures,
                                  ),
                            ),
                            Text(
                              'rev ${entry.revision}',
                              style:
                                  BlinkTypography.metaLabel(
                                    tokens,
                                    color: tokens.textMuted,
                                  ).copyWith(
                                    fontFeatures:
                                        BlinkTypography.tabularFigures,
                                  ),
                            ),
                            if (entry.isPrivate)
                              Container(
                                key: Key('entry_private_badge_${entry.id}'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
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
                          ],
                        ),
                      ),
                      if (isTrash) ...<Widget>[
                        TextButton(
                          key: Key('trash_restore_${entry.id}'),
                          onPressed: onRestore,
                          child: const Text('还原'),
                        ),
                        TextButton(
                          key: Key('trash_purge_${entry.id}'),
                          onPressed: onPurge,
                          child: Text(
                            '彻底删除',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: tokens.statusErr,
                            ),
                          ),
                        ),
                      ] else ...<Widget>[
                        IconButton(
                          key: Key('entry_edit_${entry.id}'),
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          onPressed: onSelect,
                          icon: Icon(
                            Icons.edit_outlined,
                            size: 16,
                            color: tokens.textSecondary,
                          ),
                        ),
                        IconButton(
                          key: Key('entry_delete_${entry.id}'),
                          tooltip: '移入 30 天回收站',
                          visualDensity: VisualDensity.compact,
                          onPressed: onSoftDelete,
                          icon: Icon(
                            Icons.delete_outline_rounded,
                            size: 16,
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  BfmPreviewView(
                    bodyMd: entry.bodyMd,
                    compact: true,
                    onTapLink: onTapLink,
                    onToggleTaskLine: isTrash ? null : onToggleTaskLine,
                  ),
                  if (entry.imageBlobSha256s.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final sha in entry.imageBlobSha256s)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: tokens.sidebar,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: tokens.borderHairline),
                            ),
                            child: Text(
                              '📎 ${sha.substring(0, 10)}…',
                              style:
                                  BlinkTypography.monoValue(
                                    tokens,
                                    tabular: true,
                                  ).copyWith(
                                    fontSize: 11,
                                    color: tokens.textSecondary,
                                  ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _formatTimestamp(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}
