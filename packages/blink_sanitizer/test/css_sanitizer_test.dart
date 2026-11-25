import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:test/test.dart';

void main() {
  group('CssTokenizer W3C CSS Syntax L3 escape decoding', () {
    test('decodes hex escapes with trailing space into url token', () {
      final tokens = CssTokenizer(r'\75 rl(https://evil.example/a.png)')
          .tokenize();
      expect(tokens, hasLength(1));
      expect(tokens.first.type, CssTokenType.url);
      expect(tokens.first.value, 'https://evil.example/a.png');
    });

    test('decodes 6-digit hex escapes into function token', () {
      final tokens = CssTokenizer(r'\000075rl("https://evil.example/a.png")')
          .tokenize();
      expect(tokens.first.type, CssTokenType.function);
      expect(tokens.first.lowerValue, 'url');
    });

    test('decodes escaped @import at-keyword', () {
      final tokens = CssTokenizer(r'@\69 mport "https://evil.example/a.css";')
          .tokenize();
      expect(tokens.first.type, CssTokenType.atKeyword);
      expect(tokens.first.lowerValue, 'import');
    });

    test('strips comments before matching tokens', () {
      final tokens = CssTokenizer('color:/* c */var(--blink-text-primary)')
          .tokenize();
      expect(
        tokens.where((t) => t.type == CssTokenType.function).single.lowerValue,
        'var',
      );
    });
  });

  group('CSS URL, at-rule, and script-injection blocking', () {
    final blockedPayloads = <String, String>{
      'direct url()': 'background: url(https://evil.example/track.png)',
      'uppercase URL()': 'background: URL("https://evil.example/track.png")',
      'hex-escaped \\75 rl()':
          r'background: \75 rl(https://evil.example/x.png)',
      '6-digit escaped url()':
          r'background: \000075\000072\00006c("https://evil.example")',
      'comment-split url/*x*/()':
          'background: url/*comment*/(https://evil.example/x)',
      'image-set()': 'background-image: image-set("a.png" 1x)',
      'IE expression()': 'width: expression(alert(1))',
      'escaped expression()': r'width: \65 xpression(alert(1))',
      'IE behavior property': 'behavior: url(xss.htc)',
      'escaped behavior property': r'b\65 havior: foo',
      'moz-binding property': '-moz-binding: foo',
      'javascript scheme in string': 'content: "javascript:alert(1)"',
      'escaped javascript scheme in string':
          r'content: "\6a avascript:alert(1)"',
      'data:text/html in string':
          'content: "data:text/html,<script>alert(1)</script>"',
      'unquoted javascript:': 'background: javascript:alert(1)',
    };

    for (final entry in blockedPayloads.entries) {
      test('blocks ${entry.key} in inline style', () {
        final res = sanitizeCssInlineStyle(entry.value, ownerTag: 'div');
        expect(res.css, isEmpty);
        expect(
          res.diagnostics.map((d) => d.code),
          contains(DiagnosticCode.cssUrlBlocked),
        );
      });
    }

    test('blocks @import, escaped @import, and @font-face in stylesheet', () {
      const css = '''
        @import url("https://evil.example/a.css");
        @\\69 mport "https://evil.example/b.css";
        @font-face { font-family: x; src: url(https://evil.example/f.woff2); }
        .ok { color: var(--blink-text-primary); }
      ''';
      final res = sanitizeCssStylesheet(css);
      expect(
        res.diagnostics
            .where((d) => d.code == DiagnosticCode.cssUrlBlocked)
            .length,
        greaterThanOrEqualTo(3),
      );
      expect(res.css, '.ok { color: var(--blink-text-primary) }');
    });

    test('escapes </style> breakout attempts inside CSS string literals', () {
      final res = sanitizeCssStylesheet(
        '.note::after { content: "</style><script>alert(1)</script>"; }',
      );
      expect(res.css.toLowerCase(), isNot(contains('</style')));
      expect(res.css.toLowerCase(), isNot(contains('<script')));
    });

    test('blocks position: fixed and custom property redefinition', () {
      final res = sanitizeCssStylesheet('''
        :root { --blink-surface-canvas: #000000; --sneaky: #ff0000; }
        .overlay { position: fixed; top: 0; color: var(--sneaky); }
      ''');
      expect(res.css, isNot(contains('--blink-surface-canvas')));
      expect(res.css, isNot(contains('fixed')));
      expect(res.css, isNot(contains('--sneaky')));
      expect(res.diagnostics, isNotEmpty);
    });
  });

  group('CSS hardcoded color literal blocking and var(--blink-*) allowance', () {
    final rawColorCases = <String>[
      'color: #1f2328',
      'background-color: #fff',
      'border: 1px solid #e6e8eb',
      'color: rgb(31, 35, 40)',
      'background: rgba(245, 180, 0, 0.28)',
      'color: hsl(210, 80%, 50%)',
      'color: hsla(210, 80%, 50%, 0.5)',
      'color: oklch(0.6 0.15 240)',
      'background: white',
      'color: red',
      'border-bottom: 1px solid gray',
      'background-image: linear-gradient(90deg, #ffffff, var(--blink-surface-canvas))',
      'color: var(--blink-text-primary, #1f2328)',
      'color: var(--blink-text-primary, black)',
    ];

    for (final decl in rawColorCases) {
      test('rejects raw color literal: $decl', () {
        final res = sanitizeCssInlineStyle(decl, ownerTag: 'div');
        expect(res.css, isEmpty);
        expect(
          res.diagnostics.map((d) => d.code),
          contains(DiagnosticCode.rawColorLiteral),
        );
      });
    }

    test('allows valid Surface 2 grid/flex/gradient/media stylesheet with var(--blink-*)', () {
      const css = '''
        .report {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: 16px;
          background: linear-gradient(180deg, var(--blink-surface-canvas), var(--blink-surface-ai-derived));
          color: var(--blink-text-primary);
          border: 1px solid var(--blink-border-hairline);
          border-radius: 10px;
          box-shadow: 0 2px 8px color-mix(in srgb, var(--blink-text-primary) 8%, transparent);
        }
        @media (max-width: 640px) {
          .report { grid-template-columns: 1fr; }
        }
      ''';
      final res = sanitizeCssStylesheet(css);
      expect(res.diagnostics, isEmpty);
      expect(res.css, contains('display: grid'));
      expect(res.css, contains('var(--blink-surface-canvas)'));
      expect(res.css, contains('var(--blink-border-hairline)'));
      expect(res.css, contains('@media (max-width: 640px)'));
    });

    test(
      'allows transparent, currentColor, inherit, and var(--blink-*) fallback',
      () {
        final res = sanitizeCssInlineStyle(
          'color: var(--blink-text-primary, currentColor); background: transparent; border-color: inherit;',
          ownerTag: 'p',
        );
        expect(res.diagnostics, isEmpty);
        expect(res.css, contains('var(--blink-text-primary, currentColor)'));
        expect(res.css, contains('background: transparent'));
      },
    );

    test('blocks <style> breakout / mXSS payloads via comment-split or CDO/CDC tokens', () {
      const commentBreakout =
          '.a { font-family: </*x*/style><script src="https://evil.example/a.js"></script>; }';
      final r1 = sanitizeCssStylesheet(commentBreakout);
      expect(r1.css, isEmpty);
      expect(r1.css, isNot(contains('<')));
      expect(
        r1.diagnostics.map((d) => d.code),
        contains(DiagnosticCode.disallowedAttr),
      );

      const cdoBreakout =
          '.a { font-family: </<!-- -->style><img src="https://evil.example/leak">; }';
      final r2 = sanitizeCssStylesheet(cdoBreakout);
      expect(r2.css, isEmpty);
      expect(r2.css, isNot(contains('<')));
      expect(
        r2.diagnostics.map((d) => d.code),
        contains(DiagnosticCode.disallowedAttr),
      );
    });

    test('emits diagnostic on empty var(--blink-*, ) fallback', () {
      final res = sanitizeCssInlineStyle(
        'color: var(--blink-text-primary, )',
        ownerTag: 'p',
      );
      expect(res.css, isEmpty);
      expect(
        res.diagnostics.map((d) => d.code),
        contains(DiagnosticCode.disallowedAttr),
      );
    });
  });
}
