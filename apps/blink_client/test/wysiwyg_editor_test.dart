import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/application/wysiwyg_document.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/ui/bfm_preview_view.dart';
import 'package:blink_client/ui/markdown_editor.dart';
import 'package:blink_client/ui/notes_page.dart';

class _NoopWindowAdapter implements DesktopWindowAdapter {
  @override
  Future<WindowGeometrySnapshot?> captureGeometry() async => null;

  @override
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  }) async {}

  @override
  Future<void> destroy() async {}

  @override
  Future<void> hideToTray() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> minimizeToTaskbar() async {}

  @override
  Future<void> showAndFocus() async {}
}

class _NoopTrayAdapter implements DesktopTrayAdapter {
  @override
  Future<void> destroy() async {}

  @override
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) async => true;

  @override
  Future<void> recreate() async {}
}

class _FakeFilePicker implements BlinkFilePicker {
  @override
  Future<String?> pickDirectory({String? title}) async => null;

  @override
  Future<String?> pickFileToOpen({String? title}) async => null;

  @override
  Future<String?> pickFileToSave({
    String? title,
    String? suggestedFileName,
  }) async => null;
}

Future<void> _drainIo(WidgetTester tester, {int rounds = 15}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  group('WysiwygDocument lossless model & helpers', () {
    test('empty and whitespace-only markdown parse to 1 empty paragraph', () {
      for (final input in const <String>['', '   ', '\n\n']) {
        final blocks = WysiwygDocument.parse(input);
        expect(blocks, hasLength(1));
        expect(blocks.first.type, WysiwygBlockType.paragraph);
        expect(blocks.first.text, '');
        expect(WysiwygDocument.serialize(blocks), '');
      }
    });

    test('lossless parse -> serialize round-trip across all Markdown and BFM blocks', () {
      const sample = '''# 一级标题

## 二级标题

### 三级标题

###### 六级标题

正文包含 **加粗**、*斜体*、~~删除线~~、`行内代码`、==重点高亮==、[外部链接](https://example.com)、[[entry:abc|双向引用]]、#工作/复盘 与 #private。
第二行软换行保留在同一段落。

- 无序列表项 1
- 无序列表项 2
* 星号列表项 3

1. 第一步
2. 第二步

- [ ] 待完成事项
- [x] 已完成事项
- [>] 稍后处理事项
- [-] 已取消事项

> 普通引用第一行
> 普通引用第二行

> [!insight] 核心洞察
> 保持原文只读，派生可重建。

> [!note]
> 无标题提示块内容。

```dart
void main() {
  print('hello');
}
```

```
```

---

***

| 列A | 列B |
| --- | --- |
| 值1 | 值2 |

:::fold 展开推导细节
内部详细步骤
:::

![[ai:01948765-4321-7000-8000-000000000001|结构化总结]]''';

      final blocks = WysiwygDocument.parse(sample);
      expect(blocks.map((b) => b.type).toList(), <WysiwygBlockType>[
        WysiwygBlockType.heading,
        WysiwygBlockType.heading,
        WysiwygBlockType.heading,
        WysiwygBlockType.heading,
        WysiwygBlockType.paragraph,
        WysiwygBlockType.bulletList,
        WysiwygBlockType.bulletList,
        WysiwygBlockType.bulletList,
        WysiwygBlockType.orderedList,
        WysiwygBlockType.orderedList,
        WysiwygBlockType.taskItem,
        WysiwygBlockType.taskItem,
        WysiwygBlockType.taskItem,
        WysiwygBlockType.taskItem,
        WysiwygBlockType.blockquote,
        WysiwygBlockType.callout,
        WysiwygBlockType.callout,
        WysiwygBlockType.codeBlock,
        WysiwygBlockType.codeBlock,
        WysiwygBlockType.divider,
        WysiwygBlockType.divider,
        WysiwygBlockType.table,
        WysiwygBlockType.fold,
        WysiwygBlockType.aiEmbed,
      ]);

      expect(blocks[0].level, 1);
      expect(blocks[3].level, 6);
      expect(blocks[10].taskStatus, TaskStatus.open);
      expect(blocks[11].taskStatus, TaskStatus.done);
      expect(blocks[12].taskStatus, TaskStatus.deferred);
      expect(blocks[13].taskStatus, TaskStatus.dropped);
      expect(blocks[15].calloutKind, 'insight');
      expect(blocks[15].calloutTitle, '核心洞察');
      expect(blocks[15].calloutBody, '保持原文只读，派生可重建。');
      expect(blocks[17].codeLanguage, 'dart');
      expect(blocks[23].aiEmbedId, '01948765-4321-7000-8000-000000000001');
      expect(blocks[23].aiEmbedLabel, '结构化总结');

      final serialized = WysiwygDocument.serialize(blocks);
      expect(serialized, sample);
    });

    test('matchPrefixShortcut, task checkbox, and callout helpers', () {
      final h1 = WysiwygDocument.matchPrefixShortcut('# 标题');
      expect(h1?.type, WysiwygBlockType.heading);
      expect(h1?.level, 1);
      expect(h1?.remainingText, '标题');

      final h6 = WysiwygDocument.matchPrefixShortcut('###### 小节');
      expect(h6?.type, WysiwygBlockType.heading);
      expect(h6?.level, 6);
      expect(h6?.remainingText, '小节');

      // Tag without trailing space must NOT trigger heading.
      expect(WysiwygDocument.matchPrefixShortcut('#标签'), isNull);
      expect(WysiwygDocument.matchPrefixShortcut('**加粗**'), isNull);

      final taskOpen = WysiwygDocument.matchPrefixShortcut('- [ ] 写测试');
      expect(taskOpen?.type, WysiwygBlockType.taskItem);
      expect(taskOpen?.taskStatus, TaskStatus.open);
      expect(taskOpen?.remainingText, '写测试');

      final taskDone = WysiwygDocument.matchPrefixShortcut('- [X] 已完成');
      expect(taskDone?.type, WysiwygBlockType.taskItem);
      expect(taskDone?.taskStatus, TaskStatus.done);

      final taskDeferred = WysiwygDocument.matchPrefixShortcut('- [>] 稍后');
      expect(taskDeferred?.taskStatus, TaskStatus.deferred);

      final taskDropped = WysiwygDocument.matchPrefixShortcut('- [-] 取消');
      expect(taskDropped?.taskStatus, TaskStatus.dropped);

      final bullet = WysiwygDocument.matchPrefixShortcut('- 要点');
      expect(bullet?.type, WysiwygBlockType.bulletList);
      expect(bullet?.remainingText, '要点');

      final starBullet = WysiwygDocument.matchPrefixShortcut('* 另一项');
      expect(starBullet?.type, WysiwygBlockType.bulletList);
      expect(starBullet?.remainingText, '另一项');

      final ordered = WysiwygDocument.matchPrefixShortcut('12. 编号项');
      expect(ordered?.type, WysiwygBlockType.orderedList);
      expect(ordered?.orderNumber, 12);
      expect(ordered?.remainingText, '编号项');

      final quote = WysiwygDocument.matchPrefixShortcut('> 名言');
      expect(quote?.type, WysiwygBlockType.blockquote);
      expect(quote?.remainingText, '名言');

      expect(
        WysiwygDocument.matchPrefixShortcut('---')?.type,
        WysiwygBlockType.divider,
      );
      expect(
        WysiwygDocument.matchPrefixShortcut('***')?.type,
        WysiwygBlockType.divider,
      );

      final fence = WysiwygDocument.matchPrefixShortcut('```python');
      expect(fence?.type, WysiwygBlockType.codeBlock);
      expect(fence?.remainingText, 'python');

      final checkboxUpgrade = WysiwygDocument.matchTaskCheckboxPrefix('[ ] 买书');
      expect(checkboxUpgrade?.status, TaskStatus.open);
      expect(checkboxUpgrade?.remainingText, '买书');

      final calloutUpgrade = WysiwygDocument.matchCalloutPrefix(
        '[!warning] 注意',
      );
      expect(calloutUpgrade?.kind, 'warning');
      expect(calloutUpgrade?.remainingText, '注意');
    });

    test('extractTitle and extractSnippet clean Markdown markers cleanly', () {
      expect(WysiwygDocument.extractTitle(''), '无标题笔记');
      expect(WysiwygDocument.extractTitle('---\n\n   '), '无标题笔记');
      expect(WysiwygDocument.extractSnippet(''), '');

      const note = '''# **产品复盘** ==关键结论==
- [ ] 跟进 [设计稿](https://example.com)
> 参考 [[entry:123|原始小记]] 的想法''';
      expect(WysiwygDocument.extractTitle(note), '产品复盘 关键结论');
      expect(WysiwygDocument.extractSnippet(note), '跟进 设计稿 参考 原始小记 的想法');
    });
  });

  group('BlinkSyntaxTextController SPK-02 upgraded Markdown syntax', () {
    testWidgets(
      'preserves 1:1 UTF-16 length, zero WidgetSpan, and exact composing underline across all syntax',
      (tester) async {
        const sample =
            '# 标题一\n'
            '## 标题二\n'
            '**加粗** *斜体* ~~删除~~ `代码` ==高亮== [链接](https://example.com) #private #学习 [[entry:1|引用]] 正在输入拼音\n'
            '> 普通引用\n'
            '> [!insight] 洞察\n'
            '- [ ] 待办任务\n'
            '- 无序项\n'
            '1. 有序项\n'
            '---\n'
            '```dart\n'
            'final x = 1; // #comment * 2\n'
            '```\n'
            '![[ai:abc|总结]]';

        final composingStart = sample.indexOf('正在输入拼音');
        final composingEnd = composingStart + '正在输入拼音'.length;

        final controller = BlinkSyntaxTextController()
          ..value = TextEditingValue(
            text: sample,
            selection: TextSelection.collapsed(offset: composingEnd),
            composing: TextRange(start: composingStart, end: composingEnd),
          );
        addTearDown(controller.dispose);

        late TextSpan built;
        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Builder(
              builder: (context) {
                built = controller.buildTextSpan(
                  context: context,
                  withComposing: true,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect(built.toPlainText(), sample);
        expect(built.toPlainText().length, sample.length);
        final children = built.children ?? const <InlineSpan>[];
        expect(children.whereType<WidgetSpan>(), isEmpty);

        final underlined = children.whereType<TextSpan>().where(
          (span) => span.style?.decoration == TextDecoration.underline,
        );
        expect(underlined.map((s) => s.text ?? '').join(), '正在输入拼音');

        // Mutations must stay blocked while composing is active.
        expect(controller.isComposing, isTrue);
        expect(controller.insertSnippetIfNotComposing('**x**'), isFalse);
        expect(controller.text, sample);

        // Verify WYSIWYG active-block configuration (enableBlockPrefixes=false)
        // and code-block mode (enableInlineSyntax=false) preserve 1:1 length too.
        final blockCtrl = BlinkSyntaxTextController(
          text: '**加粗** 与 ==高亮==',
          enableBlockPrefixes: false,
          overrideBaseStyle: BlinkTypography.heading1(BlinkColorTokens.day),
        );
        final codeCtrl = BlinkSyntaxTextController(
          text: 'final a = b * c; // #not-tag',
          enableBlockPrefixes: false,
          enableInlineSyntax: false,
        );
        addTearDown(blockCtrl.dispose);
        addTearDown(codeCtrl.dispose);

        late TextSpan blockSpan;
        late TextSpan codeSpan;
        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Builder(
              builder: (context) {
                blockSpan = blockCtrl.buildTextSpan(
                  context: context,
                  withComposing: false,
                );
                codeSpan = codeCtrl.buildTextSpan(
                  context: context,
                  withComposing: false,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(blockSpan.toPlainText(), blockCtrl.text);
        expect(codeSpan.toPlainText(), codeCtrl.text);
      },
    );
  });

  group('BfmPreviewView upgraded Markdown rendering', () {
    testWidgets(
      'renders lists, blockquotes, dividers, strikethrough, links with zero BFM jargon',
      (tester) async {
        TaskStatus? toggledStatus;
        int? toggledLine;
        const md = '''# 笔记标题

- 无序第一项
1. 有序第一项
> 这是一段引用
---
包含 ~~删除文本~~ 与 [文档链接](https://example.com)
- [ ] 待办任务''';

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: BfmPreviewView(
                  bodyMd: md,
                  onToggleTaskLine: (lineIndex, nextStatus) {
                    toggledLine = lineIndex;
                    toggledStatus = nextStatus;
                  },
                ),
              ),
            ),
          ),
        );

        expect(find.text('•'), findsOneWidget);
        expect(find.text('1.'), findsOneWidget);
        expect(find.byType(Divider), findsOneWidget);
        expect(find.textContaining('BFM'), findsNothing);

        await tester.tap(find.byIcon(Icons.check_box_outline_blank_rounded));
        await tester.pump();
        expect(toggledLine, 7);
        expect(toggledStatus, TaskStatus.done);
      },
    );
  });

  group('BlinkMarkdownEditor WYSIWYG, Source & SPK-02 CJK IME tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_wysiwyg_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<
      ({
        DesktopLifecycleController lifecycle,
        VaultManager vault,
        BlinkWorkspaceController workspace,
      })
    >
    createWorkspaceFixture(
      WidgetTester tester, {
      NoteEditorMode initialMode = NoteEditorMode.wysiwyg,
    }) async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final buildInfo = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
        version: '0.1.0-dev.202611280000',
        gitSha: 'abcdef1',
      );
      final lifecycle = DesktopLifecycleController(
        buildInfo: buildInfo,
        paths: paths,
        settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
        windowAdapter: _NoopWindowAdapter(),
        trayAdapter: _NoopTrayAdapter(),
      );
      await lifecycle.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );
      final vault = (await tester.runAsync(
        () => VaultManager.open(
          VaultConfig(
            vaultDir: paths.vaultDir,
            expectedChannel: BlinkChannel.blinkDev,
            enableMirrorExporter: false,
          ),
        ),
      ))!;
      final workspace = BlinkWorkspaceController(
        lifecycle: lifecycle,
        filePicker: _FakeFilePicker(),
        initialVault: vault,
        initialDestination: BlinkNavDestination.notes,
        initialNoteEditorMode: initialMode,
        enableMirrorExporter: false,
      );
      await tester.runAsync(() => workspace.initialize());
      addTearDown(() async {
        workspace.dispose();
        await tester.runAsync(() async {
          if (vault.isOpen) {
            await vault.checkpointAndClose();
          }
        });
      });
      return (lifecycle: lifecycle, vault: vault, workspace: workspace);
    }

    testWidgets(
      'renders Typora-style WYSIWYG by default and focuses blocks in-place on tap',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(
            bodyMd: '# 我的长笔记\n\n包含 **加粗** 和 ==高亮==\n\n- 要点一\n\n> 灵感引用',
          ),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: note,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.noteEditorMode, NoteEditorMode.wysiwyg);
        expect(find.byKey(const Key('editor_mode_toggle')), findsOneWidget);
        expect(find.byKey(const Key('note_source_input')), findsNothing);

        // Desktop editor toolbar sits cleanly at the bottom below the document canvas.
        final editorRect = tester.getRect(
          find.byKey(const Key('blink_markdown_editor')),
        );
        final toolbarRect = tester.getRect(
          find.byKey(const Key('note_editor_toolbar')),
        );
        final firstBlockRect = tester.getRect(
          find.byKey(const Key('wysiwyg_block_0')),
        );
        expect(toolbarRect.height, 40.0);
        expect(toolbarRect.bottom, closeTo(editorRect.bottom, 0.5));
        expect(toolbarRect.top, greaterThan(firstBlockRect.top));

        // Inactive blocks hide raw Markdown markers (`# `, `**`, `==`, `> `).
        expect(find.textContaining('# 我的长笔记'), findsNothing);
        expect(find.textContaining('**加粗**'), findsNothing);
        expect(find.textContaining('==高亮=='), findsNothing);
        expect(find.text('•'), findsOneWidget);

        // Clicking block 0 focuses it in-place as a borderless TextField.
        await tester.tap(find.byKey(const Key('wysiwyg_block_0')));
        await tester.pumpAndSettle();
        final activeField = tester.widget<TextField>(find.byType(TextField));
        expect(activeField.controller?.text, '我的长笔记');
      },
    );

    testWidgets(
      'live prefix shortcuts (# , - , - [ ] , > ), Enter split/continue, Backspace revert, divider & code block',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: ''),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: note,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Empty note starts with block 0 active and ready to type.
        expect(find.byType(TextField), findsOneWidget);
        await tester.tap(find.byType(TextField));
        await tester.pump();

        // `# ` converts paragraph -> H1 immediately.
        await tester.enterText(find.byType(TextField), '# 实时标题');
        await tester.pump();
        expect(find.text('H1'), findsOneWidget);
        var ctrl =
            tester.widget<TextField>(find.byType(TextField)).controller!
                as BlinkSyntaxTextController;
        expect(ctrl.text, '实时标题');

        // Enter splits to new paragraph (block 1).
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wysiwyg_block_1')), findsOneWidget);

        // `- ` converts paragraph -> bulletList.
        await tester.enterText(find.byType(TextField), '- 列表项一');
        await tester.pump();
        expect(find.text('•'), findsOneWidget);

        // Enter continues bullet list (block 2).
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wysiwyg_block_2')), findsOneWidget);
        expect(find.text('•'), findsNWidgets(2));

        // Enter on empty list item reverts block 2 back to paragraph.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('•'), findsOneWidget);

        // `- [ ] ` converts paragraph -> taskItem.
        await tester.enterText(find.byType(TextField), '- [ ] 核对清单');
        await tester.pump();
        expect(
          find.byIcon(Icons.check_box_outline_blank_rounded),
          findsOneWidget,
        );

        // Backspace at offset 0 reverts taskItem -> paragraph preserving text.
        ctrl =
            tester.widget<TextField>(find.byType(TextField)).controller!
                as BlinkSyntaxTextController;
        ctrl.selection = const TextSelection.collapsed(offset: 0);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(
          find.byIcon(Icons.check_box_outline_blank_rounded),
          findsNothing,
        );
        expect(ctrl.text, '核对清单');

        // Enter to new block 3, test `---` + Enter -> divider + block 4.
        ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '---');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wysiwyg_block_4')), findsOneWidget);

        // Test ```` ```dart ```` + Enter -> codeBlock.
        await tester.enterText(find.byType(TextField), '```dart');
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('dart'), findsOneWidget);

        // Flush pending auto-save timers before teardown.
        await tester.pump(const Duration(milliseconds: 700));
        await _drainIo(tester);
      },
    );

    testWidgets(
      'switches cleanly between WYSIWYG and Source via button and Ctrl+/ with zero data loss',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        const initialMd = '# 双模式测试\n\n第一段包含 **加粗**。\n\n- [ ] 待办项';
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: initialMd),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: note,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Toggle to Source via prominent toolbar button.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        expect(fixture.workspace.noteEditorMode, NoteEditorMode.source);
        expect(find.byKey(const Key('note_source_input')), findsOneWidget);

        final sourceField = tester.widget<TextField>(
          find.byKey(const Key('note_source_input')),
        );
        expect(sourceField.controller?.text, initialMd);

        // Edit in Source mode and switch back to WYSIWYG via Ctrl+/.
        const updatedMd = '$initialMd\n\n> 新增引用';
        await tester.enterText(
          find.byKey(const Key('note_source_input')),
          updatedMd,
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.slash);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();

        expect(fixture.workspace.noteEditorMode, NoteEditorMode.wysiwyg);
        expect(find.byKey(const Key('note_source_input')), findsNothing);
        // Verify newly added quote block is rendered in WYSIWYG!
        expect(find.byKey(const Key('wysiwyg_block_3')), findsOneWidget);

        // Toggle back to Source to confirm zero loss.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        final roundTripped = tester.widget<TextField>(
          find.byKey(const Key('note_source_input')),
        );
        expect(roundTripped.controller?.text, updatedMd);

        await tester.pump(const Duration(milliseconds: 700));
        await _drainIo(tester);
      },
    );

    testWidgets(
      'SPK-02 CJK IME protection in BOTH WYSIWYG and Source modes blocks shortcuts, keys, and autocomplete while composing',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: ''),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: note,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. WYSIWYG mode: simulate CJK IME pre-edit with `# nihao` composing.
        await tester.tap(find.byType(TextField));
        await tester.pump();
        final blockField = tester.widget<TextField>(find.byType(TextField));
        final blockCtrl = blockField.controller! as BlinkSyntaxTextController;
        final blockNode = blockField.focusNode!;

        const wysiwygComposing = TextEditingValue(
          text: '# nihao',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 2, end: 7),
        );
        blockCtrl.value = wysiwygComposing;
        await tester.pump();

        // Prefix shortcut `# ` MUST NOT convert block while composing!
        expect(find.text('H1'), findsNothing);
        expect(blockCtrl.value, wysiwygComposing);

        // SPK-02 Rule 3: Enter/Space/Tab/Esc/Arrows MUST return
        // KeyEventResult.ignored on the live WYSIWYG FocusNode while composing,
        // so the OS IME consumes candidate navigation/commit without splitting
        // or moving blocks.
        for (final key in const <LogicalKeyboardKey>[
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          final result = blockNode.onKeyEvent!(
            blockNode,
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.enter,
              logicalKey: key,
              timeStamp: Duration.zero,
            ),
          );
          expect(result, KeyEventResult.ignored, reason: 'WYSIWYG key $key');
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byKey(const Key('wysiwyg_block_1')), findsNothing);
        expect(find.text('H1'), findsNothing);
        expect(blockCtrl.value, wysiwygComposing);

        // Autocomplete trigger `[[量子` MUST NOT open popup while composing.
        blockCtrl.value = const TextEditingValue(
          text: '测试 [[量子',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 5, end: 7),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('note_autocomplete_overlay')),
          findsNothing,
        );

        // Commit composition -> clear composing cleanly and switch to Source mode.
        blockCtrl.value = const TextEditingValue(
          text: '测试内容',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange.empty,
        );
        await tester.pump();

        // 2. Source mode: verify IME composition blocks autocomplete & key interception.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        final sourceField = tester.widget<TextField>(
          find.byKey(const Key('note_source_input')),
        );
        final sourceCtrl = sourceField.controller! as BlinkSyntaxTextController;
        final sourceNode = sourceField.focusNode!;

        sourceCtrl.value = const TextEditingValue(
          text: '源码 #pri',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange(start: 4, end: 7),
        );
        await tester.pump();
        expect(
          find.byKey(const Key('note_autocomplete_overlay')),
          findsNothing,
        );

        for (final key in const <LogicalKeyboardKey>[
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          final result = sourceNode.onKeyEvent!(
            sourceNode,
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.enter,
              logicalKey: key,
              timeStamp: Duration.zero,
            ),
          );
          expect(result, KeyEventResult.ignored, reason: 'Source key $key');
        }
        expect(sourceCtrl.text, '源码 #pri');

        // Once composition finishes (`composing: TextRange.empty`), `#pri` triggers autocomplete.
        sourceCtrl.value = const TextEditingValue(
          text: '源码 #pri',
          selection: TextSelection.collapsed(offset: 7),
          composing: TextRange.empty,
        );
        await _drainIo(tester);
        expect(
          find.byKey(const Key('note_autocomplete_overlay')),
          findsOneWidget,
        );

        await tester.pump(const Duration(milliseconds: 700));
        await _drainIo(tester);
      },
    );

    testWidgets(
      'trashed note shows read-only restore/purge banner and BlinkNotesSidebar/Page work end-to-end',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final created = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 待删除笔记\n\n正文内容'),
        ))!;
        await tester.runAsync(
          () => fixture.workspace.softDeleteEntry(created.id),
        );
        final trashed = (await tester.runAsync(
          () =>
              fixture.vault.raw.getEntryById(created.id, includeDeleted: true),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: Row(
                children: <Widget>[
                  SizedBox(
                    width: 260,
                    child: BlinkNotesSidebar(workspace: fixture.workspace),
                  ),
                  Expanded(
                    child: BlinkMarkdownEditor(
                      workspace: fixture.workspace,
                      entry: trashed,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('note_trash_banner')), findsOneWidget);
        expect(find.text('此笔记在回收站中，不清理将一直保留'), findsOneWidget);
        expect(find.textContaining('30 天'), findsNothing);
        expect(
          find.byKey(const Key('note_trash_restore_button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('note_trash_purge_button')),
          findsOneWidget,
        );
        expect(find.byType(TextField), findsNothing);

        // Sidebar filter pills and new note button exist with expected keys.
        expect(find.byKey(const Key('new_note_button')), findsOneWidget);
        expect(find.byKey(const Key('notes_filter_all')), findsOneWidget);
        expect(find.byKey(const Key('notes_filter_private')), findsOneWidget);
        expect(find.byKey(const Key('notes_filter_trash')), findsOneWidget);

        // Tapping restore restores the entry in the vault.
        await tester.tap(find.byKey(const Key('note_trash_restore_button')));
        await _drainIo(tester);
        final restored = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(created.id),
        );
        expect(restored, isNotNull);
        expect(restored!.isDeleted, isFalse);
      },
    );

    testWidgets(
      'P0 #1: disposed BlinkMarkdownEditor unregisters shutdown hook and never overwrites newer raw edits (INV-01)',
      (tester) async {
        final fixture = await createWorkspaceFixture(
          tester,
          initialMode: NoteEditorMode.source,
        );
        final created = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 初始标题\n\n- [ ] 待办'),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: created,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Dirty edit (< 600ms, before debounce timer fires), then unmount editor.
        await tester.enterText(
          find.byKey(const Key('note_source_input')),
          '# Dirty in Source Mode',
        );
        await tester.pump();

        // Unmount editor (simulates switching to Tasks/Settings tab).
        await tester.pumpWidget(
          MaterialApp(theme: BlinkTheme.day(), home: const SizedBox.shrink()),
        );
        await _drainIo(tester);

        // Simulate newer update made elsewhere (e.g. Tasks toggle or sync).
        const newerBody = '# NEWER EDIT FROM TASKS\n\n- [x] Done';
        await tester.runAsync(
          () => fixture.workspace.updateNote(created.id, bodyMd: newerBody),
        );

        // Trigger shutdown draft flush hooks — disposed editor MUST NOT overwrite!
        await tester.runAsync(() => fixture.workspace.flushPendingDrafts());

        final persisted = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(created.id),
        );
        expect(persisted, isNotNull);
        expect(persisted!.bodyMd, newerBody);
      },
    );

    testWidgets(
      'P2 #5: WYSIWYG slash templates (/insight, /fold) convert in-place to callout/fold blocks without raw syntax residue',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: ''),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkMarkdownEditor(
                workspace: fixture.workspace,
                entry: note,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Accept `/insight` template -> converts in-place to styled Callout block.
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.enterText(find.byType(TextField), '/insight');
        await _drainIo(tester);
        expect(
          find.byKey(const Key('note_autocomplete_candidate_0')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('note_autocomplete_candidate_0')),
        );
        await tester.pumpAndSettle();

        expect(find.text('INSIGHT'), findsOneWidget);
        expect(find.textContaining('[!insight]'), findsNothing);

        // Verify clean Markdown serialization in Source mode.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        var sourceField = tester.widget<TextField>(
          find.byKey(const Key('note_source_input')),
        );
        expect(sourceField.controller?.text, '> [!insight] 洞察\n>');

        // Clear and test `/fold` template in WYSIWYG mode.
        await tester.enterText(find.byKey(const Key('note_source_input')), '');
        await tester.pump();
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('wysiwyg_block_0')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '/fold');
        await _drainIo(tester);
        expect(
          find.byKey(const Key('note_autocomplete_candidate_0')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('note_autocomplete_candidate_0')),
        );
        await tester.pumpAndSettle();

        expect(find.text('折叠标题'), findsOneWidget);
        expect(find.textContaining(':::fold'), findsNothing);

        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        sourceField = tester.widget<TextField>(
          find.byKey(const Key('note_source_input')),
        );
        expect(sourceField.controller?.text, ':::fold 折叠标题\n内容\n:::');

        await tester.pump(const Duration(milliseconds: 700));
        await _drainIo(tester);
      },
    );

    testWidgets(
      'P2 #7: mobile external jump auto-opens BlinkMobileNoteEditorScreen once and returning keeps note highlighted without loop',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 外部跳转笔记\n\n正文内容'),
        ))!;
        // Clear pending open to simulate browsing the list first.
        fixture.workspace.clearPendingMobileNoteOpen();

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: BlinkNotesPage(
                workspace: fixture.workspace,
                isMobile: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially shows mobile list with the selected note highlighted.
        expect(find.byKey(const Key('mobile_notes_header')), findsOneWidget);
        expect(
          find.byKey(const Key('mobile_note_editor_screen')),
          findsNothing,
        );
        final listTileMaterial = tester.widget<Material>(
          find
              .ancestor(
                of: find.byKey(Key('note_list_item_${note.id}')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(listTileMaterial.color, BlinkColorTokens.day.accentSubtle);

        // External jump (`openEntryById`) auto-pushes BlinkMobileNoteEditorScreen.
        await tester.runAsync(() => fixture.workspace.openEntryById(note.id));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('mobile_note_editor_screen')),
          findsOneWidget,
        );

        // Tapping `< 返回` returns cleanly to mobile notes list with ZERO re-push loop!
        await tester.tap(find.byKey(const Key('mobile_note_back_button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('mobile_note_editor_screen')),
          findsNothing,
        );
        expect(find.byKey(const Key('mobile_notes_header')), findsOneWidget);
      },
    );

    testWidgets(
      'note editor private toggle cancels privacy cleanly (strips #private, migrates FTS & tasks, updates sidebar count)',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(
            bodyMd: '# 私密设计稿 #private\n\n- [ ] 核对核心隐私链路',
            isPrivate: true,
          ),
        ))!;
        expect(note.isPrivate, isTrue);
        expect(fixture.workspace.privateNoteCount, 1);

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: ListenableBuilder(
                listenable: fixture.workspace,
                builder: (context, _) => Row(
                  children: <Widget>[
                    SizedBox(
                      width: 260,
                      child: BlinkNotesSidebar(workspace: fixture.workspace),
                    ),
                    Expanded(
                      child: BlinkMarkdownEditor(
                        workspace: fixture.workspace,
                        entry: fixture.workspace.selectedNote,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initially hidden from normalOnly search.
        expect(
          await tester.runAsync(
            () => fixture.vault.search.search(
              '私密设计稿',
              scope: PrivacyScope.normalOnly,
            ),
          ),
          isEmpty,
        );

        // Toggle 私密 OFF -> strips `#private`, persists `isPrivate: false`, migrates FTS & tasks!
        await tester.tap(find.byKey(const Key('note_editor_private_toggle')));
        await _drainIo(tester);

        final afterCancel = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(note.id),
        ))!;
        expect(afterCancel.isPrivate, isFalse);
        expect(afterCancel.bodyMd, isNot(contains('#private')));
        expect(afterCancel.bodyMd, contains('私密设计稿'));
        expect(afterCancel.bodyMd, contains('核对核心隐私链路'));
        expect(fixture.workspace.privateNoteCount, 0);

        final normalHits = (await tester.runAsync(
          () => fixture.vault.search.search(
            '私密设计稿',
            scope: PrivacyScope.normalOnly,
          ),
        ))!;
        expect(normalHits.map((h) => h.docId), contains(note.id));

        final tasks = (await tester.runAsync(
          () => fixture.vault.raw.listTasks(),
        ))!;
        expect(tasks, hasLength(1));
        expect(tasks.first.isPrivate, isFalse);

        // Toggle 私密 back ON (lock only, no `#private` token), then back OFF cleanly!
        await tester.tap(find.byKey(const Key('note_editor_private_toggle')));
        await _drainIo(tester);
        expect(
          (await tester.runAsync(
            () => fixture.vault.raw.getEntryById(note.id),
          ))!.isPrivate,
          isTrue,
        );
        expect(fixture.workspace.privateNoteCount, 1);

        await tester.tap(find.byKey(const Key('note_editor_private_toggle')));
        await _drainIo(tester);
        expect(
          (await tester.runAsync(
            () => fixture.vault.raw.getEntryById(note.id),
          ))!.isPrivate,
          isFalse,
        );
        expect(fixture.workspace.privateNoteCount, 0);
      },
    );

    testWidgets(
      'desktop bottom toolbar condenses cleanly into overflow menu at narrow widths (420px) with zero RenderFlex overflow',
      (tester) async {
        final fixture = await createWorkspaceFixture(tester);
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 窄栏底部工具栏测试\n\n正文'),
        ))!;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: Scaffold(
              body: SizedBox(
                width: 420,
                height: 500,
                child: BlinkMarkdownEditor(
                  workspace: fixture.workspace,
                  entry: note,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('note_editor_toolbar')), findsOneWidget);
        expect(find.byKey(const Key('note_fmt_overflow')), findsOneWidget);
        expect(find.byKey(const Key('editor_mode_toggle')), findsOneWidget);
      },
    );
  });
}
