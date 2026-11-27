import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:meta/meta.dart';

import '../models/blink_models.dart';
import '../utils/uuid_v7.dart';

/// Parsed endogenous task line inside a BFM v1 document.
@immutable
final class BfmTaskItem {
  const BfmTaskItem({
    required this.lineIndex,
    required this.status,
    required this.title,
  });

  final int lineIndex;
  final TaskStatus status;
  final String title;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BfmTaskItem &&
          lineIndex == other.lineIndex &&
          status == other.status &&
          title == other.title;

  @override
  int get hashCode => Object.hash(lineIndex, status, title);
}

/// Parsed BFM v1 link, book context bind, or AI read-only embed pointer.
@immutable
final class BfmParsedLink {
  const BfmParsedLink({
    required this.targetKind,
    this.targetId,
    this.anchor,
    required this.label,
    required this.isContextBind,
  });

  final BfmLinkTargetKind targetKind;
  final String? targetId;
  final String? anchor;
  final String label;
  final bool isContextBind;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BfmParsedLink &&
          targetKind == other.targetKind &&
          targetId == other.targetId &&
          anchor == other.anchor &&
          label == other.label &&
          isContextBind == other.isContextBind;

  @override
  int get hashCode =>
      Object.hash(targetKind, targetId, anchor, label, isContextBind);
}

/// Parsed BFM v1 audio timestamp (`@t[mm:ss]` or `@t[hh:mm:ss]`).
@immutable
final class BfmTimestamp {
  const BfmTimestamp({required this.seconds, required this.displayText});

  final int seconds;
  final String displayText;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BfmTimestamp &&
          seconds == other.seconds &&
          displayText == other.displayText;

  @override
  int get hashCode => Object.hash(seconds, displayText);
}

/// Structured analysis result produced by [BfmEngine.parse].
@immutable
final class BfmDocument {
  BfmDocument({
    required this.rawMd,
    required List<String> tags,
    required this.hasPrivateToken,
    required List<BfmParsedLink> links,
    required List<BfmTaskItem> tasks,
    required List<BfmTimestamp> timestamps,
    required List<String> aiEmbedIds,
    this.sourceRefId,
    required this.isSimpleFastPath,
  }) : tags = List<String>.unmodifiable(tags),
       links = List<BfmParsedLink>.unmodifiable(links),
       tasks = List<BfmTaskItem>.unmodifiable(tasks),
       timestamps = List<BfmTimestamp>.unmodifiable(timestamps),
       aiEmbedIds = List<String>.unmodifiable(aiEmbedIds);

  final String rawMd;
  final List<String> tags;
  final bool hasPrivateToken;
  final List<BfmParsedLink> links;
  final List<BfmTaskItem> tasks;
  final List<BfmTimestamp> timestamps;
  final List<String> aiEmbedIds;
  final String? sourceRefId;
  final bool isSimpleFastPath;
}

/// Callback resolving a BFM link to a mirror-relative Markdown link target.
typedef MirrorLinkResolver = String Function(
  BfmParsedLink link,
  PrivacyLevel currentEntryPrivacy,
);

/// Pure Dart BFM v1 (BLINK Flavored Markdown) parser, plain-text extractor,
/// Surface 1 semantic HTML compiler, and 10-year GFM mirror exporter.
class BfmEngine {
  const BfmEngine();

  static const BlinkHtmlSanitizer _sanitizer = BlinkHtmlSanitizer();

  /// Parses all 9 BFM v1 primitives + CJK-friendly emphasis (`#650`).
  BfmDocument parse(String bodyMd) {
    final normalized = _normalizeLineEndings(bodyMd);
    final lines = normalized.split('\n');

    final tags = <String>[];
    final seenTags = <String>{};
    var hasPrivateToken = false;
    final links = <BfmParsedLink>[];
    final tasks = <BfmTaskItem>[];
    final timestamps = <BfmTimestamp>[];
    final aiEmbedIds = <String>[];
    String? sourceRefId;

    var hasComplexBlock = false;
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        hasComplexBlock = true;
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        continue;
      }
      if (inFence) {
        continue;
      }

      if (_calloutStartPattern.hasMatch(line) ||
          _foldStartPattern.hasMatch(line) ||
          _blockMathFencePattern.hasMatch(line) ||
          _singleLineBlockMathPattern.hasMatch(line) ||
          _footnoteDefPattern.hasMatch(line) ||
          _tableSeparatorPattern.hasMatch(line) ||
          _detailsTagPattern.hasMatch(line)) {
        hasComplexBlock = true;
      }

      final taskMatch = _taskLinePattern.firstMatch(line);
      if (taskMatch != null) {
        final marker = taskMatch.group(3)!;
        final status = TaskStatus.fromBfmMarker(marker);
        if (status != null) {
          tasks.add(
            BfmTaskItem(
              lineIndex: i,
              status: status,
              title: taskMatch.group(4)!.trim(),
            ),
          );
        }
      }

      final strippedLine = _maskInlineCodeAndUrls(line).masked;

      // 1. AI read-only embeds `![[ai:<uuid>|label]]`
      final withoutEmbeds = strippedLine.replaceAllMapped(_aiEmbedPattern, (m) {
        hasComplexBlock = true;
        final id = m.group(1)!;
        final label = (m.group(2) ?? '').trim();
        aiEmbedIds.add(id);
        links.add(
          BfmParsedLink(
            targetKind: BfmLinkTargetKind.ai,
            targetId: id,
            label: label.isEmpty ? 'AI 派生视图' : label,
            isContextBind: false,
          ),
        );
        return ' ';
      });

      // 2. Wiki links `[[...]]`
      final withoutLinks = withoutEmbeds.replaceAllMapped(_wikiLinkPattern, (
        m,
      ) {
        final parsed = _parseWikiLinkInner(m.group(1)!);
        if (parsed != null) {
          links.add(parsed);
        }
        return ' ';
      });

      // 3. `@book:<uuid>(#anchor)?(|label)?`
      final withoutBooks = withoutLinks.replaceAllMapped(_bookBindPattern, (m) {
        final id = m.group(1)!;
        final anchor = m.group(2);
        final rawLabel = m.group(3)?.trim();
        final label = (rawLabel == null || rawLabel.isEmpty) ? id : rawLabel;
        sourceRefId ??= id;
        links.add(
          BfmParsedLink(
            targetKind: BfmLinkTargetKind.source,
            targetId: id,
            anchor: anchor,
            label: label,
            isContextBind: true,
          ),
        );
        return ' ';
      });

      // 4. `@t[mm:ss]` / `@t[hh:mm:ss]`
      final withoutTimes = withoutBooks.replaceAllMapped(_timestampPattern, (
        m,
      ) {
        final ts = _parseTimestamp(m.group(1)!);
        if (ts != null) {
          timestamps.add(ts);
        }
        return ' ';
      });

      // 5. `#private` & `#tags` (skip markdown heading prefix `# Heading`)
      final tagScanLine = withoutTimes.replaceFirst(_headingPrefixPattern, '');
      for (final match in _hashTokenPattern.allMatches(tagScanLine)) {
        final rawTag = match.group(1)!;
        if (_isHexColorToken(rawTag)) {
          continue;
        }
        if (rawTag.toLowerCase() == 'private') {
          hasPrivateToken = true;
          continue;
        }
        final normalizedTag = rawTag.toLowerCase();
        if (_isValidTagPath(normalizedTag) && seenTags.add(normalizedTag)) {
          tags.add(normalizedTag);
        }
      }
    }

    return BfmDocument(
      rawMd: bodyMd,
      tags: tags,
      hasPrivateToken: hasPrivateToken,
      links: links,
      tasks: tasks,
      timestamps: timestamps,
      aiEmbedIds: aiEmbedIds,
      sourceRefId: sourceRefId,
      isSimpleFastPath: !hasComplexBlock,
    );
  }

  /// Removes standalone `#private` tag tokens outside fenced code blocks,
  /// inline code spans, URLs, wiki links, AI embeds, and context binds while
  /// preserving all other Markdown syntax and original line endings.
  String stripPrivateTokens(String bodyMd) {
    if (bodyMd.isEmpty) {
      return bodyMd;
    }
    final usesCrlf = bodyMd.contains('\r\n');
    final separator = usesCrlf ? '\r\n' : '\n';
    final lines = _normalizeLineEndings(bodyMd).split('\n');

    final processed = <({String text, bool droppedPrivateOnly})>[];
    var changed = false;
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    for (final line in lines) {
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        processed.add((text: line, droppedPrivateOnly: false));
        continue;
      }
      if (inFence) {
        processed.add((text: line, droppedPrivateOnly: false));
        continue;
      }

      final stripped = _stripPrivateTokensFromLine(line);
      if (stripped.changed) {
        changed = true;
      }
      processed.add((
        text: stripped.text,
        droppedPrivateOnly: stripped.wasPrivateOnlyLine,
      ));
    }

    if (!changed) {
      return bodyMd;
    }

    final outLines = <String>[];
    var prevWasDropped = false;
    for (var i = 0; i < processed.length; i++) {
      final item = processed[i];
      if (item.droppedPrivateOnly) {
        if (outLines.isNotEmpty &&
            outLines.last.trim().isEmpty &&
            i + 1 < processed.length &&
            processed[i + 1].text.trim().isEmpty &&
            !processed[i + 1].droppedPrivateOnly) {
          outLines.removeLast();
        }
        prevWasDropped = true;
        continue;
      }
      if (prevWasDropped && outLines.isEmpty && item.text.trim().isEmpty) {
        prevWasDropped = false;
        continue;
      }
      prevWasDropped = false;
      outLines.add(item.text);
    }

    if (prevWasDropped) {
      while (outLines.isNotEmpty && outLines.last.trim().isEmpty) {
        outLines.removeLast();
      }
    }

    return outLines.join(separator);
  }

  ({String text, bool changed, bool wasPrivateOnlyLine})
  _stripPrivateTokensFromLine(String line) {
    final codeMask = _maskInlineCodeSpans(line);
    final urlMask = _maskUrls(codeMask.masked);
    final protectedTokens = <String, String>{};
    var protectedIdx = 0;

    String maskProtected(String raw) {
      final key = '\uE014PROT${protectedIdx++}\uE015';
      protectedTokens[key] = raw;
      return key;
    }

    var text = urlMask.masked;
    text = text.replaceAllMapped(
      _aiEmbedPattern,
      (m) => maskProtected(m.group(0)!),
    );
    text = text.replaceAllMapped(
      _wikiLinkPattern,
      (m) => maskProtected(m.group(0)!),
    );
    text = text.replaceAllMapped(
      _bookBindPattern,
      (m) => maskProtected(m.group(0)!),
    );
    text = text.replaceAllMapped(
      _timestampPattern,
      (m) => maskProtected(m.group(0)!),
    );

    final headingMatch = _headingPrefixPattern.firstMatch(text);
    final headingPrefix = headingMatch?.group(0) ?? '';
    var body = headingMatch != null
        ? text.substring(headingPrefix.length)
        : text;

    var strippedAny = false;
    while (true) {
      final matches = _hashTokenPattern
          .allMatches(body)
          .where((m) => m.group(1)!.toLowerCase() == 'private')
          .toList(growable: false);
      if (matches.isEmpty) {
        break;
      }
      strippedAny = true;
      for (final m in matches.reversed) {
        final before = body.substring(0, m.start);
        final after = body.substring(m.end);
        final beforeEndsWs =
            before.isNotEmpty &&
            (before.endsWith(' ') || before.endsWith('\t'));
        final afterStartsWs =
            after.isNotEmpty &&
            (after.startsWith(' ') || after.startsWith('\t'));

        if (before.trim().isEmpty) {
          body = '$before${after.replaceFirst(RegExp(r'^[ \t]+'), '')}';
        } else if (after.trim().isEmpty) {
          body =
              '${before.replaceFirst(RegExp(r'[ \t]+$'), '')}${after.replaceFirst(RegExp(r'^[ \t]+'), '')}';
        } else if (beforeEndsWs && afterStartsWs) {
          body =
              '${before.replaceFirst(RegExp(r'[ \t]+$'), '')} ${after.replaceFirst(RegExp(r'^[ \t]+'), '')}';
        } else {
          body = '$before$after';
        }
      }
    }
    if (!strippedAny) {
      return (text: line, changed: false, wasPrivateOnlyLine: false);
    }

    var restored = '$headingPrefix$body';
    for (final entry in protectedTokens.entries) {
      restored = restored.replaceAll(entry.key, entry.value);
    }
    restored = urlMask.restore(restored);
    restored = codeMask.restore(restored);

    final wasPrivateOnly = headingPrefix.isEmpty && restored.trim().isEmpty;
    if (wasPrivateOnly) {
      return (text: '', changed: true, wasPrivateOnlyLine: true);
    }
    return (text: restored, changed: true, wasPrivateOnlyLine: false);
  }

  /// Extracts FTS5 plain text: strips UUIDs, `#private`, `@t[...]`, `![[ai:...]]`
  /// (`INV-01` / `INV-09`), and Markdown/BFM syntax markers.
  String toPlainText(String bodyMd) {
    final normalized = _normalizeLineEndings(bodyMd);
    final lines = normalized.split('\n');
    final bodyOut = <String>[];
    final footnotesOut = <String>[];

    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;
    var inBlockMath = false;

    for (final rawLine in lines) {
      final fenceMatch = _fencePattern.firstMatch(rawLine);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            rawLine.trim().length == marker.length) {
          inFence = false;
        }
        continue;
      }
      if (inFence) {
        if (rawLine.trim().isNotEmpty) {
          bodyOut.add(rawLine.trim());
        }
        continue;
      }

      if (_blockMathFencePattern.hasMatch(rawLine)) {
        inBlockMath = !inBlockMath;
        continue;
      }
      if (inBlockMath) {
        if (rawLine.trim().isNotEmpty) {
          bodyOut.add(rawLine.trim());
        }
        continue;
      }

      final singleMath = _singleLineBlockMathPattern.firstMatch(rawLine);
      if (singleMath != null) {
        final expr = singleMath.group(1)!.trim();
        if (expr.isNotEmpty) {
          bodyOut.add(expr);
        }
        continue;
      }

      final foldStart = _foldStartPattern.firstMatch(rawLine);
      if (foldStart != null) {
        final title = (foldStart.group(1) ?? '').trim();
        if (title.isNotEmpty) {
          bodyOut.add(_stripInlineToPlainText(title));
        }
        continue;
      }
      if (_foldEndPattern.hasMatch(rawLine)) {
        continue;
      }

      final calloutStart = _calloutStartPattern.firstMatch(rawLine);
      if (calloutStart != null) {
        final title = (calloutStart.group(3) ?? '').trim();
        if (title.isNotEmpty) {
          bodyOut.add(_stripInlineToPlainText(title));
        }
        continue;
      }

      final fnDef = _footnoteDefPattern.firstMatch(rawLine);
      if (fnDef != null) {
        final fnText = _stripInlineToPlainText(fnDef.group(2)!);
        if (fnText.isNotEmpty) {
          footnotesOut.add(fnText);
        }
        continue;
      }

      var line = rawLine;
      // Strip blockquote prefix.
      line = line.replaceFirst(RegExp(r'^[ \t]*>[ \t]?'), '');
      // Strip heading hashes.
      line = line.replaceFirst(_headingPrefixPattern, '');
      // Strip task prefix.
      final taskMatch = _taskLinePattern.firstMatch(line);
      if (taskMatch != null) {
        line = taskMatch.group(4)!;
      } else {
        // Strip unordered/ordered list marker.
        line = line.replaceFirst(RegExp(r'^[ \t]*(?:[-*+]|\d+\.)[ \t]+'), '');
      }
      // Skip table separator rows.
      if (_tableSeparatorPattern.hasMatch(line)) {
        continue;
      }
      // Strip raw <details>/<summary> tags.
      line = line.replaceAll(
        RegExp(r'</?(?:details|summary)(?:\s+open)?>', caseSensitive: false),
        ' ',
      );

      final plain = _stripInlineToPlainText(line);
      if (plain.isNotEmpty) {
        bodyOut.add(plain);
      }
    }

    final combined = <String>[...bodyOut, ...footnotesOut];
    return combined.join('\n').replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }

  /// Compiles BFM v1 to sanitized Surface 1 semantic HTML using locked `<blink-*>` tags
  /// (`HtmlProducer.userBfm`), redacting links targeting [privateTargetIds] under
  /// [PrivacyScope.normalOnly] (`INV-03`, `INV-13`).
  String toSemanticHtml(
    String bodyMd, {
    PrivacyScope viewerScope = PrivacyScope.localWithPrivate,
    Set<String> privateTargetIds = const <String>{},
  }) {
    final normalized = _normalizeLineEndings(bodyMd);
    final rawHtml = _compileDocumentToRawHtml(
      normalized,
      viewerScope: viewerScope,
      privateTargetIds: privateTargetIds,
    );
    final sanitized = _sanitizer.sanitize(
      rawHtml,
      options: SanitizeOptions(
        profile: SanitizeProfile.surface1Native,
        producer: HtmlProducer.userBfm,
        privacyScope: viewerScope,
      ),
    );
    return sanitized.html;
  }

  /// Convenience alias for [toSemanticHtml].
  String compileToHtml(
    String bodyMd, {
    PrivacyScope viewerScope = PrivacyScope.localWithPrivate,
    Set<String> privateTargetIds = const <String>{},
  }) => toSemanticHtml(
    bodyMd,
    viewerScope: viewerScope,
    privateTargetIds: privateTargetIds,
  );

  /// Redacts cross-privacy BFM references (`[[entry:<privateId>...]]`, `@book:<privateId>...`,
  /// `![[ai:<privateId>...]]`) inside raw Markdown before returning a `normal` entry to a
  /// `normal_only` external AI reader (`INV-03`).
  String redactPrivateReferences(
    String bodyMd, {
    required Set<String> privateTargetIds,
  }) {
    if (privateTargetIds.isEmpty) {
      return bodyMd;
    }
    final lines = _normalizeLineEndings(bodyMd).split('\n');
    final out = <String>[];
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    for (final line in lines) {
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        out.add(line);
        continue;
      }
      if (inFence) {
        out.add(line);
        continue;
      }

      final masked = _maskInlineCodeSpans(line);
      var text = masked.masked;
      text = text.replaceAllMapped(_aiEmbedPattern, (m) {
        final id = m.group(1)!;
        if (privateTargetIds.contains(id)) {
          return '[private-ref]';
        }
        return m.group(0)!;
      });
      text = text.replaceAllMapped(_wikiLinkPattern, (m) {
        final parsed = _parseWikiLinkInner(m.group(1)!);
        if (parsed != null &&
            parsed.targetId != null &&
            privateTargetIds.contains(parsed.targetId)) {
          return '[private-ref]';
        }
        return m.group(0)!;
      });
      text = text.replaceAllMapped(_bookBindPattern, (m) {
        final id = m.group(1)!;
        if (privateTargetIds.contains(id)) {
          return '[private-ref]';
        }
        return m.group(0)!;
      });
      out.add(masked.restore(text));
    }
    return out.join('\n');
  }

  /// Compiles BFM v1 to 10-year readable standard GFM per `docs/design/data-and-sync.md` §5.3.
  String toMirrorMarkdown(
    String bodyMd, {
    required MirrorLinkResolver linkResolver,
    required PrivacyLevel entryPrivacy,
    Set<String> privateTargetIds = const <String>{},
  }) {
    final lines = _normalizeLineEndings(bodyMd).split('\n');
    final out = <String>[];
    var i = 0;
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    while (i < lines.length) {
      final line = lines[i];
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        out.add(line);
        i += 1;
        continue;
      }
      if (inFence) {
        out.add(line);
        i += 1;
        continue;
      }

      // Fold block -> standard `<details><summary>...</summary>`.
      final foldStart = _foldStartPattern.firstMatch(line);
      if (foldStart != null) {
        final title = (foldStart.group(1) ?? '').trim();
        final summary = title.isEmpty ? '折叠内容' : title;
        final inner = <String>[];
        i += 1;
        while (i < lines.length && !_foldEndPattern.hasMatch(lines[i])) {
          inner.add(lines[i]);
          i += 1;
        }
        if (i < lines.length && _foldEndPattern.hasMatch(lines[i])) {
          i += 1;
        }
        final innerMirror = toMirrorMarkdown(
          inner.join('\n'),
          linkResolver: linkResolver,
          entryPrivacy: entryPrivacy,
          privateTargetIds: privateTargetIds,
        );
        out.add('<details><summary>${_escapeHtml(summary)}</summary>');
        if (innerMirror.isNotEmpty) {
          out.add('');
          out.add(innerMirror);
          out.add('');
        }
        out.add('</details>');
        continue;
      }

      // Callout -> standard Markdown blockquote header.
      final calloutStart = _calloutStartPattern.firstMatch(line);
      if (calloutStart != null) {
        final kind = calloutStart.group(1)!.toLowerCase();
        final rawTitle = (calloutStart.group(3) ?? '').trim();
        final prefix = _calloutMirrorLabel(kind);
        final header = rawTitle.isEmpty ? prefix : '$prefix · $rawTitle';
        out.add('> **$header**');
        i += 1;
        while (i < lines.length && _blockquoteLinePattern.hasMatch(lines[i])) {
          final innerLine = _blockquoteLinePattern
              .firstMatch(lines[i])!
              .group(1)!;
          final converted = _convertInlineForMirror(
            innerLine,
            linkResolver: linkResolver,
            entryPrivacy: entryPrivacy,
            privateTargetIds: privateTargetIds,
          );
          out.add('> $converted');
          i += 1;
        }
        continue;
      }

      // Endogenous task checkbox downgrade (`[>]` and `[-]`).
      final taskMatch = _taskLinePattern.firstMatch(line);
      if (taskMatch != null) {
        final indent = taskMatch.group(1)!;
        final bullet = taskMatch.group(2)!;
        final marker = taskMatch.group(3)!;
        final title = _convertInlineForMirror(
          taskMatch.group(4)!,
          linkResolver: linkResolver,
          entryPrivacy: entryPrivacy,
          privateTargetIds: privateTargetIds,
        );
        if (marker == '>') {
          out.add('$indent$bullet [ ] [顺延] $title');
        } else if (marker == '-') {
          out.add('$indent$bullet [x] ~~[放弃]~~ $title');
        } else {
          out.add('$indent$bullet [$marker] $title');
        }
        i += 1;
        continue;
      }

      out.add(
        _convertInlineForMirror(
          line,
          linkResolver: linkResolver,
          entryPrivacy: entryPrivacy,
          privateTargetIds: privateTargetIds,
        ),
      );
      i += 1;
    }

    return out.join('\n');
  }

  /// Updates a single endogenous task checkbox (`lineIndex`) in [bodyMd] without
  /// altering any other byte.
  String toggleTaskLine(
    String bodyMd, {
    required int lineIndex,
    required TaskStatus newStatus,
  }) {
    final usesCrlf = bodyMd.contains('\r\n');
    final separator = usesCrlf ? '\r\n' : '\n';
    final lines = bodyMd.split(separator);
    if (lineIndex < 0 || lineIndex >= lines.length) {
      throw RangeError.range(lineIndex, 0, lines.length - 1, 'lineIndex');
    }
    final line = lines[lineIndex];
    final match = _taskLinePattern.firstMatch(line);
    if (match == null) {
      throw ArgumentError.value(
        lineIndex,
        'lineIndex',
        'Line $lineIndex is not a BFM v1 task item',
      );
    }
    final indent = match.group(1)!;
    final bullet = match.group(2)!;
    final title = match.group(4)!;
    // Preserve exact spacing between bullet and `[` and between `]` and title.
    final bracketStart = line.indexOf('[', indent.length + bullet.length);
    if (bracketStart < 0 || bracketStart + 2 >= line.length) {
      lines[lineIndex] = '$indent$bullet [${newStatus.bfmMarker}] $title';
    } else {
      lines[lineIndex] =
          '${line.substring(0, bracketStart + 1)}'
          '${newStatus.bfmMarker}'
          '${line.substring(bracketStart + 2)}';
    }
    return lines.join(separator);
  }

  String _compileDocumentToRawHtml(
    String normalized, {
    required PrivacyScope viewerScope,
    required Set<String> privateTargetIds,
    bool collectFootnotes = true,
  }) {
    final lines = normalized.split('\n');
    final footnoteDefs = <String, String>{};
    final footnoteOrder = <String>[];
    final bodyLines = <String>[];

    // Pass 1: extract top-level footnote definitions outside fenced code blocks.
    if (collectFootnotes) {
      var inFence = false;
      var fenceChar = '';
      var fenceLen = 0;
      for (final line in lines) {
        final fenceMatch = _fencePattern.firstMatch(line);
        if (fenceMatch != null) {
          final marker = fenceMatch.group(1)!;
          if (!inFence) {
            inFence = true;
            fenceChar = marker[0];
            fenceLen = marker.length;
          } else if (marker[0] == fenceChar &&
              marker.length >= fenceLen &&
              line.trim().length == marker.length) {
            inFence = false;
          }
          bodyLines.add(line);
          continue;
        }
        if (!inFence) {
          final fnDef = _footnoteDefPattern.firstMatch(line);
          if (fnDef != null) {
            final id = fnDef.group(1)!;
            final content = fnDef.group(2)!.trim();
            if (!footnoteDefs.containsKey(id)) {
              footnoteOrder.add(id);
            }
            footnoteDefs[id] = content;
            continue;
          }
        }
        bodyLines.add(line);
      }
    } else {
      bodyLines.addAll(lines);
    }

    final fnNumbers = <String, int>{};
    for (var idx = 0; idx < footnoteOrder.length; idx++) {
      fnNumbers[footnoteOrder[idx]] = idx + 1;
    }

    // Pass 2: segment into standard Markdown chunks vs custom BFM blocks
    // (callout, fold, block math, task lists).
    final htmlChunks = <String>[];
    final mdBuffer = <String>[];

    void flushMdBuffer() {
      if (mdBuffer.isEmpty) {
        return;
      }
      final chunk = mdBuffer.join('\n');
      mdBuffer.clear();
      if (chunk.trim().isEmpty) {
        return;
      }
      htmlChunks.add(
        _compileMarkdownChunk(
          chunk,
          viewerScope: viewerScope,
          privateTargetIds: privateTargetIds,
          footnoteNumbers: fnNumbers,
        ),
      );
    }

    var i = 0;
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    while (i < bodyLines.length) {
      final line = bodyLines[i];
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        mdBuffer.add(line);
        i += 1;
        continue;
      }
      if (inFence) {
        mdBuffer.add(line);
        i += 1;
        continue;
      }

      // Block math `$$ ... $$`
      if (_blockMathFencePattern.hasMatch(line)) {
        flushMdBuffer();
        final mathLines = <String>[];
        i += 1;
        while (i < bodyLines.length &&
            !_blockMathFencePattern.hasMatch(bodyLines[i])) {
          mathLines.add(bodyLines[i]);
          i += 1;
        }
        if (i < bodyLines.length &&
            _blockMathFencePattern.hasMatch(bodyLines[i])) {
          i += 1;
        }
        htmlChunks.add(
          '<blink-math display="block">${_escapeHtml(mathLines.join('\n').trim())}</blink-math>',
        );
        continue;
      }

      final singleBlockMath = _singleLineBlockMathPattern.firstMatch(line);
      if (singleBlockMath != null) {
        flushMdBuffer();
        htmlChunks.add(
          '<blink-math display="block">${_escapeHtml(singleBlockMath.group(1)!.trim())}</blink-math>',
        );
        i += 1;
        continue;
      }

      // Fold block `:::fold Title ... :::`
      final foldStart = _foldStartPattern.firstMatch(line);
      if (foldStart != null) {
        flushMdBuffer();
        final rawTitle = (foldStart.group(1) ?? '').trim();
        final summary = rawTitle.isEmpty ? '折叠内容' : rawTitle;
        final inner = <String>[];
        i += 1;
        while (i < bodyLines.length &&
            !_foldEndPattern.hasMatch(bodyLines[i])) {
          inner.add(bodyLines[i]);
          i += 1;
        }
        if (i < bodyLines.length && _foldEndPattern.hasMatch(bodyLines[i])) {
          i += 1;
        }
        final innerHtml = _compileDocumentToRawHtml(
          inner.join('\n'),
          viewerScope: viewerScope,
          privateTargetIds: privateTargetIds,
          collectFootnotes: false,
        );
        htmlChunks.add(
          '<details><summary>${_escapeHtml(summary)}</summary>$innerHtml</details>',
        );
        continue;
      }

      // Callout block `> [!type](-|+)? Title`
      final calloutStart = _calloutStartPattern.firstMatch(line);
      if (calloutStart != null) {
        flushMdBuffer();
        final kind = calloutStart.group(1)!.toLowerCase();
        final foldFlag = calloutStart.group(2);
        final rawTitle = (calloutStart.group(3) ?? '').trim();
        final title = rawTitle.isEmpty ? _calloutDefaultTitle(kind) : rawTitle;
        final inner = <String>[];
        i += 1;
        while (i < bodyLines.length &&
            _blockquoteLinePattern.hasMatch(bodyLines[i])) {
          inner.add(_blockquoteLinePattern.firstMatch(bodyLines[i])!.group(1)!);
          i += 1;
        }
        final innerHtml = _compileDocumentToRawHtml(
          inner.join('\n'),
          viewerScope: viewerScope,
          privateTargetIds: privateTargetIds,
          collectFootnotes: false,
        );
        if (foldFlag == '-' || foldFlag == '+') {
          final openAttr = foldFlag == '+' ? ' open' : '';
          htmlChunks.add(
            '<details class="callout callout-$kind"$openAttr>'
            '<summary>${_escapeHtml(title)}</summary>$innerHtml</details>',
          );
        } else {
          htmlChunks.add(
            '<aside class="callout callout-$kind">'
            '<p class="callout-title">${_escapeHtml(title)}</p>$innerHtml</aside>',
          );
        }
        continue;
      }

      // Endogenous task list group
      if (_taskLinePattern.hasMatch(line)) {
        flushMdBuffer();
        final items = StringBuffer('<ul class="task-list">');
        while (i < bodyLines.length &&
            _taskLinePattern.hasMatch(bodyLines[i])) {
          final m = _taskLinePattern.firstMatch(bodyLines[i])!;
          final status =
              TaskStatus.fromBfmMarker(m.group(3)!) ?? TaskStatus.open;
          final itemHtml = _compileInlineFragment(
            m.group(4)!.trim(),
            viewerScope: viewerScope,
            privateTargetIds: privateTargetIds,
            footnoteNumbers: fnNumbers,
          );
          items.write(
            '<li class="task-item" data-task-status="${status.wireValue}">$itemHtml</li>',
          );
          i += 1;
        }
        items.write('</ul>');
        htmlChunks.add(items.toString());
        continue;
      }

      mdBuffer.add(line);
      i += 1;
    }

    flushMdBuffer();

    if (collectFootnotes && footnoteOrder.isNotEmpty) {
      final fnBuf = StringBuffer('<section class="footnotes"><ol>');
      for (final id in footnoteOrder) {
        final safeId = _sanitizeFootnoteId(id);
        final contentHtml = _compileInlineFragment(
          footnoteDefs[id] ?? '',
          viewerScope: viewerScope,
          privateTargetIds: privateTargetIds,
          footnoteNumbers: fnNumbers,
        );
        fnBuf.write('<li id="fn-$safeId">$contentHtml</li>');
      }
      fnBuf.write('</ol></section>');
      htmlChunks.add(fnBuf.toString());
    }

    return htmlChunks.join('\n');
  }

  String _compileMarkdownChunk(
    String chunk, {
    required PrivacyScope viewerScope,
    required Set<String> privateTargetIds,
    required Map<String, int> footnoteNumbers,
  }) {
    final placeholders = <String, String>{};
    var nextId = 0;

    String registerPlaceholder(String html) {
      final token = '\uE020PH${nextId++}\uE021';
      placeholders[token] = html;
      return token;
    }

    final lines = chunk.split('\n');
    final processedLines = <String>[];
    var inFence = false;
    var fenceChar = '';
    var fenceLen = 0;

    for (final line in lines) {
      final fenceMatch = _fencePattern.firstMatch(line);
      if (fenceMatch != null) {
        final marker = fenceMatch.group(1)!;
        if (!inFence) {
          inFence = true;
          fenceChar = marker[0];
          fenceLen = marker.length;
        } else if (marker[0] == fenceChar &&
            marker.length >= fenceLen &&
            line.trim().length == marker.length) {
          inFence = false;
        }
        processedLines.add(line);
        continue;
      }
      if (inFence) {
        processedLines.add(line);
        continue;
      }

      processedLines.add(
        _preprocessInlineLine(
          line,
          viewerScope: viewerScope,
          privateTargetIds: privateTargetIds,
          footnoteNumbers: footnoteNumbers,
          registerPlaceholder: registerPlaceholder,
        ),
      );
    }

    final compiled = md.markdownToHtml(
      processedLines.join('\n'),
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: false,
    );

    var restored = compiled;
    // Restore placeholders (reverse order handles nested placeholders if any).
    for (final entry in placeholders.entries.toList().reversed) {
      restored = restored.replaceAll(entry.key, entry.value);
    }
    return restored.trim();
  }

  String _compileInlineFragment(
    String text, {
    required PrivacyScope viewerScope,
    required Set<String> privateTargetIds,
    required Map<String, int> footnoteNumbers,
  }) {
    final html = _compileMarkdownChunk(
      text,
      viewerScope: viewerScope,
      privateTargetIds: privateTargetIds,
      footnoteNumbers: footnoteNumbers,
    );
    if (html.startsWith('<p>') &&
        html.endsWith('</p>') &&
        html.indexOf('<p>', 3) < 0) {
      return html.substring(3, html.length - 4);
    }
    return html;
  }

  String _preprocessInlineLine(
    String line, {
    required PrivacyScope viewerScope,
    required Set<String> privateTargetIds,
    required Map<String, int> footnoteNumbers,
    required String Function(String html) registerPlaceholder,
  }) {
    final codeMask = _maskInlineCodeSpans(line);
    var text = codeMask.masked;

    // Protect allowed `<details>`, `<details open>`, `</details>`, `<summary>`, `</summary>`.
    text = text.replaceAllMapped(_allowedRawDetailsPattern, (m) {
      return registerPlaceholder(m.group(0)!.toLowerCase());
    });

    // Escape all remaining raw HTML tags and HTML comments as opaque placeholders
    // so package:markdown cannot decode `&lt;` entities back into live HTML tags.
    text = text.replaceAllMapped(_htmlCommentPattern, (m) {
      return registerPlaceholder(_escapeHtml(m.group(0)!));
    });
    text = text.replaceAllMapped(_rawHtmlTagPattern, (m) {
      return registerPlaceholder(_escapeHtml(m.group(0)!));
    });

    // 1. AI embed `![[ai:<uuid>|label]]`
    text = text.replaceAllMapped(_aiEmbedPattern, (m) {
      final id = m.group(1)!;
      final label = (m.group(2) ?? '').trim();
      final display = label.isEmpty ? 'AI 派生视图' : label;
      if (viewerScope == PrivacyScope.normalOnly &&
          privateTargetIds.contains(id)) {
        return registerPlaceholder('[private-ref]');
      }
      return registerPlaceholder(
        '<blink-embed id="$id" kind="ai">${_escapeHtml(display)}</blink-embed>',
      );
    });

    // 2. Wiki links `[[...]]`
    text = text.replaceAllMapped(_wikiLinkPattern, (m) {
      final parsed = _parseWikiLinkInner(m.group(1)!);
      if (parsed == null) {
        return m.group(0)!;
      }
      if (viewerScope == PrivacyScope.normalOnly &&
          parsed.targetId != null &&
          privateTargetIds.contains(parsed.targetId)) {
        return registerPlaceholder('[private-ref]');
      }
      final attrs = StringBuffer();
      if (parsed.anchor != null) {
        attrs.write(' anchor="${_escapeAttr(parsed.anchor!)}"');
      }
      if (parsed.targetId != null) {
        attrs.write(' id="${_escapeAttr(parsed.targetId!)}"');
      }
      attrs.write(' kind="${parsed.targetKind.wireValue}"');
      return registerPlaceholder(
        '<blink-ref$attrs>${_escapeHtml(parsed.label)}</blink-ref>',
      );
    });

    // 3. `@book:<uuid>(#anchor)?(|label)?`
    text = text.replaceAllMapped(_bookBindPattern, (m) {
      final id = m.group(1)!;
      final anchor = m.group(2);
      final rawLabel = m.group(3)?.trim();
      final label = (rawLabel == null || rawLabel.isEmpty) ? id : rawLabel;
      if (viewerScope == PrivacyScope.normalOnly &&
          privateTargetIds.contains(id)) {
        return registerPlaceholder('[private-ref]');
      }
      final attrs = StringBuffer();
      if (anchor != null) {
        attrs.write(' anchor="${_escapeAttr(anchor)}"');
      }
      attrs.write(' data-bind="context" id="$id" kind="source"');
      return registerPlaceholder(
        '<blink-ref$attrs>${_escapeHtml(label)}</blink-ref>',
      );
    });

    // 4. `@t[mm:ss]` / `@t[hh:mm:ss]`
    text = text.replaceAllMapped(_timestampPattern, (m) {
      final ts = _parseTimestamp(m.group(1)!);
      if (ts == null) {
        return m.group(0)!;
      }
      return registerPlaceholder(
        '<blink-time sec="${ts.seconds}">${_escapeHtml(ts.displayText)}</blink-time>',
      );
    });

    // 5. Inline math `$...$` (strict non-whitespace inner boundaries, not currency `$5`)
    text = text.replaceAllMapped(_inlineMathPattern, (m) {
      final expr = m.group(1)!;
      return registerPlaceholder(
        '<blink-math display="inline">${_escapeHtml(expr)}</blink-math>',
      );
    });

    // 6. Highlight `==...==`
    text = text.replaceAllMapped(_markPattern, (m) {
      final inner = _restoreMaskedCodeAsHtml(
        _escapeHtml(m.group(1)!),
        codeMask,
      );
      return registerPlaceholder('<mark>$inner</mark>');
    });

    // 7. Footnote inline reference `[^id]`
    text = text.replaceAllMapped(_footnoteRefPattern, (m) {
      final id = m.group(1)!;
      final safeId = _sanitizeFootnoteId(id);
      final displayNum = footnoteNumbers[id]?.toString() ?? id;
      return registerPlaceholder(
        '<sup><a href="#fn-$safeId">[${_escapeHtml(displayNum)}]</a></sup>',
      );
    });

    // 8. Protect URLs before scanning `#tags` / `#private`
    final urlMask = _maskUrls(text);
    text = urlMask.masked;

    // Preserve markdown ATX heading prefix `# ` at start of line
    final headingMatch = _headingPrefixPattern.firstMatch(text);
    final headingPrefix = headingMatch?.group(0) ?? '';
    var bodyAfterHeading = headingMatch != null
        ? text.substring(headingPrefix.length)
        : text;

    bodyAfterHeading = bodyAfterHeading.replaceAllMapped(_hashTokenPattern, (
      m,
    ) {
      final rawTag = m.group(1)!;
      if (_isHexColorToken(rawTag)) {
        return m.group(0)!;
      }
      if (rawTag.toLowerCase() == 'private') {
        return registerPlaceholder(
          '<blink-tag data-privacy="private" name="private">🔒 #private</blink-tag>',
        );
      }
      if (!_isValidTagPath(rawTag)) {
        return m.group(0)!;
      }
      return registerPlaceholder(
        '<blink-tag name="${_escapeAttr(rawTag)}">#${_escapeHtml(rawTag)}</blink-tag>',
      );
    });

    text = urlMask.restore('$headingPrefix$bodyAfterHeading');

    // 9. CJK-friendly emphasis (`#650`): resolve `***...***`, `**...**`, `*...*`
    // touching CJK / fullwidth punctuation so `这是**“中文”**测试` and `**结论。**下句` render cleanly.
    text = _applyCjkEmphasis(
      text,
      codeMask: codeMask,
      registerPlaceholder: registerPlaceholder,
    );

    return codeMask.restore(text);
  }

  String _applyCjkEmphasis(
    String text, {
    required _MaskedText codeMask,
    required String Function(String html) registerPlaceholder,
  }) {
    var out = text;
    // Bold + italic `***...***` when touching CJK or CJK punctuation.
    out = out.replaceAllMapped(_cjkBoldItalicPattern, (m) {
      final inner = _restoreMaskedCodeAsHtml(m.group(1)!, codeMask);
      if (!_containsCjkOrFullwidth(m.group(0)!) &&
          !_isAdjacentToCjk(out, m.start, m.end)) {
        return m.group(0)!;
      }
      return registerPlaceholder('<em><strong>$inner</strong></em>');
    });
    // Bold `**...**`
    out = out.replaceAllMapped(_cjkBoldPattern, (m) {
      final inner = _restoreMaskedCodeAsHtml(m.group(1)!, codeMask);
      if (!_containsCjkOrFullwidth(m.group(0)!) &&
          !_isAdjacentToCjk(out, m.start, m.end)) {
        return m.group(0)!;
      }
      return registerPlaceholder('<strong>$inner</strong>');
    });
    // Italic `*...*` (skip list bullet `* ` at start of line)
    out = out.replaceAllMapped(_cjkItalicPattern, (m) {
      final inner = _restoreMaskedCodeAsHtml(m.group(1)!, codeMask);
      if (!_containsCjkOrFullwidth(m.group(0)!) &&
          !_isAdjacentToCjk(out, m.start, m.end)) {
        return m.group(0)!;
      }
      return registerPlaceholder('<em>$inner</em>');
    });
    return out;
  }

  String _stripInlineToPlainText(String line) {
    var text = line;
    // Strip inline code backticks while preserving code content.
    text = text.replaceAllMapped(RegExp(r'`+([^`]+)`+'), (m) => m.group(1)!);
    // Strip AI embeds completely (`INV-01` / `INV-09`).
    text = text.replaceAll(_aiEmbedPattern, ' ');
    // Wiki links -> label only (strip UUID & anchor).
    text = text.replaceAllMapped(_wikiLinkPattern, (m) {
      final parsed = _parseWikiLinkInner(m.group(1)!);
      return parsed?.label ?? '';
    });
    // `@book:<uuid>|Label` -> Label only.
    text = text.replaceAllMapped(_bookBindPattern, (m) {
      final label = m.group(3)?.trim();
      return (label == null || label.isEmpty) ? '' : label;
    });
    // Strip `@t[...]` audio timestamps completely.
    text = text.replaceAll(_timestampPattern, ' ');
    // Inline math -> keep expression, strip `$`.
    text = text.replaceAllMapped(_inlineMathPattern, (m) => m.group(1)!);
    // Highlight `==...==` -> keep text.
    text = text.replaceAllMapped(_markPattern, (m) => m.group(1)!);
    // Footnote inline markers `[^1]` -> strip.
    text = text.replaceAll(_footnoteRefPattern, '');
    // Standard Markdown links `[text](url)` -> keep `text`.
    text = text.replaceAllMapped(
      RegExp(r'!?\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1)!,
    );
    // `#private` -> strip; `#parent/child` -> `parent child`.
    final urlMask = _maskUrls(text);
    var tagClean = urlMask.masked.replaceAllMapped(_hashTokenPattern, (m) {
      final rawTag = m.group(1)!;
      if (_isHexColorToken(rawTag)) {
        return m.group(0)!;
      }
      if (rawTag.toLowerCase() == 'private') {
        return ' ';
      }
      return rawTag.replaceAll('/', ' ');
    });
    tagClean = urlMask.restore(tagClean);
    // Strip emphasis / strikethrough delimiters.
    tagClean = tagClean.replaceAll(RegExp(r'(\*\*\*|\*\*|~~|\*)'), '');
    return tagClean.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  }

  String _convertInlineForMirror(
    String line, {
    required MirrorLinkResolver linkResolver,
    required PrivacyLevel entryPrivacy,
    required Set<String> privateTargetIds,
  }) {
    final codeMask = _maskInlineCodeSpans(line);
    var text = codeMask.masked;

    // 1. AI embed `![[ai:<uuid>|label]]`
    text = text.replaceAllMapped(_aiEmbedPattern, (m) {
      final id = m.group(1)!;
      final label = (m.group(2) ?? '').trim();
      final display = label.isEmpty ? 'AI 派生视图' : label;
      if (entryPrivacy == PrivacyLevel.normal &&
          privateTargetIds.contains(id)) {
        return '[$display (私密条目)]';
      }
      final link = BfmParsedLink(
        targetKind: BfmLinkTargetKind.ai,
        targetId: id,
        label: display,
        isContextBind: false,
      );
      final resolved = linkResolver(link, entryPrivacy);
      return resolved;
    });

    // 2. Wiki links `[[...]]`
    text = text.replaceAllMapped(_wikiLinkPattern, (m) {
      final parsed = _parseWikiLinkInner(m.group(1)!);
      if (parsed == null) {
        return m.group(0)!;
      }
      if (entryPrivacy == PrivacyLevel.normal &&
          parsed.targetId != null &&
          privateTargetIds.contains(parsed.targetId)) {
        return '[${parsed.label} (私密条目)]';
      }
      return linkResolver(parsed, entryPrivacy);
    });

    // 3. `@book:<uuid>(#anchor)?(|label)?`
    text = text.replaceAllMapped(_bookBindPattern, (m) {
      final id = m.group(1)!;
      final anchor = m.group(2);
      final rawLabel = m.group(3)?.trim();
      final label = (rawLabel == null || rawLabel.isEmpty) ? id : rawLabel;
      if (entryPrivacy == PrivacyLevel.normal &&
          privateTargetIds.contains(id)) {
        return '[$label (私密条目)]';
      }
      final link = BfmParsedLink(
        targetKind: BfmLinkTargetKind.source,
        targetId: id,
        anchor: anchor,
        label: label,
        isContextBind: true,
      );
      return linkResolver(link, entryPrivacy);
    });

    // 4. `@t[14:25]` -> `` `14:25` ``
    text = text.replaceAllMapped(_timestampPattern, (m) {
      final ts = _parseTimestamp(m.group(1)!);
      if (ts == null) {
        return m.group(0)!;
      }
      return '`${ts.displayText}`';
    });

    // 5. `==highlight==` -> `<mark>highlight</mark>`
    text = text.replaceAllMapped(
      _markPattern,
      (m) => '<mark>${m.group(1)!}</mark>',
    );

    return codeMask.restore(text);
  }
}

BfmParsedLink? _parseWikiLinkInner(String inner) {
  final trimmed = inner.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final pipeIdx = trimmed.indexOf('|');
  final targetSpec = (pipeIdx >= 0 ? trimmed.substring(0, pipeIdx) : trimmed)
      .trim();
  final explicitLabel = pipeIdx >= 0
      ? trimmed.substring(pipeIdx + 1).trim()
      : '';

  final typedMatch = _typedTargetPattern.firstMatch(targetSpec);
  if (typedMatch != null) {
    final rawKind = typedMatch.group(1)!;
    final id = typedMatch.group(2)!;
    final anchor = typedMatch.group(3);
    if (!isValidUuidV7(id)) {
      return null;
    }
    final kind = switch (rawKind) {
      'entry' => BfmLinkTargetKind.entry,
      'ann' => BfmLinkTargetKind.annotation,
      'book' => BfmLinkTargetKind.source,
      _ => null,
    };
    if (kind == null) {
      return null;
    }
    final label = explicitLabel.isNotEmpty
        ? explicitLabel
        : (anchor != null && anchor.isNotEmpty ? anchor : id);
    return BfmParsedLink(
      targetKind: kind,
      targetId: id,
      anchor: anchor,
      label: label,
      isContextBind: false,
    );
  }

  final label = explicitLabel.isNotEmpty ? explicitLabel : targetSpec;
  return BfmParsedLink(
    targetKind: BfmLinkTargetKind.titleQuery,
    label: label,
    isContextBind: false,
  );
}

BfmTimestamp? _parseTimestamp(String raw) {
  final parts = raw.split(':');
  if (parts.length == 2) {
    final mm = int.tryParse(parts[0]);
    final ss = int.tryParse(parts[1]);
    if (mm == null || ss == null || mm < 0 || ss < 0 || ss >= 60) {
      return null;
    }
    return BfmTimestamp(seconds: mm * 60 + ss, displayText: raw);
  }
  if (parts.length == 3) {
    final hh = int.tryParse(parts[0]);
    final mm = int.tryParse(parts[1]);
    final ss = int.tryParse(parts[2]);
    if (hh == null ||
        mm == null ||
        ss == null ||
        hh < 0 ||
        mm < 0 ||
        mm >= 60 ||
        ss < 0 ||
        ss >= 60) {
      return null;
    }
    return BfmTimestamp(seconds: hh * 3600 + mm * 60 + ss, displayText: raw);
  }
  return null;
}

String _normalizeLineEndings(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

bool _isHexColorToken(String raw) => _hexColorOnlyPattern.hasMatch(raw);

bool _isValidTagPath(String tag) {
  if (tag.isEmpty || tag.length > 64) {
    return false;
  }
  if (tag.startsWith('/') || tag.endsWith('/') || tag.contains('//')) {
    return false;
  }
  return true;
}

String _sanitizeFootnoteId(String id) =>
    id.replaceAll(RegExp(r'[^A-Za-z0-9_:-]'), '-');

String _calloutDefaultTitle(String kind) => switch (kind) {
  'note' => '笔记',
  'insight' => '洞察',
  'tension' => '张力',
  'quote' => '引用',
  'warning' => '提示',
  _ => kind,
};

String _calloutMirrorLabel(String kind) => switch (kind) {
  'note' => '📝 笔记',
  'insight' => '💡 洞察',
  'tension' => '⚡ 张力',
  'quote' => '💬 引用',
  'warning' => '⚠️ 提示',
  _ => kind,
};

bool _containsCjkOrFullwidth(String text) {
  for (final rune in text.runes) {
    if (_isCjkOrFullwidthRune(rune)) {
      return true;
    }
  }
  return false;
}

bool _isAdjacentToCjk(String fullText, int start, int end) {
  if (start > 0 && _isCjkOrFullwidthRune(fullText.codeUnitAt(start - 1))) {
    return true;
  }
  if (end < fullText.length &&
      _isCjkOrFullwidthRune(fullText.codeUnitAt(end))) {
    return true;
  }
  return false;
}

bool _isCjkOrFullwidthRune(int rune) =>
    (rune >= 0x2E80 && rune <= 0x9FFF) ||
    (rune >= 0x3000 && rune <= 0x303F) ||
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFE10 && rune <= 0xFE6F) ||
    (rune >= 0xFF00 && rune <= 0xFFEF) ||
    (rune >= 0x20000 && rune <= 0x2FA1F) ||
    rune == 0x2018 ||
    rune == 0x2019 ||
    rune == 0x201C ||
    rune == 0x201D ||
    rune == 0x2014 ||
    rune == 0x2026 ||
    rune == 0x00B7;

String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _escapeAttr(String value) =>
    _escapeHtml(value).replaceAll('"', '&quot;');

final class _MaskedText {
  const _MaskedText(this.masked, this._tokens);

  final String masked;
  final Map<String, String> _tokens;

  String restore(String input) {
    var result = input;
    for (final entry in _tokens.entries) {
      result = result.replaceAll(entry.key, entry.value);
    }
    return result;
  }
}

String _restoreMaskedCodeAsHtml(String input, _MaskedText codeMask) {
  var result = input;
  for (final entry in codeMask._tokens.entries) {
    if (!result.contains(entry.key)) {
      continue;
    }
    final match = _inlineCodeSpanPattern.firstMatch(entry.value);
    final rawCode = match != null ? match.group(2)! : entry.value;
    result = result.replaceAll(
      entry.key,
      '<code>${_escapeHtml(rawCode)}</code>',
    );
  }
  return result;
}

_MaskedText _maskInlineCodeSpans(String input) {
  final tokens = <String, String>{};
  var idx = 0;
  final masked = input.replaceAllMapped(_inlineCodeSpanPattern, (m) {
    final key = '\uE010CODE${idx++}\uE011';
    tokens[key] = m.group(0)!;
    return key;
  });
  return _MaskedText(masked, tokens);
}

_MaskedText _maskUrls(String input) {
  final tokens = <String, String>{};
  var idx = 0;
  final masked = input.replaceAllMapped(_urlPattern, (m) {
    final key = '\uE012URL${idx++}\uE013';
    tokens[key] = m.group(0)!;
    return key;
  });
  return _MaskedText(masked, tokens);
}

_MaskedText _maskInlineCodeAndUrls(String input) {
  final codeMask = _maskInlineCodeSpans(input);
  final urlMask = _maskUrls(codeMask.masked);
  return _MaskedText(urlMask.masked, <String, String>{
    ...codeMask._tokens,
    ...urlMask._tokens,
  });
}

final RegExp _fencePattern = RegExp(r'^[ \t]{0,3}(`{3,}|~{3,})');
final RegExp _calloutStartPattern = RegExp(
  r'^[ \t]*>[ \t]*\[!(note|insight|tension|quote|warning)\]([+-])?(?:[ \t]+(.*))?$',
  caseSensitive: false,
);
final RegExp _blockquoteLinePattern = RegExp(r'^[ \t]*>[ \t]?(.*)$');
final RegExp _foldStartPattern = RegExp(r'^:::fold(?:[ \t]+(.*))?$');
final RegExp _foldEndPattern = RegExp(r'^:::[ \t]*$');
final RegExp _blockMathFencePattern = RegExp(r'^[ \t]*\$\$[ \t]*$');
final RegExp _singleLineBlockMathPattern = RegExp(
  r'^[ \t]*\$\$([^$\n]+?)\$\$[ \t]*$',
);
final RegExp _footnoteDefPattern = RegExp(
  r'^\[\^([A-Za-z0-9_-]{1,32})\]:[ \t]+(.+)$',
);
final RegExp _footnoteRefPattern = RegExp(r'\[\^([A-Za-z0-9_-]{1,32})\]');
final RegExp _tableSeparatorPattern = RegExp(
  r'^[ \t]*\|?(?:[ \t]*:?-{3,}:?[ \t]*\|)+[ \t]*:?-{3,}:?[ \t]*\|?[ \t]*$',
);
final RegExp _detailsTagPattern = RegExp(
  r'</?(?:details|summary)\b',
  caseSensitive: false,
);
final RegExp _allowedRawDetailsPattern = RegExp(
  r'<(?:details(?:\s+open)?|/details|summary|/summary)>',
  caseSensitive: false,
);
final RegExp _htmlCommentPattern = RegExp(r'<!--[\s\S]*?-->');
final RegExp _rawHtmlTagPattern = RegExp(
  r'</?[A-Za-z][A-Za-z0-9:-]*(?:\s+[^<>]*)?/?>',
);
final RegExp _taskLinePattern = RegExp(
  r'^([ \t]*)([-*])[ \t]+\[([ xX>\-])\][ \t]+(.+)$',
);
final RegExp _headingPrefixPattern = RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+');
final RegExp _inlineCodeSpanPattern = RegExp(r'(`+)([^\n]*?)\1');
final RegExp _urlPattern = RegExp(r'https?://[^\s<>()]+');
final RegExp _aiEmbedPattern = RegExp(
  r'!\[\[ai:([0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(?:\|([^\]]*))?\]\]',
);
final RegExp _wikiLinkPattern = RegExp(r'(?<!\!)\[\[([^\[\]\n]+)\]\]');
final RegExp _typedTargetPattern = RegExp(
  r'^(entry|ann|book):([0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})'
  r'(?:#(p[1-9][0-9]*|ch-[a-zA-Z0-9_-]+(?:/b-[0-9]{4}-[0-9a-f]{8})?))?$',
);
final RegExp _bookBindPattern = RegExp(
  r'@book:([0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})'
  r'(?:#(p[1-9][0-9]*|ch-[a-zA-Z0-9_-]+(?:/b-[0-9]{4}-[0-9a-f]{8})?))?'
  r'(?:\|([^\s\n]+))?',
);
final RegExp _timestampPattern = RegExp(
  r'@t\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\]',
);
final RegExp _inlineMathPattern = RegExp(
  r'(?<!\\)(?<!\$)\$(?!\s)((?:[^$\n\\]|\\.)+?)(?<!\s)\$(?!\$)(?!\d)',
);
final RegExp _markPattern = RegExp(r'==(?=\S)([^=\n]+?)(?<=\S)==');
final RegExp _hashTokenPattern = RegExp(
  r'(?<![A-Za-z0-9_/&])#([\p{L}\p{N}_-]+(?:/[\p{L}\p{N}_-]+)*)',
  unicode: true,
);
final RegExp _hexColorOnlyPattern = RegExp(
  r'^(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$',
);
final RegExp _cjkBoldItalicPattern = RegExp(
  r'(?<!\*)\*\*\*(?!\s|\*)([^\n*]+?)(?<!\s)\*\*\*(?!\*)',
);
final RegExp _cjkBoldPattern = RegExp(
  r'(?<!\*)\*\*(?!\s|\*)([^\n]+?)(?<!\s)\*\*(?!\*)',
);
final RegExp _cjkItalicPattern = RegExp(
  r'(?<!\*)\*(?!\s|\*)([^\n*]+?)(?<!\s)\*(?!\*)',
);
