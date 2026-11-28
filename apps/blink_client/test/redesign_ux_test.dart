import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/ui/desktop_window_chrome.dart';

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

class _FakeImmersiveWindowAdapter extends _NoopWindowAdapter
    implements DesktopWindowChromeAdapter {
  int startDragCalls = 0;
  int toggleMaximizeCalls = 0;

  @override
  bool get supportsCustomWindowChrome => true;

  @override
  bool get usesLeadingSystemWindowControls => false;

  @override
  Future<void> startDragging() async {
    startDragCalls++;
  }

  @override
  Future<void> toggleMaximize() async {
    toggleMaximizeCalls++;
  }

  @override
  Future<bool> isMaximized() async => false;

  @override
  Stream<bool> get maximizedChanges => const Stream<bool>.empty();

  @override
  Future<void> showSystemMenu(Offset position) async {}

  @override
  void setMaximizeButtonBounds(Rect? bounds) {}
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

const List<String> _forbiddenUiJargon = <String>[
  '采集流',
  'BFM',
  '内生柔性待办',
  '单文件夹便携库',
  '开放镜像',
  'VACUUM INTO',
  'FTS5',
];

void _expectNoRenderedJargon(WidgetTester tester, {required String screen}) {
  final textWidgets = tester.widgetList<Text>(find.byType(Text));
  for (final widget in textWidgets) {
    final text = widget.data ?? widget.textSpan?.toPlainText() ?? '';
    for (final term in _forbiddenUiJargon) {
      expect(
        text.contains(term),
        isFalse,
        reason: 'Forbidden jargon "$term" found in Text "$text" on $screen',
      );
    }
  }
  final richWidgets = tester.widgetList<RichText>(find.byType(RichText));
  for (final widget in richWidgets) {
    final text = widget.text.toPlainText();
    for (final term in _forbiddenUiJargon) {
      expect(
        text.contains(term),
        isFalse,
        reason: 'Forbidden jargon "$term" found in RichText "$text" on $screen',
      );
    }
  }
}

void main() {
  group('Note-First Redesign UX & Feishu 3-Pane regression tests (#57)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_redesign_ux_test_');
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
    createFixture(
      WidgetTester tester, {
      BlinkNavDestination initialDestination = BlinkNavDestination.memos,
      DesktopWindowAdapter? windowAdapter,
    }) async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final buildInfo = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
        version: '0.1.0-dev.202611280100',
        gitSha: 'abcdef123456',
      );
      final lifecycle = DesktopLifecycleController(
        buildInfo: buildInfo,
        paths: paths,
        settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
        windowAdapter: windowAdapter ?? _NoopWindowAdapter(),
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
        filePicker: const NoopBlinkFilePicker(),
        initialVault: vault,
        initialDestination: initialDestination,
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
      'Feishu 3-pane layout renders persistent contextual Resource Sidebar across ALL 5 modules and collapses/expands cleanly at 1280x800 and 960x640',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(tester);
        await tester.runAsync(() async {
          await fixture.workspace.createMemo(bodyMd: '晨间想法 #灵感\n- [ ] 整理设计稿');
          await fixture.workspace.createNote(bodyMd: '# 项目周报\n本周完成三栏布局重构。');
        });

        for (final size in const <Size>[Size(1280, 800), Size(960, 640)]) {
          tester.view.physicalSize = size;
          fixture.workspace.setSidebarCollapsed(false);
          fixture.workspace.setDestination(BlinkNavDestination.memos);

          await tester.pumpWidget(
            BlinkApp(
              controller: fixture.lifecycle,
              workspaceController: fixture.workspace,
            ),
          );
          await tester.pumpAndSettle();

          // Unconfigured sync must NOT render the global top sync banner.
          expect(find.byKey(const Key('sync_status_capsule')), findsNothing);
          expect(find.byKey(const Key('rail_sync_status_dot')), findsOneWidget);

          final moduleChecks =
              <({Key navKey, Key sidebarItemKey, String label})>[
                (
                  navKey: const Key('nav_memos'),
                  sidebarItemKey: const Key('filter_today'),
                  label: 'memos',
                ),
                (
                  navKey: const Key('nav_notes'),
                  sidebarItemKey: const Key('new_note_button'),
                  label: 'notes',
                ),
                (
                  navKey: const Key('nav_tasks'),
                  sidebarItemKey: const Key('tasks_filter_open'),
                  label: 'tasks',
                ),
                (
                  navKey: const Key('nav_files'),
                  sidebarItemKey: const Key('files_filter_image'),
                  label: 'files',
                ),
                (
                  navKey: const Key('nav_settings'),
                  sidebarItemKey: const Key('settings_cat_general'),
                  label: 'settings',
                ),
              ];

          for (final check in moduleChecks) {
            await tester.tap(find.byKey(check.navKey));
            await tester.pumpAndSettle();

            expect(
              tester.takeException(),
              isNull,
              reason: 'Overflow or exception on ${check.label} at $size',
            );
            expect(find.byKey(const Key('desktop_nav_rail')), findsOneWidget);
            expect(
              find.byKey(const Key('resource_sidebar_pane')),
              findsOneWidget,
              reason: 'Missing Pane 2 sidebar on ${check.label} at $size',
            );
            expect(
              find.byKey(const Key('pane_divider_sidebar')),
              findsOneWidget,
            );
            expect(find.byKey(check.sidebarItemKey), findsOneWidget);
          }

          // Collapse sidebar via button on Settings, verify expand button restores it.
          await tester.tap(
            find.byKey(const Key('settings_sidebar_collapse_button')),
          );
          await tester.pumpAndSettle();
          expect(fixture.workspace.sidebarCollapsed, isTrue);
          expect(find.byKey(const Key('resource_sidebar_pane')), findsNothing);
          expect(
            find.byKey(const Key('settings_sidebar_expand_button')),
            findsOneWidget,
          );

          await tester.tap(
            find.byKey(const Key('settings_sidebar_expand_button')),
          );
          await tester.pumpAndSettle();
          expect(fixture.workspace.sidebarCollapsed, isFalse);
          expect(
            find.byKey(const Key('resource_sidebar_pane')),
            findsOneWidget,
          );

          // Collapse & expand via Ctrl+\ keyboard shortcut.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(fixture.workspace.sidebarCollapsed, isTrue);
          expect(find.byKey(const Key('resource_sidebar_pane')), findsNothing);

          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.backslash);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(fixture.workspace.sidebarCollapsed, isFalse);
          expect(
            find.byKey(const Key('resource_sidebar_pane')),
            findsOneWidget,
          );
        }
      },
    );

    testWidgets(
      'Categorized Settings renders ONLY active category on desktop and supports 2-level drill-down including 附件管理 on mobile 390x844',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.settings,
        );

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // 1. General only.
        expect(find.byKey(const Key('settings_section')), findsOneWidget);
        expect(find.byKey(const Key('vault_settings_section')), findsNothing);
        expect(find.byKey(const Key('sync_settings_section')), findsNothing);
        expect(find.byKey(const Key('about_section')), findsNothing);

        // Persist default note editor mode in General Settings.
        expect(
          find.byKey(const Key('editor_default_mode_toggle')),
          findsOneWidget,
        );
        await tester.tap(find.text('源代码'));
        await tester.pumpAndSettle();
        expect(fixture.workspace.noteEditorMode, NoteEditorMode.source);
        expect(
          fixture.lifecycle.settings.defaultNoteEditorMode,
          NoteEditorMode.source,
        );

        // 2. Storage & Backup only.
        await tester.tap(find.byKey(const Key('settings_cat_storage')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('vault_settings_section')), findsOneWidget);
        expect(find.byKey(const Key('settings_section')), findsNothing);
        expect(find.byKey(const Key('sync_settings_section')), findsNothing);
        expect(find.byKey(const Key('about_section')), findsNothing);

        // 3. Multi-device Sync only.
        await tester.tap(find.byKey(const Key('settings_cat_sync')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('sync_settings_section')), findsOneWidget);
        expect(find.byKey(const Key('settings_section')), findsNothing);
        expect(find.byKey(const Key('vault_settings_section')), findsNothing);
        expect(find.byKey(const Key('about_section')), findsNothing);

        // 4. About BLINK only.
        await tester.tap(find.byKey(const Key('settings_cat_about')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('about_section')), findsOneWidget);
        expect(find.byKey(const Key('settings_section')), findsNothing);
        expect(find.byKey(const Key('vault_settings_section')), findsNothing);
        expect(find.byKey(const Key('sync_settings_section')), findsNothing);

        // Switch viewport to mobile 390x844 -> 2-level drill-down Settings.
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('mobile_settings_general')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('mobile_settings_storage')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('mobile_settings_sync')), findsOneWidget);
        expect(find.byKey(const Key('mobile_settings_files')), findsOneWidget);
        expect(find.byKey(const Key('mobile_settings_about')), findsOneWidget);

        // Drill into 附件管理 (Files) from Mobile Settings and return cleanly.
        await tester.tap(find.byKey(const Key('mobile_settings_files')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('files_back_button')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('files_back_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mobile_settings_files')), findsOneWidget);
      },
    );

    testWidgets(
      'Chat-log Quick Memo flow creates bubble with date separator and non-destructively promotes memo to Note with backlink (INV-01)',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
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

        const memoBody = '闪念胶囊：把零散灵感沉淀为长期结构化笔记 #思考';
        await tester.enterText(
          find.byKey(const Key('editor_text_field')),
          memoBody,
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('editor_submit_button')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.memoEntries, hasLength(1));
        final memo = fixture.workspace.memoEntries.first;
        expect(find.byKey(const Key('memos_timeline_list')), findsOneWidget);
        expect(find.byKey(Key('memo_bubble_${memo.id}')), findsOneWidget);
        expect(find.text('今天'), findsWidgets);

        // Select memo bubble to reveal desktop actions, then non-destructively promote memo to a long-form note.
        await tester.tap(find.byKey(Key('memo_bubble_${memo.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('memo_promote_${memo.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.destination, BlinkNavDestination.notes);
        expect(fixture.workspace.noteEntries, hasLength(1));
        final promotedNote = fixture.workspace.selectedNote;
        expect(promotedNote, isNotNull);
        expect(promotedNote!.entryKind, EntryKind.diary);
        expect(promotedNote.bodyMd, contains(memoBody));
        expect(
          promotedNote.bodyMd,
          contains('> 来源小记：[[entry:${memo.id}|查看原小记]]'),
        );
        expect(find.byKey(const Key('blink_markdown_editor')), findsOneWidget);

        // INV-01: original memo MUST remain completely intact and untouched!
        final originalAfterPromote = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(memo.id),
        );
        expect(originalAfterPromote, isNotNull);
        expect(originalAfterPromote!.isDeleted, isFalse);
        expect(originalAfterPromote.entryKind, EntryKind.blink);
        expect(originalAfterPromote.bodyMd, memoBody);
      },
    );

    testWidgets(
      'Simplified Mobile UX (390x844): 4-tab bottom nav, hidden sync banner, single-row memo composer, and full-screen pushed note editor',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(tester);
        await tester.runAsync(
          () =>
              fixture.workspace.createNote(bodyMd: '# 移动端长文笔记\n支持所见即所得全屏专注编辑。'),
        );

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Quiet sync hides top banner when unconfigured.
        expect(find.byKey(const Key('sync_status_capsule')), findsNothing);
        // 4-tab mobile bottom nav (`小记`, `笔记`, `待办`, `设置`).
        expect(find.byKey(const Key('mobile_bottom_nav')), findsOneWidget);
        expect(find.byKey(const Key('nav_memos')), findsOneWidget);
        expect(find.byKey(const Key('nav_notes')), findsOneWidget);
        expect(find.byKey(const Key('nav_tasks')), findsOneWidget);
        expect(find.byKey(const Key('nav_settings')), findsOneWidget);
        expect(find.byKey(const Key('nav_files')), findsNothing);

        // Single-row minimal memo composer (no Edit/Preview tabs, no BFM badge).
        expect(find.byKey(const Key('mobile_bottom_composer')), findsOneWidget);
        expect(find.byKey(const Key('mobile_composer_more')), findsOneWidget);
        expect(find.byKey(const Key('mobile_tab_edit')), findsNothing);
        expect(find.byKey(const Key('mobile_tab_preview')), findsNothing);
        expect(find.textContaining('BFM'), findsNothing);

        // Switch to Notes -> clean list -> tap note pushes full-screen editor.
        await tester.tap(find.byKey(const Key('nav_notes')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mobile_notes_header')), findsOneWidget);
        expect(find.byKey(const Key('note_tab_bar')), findsNothing);
        expect(find.text('移动端长文笔记'), findsOneWidget);

        await tester.tap(find.text('移动端长文笔记'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('mobile_note_editor_screen')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('note_tab_bar')), findsNothing);
        expect(find.byKey(const Key('blink_markdown_editor')), findsOneWidget);
        expect(find.byKey(const Key('editor_mode_toggle')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Zero-jargon regression: all 5 modules and all 4 Settings categories render zero internal engineering terms',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(tester);
        await tester.runAsync(() async {
          await fixture.workspace.createMemo(bodyMd: '今天散步想到一个好点子\n- [ ] 写下来');
          await fixture.workspace.createNote(bodyMd: '# 阅读笔记\n保持简洁直觉的交互体验。');
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        _expectNoRenderedJargon(tester, screen: 'memos');

        await tester.tap(find.byKey(const Key('nav_notes')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'notes');

        await tester.tap(find.byKey(const Key('nav_tasks')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'tasks');

        await tester.tap(find.byKey(const Key('nav_files')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'files');

        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'settings/general');

        await tester.tap(find.byKey(const Key('settings_cat_storage')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'settings/storage');

        await tester.tap(find.byKey(const Key('settings_cat_sync')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'settings/sync');

        await tester.tap(find.byKey(const Key('settings_cat_about')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'settings/about');

        // Also check Search Modal for zero jargon.
        await tester.tap(find.byKey(const Key('open_search_button')));
        await tester.pumpAndSettle();
        _expectNoRenderedJargon(tester, screen: 'search_modal');
      },
    );

    testWidgets(
      'P0 #1 (INV-01): disposed BlinkMarkdownEditor never overwrites newer raw entry on shutdown',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.notes,
        );
        final note = (await tester.runAsync(
          () => fixture.workspace.createNote(bodyMd: '# 初始笔记\n- [ ] 完成核对'),
        ))!;

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // Switch to Source mode, enter dirty text (<600ms debounce), then immediately navigate away so editor disposes.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('note_source_input')),
          '# 过期脏文本\n- [ ] 完成核对',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('nav_tasks')));
        await tester.pumpAndSettle();

        // A newer edit lands in the Raw Layer (e.g. toggling a task or sync update).
        await tester.runAsync(
          () => fixture.vault.raw.updateEntry(
            id: note.id,
            bodyMd: '# 待办更新后的最新正文\n- [x] 完成核对',
          ),
        );

        // Shutdown flush MUST NOT let the disposed editor overwrite the newer DB state.
        await tester.runAsync(
          () => fixture.workspace.flushAndCloseForShutdown(),
        );

        final reopened = (await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: fixture.lifecycle.paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        ))!;
        addTearDown(() async {
          await tester.runAsync(() async {
            if (reopened.isOpen) {
              await reopened.checkpointAndClose();
            }
          });
        });

        final persisted = await tester.runAsync(
          () => reopened.raw.getEntryById(note.id),
        );
        expect(persisted, isNotNull);
        expect(persisted!.bodyMd, '# 待办更新后的最新正文\n- [x] 完成核对');
      },
    );

    testWidgets(
      'P1 #2 (AC-02): unsent memo draft survives switching tabs <500ms before shutdown',
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

        const draftText = '切页后立刻退出也不能丢失的小记草稿 #inbox';
        await tester.enterText(
          find.byKey(const Key('editor_text_field')),
          draftText,
        );
        await tester.pump();

        // Immediately switch to Settings (<500ms debounce) and shut down.
        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => fixture.workspace.flushAndCloseForShutdown(),
        );

        final reopened = (await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: fixture.lifecycle.paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        ))!;
        addTearDown(() async {
          await tester.runAsync(() async {
            if (reopened.isOpen) {
              await reopened.checkpointAndClose();
            }
          });
        });

        final recovered = await tester.runAsync(
          () => reopened.raw.loadDraft('inbox'),
        );
        expect(recovered, isNotNull);
        expect(recovered!.bodyMd, draftText);
      },
    );

    testWidgets(
      'P1 #3 & P2 #4 & P2 #6: mobile search icon flush-right, Ctrl+/ scoped to Notes, and 附入新笔记 creates diary note cleanly',
      (tester) async {
        // 1. P1 #3: Mobile memos top header search icon is flush-right at 390x844.
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.memos,
        );
        final blob = (await tester.runAsync(
          () => fixture.vault.blobs.putBytes(
            Uint8List.fromList('attachment-regression'.codeUnits),
            mimeType: 'text/plain',
          ),
        ))!;
        await tester.runAsync(() => fixture.workspace.refreshAll());

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        final searchRect = tester.getRect(
          find.byKey(const Key('mobile_search_button')),
        );
        expect(searchRect.right, greaterThanOrEqualTo(370.0));
        expect(searchRect.right, lessThanOrEqualTo(390.0));

        // 2. P2 #6 (Mobile): 设置 -> 附件管理 -> 附入新笔记 pops sub-page and opens new diary note.
        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('mobile_settings_files')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('blob_attach_new_${blob.sha256}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.destination, BlinkNavDestination.notes);
        expect(find.byKey(const Key('files_back_button')), findsNothing);
        expect(fixture.workspace.selectedNote?.entryKind, EntryKind.diary);
        expect(
          fixture.workspace.selectedNote?.imageBlobSha256s,
          contains(blob.sha256),
        );

        // Pop pushed mobile note editor if open before switching to desktop checks.
        if (find
            .byKey(const Key('mobile_note_editor_screen'))
            .evaluate()
            .isNotEmpty) {
          Navigator.of(
            tester.element(find.byKey(const Key('mobile_note_editor_screen'))),
          ).pop();
          await tester.pumpAndSettle();
        }

        // 3. P2 #4: Ctrl+/ MUST NOT toggle or persist defaultNoteEditorMode outside Notes.
        tester.view.physicalSize = const Size(1280, 800);
        await tester.pumpAndSettle();

        for (final navKey in const <Key>[
          Key('nav_memos'),
          Key('nav_tasks'),
          Key('nav_settings'),
        ]) {
          await tester.tap(find.byKey(navKey));
          await tester.pumpAndSettle();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.slash);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          expect(fixture.workspace.noteEditorMode, NoteEditorMode.wysiwyg);
          expect(
            fixture.lifecycle.settings.defaultNoteEditorMode,
            NoteEditorMode.wysiwyg,
          );
        }

        // On Notes, Ctrl+/ toggles and persists NoteEditorMode.source cleanly.
        await tester.tap(find.byKey(const Key('nav_notes')));
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.slash);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(fixture.workspace.noteEditorMode, NoteEditorMode.source);
        expect(
          fixture.lifecycle.settings.defaultNoteEditorMode,
          NoteEditorMode.source,
        );

        // 4. P2 #6 (Desktop): Files -> 附入新笔记 creates diary note & switches to Notes.
        await tester.tap(find.byKey(const Key('nav_files')));
        await tester.pumpAndSettle();
        final beforeCount = fixture.workspace.totalNoteCount;
        await tester.tap(find.byKey(Key('blob_attach_new_${blob.sha256}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.destination, BlinkNavDestination.notes);
        expect(fixture.workspace.totalNoteCount, beforeCount + 1);
        expect(fixture.workspace.selectedNote?.entryKind, EntryKind.diary);
        expect(
          fixture.workspace.selectedNote?.imageBlobSha256s,
          contains(blob.sha256),
        );
      },
    );

    testWidgets(
      'immersive desktop window chrome (138px trailing inset) renders memos & notes headers with zero overflow at 1280, 960, and 760',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final chromeAdapter = _FakeImmersiveWindowAdapter();
        final fixture = await createFixture(
          tester,
          windowAdapter: chromeAdapter,
        );
        late RawEntry note;
        await tester.runAsync(() async {
          final memo = await fixture.workspace.createMemo(bodyMd: '沉浸式标题栏测试小记');
          if (memo != null) {
            await fixture.workspace.softDeleteEntry(memo.id);
          }
          note = (await fixture.workspace.createNote(
            bodyMd: '# 沉浸式标题栏测试笔记\n正文内容',
          ))!;
        });
        fixture.workspace.clearBanner();

        for (final size in const <Size>[
          Size(1280, 800),
          Size(960, 640),
          Size(760, 560),
        ]) {
          tester.view.physicalSize = size;
          fixture.workspace.setDestination(BlinkNavDestination.memos);
          fixture.workspace.selectMemoFilter(MemoFilterKind.all);
          await tester.pumpWidget(
            BlinkApp(
              controller: fixture.lifecycle,
              workspaceController: fixture.workspace,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'Memos all at $size');
          expect(
            find.byKey(const Key('window_caption_buttons')),
            findsOneWidget,
          );

          // Memos Trash view with `清空回收站` button + 138px trailing inset.
          fixture.workspace.selectMemoFilter(MemoFilterKind.trash);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Memos trash at $size',
          );
          expect(find.textContaining('30 天'), findsNothing);
          expect(find.text('清理已过期'), findsNothing);

          // Notes Multi-Tab Bar (top 44px) + Bottom Typora Toolbar (40px) with 138px trailing inset:
          // verify zero overflow, tab bar aligned at y=0..44 clear of caption buttons,
          // bottom editor toolbar pinned cleanly at window bottom, and usable drag space in top tab bar.
          fixture.workspace.setDestination(BlinkNavDestination.notes);
          fixture.workspace.selectNoteFilter(NoteFilterKind.all);
          fixture.workspace.openNoteTab(note.id);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Notes editor at $size',
          );

          final tabBarRect = tester.getRect(
            find.byKey(const Key('note_tab_bar')),
          );
          final captionRect = tester.getRect(
            find.byKey(const Key('window_caption_buttons')),
          );
          final newTabBtnRect = tester.getRect(
            find.byKey(const Key('note_tab_new_button')),
          );
          final dragSpaceRect = tester.getRect(
            find.byKey(const Key('note_tab_bar_drag_space')),
          );
          expect(tabBarRect.top, 0.0, reason: 'Tab bar must start at y=0');
          expect(
            tabBarRect.height,
            kBlinkWindowChromeHeaderHeight,
            reason: 'Tab bar must match 44px chrome height at $size',
          );
          expect(
            newTabBtnRect.right,
            lessThanOrEqualTo(captionRect.left),
            reason:
                'New tab button must stay clear of caption buttons at $size',
          );
          expect(
            dragSpaceRect.width,
            greaterThanOrEqualTo(32.0),
            reason: 'Usable blank drag space required in note tab bar at $size',
          );

          // Bottom editor toolbar sits at the bottom of the window (NOT top),
          // with zero clipping between format controls and right-side actions.
          final bottomToolbarRect = tester.getRect(
            find.byKey(const Key('note_editor_toolbar')),
          );
          expect(
            bottomToolbarRect.top,
            greaterThan(tabBarRect.bottom),
            reason: 'Editor toolbar must sit below top tab bar at $size',
          );
          expect(
            bottomToolbarRect.bottom,
            closeTo(size.height, 0.5),
            reason: 'Editor toolbar must be pinned at window bottom at $size',
          );
          expect(
            bottomToolbarRect.height,
            40.0,
            reason: 'Bottom editor toolbar must be 40px tall at $size',
          );

          final privRect = tester.getRect(
            find.byKey(const Key('note_editor_private_toggle')),
          );
          final moreRect = tester.getRect(
            find.byKey(const Key('note_editor_more_button')),
          );
          expect(
            moreRect.right,
            lessThanOrEqualTo(size.width),
            reason:
                'Bottom toolbar right edge must stay within viewport at $size',
          );

          for (final fmtKey in const <Key>[
            Key('note_fmt_heading'),
            Key('note_fmt_bold'),
            Key('note_fmt_italic'),
            Key('note_fmt_highlight'),
            Key('note_fmt_task'),
            Key('note_fmt_bullet'),
            Key('note_fmt_quote'),
            Key('note_fmt_code'),
          ]) {
            expect(
              find.byKey(fmtKey),
              findsOneWidget,
              reason: '$fmtKey should stay directly visible at $size',
            );
            final r = tester.getRect(find.byKey(fmtKey));
            expect(
              r.right,
              lessThanOrEqualTo(privRect.left),
              reason: '$fmtKey clipped into right controls at $size',
            );
          }

          // Verify P1 #1 integration on top tab bar: rapid double-click on a tab
          // or bottom format button must NOT trigger window maximize, while blank
          // drag space in the top tab bar DOES trigger window drag!
          final maxBefore = chromeAdapter.toggleMaximizeCalls;
          await tester.tap(find.byKey(Key('note_tab_${note.id}')));
          await tester.pump(const Duration(milliseconds: 40));
          await tester.tap(find.byKey(Key('note_tab_${note.id}')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('note_fmt_heading')));
          await tester.pump(const Duration(milliseconds: 40));
          await tester.tap(find.byKey(const Key('note_fmt_heading')));
          await tester.pumpAndSettle();
          expect(
            chromeAdapter.toggleMaximizeCalls,
            maxBefore,
            reason:
                'Rapid double-click on tab or bottom toolbar button must not maximize at $size',
          );

          final dragBefore = chromeAdapter.startDragCalls;
          await tester.dragFrom(dragSpaceRect.center, const Offset(24, 0));
          await tester.pumpAndSettle();
          expect(
            chromeAdapter.startDragCalls,
            greaterThan(dragBefore),
            reason: 'Blank tab bar drag space must start window drag at $size',
          );

          // Notes Empty/Trash view with 138px trailing inset.
          fixture.workspace.selectNoteFilter(NoteFilterKind.trash);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Notes trash at $size',
          );
          expect(find.byKey(const Key('note_tab_bar')), findsOneWidget);
          expect(find.textContaining('30 天'), findsNothing);
          expect(find.text('清理已过期'), findsNothing);
        }
      },
    );

    testWidgets(
      'Multi-Tab Notes workspace: deduplicated tabs, +/x/Ctrl+W/middle-click/context-menu, Ctrl+Tab cycling, empty canvas, draft flush on switch & close, and trash preservation',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.notes,
        );
        late RawEntry noteA;
        late RawEntry noteB;
        late RawEntry noteC;
        late RawEntry trashedNote;
        await tester.runAsync(() async {
          noteA = (await fixture.workspace.createNote(
            bodyMd: '# 笔记甲\n\n初始正文甲',
          ))!;
          noteB = (await fixture.workspace.createNote(
            bodyMd: '# 笔记乙\n\n初始正文乙',
          ))!;
          noteC = (await fixture.workspace.createNote(
            bodyMd: '# 笔记丙\n\n初始正文丙',
          ))!;
          trashedNote = (await fixture.workspace.createNote(
            bodyMd: '# 回收站笔记\n\n待还原内容',
          ))!;
          await fixture.workspace.softDeleteEntry(trashedNote.id);
        });
        fixture.workspace.clearBanner();

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        // 1. Three distinct active note tabs open in order; re-clicking Note A focuses without duplicating.
        expect(fixture.workspace.openNoteTabIds, <String>[
          noteA.id,
          noteB.id,
          noteC.id,
        ]);
        expect(find.byKey(Key('note_tab_${noteA.id}')), findsOneWidget);
        expect(find.byKey(Key('note_tab_${noteB.id}')), findsOneWidget);
        expect(find.byKey(Key('note_tab_${noteC.id}')), findsOneWidget);

        await tester.tap(find.byKey(Key('note_list_item_${noteA.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.selectedNoteId, noteA.id);
        expect(fixture.workspace.openNoteTabIds, <String>[
          noteA.id,
          noteB.id,
          noteC.id,
        ]);

        // 2. Unsaved edit in Tab A (<600ms debounce) flushes cleanly before switching to Tab B.
        await tester.tap(find.byKey(const Key('editor_mode_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('note_source_input')),
          '# 笔记甲已更新\n\n切换标签前自动落盘',
        );
        await tester.pump();
        await tester.tap(find.byKey(Key('note_tab_${noteB.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.selectedNoteId, noteB.id);
        final savedA = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(noteA.id),
        );
        expect(savedA?.bodyMd, '# 笔记甲已更新\n\n切换标签前自动落盘');

        // 3. Ctrl+Tab cycles forward (B -> C -> A) and Ctrl+Shift+Tab cycles backward (A -> C).
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.selectedNoteId, noteC.id);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.selectedNoteId, noteA.id);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.selectedNoteId, noteC.id);

        // 4. Clicking `+` opens a new tab; middle-clicking closes it cleanly.
        await tester.tap(find.byKey(const Key('note_tab_new_button')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, hasLength(4));
        final createdTabId = fixture.workspace.openNoteTabIds.last;
        expect(fixture.workspace.selectedNoteId, createdTabId);

        final createdTabCenter = tester.getCenter(
          find.byKey(Key('note_tab_$createdTabId')),
        );
        final middleClick = await tester.startGesture(
          createdTabCenter,
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
        );
        await middleClick.up();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[
          noteA.id,
          noteB.id,
          noteC.id,
        ]);
        expect(fixture.workspace.selectedNoteId, noteC.id);

        // 5. Right-click context menu: `关闭右侧标签页` on Tab A closes B & C, activates A.
        await tester.tap(
          find.byKey(Key('note_tab_${noteA.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note_tab_menu_close_right')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[noteA.id]);
        expect(fixture.workspace.selectedNoteId, noteA.id);

        // Re-open B & C, then test right-click `关闭其他标签页` on B.
        fixture.workspace.openNoteTab(noteB.id);
        fixture.workspace.openNoteTab(noteC.id);
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[
          noteA.id,
          noteB.id,
          noteC.id,
        ]);
        await tester.tap(
          find.byKey(Key('note_tab_${noteB.id}')),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('note_tab_menu_close_others')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[noteB.id]);
        expect(fixture.workspace.selectedNoteId, noteB.id);

        // 6. Unsaved edit in Tab B flushes before closing via Ctrl+W; closing last tab shows empty canvas (NOT auto-reopened).
        await tester.enterText(
          find.byKey(const Key('note_source_input')),
          '# 笔记乙关闭前保存\n\nCtrl+W 自动落盘验证',
        );
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();

        expect(fixture.workspace.openNoteTabIds, isEmpty);
        expect(fixture.workspace.selectedNoteId, isNull);
        expect(find.text('暂无打开的标签页'), findsOneWidget);
        expect(find.byKey(const Key('empty_new_note_button')), findsOneWidget);
        final savedB = await tester.runAsync(
          () => fixture.vault.raw.getEntryById(noteB.id),
        );
        expect(savedB?.bodyMd, '# 笔记乙关闭前保存\n\nCtrl+W 自动落盘验证');

        // Refreshing vault does NOT force-reopen a tab after user explicitly closed all tabs.
        await tester.runAsync(() => fixture.workspace.refreshAll());
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, isEmpty);
        expect(fixture.workspace.selectedNoteId, isNull);

        // 7. Re-open A & B, switch to Trash, preview trashed note without losing active tabs, then close via `×`.
        fixture.workspace.openNoteTab(noteA.id);
        fixture.workspace.openNoteTab(noteB.id);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('notes_filter_trash')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('note_list_item_${trashedNote.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('note_trash_banner')), findsOneWidget);
        expect(fixture.workspace.openNoteTabIds, <String>[
          noteA.id,
          noteB.id,
        ], reason: 'Previewing a trashed note must preserve open active tabs');

        // Click active tab close `×` on Tab B -> activates Tab A cleanly.
        await tester.tap(find.byKey(const Key('notes_filter_all')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.selectedNoteId, noteB.id);
        await tester.tap(find.byKey(Key('note_tab_close_${noteB.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[noteA.id]);
        expect(fixture.workspace.selectedNoteId, noteA.id);
      },
    );

    testWidgets(
      'Vault load automatically seeds initial note tab when active notes already exist',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        final seededVault = (await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        ))!;
        final existingNote = (await tester.runAsync(
          () => seededVault.raw.createEntry(
            bodyMd: '# 已存在的笔记\n\n重新打开应用应自动显示为首个标签页',
            entryKind: EntryKind.diary,
          ),
        ))!;
        await tester.runAsync(() => seededVault.checkpointAndClose());

        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.notes,
        );
        expect(fixture.workspace.openNoteTabIds, <String>[existingNote.id]);
        expect(fixture.workspace.selectedNoteId, existingNote.id);

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(Key('note_tab_${existingNote.id}')), findsOneWidget);
        expect(find.byKey(const Key('blink_markdown_editor')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Overflowing tab strip (8 tabs) auto-scrolls active tab into view at 1280x800 & 760x560, supports Ctrl+Tab wrap-back & vertical mouse-wheel scrolling, and ignores hidden inactive close hits',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final chromeAdapter = _FakeImmersiveWindowAdapter();
        final fixture = await createFixture(
          tester,
          initialDestination: BlinkNavDestination.notes,
          windowAdapter: chromeAdapter,
        );

        final createdNotes = <RawEntry>[];
        await tester.runAsync(() async {
          for (var i = 1; i <= 8; i++) {
            final note = (await fixture.workspace.createNote(
              bodyMd: '# 多标签滚动测试笔记 $i\n\n第 $i 篇正文内容',
            ))!;
            createdNotes.add(note);
          }
        });
        fixture.workspace.clearBanner();

        // Part 1: Verify auto-scroll active tab into view & Ctrl+Tab wrap-back at 1280x800 and 760x560.
        for (final size in const <Size>[Size(1280, 800), Size(760, 560)]) {
          tester.view.physicalSize = size;
          fixture.workspace.openNoteTab(createdNotes.last.id);
          await tester.pumpWidget(
            BlinkApp(
              controller: fixture.lifecycle,
              workspaceController: fixture.workspace,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '8 tabs at $size');

          final tabBarRect = tester.getRect(
            find.byKey(const Key('note_tab_bar')),
          );
          final newBtnRect = tester.getRect(
            find.byKey(const Key('note_tab_new_button')),
          );
          final tab8Rect = tester.getRect(
            find.byKey(Key('note_tab_${createdNotes.last.id}')),
          );
          expect(
            tab8Rect.left,
            greaterThanOrEqualTo(tabBarRect.left - 0.5),
            reason: 'Active Tab 8 left edge must be visible at $size',
          );
          expect(
            tab8Rect.right,
            lessThanOrEqualTo(newBtnRect.left + 0.5),
            reason: 'Active Tab 8 right edge must not clip past + at $size',
          );

          // Ctrl+Tab wraps from Tab 8 -> Tab 1 and auto-scrolls Tab 1 back into view.
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pumpAndSettle();

          expect(fixture.workspace.selectedNoteId, createdNotes.first.id);
          final tab1Rect = tester.getRect(
            find.byKey(Key('note_tab_${createdNotes.first.id}')),
          );
          expect(
            tab1Rect.left,
            greaterThanOrEqualTo(tabBarRect.left - 0.5),
            reason: 'Wrapped Tab 1 left edge must be visible at $size',
          );
          expect(
            tab1Rect.right,
            lessThanOrEqualTo(newBtnRect.left + 0.5),
            reason: 'Wrapped Tab 1 right edge must be visible at $size',
          );

          // Vertical mouse-wheel scroll over the tab strip scrolls horizontally.
          final stripScroll = tester.widget<SingleChildScrollView>(
            find.descendant(
              of: find.byKey(const Key('note_tab_strip_scroll_listener')),
              matching: find.byType(SingleChildScrollView),
            ),
          );
          final scrollCtrl = stripScroll.controller!;
          expect(scrollCtrl.offset, 0.0);
          expect(scrollCtrl.position.maxScrollExtent, greaterThan(0.0));

          final stripCenter = tester.getCenter(
            find.byKey(const Key('note_tab_strip_scroll_listener')),
          );
          final wheelPointer = TestPointer(99, PointerDeviceKind.mouse);
          tester.binding.handlePointerEvent(
            wheelPointer.addPointer(location: stripCenter),
          );
          tester.binding.handlePointerEvent(
            wheelPointer.scroll(const Offset(0, 140)),
          );
          await tester.pumpAndSettle();
          expect(
            scrollCtrl.offset,
            greaterThan(0.0),
            reason: 'Vertical mouse wheel must scroll tab strip right at $size',
          );

          tester.binding.handlePointerEvent(
            wheelPointer.scroll(const Offset(0, -140)),
          );
          await tester.pumpAndSettle();
          expect(
            scrollCtrl.offset,
            0.0,
            reason:
                'Upward vertical mouse wheel must scroll back left at $size',
          );
          tester.binding.handlePointerEvent(wheelPointer.removePointer());
        }

        // Part 2 (P2): Tapping the hidden close region on an unhovered inactive tab
        // selects that tab instead of closing it; hovering reveals `x` so clicking closes it.
        tester.view.physicalSize = const Size(1280, 800);
        fixture.workspace.closeOtherNoteTabs(createdNotes[0].id);
        fixture.workspace.openNoteTab(createdNotes[1].id, activate: false);
        await tester.pumpAndSettle();

        final tabA = createdNotes[0];
        final tabB = createdNotes[1];
        expect(fixture.workspace.openNoteTabIds, <String>[tabA.id, tabB.id]);
        expect(fixture.workspace.selectedNoteId, tabA.id);

        // Tap directly on inactive Tab B's hidden `x` coordinates (no hover first).
        final hiddenCloseCenter = tester.getCenter(
          find.byKey(Key('note_tab_close_${tabB.id}')),
        );
        await tester.tapAt(hiddenCloseCenter);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(
          fixture.workspace.openNoteTabIds,
          <String>[tabA.id, tabB.id],
          reason:
              'Tapping hidden x on unhovered inactive tab must NOT close it',
        );
        expect(
          fixture.workspace.selectedNoteId,
          tabB.id,
          reason:
              'Tapping unhovered inactive tab right edge should activate it',
        );

        // Switch back to Tab A, hover Tab B with mouse to reveal `x`, then click `x` -> closes Tab B!
        fixture.workspace.openNoteTab(tabA.id, activate: true);
        await tester.pumpAndSettle();
        final hoverGesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(hoverGesture.removePointer);
        await hoverGesture.addPointer(location: Offset.zero);
        await tester.pump();
        await hoverGesture.moveTo(
          tester.getCenter(find.byKey(Key('note_tab_${tabB.id}'))),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(Key('note_tab_close_${tabB.id}')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(fixture.workspace.openNoteTabIds, <String>[tabA.id]);
        expect(fixture.workspace.selectedNoteId, tabA.id);
      },
    );
  });
}
