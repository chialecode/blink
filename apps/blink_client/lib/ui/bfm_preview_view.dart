import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';

/// Callback invoked when the user clicks a `[[...]]` link pill inside preview.
typedef BfmLinkTapCallback = void Function(BfmParsedLink link);

/// Callback invoked when the user toggles an endogenous `- [ ]` checkbox in preview.
typedef BfmTaskLineToggleCallback = void Function(
  int lineIndex,
  TaskStatus nextStatus,
);

/// Native Flutter renderer for Markdown preview & entry display (`docs/ui.md` §2.2, §3.1).
///
/// Strictly uses [BlinkColorTokens.of] (zero hardcoded hex color literals) so
/// Day, Sepia, and Dark surfaces switch cleanly without flicker.
class BfmPreviewView extends StatelessWidget {
  const BfmPreviewView({
    required this.bodyMd,
    this.compiledHtml,
    this.onTapLink,
    this.onToggleTaskLine,
    this.onTapTag,
    this.compact = false,
    super.key,
  });

  final String bodyMd;
  final String? compiledHtml;
  final BfmLinkTapCallback? onTapLink;
  final BfmTaskLineToggleCallback? onToggleTaskLine;
  final ValueChanged<String>? onTapTag;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final normalized = bodyMd.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.trim().isEmpty) {
      return Text(
        '开始输入内容，支持 Markdown 格式、#标签、#私密、[[双向链接]]、==高亮== 与待办清单。',
        style: BlinkTypography.body(tokens, color: tokens.textMuted),
      );
    }

    final blocks = _parseBlocks(normalized);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < blocks.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: compact ? 6 : 10),
          _buildBlock(context, blocks[i], tokens),
        ],
      ],
    );
  }

  Widget _buildBlock(
    BuildContext context,
    _BfmBlock block,
    BlinkColorTokens tokens,
  ) {
    switch (block) {
      case _HeadingBlock(:final level, :final text):
        final style = compact
            ? (level <= 1
                  ? BlinkTypography.heroHeading(tokens)
                  : level == 2
                  ? BlinkTypography.sectionHeading(tokens)
                  : BlinkTypography.controlLabel(tokens))
            : BlinkTypography.headingForLevel(tokens, level);
        return BlinkMarkdownInlineText(
          text: text,
          baseStyle: style,
          onTapLink: onTapLink,
          onTapTag: onTapTag,
        );
      case _ParagraphBlock(:final text):
        return BlinkMarkdownInlineText(
          text: text,
          baseStyle: compact
              ? BlinkTypography.body(tokens)
              : BlinkTypography.editorBody(tokens),
          onTapLink: onTapLink,
          onTapTag: onTapTag,
        );
      case _BulletListBlock(:final text, :final indentLevel):
        return Padding(
          padding: EdgeInsets.only(left: indentLevel * 16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 20,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '•',
                    style:
                        (compact
                                ? BlinkTypography.body(tokens)
                                : BlinkTypography.editorBody(tokens))
                            .copyWith(
                              color: tokens.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                  ),
                ),
              ),
              Expanded(
                child: BlinkMarkdownInlineText(
                  text: text,
                  baseStyle: compact
                      ? BlinkTypography.body(tokens)
                      : BlinkTypography.editorBody(tokens),
                  onTapLink: onTapLink,
                  onTapTag: onTapTag,
                ),
              ),
            ],
          ),
        );
      case _OrderedListBlock(:final ordinal, :final text, :final indentLevel):
        return Padding(
          padding: EdgeInsets.only(left: indentLevel * 16.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 24),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    '$ordinal.',
                    style:
                        (compact
                                ? BlinkTypography.body(tokens)
                                : BlinkTypography.editorBody(tokens))
                            .copyWith(
                              color: tokens.textSecondary,
                              fontFeatures: BlinkTypography.tabularFigures,
                            ),
                  ),
                ),
              ),
              Expanded(
                child: BlinkMarkdownInlineText(
                  text: text,
                  baseStyle: compact
                      ? BlinkTypography.body(tokens)
                      : BlinkTypography.editorBody(tokens),
                  onTapLink: onTapLink,
                  onTapTag: onTapTag,
                ),
              ),
            ],
          ),
        );
      case _BlockquoteBlock(:final lines):
        return IntrinsicHeight(
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
                child: BlinkMarkdownInlineText(
                  text: lines.join('\n'),
                  baseStyle: BlinkTypography.blockquote(tokens),
                  onTapLink: onTapLink,
                  onTapTag: onTapTag,
                ),
              ),
            ],
          ),
        );
      case _DividerBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Divider(height: 1, thickness: 1, color: tokens.borderHairline),
        );
      case _TaskBlock(:final lineIndex, :final status, :final title):
        final isDone = status == TaskStatus.done;
        final isDropped = status == TaskStatus.dropped;
        final isDeferred = status == TaskStatus.deferred;
        final nextStatus = isDone ? TaskStatus.open : TaskStatus.done;
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onToggleTaskLine == null
              ? null
              : () => onToggleTaskLine!(lineIndex, nextStatus),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
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
                const SizedBox(width: 8),
                Expanded(
                  child: BlinkMarkdownInlineText(
                    text: title,
                    baseStyle:
                        BlinkTypography.body(
                          tokens,
                          color: (isDone || isDropped)
                              ? tokens.textMuted
                              : tokens.textPrimary,
                        ).copyWith(
                          decoration: (isDone || isDropped)
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                    onTapLink: onTapLink,
                    onTapTag: onTapTag,
                  ),
                ),
              ],
            ),
          ),
        );
      case _CalloutBlock(:final kind, :final title, :final bodyLines):
        final accent = switch (kind) {
          'warning' || 'caution' => tokens.statusWarn,
          'danger' || 'error' => tokens.statusErr,
          'tip' || 'success' => tokens.statusOk,
          _ => tokens.accentPrimary,
        };
        return ClipRRect(
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
                          if (bodyLines.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 6),
                            BlinkMarkdownInlineText(
                              text: bodyLines.join('\n'),
                              baseStyle: BlinkTypography.body(tokens),
                              onTapLink: onTapLink,
                              onTapTag: onTapTag,
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
      case _FoldBlock(:final title, :final bodyMd):
        return _BfmFoldCard(
          title: title.isEmpty ? '展开详情' : title,
          bodyMd: bodyMd,
          onTapLink: onTapLink,
          onTapTag: onTapTag,
        );
      case _CodeBlock(:final language, :final code):
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.sidebar,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tokens.borderHairline, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (language.isNotEmpty) ...<Widget>[
                Text(
                  language,
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  code,
                  style: BlinkTypography.codeBlock(tokens),
                ),
              ),
            ],
          ),
        );
      case _TableBlock(:final headers, :final rows):
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: tokens.borderHairline, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.symmetric(
                inside: BorderSide(color: tokens.borderHairline, width: 1),
              ),
              children: <TableRow>[
                TableRow(
                  decoration: BoxDecoration(color: tokens.sidebar),
                  children: <Widget>[
                    for (final cell in headers)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Text(
                          cell,
                          style: BlinkTypography.controlLabel(tokens),
                        ),
                      ),
                  ],
                ),
                for (final row in rows)
                  TableRow(
                    children: <Widget>[
                      for (var col = 0; col < headers.length; col++)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Text(
                            col < row.length ? row[col] : '',
                            style: BlinkTypography.body(tokens),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      case _AiEmbedBlock(:final aiId, :final label):
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tokens.aiDerived,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tokens.borderHairline, width: 1),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                Icons.auto_awesome_outlined,
                size: 16,
                color: tokens.accentPrimary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label.isEmpty ? '✦ AI 派生只读视图' : '✦ AI 派生 · $label',
                      style: BlinkTypography.controlLabel(tokens),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '只读引用 · $aiId',
                      style: BlinkTypography.monoValue(
                        tokens,
                        tabular: true,
                      ).copyWith(color: tokens.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    }
  }
}

class _BfmFoldCard extends StatefulWidget {
  const _BfmFoldCard({
    required this.title,
    required this.bodyMd,
    this.onTapLink,
    this.onTapTag,
  });

  final String title;
  final String bodyMd;
  final BfmLinkTapCallback? onTapLink;
  final ValueChanged<String>? onTapTag;

  @override
  State<_BfmFoldCard> createState() => _BfmFoldCardState();
}

class _BfmFoldCardState extends State<_BfmFoldCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.sidebar,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.borderHairline, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    _expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: tokens.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: BlinkTypography.controlLabel(tokens),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...<Widget>[
            Divider(height: 1, color: tokens.borderHairline),
            Padding(
              padding: const EdgeInsets.all(12),
              child: BlinkMarkdownInlineText(
                text: widget.bodyMd,
                baseStyle: BlinkTypography.body(tokens),
                onTapLink: widget.onTapLink,
                onTapTag: widget.onTapTag,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared native Flutter inline Markdown renderer used by [BfmPreviewView] and
/// inactive WYSIWYG blocks.
class BlinkMarkdownInlineText extends StatelessWidget {
  const BlinkMarkdownInlineText({
    required this.text,
    required this.baseStyle,
    this.onTapLink,
    this.onTapTag,
    super.key,
  });

  final String text;
  final TextStyle baseStyle;
  final BfmLinkTapCallback? onTapLink;
  final ValueChanged<String>? onTapTag;

  static final RegExp _inlinePattern = RegExp(
    r'(`[^`\n]+`|\[\[[^\]]+\]\]|\[[^\]\n]+\]\([^\)\n]+\)|==[^=\n]+==|\*\*[^*\n]+\*\*|~~[^~\n]+~~|(?<!\*)\*[^*\n]+\*(?!\*)|@t\[[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?\]|(?<![\w/#])#(?:private\b|[\p{L}\p{N}_][\p{L}\p{N}_/\-]*))',
    unicode: true,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _inlinePattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final raw = match.group(0)!;
      if (raw.startsWith('`') && raw.endsWith('`') && raw.length >= 2) {
        spans.add(
          TextSpan(
            text: raw.substring(1, raw.length - 1),
            style: BlinkTypography.inlineCode(tokens),
          ),
        );
      } else if (raw.startsWith('[[')) {
        final inner = raw.substring(2, raw.length - 2);
        final parsed = _parseInlineLink(inner);
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onTapLink == null ? null : () => onTapLink!(parsed),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: tokens.accentSubtle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    parsed.label,
                    style: BlinkTypography.badge(color: tokens.accentPrimary),
                  ),
                ),
              ),
            ),
          ),
        );
      } else if (raw.startsWith('[') && raw.contains('](')) {
        final splitIdx = raw.indexOf('](');
        final label = raw.substring(1, splitIdx);
        spans.add(
          TextSpan(
            text: label,
            style: baseStyle.copyWith(
              color: tokens.accentPrimary,
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.underline,
              decorationColor: tokens.accentPrimary,
            ),
          ),
        );
      } else if (raw.startsWith('==')) {
        spans.add(
          TextSpan(
            text: raw.substring(2, raw.length - 2),
            style: baseStyle.copyWith(backgroundColor: tokens.highlightMark),
          ),
        );
      } else if (raw.startsWith('**')) {
        spans.add(
          TextSpan(
            text: raw.substring(2, raw.length - 2),
            style: baseStyle.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else if (raw.startsWith('~~')) {
        spans.add(
          TextSpan(
            text: raw.substring(2, raw.length - 2),
            style: baseStyle.copyWith(
              color: tokens.textMuted,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        );
      } else if (raw.startsWith('*')) {
        spans.add(
          TextSpan(
            text: raw.substring(1, raw.length - 1),
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (raw.startsWith('@t[')) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: tokens.sidebar,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tokens.borderHairline, width: 1),
              ),
              child: Text(
                raw.substring(3, raw.length - 1),
                style: BlinkTypography.metaLabel(
                  tokens,
                  color: tokens.textSecondary,
                ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
              ),
            ),
          ),
        );
      } else if (raw.toLowerCase() == '#private') {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
                    style: BlinkTypography.badge(color: tokens.privacyPrivate),
                  ),
                ],
              ),
            ),
          ),
        );
      } else if (raw.startsWith('#')) {
        final tagName = raw.substring(1).toLowerCase();
        if (onTapTag != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => onTapTag!(tagName),
                  child: Text(
                    raw,
                    style: baseStyle.copyWith(
                      color: tokens.accentPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        } else {
          spans.add(
            TextSpan(
              text: raw,
              style: baseStyle.copyWith(
                color: tokens.accentPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }

  static BfmParsedLink _parseInlineLink(String inner) {
    final pipeIdx = inner.indexOf('|');
    final targetPart = (pipeIdx >= 0 ? inner.substring(0, pipeIdx) : inner)
        .trim();
    final explicitLabel = pipeIdx >= 0
        ? inner.substring(pipeIdx + 1).trim()
        : '';

    final colonIdx = targetPart.indexOf(':');
    if (colonIdx > 0) {
      final prefix = targetPart.substring(0, colonIdx).toLowerCase();
      final rest = targetPart.substring(colonIdx + 1);
      final hashIdx = rest.indexOf('#');
      final id = hashIdx >= 0 ? rest.substring(0, hashIdx) : rest;
      final anchor = hashIdx >= 0 ? rest.substring(hashIdx + 1) : null;
      final kind = switch (prefix) {
        'entry' => BfmLinkTargetKind.entry,
        'ann' || 'annotation' => BfmLinkTargetKind.annotation,
        'book' || 'source' => BfmLinkTargetKind.source,
        'ai' => BfmLinkTargetKind.ai,
        _ => BfmLinkTargetKind.titleQuery,
      };
      return BfmParsedLink(
        targetKind: kind,
        targetId: kind == BfmLinkTargetKind.titleQuery ? null : id,
        anchor: anchor,
        label: explicitLabel.isNotEmpty ? explicitLabel : id,
        isContextBind: false,
      );
    }

    return BfmParsedLink(
      targetKind: BfmLinkTargetKind.titleQuery,
      label: explicitLabel.isNotEmpty ? explicitLabel : targetPart,
      isContextBind: false,
    );
  }
}

sealed class _BfmBlock {
  const _BfmBlock();
}

class _HeadingBlock extends _BfmBlock {
  const _HeadingBlock(this.level, this.text);

  final int level;
  final String text;
}

class _ParagraphBlock extends _BfmBlock {
  const _ParagraphBlock(this.text);

  final String text;
}

class _BulletListBlock extends _BfmBlock {
  const _BulletListBlock(this.text, this.indentLevel);

  final String text;
  final int indentLevel;
}

class _OrderedListBlock extends _BfmBlock {
  const _OrderedListBlock(this.ordinal, this.text, this.indentLevel);

  final int ordinal;
  final String text;
  final int indentLevel;
}

class _BlockquoteBlock extends _BfmBlock {
  const _BlockquoteBlock(this.lines);

  final List<String> lines;
}

class _DividerBlock extends _BfmBlock {
  const _DividerBlock();
}

class _TaskBlock extends _BfmBlock {
  const _TaskBlock(this.lineIndex, this.status, this.title);

  final int lineIndex;
  final TaskStatus status;
  final String title;
}

class _CalloutBlock extends _BfmBlock {
  const _CalloutBlock(this.kind, this.title, this.bodyLines);

  final String kind;
  final String title;
  final List<String> bodyLines;
}

class _FoldBlock extends _BfmBlock {
  const _FoldBlock(this.title, this.bodyMd);

  final String title;
  final String bodyMd;
}

class _CodeBlock extends _BfmBlock {
  const _CodeBlock(this.language, this.code);

  final String language;
  final String code;
}

class _TableBlock extends _BfmBlock {
  const _TableBlock(this.headers, this.rows);

  final List<String> headers;
  final List<List<String>> rows;
}

class _AiEmbedBlock extends _BfmBlock {
  const _AiEmbedBlock(this.aiId, this.label);

  final String aiId;
  final String label;
}

final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _taskRe = RegExp(
  r'^[ \t]*[-*][ \t]+\[([ xX>\-])\](?:[ \t]+(.*)|[ \t]*)$',
);
final RegExp _bulletRe = RegExp(r'^([ \t]*)[-*][ \t]+(.*)$');
final RegExp _orderedRe = RegExp(r'^([ \t]*)(\d+)\.[ \t]+(.*)$');
final RegExp _calloutRe = RegExp(r'^[ \t]*>[ \t]*\[!([A-Za-z]+)\][ \t]*(.*)$');
final RegExp _blockquoteRe = RegExp(r'^[ \t]*>[ \t]?(.*)$');
final RegExp _dividerRe = RegExp(r'^[ \t]*(?:---+|\*\*\*+)[ \t]*$');
final RegExp _foldOpenRe = RegExp(r'^[ \t]*:::fold[ \t]*(.*)$');
final RegExp _foldCloseRe = RegExp(r'^[ \t]*:::[ \t]*$');
final RegExp _fenceRe = RegExp(r'^[ \t]*```([A-Za-z0-9_+-]*)[ \t]*$');
final RegExp _aiEmbedLineRe = RegExp(
  r'^[ \t]*!\[\[ai:([^\]|]+)(?:\|([^\]]*))?\]\][ \t]*$',
);
final RegExp _tableSepRe = RegExp(
  r'^[ \t]*\|?(?:[ \t]*:?-{3,}:?[ \t]*\|)+[ \t]*:?-{3,}:?[ \t]*\|?[ \t]*$',
);

int _indentLevelOf(String prefix) {
  var spaces = 0;
  for (var i = 0; i < prefix.length; i++) {
    spaces += prefix[i] == '\t' ? 2 : 1;
  }
  return (spaces ~/ 2).clamp(0, 4);
}

List<_BfmBlock> _parseBlocks(String normalized) {
  final lines = normalized.split('\n');
  final blocks = <_BfmBlock>[];
  var i = 0;

  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // Fenced code block.
    final fenceMatch = _fenceRe.firstMatch(line);
    if (fenceMatch != null) {
      final lang = fenceMatch.group(1) ?? '';
      final codeLines = <String>[];
      i++;
      while (i < lines.length && !_fenceRe.hasMatch(lines[i])) {
        codeLines.add(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      blocks.add(_CodeBlock(lang, codeLines.join('\n')));
      continue;
    }

    // :::fold block.
    final foldMatch = _foldOpenRe.firstMatch(line);
    if (foldMatch != null) {
      final title = (foldMatch.group(1) ?? '').trim();
      final bodyLines = <String>[];
      i++;
      while (i < lines.length && !_foldCloseRe.hasMatch(lines[i])) {
        bodyLines.add(lines[i]);
        i++;
      }
      if (i < lines.length) {
        i++;
      }
      blocks.add(_FoldBlock(title, bodyLines.join('\n')));
      continue;
    }

    // > [!callout] block.
    final calloutMatch = _calloutRe.firstMatch(line);
    if (calloutMatch != null) {
      final kind = calloutMatch.group(1)!.toLowerCase();
      final title = (calloutMatch.group(2) ?? '').trim();
      final bodyLines = <String>[];
      i++;
      while (i < lines.length &&
          lines[i].trimLeft().startsWith('>') &&
          !_calloutRe.hasMatch(lines[i])) {
        bodyLines.add(lines[i].replaceFirst(RegExp(r'^[ \t]*>[ \t]?'), ''));
        i++;
      }
      blocks.add(_CalloutBlock(kind, title, bodyLines));
      continue;
    }

    // Plain blockquote (> ...).
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
      blocks.add(_BlockquoteBlock(quoteLines));
      continue;
    }

    // Standalone ![[ai:...]] read-only embed slot.
    final aiMatch = _aiEmbedLineRe.firstMatch(line);
    if (aiMatch != null) {
      blocks.add(
        _AiEmbedBlock(
          aiMatch.group(1)!.trim(),
          (aiMatch.group(2) ?? '').trim(),
        ),
      );
      i++;
      continue;
    }

    // Horizontal rule (--- or ***).
    if (_dividerRe.hasMatch(line)) {
      blocks.add(const _DividerBlock());
      i++;
      continue;
    }

    // Heading.
    final headingMatch = _headingRe.firstMatch(line);
    if (headingMatch != null) {
      blocks.add(
        _HeadingBlock(headingMatch.group(1)!.length, headingMatch.group(2)!),
      );
      i++;
      continue;
    }

    // Endogenous task line.
    final taskMatch = _taskRe.firstMatch(line);
    if (taskMatch != null) {
      final status =
          TaskStatus.fromBfmMarker(taskMatch.group(1)!) ?? TaskStatus.open;
      blocks.add(_TaskBlock(i, status, taskMatch.group(2) ?? ''));
      i++;
      continue;
    }

    // Unordered list item (- / *).
    final bulletMatch = _bulletRe.firstMatch(line);
    if (bulletMatch != null) {
      blocks.add(
        _BulletListBlock(
          bulletMatch.group(2)!,
          _indentLevelOf(bulletMatch.group(1)!),
        ),
      );
      i++;
      continue;
    }

    // Ordered list item (1. / 2. ...).
    final orderedMatch = _orderedRe.firstMatch(line);
    if (orderedMatch != null) {
      blocks.add(
        _OrderedListBlock(
          int.tryParse(orderedMatch.group(2)!) ?? 1,
          orderedMatch.group(3)!,
          _indentLevelOf(orderedMatch.group(1)!),
        ),
      );
      i++;
      continue;
    }

    // GFM table.
    if (line.contains('|') &&
        i + 1 < lines.length &&
        _tableSepRe.hasMatch(lines[i + 1])) {
      final headers = _splitTableRow(line);
      i += 2;
      final rows = <List<String>>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          lines[i].contains('|')) {
        rows.add(_splitTableRow(lines[i]));
        i++;
      }
      blocks.add(_TableBlock(headers, rows));
      continue;
    }

    // Paragraph (accumulate consecutive plain lines).
    final paraLines = <String>[line];
    i++;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_headingRe.hasMatch(lines[i]) &&
        !_taskRe.hasMatch(lines[i]) &&
        !_bulletRe.hasMatch(lines[i]) &&
        !_orderedRe.hasMatch(lines[i]) &&
        !_dividerRe.hasMatch(lines[i]) &&
        !_blockquoteRe.hasMatch(lines[i]) &&
        !_calloutRe.hasMatch(lines[i]) &&
        !_foldOpenRe.hasMatch(lines[i]) &&
        !_fenceRe.hasMatch(lines[i]) &&
        !_aiEmbedLineRe.hasMatch(lines[i])) {
      paraLines.add(lines[i]);
      i++;
    }
    blocks.add(_ParagraphBlock(paraLines.join('\n')));
  }

  return blocks;
}

List<String> _splitTableRow(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) {
    trimmed = trimmed.substring(1);
  }
  if (trimmed.endsWith('|')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed.split('|').map((cell) => cell.trim()).toList(growable: false);
}
