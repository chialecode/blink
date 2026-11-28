import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/application/wysiwyg_document.dart';
import 'package:blink_client/ui/bfm_preview_view.dart';

/// Typora-style dual-mode Markdown editor (`所见即所得` / `源代码`) for BLINK
/// long-form notes (`EntryKind.diary`).
///
/// Enforces all 5 CJK IME composition safety rules (`SPK-02`) in BOTH modes:
/// 1. Zero `TextEditingValue` mutation while `isValueComposing(value)` is true.
/// 2. Strictly 1:1 UTF-16 length-preserving `BlinkSyntaxTextController`.
/// 3. IME-first `FocusNode.onKeyEvent` returning `KeyEventResult.ignored` for
///    `Enter`/`Space`/`Tab`/`Esc`/arrows while composing.
/// 4. Safe `[[`, `#`, `@`, `/` autocomplete that only fires on collapsed,
///    non-composing selections and replaces atomically with `TextRange.empty`.
/// 5. Pure native Flutter block widgets + native active-block `TextField`.
class BlinkMarkdownEditor extends StatefulWidget {
  const BlinkMarkdownEditor({
    required this.workspace,
    required this.entry,
    this.isMobile = false,
    this.onOpenEntry,
    this.onBack,
    this.onTagTap,
    this.externalFocusNode,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final RawEntry? entry;
  final bool isMobile;
  final ValueChanged<String>? onOpenEntry;
  final VoidCallback? onBack;
  final ValueChanged<String>? onTagTap;
  final FocusNode? externalFocusNode;

  @override
  State<BlinkMarkdownEditor> createState() => _BlinkMarkdownEditorState();
}

class _BlinkMarkdownEditorState extends State<BlinkMarkdownEditor> {
  static const BfmEngine _bfm = BfmEngine();
  static const Duration _autoSaveDelay = Duration(milliseconds: 600);
  static const Duration _draftSaveDelay = Duration(milliseconds: 400);
  static const List<String> _codeLanguages = <String>[
    '',
    'dart',
    'python',
    'javascript',
    'typescript',
    'json',
    'bash',
    'sql',
    'markdown',
  ];
  static const List<String> _calloutKinds = <String>[
    'note',
    'insight',
    'tip',
    'warning',
    'danger',
  ];

  final OverlayPortalController _overlayController = OverlayPortalController();
  final LayerLink _autocompleteLink = LayerLink();
  final ScrollController _scrollController = ScrollController();

  late final BlinkSyntaxTextController _sourceController =
      BlinkSyntaxTextController(
        dimInlineMarkers: true,
        enableBlockPrefixes: true,
      );
  FocusNode? _ownedSourceFocusNode;

  final Map<String, BlinkSyntaxTextController> _blockControllers =
      <String, BlinkSyntaxTextController>{};
  final Map<String, FocusNode> _blockFocusNodes = <String, FocusNode>{};

  String? _loadedEntryId;
  String _lastPersistedBodyMd = '';
  bool _privacyLocked = false;
  bool _pendingPrivacyDowngrade = false;
  List<String> _attachedBlobSha256s = const <String>[];

  late NoteEditorMode _syncedMode = widget.workspace.noteEditorMode;
  List<WysiwygBlock> _blocks = <WysiwygBlock>[];
  int _activeBlockIndex = -1;

  bool _isDirty = false;
  bool _isSaving = false;
  bool _suppressListeners = false;
  Timer? _autoSaveTimer;
  Timer? _draftTimer;

  AutocompleteTrigger? _activeTrigger;
  List<AutocompleteCandidate> _candidates = const <AutocompleteCandidate>[];
  int _selectedCandidateIndex = 0;
  int _candidateQueryEpoch = 0;

  FocusNode get _effectiveSourceFocusNode =>
      widget.externalFocusNode ?? (_ownedSourceFocusNode ??= FocusNode());

  bool get _isWysiwyg =>
      widget.workspace.noteEditorMode == NoteEditorMode.wysiwyg;

  bool get _isTrashed => widget.entry?.isDeleted ?? false;

  bool get _isCurrentlyPrivate =>
      _privacyLocked ||
      _bfm.parse(_currentSerializedMarkdown()).hasPrivateToken;

  bool get _showAutocomplete =>
      _activeTrigger != null && _candidates.isNotEmpty && !_isTrashed;

  BlinkSyntaxTextController? get _activeTextController {
    if (!_isWysiwyg) {
      return _sourceController;
    }
    if (_activeBlockIndex >= 0 && _activeBlockIndex < _blocks.length) {
      return _blockControllers[_blocks[_activeBlockIndex].id];
    }
    return null;
  }

  FocusNode? get _activeFocusNode {
    if (!_isWysiwyg) {
      return _effectiveSourceFocusNode;
    }
    if (_activeBlockIndex >= 0 && _activeBlockIndex < _blocks.length) {
      return _blockFocusNodes[_blocks[_activeBlockIndex].id];
    }
    return null;
  }

  bool get _isAnyControllerComposing {
    if (_sourceController.isComposing) {
      return true;
    }
    for (final ctrl in _blockControllers.values) {
      if (ctrl.isComposing) {
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _sourceController.addListener(_onSourceTextChanged);
    _effectiveSourceFocusNode.onKeyEvent = _handleSourceKeyEvent;
    widget.workspace.addListener(_onWorkspaceChanged);
    widget.workspace.addDraftFlushHook(_flushForShutdown);
    _loadEntry(widget.entry);
  }

  @override
  void didUpdateWidget(covariant BlinkMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace) {
      oldWidget.workspace.removeListener(_onWorkspaceChanged);
      oldWidget.workspace.removeDraftFlushHook(_flushForShutdown);
      widget.workspace.addListener(_onWorkspaceChanged);
      widget.workspace.addDraftFlushHook(_flushForShutdown);
    }
    if (oldWidget.externalFocusNode != widget.externalFocusNode) {
      oldWidget.externalFocusNode?.onKeyEvent = null;
      _effectiveSourceFocusNode.onKeyEvent = _handleSourceKeyEvent;
    }

    final nextEntry = widget.entry;
    if (nextEntry?.id != _loadedEntryId) {
      final prevId = _loadedEntryId;
      final prevBody = _currentSerializedMarkdown();
      final prevPrivate = _privacyLocked;
      final prevAllowDowngrade = _pendingPrivacyDowngrade;
      final prevBlobs = List<String>.of(_attachedBlobSha256s);
      final prevDirty = _isDirty;
      _isDirty = false;
      _pendingPrivacyDowngrade = false;
      _cancelTimers();
      if (prevId != null && prevDirty) {
        unawaited(
          _persistNoteSnapshot(
            entryId: prevId,
            bodyMd: prevBody,
            isPrivate: prevPrivate,
            imageBlobSha256s: prevBlobs,
            workspace: oldWidget.workspace,
            allowPrivacyDowngrade: prevAllowDowngrade,
          ),
        );
      }
      _loadEntry(nextEntry);
    } else if (nextEntry != null && !_isDirty && !_isSaving) {
      final current = _currentSerializedMarkdown();
      if (nextEntry.bodyMd != current ||
          nextEntry.isPrivate != _privacyLocked ||
          !_listEquals(nextEntry.imageBlobSha256s, _attachedBlobSha256s)) {
        _loadEntry(nextEntry, preserveActiveIndex: true);
      }
    }
  }

  @override
  void dispose() {
    final pendingId = _loadedEntryId;
    final pendingBody = _currentSerializedMarkdown();
    final pendingPrivate = _privacyLocked;
    final pendingAllowDowngrade = _pendingPrivacyDowngrade;
    final pendingBlobs = List<String>.of(_attachedBlobSha256s);
    final pendingDirty = _isDirty;
    final pendingTrashed = _isTrashed;

    _isDirty = false;
    _pendingPrivacyDowngrade = false;
    _cancelTimers();
    widget.workspace.removeListener(_onWorkspaceChanged);
    widget.workspace.removeDraftFlushHook(_flushForShutdown);
    if (pendingId != null && pendingDirty && !pendingTrashed) {
      unawaited(
        _persistNoteSnapshot(
          entryId: pendingId,
          bodyMd: pendingBody,
          isPrivate: pendingPrivate,
          imageBlobSha256s: pendingBlobs,
          workspace: widget.workspace,
          allowPrivacyDowngrade: pendingAllowDowngrade,
        ),
      );
    }

    _sourceController.removeListener(_onSourceTextChanged);
    _sourceController.dispose();
    _effectiveSourceFocusNode.onKeyEvent = null;
    _ownedSourceFocusNode?.dispose();
    _disposeAllBlockControllers();
    _scrollController.dispose();
    super.dispose();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _cancelTimers() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;
    _draftTimer?.cancel();
    _draftTimer = null;
  }

  void _disposeAllBlockControllers() {
    for (final ctrl in _blockControllers.values) {
      ctrl.dispose();
    }
    _blockControllers.clear();
    for (final node in _blockFocusNodes.values) {
      node.onKeyEvent = null;
      node.dispose();
    }
    _blockFocusNodes.clear();
  }

  void _loadEntry(RawEntry? entry, {bool preserveActiveIndex = false}) {
    _cancelTimers();
    _dismissAutocomplete(notify: false);
    _loadedEntryId = entry?.id;
    _lastPersistedBodyMd = entry?.bodyMd ?? '';
    _privacyLocked = entry?.isPrivate ?? false;
    _pendingPrivacyDowngrade = false;
    _attachedBlobSha256s = List<String>.unmodifiable(
      entry?.imageBlobSha256s ?? const <String>[],
    );
    _isDirty = false;
    _isSaving = false;

    final body = entry?.bodyMd ?? '';
    _suppressListeners = true;
    try {
      _sourceController.value = TextEditingValue(
        text: body,
        selection: TextSelection.collapsed(offset: body.length),
        composing: TextRange.empty,
      );
      _disposeAllBlockControllers();
      _blocks = WysiwygDocument.parse(body);
      if (preserveActiveIndex &&
          _activeBlockIndex >= 0 &&
          _activeBlockIndex < _blocks.length) {
        // Keep current focused block index within bounds.
      } else if (entry != null && !entry.isDeleted && body.isEmpty) {
        // Start newly created empty notes ready to type immediately.
        _activeBlockIndex = 0;
      } else {
        _activeBlockIndex = -1;
      }
    } finally {
      _suppressListeners = false;
    }

    // Restore crash-recovery draft if newer than persisted entry body.
    if (entry != null && !entry.isDeleted) {
      unawaited(_maybeRestoreDraft(entry));
    }
  }

  Future<void> _maybeRestoreDraft(RawEntry entry) async {
    final vault = widget.workspace.vault;
    if (vault == null || !vault.isOpen) {
      return;
    }
    final draft = await vault.raw.loadDraft('entry:${entry.id}');
    if (!mounted || _loadedEntryId != entry.id || draft == null) {
      return;
    }
    if (draft.updatedAtUtc.isAfter(entry.updatedAtUtc) &&
        draft.bodyMd != entry.bodyMd &&
        !_isDirty) {
      _suppressListeners = true;
      try {
        _sourceController.value = TextEditingValue(
          text: draft.bodyMd,
          selection: TextSelection.collapsed(offset: draft.bodyMd.length),
          composing: TextRange.empty,
        );
        _disposeAllBlockControllers();
        _blocks = WysiwygDocument.parse(draft.bodyMd);
        _privacyLocked = draft.privacyLocked || entry.isPrivate;
        _attachedBlobSha256s = List<String>.unmodifiable(
          draft.imageBlobSha256s.isNotEmpty
              ? draft.imageBlobSha256s
              : entry.imageBlobSha256s,
        );
        _isDirty = true;
      } finally {
        _suppressListeners = false;
      }
      setState(() {});
    }
  }

  void _onWorkspaceChanged() {
    if (!mounted) {
      return;
    }
    final nextMode = widget.workspace.noteEditorMode;
    if (nextMode != _syncedMode) {
      _syncModeTransition(from: _syncedMode, to: nextMode);
    }
  }

  void _syncModeTransition({
    required NoteEditorMode from,
    required NoteEditorMode to,
  }) {
    _syncedMode = to;
    _dismissAutocomplete(notify: false);
    _suppressListeners = true;
    try {
      if (to == NoteEditorMode.source) {
        final serialized = WysiwygDocument.serialize(_blocks);
        _sourceController.value = TextEditingValue(
          text: serialized,
          selection: TextSelection.collapsed(offset: serialized.length),
          composing: TextRange.empty,
        );
      } else {
        final parsed = WysiwygDocument.parse(_sourceController.text);
        _disposeAllBlockControllers();
        _blocks = parsed;
        _activeBlockIndex = -1;
      }
    } finally {
      _suppressListeners = false;
    }
    if (mounted) {
      setState(() {});
      if (to == NoteEditorMode.source && !_isTrashed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isWysiwyg) {
            _effectiveSourceFocusNode.requestFocus();
          }
        });
      }
    }
  }

  String _currentSerializedMarkdown() {
    if (_syncedMode == NoteEditorMode.source) {
      return _sourceController.text;
    }
    return WysiwygDocument.serialize(_blocks);
  }

  BlinkSyntaxTextController _controllerForBlock(WysiwygBlock block) {
    return _blockControllers.putIfAbsent(block.id, () {
      final isRawSyntaxBlock =
          block.type == WysiwygBlockType.table ||
          block.type == WysiwygBlockType.fold;
      final isCode = block.type == WysiwygBlockType.codeBlock;
      final ctrl = BlinkSyntaxTextController(
        text: block.text,
        dimInlineMarkers: true,
        enableBlockPrefixes: isRawSyntaxBlock,
        enableInlineSyntax: !isCode,
      );
      ctrl.addListener(() => _onBlockTextChanged(block.id));
      return ctrl;
    });
  }

  FocusNode _focusNodeForBlock(WysiwygBlock block) {
    return _blockFocusNodes.putIfAbsent(block.id, () {
      final node = FocusNode();
      node.onKeyEvent = (focusNode, event) =>
          _handleBlockKeyEvent(block.id, focusNode, event);
      node.addListener(() {
        if (!mounted) {
          return;
        }
        if (node.hasFocus) {
          final idx = _blocks.indexWhere((item) => item.id == block.id);
          if (idx >= 0 && _activeBlockIndex != idx) {
            setState(() => _activeBlockIndex = idx);
          }
        }
      });
      return node;
    });
  }

  void _removeBlockResources(String blockId) {
    final ctrl = _blockControllers.remove(blockId);
    final node = _blockFocusNodes.remove(blockId);
    if (node != null) {
      node.onKeyEvent = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => node.dispose());
    }
    if (ctrl != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    }
  }

  void _focusBlock(int index, {int? caretOffset}) {
    if (_isTrashed || index < 0 || index >= _blocks.length) {
      return;
    }
    final block = _blocks[index];
    if (block.type == WysiwygBlockType.aiEmbed) {
      return;
    }

    if (block.type == WysiwygBlockType.divider) {
      final node = _focusNodeForBlock(block);
      setState(() => _activeBlockIndex = index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          node.requestFocus();
        }
      });
      return;
    }

    final ctrl = _controllerForBlock(block);
    final node = _focusNodeForBlock(block);

    _suppressListeners = true;
    try {
      if (ctrl.text != block.text) {
        ctrl.text = block.text;
      }
      final targetOffset = (caretOffset ?? ctrl.text.length).clamp(
        0,
        ctrl.text.length,
      );
      ctrl.value = TextEditingValue(
        text: ctrl.text,
        selection: TextSelection.collapsed(offset: targetOffset),
        composing: TextRange.empty,
      );
    } finally {
      _suppressListeners = false;
    }

    setState(() => _activeBlockIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        node.requestFocus();
      }
    });
  }

  void _focusEndOrAppendParagraph() {
    if (_isTrashed) {
      return;
    }
    if (_blocks.isEmpty) {
      _blocks = <WysiwygBlock>[
        WysiwygBlock(
          id: WysiwygDocument.nextBlockId(),
          type: WysiwygBlockType.paragraph,
        ),
      ];
      _focusBlock(0, caretOffset: 0);
      return;
    }
    final last = _blocks.last;
    if (last.type == WysiwygBlockType.paragraph || last.isTextMergeable) {
      _focusBlock(_blocks.length - 1, caretOffset: last.text.length);
      return;
    }
    final nextBlock = WysiwygBlock(
      id: WysiwygDocument.nextBlockId(),
      type: WysiwygBlockType.paragraph,
    );
    setState(() {
      _blocks = <WysiwygBlock>[..._blocks, nextBlock];
    });
    _focusBlock(_blocks.length - 1, caretOffset: 0);
  }

  void _markDirtyAndScheduleSave() {
    if (!_isDirty) {
      _isDirty = true;
      if (mounted) {
        setState(() {});
      }
    }
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftSaveDelay, () {
      unawaited(_saveDraftNow());
    });
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(_autoSaveDelay, () {
      unawaited(_saveNoteNow());
    });
  }

  Future<void> _saveDraftNow() async {
    final entryId = _loadedEntryId;
    final vault = widget.workspace.vault;
    if (entryId == null || vault == null || !vault.isOpen || _isTrashed) {
      return;
    }
    await vault.raw.saveDraft(
      EditorDraft(
        draftKey: 'entry:$entryId',
        bodyMd: _currentSerializedMarkdown(),
        entryKind: EntryKind.diary,
        privacyLocked: _privacyLocked,
        imageBlobSha256s: _attachedBlobSha256s,
        updatedAtUtc: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _flushForShutdown() async {
    if (!mounted || !_isDirty) {
      return;
    }
    _cancelTimers();
    final entryId = _loadedEntryId;
    if (entryId == null || _isTrashed) {
      return;
    }
    final body = _currentSerializedMarkdown();
    final allowDowngrade = _pendingPrivacyDowngrade;
    _isDirty = false;
    _pendingPrivacyDowngrade = false;
    final updated = await _persistNoteSnapshot(
      entryId: entryId,
      bodyMd: body,
      isPrivate: _privacyLocked,
      imageBlobSha256s: List<String>.of(_attachedBlobSha256s),
      workspace: widget.workspace,
      allowPrivacyDowngrade: allowDowngrade,
    );
    if (updated != null && mounted && _loadedEntryId == entryId) {
      _lastPersistedBodyMd = updated.bodyMd;
      _privacyLocked = updated.isPrivate;
      _attachedBlobSha256s = List<String>.unmodifiable(
        updated.imageBlobSha256s,
      );
    }
  }

  Future<RawEntry?> _saveNoteNow({
    bool showFeedback = false,
    bool allowPrivacyDowngrade = false,
  }) async {
    if (_isAnyControllerComposing || _isTrashed) {
      return null;
    }
    final entryId = _loadedEntryId;
    if (entryId == null) {
      return null;
    }
    _cancelTimers();
    final body = _currentSerializedMarkdown();
    final effectiveAllowDowngrade =
        allowPrivacyDowngrade || _pendingPrivacyDowngrade;
    final needsUpdate =
        _isDirty ||
        effectiveAllowDowngrade ||
        body != _lastPersistedBodyMd ||
        (widget.entry != null && widget.entry!.isPrivate != _privacyLocked) ||
        (widget.entry != null &&
            !_listEquals(widget.entry!.imageBlobSha256s, _attachedBlobSha256s));
    if (!needsUpdate) {
      if (showFeedback) {
        widget.workspace.showBanner('笔记已是最新状态。');
      }
      return widget.entry;
    }

    if (mounted) {
      setState(() => _isSaving = true);
    }
    try {
      final updated = await _persistNoteSnapshot(
        entryId: entryId,
        bodyMd: body,
        isPrivate: _privacyLocked,
        imageBlobSha256s: List<String>.of(_attachedBlobSha256s),
        workspace: widget.workspace,
        allowPrivacyDowngrade: effectiveAllowDowngrade,
      );
      if (updated != null && mounted && _loadedEntryId == entryId) {
        _lastPersistedBodyMd = updated.bodyMd;
        _privacyLocked = updated.isPrivate;
        _pendingPrivacyDowngrade = false;
        _attachedBlobSha256s = List<String>.unmodifiable(
          updated.imageBlobSha256s,
        );
        if (_currentSerializedMarkdown() == body) {
          _isDirty = false;
        }
        if (showFeedback) {
          widget.workspace.showBanner('笔记已保存。');
        }
      }
      return updated;
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  static Future<RawEntry?> _persistNoteSnapshot({
    required String entryId,
    required String bodyMd,
    required bool isPrivate,
    required List<String> imageBlobSha256s,
    required BlinkWorkspaceController workspace,
    bool allowPrivacyDowngrade = false,
  }) async {
    final vault = workspace.vault;
    if (vault == null || !vault.isOpen) {
      return null;
    }
    final updated = await workspace.updateNote(
      entryId,
      bodyMd: bodyMd,
      isPrivate: isPrivate,
      imageBlobSha256s: imageBlobSha256s,
      allowPrivacyDowngrade: allowPrivacyDowngrade,
    );
    if (updated != null) {
      try {
        await vault.raw.clearDraft('entry:$entryId');
      } catch (_) {}
    }
    return updated;
  }

  void _onSourceTextChanged() {
    if (_suppressListeners || !mounted || _isTrashed) {
      return;
    }
    // SPK-02 Rule 1: never mutate value or update autocomplete while composing.
    if (BlinkSyntaxTextController.isValueComposing(_sourceController.value)) {
      _dismissAutocomplete();
      return;
    }
    _markDirtyAndScheduleSave();
    _updateAutocompleteFor(_sourceController);
  }

  void _onBlockTextChanged(String blockId) {
    if (_suppressListeners || !mounted || _isTrashed) {
      return;
    }
    final ctrl = _blockControllers[blockId];
    if (ctrl == null) {
      return;
    }
    // SPK-02 Rule 1: strictly guard against mutating text during CJK IME composition!
    if (BlinkSyntaxTextController.isValueComposing(ctrl.value)) {
      _dismissAutocomplete();
      return;
    }

    final idx = _blocks.indexWhere((b) => b.id == blockId);
    if (idx < 0) {
      return;
    }
    final current = _blocks[idx];
    final text = ctrl.text;

    // Live Typora prefix shortcuts on collapsed cursor (never while composing).
    if (ctrl.selection.isValid && ctrl.selection.isCollapsed) {
      if (current.type == WysiwygBlockType.paragraph) {
        final matched = WysiwygDocument.matchPrefixShortcut(text);
        if (matched != null &&
            matched.type != WysiwygBlockType.divider &&
            matched.type != WysiwygBlockType.codeBlock) {
          final transformed = current.copyWith(
            type: matched.type,
            level: matched.level,
            orderNumber: matched.orderNumber,
            taskStatus: matched.taskStatus,
            clearTaskStatus: matched.taskStatus == null,
            text: matched.remainingText,
          );
          _applyAtomicBlockTransform(
            idx,
            transformed,
            ctrl,
            matched.remainingText,
          );
          return;
        }
      } else if (current.type == WysiwygBlockType.bulletList) {
        final checkbox = WysiwygDocument.matchTaskCheckboxPrefix(text);
        if (checkbox != null) {
          final transformed = current.copyWith(
            type: WysiwygBlockType.taskItem,
            taskStatus: checkbox.status,
            text: checkbox.remainingText,
          );
          _applyAtomicBlockTransform(
            idx,
            transformed,
            ctrl,
            checkbox.remainingText,
          );
          return;
        }
      } else if (current.type == WysiwygBlockType.blockquote) {
        final callout = WysiwygDocument.matchCalloutPrefix(text);
        if (callout != null) {
          final transformed = current.copyWith(
            type: WysiwygBlockType.callout,
            calloutKind: callout.kind,
            text: callout.remainingText,
          );
          _applyAtomicBlockTransform(
            idx,
            transformed,
            ctrl,
            callout.remainingText,
          );
          return;
        }
      }
    }

    if (current.text != text) {
      _blocks = List<WysiwygBlock>.of(_blocks)
        ..[idx] = current.copyWith(text: text);
      _markDirtyAndScheduleSave();
    }
    _updateAutocompleteFor(ctrl);
  }

  void _applyAtomicBlockTransform(
    int index,
    WysiwygBlock transformed,
    BlinkSyntaxTextController controller,
    String nextText,
  ) {
    _suppressListeners = true;
    try {
      _blocks = List<WysiwygBlock>.of(_blocks)..[index] = transformed;
      controller.value = TextEditingValue(
        text: nextText,
        selection: TextSelection.collapsed(offset: nextText.length),
        composing: TextRange.empty,
      );
    } finally {
      _suppressListeners = false;
    }
    _dismissAutocomplete(notify: false);
    _markDirtyAndScheduleSave();
    if (mounted) {
      setState(() {});
    }
  }

  KeyEventResult _handleSourceKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // SPK-02 Rule 3: IME-first key handling.
    if (BlinkSyntaxTextController.isValueComposing(_sourceController.value)) {
      if (_isImeNavigationOrCommitKey(event.logicalKey)) {
        return KeyEventResult.ignored;
      }
    }
    if (_handleCommonShortcuts(event)) {
      return KeyEventResult.handled;
    }
    return BlinkSyntaxTextController.handleImeFirstKeyEvent(
      _sourceController.value,
      event,
      hasOverlay: _showAutocomplete,
      onSubmit: () => unawaited(_saveNoteNow(showFeedback: true)),
      onDismissOverlay: _dismissAutocomplete,
      onSelectNextCandidate: _selectNextCandidate,
      onSelectPreviousCandidate: _selectPreviousCandidate,
      onAcceptCandidate: _acceptSelectedCandidate,
    );
  }

  KeyEventResult _handleBlockKeyEvent(
    String blockId,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final idx = _blocks.indexWhere((b) => b.id == blockId);
    if (idx < 0) {
      return KeyEventResult.ignored;
    }
    final block = _blocks[idx];
    final ctrl = _blockControllers[blockId];
    final key = event.logicalKey;

    // SPK-02 Rule 3: while IME composition is active, NEVER intercept
    // Enter/Space/Tab/Esc/arrows!
    if (ctrl != null &&
        BlinkSyntaxTextController.isValueComposing(ctrl.value)) {
      if (_isImeNavigationOrCommitKey(key)) {
        return KeyEventResult.ignored;
      }
    }

    if (_handleCommonShortcuts(event)) {
      return KeyEventResult.handled;
    }

    // Autocomplete navigation when popup is visible.
    if (_showAutocomplete) {
      if (key == LogicalKeyboardKey.escape) {
        _dismissAutocomplete();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _selectNextCandidate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _selectPreviousCandidate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _acceptSelectedCandidate();
        return KeyEventResult.handled;
      }
    }

    // Divider block key handling.
    if (block.type == WysiwygBlockType.divider) {
      if (key == LogicalKeyboardKey.backspace ||
          key == LogicalKeyboardKey.delete) {
        _deleteBlockAndFocusNeighbor(idx);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _insertParagraphAfter(idx);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && idx > 0) {
        _focusBlock(idx - 1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown && idx < _blocks.length - 1) {
        _focusBlock(idx + 1, caretOffset: 0);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (ctrl == null) {
      return KeyEventResult.ignored;
    }

    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isCtrlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    // Enter handling.
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !isCtrlOrMeta) {
      final isMultilineRaw =
          block.type == WysiwygBlockType.codeBlock ||
          block.type == WysiwygBlockType.table ||
          block.type == WysiwygBlockType.fold ||
          block.type == WysiwygBlockType.callout;
      if (isMultilineRaw) {
        if (isShift) {
          _insertParagraphAfter(idx);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      // Shift+Enter inserts a soft newline inside paragraphs/blockquotes.
      if (isShift) {
        return KeyEventResult.ignored;
      }

      _handleBlockEnterSplit(idx, block, ctrl);
      return KeyEventResult.handled;
    }

    // Backspace at offset 0: unwrap structural block or merge with previous.
    if (key == LogicalKeyboardKey.backspace &&
        ctrl.selection.isValid &&
        ctrl.selection.isCollapsed &&
        ctrl.selection.baseOffset == 0) {
      if (block.type == WysiwygBlockType.heading ||
          block.type == WysiwygBlockType.bulletList ||
          block.type == WysiwygBlockType.orderedList ||
          block.type == WysiwygBlockType.taskItem ||
          block.type == WysiwygBlockType.blockquote ||
          block.type == WysiwygBlockType.callout) {
        final reverted = block.copyWith(
          type: WysiwygBlockType.paragraph,
          clearTaskStatus: true,
          clearCalloutKind: true,
        );
        _blocks = List<WysiwygBlock>.of(_blocks)..[idx] = reverted;
        _markDirtyAndScheduleSave();
        setState(() {});
        return KeyEventResult.handled;
      }

      if (block.type == WysiwygBlockType.codeBlock && ctrl.text.isEmpty) {
        final reverted = block.copyWith(
          type: WysiwygBlockType.paragraph,
          clearCodeLanguage: true,
        );
        ctrl.enableBlockPrefixes = false;
        _blocks = List<WysiwygBlock>.of(_blocks)..[idx] = reverted;
        _markDirtyAndScheduleSave();
        setState(() {});
        return KeyEventResult.handled;
      }

      if (block.type == WysiwygBlockType.paragraph && idx > 0) {
        final prev = _blocks[idx - 1];
        if (prev.type == WysiwygBlockType.divider) {
          final removed = _blocks[idx - 1];
          _removeBlockResources(removed.id);
          final nextBlocks = List<WysiwygBlock>.of(_blocks)..removeAt(idx - 1);
          setState(() {
            _blocks = nextBlocks;
            _activeBlockIndex = idx - 1;
          });
          _markDirtyAndScheduleSave();
          return KeyEventResult.handled;
        }
        if (prev.isTextMergeable) {
          final joinOffset = prev.text.length;
          final mergedText = '${prev.text}${block.text}';
          final removed = _blocks[idx];
          _removeBlockResources(removed.id);
          final nextBlocks = List<WysiwygBlock>.of(_blocks)
            ..[idx - 1] = prev.copyWith(text: mergedText)
            ..removeAt(idx);
          setState(() {
            _blocks = nextBlocks;
          });
          _markDirtyAndScheduleSave();
          _focusBlock(idx - 1, caretOffset: joinOffset);
          return KeyEventResult.handled;
        }
      }
    }

    // ArrowUp on first line moves smoothly to previous block.
    if (key == LogicalKeyboardKey.arrowUp &&
        !isShift &&
        !isCtrlOrMeta &&
        ctrl.selection.isValid &&
        ctrl.selection.isCollapsed &&
        idx > 0) {
      final beforeCaret = ctrl.text.substring(0, ctrl.selection.baseOffset);
      if (!beforeCaret.contains('\n')) {
        _focusBlock(idx - 1);
        return KeyEventResult.handled;
      }
    }

    // ArrowDown on last line moves smoothly to next block.
    if (key == LogicalKeyboardKey.arrowDown &&
        !isShift &&
        !isCtrlOrMeta &&
        ctrl.selection.isValid &&
        ctrl.selection.isCollapsed &&
        idx < _blocks.length - 1) {
      final afterCaret = ctrl.text.substring(ctrl.selection.baseOffset);
      if (!afterCaret.contains('\n')) {
        _focusBlock(idx + 1, caretOffset: 0);
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  bool _handleCommonShortcuts(KeyEvent event) {
    final isCtrlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!isCtrlOrMeta) {
      return false;
    }
    if (event.logicalKey == LogicalKeyboardKey.slash) {
      _toggleEditorMode();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyS) {
      unawaited(_saveNoteNow(showFeedback: true));
      return true;
    }
    return false;
  }

  void _handleBlockEnterSplit(
    int idx,
    WysiwygBlock block,
    BlinkSyntaxTextController ctrl,
  ) {
    final text = ctrl.text;

    // On Enter inside paragraph, detect `---`/`***` -> divider and ```lang -> codeBlock.
    if (block.type == WysiwygBlockType.paragraph) {
      final matched = WysiwygDocument.matchPrefixShortcut(text.trim());
      if (matched != null && matched.type == WysiwygBlockType.divider) {
        final dividerBlock = WysiwygBlock(
          id: WysiwygDocument.nextBlockId(),
          type: WysiwygBlockType.divider,
          dividerMarker: text.trim().startsWith('*') ? '***' : '---',
        );
        final nextPara = WysiwygBlock(
          id: WysiwygDocument.nextBlockId(),
          type: WysiwygBlockType.paragraph,
        );
        _removeBlockResources(block.id);
        final nextBlocks = List<WysiwygBlock>.of(_blocks)
          ..[idx] = dividerBlock
          ..insert(idx + 1, nextPara);
        setState(() => _blocks = nextBlocks);
        _markDirtyAndScheduleSave();
        _focusBlock(idx + 1, caretOffset: 0);
        return;
      }
      if (matched != null && matched.type == WysiwygBlockType.codeBlock) {
        final codeBlock = block.copyWith(
          type: WysiwygBlockType.codeBlock,
          codeLanguage: matched.remainingText,
          text: '',
        );
        _applyAtomicBlockTransform(idx, codeBlock, ctrl, '');
        return;
      }
    }

    // Pressing Enter on an empty list/task/quote item exits back to paragraph.
    if ((block.isListLike || block.type == WysiwygBlockType.blockquote) &&
        text.trim().isEmpty) {
      final plain = block.copyWith(
        type: WysiwygBlockType.paragraph,
        clearTaskStatus: true,
        clearBlankLinesBefore: true,
      );
      _applyAtomicBlockTransform(idx, plain, ctrl, '');
      return;
    }

    final sel = ctrl.selection;
    final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(start, text.length) : text.length;
    final before = text.substring(0, start);
    final after = text.substring(end);

    final WysiwygBlock nextBlock;
    if (block.type == WysiwygBlockType.bulletList) {
      nextBlock = WysiwygBlock(
        id: WysiwygDocument.nextBlockId(),
        type: WysiwygBlockType.bulletList,
        listMarker: block.listMarker,
        indentPrefix: block.indentPrefix,
        text: after,
        blankLinesBefore: 0,
      );
    } else if (block.type == WysiwygBlockType.orderedList) {
      nextBlock = WysiwygBlock(
        id: WysiwygDocument.nextBlockId(),
        type: WysiwygBlockType.orderedList,
        orderNumber: block.orderNumber + 1,
        indentPrefix: block.indentPrefix,
        text: after,
        blankLinesBefore: 0,
      );
    } else if (block.type == WysiwygBlockType.taskItem) {
      nextBlock = WysiwygBlock(
        id: WysiwygDocument.nextBlockId(),
        type: WysiwygBlockType.taskItem,
        taskStatus: TaskStatus.open,
        listMarker: block.listMarker,
        indentPrefix: block.indentPrefix,
        text: after,
        blankLinesBefore: 0,
      );
    } else {
      nextBlock = WysiwygBlock(
        id: WysiwygDocument.nextBlockId(),
        type: WysiwygBlockType.paragraph,
        text: after,
      );
    }

    _suppressListeners = true;
    try {
      ctrl.value = TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: before.length),
        composing: TextRange.empty,
      );
      final updated = List<WysiwygBlock>.of(_blocks)
        ..[idx] = block.copyWith(text: before)
        ..insert(idx + 1, nextBlock);
      _blocks = updated;
    } finally {
      _suppressListeners = false;
    }

    _dismissAutocomplete(notify: false);
    _markDirtyAndScheduleSave();
    setState(() {});
    _focusBlock(idx + 1, caretOffset: 0);
  }

  void _insertParagraphAfter(int idx) {
    final nextPara = WysiwygBlock(
      id: WysiwygDocument.nextBlockId(),
      type: WysiwygBlockType.paragraph,
    );
    final nextBlocks = List<WysiwygBlock>.of(_blocks)
      ..insert(idx + 1, nextPara);
    setState(() => _blocks = nextBlocks);
    _markDirtyAndScheduleSave();
    _focusBlock(idx + 1, caretOffset: 0);
  }

  void _deleteBlockAndFocusNeighbor(int idx) {
    final removed = _blocks[idx];
    _removeBlockResources(removed.id);
    final nextBlocks = List<WysiwygBlock>.of(_blocks)..removeAt(idx);
    if (nextBlocks.isEmpty) {
      nextBlocks.add(
        WysiwygBlock(
          id: WysiwygDocument.nextBlockId(),
          type: WysiwygBlockType.paragraph,
        ),
      );
    }
    setState(() => _blocks = nextBlocks);
    _markDirtyAndScheduleSave();
    final targetIdx = (idx - 1).clamp(0, nextBlocks.length - 1);
    _focusBlock(targetIdx);
  }

  static bool _isImeNavigationOrCommitKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.tab ||
      key == LogicalKeyboardKey.escape ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight;

  void _toggleEditorMode() {
    if (_isAnyControllerComposing) {
      return;
    }
    widget.workspace.toggleNoteEditorMode();
  }

  // ---- Autocomplete management (SPK-02 Rule 4) ----

  void _updateAutocompleteFor(BlinkSyntaxTextController controller) {
    final trigger = BlinkSyntaxTextController.detectAutocompleteTrigger(
      controller.value,
    );
    _activeTrigger = trigger;
    if (trigger == null) {
      _dismissAutocomplete();
      return;
    }
    final epoch = ++_candidateQueryEpoch;
    unawaited(_loadAutocompleteCandidates(trigger, epoch));
  }

  Future<void> _loadAutocompleteCandidates(
    AutocompleteTrigger trigger,
    int epoch,
  ) async {
    final results = await BlinkEditorController.queryAutocompleteCandidates(
      widget.workspace.vault,
      trigger,
      excludeEntryId: _loadedEntryId,
    );
    if (!mounted || epoch != _candidateQueryEpoch) {
      return;
    }
    setState(() {
      _candidates = results;
      _selectedCandidateIndex = 0;
    });
    _syncOverlayPortal();
  }

  void _syncOverlayPortal() {
    if (!mounted) {
      return;
    }
    final shouldShowDesktopOverlay = !widget.isMobile && _showAutocomplete;
    if (shouldShowDesktopOverlay && !_overlayController.isShowing) {
      _overlayController.show();
    } else if (!shouldShowDesktopOverlay && _overlayController.isShowing) {
      _overlayController.hide();
    }
  }

  void _dismissAutocomplete({bool notify = true}) {
    final hadAny = _activeTrigger != null || _candidates.isNotEmpty;
    _activeTrigger = null;
    _candidates = const <AutocompleteCandidate>[];
    _selectedCandidateIndex = 0;
    if (_overlayController.isShowing) {
      _overlayController.hide();
    }
    if (notify && hadAny && mounted) {
      setState(() {});
    }
  }

  void _selectNextCandidate() {
    if (_candidates.isEmpty) {
      return;
    }
    setState(() {
      _selectedCandidateIndex =
          (_selectedCandidateIndex + 1) % _candidates.length;
    });
  }

  void _selectPreviousCandidate() {
    if (_candidates.isEmpty) {
      return;
    }
    setState(() {
      _selectedCandidateIndex =
          (_selectedCandidateIndex - 1 + _candidates.length) %
          _candidates.length;
    });
  }

  void _acceptSelectedCandidate() {
    if (!_showAutocomplete) {
      return;
    }
    final idx = _selectedCandidateIndex.clamp(0, _candidates.length - 1);
    _acceptCandidate(_candidates[idx]);
  }

  void _acceptCandidate(AutocompleteCandidate candidate) {
    final trigger = _activeTrigger;
    final ctrl = _activeTextController;
    if (trigger == null || ctrl == null) {
      return;
    }

    // In WYSIWYG mode, structured `/` templates (`/insight`, `/note`,
    // `/warning`, `/fold`, `/task`) convert in-place into native WysiwygBlocks
    // instead of leaving raw multi-line Markdown syntax inside a paragraph.
    if (_isWysiwyg &&
        trigger.kind == AutocompleteTriggerKind.slash &&
        _activeBlockIndex >= 0 &&
        _activeBlockIndex < _blocks.length &&
        _tryApplyWysiwygSlashTemplate(trigger, candidate, ctrl)) {
      if (candidate.isPrivate) {
        _privacyLocked = true;
      }
      _dismissAutocomplete();
      _markDirtyAndScheduleSave();
      return;
    }

    final applied = ctrl.applyAutocompleteSelection(
      trigger,
      candidate.insertText,
    );
    if (!applied) {
      return;
    }
    if (candidate.isPrivate) {
      _privacyLocked = true;
    }
    _dismissAutocomplete();
    _markDirtyAndScheduleSave();
  }

  bool _tryApplyWysiwygSlashTemplate(
    AutocompleteTrigger trigger,
    AutocompleteCandidate candidate,
    BlinkSyntaxTextController ctrl,
  ) {
    // SPK-02 Rule 1: never mutate TextEditingValue while IME composing.
    if (ctrl.isComposing) {
      return false;
    }
    final text = ctrl.text;
    if (trigger.triggerStart < 0 ||
        trigger.triggerEnd > text.length ||
        trigger.triggerStart > trigger.triggerEnd) {
      return false;
    }
    final parsed = WysiwygDocument.parse(candidate.insertText.trimRight());
    if (parsed.length != 1) {
      return false;
    }
    final template = parsed.first;
    if (template.type == WysiwygBlockType.paragraph) {
      return false;
    }

    final idx = _activeBlockIndex;
    final current = _blocks[idx];
    final before = text.substring(0, trigger.triggerStart);
    final after = text.substring(trigger.triggerEnd);

    if (before.trim().isEmpty && after.trim().isEmpty) {
      final converted = current.copyWith(
        type: template.type,
        text: template.text,
        level: template.level,
        orderNumber: template.orderNumber,
        taskStatus: template.taskStatus,
        clearTaskStatus: template.taskStatus == null,
        calloutKind: template.calloutKind,
        clearCalloutKind: template.calloutKind == null,
        codeLanguage: template.codeLanguage,
        clearCodeLanguage: template.codeLanguage == null,
      );
      _applyAtomicBlockTransform(idx, converted, ctrl, converted.text);
      if (converted.type == WysiwygBlockType.fold) {
        _blockFocusNodes[current.id]?.unfocus();
        if (mounted) {
          setState(() => _activeBlockIndex = -1);
        }
      }
      return true;
    }

    final trimmedBefore = before.trimRight();
    final trimmedAfter = after.trimLeft();
    final insertedBlock = template.copyWith(id: WysiwygDocument.nextBlockId());
    final nextBlocks = List<WysiwygBlock>.of(_blocks)
      ..[idx] = current.copyWith(text: trimmedBefore)
      ..insert(idx + 1, insertedBlock);
    if (trimmedAfter.isNotEmpty) {
      nextBlocks.insert(
        idx + 2,
        WysiwygBlock(
          id: WysiwygDocument.nextBlockId(),
          type: WysiwygBlockType.paragraph,
          text: trimmedAfter,
        ),
      );
    }

    _suppressListeners = true;
    try {
      ctrl.value = TextEditingValue(
        text: trimmedBefore,
        selection: TextSelection.collapsed(offset: trimmedBefore.length),
        composing: TextRange.empty,
      );
      _blocks = nextBlocks;
    } finally {
      _suppressListeners = false;
    }

    if (insertedBlock.type == WysiwygBlockType.fold) {
      _blockFocusNodes[current.id]?.unfocus();
      if (mounted) {
        setState(() => _activeBlockIndex = -1);
      }
    } else {
      if (mounted) {
        setState(() {});
      }
      _focusBlock(idx + 1, caretOffset: insertedBlock.text.length);
    }
    return true;
  }

  // ---- Toolbar Formatting Actions (ALL strictly IME guarded) ----

  void _applyInlineWrap(String prefix, String suffix, String placeholder) {
    if (_isTrashed || _isAnyControllerComposing) {
      return;
    }
    if (_isWysiwyg &&
        (_activeBlockIndex < 0 || _activeBlockIndex >= _blocks.length)) {
      _focusEndOrAppendParagraph();
    }
    final ctrl = _activeTextController;
    if (ctrl == null || ctrl.isComposing) {
      return;
    }
    final sel = ctrl.selection;
    final text = ctrl.text;
    final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(start, text.length) : text.length;
    final selected = text.substring(start, end);
    final inner = selected.isEmpty ? placeholder : selected;
    final inserted = '$prefix$inner$suffix';
    final nextText = text.replaceRange(start, end, inserted);
    final nextSelection = selected.isEmpty
        ? TextSelection(
            baseOffset: start + prefix.length,
            extentOffset: start + prefix.length + inner.length,
          )
        : TextSelection.collapsed(offset: start + inserted.length);

    ctrl.value = TextEditingValue(
      text: nextText,
      selection: nextSelection,
      composing: TextRange.empty,
    );
    _activeFocusNode?.requestFocus();
  }

  void _cycleHeadingFormat() {
    if (_isTrashed || _isAnyControllerComposing) {
      return;
    }
    if (!_isWysiwyg) {
      _sourceController.insertSnippetIfNotComposing('# ');
      _effectiveSourceFocusNode.requestFocus();
      return;
    }
    final idx = _activeBlockIndex.clamp(0, _blocks.length - 1);
    if (_blocks.isEmpty) {
      return;
    }
    final block = _blocks[idx];
    final WysiwygBlock next;
    if (block.type != WysiwygBlockType.heading) {
      next = block.copyWith(
        type: WysiwygBlockType.heading,
        level: 1,
        clearTaskStatus: true,
        clearCalloutKind: true,
      );
    } else if (block.level < 3) {
      next = block.copyWith(level: block.level + 1);
    } else {
      next = block.copyWith(type: WysiwygBlockType.paragraph);
    }
    setState(() {
      _blocks = List<WysiwygBlock>.of(_blocks)..[idx] = next;
    });
    _markDirtyAndScheduleSave();
    _focusBlock(idx);
  }

  void _toggleBlockFormat(WysiwygBlockType targetType, String sourceSnippet) {
    if (_isTrashed || _isAnyControllerComposing) {
      return;
    }
    if (!_isWysiwyg) {
      _sourceController.insertSnippetIfNotComposing(sourceSnippet);
      _effectiveSourceFocusNode.requestFocus();
      return;
    }
    if (_blocks.isEmpty) {
      return;
    }
    final idx = _activeBlockIndex < 0
        ? _blocks.length - 1
        : _activeBlockIndex.clamp(0, _blocks.length - 1);
    final block = _blocks[idx];

    if (targetType == WysiwygBlockType.codeBlock) {
      final next = block.type == WysiwygBlockType.codeBlock
          ? block.copyWith(
              type: WysiwygBlockType.paragraph,
              clearCodeLanguage: true,
            )
          : block.copyWith(
              type: WysiwygBlockType.codeBlock,
              codeLanguage: '',
              clearTaskStatus: true,
              clearCalloutKind: true,
            );
      setState(() {
        _blocks = List<WysiwygBlock>.of(_blocks)..[idx] = next;
      });
      _markDirtyAndScheduleSave();
      _focusBlock(idx);
      return;
    }

    final next = block.type == targetType
        ? block.copyWith(
            type: WysiwygBlockType.paragraph,
            clearTaskStatus: true,
            clearCalloutKind: true,
          )
        : block.copyWith(
            type: targetType,
            taskStatus: targetType == WysiwygBlockType.taskItem
                ? TaskStatus.open
                : null,
            clearTaskStatus: targetType != WysiwygBlockType.taskItem,
            clearCalloutKind: true,
          );
    setState(() {
      _blocks = List<WysiwygBlock>.of(_blocks)..[idx] = next;
    });
    _markDirtyAndScheduleSave();
    _focusBlock(idx);
  }

  void _toggleTaskItemAt(int index) {
    if (_isTrashed || index < 0 || index >= _blocks.length) {
      return;
    }
    final block = _blocks[index];
    if (block.type != WysiwygBlockType.taskItem) {
      return;
    }
    final isDone = block.taskStatus == TaskStatus.done;
    final nextStatus = isDone ? TaskStatus.open : TaskStatus.done;
    setState(() {
      _blocks = List<WysiwygBlock>.of(_blocks)
        ..[index] = block.copyWith(taskStatus: nextStatus);
    });
    _isDirty = true;
    unawaited(_saveNoteNow());
  }

  Future<void> _attachFile() async {
    if (_isTrashed || _loadedEntryId == null) {
      return;
    }
    final blob = await widget.workspace.importFileFromPicker();
    if (blob == null || !mounted) {
      return;
    }
    if (!_attachedBlobSha256s.contains(blob.sha256)) {
      setState(() {
        _attachedBlobSha256s = List<String>.unmodifiable(<String>[
          ..._attachedBlobSha256s,
          blob.sha256,
        ]);
        _isDirty = true;
      });
      await _saveNoteNow();
    }
  }

  Future<void> _detachBlob(String sha256) async {
    if (_isTrashed || _loadedEntryId == null) {
      return;
    }
    setState(() {
      _attachedBlobSha256s = List<String>.unmodifiable(
        _attachedBlobSha256s.where((item) => item != sha256),
      );
      _isDirty = true;
    });
    await _saveNoteNow();
  }

  void _replaceBodyPreservingMode(String nextMd) {
    final oldControllers = _blockControllers.values.toList(growable: false);
    final oldFocusNodes = _blockFocusNodes.values.toList(growable: false);
    _blockControllers.clear();
    _blockFocusNodes.clear();
    for (final node in oldFocusNodes) {
      node.onKeyEvent = null;
    }
    if (oldControllers.isNotEmpty || oldFocusNodes.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in oldFocusNodes) {
          node.dispose();
        }
        for (final ctrl in oldControllers) {
          ctrl.dispose();
        }
      });
    }

    _suppressListeners = true;
    try {
      final sourceOffset = _sourceController.selection.isValid
          ? _sourceController.selection.baseOffset.clamp(0, nextMd.length)
          : nextMd.length;
      _sourceController.value = TextEditingValue(
        text: nextMd,
        selection: TextSelection.collapsed(offset: sourceOffset),
        composing: TextRange.empty,
      );
      final prevActiveIndex = _activeBlockIndex;
      _blocks = WysiwygDocument.parse(nextMd);
      if (prevActiveIndex >= 0 && prevActiveIndex < _blocks.length) {
        _activeBlockIndex = prevActiveIndex;
      } else {
        _activeBlockIndex = -1;
      }
    } finally {
      _suppressListeners = false;
    }
  }

  Future<void> _togglePrivacy() async {
    if (_isTrashed || _loadedEntryId == null || _isAnyControllerComposing) {
      return;
    }
    final currentlyPrivate = _isCurrentlyPrivate;
    if (currentlyPrivate) {
      final currentMd = _currentSerializedMarkdown();
      final cleanedMd = _bfm.stripPrivateTokens(currentMd);
      if (cleanedMd != currentMd) {
        _replaceBodyPreservingMode(cleanedMd);
      }
      setState(() {
        _privacyLocked = false;
        _pendingPrivacyDowngrade = true;
        _isDirty = true;
      });
      final saved = await _saveNoteNow(allowPrivacyDowngrade: true);
      if (saved != null && mounted) {
        widget.workspace.showBanner('已取消私密，恢复为常规笔记。');
      }
    } else {
      setState(() {
        _privacyLocked = true;
        _pendingPrivacyDowngrade = false;
        _isDirty = true;
      });
      final saved = await _saveNoteNow();
      if (saved != null && mounted) {
        widget.workspace.showBanner('已设为私密，仅存本机。');
      }
    }
  }

  Future<void> _copyMarkdown() async {
    final md = _currentSerializedMarkdown();
    await Clipboard.setData(ClipboardData(text: md));
    widget.workspace.showBanner('已复制 Markdown 原文。');
  }

  Future<void> _softDeleteActiveNote() async {
    final entry = widget.entry;
    if (entry == null) {
      return;
    }
    _cancelTimers();
    _isDirty = false;
    await widget.workspace.softDeleteEntry(entry.id);
    if (widget.isMobile) {
      widget.onBack?.call();
    }
  }

  void _handleLinkTap(BfmParsedLink link) {
    if (link.targetKind == BfmLinkTargetKind.entry &&
        link.targetId != null &&
        link.targetId!.isNotEmpty) {
      if (widget.onOpenEntry != null) {
        widget.onOpenEntry!(link.targetId!);
      } else {
        unawaited(widget.workspace.openEntryById(link.targetId!));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final entry = widget.entry;

    if (entry == null) {
      return ColoredBox(
        color: tokens.canvas,
        child: Center(
          child: Text(
            '选择一篇笔记开始写作',
            style: BlinkTypography.body(tokens, color: tokens.textMuted),
          ),
        ),
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            _toggleEditorMode,
        const SingleActivator(LogicalKeyboardKey.slash, meta: true):
            _toggleEditorMode,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_saveNoteNow(showFeedback: true)),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_saveNoteNow(showFeedback: true)),
      },
      child: ColoredBox(
        key: const Key('blink_markdown_editor'),
        color: tokens.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.isMobile) _buildMobileHeader(context, tokens, entry),
            if (_isTrashed) _buildTrashBanner(tokens, entry),
            Expanded(
              child: OverlayPortal(
                controller: _overlayController,
                overlayChildBuilder: (_) => CompositedTransformFollower(
                  link: _autocompleteLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  offset: const Offset(0, 6),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: _NoteAutocompletePopup(
                      candidates: _candidates,
                      selectedIndex: _selectedCandidateIndex,
                      onSelect: _acceptCandidate,
                      onDismiss: _dismissAutocomplete,
                    ),
                  ),
                ),
                child: _isTrashed
                    ? _buildReadOnlyTrashedView(tokens, entry)
                    : _isWysiwyg
                    ? _buildWysiwygBody(context, tokens)
                    : _buildSourceBody(context, tokens),
              ),
            ),
            if (widget.isMobile && !_isTrashed)
              _buildMobileBottomAccessory(context, tokens)
            else if (!widget.isMobile && !_isTrashed)
              _buildDesktopBottomToolbar(context, tokens, entry),
          ],
        ),
      ),
    );
  }

  // ---- Desktop Typora-Style Bottom Toolbar ----

  Widget _buildDesktopBottomToolbar(
    BuildContext context,
    BlinkColorTokens tokens,
    RawEntry entry,
  ) {
    final saveLabel = _isSaving
        ? '保存中…'
        : _isDirty
        ? '未保存'
        : '已保存';

    Widget formatBtn({
      required Key buttonKey,
      required String tooltip,
      required Widget child,
      required VoidCallback onPressed,
      bool active = false,
    }) {
      return Tooltip(
        message: tooltip,
        child: InkWell(
          key: buttonKey,
          borderRadius: BorderRadius.circular(6),
          onTap: _isTrashed ? null : onPressed,
          child: Container(
            height: 28,
            constraints: const BoxConstraints(minWidth: 28),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? tokens.accentSubtle : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: child,
          ),
        ),
      );
    }

    final activeType =
        _isWysiwyg &&
            _activeBlockIndex >= 0 &&
            _activeBlockIndex < _blocks.length
        ? _blocks[_activeBlockIndex].type
        : null;

    final isPrivate = _isCurrentlyPrivate;

    final formatItems =
        <
          ({
            Key buttonKey,
            String id,
            String label,
            String tooltip,
            bool active,
            VoidCallback onPressed,
            Widget child,
          })
        >[
          (
            buttonKey: const Key('note_fmt_heading'),
            id: 'heading',
            label: '标题 (H1–H3)',
            tooltip: '标题 (H1–H3)',
            active: activeType == WysiwygBlockType.heading,
            onPressed: _cycleHeadingFormat,
            child: Text(
              'H',
              style: BlinkTypography.controlLabel(tokens).copyWith(
                fontWeight: FontWeight.w600,
                color: activeType == WysiwygBlockType.heading
                    ? tokens.accentPrimary
                    : tokens.textSecondary,
              ),
            ),
          ),
          (
            buttonKey: const Key('note_fmt_bold'),
            id: 'bold',
            label: '加粗',
            tooltip: '加粗',
            active: false,
            onPressed: () => _applyInlineWrap('**', '**', '加粗文本'),
            child: Text(
              'B',
              style: BlinkTypography.controlLabel(tokens).copyWith(
                fontWeight: FontWeight.w600,
                color: tokens.textSecondary,
              ),
            ),
          ),
          (
            buttonKey: const Key('note_fmt_italic'),
            id: 'italic',
            label: '斜体',
            tooltip: '斜体',
            active: false,
            onPressed: () => _applyInlineWrap('*', '*', '斜体文本'),
            child: Text(
              'I',
              style: BlinkTypography.controlLabel(tokens).copyWith(
                fontStyle: FontStyle.italic,
                color: tokens.textSecondary,
              ),
            ),
          ),
          (
            buttonKey: const Key('note_fmt_highlight'),
            id: 'highlight',
            label: '高亮',
            tooltip: '高亮',
            active: false,
            onPressed: () => _applyInlineWrap('==', '==', '高亮内容'),
            child: Text(
              '==',
              style: BlinkTypography.metaLabel(
                tokens,
                color: tokens.textSecondary,
              ),
            ),
          ),
          (
            buttonKey: const Key('note_fmt_task'),
            id: 'task',
            label: '待办清单',
            tooltip: '待办清单',
            active: activeType == WysiwygBlockType.taskItem,
            onPressed: () =>
                _toggleBlockFormat(WysiwygBlockType.taskItem, '- [ ] '),
            child: Icon(
              Icons.check_box_outlined,
              size: 16,
              color: activeType == WysiwygBlockType.taskItem
                  ? tokens.accentPrimary
                  : tokens.textSecondary,
            ),
          ),
          (
            buttonKey: const Key('note_fmt_bullet'),
            id: 'bullet',
            label: '无序列表',
            tooltip: '无序列表',
            active: activeType == WysiwygBlockType.bulletList,
            onPressed: () =>
                _toggleBlockFormat(WysiwygBlockType.bulletList, '- '),
            child: Icon(
              Icons.format_list_bulleted_rounded,
              size: 16,
              color: activeType == WysiwygBlockType.bulletList
                  ? tokens.accentPrimary
                  : tokens.textSecondary,
            ),
          ),
          (
            buttonKey: const Key('note_fmt_quote'),
            id: 'quote',
            label: '引用',
            tooltip: '引用',
            active: activeType == WysiwygBlockType.blockquote,
            onPressed: () =>
                _toggleBlockFormat(WysiwygBlockType.blockquote, '> '),
            child: Icon(
              Icons.format_quote_rounded,
              size: 16,
              color: activeType == WysiwygBlockType.blockquote
                  ? tokens.accentPrimary
                  : tokens.textSecondary,
            ),
          ),
          (
            buttonKey: const Key('note_fmt_code'),
            id: 'code',
            label: '代码块',
            tooltip: '代码块',
            active: activeType == WysiwygBlockType.codeBlock,
            onPressed: () =>
                _toggleBlockFormat(WysiwygBlockType.codeBlock, '```\n\n```'),
            child: Icon(
              Icons.code_rounded,
              size: 16,
              color: activeType == WysiwygBlockType.codeBlock
                  ? tokens.accentPrimary
                  : tokens.textSecondary,
            ),
          ),
        ];

    return Container(
      key: const Key('note_editor_toolbar'),
      height: 40,
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(top: BorderSide(color: tokens.borderHairline, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final compactModeToggle = availableWidth < 600;
          final compactPrivateToggle = availableWidth < 520;
          final showSaveStatus = availableWidth >= 420;

          final statusWidth = showSaveStatus ? 70.0 : 0.0;
          final privateWidth = compactPrivateToggle ? 34.0 : 64.0;
          final modeToggleWidth = compactModeToggle ? 116.0 : 144.0;
          final rightControlsWidth =
              statusWidth +
              12.0 +
              privateWidth +
              6.0 +
              30.0 +
              4.0 +
              modeToggleWidth +
              4.0 +
              30.0;
          const double allFormatsWidth = 256.0;
          const double btnWidth = 34.0;
          const double overflowBtnWidth = 34.0;

          final formatBudget = availableWidth - rightControlsWidth;
          final int visibleFormatCount;
          if (formatBudget >= allFormatsWidth) {
            visibleFormatCount = formatItems.length;
          } else {
            visibleFormatCount = ((formatBudget - overflowBtnWidth) / btnWidth)
                .floor()
                .clamp(0, formatItems.length - 1);
          }
          final visibleFormats = formatItems.sublist(0, visibleFormatCount);
          final overflowFormats = formatItems.sublist(visibleFormatCount);

          return Row(
            children: <Widget>[
              for (final item in visibleFormats)
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: formatBtn(
                    buttonKey: item.buttonKey,
                    tooltip: item.tooltip,
                    active: item.active,
                    onPressed: item.onPressed,
                    child: item.child,
                  ),
                ),
              if (overflowFormats.isNotEmpty)
                PopupMenuButton<String>(
                  key: const Key('note_fmt_overflow'),
                  tooltip: '更多格式',
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(28, 28),
                    fixedSize: const Size(28, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  color: tokens.canvas,
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: tokens.borderHairline, width: 1),
                  ),
                  icon: Icon(
                    Icons.text_format_rounded,
                    size: 17,
                    color: tokens.textSecondary,
                  ),
                  onSelected: (selectedId) {
                    for (final item in overflowFormats) {
                      if (item.id == selectedId) {
                        item.onPressed();
                        break;
                      }
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    for (final item in overflowFormats)
                      PopupMenuItem<String>(
                        key: Key('note_fmt_overflow_${item.id}'),
                        value: item.id,
                        child: Row(
                          children: <Widget>[
                            SizedBox(
                              width: 22,
                              child: Center(child: item.child),
                            ),
                            const SizedBox(width: 8),
                            Text(item.label),
                          ],
                        ),
                      ),
                  ],
                ),
              const Spacer(),
              if (showSaveStatus) ...<Widget>[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isSaving
                            ? tokens.accentPrimary
                            : _isDirty
                            ? tokens.statusWarn
                            : tokens.statusOk,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      saveLabel,
                      key: const Key('note_save_status'),
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 10),
              ],
              Tooltip(
                message: isPrivate ? '点击取消私密（当前仅存本机）' : '设为私密',
                child: InkWell(
                  key: const Key('note_editor_private_toggle'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => unawaited(_togglePrivacy()),
                  child: Container(
                    constraints: compactPrivateToggle
                        ? const BoxConstraints(minWidth: 28, minHeight: 28)
                        : null,
                    padding: compactPrivateToggle
                        ? const EdgeInsets.all(5)
                        : const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                    decoration: BoxDecoration(
                      color: isPrivate
                          ? tokens.privacySubtle
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isPrivate
                            ? tokens.privacyPrivate
                            : tokens.borderHairline,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          isPrivate
                              ? Icons.lock_rounded
                              : Icons.lock_open_rounded,
                          size: 14,
                          color: isPrivate
                              ? tokens.privacyPrivate
                              : tokens.textSecondary,
                        ),
                        if (!compactPrivateToggle) ...<Widget>[
                          const SizedBox(width: 4),
                          Text(
                            '私密',
                            style: BlinkTypography.metaLabel(
                              tokens,
                              color: isPrivate
                                  ? tokens.privacyPrivate
                                  : tokens.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                key: const Key('note_editor_attach_button'),
                tooltip: '添加附件',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                onPressed: widget.workspace.hasOpenVault
                    ? () => unawaited(_attachFile())
                    : null,
                icon: Icon(
                  Icons.attach_file_rounded,
                  size: 17,
                  color: tokens.textSecondary,
                ),
              ),
              const SizedBox(width: 4),
              _buildModeTogglePill(tokens, compact: compactModeToggle),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                key: const Key('note_editor_more_button'),
                tooltip: '更多操作',
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  minimumSize: const Size(30, 30),
                  fixedSize: const Size(30, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 17,
                  color: tokens.textSecondary,
                ),
                onSelected: (action) {
                  if (action == 'copy') {
                    unawaited(_copyMarkdown());
                  } else if (action == 'delete') {
                    unawaited(_softDeleteActiveNote());
                  }
                },
                itemBuilder: (context) => const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'copy',
                    child: Text('复制 Markdown'),
                  ),
                  PopupMenuItem<String>(value: 'delete', child: Text('移入回收站')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildModeTogglePill(
    BlinkColorTokens tokens, {
    required bool compact,
  }) {
    final isWysiwyg = _isWysiwyg;
    if (compact) {
      return Tooltip(
        message: '切换编辑模式 (Ctrl+/)',
        child: InkWell(
          key: const Key('editor_mode_toggle'),
          borderRadius: BorderRadius.circular(8),
          onTap: _toggleEditorMode,
          child: Container(
            constraints: BoxConstraints(
              minHeight: widget.isMobile ? 34 : 28,
              minWidth: 44,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: widget.isMobile ? 6 : 4,
            ),
            decoration: BoxDecoration(
              color: tokens.accentSubtle,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  isWysiwyg ? Icons.article_outlined : Icons.code_rounded,
                  size: 15,
                  color: tokens.accentPrimary,
                ),
                const SizedBox(width: 4),
                Text(
                  isWysiwyg ? '所见即所得' : '源代码',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.accentPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: '切换编辑模式 (Ctrl+/)',
      child: InkWell(
        key: const Key('editor_mode_toggle'),
        borderRadius: BorderRadius.circular(8),
        onTap: _toggleEditorMode,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.borderHairline, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isWysiwyg ? tokens.accentSubtle : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '所见即所得',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: isWysiwyg
                        ? tokens.accentPrimary
                        : tokens.textSecondary,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: !isWysiwyg ? tokens.accentSubtle : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '源代码',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: !isWysiwyg
                        ? tokens.accentPrimary
                        : tokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Mobile Minimal 44px Header & Bottom Sheet ----

  Widget _buildMobileHeader(
    BuildContext context,
    BlinkColorTokens tokens,
    RawEntry entry,
  ) {
    final saveLabel = _isSaving
        ? '保存中…'
        : _isDirty
        ? '编辑中'
        : '已保存';

    return Container(
      key: const Key('mobile_note_editor_header'),
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          TextButton.icon(
            key: const Key('mobile_note_back_button'),
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: tokens.textPrimary,
            ),
            onPressed: () {
              unawaited(_saveNoteNow());
              widget.onBack?.call();
            },
            icon: const Icon(Icons.chevron_left_rounded, size: 22),
            label: const Text('返回'),
          ),
          const SizedBox(width: 4),
          if (!_isTrashed)
            Expanded(
              child: Text(
                saveLabel,
                key: const Key('note_save_status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textMuted,
                ),
              ),
            )
          else
            const Spacer(),
          if (!_isTrashed) ...<Widget>[
            _buildModeTogglePill(tokens, compact: true),
            IconButton(
              key: const Key('note_editor_more_button'),
              tooltip: '更多操作',
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: () => _openMobileMoreSheet(context, tokens),
              icon: Icon(
                Icons.more_horiz_rounded,
                size: 20,
                color: tokens.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openMobileMoreSheet(
    BuildContext context,
    BlinkColorTokens tokens,
  ) async {
    final isPrivate = _isCurrentlyPrivate;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.canvas,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                key: const Key('note_editor_private_toggle'),
                leading: Icon(
                  isPrivate ? Icons.lock_rounded : Icons.lock_open_rounded,
                  color: isPrivate
                      ? tokens.privacyPrivate
                      : tokens.textSecondary,
                ),
                title: Text(isPrivate ? '取消私密' : '设为私密笔记'),
                subtitle: Text(
                  isPrivate ? '当前仅存本机，点击恢复常规笔记' : '仅存本机，不上传云端',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_togglePrivacy());
                },
              ),
              ListTile(
                key: const Key('note_editor_attach_button'),
                leading: Icon(
                  Icons.attach_file_rounded,
                  color: tokens.textSecondary,
                ),
                title: const Text('添加附件'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_attachFile());
                },
              ),
              ListTile(
                leading: Icon(Icons.copy_outlined, color: tokens.textSecondary),
                title: const Text('复制 Markdown'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_copyMarkdown());
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: tokens.statusErr,
                ),
                title: Text(
                  '移入回收站',
                  style: BlinkTypography.body(tokens, color: tokens.statusErr),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_softDeleteActiveNote());
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMobileBottomAccessory(
    BuildContext context,
    BlinkColorTokens tokens,
  ) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final isEditingFocused =
        keyboardInset > 0 ||
        (_isWysiwyg
            ? _activeBlockIndex >= 0
            : _effectiveSourceFocusNode.hasFocus);

    if (!_showAutocomplete && !isEditingFocused) {
      return const SizedBox.shrink();
    }

    Widget quickBtn(String label, VoidCallback onTap, {IconData? icon}) {
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 40, minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: icon != null
              ? Icon(icon, size: 18, color: tokens.textSecondary)
              : Text(
                  label,
                  style: BlinkTypography.controlLabel(tokens)
                      .copyWith(color: tokens.textSecondary),
                ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_showAutocomplete)
            _NoteMobileAutocompleteBar(
              candidates: _candidates,
              selectedIndex: _selectedCandidateIndex,
              onSelect: _acceptCandidate,
              onDismiss: _dismissAutocomplete,
            ),
          if (isEditingFocused)
            Container(
              height: 44,
              decoration: BoxDecoration(
                color: tokens.sidebar,
                border: Border(
                  top: BorderSide(color: tokens.borderHairline, width: 1),
                ),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(
                  children: <Widget>[
                    quickBtn('H', _cycleHeadingFormat),
                    quickBtn('B', () => _applyInlineWrap('**', '**', '加粗文本')),
                    quickBtn('I', () => _applyInlineWrap('*', '*', '斜体文本')),
                    quickBtn('==', () => _applyInlineWrap('==', '==', '高亮')),
                    quickBtn(
                      '',
                      () => _toggleBlockFormat(
                        WysiwygBlockType.taskItem,
                        '- [ ] ',
                      ),
                      icon: Icons.check_box_outlined,
                    ),
                    quickBtn(
                      '',
                      () =>
                          _toggleBlockFormat(WysiwygBlockType.bulletList, '- '),
                      icon: Icons.format_list_bulleted_rounded,
                    ),
                    quickBtn(
                      '',
                      () =>
                          _toggleBlockFormat(WysiwygBlockType.blockquote, '> '),
                      icon: Icons.format_quote_rounded,
                    ),
                    quickBtn(
                      '',
                      () => _toggleBlockFormat(
                        WysiwygBlockType.codeBlock,
                        '```\n\n```',
                      ),
                      icon: Icons.code_rounded,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- Trash Banner & Read-Only View ----

  Widget _buildTrashBanner(BlinkColorTokens tokens, RawEntry entry) {
    return Container(
      key: const Key('note_trash_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.statusWarnSubtle,
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.delete_outline_rounded,
                size: 16,
                color: tokens.statusWarn,
              ),
              const SizedBox(width: 6),
              Text(
                '此笔记在回收站中，不清理将一直保留',
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.statusWarn,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              OutlinedButton(
                key: const Key('note_trash_restore_button'),
                onPressed: () =>
                    unawaited(widget.workspace.restoreEntry(entry.id)),
                child: const Text('还原'),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const Key('note_trash_purge_button'),
                onPressed: () async {
                  await widget.workspace.purgeEntryPermanently(entry.id);
                  if (widget.isMobile) {
                    widget.onBack?.call();
                  }
                },
                child: Text(
                  '彻底删除',
                  style: BlinkTypography.controlLabel(tokens)
                      .copyWith(color: tokens.statusErr),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReadOnlyTrashedView(BlinkColorTokens tokens, RawEntry entry) {
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: widget.isMobile ? 16 : 32,
        vertical: widget.isMobile ? 16 : 28,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: BfmPreviewView(
            bodyMd: entry.bodyMd,
            onTapLink: _handleLinkTap,
            onTapTag: widget.onTagTap,
          ),
        ),
      ),
    );
  }

  // ---- WYSIWYG Document Body ----

  Widget _buildWysiwygBody(BuildContext context, BlinkColorTokens tokens) {
    final horizontalPad = widget.isMobile ? 16.0 : 36.0;
    final topPad = widget.isMobile ? 16.0 : 28.0;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _focusEndOrAppendParagraph,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, 96),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_attachedBlobSha256s.isNotEmpty) ...<Widget>[
                  _buildAttachmentChips(tokens),
                  const SizedBox(height: 12),
                ],
                for (var i = 0; i < _blocks.length; i++) ...<Widget>[
                  _buildWysiwygBlock(context, tokens, i, _blocks[i]),
                  SizedBox(height: _blockBottomSpacing(_blocks, i)),
                ],
                GestureDetector(
                  key: const Key('wysiwyg_tail_tap_area'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _focusEndOrAppendParagraph,
                  child: const SizedBox(height: 120),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double _blockBottomSpacing(List<WysiwygBlock> blocks, int index) {
    if (index >= blocks.length - 1) {
      return 0;
    }
    final current = blocks[index];
    final next = blocks[index + 1];
    if (current.isListLike && next.isListLike && current.type == next.type) {
      return 4;
    }
    if (current.type == WysiwygBlockType.heading) {
      return 10;
    }
    return 10;
  }

  Widget _buildWysiwygBlock(
    BuildContext context,
    BlinkColorTokens tokens,
    int index,
    WysiwygBlock block,
  ) {
    final isActive = index == _activeBlockIndex;
    final body = isActive
        ? _buildActiveBlock(context, tokens, index, block)
        : _buildInactiveBlock(context, tokens, index, block);

    final wrapped = isActive
        ? CompositedTransformTarget(link: _autocompleteLink, child: body)
        : body;

    return KeyedSubtree(key: Key('wysiwyg_block_$index'), child: wrapped);
  }

  Widget _buildActiveBlock(
    BuildContext context,
    BlinkColorTokens tokens,
    int index,
    WysiwygBlock block,
  ) {
    if (block.type == WysiwygBlockType.aiEmbed) {
      return _buildInactiveBlock(context, tokens, index, block);
    }

    if (block.type == WysiwygBlockType.divider) {
      final node = _focusNodeForBlock(block);
      return Focus(
        focusNode: node,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: tokens.accentSubtle,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Divider(height: 1, thickness: 1, color: tokens.accentPrimary),
        ),
      );
    }

    final ctrl = _controllerForBlock(block);
    final node = _focusNodeForBlock(block);
    ctrl.enableInlineSyntax = block.type != WysiwygBlockType.codeBlock;
    final baseBodyStyle = BlinkTypography.editorBody(tokens)
        .copyWith(fontSize: widget.isMobile ? 16 : 15);

    switch (block.type) {
      case WysiwygBlockType.heading:
        final headingStyle = BlinkTypography.headingForLevel(
          tokens,
          block.level,
        );
        ctrl.overrideBaseStyle = headingStyle;
        ctrl.enableBlockPrefixes = false;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                'H${block.level.clamp(1, 6)}',
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textMuted,
                ),
              ),
            ),
            Expanded(
              child: _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: headingStyle,
                hintText: '标题 ${block.level}',
                tokens: tokens,
              ),
            ),
          ],
        );

      case WysiwygBlockType.paragraph:
        ctrl.overrideBaseStyle = baseBodyStyle;
        ctrl.enableBlockPrefixes = false;
        return _buildInlineTextField(
          block: block,
          controller: ctrl,
          focusNode: node,
          style: baseBodyStyle,
          hintText: _blocks.length == 1
              ? '开始写作… 输入 # 标题、- 列表、- [ ] 待办、> 引用'
              : null,
          tokens: tokens,
        );

      case WysiwygBlockType.bulletList:
        ctrl.overrideBaseStyle = baseBodyStyle;
        ctrl.enableBlockPrefixes = false;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  '•',
                  style: baseBodyStyle.copyWith(
                    color: tokens.accentPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: baseBodyStyle,
                hintText: '列表项',
                tokens: tokens,
              ),
            ),
          ],
        );

      case WysiwygBlockType.orderedList:
        ctrl.overrideBaseStyle = baseBodyStyle;
        ctrl.enableBlockPrefixes = false;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 24),
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '${block.orderNumber}.',
                  style: baseBodyStyle.copyWith(
                    color: tokens.accentPrimary,
                    fontFeatures: BlinkTypography.tabularFigures,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: baseBodyStyle,
                hintText: '有序列表项',
                tokens: tokens,
              ),
            ),
          ],
        );

      case WysiwygBlockType.taskItem:
        final status = block.taskStatus ?? TaskStatus.open;
        final isDone = status == TaskStatus.done;
        final isDropped = status == TaskStatus.dropped;
        final taskStyle = baseBodyStyle.copyWith(
          color: (isDone || isDropped) ? tokens.textMuted : tokens.textPrimary,
          decoration: (isDone || isDropped) ? TextDecoration.lineThrough : null,
        );
        ctrl.overrideBaseStyle = taskStyle;
        ctrl.enableBlockPrefixes = false;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildTaskCheckboxIcon(
              tokens: tokens,
              status: status,
              onTap: () => _toggleTaskItemAt(index),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: taskStyle,
                hintText: '待办事项',
                tokens: tokens,
              ),
            ),
          ],
        );

      case WysiwygBlockType.blockquote:
        final quoteStyle = BlinkTypography.blockquote(tokens)
            .copyWith(fontSize: widget.isMobile ? 16 : 15);
        ctrl.overrideBaseStyle = quoteStyle;
        ctrl.enableBlockPrefixes = false;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: tokens.accentPrimary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildInlineTextField(
                  block: block,
                  controller: ctrl,
                  focusNode: node,
                  style: quoteStyle,
                  hintText: '引用内容',
                  tokens: tokens,
                ),
              ),
            ],
          ),
        );

      case WysiwygBlockType.callout:
        final kind = block.calloutKind ?? 'note';
        final accent = _calloutAccent(tokens, kind);
        ctrl.overrideBaseStyle = baseBodyStyle;
        ctrl.enableBlockPrefixes = false;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.aiDerived,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent, width: 1),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(width: 3, color: accent),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () {
                              final nextIdx =
                                  (_calloutKinds.indexOf(kind) + 1) %
                                  _calloutKinds.length;
                              setState(() {
                                _blocks = List<WysiwygBlock>.of(_blocks)
                                  ..[index] = block.copyWith(
                                    calloutKind: _calloutKinds[nextIdx],
                                  );
                              });
                              _markDirtyAndScheduleSave();
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                kind.toUpperCase(),
                                style: BlinkTypography.badge(color: accent),
                              ),
                            ),
                          ),
                          _buildInlineTextField(
                            block: block,
                            controller: ctrl,
                            focusNode: node,
                            style: baseBodyStyle,
                            hintText: '第一行为标题，换行输入正文',
                            tokens: tokens,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

      case WysiwygBlockType.codeBlock:
        final codeStyle = BlinkTypography.codeBlock(tokens);
        ctrl.overrideBaseStyle = codeStyle;
        ctrl.enableBlockPrefixes = false;
        final lang = (block.codeLanguage ?? '').trim();
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.accentPrimary, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  PopupMenuButton<String>(
                    tooltip: '切换代码语言',
                    onSelected: (selected) {
                      setState(() {
                        _blocks = List<WysiwygBlock>.of(_blocks)
                          ..[index] = block.copyWith(codeLanguage: selected);
                      });
                      _markDirtyAndScheduleSave();
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      for (final item in _codeLanguages)
                        PopupMenuItem<String>(
                          value: item,
                          child: Text(item.isEmpty ? '纯文本' : item),
                        ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.canvas,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: tokens.borderHairline),
                      ),
                      child: Text(
                        lang.isEmpty ? '代码' : lang,
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Shift+Enter 跳出',
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.textMuted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: codeStyle,
                hintText: '输入代码…',
                tokens: tokens,
              ),
            ],
          ),
        );

      case WysiwygBlockType.table:
      case WysiwygBlockType.fold:
        final monoStyle = BlinkTypography.codeBlock(tokens);
        ctrl.overrideBaseStyle = monoStyle;
        ctrl.enableBlockPrefixes = true;
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.accentPrimary, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    block.type == WysiwygBlockType.table ? '编辑表格' : '编辑折叠块',
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.accentPrimary,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      node.unfocus();
                      setState(() => _activeBlockIndex = -1);
                    },
                    child: const Text('完成'),
                  ),
                ],
              ),
              _buildInlineTextField(
                block: block,
                controller: ctrl,
                focusNode: node,
                style: monoStyle,
                tokens: tokens,
              ),
            ],
          ),
        );

      case WysiwygBlockType.divider:
      case WysiwygBlockType.aiEmbed:
        return const SizedBox.shrink();
    }
  }

  Widget _buildInlineTextField({
    required WysiwygBlock block,
    required BlinkSyntaxTextController controller,
    required FocusNode focusNode,
    required TextStyle style,
    required BlinkColorTokens tokens,
    String? hintText,
  }) {
    return TextField(
      key: ValueKey<String>('wysiwyg_block_input_${block.id}'),
      controller: controller,
      focusNode: focusNode,
      maxLines: null,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      style: style,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        hintText: hintText,
        hintStyle: style.copyWith(color: tokens.textMuted),
      ),
    );
  }

  Widget _buildInactiveBlock(
    BuildContext context,
    BlinkColorTokens tokens,
    int index,
    WysiwygBlock block,
  ) {
    final baseBodyStyle = BlinkTypography.editorBody(tokens)
        .copyWith(fontSize: widget.isMobile ? 16 : 15);

    Widget content;
    switch (block.type) {
      case WysiwygBlockType.heading:
        final headingStyle = BlinkTypography.headingForLevel(
          tokens,
          block.level,
        );
        content = block.text.isEmpty
            ? Text(
                '标题 ${block.level}',
                style: headingStyle.copyWith(color: tokens.textMuted),
              )
            : BlinkMarkdownInlineText(
                text: block.text,
                baseStyle: headingStyle,
                onTapLink: _handleLinkTap,
                onTapTag: widget.onTagTap,
              );

      case WysiwygBlockType.paragraph:
        if (block.text.isEmpty) {
          content = _blocks.length == 1
              ? Text(
                  '点击此处开始写作，支持 # 标题、- 列表、- [ ] 待办、> 引用…',
                  style: baseBodyStyle.copyWith(color: tokens.textMuted),
                )
              : const SizedBox(height: 24);
        } else {
          content = BlinkMarkdownInlineText(
            text: block.text,
            baseStyle: baseBodyStyle,
            onTapLink: _handleLinkTap,
            onTapTag: widget.onTagTap,
          );
        }

      case WysiwygBlockType.bulletList:
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(
                  '•',
                  style: baseBodyStyle.copyWith(
                    color: tokens.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Expanded(
              child: block.text.isEmpty
                  ? Text(
                      '列表项',
                      style: baseBodyStyle.copyWith(color: tokens.textMuted),
                    )
                  : BlinkMarkdownInlineText(
                      text: block.text,
                      baseStyle: baseBodyStyle,
                      onTapLink: _handleLinkTap,
                      onTapTag: widget.onTagTap,
                    ),
            ),
          ],
        );

      case WysiwygBlockType.orderedList:
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 24),
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '${block.orderNumber}.',
                  style: baseBodyStyle.copyWith(
                    color: tokens.textSecondary,
                    fontFeatures: BlinkTypography.tabularFigures,
                  ),
                ),
              ),
            ),
            Expanded(
              child: block.text.isEmpty
                  ? Text(
                      '有序列表项',
                      style: baseBodyStyle.copyWith(color: tokens.textMuted),
                    )
                  : BlinkMarkdownInlineText(
                      text: block.text,
                      baseStyle: baseBodyStyle,
                      onTapLink: _handleLinkTap,
                      onTapTag: widget.onTagTap,
                    ),
            ),
          ],
        );

      case WysiwygBlockType.taskItem:
        final status = block.taskStatus ?? TaskStatus.open;
        final isDone = status == TaskStatus.done;
        final isDropped = status == TaskStatus.dropped;
        final taskStyle = baseBodyStyle.copyWith(
          color: (isDone || isDropped) ? tokens.textMuted : tokens.textPrimary,
          decoration: (isDone || isDropped) ? TextDecoration.lineThrough : null,
        );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildTaskCheckboxIcon(
              tokens: tokens,
              status: status,
              onTap: () => _toggleTaskItemAt(index),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _focusBlock(index),
                child: block.text.isEmpty
                    ? Text(
                        '待办事项',
                        style: baseBodyStyle.copyWith(color: tokens.textMuted),
                      )
                    : BlinkMarkdownInlineText(
                        text: block.text,
                        baseStyle: taskStyle,
                        onTapLink: _handleLinkTap,
                        onTapTag: widget.onTagTap,
                      ),
              ),
            ),
          ],
        );

      case WysiwygBlockType.blockquote:
        final quoteStyle = BlinkTypography.blockquote(tokens)
            .copyWith(fontSize: widget.isMobile ? 16 : 15);
        content = IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                width: 3,
                decoration: BoxDecoration(
                  color: tokens.borderHairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: block.text.isEmpty
                    ? Text(
                        '引用内容',
                        style: quoteStyle.copyWith(color: tokens.textMuted),
                      )
                    : BlinkMarkdownInlineText(
                        text: block.text,
                        baseStyle: quoteStyle,
                        onTapLink: _handleLinkTap,
                        onTapTag: widget.onTagTap,
                      ),
              ),
            ],
          ),
        );

      case WysiwygBlockType.callout:
        final kind = block.calloutKind ?? 'note';
        final accent = _calloutAccent(tokens, kind);
        final title = block.calloutTitle;
        final body = block.calloutBody;
        content = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.aiDerived,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tokens.borderHairline, width: 1),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(width: 3, color: accent),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            title.isEmpty ? kind.toUpperCase() : title,
                            style: BlinkTypography.controlLabel(tokens)
                                .copyWith(
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          if (body.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            BlinkMarkdownInlineText(
                              text: body,
                              baseStyle: BlinkTypography.body(tokens),
                              onTapLink: _handleLinkTap,
                              onTapTag: widget.onTagTap,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

      case WysiwygBlockType.codeBlock:
        final lang = (block.codeLanguage ?? '').trim();
        content = Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.borderHairline, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (lang.isNotEmpty) ...<Widget>[
                Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.canvas,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: tokens.borderHairline),
                    ),
                    child: Text(
                      lang,
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(
                block.text.isEmpty ? '点击输入代码…' : block.text,
                style: BlinkTypography.codeBlock(
                  tokens,
                  color: block.text.isEmpty
                      ? tokens.textMuted
                      : tokens.textPrimary,
                ),
              ),
            ],
          ),
        );

      case WysiwygBlockType.divider:
        content = Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, thickness: 1, color: tokens.borderHairline),
        );

      case WysiwygBlockType.table:
        content = BfmPreviewView(
          bodyMd: block.text,
          onTapLink: _handleLinkTap,
          onTapTag: widget.onTagTap,
        );

      case WysiwygBlockType.fold:
        return Stack(
          children: <Widget>[
            BfmPreviewView(
              bodyMd: block.text,
              onTapLink: _handleLinkTap,
              onTapTag: widget.onTagTap,
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                tooltip: '编辑折叠块',
                visualDensity: VisualDensity.compact,
                onPressed: () => _focusBlock(index),
                icon: Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: tokens.textMuted,
                ),
              ),
            ),
          ],
        );

      case WysiwygBlockType.aiEmbed:
        return BfmPreviewView(
          bodyMd: block.text,
          onTapLink: _handleLinkTap,
          onTapTag: widget.onTagTap,
        );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _focusBlock(index),
      child: content,
    );
  }

  Widget _buildTaskCheckboxIcon({
    required BlinkColorTokens tokens,
    required TaskStatus status,
    required VoidCallback onTap,
  }) {
    final isDone = status == TaskStatus.done;
    final isDeferred = status == TaskStatus.deferred;
    final isDropped = status == TaskStatus.dropped;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Icon(
          isDone
              ? Icons.check_box_rounded
              : isDeferred
              ? Icons.schedule_rounded
              : isDropped
              ? Icons.indeterminate_check_box_outlined
              : Icons.check_box_outline_blank_rounded,
          size: 18,
          color: isDone
              ? tokens.statusOk
              : isDeferred
              ? tokens.statusWarn
              : isDropped
              ? tokens.textMuted
              : tokens.accentPrimary,
        ),
      ),
    );
  }

  Color _calloutAccent(BlinkColorTokens tokens, String kind) => switch (kind) {
    'warning' || 'caution' => tokens.statusWarn,
    'danger' || 'error' => tokens.statusErr,
    'tip' || 'success' => tokens.statusOk,
    _ => tokens.accentPrimary,
  };

  // ---- Source Mode Body ----

  Widget _buildSourceBody(BuildContext context, BlinkColorTokens tokens) {
    final horizontalPad = widget.isMobile ? 16.0 : 36.0;
    final topPad = widget.isMobile ? 16.0 : 28.0;
    final sourceStyle = BlinkTypography.editorBody(tokens)
        .copyWith(fontSize: widget.isMobile ? 16 : 15);

    return SingleChildScrollView(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(horizontalPad, topPad, horizontalPad, 96),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_attachedBlobSha256s.isNotEmpty) ...<Widget>[
                _buildAttachmentChips(tokens),
                const SizedBox(height: 12),
              ],
              CompositedTransformTarget(
                link: _autocompleteLink,
                child: TextField(
                  key: const Key('note_source_input'),
                  controller: _sourceController,
                  focusNode: _effectiveSourceFocusNode,
                  maxLines: null,
                  minLines: 16,
                  keyboardType: TextInputType.multiline,
                  style: sourceStyle,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '以 Markdown 源代码编辑笔记…',
                    hintStyle: sourceStyle.copyWith(color: tokens.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachmentChips(BlinkColorTokens tokens) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final sha in _attachedBlobSha256s)
          InputChip(
            label: Text('附件 ${sha.length > 10 ? sha.substring(0, 10) : sha}…'),
            backgroundColor: tokens.sidebar,
            side: BorderSide(color: tokens.borderHairline),
            labelStyle: BlinkTypography.metaLabel(tokens),
            onDeleted: _isTrashed ? null : () => unawaited(_detachBlob(sha)),
          ),
      ],
    );
  }
}

class _NoteAutocompletePopup extends StatelessWidget {
  const _NoteAutocompletePopup({
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
      key: const Key('note_autocomplete_overlay'),
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
              key: Key('note_autocomplete_candidate_$index'),
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

class _NoteMobileAutocompleteBar extends StatelessWidget {
  const _NoteMobileAutocompleteBar({
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
      key: const Key('mobile_note_autocomplete_bar'),
      height: 52,
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
                    key: Key('mobile_note_autocomplete_candidate_$index'),
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => onSelect(item),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: 40,
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
