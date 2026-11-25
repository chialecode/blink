import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'css_sanitizer.dart';
import 'models.dart';

/// Pure Dart HTML5/SVG + CSS whitelist sanitizer and `<blink-*>` contract validator.
class BlinkHtmlSanitizer {
  const BlinkHtmlSanitizer();

  /// Parses [rawHtml] with an HTML5 DOM tree builder (`package:html`), applies
  /// strict tag/attribute/CSS/URL/`<blink-*>` whitelists, and deterministically
  /// rebuilds clean output HTML along with structured diagnostics.
  SanitizeResult sanitize(String rawHtml, {required SanitizeOptions options}) {
    final diagnostics = <SanitizeDiagnostic>[];
    final extractedRefs = <BlinkRefTarget>[];
    final out = StringBuffer();

    final isFullDocument = _fullDocStartPattern.hasMatch(rawHtml);
    if (isFullDocument) {
      final doc = html_parser.parse(rawHtml);
      final head = doc.head;
      if (head != null) {
        for (final node in head.nodes) {
          if (node is dom.Element) {
            final tag = _localName(node);
            if (tag == 'title' &&
                options.profile == SanitizeProfile.surface2Sandbox) {
              // Document <title> metadata is dropped silently in Surface 2 docs.
              continue;
            }
            _sanitizeNode(
              node,
              options: options,
              diagnostics: diagnostics,
              extractedRefs: extractedRefs,
              out: out,
              inSvg: false,
            );
          }
        }
      }
      final body = doc.body;
      if (body != null) {
        for (final node in body.nodes) {
          _sanitizeNode(
            node,
            options: options,
            diagnostics: diagnostics,
            extractedRefs: extractedRefs,
            out: out,
            inSvg: false,
          );
        }
      }
    } else {
      final fragment = html_parser.parseFragment(rawHtml);
      for (final node in fragment.nodes) {
        _sanitizeNode(
          node,
          options: options,
          diagnostics: diagnostics,
          extractedRefs: extractedRefs,
          out: out,
          inSvg: false,
        );
      }
    }

    return SanitizeResult(
      html: out.toString(),
      diagnostics: diagnostics,
      extractedRefs: extractedRefs,
    );
  }
}

/// Top-level convenience entry point for [BlinkHtmlSanitizer.sanitize].
SanitizeResult sanitizeBlinkHtml(
  String rawHtml, {
  required SanitizeOptions options,
}) => const BlinkHtmlSanitizer().sanitize(rawHtml, options: options);

final RegExp _fullDocStartPattern = RegExp(
  r'^\s*(?:<!--[\s\S]*?-->\s*)*(?:<!doctype\b|<html\b|<head\b|<body\b)',
  caseSensitive: false,
);

final RegExp _uuidV7Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

final RegExp _blinkAnchorAttrPattern = RegExp(
  r'^(?:p[1-9][0-9]*|ch-[a-zA-Z0-9_-]+(?:/b-[0-9]{4}-[0-9a-f]{8})?)$',
);

final RegExp _blinkBlobUrlPattern = RegExp(r'^blink-blob://[0-9a-f]{64}$');

final RegExp _blinkAnchorUrlPattern = RegExp(
  r'^blink-anchor://[a-zA-Z0-9_-]+(?:#[a-zA-Z0-9_-]+)?$',
);

final RegExp _blinkRefUrlPattern = RegExp(
  r'^blink-ref://(?:entry|annotation|source)/'
  r'[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
  r'(?:\?anchor=[a-zA-Z0-9_%./-]+)?$',
);

final RegExp _safeFragmentHrefPattern = RegExp(r'^#[A-Za-z0-9_:-]{1,128}$');

final RegExp _safeIdPattern = RegExp(r'^[A-Za-z][A-Za-z0-9_:-]{0,127}$');

final RegExp _safeClassTokenPattern = RegExp(
  r'^[A-Za-z_-][A-Za-z0-9_-]{0,63}$',
);

final RegExp _blinkTagNamePattern = RegExp(r'^[^\s\x00-\x1f\x7f]{1,64}$');

final RegExp _blinkTimeSecPattern = RegExp(r'^[0-9]{1,7}$');

final RegExp _positiveIntPattern = RegExp(r'^[1-9][0-9]{0,2}$');

final RegExp _nonNegIntPattern = RegExp(r'^[0-9]{1,5}$');

final RegExp _svgLocalUrlRefPattern = RegExp(
  r'^url\(\s*#([A-Za-z_][A-Za-z0-9_-]{0,127})\s*\)$',
  caseSensitive: false,
);

final RegExp _svgAnyUrlPattern = RegExp(
  r'(?:url|src)\s*\(|\\(?:0{0,4}75|0{0,4}55)',
  caseSensitive: false,
);

final RegExp _rawHexColorPattern = RegExp(
  r'^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$',
  caseSensitive: false,
);

final RegExp _rawColorFnPattern = RegExp(
  r'^(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\s*\(',
  caseSensitive: false,
);

final RegExp _blinkVarValuePattern = RegExp(
  r'^var\(\s*--blink-[a-z0-9-]+\s*\)$',
);

final RegExp _rawColorSubstringPattern = RegExp(
  r'#[0-9a-f]{3,8}\b|(?:rgba?|hsla?|oklch|oklab)\s*\(',
  caseSensitive: false,
);

const Set<String> _htmlVoidTags = <String>{'br', 'hr', 'img', 'col', 'wbr'};

const Set<String> _allowedHtmlTags = <String>{
  'article',
  'section',
  'nav',
  'aside',
  'header',
  'footer',
  'main',
  'div',
  'span',
  'p',
  'br',
  'hr',
  'wbr',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'hgroup',
  'blockquote',
  'pre',
  'code',
  'kbd',
  'samp',
  'var',
  'cite',
  'q',
  'abbr',
  'dfn',
  'time',
  'address',
  'strong',
  'b',
  'em',
  'i',
  'u',
  's',
  'del',
  'ins',
  'mark',
  'small',
  'sub',
  'sup',
  'ruby',
  'rt',
  'rp',
  'rb',
  'rtc',
  'bdi',
  'bdo',
  'ul',
  'ol',
  'li',
  'dl',
  'dt',
  'dd',
  'table',
  'caption',
  'colgroup',
  'col',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'th',
  'td',
  'figure',
  'figcaption',
  'details',
  'summary',
  'a',
  'img',
};

const Set<String> _allowedSvgTags = <String>{
  'svg',
  'g',
  'defs',
  'path',
  'rect',
  'circle',
  'ellipse',
  'line',
  'polyline',
  'polygon',
  'lineargradient',
  'radialgradient',
  'stop',
  'clippath',
  'mask',
  'pattern',
  'marker',
  'text',
  'tspan',
  'desc',
};

const Map<String, String> _canonicalSvgTagNames = <String, String>{
  'lineargradient': 'linearGradient',
  'radialgradient': 'radialGradient',
  'clippath': 'clipPath',
};

const Map<String, String> _canonicalSvgAttrNames = <String, String>{
  'viewbox': 'viewBox',
  'preserveaspectratio': 'preserveAspectRatio',
  'gradientunits': 'gradientUnits',
  'gradienttransform': 'gradientTransform',
  'spreadmethod': 'spreadMethod',
  'markerwidth': 'markerWidth',
  'markerheight': 'markerHeight',
  'refx': 'refX',
  'refy': 'refY',
};

const Set<String> _knownBlinkTags = <String>{
  'blink-ref',
  'blink-embed',
  'blink-tag',
  'blink-time',
  'blink-math',
  'blink-grid',
  'blink-card',
  'blink-metric',
  'blink-timeline',
  'blink-compare',
  'blink-chart',
};

const Set<String> _aiSurface1LayoutTags = <String>{
  'blink-grid',
  'blink-card',
  'blink-metric',
  'blink-timeline',
  'blink-compare',
  'blink-chart',
};

const Set<String> _globalHtmlAttrs = <String>{
  'id',
  'class',
  'dir',
  'lang',
  'title',
  'role',
  'aria-label',
  'aria-labelledby',
  'aria-describedby',
  'aria-hidden',
  'style',
};

const Map<String, Set<String>> _tagSpecificHtmlAttrs = <String, Set<String>>{
  'a': <String>{'href'},
  'img': <String>{'src', 'alt', 'width', 'height'},
  'th': <String>{'colspan', 'rowspan', 'scope', 'headers'},
  'td': <String>{'colspan', 'rowspan', 'headers'},
  'col': <String>{'span'},
  'colgroup': <String>{'span'},
  'ol': <String>{'start', 'type', 'reversed'},
  'li': <String>{'value', 'data-task-status'},
  'details': <String>{'open'},
  'time': <String>{'datetime'},
};

const Set<String> _allowedSvgAttrs = <String>{
  'id',
  'class',
  'role',
  'aria-label',
  'aria-hidden',
  'style',
  'xmlns',
  'viewbox',
  'width',
  'height',
  'preserveaspectratio',
  'x',
  'y',
  'x1',
  'y1',
  'x2',
  'y2',
  'cx',
  'cy',
  'r',
  'rx',
  'ry',
  'd',
  'points',
  'transform',
  'fill',
  'fill-opacity',
  'fill-rule',
  'stroke',
  'stroke-width',
  'stroke-opacity',
  'stroke-linecap',
  'stroke-linejoin',
  'stroke-dasharray',
  'stroke-dashoffset',
  'stroke-miterlimit',
  'opacity',
  'offset',
  'stop-color',
  'stop-opacity',
  'gradientunits',
  'gradienttransform',
  'spreadmethod',
  'clip-path',
  'clip-rule',
  'mask',
  'marker-start',
  'marker-mid',
  'marker-end',
  'markerwidth',
  'markerheight',
  'refx',
  'refy',
  'orient',
  'dx',
  'dy',
  'text-anchor',
  'dominant-baseline',
  'font-size',
  'font-weight',
  'letter-spacing',
};

const Set<String> _svgColorAttrs = <String>{'fill', 'stroke', 'stop-color'};

const Set<String> _svgPaintOrClipAttrs = <String>{
  'fill',
  'stroke',
  'clip-path',
  'mask',
  'marker-start',
  'marker-mid',
  'marker-end',
};

String _localName(dom.Element el) => (el.localName ?? '').toLowerCase();

String _attrKeyName(Object key) {
  if (key is dom.AttributeName) {
    final prefix = key.prefix;
    if (prefix != null && prefix.isNotEmpty) {
      return '${prefix.toLowerCase()}:${key.name.toLowerCase()}';
    }
    return key.name.toLowerCase();
  }
  return key.toString().toLowerCase();
}

void _sanitizeNode(
  dom.Node node, {
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
  required bool inSvg,
}) {
  if (node is dom.Text) {
    out.write(_escapeHtmlText(node.data));
    return;
  }
  if (node is dom.Comment || node is dom.DocumentType) {
    // Strip all comments and processing instructions unconditionally.
    return;
  }
  if (node is! dom.Element) {
    return;
  }

  final tag = _localName(node);
  if (tag.isEmpty) {
    return;
  }

  // Handle `<style>`: allowed ONLY on Surface 2 outside `<svg>`.
  if (tag == 'style') {
    if (!inSvg && options.profile == SanitizeProfile.surface2Sandbox) {
      final rawCss = node.text;
      final cssResult = sanitizeCssStylesheet(rawCss);
      diagnostics.addAll(cssResult.diagnostics);
      if (cssResult.css.isNotEmpty) {
        if (cssResult.css.contains('<')) {
          diagnostics.add(
            const SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Blocked unsafe "<" sequence in compiled <style>',
              tagName: 'style',
            ),
          );
          return;
        }
        out.write('<style>');
        out.write(cssResult.css);
        out.write('</style>');
      }
      return;
    }
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedTag,
        message: 'Tag <style> is not permitted in ${options.profile.wireValue}',
        tagName: 'style',
      ),
    );
    return;
  }

  // Handle `<blink-*>` custom tags (never allowed inside `<svg>`).
  if (tag.startsWith('blink-')) {
    if (inSvg) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedTag,
          message: 'Custom tag <$tag> is not permitted inside <svg>',
          tagName: tag,
        ),
      );
      return;
    }
    _sanitizeBlinkTag(
      node,
      tag: tag,
      options: options,
      diagnostics: diagnostics,
      extractedRefs: extractedRefs,
      out: out,
    );
    return;
  }

  // Handle `<svg>` root and SVG descendants.
  if (tag == 'svg' || inSvg) {
    _sanitizeSvgElement(
      node,
      tag: tag,
      options: options,
      diagnostics: diagnostics,
      out: out,
    );
    return;
  }

  // Standard HTML5 whitelist check.
  if (!_allowedHtmlTags.contains(tag)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedTag,
        message: 'Disallowed HTML tag <$tag>',
        tagName: tag,
      ),
    );
    return;
  }

  // Enforce identical refValidator / privacy-scope checks on direct `<a href="blink-ref://...">`.
  if (tag == 'a') {
    final rawHref = _findRawHrefAttr(node);
    if (rawHref != null && rawHref.toLowerCase().startsWith('blink-ref:')) {
      _sanitizeBlinkRefAnchor(
        node,
        rawHref: rawHref,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );
      return;
    }
  }

  final cleanAttrs = _sanitizeHtmlAttributes(
    node,
    tag: tag,
    options: options,
    diagnostics: diagnostics,
  );

  // Drop `<img>` if it has no valid `blink-blob://` src.
  if (tag == 'img' && !cleanAttrs.containsKey('src')) {
    return;
  }

  _writeOpeningTag(out, tag, cleanAttrs);
  if (_htmlVoidTags.contains(tag)) {
    return;
  }
  for (final child in node.nodes) {
    _sanitizeNode(
      child,
      options: options,
      diagnostics: diagnostics,
      extractedRefs: extractedRefs,
      out: out,
      inSvg: false,
    );
  }
  out.write('</$tag>');
}

void _sanitizeSvgElement(
  dom.Element element, {
  required String tag,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  if (!_allowedSvgTags.contains(tag)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedTag,
        message: 'Disallowed SVG tag <$tag>',
        tagName: tag,
      ),
    );
    return;
  }

  if ((tag == 'text' || tag == 'tspan') &&
      options.profile != SanitizeProfile.surface2Sandbox) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.surface1SvgText,
        message:
            'SVG <$tag> on ${options.profile.wireValue} has limited CJK font/wrapping support; prefer Surface 2 or native text',
        tagName: tag,
      ),
    );
  }

  final cleanAttrs = <String, String>{};
  final rawEntries = element.attributes.entries.toList()
    ..sort((a, b) => _attrKeyName(a.key).compareTo(_attrKeyName(b.key)));

  for (final entry in rawEntries) {
    final name = _attrKeyName(entry.key);
    final value = entry.value.trim();

    if (_isEventHandlerAttr(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Inline event handler "$name" is forbidden',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }

    if (!_allowedSvgAttrs.contains(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed SVG attribute "$name" on <$tag>',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }

    if (name == 'style') {
      final cssRes = sanitizeCssInlineStyle(
        value,
        context: options.profile == SanitizeProfile.readingBlock
            ? CssSanitizeContext.readingBlockInlineStyle
            : CssSanitizeContext.inlineStyle,
        ownerTag: tag,
      );
      diagnostics.addAll(cssRes.diagnostics);
      if (cssRes.css.isNotEmpty) {
        cleanAttrs['style'] = cssRes.css;
      }
      continue;
    }

    if (name == 'xmlns') {
      if (tag == 'svg' && value == 'http://www.w3.org/2000/svg') {
        cleanAttrs['xmlns'] = value;
      } else {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.disallowedAttr,
            message: 'Disallowed xmlns value on <$tag>',
            tagName: tag,
            attributeName: 'xmlns',
          ),
        );
      }
      continue;
    }

    if (name == 'id') {
      if (_safeIdPattern.hasMatch(value)) {
        cleanAttrs['id'] = value;
      } else {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.disallowedAttr,
            message: 'Invalid id attribute on <$tag>',
            tagName: tag,
            attributeName: 'id',
          ),
        );
      }
      continue;
    }

    if (name == 'class') {
      final cleanClass = _sanitizeClassList(value);
      if (cleanClass.isNotEmpty) {
        cleanAttrs['class'] = cleanClass;
      }
      continue;
    }

    if (_svgPaintOrClipAttrs.contains(name) || _svgColorAttrs.contains(name)) {
      final validated = _validateSvgPaintOrColorAttr(
        tag: tag,
        attrName: name,
        value: value,
        allowLocalUrlRef: _svgPaintOrClipAttrs.contains(name),
        diagnostics: diagnostics,
      );
      if (validated != null) {
        cleanAttrs[_canonicalSvgAttrNames[name] ?? name] = validated;
      }
      continue;
    }

    // Catch stray `url(...)` in any other SVG attribute.
    if (_svgAnyUrlPattern.hasMatch(value)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.cssUrlBlocked,
          message: 'Blocked url(...) in SVG attribute "$name"',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }

    cleanAttrs[_canonicalSvgAttrNames[name] ?? name] = value;
  }

  final canonicalTag = _canonicalSvgTagNames[tag] ?? tag;
  _writeOpeningTag(out, canonicalTag, cleanAttrs);
  for (final child in element.nodes) {
    _sanitizeNode(
      child,
      options: options,
      diagnostics: diagnostics,
      extractedRefs: <BlinkRefTarget>[],
      out: out,
      inSvg: true,
    );
  }
  out.write('</$canonicalTag>');
}

String? _validateSvgPaintOrColorAttr({
  required String tag,
  required String attrName,
  required String value,
  required bool allowLocalUrlRef,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  if (value.isEmpty) {
    return null;
  }
  final lower = value.toLowerCase();
  if (lower == 'none' ||
      lower == 'currentcolor' ||
      lower == 'transparent' ||
      lower == 'inherit') {
    return value;
  }
  if (_blinkVarValuePattern.hasMatch(value)) {
    return value;
  }
  if (allowLocalUrlRef) {
    final localMatch = _svgLocalUrlRefPattern.firstMatch(value);
    if (localMatch != null) {
      return 'url(#${localMatch.group(1)})';
    }
  }
  if (_svgAnyUrlPattern.hasMatch(value)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.cssUrlBlocked,
        message: 'External or invalid url(...) in SVG "$attrName" is blocked',
        tagName: tag,
        attributeName: attrName,
        detail: value,
      ),
    );
    return null;
  }
  if (_rawHexColorPattern.hasMatch(value) ||
      _rawColorFnPattern.hasMatch(value) ||
      cssNamedColors.contains(lower)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.rawColorLiteral,
        message:
            'Hardcoded color "$value" in SVG "$attrName" is forbidden; use currentColor or var(--blink-*)',
        tagName: tag,
        attributeName: attrName,
        detail: value,
      ),
    );
    return null;
  }

  diagnostics.add(
    SanitizeDiagnostic(
      code: DiagnosticCode.disallowedAttr,
      message: 'Disallowed SVG "$attrName" value "$value"',
      tagName: tag,
      attributeName: attrName,
      detail: value,
    ),
  );
  return null;
}

Map<String, String> _sanitizeHtmlAttributes(
  dom.Element element, {
  required String tag,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  final cleanAttrs = <String, String>{};
  final allowedSpecific = _tagSpecificHtmlAttrs[tag] ?? const <String>{};
  final rawEntries = element.attributes.entries.toList()
    ..sort((a, b) => _attrKeyName(a.key).compareTo(_attrKeyName(b.key)));

  for (final entry in rawEntries) {
    final name = _attrKeyName(entry.key);
    final rawValue = entry.value;
    final value = rawValue.trim();

    if (_isEventHandlerAttr(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Inline event handler "$name" is forbidden',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }

    if (!_globalHtmlAttrs.contains(name) && !allowedSpecific.contains(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed attribute "$name" on <$tag>',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }

    switch (name) {
      case 'style':
        final cssRes = sanitizeCssInlineStyle(
          value,
          context: options.profile == SanitizeProfile.readingBlock
              ? CssSanitizeContext.readingBlockInlineStyle
              : CssSanitizeContext.inlineStyle,
          ownerTag: tag,
        );
        diagnostics.addAll(cssRes.diagnostics);
        if (cssRes.css.isNotEmpty) {
          cleanAttrs['style'] = cssRes.css;
        }
      case 'src':
        if (_isValidBlinkBlobUrl(value)) {
          cleanAttrs['src'] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message:
                  'Blocked non-blink-blob image src on <$tag>; only blink-blob://<64-hex-sha256> is allowed',
              tagName: tag,
              attributeName: 'src',
              detail: value,
            ),
          );
        }
      case 'href':
        if (_isValidLinkHref(value, options.profile)) {
          cleanAttrs['href'] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Blocked disallowed link href on <$tag>',
              tagName: tag,
              attributeName: 'href',
              detail: value,
            ),
          );
        }
      case 'id':
        if (_safeIdPattern.hasMatch(value)) {
          cleanAttrs['id'] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Invalid id attribute on <$tag>',
              tagName: tag,
              attributeName: 'id',
            ),
          );
        }
      case 'class':
        final cleanClass = _sanitizeClassList(value);
        if (cleanClass.isNotEmpty) {
          cleanAttrs['class'] = cleanClass;
        }
      case 'dir':
        if (value == 'ltr' || value == 'rtl' || value == 'auto') {
          cleanAttrs['dir'] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Invalid dir attribute value "$value"',
              tagName: tag,
              attributeName: 'dir',
            ),
          );
        }
      case 'aria-hidden':
        if (value == 'true' || value == 'false') {
          cleanAttrs['aria-hidden'] = value;
        }
      case 'colspan':
      case 'rowspan':
      case 'span':
        if (_positiveIntPattern.hasMatch(value)) {
          cleanAttrs[name] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Invalid numeric attribute "$name" on <$tag>',
              tagName: tag,
              attributeName: name,
            ),
          );
        }
      case 'width':
      case 'height':
        if (_nonNegIntPattern.hasMatch(value)) {
          cleanAttrs[name] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Invalid dimension attribute "$name" on <$tag>',
              tagName: tag,
              attributeName: name,
            ),
          );
        }
      case 'scope':
        if (value == 'row' ||
            value == 'col' ||
            value == 'rowgroup' ||
            value == 'colgroup') {
          cleanAttrs['scope'] = value;
        }
      case 'data-task-status':
        if (value == 'open' ||
            value == 'done' ||
            value == 'deferred' ||
            value == 'dropped') {
          cleanAttrs['data-task-status'] = value;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedAttr,
              message: 'Invalid data-task-status value "$value"',
              tagName: tag,
              attributeName: name,
            ),
          );
        }
      case 'open':
      case 'reversed':
        cleanAttrs[name] = '';
      case 'start':
      case 'value':
        if (RegExp(r'^-?[0-9]{1,6}$').hasMatch(value)) {
          cleanAttrs[name] = value;
        }
      case 'type':
        if (value == '1' ||
            value == 'a' ||
            value == 'A' ||
            value == 'i' ||
            value == 'I') {
          cleanAttrs['type'] = value;
        }
      default:
        cleanAttrs[name] = value;
    }
  }

  return cleanAttrs;
}

void _sanitizeBlinkTag(
  dom.Element element, {
  required String tag,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
}) {
  if (!_knownBlinkTags.contains(tag)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedTag,
        message: 'Unknown custom tag <$tag>',
        tagName: tag,
      ),
    );
    return;
  }

  // Producer & profile boundary enforcement per docs/design/data-and-sync.md §4.2.
  if (options.profile == SanitizeProfile.readingBlock ||
      options.producer == HtmlProducer.externalContent) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedProducerTag,
        message: 'Custom tag <$tag> is forbidden in external/readingBlock HTML',
        tagName: tag,
      ),
    );
    return;
  }

  switch (tag) {
    case 'blink-ref':
      _sanitizeBlinkRef(
        element,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );
    case 'blink-embed':
      if (options.producer != HtmlProducer.userBfm) {
        diagnostics.add(
          const SanitizeDiagnostic(
            code: DiagnosticCode.disallowedProducerTag,
            message: '<blink-embed> is restricted to user BFM and forbidden from AI producers',
            tagName: 'blink-embed',
          ),
        );
        return;
      }
      _sanitizeBlinkEmbed(element, diagnostics: diagnostics, out: out);
    case 'blink-tag':
      if (options.producer != HtmlProducer.userBfm) {
        diagnostics.add(
          const SanitizeDiagnostic(
            code: DiagnosticCode.disallowedProducerTag,
            message: '<blink-tag> is restricted to user BFM',
            tagName: 'blink-tag',
          ),
        );
        return;
      }
      _sanitizeBlinkTagElement(element, diagnostics: diagnostics, out: out);
    case 'blink-time':
      if (options.producer != HtmlProducer.userBfm) {
        diagnostics.add(
          const SanitizeDiagnostic(
            code: DiagnosticCode.disallowedProducerTag,
            message: '<blink-time> is restricted to user BFM',
            tagName: 'blink-time',
          ),
        );
        return;
      }
      _sanitizeBlinkTime(element, diagnostics: diagnostics, out: out);
    case 'blink-math':
      _sanitizeBlinkMath(element, diagnostics: diagnostics, out: out);
    default:
      if (_aiSurface1LayoutTags.contains(tag)) {
        if (options.producer != HtmlProducer.aiDerived ||
            options.profile != SanitizeProfile.surface1Native) {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedProducerTag,
              message:
                  '<$tag> is restricted to AI-derived Surface 1 (surface1_native) views',
              tagName: tag,
            ),
          );
          return;
        }
        _sanitizeAiLayoutTag(
          element,
          tag: tag,
          options: options,
          diagnostics: diagnostics,
          extractedRefs: extractedRefs,
          out: out,
        );
      }
  }
}

void _sanitizeBlinkRef(
  dom.Element element, {
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-ref',
    allowed: const <String>{'id', 'kind', 'anchor', 'data-bind'},
    diagnostics: diagnostics,
  );

  final kindRaw = attrs['kind'];
  final kind = BlinkRefKind.tryParse(kindRaw);
  if (kind == null) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-ref> requires kind in {entry, annotation, source, title_query}',
        tagName: 'blink-ref',
        attributeName: 'kind',
        detail: kindRaw,
      ),
    );
    return;
  }

  final idRaw = attrs['id'];
  String? validId;
  if (kind == BlinkRefKind.titleQuery) {
    if (idRaw != null && idRaw.isNotEmpty) {
      if (!_uuidV7Pattern.hasMatch(idRaw)) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.invalidBlinkAttr,
            message: '<blink-ref> id must be a lowercase UUIDv7',
            tagName: 'blink-ref',
            attributeName: 'id',
            detail: idRaw,
          ),
        );
        return;
      }
      validId = idRaw;
    }
  } else {
    if (idRaw == null || !_uuidV7Pattern.hasMatch(idRaw)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message:
              '<blink-ref kind="${kind.wireValue}"> requires a lowercase UUIDv7 id',
          tagName: 'blink-ref',
          attributeName: 'id',
          detail: idRaw,
        ),
      );
      return;
    }
    validId = idRaw;
  }

  final anchorRaw = attrs['anchor'];
  if (anchorRaw != null && anchorRaw.isNotEmpty) {
    if (!_blinkAnchorAttrPattern.hasMatch(anchorRaw)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-ref> anchor "$anchorRaw" does not match schema',
          tagName: 'blink-ref',
          attributeName: 'anchor',
          detail: anchorRaw,
        ),
      );
      return;
    }
  }

  final dataBindRaw = attrs['data-bind'];
  if (dataBindRaw != null) {
    if (options.producer != HtmlProducer.userBfm || dataBindRaw != 'context') {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message:
              '<blink-ref> data-bind="context" is only permitted for user BFM',
          tagName: 'blink-ref',
          attributeName: 'data-bind',
          detail: dataBindRaw,
        ),
      );
      return;
    }
  }

  final label = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-ref',
    diagnostics: diagnostics,
  );

  final target = BlinkRefTarget(
    kind: kind,
    id: validId,
    anchor: (anchorRaw != null && anchorRaw.isNotEmpty) ? anchorRaw : null,
    dataBind: dataBindRaw,
    label: label,
  );

  final validator = options.refValidator;
  if (validator != null) {
    final status = validator(target, options.privacyScope);
    switch (status) {
      case BlinkRefValidationStatus.valid:
        break;
      case BlinkRefValidationStatus.notFound:
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.brokenBlinkRef,
            message:
                'Referenced ${kind.wireValue} target "${validId ?? label}" not found',
            tagName: 'blink-ref',
            attributeName: 'id',
            detail: validId ?? label,
          ),
        );
        return;
      case BlinkRefValidationStatus.privacyScopeViolation:
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.privacyScopeViolation,
            message:
                'Referenced ${kind.wireValue} target violates ${options.privacyScope.wireValue} privacy scope',
            tagName: 'blink-ref',
            attributeName: 'id',
            detail: validId,
          ),
        );
        // Desensitize in output without leaking target title or ID.
        out.write('[private-ref]');
        return;
    }
  }

  extractedRefs.add(target);

  if (options.profile == SanitizeProfile.surface2Sandbox &&
      options.compileSurface2Refs) {
    final href = target.toSurface2Href();
    if (href != null) {
      _writeOpeningTag(out, 'a', <String, String>{
        'class': 'blink-ref',
        'href': href,
      });
      out.write(_escapeHtmlText(label));
      out.write('</a>');
    } else {
      _writeOpeningTag(out, 'span', const <String, String>{
        'class': 'blink-ref blink-ref-query',
      });
      out.write(_escapeHtmlText(label));
      out.write('</span>');
    }
    return;
  }

  final cleanAttrs = <String, String>{
    if (target.anchor != null) 'anchor': target.anchor!,
    if (target.dataBind != null) 'data-bind': target.dataBind!,
    if (target.id != null) 'id': target.id!,
    'kind': target.kind.wireValue,
  };
  _writeOpeningTag(out, 'blink-ref', cleanAttrs);
  out.write(_escapeHtmlText(label));
  out.write('</blink-ref>');
}

void _sanitizeBlinkEmbed(
  dom.Element element, {
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-embed',
    allowed: const <String>{'kind', 'id'},
    diagnostics: diagnostics,
  );
  final kind = attrs['kind'];
  final id = attrs['id'];
  if (kind != 'ai') {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-embed> requires kind="ai"',
        tagName: 'blink-embed',
        attributeName: 'kind',
        detail: kind,
      ),
    );
    return;
  }
  if (id == null || !_uuidV7Pattern.hasMatch(id)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-embed> requires a lowercase UUIDv7 id',
        tagName: 'blink-embed',
        attributeName: 'id',
        detail: id,
      ),
    );
    return;
  }
  final label = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-embed',
    diagnostics: diagnostics,
  );
  _writeOpeningTag(out, 'blink-embed', <String, String>{
    'id': id,
    'kind': 'ai',
  });
  out.write(_escapeHtmlText(label));
  out.write('</blink-embed>');
}

void _sanitizeBlinkTagElement(
  dom.Element element, {
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-tag',
    allowed: const <String>{'name', 'data-privacy'},
    diagnostics: diagnostics,
  );
  final name = attrs['name'];
  if (name == null ||
      !_blinkTagNamePattern.hasMatch(name) ||
      name.startsWith('/') ||
      name.endsWith('/') ||
      name.contains('//')) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-tag> requires valid 1..64 char tag path name',
        tagName: 'blink-tag',
        attributeName: 'name',
        detail: name,
      ),
    );
    return;
  }
  final dataPrivacy = attrs['data-privacy'];
  if (dataPrivacy != null) {
    if (name != 'private' || dataPrivacy != 'private') {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-tag> data-privacy="private" is only valid when name="private"',
          tagName: 'blink-tag',
          attributeName: 'data-privacy',
          detail: dataPrivacy,
        ),
      );
      return;
    }
  }
  final label = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-tag',
    diagnostics: diagnostics,
  );
  final cleanAttrs = <String, String>{
    'data-privacy': ?dataPrivacy,
    'name': name,
  };
  _writeOpeningTag(out, 'blink-tag', cleanAttrs);
  out.write(_escapeHtmlText(label));
  out.write('</blink-tag>');
}

void _sanitizeBlinkTime(
  dom.Element element, {
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-time',
    allowed: const <String>{'sec'},
    diagnostics: diagnostics,
  );
  final sec = attrs['sec'];
  if (sec == null || !_blinkTimeSecPattern.hasMatch(sec)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-time> requires non-negative integer sec (0..9999999)',
        tagName: 'blink-time',
        attributeName: 'sec',
        detail: sec,
      ),
    );
    return;
  }
  final label = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-time',
    diagnostics: diagnostics,
  );
  _writeOpeningTag(out, 'blink-time', <String, String>{'sec': sec});
  out.write(_escapeHtmlText(label));
  out.write('</blink-time>');
}

void _sanitizeBlinkMath(
  dom.Element element, {
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-math',
    allowed: const <String>{'display'},
    diagnostics: diagnostics,
  );
  final display = attrs['display'];
  if (display != 'inline' && display != 'block') {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-math> requires display in {inline, block}',
        tagName: 'blink-math',
        attributeName: 'display',
        detail: display,
      ),
    );
    return;
  }
  final expr = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-math',
    diagnostics: diagnostics,
  );
  _writeOpeningTag(out, 'blink-math', <String, String>{'display': display!});
  out.write(_escapeHtmlText(expr));
  out.write('</blink-math>');
}

void _sanitizeAiLayoutTag(
  dom.Element element, {
  required String tag,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
}) {
  switch (tag) {
    case 'blink-grid':
      final attrs = _extractNormalizedAttrs(
        element,
        tag: tag,
        allowed: const <String>{'cols', 'gap'},
        diagnostics: diagnostics,
      );
      final clean = <String, String>{};
      final cols = attrs['cols'];
      if (cols != null) {
        if (cols == '1' || cols == '2' || cols == '3' || cols == '4') {
          clean['cols'] = cols;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-grid> cols must be 1..4',
              tagName: tag,
              attributeName: 'cols',
              detail: cols,
            ),
          );
          return;
        }
      }
      final gap = attrs['gap'];
      if (gap != null) {
        if (gap == 'sm' || gap == 'md' || gap == 'lg') {
          clean['gap'] = gap;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-grid> gap must be sm, md, or lg',
              tagName: tag,
              attributeName: 'gap',
              detail: gap,
            ),
          );
          return;
        }
      }
      _writeElementWithSanitizedChildren(
        element,
        tag: tag,
        attrs: clean,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );

    case 'blink-card':
      final attrs = _extractNormalizedAttrs(
        element,
        tag: tag,
        allowed: const <String>{'title', 'tone', 'span'},
        diagnostics: diagnostics,
      );
      final clean = <String, String>{};
      final title = attrs['title'];
      if (title != null) {
        if (title.length > 200) {
          diagnostics.add(
            const SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-card> title exceeds 200 characters',
              tagName: 'blink-card',
              attributeName: 'title',
            ),
          );
          return;
        }
        clean['title'] = title;
      }
      final tone = attrs['tone'];
      if (tone != null) {
        const tones = <String>{
          'neutral',
          'accent',
          'insight',
          'warning',
          'ok',
          'err',
          'private',
        };
        if (tones.contains(tone)) {
          clean['tone'] = tone;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-card> invalid tone "$tone"',
              tagName: tag,
              attributeName: 'tone',
              detail: tone,
            ),
          );
          return;
        }
      }
      final span = attrs['span'];
      if (span != null) {
        if (span == '1' || span == '2') {
          clean['span'] = span;
        } else {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-card> span must be 1 or 2',
              tagName: tag,
              attributeName: 'span',
              detail: span,
            ),
          );
          return;
        }
      }
      _writeElementWithSanitizedChildren(
        element,
        tag: tag,
        attrs: clean,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );

    case 'blink-metric':
      final attrs = _extractNormalizedAttrs(
        element,
        tag: tag,
        allowed: const <String>{'label', 'value', 'unit', 'delta', 'tone'},
        diagnostics: diagnostics,
      );
      final label = attrs['label'];
      final value = attrs['value'];
      if (label == null || label.isEmpty || label.length > 120) {
        diagnostics.add(
          const SanitizeDiagnostic(
            code: DiagnosticCode.invalidBlinkAttr,
            message: '<blink-metric> requires non-empty label (<=120 chars)',
            tagName: 'blink-metric',
            attributeName: 'label',
          ),
        );
        return;
      }
      if (value == null || value.isEmpty || value.length > 64) {
        diagnostics.add(
          const SanitizeDiagnostic(
            code: DiagnosticCode.invalidBlinkAttr,
            message: '<blink-metric> requires non-empty value (<=64 chars)',
            tagName: 'blink-metric',
            attributeName: 'value',
          ),
        );
        return;
      }
      final clean = <String, String>{'label': label, 'value': value};
      final unit = attrs['unit'];
      if (unit != null) {
        if (unit.length > 32) {
          diagnostics.add(
            const SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-metric> unit exceeds 32 characters',
              tagName: 'blink-metric',
              attributeName: 'unit',
            ),
          );
          return;
        }
        clean['unit'] = unit;
      }
      final delta = attrs['delta'];
      if (delta != null) {
        if (delta.length > 32) {
          diagnostics.add(
            const SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-metric> delta exceeds 32 characters',
              tagName: 'blink-metric',
              attributeName: 'delta',
            ),
          );
          return;
        }
        clean['delta'] = delta;
      }
      final tone = attrs['tone'];
      if (tone != null) {
        const tones = <String>{'neutral', 'accent', 'ok', 'warn', 'err'};
        if (!tones.contains(tone)) {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-metric> invalid tone "$tone"',
              tagName: tag,
              attributeName: 'tone',
              detail: tone,
            ),
          );
          return;
        }
        clean['tone'] = tone;
      }
      _writeElementWithSanitizedChildren(
        element,
        tag: tag,
        attrs: clean,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );

    case 'blink-timeline':
      final attrs = _extractNormalizedAttrs(
        element,
        tag: tag,
        allowed: const <String>{'title'},
        diagnostics: diagnostics,
      );
      final clean = <String, String>{};
      final title = attrs['title'];
      if (title != null) {
        if (title.length > 200) {
          diagnostics.add(
            const SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-timeline> title exceeds 200 characters',
              tagName: 'blink-timeline',
              attributeName: 'title',
            ),
          );
          return;
        }
        clean['title'] = title;
      }
      _writeElementWithSanitizedChildren(
        element,
        tag: tag,
        attrs: clean,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );

    case 'blink-compare':
      final attrs = _extractNormalizedAttrs(
        element,
        tag: tag,
        allowed: const <String>{'left-title', 'right-title', 'tone'},
        diagnostics: diagnostics,
      );
      final clean = <String, String>{};
      for (final titleAttr in const <String>['left-title', 'right-title']) {
        final v = attrs[titleAttr];
        if (v != null) {
          if (v.length > 120) {
            diagnostics.add(
              SanitizeDiagnostic(
                code: DiagnosticCode.invalidBlinkAttr,
                message: '<blink-compare> $titleAttr exceeds 120 characters',
                tagName: tag,
                attributeName: titleAttr,
              ),
            );
            return;
          }
          clean[titleAttr] = v;
        }
      }
      final tone = attrs['tone'];
      if (tone != null) {
        const tones = <String>{'neutral', 'tension', 'evolution'};
        if (!tones.contains(tone)) {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.invalidBlinkAttr,
              message: '<blink-compare> invalid tone "$tone"',
              tagName: tag,
              attributeName: 'tone',
              detail: tone,
            ),
          );
          return;
        }
        clean['tone'] = tone;
      }
      _writeElementWithSanitizedChildren(
        element,
        tag: tag,
        attrs: clean,
        options: options,
        diagnostics: diagnostics,
        extractedRefs: extractedRefs,
        out: out,
      );

    case 'blink-chart':
      _sanitizeBlinkChart(element, diagnostics: diagnostics, out: out);
  }
}

void _sanitizeBlinkChart(
  dom.Element element, {
  required List<SanitizeDiagnostic> diagnostics,
  required StringBuffer out,
}) {
  final attrs = _extractNormalizedAttrs(
    element,
    tag: 'blink-chart',
    allowed: const <String>{'chart-type', 'data-json', 'title', 'height'},
    diagnostics: diagnostics,
  );

  final chartType = attrs['chart-type'];
  const allowedChartTypes = <String>{'line', 'bar', 'pie', 'radar'};
  if (chartType == null || !allowedChartTypes.contains(chartType)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-chart> requires chart-type in {line, bar, pie, radar}',
        tagName: 'blink-chart',
        attributeName: 'chart-type',
        detail: chartType,
      ),
    );
    return;
  }

  final rawJson = attrs['data-json'];
  if (rawJson == null || rawJson.isEmpty || rawJson.length > 32768) {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-chart> requires non-empty data-json (<= 32 KiB)',
        tagName: 'blink-chart',
        attributeName: 'data-json',
      ),
    );
    return;
  }

  final normalizedJson = _validateAndNormalizeChartJson(rawJson, diagnostics);
  if (normalizedJson == null) {
    return;
  }

  final clean = <String, String>{
    'chart-type': chartType,
    'data-json': normalizedJson,
  };

  final title = attrs['title'];
  if (title != null) {
    if (title.length > 200) {
      diagnostics.add(
        const SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-chart> title exceeds 200 characters',
          tagName: 'blink-chart',
          attributeName: 'title',
        ),
      );
      return;
    }
    clean['title'] = title;
  }

  final height = attrs['height'];
  if (height != null) {
    final parsedHeight = int.tryParse(height);
    if (parsedHeight == null || parsedHeight < 80 || parsedHeight > 600) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-chart> height must be an integer in 80..600',
          tagName: 'blink-chart',
          attributeName: 'height',
          detail: height,
        ),
      );
      return;
    }
    clean['height'] = parsedHeight.toString();
  }

  final fallbackText = _extractPlainTextOnly(
    element,
    ownerTag: 'blink-chart',
    diagnostics: diagnostics,
  );
  _writeOpeningTag(out, 'blink-chart', clean);
  out.write(_escapeHtmlText(fallbackText));
  out.write('</blink-chart>');
}

String? _validateAndNormalizeChartJson(
  String rawJson,
  List<SanitizeDiagnostic> diagnostics,
) {
  Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-chart> data-json is not valid JSON',
        tagName: 'blink-chart',
        attributeName: 'data-json',
      ),
    );
    return null;
  }

  if (decoded is! Map<String, Object?>) {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-chart> data-json must be a JSON object',
        tagName: 'blink-chart',
        attributeName: 'data-json',
      ),
    );
    return null;
  }

  if (!_validateChartObject(decoded, diagnostics, depth: 0)) {
    return null;
  }

  return jsonEncode(decoded);
}

bool _validateChartObject(
  Object? node,
  List<SanitizeDiagnostic> diagnostics, {
  required int depth,
}) {
  if (depth > 5) {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: '<blink-chart> data-json nesting exceeds limit',
        tagName: 'blink-chart',
        attributeName: 'data-json',
      ),
    );
    return false;
  }
  if (node == null || node is bool) {
    return true;
  }
  if (node is num) {
    if (!node.isFinite) {
      diagnostics.add(
        const SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-chart> data-json contains non-finite number',
          tagName: 'blink-chart',
          attributeName: 'data-json',
        ),
      );
      return false;
    }
    return true;
  }
  if (node is String) {
    if (_rawColorSubstringPattern.hasMatch(node)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.rawColorLiteral,
          message: '<blink-chart> data-json must not contain hardcoded color literals',
          tagName: 'blink-chart',
          attributeName: 'data-json',
          detail: node,
        ),
      );
      return false;
    }
    return true;
  }
  if (node is List<Object?>) {
    if (node.length > 500) {
      diagnostics.add(
        const SanitizeDiagnostic(
          code: DiagnosticCode.invalidBlinkAttr,
          message: '<blink-chart> data-json array exceeds 500 items',
          tagName: 'blink-chart',
          attributeName: 'data-json',
        ),
      );
      return false;
    }
    for (final item in node) {
      if (!_validateChartObject(item, diagnostics, depth: depth + 1)) {
        return false;
      }
    }
    return true;
  }
  if (node is Map<String, Object?>) {
    for (final entry in node.entries) {
      final keyLower = entry.key.toLowerCase();
      if (keyLower == 'color' ||
          keyLower == 'backgroundcolor' ||
          keyLower == 'bordercolor' ||
          keyLower == 'hex') {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.rawColorLiteral,
            message:
                '<blink-chart> data-json field "${entry.key}" is forbidden; chart colors come from host theme tokens',
            tagName: 'blink-chart',
            attributeName: 'data-json',
            detail: entry.key,
          ),
        );
        return false;
      }
      if (!_validateChartObject(entry.value, diagnostics, depth: depth + 1)) {
        return false;
      }
    }
    return true;
  }
  return false;
}

Map<String, String> _extractNormalizedAttrs(
  dom.Element element, {
  required String tag,
  required Set<String> allowed,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  final result = <String, String>{};
  final entries = element.attributes.entries.toList()
    ..sort((a, b) => _attrKeyName(a.key).compareTo(_attrKeyName(b.key)));

  for (final entry in entries) {
    final name = _attrKeyName(entry.key);
    final value = entry.value.trim();
    if (_isEventHandlerAttr(name) || !allowed.contains(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed attribute "$name" on <$tag>',
          tagName: tag,
          attributeName: name,
        ),
      );
      continue;
    }
    result[name] = value;
  }
  return result;
}

const Set<String> _silentDropNestedTags = <String>{
  'script',
  'style',
  'iframe',
  'object',
  'embed',
  'template',
  'foreignobject',
};

String _extractPlainTextOnly(
  dom.Element element, {
  required String ownerTag,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  final buf = StringBuffer();
  void collect(dom.Element container, {required bool reportDisallowed}) {
    for (final child in container.nodes) {
      if (child is dom.Text) {
        buf.write(child.data);
      } else if (child is dom.Element) {
        final childTag = _localName(child);
        if (reportDisallowed) {
          diagnostics.add(
            SanitizeDiagnostic(
              code: DiagnosticCode.disallowedTag,
              message:
                  'Nested HTML tag <$childTag> is not permitted inside <$ownerTag>',
              tagName: childTag,
            ),
          );
        }
        if (!_silentDropNestedTags.contains(childTag)) {
          collect(child, reportDisallowed: false);
        }
      }
    }
  }

  collect(element, reportDisallowed: true);
  return buf.toString();
}

String? _findRawHrefAttr(dom.Element element) {
  for (final entry in element.attributes.entries) {
    if (_attrKeyName(entry.key) == 'href') {
      return entry.value.trim();
    }
  }
  return null;
}

BlinkRefTarget? _tryParseBlinkRefUrl(String value, {required String label}) {
  if (_hasControlChar(value) || !_blinkRefUrlPattern.hasMatch(value)) {
    return null;
  }
  const prefix = 'blink-ref://';
  final rest = value.substring(prefix.length);
  final qIdx = rest.indexOf('?');
  final pathPart = qIdx >= 0 ? rest.substring(0, qIdx) : rest;
  final queryPart = qIdx >= 0 ? rest.substring(qIdx + 1) : null;

  final slashIdx = pathPart.indexOf('/');
  if (slashIdx <= 0) {
    return null;
  }
  final kindRaw = pathPart.substring(0, slashIdx);
  final id = pathPart.substring(slashIdx + 1);
  final kind = BlinkRefKind.tryParse(kindRaw);
  if (kind == null ||
      kind == BlinkRefKind.titleQuery ||
      !_uuidV7Pattern.hasMatch(id)) {
    return null;
  }

  String? decodedAnchor;
  if (queryPart != null) {
    if (!queryPart.startsWith('anchor=') || queryPart.contains('&')) {
      return null;
    }
    final encodedAnchor = queryPart.substring('anchor='.length);
    try {
      decodedAnchor = Uri.decodeQueryComponent(encodedAnchor);
    } on ArgumentError {
      return null;
    }
    if (!_blinkAnchorAttrPattern.hasMatch(decodedAnchor)) {
      return null;
    }
  }

  return BlinkRefTarget(
    kind: kind,
    id: id,
    anchor: decodedAnchor,
    label: label,
  );
}

void _sanitizeBlinkRefAnchor(
  dom.Element element, {
  required String rawHref,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
}) {
  if (options.profile != SanitizeProfile.surface2Sandbox ||
      options.producer == HtmlProducer.externalContent) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'blink-ref:// links are only permitted in Surface 2 views',
        tagName: 'a',
        attributeName: 'href',
        detail: rawHref,
      ),
    );
    return;
  }

  final label = _extractPlainTextOnly(
    element,
    ownerTag: 'a',
    diagnostics: diagnostics,
  );
  final target = _tryParseBlinkRefUrl(rawHref, label: label);
  if (target == null) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.invalidBlinkAttr,
        message: 'Invalid blink-ref:// link syntax or anchor in <a href>',
        tagName: 'a',
        attributeName: 'href',
        detail: rawHref,
      ),
    );
    return;
  }

  final validator = options.refValidator;
  if (validator != null) {
    final status = validator(target, options.privacyScope);
    switch (status) {
      case BlinkRefValidationStatus.valid:
        break;
      case BlinkRefValidationStatus.notFound:
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.brokenBlinkRef,
            message:
                'Referenced ${target.kind.wireValue} target "${target.id}" not found',
            tagName: 'a',
            attributeName: 'href',
            detail: target.id,
          ),
        );
        return;
      case BlinkRefValidationStatus.privacyScopeViolation:
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.privacyScopeViolation,
            message:
                'Referenced ${target.kind.wireValue} target violates ${options.privacyScope.wireValue} privacy scope',
            tagName: 'a',
            attributeName: 'href',
            detail: target.id,
          ),
        );
        out.write('[private-ref]');
        return;
    }
  }

  // Still sanitize any other attributes on `<a>` (e.g. catch `onclick`).
  final cleanAttrs = <String, String>{};
  final rawEntries = element.attributes.entries.toList()
    ..sort((a, b) => _attrKeyName(a.key).compareTo(_attrKeyName(b.key)));
  for (final entry in rawEntries) {
    final name = _attrKeyName(entry.key);
    if (name == 'href') {
      continue;
    }
    if (_isEventHandlerAttr(name) || !_globalHtmlAttrs.contains(name)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed attribute "$name" on <a>',
          tagName: 'a',
          attributeName: name,
        ),
      );
      continue;
    }
    final val = entry.value.trim();
    if (name == 'class') {
      final cleanClass = _sanitizeClassList(val);
      if (cleanClass.isNotEmpty) {
        cleanAttrs['class'] = cleanClass;
      }
    } else if (name == 'id') {
      if (_safeIdPattern.hasMatch(val)) {
        cleanAttrs['id'] = val;
      }
    } else if (name == 'style') {
      final cssRes = sanitizeCssInlineStyle(val, ownerTag: 'a');
      diagnostics.addAll(cssRes.diagnostics);
      if (cssRes.css.isNotEmpty) {
        cleanAttrs['style'] = cssRes.css;
      }
    } else {
      cleanAttrs[name] = val;
    }
  }

  extractedRefs.add(target);
  cleanAttrs['href'] = target.toSurface2Href()!;
  _writeOpeningTag(out, 'a', cleanAttrs);
  out.write(_escapeHtmlText(label));
  out.write('</a>');
}

void _writeElementWithSanitizedChildren(
  dom.Element element, {
  required String tag,
  required Map<String, String> attrs,
  required SanitizeOptions options,
  required List<SanitizeDiagnostic> diagnostics,
  required List<BlinkRefTarget> extractedRefs,
  required StringBuffer out,
}) {
  _writeOpeningTag(out, tag, attrs);
  for (final child in element.nodes) {
    _sanitizeNode(
      child,
      options: options,
      diagnostics: diagnostics,
      extractedRefs: extractedRefs,
      out: out,
      inSvg: false,
    );
  }
  out.write('</$tag>');
}

bool _isEventHandlerAttr(String lowerName) => lowerName.startsWith('on');

bool _hasControlChar(String value) {
  for (final cu in value.codeUnits) {
    if (cu <= 0x1F || cu == 0x7F) {
      return true;
    }
  }
  return false;
}

bool _isValidBlinkBlobUrl(String value) =>
    !_hasControlChar(value) && _blinkBlobUrlPattern.hasMatch(value);

bool _isValidLinkHref(String value, SanitizeProfile profile) {
  if (value.isEmpty || _hasControlChar(value)) {
    return false;
  }
  if (_safeFragmentHrefPattern.hasMatch(value)) {
    return true;
  }
  if (_blinkAnchorUrlPattern.hasMatch(value)) {
    return true;
  }
  return false;
}

String _sanitizeClassList(String raw) {
  final kept = <String>[];
  for (final token in raw.split(RegExp(r'\s+'))) {
    if (token.isNotEmpty && _safeClassTokenPattern.hasMatch(token)) {
      kept.add(token);
    }
  }
  return kept.join(' ');
}

void _writeOpeningTag(
  StringBuffer out,
  String tagName,
  Map<String, String> attrs,
) {
  out.write('<$tagName');
  if (attrs.isNotEmpty) {
    final keys = attrs.keys.toList()..sort();
    for (final key in keys) {
      final val = attrs[key]!;
      out.write(' $key="${_escapeHtmlAttr(val)}"');
    }
  }
  out.write('>');
}

String _escapeHtmlText(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _escapeHtmlAttr(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
