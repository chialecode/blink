import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:test/test.dart';

void main() {
  const bfm = BfmEngine();

  group('BFM v1 golden conformance fixture', () {
    final fixtureFile = File('test/fixtures/bfm_conformance.json');
    final raw =
        jsonDecode(fixtureFile.readAsStringSync()) as Map<String, Object?>;
    final cases = (raw['cases'] as List<Object?>).cast<Map<String, Object?>>();

    for (final testCase in cases) {
      final name = testCase['name'] as String;
      test(name, () {
        final input = testCase['input'] as String;
        final doc = bfm.parse(input);
        final html = bfm.compileToHtml(input);
        final plain = bfm.toPlainText(input);
        final mirror = bfm.toMirrorMarkdown(
          input,
          entryPrivacy: PrivacyLevel.normal,
          linkResolver: (link, _) {
            if (link.targetKind == BfmLinkTargetKind.ai) {
              return '> ✦ AI 派生视图：[${link.label}](../../insights/${link.targetId}.html)';
            }
            return '[${link.label}](target/${link.targetId ?? link.label}.md)';
          },
        );

        if (testCase.containsKey('expectTags')) {
          expect(
            doc.tags,
            equals((testCase['expectTags'] as List<Object?>).cast<String>()),
          );
        }
        if (testCase.containsKey('expectHasPrivate')) {
          expect(doc.hasPrivateToken, equals(testCase['expectHasPrivate']));
        }
        if (testCase.containsKey('expectIsSimpleFastPath')) {
          expect(
            doc.isSimpleFastPath,
            equals(testCase['expectIsSimpleFastPath']),
          );
        }
        if (testCase.containsKey('expectSourceRefId')) {
          expect(doc.sourceRefId, equals(testCase['expectSourceRefId']));
        }
        if (testCase.containsKey('expectLinkCount')) {
          expect(doc.links.length, equals(testCase['expectLinkCount']));
        }
        if (testCase.containsKey('expectAiEmbedIds')) {
          expect(
            doc.aiEmbedIds,
            equals(
              (testCase['expectAiEmbedIds'] as List<Object?>).cast<String>(),
            ),
          );
        }
        if (testCase.containsKey('expectTasks')) {
          final expectedTasks = (testCase['expectTasks'] as List<Object?>)
              .cast<Map<String, Object?>>();
          expect(doc.tasks.length, equals(expectedTasks.length));
          for (var i = 0; i < expectedTasks.length; i++) {
            expect(
              doc.tasks[i].lineIndex,
              equals(expectedTasks[i]['lineIndex']),
            );
            expect(
              doc.tasks[i].status.wireValue,
              equals(expectedTasks[i]['status']),
            );
            expect(doc.tasks[i].title, equals(expectedTasks[i]['title']));
          }
        }
        if (testCase.containsKey('expectTimestamps')) {
          final expectedTs = (testCase['expectTimestamps'] as List<Object?>)
              .cast<Map<String, Object?>>();
          expect(doc.timestamps.length, equals(expectedTs.length));
          for (var i = 0; i < expectedTs.length; i++) {
            expect(doc.timestamps[i].seconds, equals(expectedTs[i]['seconds']));
            expect(
              doc.timestamps[i].displayText,
              equals(expectedTs[i]['displayText']),
            );
          }
        }
        if (testCase.containsKey('expectHtmlContains')) {
          for (final snippet
              in (testCase['expectHtmlContains'] as List<Object?>)
                  .cast<String>()) {
            expect(html, contains(snippet));
          }
        }
        if (testCase.containsKey('expectHtmlNotContains')) {
          for (final snippet
              in (testCase['expectHtmlNotContains'] as List<Object?>)
                  .cast<String>()) {
            expect(html, isNot(contains(snippet)));
          }
        }
        if (testCase.containsKey('expectPlainText')) {
          expect(plain, equals(testCase['expectPlainText']));
        }
        if (testCase.containsKey('expectPlainTextContains')) {
          for (final snippet
              in (testCase['expectPlainTextContains'] as List<Object?>)
                  .cast<String>()) {
            expect(plain, contains(snippet));
          }
        }
        if (testCase.containsKey('expectPlainTextNotContains')) {
          for (final snippet
              in (testCase['expectPlainTextNotContains'] as List<Object?>)
                  .cast<String>()) {
            expect(plain, isNot(contains(snippet)));
          }
        }
        if (testCase.containsKey('expectMirrorContains')) {
          for (final snippet
              in (testCase['expectMirrorContains'] as List<Object?>)
                  .cast<String>()) {
            expect(mirror, contains(snippet));
          }
        }
      });
    }
  });

  group('BFM v1 privacy redaction & task toggling', () {
    test('redacts cross-privacy refs in HTML and mirror Markdown', () {
      const privEntryId = '019349c8-7c10-7b22-9a11-4058c2e90111';
      const privAiId = '019349c8-7c10-7b22-9a11-4058c2e90222';
      const md = '普通记录引用 [[entry:$privEntryId|秘密日记]] 与 ![[ai:$privAiId|私密复盘]]';

      final normalHtml = bfm.toSemanticHtml(
        md,
        viewerScope: PrivacyScope.normalOnly,
        privateTargetIds: const <String>{privEntryId, privAiId},
      );
      expect(normalHtml, isNot(contains(privEntryId)));
      expect(normalHtml, isNot(contains('秘密日记')));
      expect(normalHtml, isNot(contains(privAiId)));
      expect(normalHtml, contains('[private-ref]'));

      final mirrorMd = bfm.toMirrorMarkdown(
        md,
        entryPrivacy: PrivacyLevel.normal,
        privateTargetIds: const <String>{privEntryId, privAiId},
        linkResolver: (link, _) => '[${link.label}](should-not-leak)',
      );
      expect(mirrorMd, contains('[秘密日记 (私密条目)]'));
      expect(mirrorMd, contains('[私密复盘 (私密条目)]'));
      expect(mirrorMd, isNot(contains('should-not-leak')));
      expect(mirrorMd, isNot(contains(privEntryId)));
    });

    test('toggleTaskLine alters only the single checkbox marker byte', () {
      const original = '# 日记\n- [ ] 第一项任务\n- [x] 第二项任务\n保留尾行';
      final updated = bfm.toggleTaskLine(
        original,
        lineIndex: 1,
        newStatus: TaskStatus.done,
      );
      expect(updated, equals('# 日记\n- [x] 第一项任务\n- [x] 第二项任务\n保留尾行'));

      final deferred = bfm.toggleTaskLine(
        updated,
        lineIndex: 2,
        newStatus: TaskStatus.deferred,
      );
      expect(deferred, equals('# 日记\n- [x] 第一项任务\n- [>] 第二项任务\n保留尾行'));
    });

    test('renders inline code inside CJK emphasis and highlights without sentinel leaks', () {
      final boldCodeHtml = bfm.toSemanticHtml('这是**`foo`**测试');
      expect(boldCodeHtml, contains('<strong><code>foo</code></strong>'));
      expect(boldCodeHtml, isNot(contains('\uE010')));
      expect(boldCodeHtml, isNot(contains('CODE0')));

      final markCodeHtml = bfm.toSemanticHtml('这是==`foo`==高亮');
      expect(markCodeHtml, contains('<mark><code>foo</code></mark>'));
      expect(markCodeHtml, isNot(contains('\uE010')));
      expect(markCodeHtml, isNot(contains('CODE0')));

      final literalPhHtml = bfm.toSemanticHtml('字面量 BLINKPH0ENDPH 与 #标签');
      expect(literalPhHtml, contains('BLINKPH0ENDPH'));
      expect(literalPhHtml, contains('<blink-tag name="标签">#标签</blink-tag>'));
    });

    test('stripPrivateTokens removes standalone #private while preserving code, URLs, links, and formatting', () {
      expect(bfm.stripPrivateTokens(''), equals(''));
      expect(bfm.stripPrivateTokens('普通笔记 #工作'), equals('普通笔记 #工作'));
      expect(bfm.stripPrivateTokens('#private'), equals(''));
      expect(bfm.stripPrivateTokens('  #PRIVATE  '), equals(''));
      expect(bfm.stripPrivateTokens('私密想法 #private'), equals('私密想法'));
      expect(bfm.stripPrivateTokens('#private 私密想法'), equals('私密想法'));
      expect(bfm.stripPrivateTokens('私密 #Private 想法 #工作'), equals('私密 想法 #工作'));
      expect(
        bfm.stripPrivateTokens('# 标题 #private\n\n- [ ] 待办 #private'),
        equals('# 标题\n\n- [ ] 待办'),
      );
      expect(
        bfm.stripPrivateTokens('第一段\n\n#private\n\n第二段'),
        equals('第一段\n\n第二段'),
      );
      expect(bfm.stripPrivateTokens('第一段\n\n#private'), equals('第一段'));
      expect(bfm.stripPrivateTokens('#private\n\n正文内容'), equals('正文内容'));
      expect(
        bfm.stripPrivateTokens('行内代码 `#private` 与真实 #private'),
        equals('行内代码 `#private` 与真实'),
      );
      expect(
        bfm.stripPrivateTokens('网址 https://example.com/#private 和 #private'),
        equals('网址 https://example.com/#private 和'),
      );
      expect(
        bfm.stripPrivateTokens(
          '```dart\n// #private inside fence\n```\n正文 #private',
        ),
        equals('```dart\n// #private inside fence\n```\n正文'),
      );
      expect(
        bfm.stripPrivateTokens('标签 #private/sub 与 #private'),
        equals('标签 #private/sub 与'),
      );
      expect(
        bfm.stripPrivateTokens('第一行 #private\r\n第二行'),
        equals('第一行\r\n第二行'),
      );
      expect(bfm.stripPrivateTokens('#private#private'), equals(''));
      expect(bfm.stripPrivateTokens('#private#private#private'), equals(''));
      expect(bfm.stripPrivateTokens('前缀 #private#PRIVATE 后缀'), equals('前缀 后缀'));

      for (final sample in const <String>[
        '#private',
        '#private#private',
        '前缀 #private#private 后缀',
        'A #private B #PRIVATE',
        '# 标题 #private\n\n#private\n\n正文',
        '```md\n#private\n```\n外部 #private',
      ]) {
        final stripped = bfm.stripPrivateTokens(sample);
        expect(bfm.parse(stripped).hasPrivateToken, isFalse);
      }
    });
  });

  group('Unicode code-point offsets (INV-10) & RFC 9562 UUIDv7', () {
    test(
      'maps UTF-16 and .runes offsets accurately across surrogate pairs',
      () {
        // '𠀀' is U+20000 (CJK Ext B, 2 UTF-16 units); '🔒' is U+1F512 (2 UTF-16 units).
        const text = '中𠀀文🔒测试';
        expect(text.runes.length, equals(6));
        expect(text.length, equals(8));

        expect(codePointToUtf16Index(text, 0), equals(0));
        expect(codePointToUtf16Index(text, 1), equals(1)); // start of '𠀀'
        expect(codePointToUtf16Index(text, 2), equals(3)); // '文'
        expect(codePointToUtf16Index(text, 3), equals(4)); // start of '🔒'
        expect(codePointToUtf16Index(text, 4), equals(6)); // '测'
        expect(codePointToUtf16Index(text, 6), equals(8));

        expect(utf16ToCodePointIndex(text, 0), equals(0));
        expect(utf16ToCodePointIndex(text, 1), equals(1));
        expect(
          utf16ToCodePointIndex(text, 2),
          equals(1),
        ); // mid-surrogate snaps safely
        expect(utf16ToCodePointIndex(text, 3), equals(2));
        expect(utf16ToCodePointIndex(text, 6), equals(4));
        expect(utf16ToCodePointIndex(text, 8), equals(6));

        expect(sliceByCodePoints(text, 1, 4), equals('𠀀文🔒'));
        expect(graphemeLength('👨‍👩‍👧‍👦中文'), equals(3));
      },
    );

    test('generates valid, strictly monotonic RFC 9562 UUIDv7 strings', () {
      final generated = List<String>.generate(64, (_) => generateUuidV7());
      for (final id in generated) {
        expect(isValidUuidV7(id), isTrue, reason: 'Invalid UUIDv7: $id');
      }
      for (var i = 1; i < generated.length; i++) {
        expect(
          generated[i].compareTo(generated[i - 1]) > 0,
          isTrue,
          reason: 'Expected monotonic ordering at index $i',
        );
      }
    });
  });
}
