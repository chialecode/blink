import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:test/test.dart';

const String _validUuid1 = '019349c8-7c10-7b22-9a11-4058c2e90101';
const String _validUuid2 = '019349c8-7c10-7b22-8f00-4058c2e90202';
const String _validSha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

void main() {
  group('Adversarial HTML5 / XSS / active tag blocking', () {
    test(
      'drops executable, embed, form, metadata, and template tags completely',
      () {
        const adversarial = '''
        <p>Safe text</p>
        <script>alert('xss')</script>
        <iframe src="https://evil.example">fallback</iframe>
        <object data="https://evil.example/a.swf"></object>
        <embed src="https://evil.example/a.swf">
        <form action="https://evil.example"><input name="p" value="1"></form>
        <base href="https://evil.example/">
        <meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel="stylesheet" href="https://evil.example/a.css">
        <template><script>alert(2)</script></template>
        <!--[if IE]><script>alert(3)</script><![endif]-->
      ''';

        final res = sanitizeBlinkHtml(
          adversarial,
          options: const SanitizeOptions(
            profile: SanitizeProfile.surface1Native,
          ),
        );

        expect(res.isValid, isFalse);
        expect(res.html.trim(), '<p>Safe text</p>');
        expect(res.html, isNot(contains('alert')));
        final disallowedTags = res.diagnostics
            .where((d) => d.code == DiagnosticCode.disallowedTag)
            .map((d) => d.tagName)
            .toSet();
        expect(
          disallowedTags,
          containsAll(<String>[
            'script',
            'iframe',
            'object',
            'embed',
            'form',
            'base',
            'meta',
            'link',
            'template',
          ]),
        );
      },
    );

    test('strips all inline on* event handlers (case-insensitive)', () {
      const html =
          '<div onclick="alert(1)" ONMOUSEOVER="alert(2)" onanimationstart="x">'
          '<img src="blink-blob://$_validSha256" onerror="alert(3)" alt="ok">'
          '</div>';
      final res = sanitizeBlinkHtml(
        html,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );

      expect(res.isValid, isFalse);
      expect(res.html, isNot(contains('on')));
      expect(
        res.diagnostics.where((d) => d.code == DiagnosticCode.disallowedAttr),
        hasLength(4),
      );
      expect(res.html, contains('src="blink-blob://$_validSha256"'));
    });

    test('rejects <style> on surface1Native and readingBlock', () {
      const html =
          '<style>.a { color: var(--blink-text-primary); }</style><p>hi</p>';
      for (final profile in const <SanitizeProfile>[
        SanitizeProfile.surface1Native,
        SanitizeProfile.readingBlock,
      ]) {
        final res = sanitizeBlinkHtml(
          html,
          options: SanitizeOptions(profile: profile),
        );
        expect(res.isValid, isFalse);
        expect(res.html, '<p>hi</p>');
        expect(
          res.diagnostics.map((d) => d.code),
          contains(DiagnosticCode.disallowedTag),
        );
      }
    });

    test('blocks obfuscated inline style CSS escapes and raw colors', () {
      const html =
          r'<div style="background: \75 rl(https://evil.example/x); color: #ff0000; padding: 8px">Hi</div>';
      final res = sanitizeBlinkHtml(
        html,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );

      expect(res.isValid, isFalse);
      expect(res.html, '<div style="padding: 8px">Hi</div>');
      expect(
        res.diagnostics.map((d) => d.code),
        containsAll(<DiagnosticCode>[
          DiagnosticCode.cssUrlBlocked,
          DiagnosticCode.rawColorLiteral,
        ]),
      );
    });
  });

  group('SVG security and W_SURFACE1_SVG_TEXT warning', () {
    test('blocks foreignObject, SVG image/use external refs, SMIL animate*, and raw SVG colors', () {
      const svg = '''
        <svg viewBox="0 0 200 100" xmlns="http://www.w3.org/2000/svg">
          <foreignObject width="100" height="100"><div xmlns="http://www.w3.org/1999/xhtml"><script>alert(1)</script></div></foreignObject>
          <image href="https://evil.example/p.png" xlink:href="https://evil.example/p2.png"/>
          <use href="https://evil.example/sprite.svg#icon"/>
          <animate attributeName="x" from="0" to="10"/>
          <animateTransform attributeName="transform" type="rotate"/>
          <set attributeName="fill" to="red"/>
          <rect x="0" y="0" width="80" height="40" fill="#ff0000" stroke="var(--blink-border-hairline)" onclick="alert(1)"/>
          <circle cx="50" cy="50" r="20" fill="currentColor"/>
        </svg>
      ''';

      final res = sanitizeBlinkHtml(
        svg,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );

      expect(res.isValid, isFalse);
      expect(res.html, isNot(contains('foreignObject')));
      expect(res.html, isNot(contains('<image')));
      expect(res.html, isNot(contains('<use')));
      expect(res.html, isNot(contains('animate')));
      expect(res.html, isNot(contains('<set')));
      expect(res.html, isNot(contains('#ff0000')));
      expect(res.html, isNot(contains('onclick')));
      expect(res.html, contains('viewBox="0 0 200 100"'));
      expect(res.html, contains('stroke="var(--blink-border-hairline)"'));
      expect(res.html, contains('fill="currentColor"'));
      expect(
        res.diagnostics.map((d) => d.code),
        containsAll(<DiagnosticCode>[
          DiagnosticCode.disallowedTag,
          DiagnosticCode.disallowedAttr,
          DiagnosticCode.rawColorLiteral,
        ]),
      );
    });

    test('blocks external url() in SVG fill attribute while allowing local #gradient ref', () {
      const svg = '''
        <svg viewBox="0 0 100 100">
          <defs>
            <linearGradient id="g1">
              <stop offset="0%" stop-color="var(--blink-accent-primary)"/>
            </linearGradient>
          </defs>
          <rect width="50" height="50" fill="url(#g1)"/>
          <rect width="50" height="50" fill="url(https://evil.example/g.svg#x)"/>
        </svg>
      ''';
      final res = sanitizeBlinkHtml(
        svg,
        options: const SanitizeOptions(
          profile: SanitizeProfile.surface2Sandbox,
        ),
      );

      expect(res.isValid, isFalse);
      expect(res.html, contains('fill="url(#g1)"'));
      expect(res.html, isNot(contains('evil.example')));
      expect(
        res.diagnostics.map((d) => d.code),
        contains(DiagnosticCode.cssUrlBlocked),
      );
    });

    test('emits W_SURFACE1_SVG_TEXT warning on Surface 1 without failing isValid', () {
      const svg =
          '<svg viewBox="0 0 100 40"><text x="10" y="20" fill="currentColor">中文</text></svg>';

      final s1 = sanitizeBlinkHtml(
        svg,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );
      expect(s1.isValid, isTrue);
      expect(
        s1.warnings.map((d) => d.code),
        contains(DiagnosticCode.surface1SvgText),
      );
      expect(s1.warnings.single.codeString, 'W_SURFACE1_SVG_TEXT');

      final s2 = sanitizeBlinkHtml(
        svg,
        options: const SanitizeOptions(
          profile: SanitizeProfile.surface2Sandbox,
        ),
      );
      expect(s2.isValid, isTrue);
      expect(s2.warnings, isEmpty);
    });
  });

  group('URL hygiene for images and links', () {
    test('allows only verified blink-blob://<64-hex> on img and blocks external/data/js', () {
      const html =
          '''
        <figure>
          <img src="blink-blob://$_validSha256" alt="valid">
          <img src="blink-blob://not-a-sha256" alt="bad-sha">
          <img src="https://evil.example/tracker.png" alt="ext-https">
          <img src="http://evil.example/tracker.png" alt="ext-http">
          <img src="data:text/html,<script>alert(1)</script>" alt="data-html">
          <img src="javascript:alert(1)" alt="js">
        </figure>
      ''';

      final res = sanitizeBlinkHtml(
        html,
        options: const SanitizeOptions(profile: SanitizeProfile.readingBlock),
      );

      expect(res.isValid, isFalse);
      expect(res.html, contains('src="blink-blob://$_validSha256"'));
      expect(res.html, isNot(contains('not-a-sha256')));
      expect(res.html, isNot(contains('evil.example')));
      expect(res.html, isNot(contains('data:text/html')));
      expect(res.html, isNot(contains('javascript:')));
    });

    test('allows blink-anchor:// and #fragment links and blocks external/javascript/data hrefs', () {
      const html = '''
        <p>
          <a href="blink-anchor://ch-003#b-0001-9f2a1c04">Ch 3</a>
          <a href="#fn-1">[1]</a>
          <a href="https://evil.example/phish">External</a>
          <a href="javascript:alert(1)">JS</a>
          <a href="java\tscript:alert(2)">TabJS</a>
          <a href="data:text/html;base64,PHNjcmlwdD4=">Data</a>
        </p>
      ''';

      final res = sanitizeBlinkHtml(
        html,
        options: const SanitizeOptions(profile: SanitizeProfile.readingBlock),
      );

      expect(res.isValid, isFalse);
      expect(
        res.html,
        contains('href="blink-anchor://ch-003#b-0001-9f2a1c04"'),
      );
      expect(res.html, contains('href="#fn-1"'));
      expect(res.html, isNot(contains('evil.example')));
      expect(res.html, isNot(contains('javascript:')));
      expect(res.html, isNot(contains('data:text/html')));
      // Anchor text is preserved safely without href.
      expect(res.html, contains('<a>External</a>'));
    });
  });

  group('Locked <blink-*> tags, producer boundaries, and reference validation', () {
    test(
      'rejects <blink-embed>, <blink-tag>, and <blink-time> from AI producers',
      () {
        const aiHtml =
            '''
        <p>AI output</p>
        <blink-embed kind="ai" id="$_validUuid1">Recursive card</blink-embed>
        <blink-tag name="work">#work</blink-tag>
        <blink-time sec="865">14:25</blink-time>
      ''';

        final res = sanitizeBlinkHtml(
          aiHtml,
          options: const SanitizeOptions(
            profile: SanitizeProfile.surface1Native,
            producer: HtmlProducer.aiDerived,
          ),
        );

        expect(res.isValid, isFalse);
        expect(res.html.trim(), '<p>AI output</p>');
        final producerErrors = res.diagnostics
            .where((d) => d.code == DiagnosticCode.disallowedProducerTag)
            .map((d) => d.tagName)
            .toList();
        expect(
          producerErrors,
          unorderedEquals(<String>['blink-embed', 'blink-tag', 'blink-time']),
        );
      },
    );

    test('allows user BFM tags (<blink-embed|tag|time|ref|math>) for userBfm and rejects AI layout tags', () {
      const bfmHtml =
          '''
        <p>
          <blink-ref kind="source" id="$_validUuid1" anchor="p42" data-bind="context">《思考》</blink-ref>
          <blink-tag name="private" data-privacy="private">🔒 #private</blink-tag>
          <blink-time sec="865">14:25</blink-time>
          <blink-math display="inline">E=mc^2</blink-math>
          <blink-embed kind="ai" id="$_validUuid2">Weekly synthesis</blink-embed>
        </p>
        <blink-grid cols="2"><blink-card title="Forbidden for BFM">x</blink-card></blink-grid>
      ''';

      final res = sanitizeBlinkHtml(
        bfmHtml,
        options: const SanitizeOptions(
          profile: SanitizeProfile.surface1Native,
          producer: HtmlProducer.userBfm,
        ),
      );

      expect(res.isValid, isFalse);
      expect(res.diagnostics.single.code, DiagnosticCode.disallowedProducerTag);
      expect(res.diagnostics.single.tagName, 'blink-grid');
      expect(
        res.html,
        contains(
          '<blink-embed id="$_validUuid2" kind="ai">Weekly synthesis</blink-embed>',
        ),
      );
      expect(
        res.html,
        contains(
          '<blink-tag data-privacy="private" name="private">🔒 #private</blink-tag>',
        ),
      );
      expect(res.html, contains('<blink-time sec="865">14:25</blink-time>'));
      expect(
        res.html,
        contains('<blink-math display="inline">E=mc^2</blink-math>'),
      );
      expect(res.extractedRefs, hasLength(1));
      expect(res.extractedRefs.single.anchor, 'p42');
      expect(res.extractedRefs.single.dataBind, 'context');
    });

    test('rejects all <blink-*> tags in readingBlock external HTML', () {
      const externalHtml =
          '<p>Article <blink-ref kind="entry" id="$_validUuid1">fake</blink-ref></p>';
      final res = sanitizeBlinkHtml(
        externalHtml,
        options: const SanitizeOptions(profile: SanitizeProfile.readingBlock),
      );
      expect(res.isValid, isFalse);
      expect(res.html, '<p>Article </p>');
      expect(res.diagnostics.single.code, DiagnosticCode.disallowedProducerTag);
    });

    test('validates <blink-ref> attributes and invokes pluggable refValidator for existence & privacy scope', () {
      const html =
          '''
        <p>
          <blink-ref kind="entry" id="$_validUuid1">Valid Note</blink-ref>
          <blink-ref kind="entry" id="$_validUuid2">Secret Note</blink-ref>
          <blink-ref kind="annotation" id="019349c8-7c10-7b22-a111-4058c2e90999">Missing Note</blink-ref>
          <blink-ref kind="entry" id="not-a-uuidv7">Bad ID</blink-ref>
        </p>
      ''';

      final res = sanitizeBlinkHtml(
        html,
        options: SanitizeOptions(
          profile: SanitizeProfile.surface1Native,
          producer: HtmlProducer.aiDerived,
          privacyScope: PrivacyScope.normalOnly,
          refValidator: (target, scope) {
            if (target.id == _validUuid1) {
              return BlinkRefValidationStatus.valid;
            }
            if (target.id == _validUuid2) {
              return BlinkRefValidationStatus.privacyScopeViolation;
            }
            return BlinkRefValidationStatus.notFound;
          },
        ),
      );

      expect(res.isValid, isFalse);
      expect(res.extractedRefs, hasLength(1));
      expect(res.extractedRefs.single.id, _validUuid1);
      expect(
        res.html,
        contains(
          '<blink-ref id="$_validUuid1" kind="entry">Valid Note</blink-ref>',
        ),
      );
      expect(res.html, contains('[private-ref]'));
      expect(res.html, isNot(contains('Secret Note')));
      expect(res.html, isNot(contains(_validUuid2)));
      expect(res.html, isNot(contains('Missing Note')));
      expect(res.html, isNot(contains('Bad ID')));
      expect(
        res.diagnostics.map((d) => d.code),
        containsAll(<DiagnosticCode>[
          DiagnosticCode.privacyScopeViolation,
          DiagnosticCode.brokenBlinkRef,
          DiagnosticCode.invalidBlinkAttr,
        ]),
      );
    });

    test('compiles valid <blink-ref> into blink-ref:// anchor on Surface 2', () {
      const doc =
          '''
        <!doctype html>
        <html>
          <head>
            <title>Weekly Review</title>
            <style>
              .grid { display: grid; gap: 12px; color: var(--blink-text-primary); background: var(--blink-surface-canvas); }
            </style>
          </head>
          <body>
            <main class="grid">
              <h1>周度复盘</h1>
              <p>依据 <blink-ref kind="source" id="$_validUuid1" anchor="ch-003/b-0001-9f2a1c04">《系统之美》</blink-ref></p>
            </main>
          </body>
        </html>
      ''';

      final res = sanitizeBlinkHtml(
        doc,
        options: SanitizeOptions(
          profile: SanitizeProfile.surface2Sandbox,
          producer: HtmlProducer.aiDerived,
          refValidator: (_, _) => BlinkRefValidationStatus.valid,
        ),
      );

      expect(res.isValid, isTrue);
      expect(res.diagnostics, isEmpty);
      expect(res.extractedRefs, hasLength(1));
      expect(
        res.html,
        contains(
          '<style>.grid { display: grid; gap: 12px; color: var(--blink-text-primary); background: var(--blink-surface-canvas) }</style>',
        ),
      );
      expect(
        res.html,
        contains(
          '<a class="blink-ref" href="blink-ref://source/$_validUuid1?anchor=ch-003%2Fb-0001-9f2a1c04">《系统之美》</a>',
        ),
      );
    });

    test(
      'validates AI Surface 1 layout tags and <blink-chart> data-json schema',
      () {
        const validSurface1 =
            '''
        <blink-grid cols="2" gap="md">
          <blink-card title="本周核心洞察" tone="insight">
            <p>跨时空回响 <blink-ref kind="entry" id="$_validUuid1">2026-11-20</blink-ref></p>
          </blink-card>
          <blink-metric label="本周阅读" value="4.5" unit="小时" delta="+18%" tone="ok"></blink-metric>
        </blink-grid>
        <blink-timeline title="演进轨迹">
          <ol><li>初步假设</li><li>实证修正</li></ol>
        </blink-timeline>
        <blink-compare left-title="旧观点" right-title="新认知" tone="evolution">
          <p>对比说明</p>
        </blink-compare>
        <blink-chart chart-type="bar" height="220" title="每日记录" data-json='{"labels":["Mon","Tue"],"values":[3,7]}'>Fallback</blink-chart>
      ''';

        final res = sanitizeBlinkHtml(
          validSurface1,
          options: SanitizeOptions(
            profile: SanitizeProfile.surface1Native,
            producer: HtmlProducer.aiDerived,
            refValidator: (_, _) => BlinkRefValidationStatus.valid,
          ),
        );

        expect(res.isValid, isTrue);
        expect(res.diagnostics, isEmpty);
        expect(res.extractedRefs, hasLength(1));
        expect(res.html, contains('<blink-grid cols="2" gap="md">'));
        expect(res.html, contains('<blink-chart chart-type="bar"'));
        expect(res.html, contains('height="220"'));
      },
    );

    test('rejects <blink-chart> with hardcoded colors or invalid JSON, and rejects AI layout tags on Surface 2', () {
      const badChart =
          '<blink-chart chart-type="pie" data-json=\'{"color":"#ff0000","values":[1,2]}\'></blink-chart>';
      final r1 = sanitizeBlinkHtml(
        badChart,
        options: const SanitizeOptions(
          profile: SanitizeProfile.surface1Native,
          producer: HtmlProducer.aiDerived,
        ),
      );
      expect(r1.isValid, isFalse);
      expect(
        r1.diagnostics.map((d) => d.code),
        contains(DiagnosticCode.rawColorLiteral),
      );

      const s2Layout = '<blink-grid cols="2"><p>nope</p></blink-grid>';
      final r2 = sanitizeBlinkHtml(
        s2Layout,
        options: const SanitizeOptions(
          profile: SanitizeProfile.surface2Sandbox,
          producer: HtmlProducer.aiDerived,
        ),
      );
      expect(r2.isValid, isFalse);
      expect(r2.diagnostics.single.code, DiagnosticCode.disallowedProducerTag);
    });

    test('is deterministic across repeated invocations', () {
      const input =
          '<p title="t" class="b a" id="p1">Hello <strong style="font-weight: 600; color: var(--blink-text-primary)">世界</strong></p>';
      final a = sanitizeBlinkHtml(
        input,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );
      final b = sanitizeBlinkHtml(
        input,
        options: const SanitizeOptions(profile: SanitizeProfile.surface1Native),
      );
      expect(a.html, b.html);
      expect(a.diagnostics, b.diagnostics);
    });
  });
}
