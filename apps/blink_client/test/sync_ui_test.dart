import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/secret_store.dart';
import 'package:blink_client/ui/settings_page.dart';
import 'package:blink_client/ui/sync_conflict_dialog.dart';
import 'package:blink_client/ui/sync_status_capsule.dart';

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

  group(
    'Sync UI widgets (capsule, desktop + mobile settings, conflict dialog)',
    () {
      late Directory rootTemp;
      HttpOverrides? previousHttpOverrides;

      setUp(() {
        previousHttpOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        rootTemp = Directory.systemTemp.createTempSync('blink_sync_ui_test_');
      });

      tearDown(() {
        HttpOverrides.global = previousHttpOverrides;
        if (rootTemp.existsSync()) {
          rootTemp.deleteSync(recursive: true);
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
        required String name,
        required bool isMobile,
        List<LanPeerAnnouncement>? sharedLanRegistry,
      }) async {
        final paths = BlinkPaths(
          dataRoot: Directory('${rootTemp.path}/${name}_app'),
          defaultVaultDir: Directory('${rootTemp.path}/${name}_vault'),
        );
        final lifecycle = DesktopLifecycleController(
          buildInfo: BlinkBuildInfo.normalized(
            channel: 'blink-dev',
            version: '0.1.0-dev.202611271400',
            gitSha: '1234567890ab',
          ),
          paths: paths,
          settingsStore: DesktopSettingsStore(file: paths.desktopSettingsFile),
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await lifecycle.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: true),
        );
        final vault = (await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
              deviceName: name,
            ),
          ),
        ))!;
        final sync = BlinkSyncController(
          paths: paths,
          expectedChannel: BlinkChannel.blinkDev,
          secretStore: InMemoryBlinkSecretStore(channel: 'blink-dev'),
          lanDiscovery: LanDiscovery(
            adapter: InMemoryLanDiscoveryAdapter(
              sharedRegistry: sharedLanRegistry,
            ),
          ),
          isQuiet: true,
          isMobilePlatform: isMobile,
          enableSseWakeup: false,
          writeDebounce: const Duration(milliseconds: 50),
        );
        final workspace = BlinkWorkspaceController(
          lifecycle: lifecycle,
          filePicker: const NoopBlinkFilePicker(),
          initialVault: vault,
          syncController: sync,
          enableMirrorExporter: false,
        );
        await tester.runAsync(() => workspace.initialize());
        addTearDown(() async {
          await tester.runAsync(() => sync.stopForShutdown());
          workspace.dispose();
          sync.dispose();
          await tester.runAsync(() async {
            if (vault.isOpen) {
              await vault.checkpointAndClose();
            }
          });
        });
        return (lifecycle: lifecycle, vault: vault, workspace: workspace);
      }

      testWidgets(
        'BlinkSyncStatusCapsule displays honest states, semantics, and conflict/sync actions',
        (tester) async {
          final desktop = await createFixture(
            tester,
            name: 'capsule_desktop',
            isMobile: false,
          );
          final mobile = await createFixture(
            tester,
            name: 'capsule_mobile',
            isMobile: true,
          );

          var conflictsOpened = false;
          var settingsOpened = false;

          await tester.pumpWidget(
            MaterialApp(
              theme: BlinkTheme.day(),
              home: Scaffold(
                body: BlinkSyncStatusCapsule(
                  sync: mobile.workspace.sync,
                  onOpenConflicts: () => conflictsOpened = true,
                  onOpenSyncSettings: () => settingsOpened = true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Initially unconfigured.
          expect(find.byKey(const Key('sync_status_capsule')), findsOneWidget);
          expect(find.textContaining('未配置同步'), findsOneWidget);
          await tester.tap(
            find.byKey(const Key('sync_capsule_settings_button')),
          );
          expect(settingsOpened, isTrue);

          // Pair mobile with desktop -> transitions to idleSynced with Sync Now button.
          await tester.runAsync(() async {
            await desktop.workspace.sync.setDesktopServerEnabled(
              true,
              bindHost: '127.0.0.1',
              port: 0,
            );
            final port = desktop.workspace.sync.activeServerPort!;
            final code = desktop.workspace.sync.generatePairingCode()!;
            final baseEntry = await desktop.vault.raw.createEntry(
              bodyMd: '胶囊同步测试基线',
            );
            await mobile.workspace.sync.pairWithDirectPeer(
              baseUrl: 'http://127.0.0.1:$port',
              pairingCode: code.code,
            );
            await mobile.workspace.sync.setAutoSyncEnabled(false);

            // Stop desktop & create concurrent conflict.
            await desktop.workspace.sync.setDesktopServerEnabled(false);
            await desktop.vault.raw.updateEntry(
              id: baseEntry.id,
              bodyMd: '桌面编辑冲突文本',
            );
            await mobile.vault.raw.updateEntry(
              id: baseEntry.id,
              bodyMd: '手机编辑冲突文本',
            );

            // First verify peerAsleep while desktop is stopped.
            await mobile.workspace.sync.syncNow(manual: true);
          });
          await tester.pumpAndSettle();

          expect(find.textContaining('对端休眠'), findsOneWidget);
          expect(
            find.byKey(const Key('sync_capsule_sync_now_button')),
            findsOneWidget,
          );

          // Restart desktop & sync -> capsule surfaces conflict alert + button.
          await tester.runAsync(() async {
            final port = desktop.workspace.sync.config.desktopServerPort;
            await desktop.workspace.sync.setDesktopServerEnabled(
              true,
              bindHost: '127.0.0.1',
              port: port == 0 ? 0 : port,
            );
            // Re-point if port changed (port 0 picks ephemeral).
            final actualPort = desktop.workspace.sync.activeServerPort!;
            final newCode = desktop.workspace.sync.generatePairingCode()!;
            await mobile.workspace.sync.pairWithDirectPeer(
              baseUrl: 'http://127.0.0.1:$actualPort',
              pairingCode: newCode.code,
            );
          });
          await tester.pumpAndSettle();

          expect(find.textContaining('条同步冲突待处理'), findsOneWidget);
          await tester.tap(
            find.byKey(const Key('sync_capsule_conflicts_button')),
          );
          expect(conflictsOpened, isTrue);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'BlinkSettingsPage renders Desktop Host controls on desktop and hides them cleanly on mobile < 600px with #private relay exclusion ON',
        (tester) async {
          // 1. Desktop viewport
          tester.view.physicalSize = const Size(1280, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final desktop = await createFixture(
            tester,
            name: 'settings_desktop',
            isMobile: false,
          );

          await tester.pumpWidget(
            MaterialApp(
              theme: BlinkTheme.day(),
              home: Scaffold(
                body: BlinkSettingsPage(
                  workspace: desktop.workspace,
                  isMobilePlatform: false,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('sync_settings_section')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('sync_host_toggle')), findsOneWidget);
          expect(find.byKey(const Key('sync_auto_toggle')), findsOneWidget);
          expect(
            find.byKey(const Key('sync_exclude_private_relay_toggle')),
            findsOneWidget,
          );

          // `#private` relay exclusion toggle MUST default to ON (`true`).
          final privSwitch = tester.widget<SwitchListTile>(
            find.byKey(const Key('sync_exclude_private_relay_toggle')),
          );
          expect(privSwitch.value, isTrue);

          // Generate E2EE master key and confirm recovery code box appears.
          await tester.ensureVisible(
            find.byKey(const Key('sync_generate_master_key_button')),
          );
          await tester.tap(
            find.byKey(const Key('sync_generate_master_key_button')),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('sync_recovery_code_display')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const Key('sync_recovery_code_display')),
              matching: find.textContaining('BLINK1-'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);

          // 2. Mobile < 600px viewport
          tester.view.physicalSize = const Size(390, 844);
          final mobile = await createFixture(
            tester,
            name: 'settings_mobile',
            isMobile: true,
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: BlinkTheme.dark(),
              home: Scaffold(
                body: BlinkSettingsPage(
                  workspace: mobile.workspace,
                  isMobilePlatform: true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('sync_settings_section')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('sync_host_toggle')), findsNothing);
          expect(find.byKey(const Key('sync_peer_url_input')), findsOneWidget);
          expect(
            find.byKey(const Key('sync_exclude_private_relay_toggle')),
            findsOneWidget,
          );
          final mobilePrivSwitch = tester.widget<SwitchListTile>(
            find.byKey(const Key('sync_exclude_private_relay_toggle')),
          );
          expect(mobilePrivSwitch.value, isTrue);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'BlinkSyncConflictDialog switches side-by-side (>=600px) vs stacked (<600px) and resolves conflict cleanly',
        (tester) async {
          final desktop = await createFixture(
            tester,
            name: 'conflict_desktop',
            isMobile: false,
          );
          final mobile = await createFixture(
            tester,
            name: 'conflict_mobile',
            isMobile: true,
          );

          late String entryId;
          await tester.runAsync(() async {
            await desktop.workspace.sync.setDesktopServerEnabled(
              true,
              bindHost: '127.0.0.1',
              port: 0,
            );
            final port = desktop.workspace.sync.activeServerPort!;
            final code = desktop.workspace.sync.generatePairingCode()!;
            final entry = await desktop.vault.raw.createEntry(bodyMd: '原始文本');
            entryId = entry.id;
            await mobile.workspace.sync.pairWithDirectPeer(
              baseUrl: 'http://127.0.0.1:$port',
              pairingCode: code.code,
            );
            await mobile.workspace.sync.setAutoSyncEnabled(false);

            await desktop.workspace.sync.setDesktopServerEnabled(false);
            await desktop.vault.raw.updateEntry(
              id: entryId,
              bodyMd: '桌面修改版本 A',
            );
            await mobile.vault.raw.updateEntry(id: entryId, bodyMd: '手机修改版本 B');

            await desktop.workspace.sync.setDesktopServerEnabled(
              true,
              bindHost: '127.0.0.1',
              port: port,
            );
            await mobile.workspace.sync.syncNow(manual: true);
          });
          expect(mobile.workspace.sync.openConflictCount, 1);

          // Desktop wide layout >= 600px -> side-by-side comparison.
          tester.view.physicalSize = const Size(1024, 768);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            MaterialApp(
              theme: BlinkTheme.day(),
              home: Scaffold(
                body: BlinkSyncConflictDialog(sync: mobile.workspace.sync),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('conflict_compare_side_by_side')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('conflict_compare_stacked')),
            findsNothing,
          );
          expect(find.text('保留本机'), findsOneWidget);
          expect(find.text('采用远端'), findsOneWidget);
          expect(find.text('合并保存后确认'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // Mobile narrow layout < 600px -> stacked vertical comparison.
          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('conflict_compare_stacked')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('conflict_compare_side_by_side')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);

          // Edit merge text and tap "合并保存后确认".
          await tester.enterText(
            find.byKey(const Key('conflict_merge_editor')),
            '最终手动合并内容：A + B',
          );
          await tester.tap(find.byKey(const Key('conflict_merge_save_button')));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();

          expect(mobile.workspace.sync.openConflictCount, 0);
          final resolvedEntry = await tester.runAsync(
            () => mobile.vault.raw.getEntryById(entryId),
          );
          expect(resolvedEntry?.bodyMd, '最终手动合并内容：A + B');
          expect(tester.takeException(), isNull);
        },
      );
    },
  );
}
