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
      BlinkNavDestination initialDestination = BlinkNavDestination.memos,
      SettingsCategory initialSettingsCategory = SettingsCategory.general,
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
        initialSettingsCategory: initialSettingsCategory,
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
      'adaptive 4 breakpoints render cleanly without AppBar, DEV topbar banner, or horizontal overflow',
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
          expect(find.byType(AppBar), findsNothing);
          expect(find.text('DEV 开发通道'), findsNothing);
          expect(find.byKey(const Key('nav_memos')), findsOneWidget);
          expect(find.byKey(const Key('nav_notes')), findsOneWidget);
          expect(find.byKey(const Key('nav_tasks')), findsOneWidget);
          expect(find.byKey(const Key('nav_settings')), findsOneWidget);

          if (size.width < 600) {
            expect(find.byKey(const Key('mobile_bottom_nav')), findsOneWidget);
            expect(find.byKey(const Key('nav_files')), findsNothing);
            expect(find.byKey(const Key('desktop_nav_rail')), findsNothing);
            expect(find.byKey(const Key('pane_divider_rail')), findsNothing);
            expect(
              find.byKey(const Key('open_sidebar_drawer_button')),
              findsOneWidget,
            );
            expect(
              find.byKey(const Key('mobile_search_button')),
              findsOneWidget,
            );
          } else {
            expect(find.byKey(const Key('desktop_nav_rail')), findsOneWidget);
            expect(find.byKey(const Key('nav_files')), findsOneWidget);
            expect(find.byKey(const Key('open_search_button')), findsOneWidget);
            expect(find.byKey(const Key('mobile_bottom_nav')), findsNothing);

            final railDivider = find.byKey(const Key('pane_divider_rail'));
            expect(railDivider, findsOneWidget);
            final railDividerRect = tester.getRect(railDivider);
            expect(railDividerRect.top, 0.0);
            expect(railDividerRect.height, size.height);
            expect(railDividerRect.width, 1.0);

            if (size.width >= 960) {
              final sidebarDivider = find.byKey(
                const Key('pane_divider_sidebar'),
              );
              expect(sidebarDivider, findsOneWidget);
              final sidebarDividerRect = tester.getRect(sidebarDivider);
              expect(sidebarDividerRect.top, 0.0);
              expect(sidebarDividerRect.height, size.height);
              expect(sidebarDividerRect.width, 1.0);
              expect(
                find.byKey(const Key('open_sidebar_drawer_button')),
                findsNothing,
              );
            } else {
              expect(
                find.byKey(const Key('pane_divider_sidebar')),
                findsNothing,
              );
              expect(
                find.byKey(const Key('open_sidebar_drawer_button')),
                findsOneWidget,
              );
            }
          }
        }

        // Compact tablet drawer toggle in the left rail opens the filter drawer cleanly.
        tester.view.physicalSize = const Size(760, 560);
        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('open_sidebar_drawer_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('filter_all')), findsOneWidget);

        // Close drawer, switch to Settings -> About, and verify brand mark + DEV badge live in About.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_compact_cat_about')));
        await tester.pumpAndSettle();
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('about_section')),
            matching: find.byKey(const Key('brand_mark')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('about_section')),
            matching: find.text('DEV 开发通道'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'creates memo with #private, CJK FTS5 search, task sync, jump back, and permanent local trash restore/purge',
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

        const body =
            '# 量子计算笔记\n==核心洞察== #研究 #private\n- [ ] 完成量子算法复盘\n> [!insight] 重点\n> 保持本地隔离\n:::fold 详细推导\n隐蔽细节\n:::';
        await tester.enterText(
          find.byKey(const Key('editor_text_field')),
          body,
        );
        await tester.pump(const Duration(milliseconds: 220));
        await tester.pumpAndSettle();

        // Submit memo.
        await tester.tap(find.byKey(const Key('editor_submit_button')));
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
          find.byKey(Key('memo_private_badge_${created.id}')),
          findsOneWidget,
        );
        expect(find.textContaining('量子计算笔记'), findsWidgets);

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

        // Tasks view: toggle `- [ ]` -> `- [x]` syncs to raw_entries.body_md.
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

        // Jump back to source memo from Tasks view.
        await tester.tap(find.byKey(Key('task_source_${task.id}')));
        await tester.pumpAndSettle();
        expect(fixture.workspace.destination, BlinkNavDestination.memos);

        // Soft-delete to 30-day Trash -> restore -> soft-delete -> purge permanently.
        await tester.tap(find.byKey(Key('memo_delete_${created.id}')));
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

        // Delete again and permanently purge via confirmation dialog.
        await tester.runAsync(
          () => fixture.workspace.softDeleteEntry(created.id),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('trash_purge_${created.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('trash_purge_confirm')));
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

        // Switch to Storage & Backup category, then attempt to switch blink-dev client to blink prod vault -> channel_mismatch banner!
        await tester.tap(find.byKey(const Key('settings_cat_storage')));
        await tester.pumpAndSettle();
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

    testWidgets(
      'settings shows non-blocking OneDrive hint when vault sits inside a OneDrive folder',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final oneDriveVaultDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}OneDrive${Platform.pathSeparator}Documents${Platform.pathSeparator}blink-dev',
        );
        final appLocalDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}app_local',
        );
        final paths = BlinkPaths(
          dataRoot: appLocalDir,
          defaultVaultDir: oneDriveVaultDir,
        );
        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
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
              vaultDir: oneDriveVaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        ))!;
        final workspace = BlinkWorkspaceController(
          lifecycle: lifecycle,
          filePicker: _FakeFilePicker(),
          initialVault: vault,
          initialDestination: BlinkNavDestination.settings,
          initialSettingsCategory: SettingsCategory.storage,
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

        await tester.pumpWidget(
          BlinkApp(controller: lifecycle, workspaceController: workspace),
        );
        await tester.pumpAndSettle();

        expect(find.text('数据文件夹'), findsWidgets);
        expect(find.byKey(const Key('vault_path_value')), findsOneWidget);
        expect(find.byKey(const Key('vault_onedrive_hint')), findsOneWidget);
        expect(find.textContaining('OneDrive'), findsWidgets);
        // Vault remains open and unblocked.
        expect(workspace.hasOpenVault, isTrue);
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

    testWidgets(
      'vault switch guards same-path reopen, flushes Vault A draft, and isolates Vault B editor & search (P1)',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          channel: 'blink-dev',
          enableMirror: false,
          initialDestination: BlinkNavDestination.memos,
        );
        final vaultADir = fixture.vault.config.vaultDir;
        final vaultBDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}clean_vault_b',
        );

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        const secretDraft = '绝密草稿 #private 不能泄漏到新库';
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('editor_text_field')),
          secretDraft,
        );
        await tester.pumpAndSettle();

        // Open search modal and set a query before switching vaults.
        await tester.tap(find.byKey(const Key('open_search_button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('search_modal_input')),
          '绝密',
        );
        await tester.pump();
        Navigator.of(tester.element(find.byKey(const Key('search_modal'))))
            .pop();
        await tester.pumpAndSettle();

        // Same-path re-open must be a safe no-op keeping Vault A open.
        final samePathOk = await tester.runAsync(
          () => fixture.workspace.switchVaultDirectory(vaultADir.path),
        );
        expect(samePathOk, isTrue);
        expect(fixture.vault.isOpen, isTrue);

        // Switch from Vault A -> clean Vault B.
        final switched = await tester.runAsync(
          () => fixture.workspace.switchVaultDirectory(vaultBDir.path),
        );
        expect(switched, isTrue);
        await _drainRealIo(tester);

        // Editor must be completely cleared on Vault B (zero Vault A leak).
        final editorField = tester.widget<TextField>(
          find.byKey(const Key('editor_text_field')),
        );
        expect(editorField.controller!.text, isEmpty);

        // Vault B's `editor_drafts` must contain zero leaked draft from Vault A.
        final vaultBDraft = await tester.runAsync(
          () => fixture.workspace.vault!.raw.loadDraft('inbox'),
        );
        expect(vaultBDraft, isNull);

        // Vault A's pending draft was flushed into Vault A before switching.
        final vaultADraft = await tester.runAsync(
          () => fixture.vault.raw.loadDraft('inbox'),
        );
        expect(vaultADraft, isNotNull);
        expect(vaultADraft!.bodyMd, secretDraft);
        expect(vaultADraft.privacyLocked, isTrue);

        // Search modal opens cleared after vault switch.
        await tester.tap(find.byKey(const Key('open_search_button')));
        await tester.pumpAndSettle();
        final searchField = tester.widget<TextField>(
          find.byKey(const Key('search_modal_input')),
        );
        expect(searchField.controller!.text, isEmpty);
      },
    );

    testWidgets(
      'deleting actively edited entry resets editor and submitting purged entry surfaces honest error banner (P2)',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.memos,
        );
        final entry1 = (await tester.runAsync(
          () => fixture.workspace.createMemo(bodyMd: '第一条待删小记\n* [ ] 星号待办'),
        ))!;
        final entry2 = (await tester.runAsync(
          () => fixture.workspace.createMemo(bodyMd: '第二条将被后台清除的小记'),
        ))!;

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // Start editing entry1 (select bubble to reveal desktop action strip), then soft-delete -> editor resets to empty inbox.
        await tester.tap(find.byKey(Key('memo_bubble_${entry1.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${entry1.id}')));
        await _drainRealIo(tester);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('editor_text_field')))
              .controller!
              .text,
          contains('第一条待删小记'),
        );

        await tester.tap(find.byKey(Key('memo_delete_${entry1.id}')));
        await _drainRealIo(tester);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('editor_text_field')))
              .controller!
              .text,
          isEmpty,
        );

        // Start editing entry2, purge it underneath, then click submit -> honest error banner (zero unhandled exception).
        await tester.tap(find.byKey(Key('memo_bubble_${entry2.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${entry2.id}')));
        await _drainRealIo(tester);
        await tester.runAsync(() async {
          await fixture.vault.raw.softDeleteEntry(entry2.id);
          await fixture.vault.raw.purgeEntryPermanently(entry2.id);
        });

        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.bannerIsError,
        );
        expect(tester.takeException(), isNull);
        expect(fixture.workspace.bannerIsError, isTrue);
        expect(fixture.workspace.bannerMessage, contains('not found'));
      },
    );

    test('exportBlobToFile cleans up temporary file when destination rename fails (P2)', () async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final lifecycle = DesktopLifecycleController(
        buildInfo: BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
        ),
        paths: paths,
        settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
        windowAdapter: _NoopWindowAdapter(),
        trayAdapter: _NoopTrayAdapter(),
      );
      await lifecycle.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );
      final workspace = BlinkWorkspaceController(
        lifecycle: lifecycle,
        filePicker: const NoopBlinkFilePicker(),
        enableMirrorExporter: false,
      );
      await workspace.initialize();
      try {
        final blob = await workspace.vault!.blobs.putBytes(
          Uint8List.fromList('atomic-export-check'.codeUnits),
          mimeType: 'text/plain',
        );
        final blockingDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}cannot_overwrite_dir',
        )..createSync(recursive: true);

        final result = await workspace.exportBlobToFile(
          blob,
          File(blockingDir.path),
        );
        expect(result, isNull);
        expect(workspace.bannerIsError, isTrue);

        final leftoverTmp = tempDir
            .listSync()
            .where((e) => e.path.contains('.blink-tmp-'))
            .toList();
        expect(leftoverTmp, isEmpty);
      } finally {
        await workspace.flushAndCloseForShutdown();
        workspace.dispose();
      }
    });

    testWidgets(
      'memo composer & edit cancel private cleanly (with and without #private) and permanent local trash supports confirmed emptyTrash',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.memos,
        );
        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // 1. New memo composer: typing `#private` activates lock; tapping toggle OFF strips `#private` & unlocks.
        await tester.enterText(
          find.byKey(const Key('editor_text_field')),
          '临时草稿 #private 准备取消',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();

        final composerField = tester.widget<TextField>(
          find.byKey(const Key('editor_text_field')),
        );
        expect(composerField.controller!.text, '临时草稿 准备取消');

        // Submit -> must save as normal (non-private) memo!
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.memoEntries.length == 1,
        );
        expect(fixture.workspace.memoEntries.first.isPrivate, isFalse);
        expect(fixture.workspace.privateMemoCount, 0);

        // 2. Create a private memo with `#private` + task, then edit it -> toggle 私密 OFF -> save!
        final privMemo = (await tester.runAsync(
          () => fixture.workspace.createMemo(
            bodyMd: '待解密小记 #private\n- [ ] 待解密待办',
            isPrivate: true,
          ),
        ))!;
        await tester.pumpAndSettle();
        expect(fixture.workspace.privateMemoCount, 1);
        expect(
          find.byKey(Key('memo_private_badge_${privMemo.id}')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(Key('memo_bubble_${privMemo.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${privMemo.id}')));
        await _drainRealIo(tester);

        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.privateMemoCount == 0,
        );

        final downgradedMemo = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(privMemo.id),
        ))!;
        expect(downgradedMemo.isPrivate, isFalse);
        expect(downgradedMemo.bodyMd, isNot(contains('#private')));
        expect(
          find.byKey(Key('memo_private_badge_${privMemo.id}')),
          findsNothing,
        );
        final normalHits = (await tester.runAsync(
          () => fixture.vault.search.search(
            '待解密小记',
            scope: PrivacyScope.normalOnly,
          ),
        ))!;
        expect(normalHits.map((h) => h.docId), contains(privMemo.id));

        // 3. Direct bubble menu: re-enable private -> cancel private in one click!
        await tester.tap(find.byKey(Key('memo_more_${privMemo.id}')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key('memo_menu_toggle_private_${privMemo.id}')),
        );
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.privateMemoCount == 1,
        );
        expect(
          (await tester.runAsync(
            () => fixture.vault.raw.getEntryById(privMemo.id),
          ))!.isPrivate,
          isTrue,
        );

        await tester.tap(find.byKey(Key('memo_more_${privMemo.id}')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key('memo_menu_toggle_private_${privMemo.id}')),
        );
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.privateMemoCount == 0,
        );
        expect(
          (await tester.runAsync(
            () => fixture.vault.raw.getEntryById(privMemo.id),
          ))!.isPrivate,
          isFalse,
        );

        // 4. Permanent local trash: soft-delete memos & a note -> verify zero "30 天"/"清理已过期",
        // confirm `清空回收站` in Memos empties only trashed memos and leaves trashed note intact,
        // then confirm `清空回收站` in Notes empties trashed notes!
        final noteToTrash = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 回收站永久保留测试笔记'),
        ))!;
        await tester.runAsync(() async {
          await fixture.workspace.softDeleteEntry(privMemo.id);
          await fixture.workspace.softDeleteEntry(noteToTrash.id);
        });
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('filter_trash')));
        await tester.pumpAndSettle();

        expect(find.textContaining('30 天'), findsNothing);
        expect(find.textContaining('30天'), findsNothing);
        expect(find.text('清理已过期'), findsNothing);
        expect(find.text('回收站中的内容会一直保留，直到你手动还原或彻底删除'), findsOneWidget);
        expect(find.byKey(const Key('trash_empty_button')), findsOneWidget);

        // Open confirmation dialog and cancel first -> item stays in trash.
        await tester.tap(find.byKey(const Key('trash_empty_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('trash_empty_cancel')));
        await tester.pumpAndSettle();
        expect(fixture.workspace.trashMemoCount, 1);

        // Open confirmation dialog and confirm -> trashed memo purged, trashed note untouched!
        await tester.tap(find.byKey(const Key('trash_empty_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('trash_empty_confirm')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.trashMemoCount == 0,
        );
        expect(
          await tester.runAsync(
            () => fixture.vault.raw.getEntryById(
              privMemo.id,
              includeDeleted: true,
            ),
          ),
          isNull,
        );
        expect(fixture.workspace.trashNoteCount, 1);

        // Switch to Notes -> Trash -> verify zero "30 天" and confirm `清空回收站` empties trashed notes!
        await tester.tap(find.byKey(const Key('nav_notes')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('notes_filter_trash')));
        await tester.pumpAndSettle();

        expect(find.textContaining('30 天'), findsNothing);
        expect(find.textContaining('30天'), findsNothing);
        expect(find.text('清理已过期'), findsNothing);
        expect(find.byKey(const Key('trash_empty_button')), findsOneWidget);

        await tester.tap(find.byKey(const Key('trash_empty_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('trash_empty_confirm')));
        await _drainRealIo(
          tester,
          until: () => fixture.workspace.trashNoteCount == 0,
        );
        expect(
          await tester.runAsync(
            () => fixture.vault.raw.getEntryById(
              noteToTrash.id,
              includeDeleted: true,
            ),
          ),
          isNull,
        );
      },
    );

    testWidgets(
      'P1 #2 & P2 #3: bubble cancel during active edit, cancelled/restored downgrade drafts, and #private-only memo with/without attachment',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.memos,
        );
        final blob = (await tester.runAsync(
          () => fixture.vault.blobs.putBytes(
            Uint8List.fromList('private-attachment-only'.codeUnits),
            mimeType: 'text/plain',
          ),
        ))!;
        final m1 = (await tester.runAsync(
          () => fixture.workspace.createMemo(
            bodyMd: '编辑中点菜单取消私密 #private',
            isPrivate: true,
          ),
        ))!;
        final m2 = (await tester.runAsync(
          () => fixture.workspace.createMemo(
            bodyMd: '草稿取消私密测试 #private',
            isPrivate: true,
          ),
        ))!;
        final mAttachOnly = (await tester.runAsync(
          () => fixture.workspace.createMemo(
            bodyMd: '#private',
            isPrivate: true,
            imageBlobSha256s: <String>[blob.sha256],
          ),
        ))!;
        final mTagOnly = (await tester.runAsync(
          () =>
              fixture.workspace.createMemo(bodyMd: '#private', isPrivate: true),
        ))!;
        final mTabSwitch = (await tester.runAsync(
          () => fixture.workspace.createMemo(
            bodyMd: '跨标签切换测试 #private',
            isPrivate: true,
          ),
        ))!;

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // P1 #2A: Open M1 in composer, then click bubble `⋯ → 取消私密` while editing.
        // Composer must update immediately without stale draft re-locking on subsequent Save.
        await tester.tap(find.byKey(Key('memo_bubble_${m1.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${m1.id}')));
        await _drainRealIo(tester);

        await tester.tap(find.byKey(Key('memo_more_${m1.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_menu_toggle_private_${m1.id}')));
        await _drainRealIo(tester);

        final composerAfterMenu = tester.widget<TextField>(
          find.byKey(const Key('editor_text_field')),
        );
        expect(composerAfterMenu.controller!.text, '编辑中点菜单取消私密');

        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(tester);
        final m1AfterSave = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(m1.id),
        ))!;
        expect(m1AfterSave.isPrivate, isFalse);
        expect(m1AfterSave.bodyMd, '编辑中点菜单取消私密');

        // P1 #2B (part 1): Cancel edit discards stale edit draft cleanly.
        await tester.tap(find.byKey(Key('memo_bubble_${m2.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${m2.id}')));
        await _drainRealIo(tester);
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('memo_edit_cancel_button')));
        await _drainRealIo(tester);
        expect(
          await tester.runAsync(
            () => fixture.vault.raw.loadDraft('entry:${m2.id}'),
          ),
          isNull,
        );

        // P1 #2B (part 2): Restoring a saved draft (`privacyLocked: false`, `#private` stripped)
        // for an existing private memo preserves explicit downgrade intent on Save!
        await tester.runAsync(
          () => fixture.vault.raw.saveDraft(
            EditorDraft(
              draftKey: 'entry:${m2.id}',
              bodyMd: '草稿取消私密测试',
              entryKind: EntryKind.blink,
              privacyLocked: false,
              updatedAtUtc: DateTime.now().toUtc(),
            ),
          ),
        );
        await tester.tap(find.byKey(Key('memo_bubble_${m2.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${m2.id}')));
        await _drainRealIo(tester);
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(tester);

        final m2AfterRestoredSave = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(m2.id),
        ))!;
        expect(m2AfterRestoredSave.isPrivate, isFalse);
        expect(m2AfterRestoredSave.bodyMd, '草稿取消私密测试');

        // P2 #3a & #3b: `#private`-only memo WITH attachment saves cleanly as normal
        // and never renders empty-editor `#私密` placeholder text in the bubble.
        await tester.tap(find.byKey(Key('memo_bubble_${mAttachOnly.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${mAttachOnly.id}')));
        await _drainRealIo(tester);
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(tester);

        final attachAfter = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(mAttachOnly.id),
        ))!;
        expect(attachAfter.isPrivate, isFalse);
        expect(attachAfter.bodyMd, isEmpty);
        expect(attachAfter.imageBlobSha256s, contains(blob.sha256));
        expect(find.textContaining('开始输入内容'), findsNothing);
        expect(find.textContaining('#私密'), findsNothing);

        // P2 #3a & #3b: `#private`-only memo WITHOUT attachments shows honest error banner
        // instead of silently ignoring or rendering composer hints.
        fixture.workspace.clearBanner();
        await tester.tap(find.byKey(Key('memo_more_${mTagOnly.id}')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(Key('memo_menu_toggle_private_${mTagOnly.id}')),
        );
        await _drainRealIo(tester);
        expect(fixture.workspace.bannerIsError, isTrue);
        expect(fixture.workspace.bannerMessage, contains('正文为空'));
        expect(
          (await tester.runAsync(
            () => fixture.vault.raw.getEntryById(mTagOnly.id),
          ))!.isPrivate,
          isTrue,
        );

        fixture.workspace.clearBanner();
        await tester.tap(find.byKey(Key('memo_bubble_${mTagOnly.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${mTagOnly.id}')));
        await _drainRealIo(tester);
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(tester);
        expect(fixture.workspace.bannerIsError, isTrue);
        expect(fixture.workspace.bannerMessage, contains('正文为空'));
        await tester.tap(find.byKey(const Key('memo_edit_cancel_button')));
        await _drainRealIo(tester);

        // P1 #2-B3: Edit private memo -> toggle 私密 OFF -> switch tab (Memos -> Notes -> Memos)
        // -> click 保存 -> must preserve explicit downgrade intent and downgrade to normal!
        await tester.tap(find.byKey(Key('memo_bubble_${mTabSwitch.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_edit_${mTabSwitch.id}')));
        await _drainRealIo(tester);
        await tester.tap(find.byKey(const Key('composer_private_toggle')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('nav_notes')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav_memos')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await _drainRealIo(tester);

        final mTabSwitchAfter = (await tester.runAsync(
          () => fixture.vault.raw.getEntryById(mTabSwitch.id),
        ))!;
        expect(mTabSwitchAfter.isPrivate, isFalse);
        expect(mTabSwitchAfter.bodyMd, '跨标签切换测试');
      },
    );
  });
}
