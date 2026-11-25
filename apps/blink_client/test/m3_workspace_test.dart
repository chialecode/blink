import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';

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
  String? openFileResult;
  String? saveFileResult;
  String? directoryResult;

  @override
  Future<String?> pickFileToOpen({String? title}) async => openFileResult;

  @override
  Future<String?> pickFileToSave({
    String? title,
    String? suggestedFileName,
  }) async => saveFileResult;

  @override
  Future<String?> pickDirectory({String? title}) async => directoryResult;
}

/// Drains multi-step `dart:io` futures triggered from UI `onPressed` callbacks
/// inside Flutter's `FakeAsync` widget test zone until [until] succeeds.
Future<void> _drainRealIo(
  WidgetTester tester, {
  bool Function()? until,
  int maxRounds = 40,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    await tester.pump();
    if (until != null && until()) {
      break;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  await tester.pumpAndSettle();
}

void main() {
  group('SPK-02 CJK IME 5 rules unit tests', () {
    test('Rule 1 & 4: blocks mutation & trigger detection while composing', () {
      final controller = BlinkSyntaxTextController();
      addTearDown(controller.dispose);

      const composingValue = TextEditingValue(
        text: '测试 [[量子',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 5, end: 7),
      );
      controller.value = composingValue;

      expect(controller.isComposing, isTrue);
      expect(
        BlinkSyntaxTextController.detectAutocompleteTrigger(composingValue),
        isNull,
      );

      // Must refuse atomic replacement and snippet insertion while composing.
      final applied = controller.applyAutocompleteSelection(
        const AutocompleteTrigger(
          kind: AutocompleteTriggerKind.wikiLink,
          triggerStart: 3,
          triggerEnd: 7,
          query: '量子',
        ),
        '[[entry:abc|量子]]',
      );
      expect(applied, isFalse);
      expect(controller.value, composingValue);
      expect(controller.insertSnippetIfNotComposing('#tag'), isFalse);
      expect(controller.value, composingValue);
    });

    test(
      'Rule 3: Enter/Space/Tab/Esc/arrows return ignored while composing',
      () {
        var submitted = false;
        var dismissed = false;
        const composingValue = TextEditingValue(
          text: 'zhongwen',
          selection: TextSelection.collapsed(offset: 8),
          composing: TextRange(start: 0, end: 8),
        );

        for (final logicalKey in const <LogicalKeyboardKey>[
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.tab,
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.arrowDown,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ]) {
          final result = BlinkSyntaxTextController.handleImeFirstKeyEvent(
            composingValue,
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.enter,
              logicalKey: logicalKey,
              timeStamp: Duration.zero,
            ),
            hasOverlay: true,
            onSubmit: () => submitted = true,
            onDismissOverlay: () => dismissed = true,
          );
          expect(result, KeyEventResult.ignored);
        }
        expect(submitted, isFalse);
        expect(dismissed, isFalse);
      },
    );

    test('Rule 4: detects [[, #, / when collapsed and replaces atomically', () {
      final controller = BlinkSyntaxTextController();
      addTearDown(controller.dispose);

      // Non-collapsed selection must not trigger autocomplete.
      expect(
        BlinkSyntaxTextController.detectAutocompleteTrigger(
          const TextEditingValue(
            text: '笔记 #学习',
            selection: TextSelection(baseOffset: 3, extentOffset: 6),
          ),
        ),
        isNull,
      );

      controller.value = const TextEditingValue(
        text: '查看 [[知识',
        selection: TextSelection.collapsed(offset: 7),
      );
      final wikiTrigger = BlinkSyntaxTextController.detectAutocompleteTrigger(
        controller.value,
      );
      expect(wikiTrigger, isNotNull);
      expect(wikiTrigger!.kind, AutocompleteTriggerKind.wikiLink);
      expect(wikiTrigger.query, '知识');

      final replaced = controller.applyAutocompleteSelection(
        wikiTrigger,
        '[[entry:id-1|知识图谱]]',
      );
      expect(replaced, isTrue);
      expect(controller.text, '查看 [[entry:id-1|知识图谱]]');
      expect(controller.value.composing, TextRange.empty);
      expect(controller.selection.isCollapsed, isTrue);

      final tagTrigger = BlinkSyntaxTextController.detectAutocompleteTrigger(
        const TextEditingValue(
          text: '今日记录 #pri',
          selection: TextSelection.collapsed(offset: 9),
        ),
      );
      expect(tagTrigger?.kind, AutocompleteTriggerKind.tag);
      expect(tagTrigger?.query, 'pri');

      final slashTrigger = BlinkSyntaxTextController.detectAutocompleteTrigger(
        const TextEditingValue(
          text: '/ins',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      expect(slashTrigger?.kind, AutocompleteTriggerKind.slash);
      expect(slashTrigger?.query, 'ins');
    });

    testWidgets(
      'Rule 2: buildTextSpan is strictly 1:1 UTF-16 length-preserving with underline on composing range',
      (tester) async {
        final controller = BlinkSyntaxTextController();
        addTearDown(controller.dispose);

        const sample =
            '==高亮== #tag #private [[entry:123|标题]] 正在输入拼音\n> [!insight] 洞察\n- [ ] 待办';
        controller.value = const TextEditingValue(
          text: sample,
          selection: TextSelection.collapsed(offset: 44),
          composing: TextRange(start: 38, end: 44),
        );

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

        // Strictly 1:1 UTF-16 length and zero WidgetSpan.
        expect(built.toPlainText(), sample);
        expect(built.toPlainText().length, sample.length);
        final children = built.children ?? const <InlineSpan>[];
        expect(children.whereType<WidgetSpan>(), isEmpty);

        // Composing range substring must keep native underline decoration.
        final underlined = children.whereType<TextSpan>().where(
          (span) => span.style?.decoration == TextDecoration.underline,
        );
        expect(
          underlined.map((span) => span.text ?? '').join(),
          sample.substring(38, 44),
        );
      },
    );
  });

  group('M3 Desktop Workspace end-to-end widget tests', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_m3_workspace_test_');
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
        _FakeFilePicker picker,
      })
    >
    createFixture(
      WidgetTester tester, {
      String channel = 'blink-dev',
      bool enableMirror = false,
      BlinkNavDestination initialDestination = BlinkNavDestination.stream,
    }) async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final buildInfo = BlinkBuildInfo.normalized(
        channel: channel,
        identity: channel,
        version: '0.1.0-dev.202611251200',
        gitSha: '1234567',
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
            expectedChannel: channel == 'blink'
                ? BlinkChannel.blink
                : BlinkChannel.blinkDev,
            enableMirrorExporter: enableMirror,
          ),
        ),
      ))!;
      final picker = _FakeFilePicker();
      final workspace = BlinkWorkspaceController(
        lifecycle: lifecycle,
        filePicker: picker,
        initialVault: vault,
        initialDestination: initialDestination,
        enableMirrorExporter: enableMirror,
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
      return (
        lifecycle: lifecycle,
        vault: vault,
        workspace: workspace,
        picker: picker,
      );
    }

    testWidgets(
      'adaptive 4 breakpoints render cleanly without horizontal overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(tester);
        for (final size in const <Size>[
          Size(1360, 800),
          Size(1024, 700),
          Size(760, 560),
          Size(420, 800),
        ]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            BlinkApp(
              controller: fixture.lifecycle,
              workspaceController: fixture.workspace,
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('nav_stream')), findsOneWidget);
          expect(find.byKey(const Key('nav_files')), findsOneWidget);
          expect(find.byKey(const Key('nav_tasks')), findsOneWidget);
          expect(find.byKey(const Key('nav_settings')), findsOneWidget);

          if (size.width < 600) {
            expect(find.byKey(const Key('mobile_bottom_nav')), findsOneWidget);
            expect(find.byKey(const Key('desktop_nav_rail')), findsNothing);
          } else {
            expect(find.byKey(const Key('desktop_nav_rail')), findsOneWidget);
            expect(find.byKey(const Key('mobile_bottom_nav')), findsNothing);
          }
        }
      },
    );

    testWidgets(
      'creates BFM v1 entry with #private, split preview, CJK FTS5 search, endogenous task sync, and 30-day trash',
      (tester) async {
        tester.view.physicalSize = const Size(1360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(tester);
        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // Toggle 150ms split preview and enter BFM v1 content.
        await tester.tap(find.byKey(const Key('editor_preview_toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bfm_split_preview')), findsOneWidget);

        const body =
            '# 量子计算笔记\n==核心洞察== #研究 #private\n- [ ] 完成量子算法复盘\n> [!insight] 重点\n> 保持本地隔离\n:::fold 详细推导\n隐蔽细节\n:::';
        await tester.enterText(find.byKey(const Key('bfm_editor_input')), body);
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pumpAndSettle();

        // Preview reflects headings & callout.
        expect(find.textContaining('量子计算笔记'), findsWidgets);

        // Submit entry.
        await tester.tap(find.byKey(const Key('bfm_submit_button')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final entries = await tester.runAsync(
          () => fixture.vault.raw.listEntries(),
        );
        expect(entries, hasLength(1));
        final created = entries!.first;
        expect(created.isPrivate, isTrue);
        expect(
          find.byKey(Key('entry_private_badge_${created.id}')),
          findsOneWidget,
        );

        // Live CJK FTS5 search via search button (`Ctrl+K` modal).
        await tester.tap(find.byKey(const Key('open_search_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_modal')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('search_modal_input')),
          '量子算法',
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(Key('search_hit_${created.id}')), findsOneWidget);
        await tester.tap(find.byKey(Key('search_hit_${created.id}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_modal')), findsNothing);

        // Endogenous Tasks view: toggle `- [ ]` -> `- [x]` syncs to raw_entries.body_md.
        await tester.tap(find.byKey(const Key('nav_tasks')));
        await tester.pumpAndSettle();

        final tasks = await tester.runAsync(
          () => fixture.vault.raw.listTasks(),
        );
        expect(tasks, hasLength(1));
        final task = tasks!.first;
        expect(task.status, TaskStatus.open);

        await tester.tap(find.byKey(Key('task_toggle_${task.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final updatedEntry = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(created.id),
        );
        expect(updatedEntry!.bodyMd, contains('- [x] 完成量子算法复盘'));

        // Jump back to source entry from Tasks view.
        await tester.tap(find.byKey(Key('task_source_${task.id}')));
        await tester.pumpAndSettle();
        expect(fixture.workspace.destination, BlinkNavDestination.stream);

        // Soft-delete to 30-day Trash -> restore -> soft-delete -> purge permanently.
        await tester.tap(find.byKey(Key('entry_delete_${created.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('filter_trash')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('trash_restore_${created.id}')), findsOneWidget);

        await tester.tap(find.byKey(Key('trash_restore_${created.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final restored = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(created.id),
        );
        expect(restored, isNotNull);
        expect(restored!.isDeleted, isFalse);

        // Delete again and permanently purge.
        await tester.runAsync(
          () => fixture.workspace.softDeleteEntry(created.id),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('trash_purge_${created.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();

        final afterPurge = await tester.runAsync(
          () =>
              fixture.vault.raw.getEntryById(created.id, includeDeleted: true),
        );
        expect(afterPurge, isNull);
      },
    );

    testWidgets(
      'imports, exports, and GCs content-addressed blobs via fake BlinkFilePicker',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.files,
        );

        final sampleSource = File(
          '${tempDir.path}${Platform.pathSeparator}sample_note.txt',
        )..writeAsStringSync('BLINK content-addressed attachment test');
        final exportTarget = File(
          '${tempDir.path}${Platform.pathSeparator}exported_copy.txt',
        );
        fixture.picker.openFileResult = sampleSource.path;
        fixture.picker.saveFileResult = exportTarget.path;

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('files_import_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.blobs.isNotEmpty,
        );

        final blobs = await tester.runAsync(
          () => fixture.vault.blobs.listBlobs(),
        );
        expect(blobs, hasLength(1));
        final blob = blobs!.first;
        expect(blob.mimeType, 'text/plain');
        expect(find.byKey(Key('blob_card_${blob.sha256}')), findsOneWidget);

        // Export copy and verify byte-for-byte fidelity.
        await tester.ensureVisible(
          find.byKey(Key('blob_export_${blob.sha256}')),
        );
        await tester.tap(find.byKey(Key('blob_export_${blob.sha256}')));
        await _drainRealIo(tester, until: () => exportTarget.existsSync());

        expect(exportTarget.existsSync(), isTrue);
        expect(
          exportTarget.readAsStringSync(),
          'BLINK content-addressed attachment test',
        );

        // Unreferenced blob is safely collected by GC (`INV-12`).
        await tester.tap(find.byKey(const Key('files_gc_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.blobs.isEmpty,
        );

        final afterGc = await tester.runAsync(
          () => fixture.vault.blobs.listBlobs(),
        );
        expect(afterGc, isEmpty);
      },
    );

    testWidgets(
      'switches Day/Sepia/Dark theme, surfaces honest channel_mismatch on wrong-channel vault, and runs hot backup/mirror',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          channel: 'blink-dev',
          enableMirror: true,
          initialDestination: BlinkNavDestination.settings,
        );

        // Create a production (`blink`) vault in a sibling temp folder.
        final prodVaultDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}prod_vault',
        );
        await tester.runAsync(() async {
          final prodVault = await VaultManager.open(
            VaultConfig(
              vaultDir: prodVaultDir,
              expectedChannel: BlinkChannel.blink,
              enableMirrorExporter: false,
            ),
          );
          await prodVault.checkpointAndClose();
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // Switch theme to Sepia and verify BlinkColorTokens.sepia canvas.
        await tester.tap(find.text('暖纸'));
        await tester.pumpAndSettle();
        final sepiaScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(sepiaScaffold.backgroundColor, BlinkColorTokens.sepia.canvas);
        expect(
          fixture.lifecycle.settings.surfaceMode,
          DesktopSurfacePreference.sepia,
        );

        // Switch theme to Dark and verify BlinkColorTokens.dark canvas.
        await tester.tap(find.text('夜间'));
        await tester.pumpAndSettle();
        final darkScaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(darkScaffold.backgroundColor, BlinkColorTokens.dark.canvas);

        // Attempt to switch blink-dev client to blink prod vault -> channel_mismatch banner!
        await tester.ensureVisible(find.byKey(const Key('vault_path_input')));
        await tester.enterText(
          find.byKey(const Key('vault_path_input')),
          prodVaultDir.path,
        );
        await tester.ensureVisible(
          find.byKey(const Key('vault_switch_button')),
        );
        await tester.tap(find.byKey(const Key('vault_switch_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.vaultErrorCode != null,
        );

        expect(
          fixture.workspace.vaultErrorCode,
          BlinkErrorCode.channelMismatch,
        );
        expect(find.byKey(const Key('vault_error_banner')), findsOneWidget);
        expect(find.textContaining('channel_mismatch'), findsWidgets);
        // Original blink-dev vault stays open & unharmed.
        expect(fixture.workspace.vault?.isOpen, isTrue);

        // Hot backup (`VACUUM INTO`) & immediate `.md` mirror export succeed.
        final backup = await tester.runAsync(
          () => fixture.workspace.createHotBackup(),
        );
        expect(backup, isNotNull);
        expect(backup!.backupFile.existsSync(), isTrue);

        final mirrorOk = await tester.runAsync(
          () => fixture.workspace.flushMirrorNow(),
        );
        expect(mirrorOk, isTrue);
      },
    );

    test('shutdown flush hook saves pending draft, flushes mirror, and closes WAL before lifecycle.json', () async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final buildInfo = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );
      final exitCodes = <int>[];
      final lifecycle = DesktopLifecycleController(
        buildInfo: buildInfo,
        paths: paths,
        settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
        windowAdapter: _NoopWindowAdapter(),
        trayAdapter: _NoopTrayAdapter(),
        exitProcess: exitCodes.add,
      );
      await lifecycle.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );

      final workspace = BlinkWorkspaceController(
        lifecycle: lifecycle,
        filePicker: const NoopBlinkFilePicker(),
        enableMirrorExporter: true,
      );
      await workspace.initialize();

      final editor = BlinkEditorController(
        vaultProvider: () => workspace.vault,
      );
      workspace.registerDraftFlushHook(editor.flushDraftNow);
      editor.textController.text = '关机前尚未提交的草稿内容 #shutdown';

      await workspace.createEntry(bodyMd: '已提交的记录，等待退出刷镜像');

      final accepted = await lifecycle.performShutdown(
        ExitReason.quitForUpdate,
      );
      expect(accepted, isTrue);
      expect(exitCodes, const <int>[0]);
      expect(lifecycle.lastShutdownPersistenceError, isNull);
      expect(paths.lifecycleFile.existsSync(), isTrue);
      expect(workspace.vault!.isOpen, isFalse);

      // Re-open vault to verify draft survived shutdown & WAL checkpointed cleanly.
      final reopened = await VaultManager.open(
        VaultConfig(
          vaultDir: paths.vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      try {
        final recoveredDraft = await reopened.raw.loadDraft('inbox');
        expect(recoveredDraft, isNotNull);
        expect(recoveredDraft!.bodyMd, '关机前尚未提交的草稿内容 #shutdown');
      } finally {
        await reopened.checkpointAndClose();
        editor.dispose();
        workspace.dispose();
      }
    });
  });
}
