import 'package:meta/meta.dart';

import 'models.dart';

/// Context in which CSS is being sanitized.
enum CssSanitizeContext {
  /// Full `<style>` stylesheet block (Surface 2 sandbox only).
  surface2Stylesheet,

  /// Inline `style="..."` attribute on Surface 1 or Surface 2 elements.
  inlineStyle,

  /// Inline `style="..."` attribute on untrusted external reading blocks.
  readingBlockInlineStyle,
}

/// Token kinds emitted by [CssTokenizer] per W3C CSS Syntax Module Level 3.
enum CssTokenType {
  ident,
  function,
  atKeyword,
  hash,
  string,
  badString,
  url,
  badUrl,
  delim,
  number,
  percentage,
  dimension,
  whitespace,
  colon,
  semicolon,
  comma,
  lBracket,
  rBracket,
  lParen,
  rParen,
  lBrace,
  rBrace,
  cdo,
  cdc,
}

/// A single decoded CSS Syntax Level 3 token.
@immutable
class CssToken {
  const CssToken({
    required this.type,
    required this.value,
    this.unit = '',
    this.isIdHash = false,
  });

  final CssTokenType type;

  /// Escape-decoded token payload (e.g. identifier name, string value, number).
  final String value;

  /// Escape-decoded unit for [CssTokenType.dimension] tokens (e.g. `px`).
  final String unit;

  /// True for `<hash-token>` with type flag `"id"`.
  final bool isIdHash;

  String get lowerValue => value.toLowerCase();

  @override
  String toString() =>
      'CssToken($type, "$value"${unit.isNotEmpty ? ', unit: "$unit"' : ''})';
}

/// Result of compiling CSS through the whitelist compiler.
@immutable
class CssSanitizeResult {
  CssSanitizeResult({
    required this.css,
    List<SanitizeDiagnostic> diagnostics = const <SanitizeDiagnostic>[],
  }) : diagnostics = List<SanitizeDiagnostic>.unmodifiable(diagnostics);

  /// Clean, deterministically re-serialized CSS (empty if everything was dropped).
  final String css;

  /// Diagnostics emitted for blocked constructs, URLs, or raw colors.
  final List<SanitizeDiagnostic> diagnostics;
}

/// W3C CSS Syntax Module Level 3 tokenizer with complete hex escape decoding.
///
/// Decodes CSS escapes (e.g. `\75 rl(...)`, `\000075rl(...)`, `@\69 mport`)
/// during tokenization so downstream checks inspect canonical decoded tokens.
class CssTokenizer {
  CssTokenizer(String rawInput) : _codePoints = _preprocess(rawInput);

  final List<int> _codePoints;
  int _index = 0;

  static List<int> _preprocess(String input) {
    final result = <int>[];
    final units = input.codeUnits;
    var i = 0;
    while (i < units.length) {
      final cu = units[i];
      if (cu == 0x0D) {
        // CR or CRLF -> LF
        result.add(0x0A);
        if (i + 1 < units.length && units[i + 1] == 0x0A) {
          i += 2;
        } else {
          i += 1;
        }
      } else if (cu == 0x0C) {
        // FF -> LF
        result.add(0x0A);
        i += 1;
      } else if (cu == 0x00) {
        // NULL -> U+FFFD
        result.add(0xFFFD);
        i += 1;
      } else if (cu >= 0xD800 && cu <= 0xDBFF) {
        if (i + 1 < units.length) {
          final next = units[i + 1];
          if (next >= 0xDC00 && next <= 0xDFFF) {
            final cp = 0x10000 + ((cu - 0xD800) << 10) + (next - 0xDC00);
            result.add(cp);
            i += 2;
            continue;
          }
        }
        // Unpaired high surrogate -> U+FFFD
        result.add(0xFFFD);
        i += 1;
      } else if (cu >= 0xDC00 && cu <= 0xDFFF) {
        // Unpaired low surrogate -> U+FFFD
        result.add(0xFFFD);
        i += 1;
      } else {
        result.add(cu);
        i += 1;
      }
    }
    return result;
  }

  List<CssToken> tokenize() {
    final tokens = <CssToken>[];
    while (!_isEof) {
      _consumeComments();
      if (_isEof) {
        break;
      }
      final cp = _peek();
      if (_isWhitespace(cp)) {
        while (!_isEof && _isWhitespace(_peek())) {
          _index++;
        }
        tokens.add(const CssToken(type: CssTokenType.whitespace, value: ' '));
        continue;
      }
      if (cp == 0x22 || cp == 0x27) {
        // " or '
        tokens.add(_consumeStringToken(cp));
        continue;
      }
      if (cp == 0x23) {
        // #
        _index++;
        if (!_isEof &&
            (_isIdentCodePoint(_peek()) || _startsValidEscape(_index))) {
          final isId = _startsIdentSequence(_index);
          final name = _consumeIdentSequence();
          tokens.add(
            CssToken(type: CssTokenType.hash, value: name, isIdHash: isId),
          );
        } else {
          tokens.add(const CssToken(type: CssTokenType.delim, value: '#'));
        }
        continue;
      }
      if (cp == 0x28) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.lParen, value: '('));
        continue;
      }
      if (cp == 0x29) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.rParen, value: ')'));
        continue;
      }
      if (cp == 0x2B) {
        // +
        if (_startsNumber(_index)) {
          tokens.add(_consumeNumericToken());
        } else {
          _index++;
          tokens.add(const CssToken(type: CssTokenType.delim, value: '+'));
        }
        continue;
      }
      if (cp == 0x2C) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.comma, value: ','));
        continue;
      }
      if (cp == 0x2D) {
        // -
        if (_startsNumber(_index)) {
          tokens.add(_consumeNumericToken());
        } else if (_peekAt(1) == 0x2D && _peekAt(2) == 0x3E) {
          // -->
          _index += 3;
          tokens.add(const CssToken(type: CssTokenType.cdc, value: '-->'));
        } else if (_startsIdentSequence(_index)) {
          tokens.add(_consumeIdentLikeToken());
        } else {
          _index++;
          tokens.add(const CssToken(type: CssTokenType.delim, value: '-'));
        }
        continue;
      }
      if (cp == 0x2E) {
        // .
        if (_startsNumber(_index)) {
          tokens.add(_consumeNumericToken());
        } else {
          _index++;
          tokens.add(const CssToken(type: CssTokenType.delim, value: '.'));
        }
        continue;
      }
      if (cp == 0x3A) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.colon, value: ':'));
        continue;
      }
      if (cp == 0x3B) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.semicolon, value: ';'));
        continue;
      }
      if (cp == 0x3C) {
        // <
        if (_peekAt(1) == 0x21 && _peekAt(2) == 0x2D && _peekAt(3) == 0x2D) {
          _index += 4;
          tokens.add(const CssToken(type: CssTokenType.cdo, value: '<!--'));
        } else {
          _index++;
          tokens.add(const CssToken(type: CssTokenType.delim, value: '<'));
        }
        continue;
      }
      if (cp == 0x40) {
        // @
        _index++;
        if (_startsIdentSequence(_index)) {
          final name = _consumeIdentSequence();
          tokens.add(CssToken(type: CssTokenType.atKeyword, value: name));
        } else {
          tokens.add(const CssToken(type: CssTokenType.delim, value: '@'));
        }
        continue;
      }
      if (cp == 0x5B) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.lBracket, value: '['));
        continue;
      }
      if (cp == 0x5C) {
        // \
        if (_startsValidEscape(_index)) {
          tokens.add(_consumeIdentLikeToken());
        } else {
          _index++;
          tokens.add(const CssToken(type: CssTokenType.delim, value: r'\'));
        }
        continue;
      }
      if (cp == 0x5D) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.rBracket, value: ']'));
        continue;
      }
      if (cp == 0x7B) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.lBrace, value: '{'));
        continue;
      }
      if (cp == 0x7D) {
        _index++;
        tokens.add(const CssToken(type: CssTokenType.rBrace, value: '}'));
        continue;
      }
      if (_isDigit(cp)) {
        tokens.add(_consumeNumericToken());
        continue;
      }
      if (_isIdentStartCodePoint(cp)) {
        tokens.add(_consumeIdentLikeToken());
        continue;
      }
      _index++;
      tokens.add(
        CssToken(type: CssTokenType.delim, value: String.fromCharCode(cp)),
      );
    }
    return tokens;
  }

  bool get _isEof => _index >= _codePoints.length;

  int _peek() => _codePoints[_index];

  int _peekAt(int offset) {
    final pos = _index + offset;
    return pos < _codePoints.length ? _codePoints[pos] : -1;
  }

  void _consumeComments() {
    while (_index + 1 < _codePoints.length &&
        _codePoints[_index] == 0x2F &&
        _codePoints[_index + 1] == 0x2A) {
      _index += 2;
      while (_index < _codePoints.length) {
        if (_codePoints[_index] == 0x2A &&
            _index + 1 < _codePoints.length &&
            _codePoints[_index + 1] == 0x2F) {
          _index += 2;
          break;
        }
        _index++;
      }
    }
  }

  CssToken _consumeStringToken(int quote) {
    _index++; // skip opening quote
    final buf = StringBuffer();
    while (!_isEof) {
      final cp = _peek();
      if (cp == quote) {
        _index++;
        return CssToken(type: CssTokenType.string, value: buf.toString());
      }
      if (cp == 0x0A) {
        return CssToken(type: CssTokenType.badString, value: buf.toString());
      }
      if (cp == 0x5C) {
        _index++;
        if (_isEof) {
          break;
        }
        if (_peek() == 0x0A) {
          _index++; // escaped newline ignored
        } else {
          buf.writeCharCode(_consumeEscapedCodePoint());
        }
        continue;
      }
      buf.writeCharCode(cp);
      _index++;
    }
    return CssToken(type: CssTokenType.string, value: buf.toString());
  }

  int _consumeEscapedCodePoint() {
    if (_isEof) {
      return 0xFFFD;
    }
    final first = _peek();
    if (_isHexDigit(first)) {
      var value = 0;
      var count = 0;
      while (!_isEof && count < 6 && _isHexDigit(_peek())) {
        value = (value << 4) | _hexValue(_peek());
        _index++;
        count++;
      }
      if (!_isEof && _isWhitespace(_peek())) {
        _index++;
      }
      if (value == 0 ||
          value > 0x10FFFF ||
          (value >= 0xD800 && value <= 0xDFFF)) {
        return 0xFFFD;
      }
      return value;
    }
    _index++;
    return first;
  }

  String _consumeIdentSequence() {
    final buf = StringBuffer();
    while (!_isEof) {
      final cp = _peek();
      if (_isIdentCodePoint(cp)) {
        buf.writeCharCode(cp);
        _index++;
      } else if (_startsValidEscape(_index)) {
        _index++; // skip backslash
        buf.writeCharCode(_consumeEscapedCodePoint());
      } else {
        break;
      }
    }
    return buf.toString();
  }

  CssToken _consumeIdentLikeToken() {
    final name = _consumeIdentSequence();
    if (!_isEof && _peek() == 0x28) {
      _index++; // consume '('
      if (name.toLowerCase() == 'url') {
        var lookahead = _index;
        while (lookahead < _codePoints.length &&
            _isWhitespace(_codePoints[lookahead])) {
          lookahead++;
        }
        if (lookahead < _codePoints.length &&
            (_codePoints[lookahead] == 0x22 ||
                _codePoints[lookahead] == 0x27)) {
          return CssToken(type: CssTokenType.function, value: name);
        }
        return _consumeUrlToken();
      }
      return CssToken(type: CssTokenType.function, value: name);
    }
    return CssToken(type: CssTokenType.ident, value: name);
  }

  CssToken _consumeUrlToken() {
    while (!_isEof && _isWhitespace(_peek())) {
      _index++;
    }
    final buf = StringBuffer();
    while (!_isEof) {
      final cp = _peek();
      if (cp == 0x29) {
        _index++;
        return CssToken(type: CssTokenType.url, value: buf.toString());
      }
      if (_isWhitespace(cp)) {
        while (!_isEof && _isWhitespace(_peek())) {
          _index++;
        }
        if (_isEof) {
          return CssToken(type: CssTokenType.url, value: buf.toString());
        }
        if (_peek() == 0x29) {
          _index++;
          return CssToken(type: CssTokenType.url, value: buf.toString());
        }
        _consumeBadUrlRemnants();
        return CssToken(type: CssTokenType.badUrl, value: buf.toString());
      }
      if (cp == 0x22 || cp == 0x27 || cp == 0x28 || _isNonPrintable(cp)) {
        _consumeBadUrlRemnants();
        return CssToken(type: CssTokenType.badUrl, value: buf.toString());
      }
      if (cp == 0x5C) {
        if (_startsValidEscape(_index)) {
          _index++;
          buf.writeCharCode(_consumeEscapedCodePoint());
        } else {
          _consumeBadUrlRemnants();
          return CssToken(type: CssTokenType.badUrl, value: buf.toString());
        }
        continue;
      }
      buf.writeCharCode(cp);
      _index++;
    }
    return CssToken(type: CssTokenType.url, value: buf.toString());
  }

  void _consumeBadUrlRemnants() {
    while (!_isEof) {
      final cp = _peek();
      if (cp == 0x29) {
        _index++;
        return;
      }
      if (_startsValidEscape(_index)) {
        _index++;
        _consumeEscapedCodePoint();
      } else {
        _index++;
      }
    }
  }

  CssToken _consumeNumericToken() {
    final buf = StringBuffer();
    if (!_isEof && (_peek() == 0x2B || _peek() == 0x2D)) {
      buf.writeCharCode(_peek());
      _index++;
    }
    while (!_isEof && _isDigit(_peek())) {
      buf.writeCharCode(_peek());
      _index++;
    }
    if (_index + 1 < _codePoints.length &&
        _codePoints[_index] == 0x2E &&
        _isDigit(_codePoints[_index + 1])) {
      buf.write('.');
      _index++;
      while (!_isEof && _isDigit(_peek())) {
        buf.writeCharCode(_peek());
        _index++;
      }
    }
    if (!_isEof && (_peek() == 0x45 || _peek() == 0x65)) {
      final hasSign =
          _index + 1 < _codePoints.length &&
          (_codePoints[_index + 1] == 0x2B || _codePoints[_index + 1] == 0x2D);
      final digitPos = hasSign ? _index + 2 : _index + 1;
      if (digitPos < _codePoints.length && _isDigit(_codePoints[digitPos])) {
        buf.writeCharCode(_peek());
        _index++;
        if (hasSign) {
          buf.writeCharCode(_peek());
          _index++;
        }
        while (!_isEof && _isDigit(_peek())) {
          buf.writeCharCode(_peek());
          _index++;
        }
      }
    }
    final repr = buf.toString();
    if (_startsIdentSequence(_index)) {
      final unit = _consumeIdentSequence();
      return CssToken(type: CssTokenType.dimension, value: repr, unit: unit);
    }
    if (!_isEof && _peek() == 0x25) {
      _index++;
      return CssToken(type: CssTokenType.percentage, value: repr);
    }
    return CssToken(type: CssTokenType.number, value: repr);
  }

  bool _startsValidEscape(int pos) {
    if (pos >= _codePoints.length || _codePoints[pos] != 0x5C) {
      return false;
    }
    if (pos + 1 >= _codePoints.length) {
      return false;
    }
    return _codePoints[pos + 1] != 0x0A;
  }

  bool _startsIdentSequence(int pos) {
    if (pos >= _codePoints.length) {
      return false;
    }
    final cp = _codePoints[pos];
    if (cp == 0x2D) {
      if (pos + 1 >= _codePoints.length) {
        return false;
      }
      final next = _codePoints[pos + 1];
      return _isIdentStartCodePoint(next) ||
          next == 0x2D ||
          _startsValidEscape(pos + 1);
    }
    if (_isIdentStartCodePoint(cp)) {
      return true;
    }
    if (cp == 0x5C) {
      return _startsValidEscape(pos);
    }
    return false;
  }

  bool _startsNumber(int pos) {
    if (pos >= _codePoints.length) {
      return false;
    }
    final cp = _codePoints[pos];
    if (cp == 0x2B || cp == 0x2D) {
      if (pos + 1 >= _codePoints.length) {
        return false;
      }
      final next = _codePoints[pos + 1];
      if (_isDigit(next)) {
        return true;
      }
      return next == 0x2E &&
          pos + 2 < _codePoints.length &&
          _isDigit(_codePoints[pos + 2]);
    }
    if (cp == 0x2E) {
      return pos + 1 < _codePoints.length && _isDigit(_codePoints[pos + 1]);
    }
    return _isDigit(cp);
  }

  static bool _isWhitespace(int cp) => cp == 0x09 || cp == 0x0A || cp == 0x20;

  static bool _isDigit(int cp) => cp >= 0x30 && cp <= 0x39;

  static bool _isHexDigit(int cp) =>
      _isDigit(cp) || (cp >= 0x41 && cp <= 0x46) || (cp >= 0x61 && cp <= 0x66);

  static int _hexValue(int cp) {
    if (cp >= 0x30 && cp <= 0x39) return cp - 0x30;
    if (cp >= 0x41 && cp <= 0x46) return cp - 0x41 + 10;
    return cp - 0x61 + 10;
  }

  static bool _isIdentStartCodePoint(int cp) =>
      (cp >= 0x41 && cp <= 0x5A) ||
      (cp >= 0x61 && cp <= 0x7A) ||
      cp == 0x5F ||
      cp >= 0x80;

  static bool _isIdentCodePoint(int cp) =>
      _isIdentStartCodePoint(cp) || _isDigit(cp) || cp == 0x2D;

  static bool _isNonPrintable(int cp) =>
      (cp >= 0x00 && cp <= 0x08) ||
      cp == 0x0B ||
      (cp >= 0x0E && cp <= 0x1F) ||
      cp == 0x7F;
}

/// Sanitizes an inline `style="..."` attribute value.
CssSanitizeResult sanitizeCssInlineStyle(
  String rawCss, {
  CssSanitizeContext context = CssSanitizeContext.inlineStyle,
  String? ownerTag,
}) {
  final tokens = CssTokenizer(rawCss).tokenize();
  final diagnostics = <SanitizeDiagnostic>[];
  final compiled = _compileDeclarationList(
    tokens,
    context: context,
    diagnostics: diagnostics,
    ownerTag: ownerTag,
  );
  return CssSanitizeResult(css: compiled, diagnostics: diagnostics);
}

/// Sanitizes a Surface 2 `<style>` stylesheet block.
CssSanitizeResult sanitizeCssStylesheet(String rawCss) {
  final tokens = CssTokenizer(rawCss).tokenize();
  final diagnostics = <SanitizeDiagnostic>[];
  final compiled = _compileRuleList(tokens, diagnostics: diagnostics, depth: 0);
  // Defense-in-depth: compiled CSS must never contain `<` (prevents `</style>` breakout).
  if (compiled.contains('<')) {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'Compiled CSS stylesheet rejected due to disallowed "<" token',
        tagName: 'style',
      ),
    );
    return CssSanitizeResult(css: '', diagnostics: diagnostics);
  }
  return CssSanitizeResult(css: compiled, diagnostics: diagnostics);
}

const int _maxCssNestingDepth = 4;

const Set<String> _blockedCssProperties = <String>{
  'behavior',
  '-moz-binding',
  'binding',
  '-o-link',
  '-o-link-source',
  'src',
};

const Set<String> _blockedUrlFunctions = <String>{
  'url',
  'src',
  'image-set',
  '-webkit-image-set',
  'cross-fade',
  'element',
  'expression',
  'paint',
};

const Set<String> _rawColorFunctions = <String>{
  'rgb',
  'rgba',
  'hsl',
  'hsla',
  'hwb',
  'lab',
  'lch',
  'oklab',
  'oklch',
  'color',
  'device-cmyk',
  'gray',
};

const Set<String> _allowedValueFunctions = <String>{
  'var',
  'calc',
  'min',
  'max',
  'clamp',
  'minmax',
  'repeat',
  'fit-content',
  'linear-gradient',
  'radial-gradient',
  'conic-gradient',
  'repeating-linear-gradient',
  'repeating-radial-gradient',
  'color-mix',
  'translate',
  'translatex',
  'translatey',
  'scale',
  'scalex',
  'scaley',
  'rotate',
  'skew',
  'skewx',
  'skewy',
  'blur',
  'opacity',
  'brightness',
  'contrast',
  'cubic-bezier',
  'steps',
  'counter',
  'counters',
};

const Set<String> _allowedAtRules = <String>{
  'media',
  'supports',
  'container',
  'layer',
  'keyframes',
};

const Set<String> _blockedUrlAtRules = <String>{
  'import',
  'font-face',
  'namespace',
  'document',
  '-moz-document',
};

const Set<String> _allowedReadingBlockProperties = <String>{
  'text-align',
  'vertical-align',
  'font-weight',
  'font-style',
  'text-decoration',
  'text-decoration-line',
  'white-space',
  'list-style-type',
  'width',
  'max-width',
  'border-collapse',
  'margin',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'padding',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
};

const Set<String> _allowedStandardProperties = <String>{
  // Layout & box
  'display',
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'inset',
  'z-index',
  'box-sizing',
  'width',
  'min-width',
  'max-width',
  'height',
  'min-height',
  'max-height',
  'aspect-ratio',
  'overflow',
  'overflow-x',
  'overflow-y',
  'visibility',
  'opacity',
  'float',
  'clear',
  'vertical-align',
  'object-fit',
  'object-position',
  // Spacing
  'margin',
  'margin-top',
  'margin-right',
  'margin-bottom',
  'margin-left',
  'margin-inline',
  'margin-block',
  'padding',
  'padding-top',
  'padding-right',
  'padding-bottom',
  'padding-left',
  'padding-inline',
  'padding-block',
  'gap',
  'row-gap',
  'column-gap',
  // Flex & Grid
  'flex',
  'flex-direction',
  'flex-wrap',
  'flex-flow',
  'flex-grow',
  'flex-shrink',
  'flex-basis',
  'justify-content',
  'justify-items',
  'justify-self',
  'align-items',
  'align-content',
  'align-self',
  'place-items',
  'place-content',
  'place-self',
  'order',
  'grid',
  'grid-template',
  'grid-template-columns',
  'grid-template-rows',
  'grid-template-areas',
  'grid-auto-columns',
  'grid-auto-rows',
  'grid-auto-flow',
  'grid-column',
  'grid-column-start',
  'grid-column-end',
  'grid-row',
  'grid-row-start',
  'grid-row-end',
  'grid-area',
  // Typography
  'color',
  'font',
  'font-family',
  'font-size',
  'font-weight',
  'font-style',
  'font-variant',
  'font-variant-numeric',
  'line-height',
  'letter-spacing',
  'word-spacing',
  'text-align',
  'text-decoration',
  'text-decoration-line',
  'text-decoration-style',
  'text-decoration-color',
  'text-decoration-thickness',
  'text-underline-offset',
  'text-transform',
  'text-indent',
  'text-overflow',
  'text-wrap',
  'white-space',
  'word-break',
  'overflow-wrap',
  'word-wrap',
  'hyphens',
  'list-style',
  'list-style-type',
  'list-style-position',
  'quotes',
  'direction',
  'writing-mode',
  'tab-size',
  // Visual & borders
  'background',
  'background-color',
  'background-image',
  'background-clip',
  'background-size',
  'background-position',
  'background-repeat',
  'border',
  'border-top',
  'border-right',
  'border-bottom',
  'border-left',
  'border-width',
  'border-style',
  'border-color',
  'border-top-width',
  'border-top-style',
  'border-top-color',
  'border-right-width',
  'border-right-style',
  'border-right-color',
  'border-bottom-width',
  'border-bottom-style',
  'border-bottom-color',
  'border-left-width',
  'border-left-style',
  'border-left-color',
  'border-radius',
  'border-top-left-radius',
  'border-top-right-radius',
  'border-bottom-left-radius',
  'border-bottom-right-radius',
  'border-collapse',
  'border-spacing',
  'outline',
  'outline-width',
  'outline-style',
  'outline-color',
  'outline-offset',
  'box-shadow',
  'text-shadow',
  'accent-color',
  'caret-color',
  'mix-blend-mode',
  'filter',
  'backdrop-filter',
  // Tables & columns
  'table-layout',
  'caption-side',
  'empty-cells',
  'columns',
  'column-count',
  'column-width',
  'column-rule',
  'column-rule-width',
  'column-rule-style',
  'column-rule-color',
  'break-inside',
  'break-before',
  'break-after',
  'page-break-inside',
  // SVG presentation
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
  'stop-color',
  'stop-opacity',
  'vector-effect',
  'paint-order',
  'text-anchor',
  'dominant-baseline',
  'shape-rendering',
  // Misc safe
  'transform',
  'transform-origin',
  'transition',
  'animation',
  'animation-name',
  'animation-duration',
  'animation-timing-function',
  'animation-delay',
  'animation-iteration-count',
  'animation-direction',
  'animation-fill-mode',
  'cursor',
  'user-select',
  'pointer-events',
  'content',
  'counter-reset',
  'counter-increment',
};

const Set<String> _nonColorIdentProperties = <String>{
  'font-family',
  'grid-area',
  'grid-template-areas',
  'animation-name',
  'content',
  'counter-reset',
  'counter-increment',
};

final RegExp _blinkCssVarPattern = RegExp(r'^--blink-[a-z0-9-]+$');

final RegExp _dangerousSchemePattern = RegExp(
  r'(?:javascript|vbscript)\s*:|data\s*:\s*(?:text/html|image/svg\+xml|application/xhtml)',
  caseSensitive: false,
);

/// Complete CSS Color Module Level 4 named color set (148 colors).
const Set<String> cssNamedColors = <String>{
  'aliceblue',
  'antiquewhite',
  'aqua',
  'aquamarine',
  'azure',
  'beige',
  'bisque',
  'black',
  'blanchedalmond',
  'blue',
  'blueviolet',
  'brown',
  'burlywood',
  'cadetblue',
  'chartreuse',
  'chocolate',
  'coral',
  'cornflowerblue',
  'cornsilk',
  'crimson',
  'cyan',
  'darkblue',
  'darkcyan',
  'darkgoldenrod',
  'darkgray',
  'darkgreen',
  'darkgrey',
  'darkkhaki',
  'darkmagenta',
  'darkolivegreen',
  'darkorange',
  'darkorchid',
  'darkred',
  'darksalmon',
  'darkseagreen',
  'darkslateblue',
  'darkslategray',
  'darkslategrey',
  'darkturquoise',
  'darkviolet',
  'deeppink',
  'deepskyblue',
  'dimgray',
  'dimgrey',
  'dodgerblue',
  'firebrick',
  'floralwhite',
  'forestgreen',
  'fuchsia',
  'gainsboro',
  'ghostwhite',
  'gold',
  'goldenrod',
  'gray',
  'green',
  'greenyellow',
  'grey',
  'honeydew',
  'hotpink',
  'indianred',
  'indigo',
  'ivory',
  'khaki',
  'lavender',
  'lavenderblush',
  'lawngreen',
  'lemonchiffon',
  'lightblue',
  'lightcoral',
  'lightcyan',
  'lightgoldenrodyellow',
  'lightgray',
  'lightgreen',
  'lightgrey',
  'lightpink',
  'lightsalmon',
  'lightseagreen',
  'lightskyblue',
  'lightslategray',
  'lightslategrey',
  'lightsteelblue',
  'lightyellow',
  'lime',
  'limegreen',
  'linen',
  'magenta',
  'maroon',
  'mediumaquamarine',
  'mediumblue',
  'mediumorchid',
  'mediumpurple',
  'mediumseagreen',
  'mediumslateblue',
  'mediumspringgreen',
  'mediumturquoise',
  'mediumvioletred',
  'midnightblue',
  'mintcream',
  'mistyrose',
  'moccasin',
  'navajowhite',
  'navy',
  'oldlace',
  'olive',
  'olivedrab',
  'orange',
  'orangered',
  'orchid',
  'palegoldenrod',
  'palegreen',
  'paleturquoise',
  'palevioletred',
  'papayawhip',
  'peachpuff',
  'peru',
  'pink',
  'plum',
  'powderblue',
  'purple',
  'rebeccapurple',
  'red',
  'rosybrown',
  'royalblue',
  'saddlebrown',
  'salmon',
  'sandybrown',
  'seagreen',
  'seashell',
  'sienna',
  'silver',
  'skyblue',
  'slateblue',
  'slategray',
  'slategrey',
  'snow',
  'springgreen',
  'steelblue',
  'tan',
  'teal',
  'thistle',
  'tomato',
  'turquoise',
  'violet',
  'wheat',
  'white',
  'whitesmoke',
  'yellow',
  'yellowgreen',
};

String _compileRuleList(
  List<CssToken> tokens, {
  required List<SanitizeDiagnostic> diagnostics,
  required int depth,
  bool isKeyframesBody = false,
}) {
  if (depth > _maxCssNestingDepth) {
    diagnostics.add(
      const SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'CSS nesting depth exceeded maximum allowed limit',
        tagName: 'style',
      ),
    );
    return '';
  }

  final outRules = <String>[];
  var i = 0;

  while (i < tokens.length) {
    while (i < tokens.length &&
        (tokens[i].type == CssTokenType.whitespace ||
            tokens[i].type == CssTokenType.cdo ||
            tokens[i].type == CssTokenType.cdc ||
            tokens[i].type == CssTokenType.semicolon)) {
      i++;
    }
    if (i >= tokens.length) {
      break;
    }

    final token = tokens[i];
    if (token.type == CssTokenType.atKeyword) {
      final atName = token.lowerValue;
      i++;
      final prelude = <CssToken>[];
      var foundBlock = false;
      var blockTokens = <CssToken>[];

      while (i < tokens.length) {
        final cur = tokens[i];
        if (cur.type == CssTokenType.semicolon) {
          i++;
          break;
        }
        if (cur.type == CssTokenType.lBrace) {
          foundBlock = true;
          final end = _findMatchingBrace(tokens, i);
          blockTokens = tokens.sublist(i + 1, end);
          i = end < tokens.length ? end + 1 : tokens.length;
          break;
        }
        prelude.add(cur);
        i++;
      }

      if (_blockedUrlAtRules.contains(atName)) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.cssUrlBlocked,
            message: 'Disallowed CSS at-rule @$atName',
            tagName: 'style',
            detail: '@$atName',
          ),
        );
        continue;
      }

      if (!_allowedAtRules.contains(atName) || !foundBlock) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.disallowedAttr,
            message: 'Unsupported CSS at-rule @$atName',
            tagName: 'style',
            detail: '@$atName',
          ),
        );
        continue;
      }

      final preludeSafe = _validateAndSerializePrelude(
        prelude,
        atName: atName,
        diagnostics: diagnostics,
      );
      if (preludeSafe == null) {
        continue;
      }

      final compiledBody = _compileRuleList(
        blockTokens,
        diagnostics: diagnostics,
        depth: depth + 1,
        isKeyframesBody: atName == 'keyframes',
      );
      if (compiledBody.isNotEmpty) {
        outRules.add('@$atName $preludeSafe { $compiledBody }');
      }
      continue;
    }

    // Qualified rule: prelude up to `{`
    final prelude = <CssToken>[];
    var foundBrace = false;
    while (i < tokens.length) {
      final cur = tokens[i];
      if (cur.type == CssTokenType.lBrace) {
        foundBrace = true;
        break;
      }
      if (cur.type == CssTokenType.semicolon) {
        i++;
        break;
      }
      prelude.add(cur);
      i++;
    }
    if (!foundBrace) {
      break;
    }

    final blockEnd = _findMatchingBrace(tokens, i);
    final blockTokens = tokens.sublist(i + 1, blockEnd);
    i = blockEnd < tokens.length ? blockEnd + 1 : tokens.length;

    final selector = _validateAndSerializeSelector(
      prelude,
      isKeyframes: isKeyframesBody,
      diagnostics: diagnostics,
    );
    if (selector == null || selector.isEmpty) {
      continue;
    }

    final decls = _compileDeclarationList(
      blockTokens,
      context: CssSanitizeContext.surface2Stylesheet,
      diagnostics: diagnostics,
      ownerTag: 'style',
    );
    if (decls.isNotEmpty) {
      outRules.add('$selector { $decls }');
    }
  }

  return outRules.join('\n');
}

int _findMatchingBrace(List<CssToken> tokens, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < tokens.length; i++) {
    if (tokens[i].type == CssTokenType.lBrace) {
      depth++;
    } else if (tokens[i].type == CssTokenType.rBrace) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return tokens.length;
}

String? _validateAndSerializePrelude(
  List<CssToken> prelude, {
  required String atName,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  final trimmed = _trimWhitespace(prelude);
  if (trimmed.isEmpty) {
    return null;
  }
  if (_containsBlockedUrlOrScheme(trimmed, diagnostics, ownerTag: 'style')) {
    return null;
  }
  for (final token in trimmed) {
    if (token.type == CssTokenType.badString ||
        token.type == CssTokenType.badUrl ||
        token.type == CssTokenType.atKeyword ||
        token.type == CssTokenType.cdo ||
        token.type == CssTokenType.cdc ||
        (token.type == CssTokenType.delim && token.value == '<')) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Malformed token in @$atName prelude',
          tagName: 'style',
        ),
      );
      return null;
    }
  }
  return _serializeTokenList(trimmed);
}

String? _validateAndSerializeSelector(
  List<CssToken> prelude, {
  required bool isKeyframes,
  required List<SanitizeDiagnostic> diagnostics,
}) {
  final trimmed = _trimWhitespace(prelude);
  if (trimmed.isEmpty) {
    return null;
  }
  if (_containsBlockedUrlOrScheme(trimmed, diagnostics, ownerTag: 'style')) {
    return null;
  }

  for (final token in trimmed) {
    if (token.type == CssTokenType.badString ||
        token.type == CssTokenType.badUrl ||
        token.type == CssTokenType.cdo ||
        token.type == CssTokenType.cdc) {
      diagnostics.add(
        const SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Malformed CSS selector token rejected',
          tagName: 'style',
        ),
      );
      return null;
    }
    if (token.type == CssTokenType.delim && token.value == '<') {
      diagnostics.add(
        const SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed character in CSS selector',
          tagName: 'style',
        ),
      );
      return null;
    }
    if (isKeyframes) {
      if (token.type != CssTokenType.ident &&
          token.type != CssTokenType.percentage &&
          token.type != CssTokenType.comma &&
          token.type != CssTokenType.whitespace) {
        return null;
      }
      if (token.type == CssTokenType.ident &&
          token.lowerValue != 'from' &&
          token.lowerValue != 'to') {
        return null;
      }
    }
  }

  return _serializeTokenList(trimmed);
}

String _compileDeclarationList(
  List<CssToken> tokens, {
  required CssSanitizeContext context,
  required List<SanitizeDiagnostic> diagnostics,
  String? ownerTag,
}) {
  final outDecls = <String>[];
  final chunks = _splitDeclarations(tokens);

  for (final chunk in chunks) {
    final trimmed = _trimWhitespace(chunk);
    if (trimmed.isEmpty) {
      continue;
    }

    // Detect stray at-rules inside inline styles (e.g. `@import url(...)`)
    if (trimmed.first.type == CssTokenType.atKeyword) {
      final atName = trimmed.first.lowerValue;
      diagnostics.add(
        SanitizeDiagnostic(
          code: _blockedUrlAtRules.contains(atName)
              ? DiagnosticCode.cssUrlBlocked
              : DiagnosticCode.disallowedAttr,
          message: 'Disallowed CSS at-rule @$atName in declaration list',
          tagName: ownerTag,
          attributeName: ownerTag == 'style' ? null : 'style',
          detail: '@$atName',
        ),
      );
      continue;
    }

    final colonIdx = trimmed.indexWhere((t) => t.type == CssTokenType.colon);
    if (colonIdx <= 0) {
      // Even in malformed fragments, still scan for blocked URLs/expressions.
      _containsBlockedUrlOrScheme(trimmed, diagnostics, ownerTag: ownerTag);
      continue;
    }

    final propTokens = _trimWhitespace(trimmed.sublist(0, colonIdx));
    final valueTokens = _trimWhitespace(trimmed.sublist(colonIdx + 1));

    if (propTokens.length != 1 || propTokens.first.type != CssTokenType.ident) {
      _containsBlockedUrlOrScheme(valueTokens, diagnostics, ownerTag: ownerTag);
      continue;
    }

    final propName = propTokens.first.lowerValue;
    if (valueTokens.isEmpty) {
      continue;
    }

    // Check explicitly dangerous CSS properties first (`behavior`, `-moz-binding`)
    if (_blockedCssProperties.contains(propName)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.cssUrlBlocked,
          message: 'Blocked dangerous CSS property "$propName"',
          tagName: ownerTag,
          attributeName: ownerTag == 'style' ? null : 'style',
          detail: propName,
        ),
      );
      continue;
    }

    // Reject custom property redefinitions (host owns `--blink-*`, prevents color smuggling)
    if (propName.startsWith('--')) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message:
              'Custom CSS property declarations are not permitted: $propName',
          tagName: ownerTag,
          attributeName: ownerTag == 'style' ? null : 'style',
          detail: propName,
        ),
      );
      continue;
    }

    // Always inspect value for URLs / expressions / raw colors before property drop
    // so callers get precise security diagnostics.
    final hasBlockedUrl = _containsBlockedUrlOrScheme(
      valueTokens,
      diagnostics,
      ownerTag: ownerTag,
      propertyName: propName,
    );
    if (hasBlockedUrl) {
      continue;
    }

    final allowedProps = context == CssSanitizeContext.readingBlockInlineStyle
        ? _allowedReadingBlockProperties
        : _allowedStandardProperties;

    if (!allowedProps.contains(propName)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Disallowed CSS property "$propName"',
          tagName: ownerTag,
          attributeName: ownerTag == 'style' ? null : 'style',
          detail: propName,
        ),
      );
      continue;
    }

    // Disallow `position: fixed` to prevent overlaying host UI chrome.
    if (propName == 'position' &&
        valueTokens.any(
          (t) => t.type == CssTokenType.ident && t.lowerValue == 'fixed',
        )) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'CSS position: fixed is not permitted',
          tagName: ownerTag,
          attributeName: ownerTag == 'style' ? null : 'style',
          detail: 'position: fixed',
        ),
      );
      continue;
    }

    final validatedValue = _validateAndSerializeValue(
      valueTokens,
      propertyName: propName,
      diagnostics: diagnostics,
      ownerTag: ownerTag,
    );
    if (validatedValue != null && validatedValue.isNotEmpty) {
      outDecls.add('$propName: $validatedValue');
    }
  }

  return outDecls.join('; ');
}

List<List<CssToken>> _splitDeclarations(List<CssToken> tokens) {
  final chunks = <List<CssToken>>[];
  var current = <CssToken>[];
  var parenDepth = 0;
  var bracketDepth = 0;

  for (final token in tokens) {
    if (token.type == CssTokenType.lParen ||
        token.type == CssTokenType.function) {
      parenDepth++;
    } else if (token.type == CssTokenType.rParen && parenDepth > 0) {
      parenDepth--;
    } else if (token.type == CssTokenType.lBracket) {
      bracketDepth++;
    } else if (token.type == CssTokenType.rBracket && bracketDepth > 0) {
      bracketDepth--;
    }

    if (token.type == CssTokenType.semicolon &&
        parenDepth == 0 &&
        bracketDepth == 0) {
      chunks.add(current);
      current = <CssToken>[];
    } else {
      current.add(token);
    }
  }
  if (current.isNotEmpty) {
    chunks.add(current);
  }
  return chunks;
}

bool _containsBlockedUrlOrScheme(
  List<CssToken> tokens,
  List<SanitizeDiagnostic> diagnostics, {
  String? ownerTag,
  String? propertyName,
}) {
  final attrName = ownerTag == 'style' ? null : 'style';

  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.type == CssTokenType.url || token.type == CssTokenType.badUrl) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.cssUrlBlocked,
          message: 'CSS url(...) is blocked',
          tagName: ownerTag,
          attributeName: attrName,
          detail: propertyName ?? 'url',
        ),
      );
      return true;
    }

    if (token.type == CssTokenType.function &&
        _blockedUrlFunctions.contains(token.lowerValue)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.cssUrlBlocked,
          message: 'Blocked CSS function ${token.lowerValue}(...)',
          tagName: ownerTag,
          attributeName: attrName,
          detail: token.lowerValue,
        ),
      );
      return true;
    }

    // Catch comment/space-split attempts like `url/*x*/(...)` or `expression (...)`.
    if (token.type == CssTokenType.ident &&
        _blockedUrlFunctions.contains(token.lowerValue)) {
      var nextIdx = i + 1;
      while (nextIdx < tokens.length &&
          tokens[nextIdx].type == CssTokenType.whitespace) {
        nextIdx++;
      }
      if (nextIdx < tokens.length &&
          tokens[nextIdx].type == CssTokenType.lParen) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.cssUrlBlocked,
            message: 'Blocked CSS function ${token.lowerValue}(...)',
            tagName: ownerTag,
            attributeName: attrName,
            detail: token.lowerValue,
          ),
        );
        return true;
      }
    }

    if (token.type == CssTokenType.string ||
        token.type == CssTokenType.badString) {
      final compact = _stripAsciiControlAndSpace(token.value);
      if (_dangerousSchemePattern.hasMatch(compact)) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.cssUrlBlocked,
            message: 'Blocked dangerous URI scheme inside CSS string',
            tagName: ownerTag,
            attributeName: attrName,
            detail: propertyName,
          ),
        );
        return true;
      }
    }

    // Check unquoted `javascript:` / `data:text/html` sequences in token stream
    if (token.type == CssTokenType.ident &&
        (token.lowerValue == 'javascript' || token.lowerValue == 'vbscript')) {
      var nextIdx = i + 1;
      while (nextIdx < tokens.length &&
          tokens[nextIdx].type == CssTokenType.whitespace) {
        nextIdx++;
      }
      if (nextIdx < tokens.length &&
          tokens[nextIdx].type == CssTokenType.colon) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.cssUrlBlocked,
            message: 'Blocked ${token.lowerValue}: scheme in CSS',
            tagName: ownerTag,
            attributeName: attrName,
            detail: propertyName,
          ),
        );
        return true;
      }
    }
  }
  return false;
}

String? _validateAndSerializeValue(
  List<CssToken> tokens, {
  required String propertyName,
  required List<SanitizeDiagnostic> diagnostics,
  String? ownerTag,
}) {
  final attrName = ownerTag == 'style' ? null : 'style';
  final checkNamedColors = !_nonColorIdentProperties.contains(propertyName);
  var i = 0;

  while (i < tokens.length) {
    final token = tokens[i];

    if (token.type == CssTokenType.badString ||
        token.type == CssTokenType.badUrl ||
        token.type == CssTokenType.lBrace ||
        token.type == CssTokenType.rBrace ||
        token.type == CssTokenType.atKeyword ||
        token.type == CssTokenType.cdo ||
        token.type == CssTokenType.cdc ||
        (token.type == CssTokenType.delim &&
            (token.value == '<' || token.value == '>'))) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.disallowedAttr,
          message: 'Malformed token in CSS value for "$propertyName"',
          tagName: ownerTag,
          attributeName: attrName,
          detail: propertyName,
        ),
      );
      return null;
    }

    // Hardcoded hex colors (`#fff`, `#1e60d5`, `#11223344`)
    if (token.type == CssTokenType.hash) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.rawColorLiteral,
          message:
              'Hardcoded hex color "#${token.value}" is forbidden; use var(--blink-*)',
          tagName: ownerTag,
          attributeName: attrName,
          detail: '#${token.value}',
        ),
      );
      return null;
    }

    // Hardcoded color functions (`rgb()`, `rgba()`, `hsl()`, `hsla()`, ...)
    if (token.type == CssTokenType.function) {
      final fnName = token.lowerValue;
      if (_rawColorFunctions.contains(fnName)) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.rawColorLiteral,
            message:
                'Hardcoded color function "$fnName(...)" is forbidden; use var(--blink-*)',
            tagName: ownerTag,
            attributeName: attrName,
            detail: fnName,
          ),
        );
        return null;
      }

      if (!_allowedValueFunctions.contains(fnName)) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.disallowedAttr,
            message: 'Disallowed CSS function "$fnName(...)"',
            tagName: ownerTag,
            attributeName: attrName,
            detail: fnName,
          ),
        );
        return null;
      }

      final closeIdx = _findMatchingParen(tokens, i);
      if (closeIdx >= tokens.length) {
        diagnostics.add(
          SanitizeDiagnostic(
            code: DiagnosticCode.disallowedAttr,
            message: 'Unclosed CSS function "$fnName("',
            tagName: ownerTag,
            attributeName: attrName,
            detail: fnName,
          ),
        );
        return null;
      }

      final argTokens = tokens.sublist(i + 1, closeIdx);
      if (fnName == 'var') {
        if (!_validateVarFunctionArgs(
          argTokens,
          propertyName: propertyName,
          diagnostics: diagnostics,
          ownerTag: ownerTag,
        )) {
          return null;
        }
      } else {
        // Recursively validate inner function arguments (catches nested rgb/#hex/url).
        final inner = _validateAndSerializeValue(
          argTokens,
          propertyName: propertyName,
          diagnostics: diagnostics,
          ownerTag: ownerTag,
        );
        if (inner == null) {
          return null;
        }
      }
      i = closeIdx + 1;
      continue;
    }

    // Named CSS colors (`red`, `white`, `black`, ...)
    if (checkNamedColors &&
        token.type == CssTokenType.ident &&
        cssNamedColors.contains(token.lowerValue)) {
      diagnostics.add(
        SanitizeDiagnostic(
          code: DiagnosticCode.rawColorLiteral,
          message:
              'Hardcoded color name "${token.value}" is forbidden; use var(--blink-*)',
          tagName: ownerTag,
          attributeName: attrName,
          detail: token.lowerValue,
        ),
      );
      return null;
    }

    i++;
  }

  return _serializeTokenList(tokens);
}

bool _validateVarFunctionArgs(
  List<CssToken> argTokens, {
  required String propertyName,
  required List<SanitizeDiagnostic> diagnostics,
  String? ownerTag,
}) {
  final attrName = ownerTag == 'style' ? null : 'style';
  final trimmed = _trimWhitespace(argTokens);
  if (trimmed.isEmpty || trimmed.first.type != CssTokenType.ident) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'CSS var() must reference a --blink-* token',
        tagName: ownerTag,
        attributeName: attrName,
        detail: propertyName,
      ),
    );
    return false;
  }

  final varName = trimmed.first.value;
  if (!_blinkCssVarPattern.hasMatch(varName)) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message:
            'CSS var($varName) is not a permitted host semantic token (--blink-*)',
        tagName: ownerTag,
        attributeName: attrName,
        detail: varName,
      ),
    );
    return false;
  }

  // Remaining tokens, if any, must start with `,` followed by a valid fallback.
  var restIdx = 1;
  while (restIdx < trimmed.length &&
      trimmed[restIdx].type == CssTokenType.whitespace) {
    restIdx++;
  }
  if (restIdx == trimmed.length) {
    return true;
  }
  if (trimmed[restIdx].type != CssTokenType.comma) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'Malformed fallback in CSS var($varName)',
        tagName: ownerTag,
        attributeName: attrName,
        detail: varName,
      ),
    );
    return false;
  }

  final fallbackTokens = _trimWhitespace(trimmed.sublist(restIdx + 1));
  if (fallbackTokens.isEmpty) {
    diagnostics.add(
      SanitizeDiagnostic(
        code: DiagnosticCode.disallowedAttr,
        message: 'Empty fallback in CSS var($varName)',
        tagName: ownerTag,
        attributeName: attrName,
        detail: varName,
      ),
    );
    return false;
  }
  if (_containsBlockedUrlOrScheme(
    fallbackTokens,
    diagnostics,
    ownerTag: ownerTag,
    propertyName: propertyName,
  )) {
    return false;
  }
  final fallbackSerialized = _validateAndSerializeValue(
    fallbackTokens,
    propertyName: propertyName,
    diagnostics: diagnostics,
    ownerTag: ownerTag,
  );
  return fallbackSerialized != null;
}

int _findMatchingParen(List<CssToken> tokens, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < tokens.length; i++) {
    final t = tokens[i].type;
    if (t == CssTokenType.function || t == CssTokenType.lParen) {
      depth++;
    } else if (t == CssTokenType.rParen) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return tokens.length;
}

List<CssToken> _trimWhitespace(List<CssToken> tokens) {
  var start = 0;
  var end = tokens.length;
  while (start < end && tokens[start].type == CssTokenType.whitespace) {
    start++;
  }
  while (end > start && tokens[end - 1].type == CssTokenType.whitespace) {
    end--;
  }
  return tokens.sublist(start, end);
}

String _stripAsciiControlAndSpace(String input) {
  final buf = StringBuffer();
  for (final cu in input.codeUnits) {
    if (cu > 0x20 && cu != 0x7F) {
      buf.writeCharCode(cu);
    }
  }
  return buf.toString();
}

String _serializeTokenList(List<CssToken> tokens) {
  final buf = StringBuffer();
  CssTokenType? prevType;

  for (final token in tokens) {
    if (token.type == CssTokenType.whitespace) {
      if (buf.isNotEmpty && prevType != CssTokenType.whitespace) {
        buf.write(' ');
        prevType = CssTokenType.whitespace;
      }
      continue;
    }

    switch (token.type) {
      case CssTokenType.ident:
        buf.write(_escapeCssIdent(token.value));
      case CssTokenType.function:
        buf.write('${_escapeCssIdent(token.lowerValue)}(');
      case CssTokenType.atKeyword:
        buf.write('@${_escapeCssIdent(token.lowerValue)}');
      case CssTokenType.hash:
        buf.write('#${_escapeCssIdent(token.value)}');
      case CssTokenType.string:
        buf.write(_serializeCssString(token.value));
      case CssTokenType.number:
        buf.write(token.value);
      case CssTokenType.percentage:
        buf.write('${token.value}%');
      case CssTokenType.dimension:
        buf.write('${token.value}${_escapeCssIdent(token.unit)}');
      case CssTokenType.colon:
        buf.write(':');
      case CssTokenType.semicolon:
        buf.write(';');
      case CssTokenType.comma:
        buf.write(',');
      case CssTokenType.lParen:
        buf.write('(');
      case CssTokenType.rParen:
        buf.write(')');
      case CssTokenType.lBracket:
        buf.write('[');
      case CssTokenType.rBracket:
        buf.write(']');
      case CssTokenType.lBrace:
        buf.write('{');
      case CssTokenType.rBrace:
        buf.write('}');
      case CssTokenType.delim:
        buf.write(token.value);
      case CssTokenType.whitespace:
      case CssTokenType.badString:
      case CssTokenType.url:
      case CssTokenType.badUrl:
      case CssTokenType.cdo:
      case CssTokenType.cdc:
        break;
    }
    prevType = token.type;
  }

  return buf.toString().trim();
}

String _escapeCssIdent(String value) {
  final buf = StringBuffer();
  for (final rune in value.runes) {
    if ((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A) ||
        rune == 0x2D ||
        rune == 0x5F ||
        rune >= 0x80) {
      buf.writeCharCode(rune);
    } else {
      buf.write('\\${rune.toRadixString(16)} ');
    }
  }
  return buf.toString();
}

String _serializeCssString(String value) {
  final buf = StringBuffer('"');
  for (final rune in value.runes) {
    if (rune == 0x22) {
      buf.write(r'\"');
    } else if (rune == 0x5C) {
      buf.write(r'\\');
    } else if (rune == 0x0A) {
      buf.write(r'\a ');
    } else if (rune == 0x3C) {
      // Prevent `</style>` breakout from inside CSS string literals.
      buf.write(r'\3c ');
    } else if (rune == 0x3E) {
      buf.write(r'\3e ');
    } else {
      buf.writeCharCode(rune);
    }
  }
  buf.write('"');
  return buf.toString();
}
