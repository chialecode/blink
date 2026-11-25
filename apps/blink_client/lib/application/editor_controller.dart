import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:blink_client/app/blink_theme.dart';

/// Active autocomplete trigger kind (`docs/ui.md` §2.2 Rule 4).
enum AutocompleteTriggerKind { wikiLink, tag, slash }

/// Immutable trigger span parsed at the collapsed cursor position.
@immutable
class AutocompleteTrigger {
  const AutocompleteTrigger({
    required this.kind,
    required this.triggerStart,
    required this.triggerEnd,
    required this.query,
  });

  final AutocompleteTriggerKind kind;
  final int triggerStart;
  final int triggerEnd;
  final String query;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutocompleteTrigger &&
          kind == other.kind &&
          triggerStart == other.triggerStart &&
          triggerEnd == other.triggerEnd &&
          query == other.query;

  @override
  int get hashCode => Object.hash(kind, triggerStart, triggerEnd, query);
}

/// Single selectable autocomplete suggestion rendered inside `OverlayPortal`.
@immutable
class AutocompleteCandidate {
  const AutocompleteCandidate({
    required this.label,
    required this.subtitle,
    required this.insertText,
    this.isPrivate = false,
  });

  final String label;
  final String subtitle;
  final String insertText;
  final bool isPrivate;
}

class _StyledSegment {
  const _StyledSegment(this.start, this.end, this.style);

  final int start;
  final int end;
  final TextStyle style;
}

/// CJK-IME-safe BFM v1 `TextEditingController` enforcing `SPK-02` Rules 1-4:
/// 1. Zero `TextEditingValue` mutation while `value.composing.isValid && !value.composing.isCollapsed`.
/// 2. Strictly 1:1 UTF-16 length-preserving `buildTextSpan` (NO `WidgetSpan`,
///    NO character insertion/deletion) that preserves `TextDecoration.underline`
///    on `withComposing && value.isComposingRangeValid`.
/// 3. IME-first keyboard handling helper returning `KeyEventResult.ignored` for
///    `Enter`/`Space`/`Tab`/`Esc`/arrows while composing is active.
/// 4. Atomic single-value replacement with `composing: TextRange.empty` when
///    selecting an `OverlayPortal` autocomplete candidate.
class BlinkSyntaxTextController extends TextEditingController {
  BlinkSyntaxTextController({super.text});

  static final RegExp _tokenPattern = RegExp(
    r'(!\[\[ai:[^\]]+\]\]|\[\[[^\]]+\]\]|==[^=\n]+==|(?<![\w/#])#(?:private\b|[\p{L}\p{N}_][\p{L}\p{N}_/\-]*)|^[ \t]*>[ \t]*\[![A-Za-z]+\]|^[ \t]*-[ \t]+\[[ xX>\-]\])',
    multiLine: true,
    unicode: true,
  );

  /// Whether an OS IME pre-edit composition range is currently active.
  bool get isComposing => isValueComposing(value);

  /// Static check for active IME composition (`SPK-02` Rule 1).
  static bool isValueComposing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  /// `SPK-02` Rule 3: IME-first key event dispatcher for `FocusNode.onKeyEvent`.
  ///
  /// Whenever IME composition is active, returns [KeyEventResult.ignored] for
  /// `Enter`, `Space`, `Tab`, `Esc`, and arrow keys so the OS IME consumes the
  /// candidate-selection keystroke without submitting or hijacking focus.
  static KeyEventResult handleImeFirstKeyEvent(
    TextEditingValue value,
    KeyEvent event, {
    required VoidCallback onSubmit,
    VoidCallback? onDismissOverlay,
    VoidCallback? onSelectNextCandidate,
    VoidCallback? onSelectPreviousCandidate,
    VoidCallback? onAcceptCandidate,
    bool hasOverlay = false,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (isValueComposing(value)) {
      if (_isImeNavigationOrCommitKey(key)) {
        return KeyEventResult.ignored;
      }
    }

    if (hasOverlay) {
      if (key == LogicalKeyboardKey.escape) {
        onDismissOverlay?.call();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown &&
          onSelectNextCandidate != null) {
        onSelectNextCandidate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp &&
          onSelectPreviousCandidate != null) {
        onSelectPreviousCandidate();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.tab && onAcceptCandidate != null) {
        onAcceptCandidate();
        return KeyEventResult.handled;
      }
    }

    final isControlOrMeta =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (isControlOrMeta &&
        (key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      onSubmit();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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

  /// `SPK-02` Rule 4: Detects `[[`, `#`, or `/` trigger ONLY when
  /// `selection.isCollapsed` and IME composition is inactive.
  static AutocompleteTrigger? detectAutocompleteTrigger(
    TextEditingValue value,
  ) {
    if (isValueComposing(value)) {
      return null;
    }
    if (!value.selection.isValid || !value.selection.isCollapsed) {
      return null;
    }
    final cursor = value.selection.baseOffset;
    if (cursor < 0 || cursor > value.text.length) {
      return null;
    }

    final lineStart = value.text.lastIndexOf('\n', cursor > 0 ? cursor - 1 : 0);
    final segmentStart = lineStart < 0 ? 0 : lineStart + 1;
    final prefix = value.text.substring(segmentStart, cursor);

    // 1. `[[` wikilink trigger (allows spaces & CJK search terms until `]]`).
    final wikiIndex = prefix.lastIndexOf('[[');
    if (wikiIndex >= 0) {
      final afterOpen = prefix.substring(wikiIndex + 2);
      if (!afterOpen.contains(']]') && !afterOpen.contains('\n')) {
        return AutocompleteTrigger(
          kind: AutocompleteTriggerKind.wikiLink,
          triggerStart: segmentStart + wikiIndex,
          triggerEnd: cursor,
          query: afterOpen,
        );
      }
    }

    // 2. `#` tag trigger at line start or after whitespace.
    final hashIndex = prefix.lastIndexOf('#');
    if (hashIndex >= 0) {
      final beforeHash = hashIndex == 0 ? '' : prefix[hashIndex - 1];
      final afterHash = prefix.substring(hashIndex + 1);
      final validBoundary = hashIndex == 0 || beforeHash.trim().isEmpty;
      if (validBoundary &&
          !afterHash.contains(' ') &&
          !afterHash.contains('\t') &&
          !afterHash.startsWith('#')) {
        return AutocompleteTrigger(
          kind: AutocompleteTriggerKind.tag,
          triggerStart: segmentStart + hashIndex,
          triggerEnd: cursor,
          query: afterHash,
        );
      }
    }

    // 3. `/` BFM snippet trigger at line start or after whitespace.
    final slashIndex = prefix.lastIndexOf('/');
    if (slashIndex >= 0) {
      final beforeSlash = slashIndex == 0 ? '' : prefix[slashIndex - 1];
      final afterSlash = prefix.substring(slashIndex + 1);
      final validBoundary = slashIndex == 0 || beforeSlash.trim().isEmpty;
      if (validBoundary &&
          !afterSlash.contains(' ') &&
          !afterSlash.contains('\t')) {
        return AutocompleteTrigger(
          kind: AutocompleteTriggerKind.slash,
          triggerStart: segmentStart + slashIndex,
          triggerEnd: cursor,
          query: afterSlash,
        );
      }
    }

    return null;
  }

  /// Replaces [trigger] range atomically with [replacement] and clears
  /// `composing` to [TextRange.empty] (`SPK-02` Rules 1 & 4).
  ///
  /// Returns `false` without mutating [value] if IME composition is active.
  bool applyAutocompleteSelection(
    AutocompleteTrigger trigger,
    String replacement,
  ) {
    if (isComposing) {
      return false;
    }
    if (trigger.triggerStart < 0 ||
        trigger.triggerEnd > text.length ||
        trigger.triggerStart > trigger.triggerEnd) {
      return false;
    }
    final nextText = text.replaceRange(
      trigger.triggerStart,
      trigger.triggerEnd,
      replacement,
    );
    final nextOffset = trigger.triggerStart + replacement.length;
    value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
      composing: TextRange.empty,
    );
    return true;
  }

  /// Safely inserts [snippet] at the current selection when NOT composing.
  bool insertSnippetIfNotComposing(String snippet) {
    if (isComposing) {
      return false;
    }
    final sel = value.selection;
    final start = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final end = sel.isValid ? sel.end.clamp(start, text.length) : text.length;
    final nextText = text.replaceRange(start, end, snippet);
    value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + snippet.length),
      composing: TextRange.empty,
    );
    return true;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final tokens = BlinkColorTokens.of(context);
    final baseStyle = style ?? BlinkTypography.editorBody(tokens);
    final source = value.text;
    if (source.isEmpty) {
      return TextSpan(style: baseStyle, text: '');
    }

    final segments = _tokenizeSegments(source, baseStyle, tokens);
    final hasComposingRange =
        withComposing &&
        value.isComposingRangeValid &&
        !value.composing.isCollapsed;
    final composingStart = hasComposingRange
        ? value.composing.start.clamp(0, source.length)
        : -1;
    final composingEnd = hasComposingRange
        ? value.composing.end.clamp(0, source.length)
        : -1;

    final children = <InlineSpan>[];
    for (final seg in segments) {
      if (!hasComposingRange ||
          seg.end <= composingStart ||
          seg.start >= composingEnd) {
        children.add(
          TextSpan(
            text: source.substring(seg.start, seg.end),
            style: seg.style,
          ),
        );
        continue;
      }

      if (seg.start < composingStart) {
        children.add(
          TextSpan(
            text: source.substring(seg.start, composingStart),
            style: seg.style,
          ),
        );
      }

      final overlapStart = seg.start > composingStart
          ? seg.start
          : composingStart;
      final overlapEnd = seg.end < composingEnd ? seg.end : composingEnd;
      if (overlapStart < overlapEnd) {
        children.add(
          TextSpan(
            text: source.substring(overlapStart, overlapEnd),
            style: seg.style.merge(
              const TextStyle(decoration: TextDecoration.underline),
            ),
          ),
        );
      }

      if (seg.end > composingEnd) {
        children.add(
          TextSpan(
            text: source.substring(composingEnd, seg.end),
            style: seg.style,
          ),
        );
      }
    }

    return TextSpan(style: baseStyle, children: children);
  }

  List<_StyledSegment> _tokenizeSegments(
    String source,
    TextStyle baseStyle,
    BlinkColorTokens tokens,
  ) {
    final segments = <_StyledSegment>[];
    var cursor = 0;

    for (final match in _tokenPattern.allMatches(source)) {
      if (match.start > cursor) {
        segments.add(_StyledSegment(cursor, match.start, baseStyle));
      }
      final raw = match.group(0)!;
      if (raw.startsWith('![[ai:')) {
        segments.add(
          _StyledSegment(
            match.start,
            match.end,
            baseStyle.copyWith(color: tokens.textMuted),
          ),
        );
      } else if (raw.startsWith('[[')) {
        _addWikiLinkSegments(
          segments,
          match.start,
          match.end,
          raw,
          baseStyle,
          tokens,
        );
      } else if (raw.startsWith('==')) {
        segments.add(
          _StyledSegment(
            match.start,
            match.end,
            baseStyle.copyWith(backgroundColor: tokens.highlightMark),
          ),
        );
      } else if (raw.startsWith('#')) {
        final isPrivate = raw.toLowerCase() == '#private';
        segments.add(
          _StyledSegment(
            match.start,
            match.end,
            baseStyle.copyWith(
              color: isPrivate ? tokens.privacyPrivate : tokens.accentPrimary,
              fontWeight: isPrivate ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        );
      } else {
        // Callout prefix `> [!type]` or endogenous task prefix `- [ ]`.
        segments.add(
          _StyledSegment(
            match.start,
            match.end,
            baseStyle.copyWith(
              color: tokens.accentPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < source.length) {
      segments.add(_StyledSegment(cursor, source.length, baseStyle));
    }
    return segments;
  }

  void _addWikiLinkSegments(
    List<_StyledSegment> out,
    int start,
    int end,
    String raw,
    TextStyle baseStyle,
    BlinkColorTokens tokens,
  ) {
    final muted = baseStyle.copyWith(color: tokens.textMuted);
    final accent = baseStyle.copyWith(
      color: tokens.accentPrimary,
      fontWeight: FontWeight.w500,
    );
    final pipeOffset = raw.indexOf('|');
    if (pipeOffset > 2 && pipeOffset < raw.length - 3) {
      // Muted `[[target|` + accented `Label` + muted `]]` (exact 1:1 length).
      out.add(_StyledSegment(start, start + pipeOffset + 1, muted));
      out.add(_StyledSegment(start + pipeOffset + 1, end - 2, accent));
      out.add(_StyledSegment(end - 2, end, muted));
      return;
    }
    out.add(_StyledSegment(start, start + 2, muted));
    if (end - 2 > start + 2) {
      out.add(_StyledSegment(start + 2, end - 2, accent));
    }
    out.add(_StyledSegment(end - 2, end, muted));
  }
}

/// Manages active BFM v1 composer/editor state, 500ms crash-safe draft
/// persistence (`RawRepository.saveDraft`), 150ms debounced preview compilation,
/// and `OverlayPortal` autocomplete candidates (`SPK-02`).
class BlinkEditorController extends ChangeNotifier {
  BlinkEditorController({
    required this.vaultProvider,
    this.draftDebounce = const Duration(milliseconds: 500),
    this.previewDebounce = const Duration(milliseconds: 150),
  }) {
    textController.addListener(_onTextControllerChanged);
  }

  final VaultManager? Function() vaultProvider;
  final Duration draftDebounce;
  final Duration previewDebounce;

  final BlinkSyntaxTextController textController = BlinkSyntaxTextController();
  final BfmEngine _bfm = const BfmEngine();

  String? _editingEntryId;
  EntryKind _entryKind = EntryKind.blink;
  bool _privacyLocked = false;
  List<String> _attachedBlobSha256s = const <String>[];
  String _compiledPreviewHtml = '';
  late BfmDocument _parsedPreviewDoc = _bfm.parse('');

  AutocompleteTrigger? _activeTrigger;
  List<AutocompleteCandidate> _candidates = const <AutocompleteCandidate>[];
  int _selectedCandidateIndex = 0;

  bool _isSaving = false;
  bool _hasUnsavedDraft = false;
  bool _suppressListener = false;
  bool _isDisposed = false;
  int _candidateQueryEpoch = 0;

  Timer? _draftTimer;
  Timer? _previewTimer;

  String? get editingEntryId => _editingEntryId;
  bool get isEditingExisting => _editingEntryId != null;
  String get activeDraftKey =>
      _editingEntryId == null ? 'inbox' : 'entry:$_editingEntryId';

  EntryKind get entryKind => _entryKind;
  bool get privacyLocked => _privacyLocked;
  List<String> get attachedBlobSha256s => _attachedBlobSha256s;
  String get compiledPreviewHtml => _compiledPreviewHtml;
  BfmDocument get parsedPreviewDoc => _parsedPreviewDoc;

  AutocompleteTrigger? get activeTrigger => _activeTrigger;
  List<AutocompleteCandidate> get candidates => _candidates;
  int get selectedCandidateIndex => _selectedCandidateIndex;
  bool get showAutocomplete => _activeTrigger != null && _candidates.isNotEmpty;

  bool get isSaving => _isSaving;
  bool get hasUnsavedDraft => _hasUnsavedDraft;

  static const List<AutocompleteCandidate> _slashSnippets =
      <AutocompleteCandidate>[
        AutocompleteCandidate(
          label: '/insight',
          subtitle: '插入洞察 Callout 块',
          insertText: '> [!insight] 洞察\n> ',
        ),
        AutocompleteCandidate(
          label: '/note',
          subtitle: '插入注释 Callout 块',
          insertText: '> [!note] 说明\n> ',
        ),
        AutocompleteCandidate(
          label: '/warning',
          subtitle: '插入警示 Callout 块',
          insertText: '> [!warning] 提示\n> ',
        ),
        AutocompleteCandidate(
          label: '/fold',
          subtitle: '插入 :::fold 折叠块',
          insertText: ':::fold 折叠标题\n内容\n:::\n',
        ),
        AutocompleteCandidate(
          label: '/task',
          subtitle: '插入内生待办 - [ ]',
          insertText: '- [ ] ',
        ),
        AutocompleteCandidate(
          label: '/mark',
          subtitle: '插入 ==高亮== 片段',
          insertText: '==高亮内容==',
        ),
      ];

  /// Loads any persisted crash-recovery draft for the inbox composer.
  Future<void> loadInboxDraft() async {
    final vault = vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    final draft = await vault.raw.loadDraft('inbox');
    if (draft == null || _isDisposed) {
      return;
    }
    _applyLoadedState(
      entryId: null,
      bodyMd: draft.bodyMd,
      entryKind: draft.entryKind,
      privacyLocked: draft.privacyLocked,
      imageBlobSha256s: draft.imageBlobSha256s,
    );
  }

  /// Switches the editor into editing an existing [entry] (restoring any
  /// unsaved draft for `entry:<id>` if present).
  Future<void> startEditingEntry(RawEntry entry) async {
    await flushDraftNow();
    final vault = vaultProvider();
    EditorDraft? draft;
    if (vault != null && vault.isOpen) {
      draft = await vault.raw.loadDraft('entry:${entry.id}');
    }
    if (_isDisposed) {
      return;
    }
    _applyLoadedState(
      entryId: entry.id,
      bodyMd: draft?.bodyMd ?? entry.bodyMd,
      entryKind: draft?.entryKind ?? entry.entryKind,
      privacyLocked: draft?.privacyLocked ?? entry.isPrivate,
      imageBlobSha256s: draft?.imageBlobSha256s ?? entry.imageBlobSha256s,
    );
  }

  /// Returns to the inbox new-entry composer (loading any saved inbox draft).
  Future<void> startNewEntry() async {
    await flushDraftNow();
    final vault = vaultProvider();
    EditorDraft? draft;
    if (vault != null && vault.isOpen) {
      draft = await vault.raw.loadDraft('inbox');
    }
    if (_isDisposed) {
      return;
    }
    _applyLoadedState(
      entryId: null,
      bodyMd: draft?.bodyMd ?? '',
      entryKind: draft?.entryKind ?? EntryKind.blink,
      privacyLocked: draft?.privacyLocked ?? false,
      imageBlobSha256s: draft?.imageBlobSha256s ?? const <String>[],
    );
  }

  void _applyLoadedState({
    required String? entryId,
    required String bodyMd,
    required EntryKind entryKind,
    required bool privacyLocked,
    required List<String> imageBlobSha256s,
  }) {
    _suppressListener = true;
    try {
      _editingEntryId = entryId;
      _entryKind = entryKind;
      _privacyLocked = privacyLocked;
      _attachedBlobSha256s = List<String>.unmodifiable(imageBlobSha256s);
      textController.value = TextEditingValue(
        text: bodyMd,
        selection: TextSelection.collapsed(offset: bodyMd.length),
        composing: TextRange.empty,
      );
      _activeTrigger = null;
      _candidates = const <AutocompleteCandidate>[];
      _selectedCandidateIndex = 0;
      _compilePreviewImmediate(bodyMd);
    } finally {
      _suppressListener = false;
    }
    _safeNotify();
  }

  void setEntryKind(EntryKind kind) {
    if (_entryKind == kind) {
      return;
    }
    _entryKind = kind;
    _scheduleDraftSave();
    _safeNotify();
  }

  void setPrivacyLocked(bool locked) {
    if (_privacyLocked == locked) {
      return;
    }
    _privacyLocked = locked;
    _scheduleDraftSave();
    _safeNotify();
  }

  void attachBlobSha256(String sha256) {
    if (_attachedBlobSha256s.contains(sha256)) {
      return;
    }
    _attachedBlobSha256s = List<String>.unmodifiable(<String>[
      ..._attachedBlobSha256s,
      sha256,
    ]);
    _scheduleDraftSave();
    _safeNotify();
  }

  void detachBlobSha256(String sha256) {
    if (!_attachedBlobSha256s.contains(sha256)) {
      return;
    }
    _attachedBlobSha256s = List<String>.unmodifiable(
      _attachedBlobSha256s.where((item) => item != sha256),
    );
    _scheduleDraftSave();
    _safeNotify();
  }

  void dismissAutocomplete() {
    if (_activeTrigger == null && _candidates.isEmpty) {
      return;
    }
    _activeTrigger = null;
    _candidates = const <AutocompleteCandidate>[];
    _selectedCandidateIndex = 0;
    _safeNotify();
  }

  void selectNextCandidate() {
    if (_candidates.isEmpty) {
      return;
    }
    _selectedCandidateIndex =
        (_selectedCandidateIndex + 1) % _candidates.length;
    _safeNotify();
  }

  void selectPreviousCandidate() {
    if (_candidates.isEmpty) {
      return;
    }
    _selectedCandidateIndex =
        (_selectedCandidateIndex - 1 + _candidates.length) % _candidates.length;
    _safeNotify();
  }

  bool acceptSelectedCandidate() {
    if (!showAutocomplete) {
      return false;
    }
    final index = _selectedCandidateIndex.clamp(0, _candidates.length - 1);
    return acceptCandidate(_candidates[index]);
  }

  bool acceptCandidate(AutocompleteCandidate candidate) {
    final trigger = _activeTrigger;
    if (trigger == null) {
      return false;
    }
    final applied = textController.applyAutocompleteSelection(
      trigger,
      candidate.insertText,
    );
    if (!applied) {
      return false;
    }
    if (candidate.isPrivate) {
      _privacyLocked = true;
    }
    dismissAutocomplete();
    return true;
  }

  /// Submits the current editor text (creating a new `raw_entries` row or
  /// updating the active entry) and clears its crash-recovery draft slot.
  Future<RawEntry?> submit() async {
    if (textController.isComposing) {
      return null;
    }
    final vault = vaultProvider();
    if (vault == null || !vault.isOpen) {
      return null;
    }
    final body = textController.text.trim();
    if (body.isEmpty) {
      return null;
    }

    _isSaving = true;
    _draftTimer?.cancel();
    dismissAutocomplete();
    _safeNotify();

    try {
      final RawEntry saved;
      final draftKey = activeDraftKey;
      if (_editingEntryId == null) {
        saved = await vault.raw.createEntry(
          bodyMd: textController.text,
          entryKind: _entryKind,
          privacyLocked: _privacyLocked,
          imageBlobSha256s: _attachedBlobSha256s,
        );
      } else {
        saved = await vault.raw.updateEntry(
          id: _editingEntryId!,
          bodyMd: textController.text,
          entryKind: _entryKind,
          privacyLocked: _privacyLocked,
          imageBlobSha256s: _attachedBlobSha256s,
        );
      }
      await vault.raw.clearDraft(draftKey);
      _hasUnsavedDraft = false;

      if (_editingEntryId == null) {
        _applyLoadedState(
          entryId: null,
          bodyMd: '',
          entryKind: EntryKind.blink,
          privacyLocked: false,
          imageBlobSha256s: const <String>[],
        );
      } else {
        _applyLoadedState(
          entryId: saved.id,
          bodyMd: saved.bodyMd,
          entryKind: saved.entryKind,
          privacyLocked: saved.isPrivate,
          imageBlobSha256s: saved.imageBlobSha256s,
        );
      }
      return saved;
    } finally {
      _isSaving = false;
      _safeNotify();
    }
  }

  /// Immediately persists any pending editor draft into `editor_drafts`
  /// (used on window shutdown / vault switch / entry switch).
  Future<void> flushDraftNow() async {
    _draftTimer?.cancel();
    final vault = vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    final text = textController.text;
    if (text.trim().isEmpty && _attachedBlobSha256s.isEmpty) {
      if (_hasUnsavedDraft) {
        await vault.raw.clearDraft(activeDraftKey);
        _hasUnsavedDraft = false;
      }
      return;
    }
    await vault.raw.saveDraft(
      EditorDraft(
        draftKey: activeDraftKey,
        bodyMd: text,
        entryKind: _entryKind,
        privacyLocked: _privacyLocked,
        imageBlobSha256s: _attachedBlobSha256s,
        updatedAtUtc: DateTime.now().toUtc(),
      ),
    );
    _hasUnsavedDraft = false;
  }

  void _onTextControllerChanged() {
    if (_suppressListener || _isDisposed) {
      return;
    }

    // SPK-02 Rule 1: while IME composition is active, NEVER mutate controller
    // value and defer autocomplete popup updates.
    if (textController.isComposing) {
      if (_activeTrigger != null || _candidates.isNotEmpty) {
        _activeTrigger = null;
        _candidates = const <AutocompleteCandidate>[];
        _safeNotify();
      }
      return;
    }

    _hasUnsavedDraft = true;
    _scheduleDraftSave();
    _schedulePreviewCompile();
    _updateAutocompleteTrigger();
  }

  void _scheduleDraftSave() {
    _draftTimer?.cancel();
    _draftTimer = Timer(draftDebounce, () {
      unawaited(flushDraftNow());
    });
  }

  void _schedulePreviewCompile() {
    _previewTimer?.cancel();
    final snapshot = textController.text;
    _previewTimer = Timer(previewDebounce, () {
      if (_isDisposed) {
        return;
      }
      _compilePreviewImmediate(snapshot);
      _safeNotify();
    });
  }

  void _compilePreviewImmediate(String bodyMd) {
    _parsedPreviewDoc = _bfm.parse(bodyMd);
    _compiledPreviewHtml = _bfm.toSemanticHtml(bodyMd);
  }

  void _updateAutocompleteTrigger() {
    final trigger = BlinkSyntaxTextController.detectAutocompleteTrigger(
      textController.value,
    );
    _activeTrigger = trigger;
    if (trigger == null) {
      if (_candidates.isNotEmpty) {
        _candidates = const <AutocompleteCandidate>[];
        _selectedCandidateIndex = 0;
        _safeNotify();
      }
      return;
    }
    final epoch = ++_candidateQueryEpoch;
    unawaited(_loadCandidatesForTrigger(trigger, epoch));
  }

  Future<void> _loadCandidatesForTrigger(
    AutocompleteTrigger trigger,
    int epoch,
  ) async {
    final nextCandidates = <AutocompleteCandidate>[];
    final queryLower = trigger.query.trim().toLowerCase();

    switch (trigger.kind) {
      case AutocompleteTriggerKind.slash:
        for (final item in _slashSnippets) {
          if (queryLower.isEmpty ||
              item.label.toLowerCase().contains(queryLower) ||
              item.subtitle.toLowerCase().contains(queryLower)) {
            nextCandidates.add(item);
          }
        }
      case AutocompleteTriggerKind.tag:
        if (queryLower.isEmpty || 'private'.contains(queryLower)) {
          nextCandidates.add(
            const AutocompleteCandidate(
              label: '#private',
              subtitle: '私密隔离 · 零云端出境',
              insertText: '#private ',
              isPrivate: true,
            ),
          );
        }
        final vault = vaultProvider();
        if (vault != null && vault.isOpen) {
          final tagCounts = await vault.raw.listTagCounts();
          final sortedTags = tagCounts.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          for (final entry in sortedTags) {
            if (queryLower.isEmpty ||
                entry.key.toLowerCase().contains(queryLower)) {
              nextCandidates.add(
                AutocompleteCandidate(
                  label: '#${entry.key}',
                  subtitle: '${entry.value} 条记录',
                  insertText: '#${entry.key} ',
                ),
              );
            }
            if (nextCandidates.length >= 8) {
              break;
            }
          }
        }
      case AutocompleteTriggerKind.wikiLink:
        final vault = vaultProvider();
        if (vault != null && vault.isOpen) {
          final trimmedQuery = trigger.query.trim();
          if (trimmedQuery.isNotEmpty) {
            final hits = await vault.search.search(
              trimmedQuery,
              scope: PrivacyScope.localWithPrivate,
              docKinds: const <String>['entry'],
              limit: 8,
            );
            for (final hit in hits) {
              final entry = await vault.raw.getEntryById(hit.docId);
              if (entry == null) {
                continue;
              }
              final title = _entrySummaryTitle(entry.bodyMd);
              nextCandidates.add(
                AutocompleteCandidate(
                  label: title,
                  subtitle: hit.snippet.replaceAll('\n', ' '),
                  insertText: '[[entry:${entry.id}|$title]]',
                  isPrivate: entry.isPrivate,
                ),
              );
            }
          } else {
            final recent = await vault.raw.listEntries(
              const EntryQuery(limit: 8),
            );
            for (final entry in recent) {
              if (entry.id == _editingEntryId) {
                continue;
              }
              final title = _entrySummaryTitle(entry.bodyMd);
              nextCandidates.add(
                AutocompleteCandidate(
                  label: title,
                  subtitle: entry.isPrivate ? '🔒 私密条目' : '最近记录',
                  insertText: '[[entry:${entry.id}|$title]]',
                  isPrivate: entry.isPrivate,
                ),
              );
            }
          }
        }
    }

    if (_isDisposed || epoch != _candidateQueryEpoch) {
      return;
    }
    _candidates = List<AutocompleteCandidate>.unmodifiable(nextCandidates);
    _selectedCandidateIndex = 0;
    _safeNotify();
  }

  static String _entrySummaryTitle(String bodyMd) {
    for (final rawLine in bodyMd.split('\n')) {
      final clean = rawLine.replaceFirst(RegExp(r'^#+\s*'), '').trim();
      if (clean.isNotEmpty) {
        return clean.length > 32 ? '${clean.substring(0, 32)}…' : clean;
      }
    }
    return '未命名记录';
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _draftTimer?.cancel();
    _previewTimer?.cancel();
    textController.removeListener(_onTextControllerChanged);
    textController.dispose();
    super.dispose();
  }
}
