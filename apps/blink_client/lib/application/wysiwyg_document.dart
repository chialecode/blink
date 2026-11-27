import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';

/// Structural block kinds supported by BLINK's Typora-style WYSIWYG editor.
enum WysiwygBlockType {
  heading,
  paragraph,
  bulletList,
  orderedList,
  taskItem,
  blockquote,
  callout,
  codeBlock,
  divider,
  table,
  fold,
  aiEmbed,
}

/// Immutable block node in [WysiwygDocument].
///
/// The canonical persisted format remains UTF-8 Markdown (`raw_entries.body_md`),
/// and [WysiwygDocument.parse] / [WysiwygDocument.serialize] round-trip blocks
/// without data loss.
@immutable
class WysiwygBlock {
  const WysiwygBlock({
    required this.id,
    required this.type,
    this.text = '',
    this.level = 1,
    this.orderNumber = 1,
    this.taskStatus,
    this.calloutKind,
    this.codeLanguage,
    this.listMarker = '-',
    this.indentPrefix = '',
    this.dividerMarker = '---',
    this.blankLinesBefore,
  });

  /// Stable local block identifier used for widget keys and `FocusNode` reuse.
  final String id;

  final WysiwygBlockType type;

  /// Block text content:
  /// - `heading` / `bulletList` / `orderedList` / `taskItem` / `blockquote`:
  ///   content with leading structural marker stripped.
  /// - `callout`: first line is the optional callout title; lines 2+ are the
  ///   callout body (with leading `> ` stripped).
  /// - `codeBlock`: raw code body without opening/closing fences.
  /// - `divider`: empty string (original `---`/`***` preserved in [dividerMarker]).
  /// - `table` / `fold` / `aiEmbed`: full raw Markdown lines.
  final String text;

  /// Heading level (`1..6`) for [WysiwygBlockType.heading].
  final int level;

  /// Display ordinal (`1`, `2`, ...) for [WysiwygBlockType.orderedList].
  final int orderNumber;

  /// Task status (`open`, `done`, `deferred`, `dropped`) for [WysiwygBlockType.taskItem].
  final TaskStatus? taskStatus;

  /// Callout semantic kind (`note`, `insight`, `warning`, `tip`, `danger`, ...).
  final String? calloutKind;

  /// Fenced code language identifier (e.g. `dart`, `python`, or `''`).
  final String? codeLanguage;

  /// Original list marker (`-` or `*`) preserved for lossless serialization.
  final String listMarker;

  /// Leading indentation preserved for nested list/task round-tripping.
  final String indentPrefix;

  /// Original divider marker (`---`, `***`, etc.) preserved for round-tripping.
  final String dividerMarker;

  /// Exact number of blank lines preceding this block in source Markdown.
  /// When `null`, [WysiwygDocument.serialize] chooses clean canonical spacing.
  final int? blankLinesBefore;

  /// Whether this block uses inline prose editing (vs raw/atomic block editing).
  bool get isTextMergeable =>
      type == WysiwygBlockType.paragraph ||
      type == WysiwygBlockType.heading ||
      type == WysiwygBlockType.bulletList ||
      type == WysiwygBlockType.orderedList ||
      type == WysiwygBlockType.taskItem ||
      type == WysiwygBlockType.blockquote;

  /// Whether this block is an editable list-like block that continues on Enter.
  bool get isListLike =>
      type == WysiwygBlockType.bulletList ||
      type == WysiwygBlockType.orderedList ||
      type == WysiwygBlockType.taskItem;

  /// Extracts the callout title (first line of [text]) for [WysiwygBlockType.callout].
  String get calloutTitle {
    if (type != WysiwygBlockType.callout) {
      return '';
    }
    final nl = text.indexOf('\n');
    return (nl < 0 ? text : text.substring(0, nl)).trim();
  }

  /// Extracts the callout body (lines after the first) for [WysiwygBlockType.callout].
  String get calloutBody {
    if (type != WysiwygBlockType.callout) {
      return '';
    }
    final nl = text.indexOf('\n');
    return nl < 0 ? '' : text.substring(nl + 1);
  }

  /// Extracts the `ai:<id>` identifier from an [WysiwygBlockType.aiEmbed] block.
  String get aiEmbedId {
    if (type != WysiwygBlockType.aiEmbed) {
      return '';
    }
    final match = WysiwygDocument._aiEmbedLineRe.firstMatch(text.trim());
    return match?.group(1)?.trim() ?? '';
  }

  /// Extracts the optional display label from an [WysiwygBlockType.aiEmbed] block.
  String get aiEmbedLabel {
    if (type != WysiwygBlockType.aiEmbed) {
      return '';
    }
    final match = WysiwygDocument._aiEmbedLineRe.firstMatch(text.trim());
    return match?.group(2)?.trim() ?? '';
  }

  WysiwygBlock copyWith({
    String? id,
    WysiwygBlockType? type,
    String? text,
    int? level,
    int? orderNumber,
    TaskStatus? taskStatus,
    bool clearTaskStatus = false,
    String? calloutKind,
    bool clearCalloutKind = false,
    String? codeLanguage,
    bool clearCodeLanguage = false,
    String? listMarker,
    String? indentPrefix,
    String? dividerMarker,
    int? blankLinesBefore,
    bool clearBlankLinesBefore = false,
  }) {
    return WysiwygBlock(
      id: id ?? this.id,
      type: type ?? this.type,
      text: text ?? this.text,
      level: level ?? this.level,
      orderNumber: orderNumber ?? this.orderNumber,
      taskStatus: clearTaskStatus ? null : (taskStatus ?? this.taskStatus),
      calloutKind: clearCalloutKind ? null : (calloutKind ?? this.calloutKind),
      codeLanguage: clearCodeLanguage
          ? null
          : (codeLanguage ?? this.codeLanguage),
      listMarker: listMarker ?? this.listMarker,
      indentPrefix: indentPrefix ?? this.indentPrefix,
      dividerMarker: dividerMarker ?? this.dividerMarker,
      blankLinesBefore: clearBlankLinesBefore
          ? null
          : (blankLinesBefore ?? this.blankLinesBefore),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WysiwygBlock &&
          id == other.id &&
          type == other.type &&
          text == other.text &&
          level == other.level &&
          orderNumber == other.orderNumber &&
          taskStatus == other.taskStatus &&
          calloutKind == other.calloutKind &&
          codeLanguage == other.codeLanguage &&
          listMarker == other.listMarker &&
          indentPrefix == other.indentPrefix &&
          dividerMarker == other.dividerMarker &&
          blankLinesBefore == other.blankLinesBefore;

  @override
  int get hashCode => Object.hash(
    id,
    type,
    text,
    level,
    orderNumber,
    taskStatus,
    calloutKind,
    codeLanguage,
    listMarker,
    indentPrefix,
    dividerMarker,
    blankLinesBefore,
  );
}

/// Pure Dart lossless Markdown <-> [WysiwygBlock] document model, prefix
/// shortcut detector, and note title/snippet extractors.
abstract final class WysiwygDocument {
  static int _idCounter = 0;

  /// Generates a unique local block ID for focus and widget identity.
  static String nextBlockId() => 'wb_${++_idCounter}';

  static final RegExp _headingRe = RegExp(r'^(#{1,6})[ \t]+(.*)$');
  static final RegExp _taskRe = RegExp(
    r'^([ \t]*)([-*])[ \t]+\[([ xX>\-])\](?:[ \t]+(.*)|[ \t]*)$',
  );
  static final RegExp _bulletRe = RegExp(r'^([ \t]*)([-*])[ \t]+(.*)$');
  static final RegExp _orderedRe = RegExp(r'^([ \t]*)(\d+)\.[ \t]+(.*)$');
  static final RegExp _calloutRe = RegExp(
    r'^[ \t]*>[ \t]*\[!([A-Za-z]+)\][ \t]*(.*)$',
  );
  static final RegExp _blockquoteRe = RegExp(r'^[ \t]*>[ \t]?(.*)$');
  static final RegExp _fenceOpenRe = RegExp(
    r'^[ \t]*```([A-Za-z0-9_+-]*)[ \t]*$',
  );
  static final RegExp _fenceCloseRe = RegExp(r'^[ \t]*```[ \t]*$');
  static final RegExp _dividerRe = RegExp(r'^[ \t]*(---+|\*\*\*+)[ \t]*$');
  static final RegExp _foldOpenRe = RegExp(r'^[ \t]*:::fold(?:[ \t]+(.*))?$');
  static final RegExp _foldCloseRe = RegExp(r'^[ \t]*:::[ \t]*$');
  static final RegExp _aiEmbedLineRe = RegExp(
    r'^[ \t]*!\[\[ai:([^\]|]+)(?:\|([^\]]*))?\]\][ \t]*$',
  );
  static final RegExp _tableSepRe = RegExp(
    r'^[ \t]*\|?(?:[ \t]*:?-{3,}:?[ \t]*\|)+[ \t]*:?-{3,}:?[ \t]*\|?[ \t]*$',
  );

  // Prefix shortcut patterns (live typing + Enter conversion).
  static final RegExp _shortcutHeadingRe = RegExp(r'^(#{1,6}) (.*)$');
  static final RegExp _shortcutTaskRe = RegExp(r'^[-*] \[([ xX>\-])\] (.*)$');
  static final RegExp _shortcutBulletRe = RegExp(r'^[-*] (.*)$');
  static final RegExp _shortcutOrderedRe = RegExp(r'^(\d+)\. (.*)$');
  static final RegExp _shortcutQuoteRe = RegExp(r'^> (.*)$');
  static final RegExp _shortcutTaskCheckboxOnlyRe = RegExp(
    r'^\[([ xX>\-])\] (.*)$',
  );
  static final RegExp _shortcutCalloutOnlyRe = RegExp(
    r'^\[!([A-Za-z]+)\] (.*)$',
  );

  /// Parses UTF-8 Markdown into a non-empty list of [WysiwygBlock]s.
  ///
  /// An empty or whitespace-only input produces a single empty `paragraph`
  /// block so the WYSIWYG canvas always has an editable target.
  static List<WysiwygBlock> parse(String markdown) {
    final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.isEmpty) {
      return <WysiwygBlock>[
        WysiwygBlock(id: nextBlockId(), type: WysiwygBlockType.paragraph),
      ];
    }

    final lines = normalized.split('\n');
    final blocks = <WysiwygBlock>[];
    var i = 0;
    var pendingBlankLines = 0;

    int? consumeBlankLines() {
      if (blocks.isEmpty) {
        pendingBlankLines = 0;
        return null;
      }
      final count = pendingBlankLines;
      pendingBlankLines = 0;
      return count;
    }

    while (i < lines.length) {
      final line = lines[i];
      if (line.trim().isEmpty) {
        pendingBlankLines++;
        i++;
        continue;
      }

      // 1. Fenced code block.
      final fenceMatch = _fenceOpenRe.firstMatch(line);
      if (fenceMatch != null) {
        final lang = fenceMatch.group(1) ?? '';
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !_fenceCloseRe.hasMatch(lines[i])) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) {
          i++;
        }
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.codeBlock,
            text: codeLines.join('\n'),
            codeLanguage: lang,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        continue;
      }

      // 2. :::fold ... ::: block.
      if (_foldOpenRe.hasMatch(line)) {
        final rawLines = <String>[line];
        i++;
        while (i < lines.length && !_foldCloseRe.hasMatch(lines[i])) {
          rawLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) {
          rawLines.add(lines[i]);
          i++;
        }
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.fold,
            text: rawLines.join('\n'),
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        continue;
      }

      // 3. > [!callout] block.
      final calloutMatch = _calloutRe.firstMatch(line);
      if (calloutMatch != null) {
        final kind = calloutMatch.group(1)!.toLowerCase();
        final title = (calloutMatch.group(2) ?? '').trim();
        final bodyLines = <String>[];
        i++;
        while (i < lines.length && _blockquoteRe.hasMatch(lines[i])) {
          if (_calloutRe.hasMatch(lines[i])) {
            break;
          }
          bodyLines.add(_blockquoteRe.firstMatch(lines[i])!.group(1)!);
          i++;
        }
        final combinedText = bodyLines.isEmpty
            ? title
            : '$title\n${bodyLines.join('\n')}';
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.callout,
            text: combinedText,
            calloutKind: kind,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        continue;
      }

      // 4. Plain blockquote (> ...).
      final quoteMatch = _blockquoteRe.firstMatch(line);
      if (quoteMatch != null) {
        final quoteLines = <String>[quoteMatch.group(1)!];
        i++;
        while (i < lines.length &&
            _blockquoteRe.hasMatch(lines[i]) &&
            !_calloutRe.hasMatch(lines[i])) {
          quoteLines.add(_blockquoteRe.firstMatch(lines[i])!.group(1)!);
          i++;
        }
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.blockquote,
            text: quoteLines.join('\n'),
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        continue;
      }

      // 5. Standalone ![[ai:...]] read-only embed slot.
      if (_aiEmbedLineRe.hasMatch(line)) {
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.aiEmbed,
            text: line.trim(),
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 6. Horizontal rule (--- or ***).
      final dividerMatch = _dividerRe.firstMatch(line);
      if (dividerMatch != null) {
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.divider,
            text: '',
            dividerMarker: dividerMatch.group(1)!,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 7. Heading (# .. ######).
      final headingMatch = _headingRe.firstMatch(line);
      if (headingMatch != null) {
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.heading,
            level: headingMatch.group(1)!.length,
            text: headingMatch.group(2)!,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 8. Task list item (- [ ] / - [x] / - [>] / - [-]).
      final taskMatch = _taskRe.firstMatch(line);
      if (taskMatch != null) {
        final status =
            TaskStatus.fromBfmMarker(taskMatch.group(3)!) ?? TaskStatus.open;
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.taskItem,
            indentPrefix: taskMatch.group(1)!,
            listMarker: taskMatch.group(2)!,
            taskStatus: status,
            text: taskMatch.group(4) ?? '',
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 9. Unordered bullet list item (- / *).
      final bulletMatch = _bulletRe.firstMatch(line);
      if (bulletMatch != null) {
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.bulletList,
            indentPrefix: bulletMatch.group(1)!,
            listMarker: bulletMatch.group(2)!,
            text: bulletMatch.group(3)!,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 10. Ordered list item (1. / 2. ...).
      final orderedMatch = _orderedRe.firstMatch(line);
      if (orderedMatch != null) {
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.orderedList,
            indentPrefix: orderedMatch.group(1)!,
            orderNumber: int.tryParse(orderedMatch.group(2)!) ?? 1,
            text: orderedMatch.group(3)!,
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        i++;
        continue;
      }

      // 11. GFM pipe table.
      if (line.contains('|') &&
          i + 1 < lines.length &&
          _tableSepRe.hasMatch(lines[i + 1])) {
        final rawLines = <String>[line, lines[i + 1]];
        i += 2;
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            lines[i].contains('|')) {
          rawLines.add(lines[i]);
          i++;
        }
        blocks.add(
          WysiwygBlock(
            id: nextBlockId(),
            type: WysiwygBlockType.table,
            text: rawLines.join('\n'),
            blankLinesBefore: consumeBlankLines(),
          ),
        );
        continue;
      }

      // 12. Paragraph (accumulate consecutive plain lines).
      final paraLines = <String>[line];
      final leadingBlanks = consumeBlankLines();
      i++;
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !_startsStructuredBlock(lines, i)) {
        paraLines.add(lines[i]);
        i++;
      }
      blocks.add(
        WysiwygBlock(
          id: nextBlockId(),
          type: WysiwygBlockType.paragraph,
          text: paraLines.join('\n'),
          blankLinesBefore: leadingBlanks,
        ),
      );
    }

    if (blocks.isEmpty) {
      return <WysiwygBlock>[
        WysiwygBlock(id: nextBlockId(), type: WysiwygBlockType.paragraph),
      ];
    }
    return blocks;
  }

  static bool _startsStructuredBlock(List<String> lines, int index) {
    final line = lines[index];
    if (_fenceOpenRe.hasMatch(line) ||
        _foldOpenRe.hasMatch(line) ||
        _calloutRe.hasMatch(line) ||
        _blockquoteRe.hasMatch(line) ||
        _aiEmbedLineRe.hasMatch(line) ||
        _dividerRe.hasMatch(line) ||
        _headingRe.hasMatch(line) ||
        _taskRe.hasMatch(line) ||
        _bulletRe.hasMatch(line) ||
        _orderedRe.hasMatch(line)) {
      return true;
    }
    if (line.contains('|') &&
        index + 1 < lines.length &&
        _tableSepRe.hasMatch(lines[index + 1])) {
      return true;
    }
    return false;
  }

  /// Losslessly reconstructs clean UTF-8 Markdown from [blocks].
  static String serialize(List<WysiwygBlock> blocks) {
    if (blocks.isEmpty) {
      return '';
    }
    if (blocks.length == 1 &&
        blocks.first.type == WysiwygBlockType.paragraph &&
        blocks.first.text.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (i > 0) {
        final prev = blocks[i - 1];
        final blankLines =
            block.blankLinesBefore ?? _defaultBlankLinesBetween(prev, block);
        buffer.write('\n' * (blankLines + 1));
      }
      buffer.write(_serializeBlock(block));
    }
    return buffer.toString();
  }

  static int _defaultBlankLinesBetween(WysiwygBlock prev, WysiwygBlock next) {
    if (prev.isListLike && next.isListLike && prev.type == next.type) {
      return 0;
    }
    return 1;
  }

  static String _serializeBlock(WysiwygBlock block) {
    switch (block.type) {
      case WysiwygBlockType.heading:
        final level = block.level.clamp(1, 6);
        final hashes = '#' * level;
        return '$hashes ${block.text}';
      case WysiwygBlockType.paragraph:
        return block.text;
      case WysiwygBlockType.bulletList:
        final marker = block.listMarker == '*' ? '*' : '-';
        return '${block.indentPrefix}$marker ${block.text}';
      case WysiwygBlockType.orderedList:
        final ordinal = block.orderNumber < 1 ? 1 : block.orderNumber;
        return '${block.indentPrefix}$ordinal. ${block.text}';
      case WysiwygBlockType.taskItem:
        final marker = block.listMarker == '*' ? '*' : '-';
        final statusMarker = (block.taskStatus ?? TaskStatus.open).bfmMarker;
        return '${block.indentPrefix}$marker [$statusMarker] ${block.text}';
      case WysiwygBlockType.blockquote:
        final lines = block.text.split('\n');
        return lines.map((line) => line.isEmpty ? '>' : '> $line').join('\n');
      case WysiwygBlockType.callout:
        final kind = (block.calloutKind == null || block.calloutKind!.isEmpty)
            ? 'note'
            : block.calloutKind!;
        final lines = block.text.split('\n');
        final title = lines.first.trim();
        final header = title.isEmpty ? '> [!$kind]' : '> [!$kind] $title';
        if (lines.length <= 1) {
          return header;
        }
        final rest = lines
            .skip(1)
            .map((line) => line.isEmpty ? '>' : '> $line')
            .join('\n');
        return '$header\n$rest';
      case WysiwygBlockType.codeBlock:
        final lang = (block.codeLanguage ?? '').trim();
        final body = block.text;
        return body.isEmpty ? '```$lang\n```' : '```$lang\n$body\n```';
      case WysiwygBlockType.divider:
        return block.dividerMarker.trim().isEmpty
            ? '---'
            : block.dividerMarker.trim();
      case WysiwygBlockType.table:
      case WysiwygBlockType.fold:
      case WysiwygBlockType.aiEmbed:
        return block.text;
    }
  }

  /// Detects Markdown prefix shortcuts for Typora-style live conversion.
  ///
  /// - `# `..`###### ` -> [WysiwygBlockType.heading] (`level: 1..6`)
  /// - `- [ ] ` / `- [x] ` / `- [X] ` / `- [>] ` / `- [-] ` -> [WysiwygBlockType.taskItem]
  /// - `- ` / `* ` -> [WysiwygBlockType.bulletList]
  /// - `<digits>. ` -> [WysiwygBlockType.orderedList]
  /// - `> ` -> [WysiwygBlockType.blockquote]
  /// - `---` / `***` -> [WysiwygBlockType.divider] (triggered on Enter in editor)
  /// - ```` ``` ```` / ```` ```<lang> ```` -> [WysiwygBlockType.codeBlock]
  ///   (triggered on Enter in editor; language returned in `remainingText`)
  static ({
    WysiwygBlockType type,
    int level,
    int orderNumber,
    TaskStatus? taskStatus,
    String remainingText,
  })?
  matchPrefixShortcut(String line) {
    final heading = _shortcutHeadingRe.firstMatch(line);
    if (heading != null) {
      return (
        type: WysiwygBlockType.heading,
        level: heading.group(1)!.length,
        orderNumber: 1,
        taskStatus: null,
        remainingText: heading.group(2)!,
      );
    }

    final task = _shortcutTaskRe.firstMatch(line);
    if (task != null) {
      return (
        type: WysiwygBlockType.taskItem,
        level: 1,
        orderNumber: 1,
        taskStatus: TaskStatus.fromBfmMarker(task.group(1)!) ?? TaskStatus.open,
        remainingText: task.group(2)!,
      );
    }

    final bullet = _shortcutBulletRe.firstMatch(line);
    if (bullet != null) {
      return (
        type: WysiwygBlockType.bulletList,
        level: 1,
        orderNumber: 1,
        taskStatus: null,
        remainingText: bullet.group(1)!,
      );
    }

    final ordered = _shortcutOrderedRe.firstMatch(line);
    if (ordered != null) {
      return (
        type: WysiwygBlockType.orderedList,
        level: 1,
        orderNumber: int.tryParse(ordered.group(1)!) ?? 1,
        taskStatus: null,
        remainingText: ordered.group(2)!,
      );
    }

    final quote = _shortcutQuoteRe.firstMatch(line);
    if (quote != null) {
      return (
        type: WysiwygBlockType.blockquote,
        level: 1,
        orderNumber: 1,
        taskStatus: null,
        remainingText: quote.group(1)!,
      );
    }

    if (_dividerRe.hasMatch(line)) {
      return (
        type: WysiwygBlockType.divider,
        level: 1,
        orderNumber: 1,
        taskStatus: null,
        remainingText: '',
      );
    }

    final fence = _fenceOpenRe.firstMatch(line);
    if (fence != null) {
      return (
        type: WysiwygBlockType.codeBlock,
        level: 1,
        orderNumber: 1,
        taskStatus: null,
        remainingText: (fence.group(1) ?? '').trim(),
      );
    }

    return null;
  }

  /// Detects `[ ] ` / `[x] ` / `[>] ` / `[-] ` typed inside an already-active
  /// bullet list item so typing `- [ ] ` character-by-character upgrades smoothly
  /// from `paragraph` -> `bulletList` -> `taskItem`.
  static ({TaskStatus status, String remainingText})? matchTaskCheckboxPrefix(
    String line,
  ) {
    final match = _shortcutTaskCheckboxOnlyRe.firstMatch(line);
    if (match == null) {
      return null;
    }
    return (
      status: TaskStatus.fromBfmMarker(match.group(1)!) ?? TaskStatus.open,
      remainingText: match.group(2)!,
    );
  }

  /// Detects `[!note] ` / `[!insight] ` / `[!warning] ` typed inside an active
  /// blockquote to upgrade it seamlessly into a callout block.
  static ({String kind, String remainingText})? matchCalloutPrefix(
    String line,
  ) {
    final match = _shortcutCalloutOnlyRe.firstMatch(line);
    if (match == null) {
      return null;
    }
    return (
      kind: match.group(1)!.toLowerCase(),
      remainingText: match.group(2)!,
    );
  }

  /// Extracts a clean human-readable title from [bodyMd], or `'无标题笔记'`
  /// when the document has no visible content.
  static String extractTitle(String bodyMd, {int maxLength = 60}) {
    final lines = bodyMd
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final found = _findFirstContentLine(lines);
    if (found == null) {
      return '无标题笔记';
    }
    final cleaned = found.cleaned;
    if (cleaned.length <= maxLength) {
      return cleaned;
    }
    return '${cleaned.substring(0, maxLength)}…';
  }

  /// Extracts a clean plain-text preview snippet from [bodyMd], skipping the
  /// title line extracted by [extractTitle].
  static String extractSnippet(String bodyMd, {int maxLength = 120}) {
    final lines = bodyMd
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final titleLine = _findFirstContentLine(lines);
    final startIdx = titleLine == null ? 0 : titleLine.lineIndex + 1;
    final parts = <String>[];
    var inFence = false;

    for (var i = startIdx; i < lines.length; i++) {
      final raw = lines[i];
      if (_fenceOpenRe.hasMatch(raw) || _fenceCloseRe.hasMatch(raw)) {
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        final trimmed = raw.trim();
        if (trimmed.isNotEmpty) {
          parts.add(trimmed);
        }
        continue;
      }
      if (raw.trim().isEmpty ||
          _dividerRe.hasMatch(raw) ||
          _foldCloseRe.hasMatch(raw) ||
          _tableSepRe.hasMatch(raw)) {
        continue;
      }
      final cleaned = _cleanLineToPlainText(raw);
      if (cleaned.isNotEmpty) {
        parts.add(cleaned);
      }
      if (parts.join(' ').length >= maxLength) {
        break;
      }
    }

    final joined = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (joined.isEmpty) {
      return '';
    }
    if (joined.length <= maxLength) {
      return joined;
    }
    return '${joined.substring(0, maxLength)}…';
  }

  static ({int lineIndex, String cleaned})? _findFirstContentLine(
    List<String> lines,
  ) {
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      if (raw.trim().isEmpty ||
          _dividerRe.hasMatch(raw) ||
          _fenceOpenRe.hasMatch(raw) ||
          _fenceCloseRe.hasMatch(raw) ||
          _foldCloseRe.hasMatch(raw) ||
          _tableSepRe.hasMatch(raw)) {
        continue;
      }
      final cleaned = _cleanLineToPlainText(raw);
      if (cleaned.isNotEmpty) {
        return (lineIndex: i, cleaned: cleaned);
      }
    }
    return null;
  }

  static String _cleanLineToPlainText(String rawLine) {
    var text = rawLine.trim();
    final foldMatch = _foldOpenRe.firstMatch(text);
    if (foldMatch != null) {
      text = (foldMatch.group(1) ?? '').trim();
    }
    final calloutMatch = _calloutRe.firstMatch(text);
    if (calloutMatch != null) {
      text = (calloutMatch.group(2) ?? '').trim();
    } else {
      text = text.replaceFirst(RegExp(r'^>[ \t]?'), '');
    }
    text = text.replaceFirst(RegExp(r'^#{1,6}[ \t]+'), '');
    text = text.replaceFirst(RegExp(r'^[-*][ \t]+\[[ xX>\-]\][ \t]*'), '');
    text = text.replaceFirst(RegExp(r'^(?:[-*+]|\d+\.)[ \t]+'), '');

    // Strip inline syntax markers while preserving human-readable labels.
    text = text.replaceAllMapped(
      RegExp(r'!\[\[ai:[^\]|]+(?:\|([^\]]*))?\]\]'),
      (m) => (m.group(1) ?? '').trim(),
    );
    text = text.replaceAllMapped(RegExp(r'\[\[([^\[\]\n]+)\]\]'), (m) {
      final inner = m.group(1)!;
      final pipe = inner.indexOf('|');
      return (pipe >= 0 ? inner.substring(pipe + 1) : inner).trim();
    });
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]\n]+)\]\([^\)\n]+\)'),
      (m) => m.group(1)!,
    );
    text = text.replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'==([^=\n]+)=='), (m) => m.group(1)!);
    text = text.replaceAllMapped(
      RegExp(r'\*\*([^*\n]+)\*\*'),
      (m) => m.group(1)!,
    );
    text = text.replaceAllMapped(RegExp(r'~~([^~\n]+)~~'), (m) => m.group(1)!);
    text = text.replaceAllMapped(
      RegExp(r'(?<!\*)\*([^*\n]+)\*(?!\*)'),
      (m) => m.group(1)!,
    );
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
