import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/application/editor_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/ui/settings_page.dart';

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
  }) async => false;

  @override
  Future<void> recreate() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android BlinkPaths dual-channel isolation (INV-06)', () {
    test('maps blink and blink-dev channels to <AppFilesDir>/blink[-dev]', () {
      const prodFilesDir = '/data/user/0/io.github.chialecode.blink/files';
      const prodCacheDir = '/data/user/0/io.github.chialecode.blink/cache';
      const prodNoBackupDir =
          '/data/user/0/io.github.chialecode.blink/no_backup';

      // Android APK builds carry BLINK_CHANNEL without Windows BLINK_IDENTITY.
      final prodInfo = BlinkBuildInfo.normalized(channel: 'blink');
      expect(prodInfo.isSourceBuild, isTrue);
      expect(prodInfo.isProductionChannel, isTrue);

      final prodPaths = BlinkPaths.resolve(
        prodInfo,
        environment: const <String, String>{},
        isAndroid: true,
        androidFilesDir: prodFilesDir,
        androidCacheDir: prodCacheDir,
        androidNoBackupFilesDir: prodNoBackupDir,
      );
      expect(prodPaths.dataRoot.path, '$prodFilesDir/blink');
      expect(prodPaths.defaultVaultDir.path, '$prodFilesDir/blink');
      expect(prodPaths.vaultDir.path, '$prodFilesDir/blink');
      expect(prodPaths.cacheDir.path, prodCacheDir);
      expect(prodPaths.mediaCacheDir.path, '$prodCacheDir/media');
      expect(prodPaths.noBackupDir?.path, '$prodNoBackupDir/blink');
      expect(
        prodPaths.isForbiddenTargetPath('$prodFilesDir/blink-dev'),
        isTrue,
      );
      expect(prodPaths.isForbiddenTargetPath('$prodFilesDir/blink'), isFalse);

      const devFilesDir = '/data/user/0/io.github.chialecode.blink.dev/files';
      const devCacheDir = '/data/user/0/io.github.chialecode.blink.dev/cache';
      const devNoBackupDir =
          '/data/user/0/io.github.chialecode.blink.dev/no_backup';

      final devInfo = BlinkBuildInfo.normalized(channel: 'blink-dev');
      final devPaths = BlinkPaths.resolve(
        devInfo,
        environment: const <String, String>{},
        isAndroid: true,
        androidFilesDir: devFilesDir,
        androidCacheDir: devCacheDir,
        androidNoBackupFilesDir: devNoBackupDir,
      );
      expect(devPaths.dataRoot.path, '$devFilesDir/blink-dev');
      expect(devPaths.defaultVaultDir.path, '$devFilesDir/blink-dev');
      expect(devPaths.vaultDir.path, '$devFilesDir/blink-dev');
      expect(devPaths.cacheDir.path, devCacheDir);
      expect(devPaths.mediaCacheDir.path, '$devCacheDir/media');
      expect(devPaths.noBackupDir?.path, '$devNoBackupDir/blink-dev');
      expect(devPaths.isForbiddenTargetPath('$devFilesDir/blink'), isTrue);
      expect(
        devPaths.isForbiddenTargetPath('$devFilesDir/blink/nested'),
        isTrue,
      );
      expect(devPaths.isForbiddenTargetPath('$devFilesDir/blink-dev'), isFalse);
    });

    test('refuses to fall back to ephemeral systemTemp when androidFilesDir is missing', () {
      final devInfo = BlinkBuildInfo.normalized(channel: 'blink-dev');
      expect(
        () => BlinkPaths.resolve(
          devInfo,
          environment: const <String, String>{},
          isAndroid: true,
        ),
        throwsStateError,
      );
      expect(
        () => BlinkPaths.resolve(
          devInfo,
          environment: const <String, String>{},
          isAndroid: true,
          androidFilesDir: '   ',
        ),
        throwsStateError,
      );
    });

    test('blocks cross-channel BLINK_VAULT_DIR override on Android', () {
      const filesDir = '/data/user/0/io.github.chialecode.blink.dev/files';
      final devInfo = BlinkBuildInfo.normalized(channel: 'blink-dev');
      expect(
        () => BlinkPaths.resolve(
          devInfo,
          environment: const <String, String>{
            'BLINK_VAULT_DIR': '$filesDir/blink',
          },
          isAndroid: true,
          androidFilesDir: filesDir,
        ),
        throwsStateError,
      );
    });
  });

  group('AndroidPlatformBridge & AndroidBlinkFilePicker MethodChannel', () {
    const channel = MethodChannel(kBlinkAndroidPlatformChannelName);
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('queries storage dirs, SAF pickers, content URI write, and multicast lock', () async {
      Uint8List? writtenBytes;
      String? writtenUri;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'getStorageDirs':
                return <String, String>{
                  'filesDir':
                      '/data/user/0/io.github.chialecode.blink.dev/files',
                  'noBackupFilesDir':
                      '/data/user/0/io.github.chialecode.blink.dev/no_backup',
                  'cacheDir':
                      '/data/user/0/io.github.chialecode.blink.dev/cache',
                };
              case 'pickFileToOpen':
                return '/data/user/0/io.github.chialecode.blink.dev/cache/picked_imports/sample.pdf';
              case 'pickFileToSave':
                return 'content://com.android.externalstorage.documents/document/primary%3Aexport.txt';
              case 'writeBytesToContentUri':
                final args = call.arguments as Map<Object?, Object?>;
                writtenUri = args['uri'] as String?;
                writtenBytes = args['bytes'] as Uint8List?;
                return true;
              case 'acquireMulticastLock':
                return true;
              case 'releaseMulticastLock':
                return true;
            }
            return null;
          });

      const bridge = AndroidPlatformBridge();
      final dirs = await bridge.getStorageDirs();
      expect(
        dirs.filesDir,
        '/data/user/0/io.github.chialecode.blink.dev/files',
      );
      expect(
        dirs.noBackupFilesDir,
        '/data/user/0/io.github.chialecode.blink.dev/no_backup',
      );
      expect(
        dirs.cacheDir,
        '/data/user/0/io.github.chialecode.blink.dev/cache',
      );

      const picker = AndroidBlinkFilePicker(bridge: bridge);
      final opened = await picker.pickFileToOpen(title: '选择附件');
      expect(opened, endsWith('/sample.pdf'));
      expect(await picker.pickDirectory(title: 'ignored'), isNull);

      final savedUri = await picker.pickFileToSave(
        title: '导出副本',
        suggestedFileName: 'note.txt',
      );
      expect(savedUri, startsWith('content://'));

      final payload = Uint8List.fromList('blink-android-export'.codeUnits);
      final wrote = await picker.writeBytesToUri(savedUri!, payload);
      expect(wrote, isTrue);
      expect(writtenUri, savedUri);
      expect(writtenBytes, payload);

      expect(await bridge.acquireMulticastLock(), isTrue);
      expect(await bridge.releaseMulticastLock(), isTrue);

      expect(calls.map((c) => c.method).toList(), <String>[
        'getStorageDirs',
        'pickFileToOpen',
        'pickFileToSave',
        'writeBytesToContentUri',
        'acquireMulticastLock',
        'releaseMulticastLock',
      ]);
    });

    test('throws StateError on incomplete storage dirs and wires default picker factory', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getStorageDirs') {
              return <String, String>{'filesDir': '', 'cacheDir': '/tmp'};
            }
            return null;
          });

      const bridge = AndroidPlatformBridge();
      await expectLater(bridge.getStorageDirs(), throwsStateError);

      expect(
        createDefaultBlinkFilePicker(
          quietOverride: false,
          isAndroidOverride: true,
          isWindowsOverride: false,
        ),
        isA<AndroidBlinkFilePicker>(),
      );
      expect(
        createDefaultBlinkFilePicker(
          quietOverride: true,
          isAndroidOverride: true,
          isWindowsOverride: false,
        ),
        isA<NoopBlinkFilePicker>(),
      );
    });

    test(
      'workspace exportBlobToPicker streams bytes to Android content:// URI',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'blink_android_saf_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        Uint8List? exportedBytes;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'pickFileToSave') {
                return 'content://com.android.providers.downloads/document/42';
              }
              if (call.method == 'writeBytesToContentUri') {
                final args = call.arguments as Map<Object?, Object?>;
                exportedBytes = args['bytes'] as Uint8List?;
                return true;
              }
              return null;
            });

        final paths = BlinkPaths(dataRoot: tempDir);
        final lifecycle = DesktopLifecycleController(
          buildInfo: BlinkBuildInfo.normalized(channel: 'blink-dev'),
          paths: paths,
          settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await lifecycle.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: true),
        );
        final workspace = BlinkWorkspaceController(
          lifecycle: lifecycle,
          filePicker: const AndroidBlinkFilePicker(),
          enableMirrorExporter: false,
        );
        await workspace.initialize();
        try {
          final expected = Uint8List.fromList('Android SAF 附件内容'.codeUnits);
          final blob = await workspace.vault!.blobs.putBytes(
            expected,
            mimeType: 'text/plain',
          );
          final result = await workspace.exportBlobToPicker(blob);
          expect(result, isNotNull);
          expect(exportedBytes, expected);
          expect(workspace.bannerIsError, isFalse);
        } finally {
          await workspace.flushAndCloseForShutdown();
          workspace.dispose();
        }
      },
    );
  });

  group('Mobile < 600px BFM editing experience & Settings mobile guards', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_mobile_ui_test_');
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
    createMobileFixture(
      WidgetTester tester, {
      BlinkNavDestination initialDestination = BlinkNavDestination.stream,
    }) async {
      final paths = BlinkPaths(dataRoot: tempDir);
      final buildInfo = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        version: '0.1.0-dev.202611271200',
        gitSha: 'abcdef123456',
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
      'anchors bottom BFM composer, shows >=44dp keyboard autocomplete bar for #, @, /, [[, and toggles Edit/Preview cleanly on <600px',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createMobileFixture(tester);
        await tester.runAsync(
          () => fixture.workspace.createEntry(bodyMd: '知识图谱基线笔记 #研究'),
        );

        await tester.pumpWidget(
          BlinkApp(
            controller: fixture.lifecycle,
            workspaceController: fixture.workspace,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('mobile_bottom_nav')), findsOneWidget);
        expect(find.byKey(const Key('mobile_bottom_composer')), findsOneWidget);

        // Composer must be anchored cleanly below the stream entries list.
        final composerRect = tester.getRect(
          find.byKey(const Key('mobile_bottom_composer')),
        );
        final bottomNavRect = tester.getRect(
          find.byKey(const Key('mobile_bottom_nav')),
        );
        expect(composerRect.bottom, lessThanOrEqualTo(bottomNavRect.top + 0.5));
        expect(composerRect.top, greaterThan(300));

        // Simulate soft keyboard opening: bottom nav yields and composer shifts up cleanly.
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('mobile_bottom_nav')), findsNothing);
        final raisedComposerRect = tester.getRect(
          find.byKey(const Key('mobile_bottom_composer')),
        );
        expect(raisedComposerRect.bottom, lessThanOrEqualTo(844 - 300 + 0.5));

        // 1. Trigger `#` autocomplete -> horizontal bar (NOT OverlayPortal popup), >=44dp target.
        final inputFinder = find.byKey(const Key('bfm_editor_input'));
        final textField = tester.widget<TextField>(inputFinder);
        final syntaxController =
            textField.controller! as BlinkSyntaxTextController;

        await tester.tap(inputFinder);
        await tester.pump();
        syntaxController.value = const TextEditingValue(
          text: '移动闪念 #pri',
          selection: TextSelection.collapsed(offset: 9),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('mobile_autocomplete_bar')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('bfm_autocomplete_overlay')), findsNothing);

        final firstCandidate = find.byKey(
          const Key('mobile_autocomplete_candidate_0'),
        );
        expect(firstCandidate, findsOneWidget);
        final candidateSize = tester.getSize(firstCandidate);
        expect(candidateSize.height, greaterThanOrEqualTo(44.0));
        expect(candidateSize.width, greaterThanOrEqualTo(44.0));

        // Selecting `#private` atomically replaces trigger and clears composing.
        await tester.tap(firstCandidate);
        await tester.pumpAndSettle();
        expect(syntaxController.text, '移动闪念 #private ');
        expect(syntaxController.value.composing, TextRange.empty);
        expect(find.byKey(const Key('mobile_autocomplete_bar')), findsNothing);

        // 2. Trigger `@` autocomplete -> suggests `@t[00:00]` / `@book:`.
        syntaxController.value = TextEditingValue(
          text: '${syntaxController.text}@t',
          selection: TextSelection.collapsed(
            offset: syntaxController.text.length + 2,
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('mobile_autocomplete_bar')),
          findsOneWidget,
        );
        expect(find.text('@t[00:00]'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('mobile_autocomplete_candidate_0')),
        );
        await tester.pumpAndSettle();
        expect(syntaxController.text, contains('@t[00:00]'));

        // 3. Trigger `/` autocomplete -> suggests BFM block snippets.
        syntaxController.value = TextEditingValue(
          text: '${syntaxController.text}/task',
          selection: TextSelection.collapsed(
            offset: syntaxController.text.length + 5,
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('mobile_autocomplete_bar')),
          findsOneWidget,
        );
        expect(find.text('/task'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('mobile_autocomplete_candidate_0')),
        );
        await tester.pumpAndSettle();
        expect(syntaxController.text, contains('- [ ] '));

        // 4. Trigger `[[` wikilink autocomplete -> finds existing CJK entry.
        syntaxController.value = TextEditingValue(
          text: '${syntaxController.text}[[知识',
          selection: TextSelection.collapsed(
            offset: syntaxController.text.length + 4,
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('mobile_autocomplete_bar')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('mobile_autocomplete_candidate_0')),
        );
        await tester.pumpAndSettle();
        expect(syntaxController.text, contains('[[entry:'));

        // 5. While CJK IME composition is active, autocomplete bar stays hidden (SPK-02 Rule 1).
        final beforeComposing = '${syntaxController.text} #拼音';
        syntaxController.value = TextEditingValue(
          text: beforeComposing,
          selection: TextSelection.collapsed(offset: beforeComposing.length),
          composing: TextRange(
            start: beforeComposing.length - 2,
            end: beforeComposing.length,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mobile_autocomplete_bar')), findsNothing);

        // Clear composing and close keyboard, then toggle Edit / Preview tabs.
        tester.view.viewInsets = FakeViewPadding.zero;
        const finalNote = '# 手机离线笔记\n==移动端亮点== #mobile #private\n- [ ] 验证离线保存';
        syntaxController.value = const TextEditingValue(
          text: finalNote,
          selection: TextSelection.collapsed(offset: finalNote.length),
          composing: TextRange.empty,
        );
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('mobile_tab_preview')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mobile_bfm_preview')), findsOneWidget);
        expect(find.textContaining('手机离线笔记'), findsWidgets);

        await tester.tap(find.byKey(const Key('mobile_tab_edit')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bfm_editor_input')), findsOneWidget);
        expect(syntaxController.text, finalNote);

        // Submit offline entry and verify persistence in SQLite vault.
        await tester.tap(find.byKey(const Key('bfm_submit_button')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();

        final entries = await tester.runAsync(
          () => fixture.vault.raw.listEntries(),
        );
        expect(entries!.any((e) => e.bodyMd == finalNote), isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'settings hides desktop-only tray, folder switcher, and mirror controls on mobile platforms',
      (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final fixture = await createMobileFixture(
          tester,
          initialDestination: BlinkNavDestination.settings,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.light(),
            home: Scaffold(
              body: BlinkSettingsPage(
                workspace: fixture.workspace,
                isMobilePlatform: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Desktop-only controls must be hidden on mobile.
        expect(find.byKey(const Key('close_behavior_toggle')), findsNothing);
        expect(find.byKey(const Key('vault_mirror_status')), findsNothing);
        expect(find.byKey(const Key('vault_path_input')), findsNothing);
        expect(find.byKey(const Key('vault_pick_button')), findsNothing);
        expect(find.byKey(const Key('vault_switch_button')), findsNothing);
        expect(find.byKey(const Key('vault_mirror_button')), findsNothing);
        expect(find.byKey(const Key('vault_reset_button')), findsNothing);
        expect(find.byKey(const Key('vault_onedrive_hint')), findsNothing);

        // Mobile-appropriate controls & About metadata remain intact.
        expect(find.byKey(const Key('surface_mode_toggle')), findsOneWidget);
        expect(find.byKey(const Key('vault_path_value')), findsOneWidget);
        expect(find.byKey(const Key('vault_channel_lock')), findsOneWidget);
        expect(find.byKey(const Key('vault_backup_button')), findsOneWidget);
        expect(find.byKey(const Key('vault_rebuild_button')), findsOneWidget);
        expect(find.byKey(const Key('mobile_sandbox_notice')), findsOneWidget);
        expect(find.byKey(const Key('about_section')), findsOneWidget);
        expect(find.byKey(const Key('about_version')), findsOneWidget);
        expect(find.byKey(const Key('about_channel')), findsOneWidget);
        expect(find.byKey(const Key('about_data_root')), findsOneWidget);
      },
    );
  });
}
