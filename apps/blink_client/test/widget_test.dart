import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';
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

void main() {
  group('BlinkApp desktop shell widget tests (M2-K02 preserved)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_widget_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'renders dev build metadata and persists close behavior toggle at 760x560',
      (tester) async {
        tester.view.physicalSize = const Size(760, 560);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611221600',
          gitSha: 'a1b2c3d4e5f6',
        );
        final paths = BlinkPaths(dataRoot: tempDir);
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppBar), findsNothing);
        expect(find.byKey(const Key('settings_section')), findsOneWidget);

        final materialApp = tester.widget<MaterialApp>(
          find.byType(MaterialApp),
        );
        expect(materialApp.themeMode, ThemeMode.system);
        expect(
          materialApp.theme?.colorScheme.primary,
          BlinkColorTokens.day.accentPrimary,
        );
        expect(
          materialApp.darkTheme?.colorScheme.primary,
          BlinkColorTokens.dark.accentPrimary,
        );

        // Default close behavior is hide-to-tray.
        expect(
          controller.settings.closeButtonBehavior,
          CloseButtonBehavior.hideToTray,
        );

        // Toggle to direct exit and verify atomic persistence.
        await tester.tap(find.text('直接退出'));
        await tester.pumpAndSettle();

        expect(
          controller.settings.closeButtonBehavior,
          CloseButtonBehavior.exitApp,
        );
        expect(paths.desktopSettingsFile.existsSync(), isTrue);
        expect(
          store.loadSync().settings.closeButtonBehavior,
          CloseButtonBehavior.exitApp,
        );

        // Switch to Storage & Backup category via compact switcher at 760x560.
        await tester.tap(find.byKey(const Key('settings_compact_cat_storage')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('vault_settings_section')), findsOneWidget);
        expect(find.text('数据文件夹'), findsWidgets);
        expect(find.byKey(const Key('vault_path_value')), findsOneWidget);
        expect(find.byKey(const Key('vault_onedrive_hint')), findsNothing);

        // Switch to About BLINK category and verify build metadata & styling.
        await tester.tap(find.byKey(const Key('settings_compact_cat_about')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('about_section')), findsOneWidget);
        expect(find.text('BLINK Dev'), findsOneWidget);
        expect(find.text('DEV 开发通道'), findsOneWidget);
        expect(find.text('0.1.0-dev.202611221600'), findsOneWidget);
        expect(find.text('blink-dev'), findsNWidgets(2));
        expect(find.text('a1b2c3d'), findsOneWidget);
        expect(find.text(tempDir.path), findsOneWidget);

        // Brand mark, unified brand blue accent, and dev channel pill styling.
        final brandMarkFinder = find.byKey(const Key('brand_mark'));
        expect(brandMarkFinder, findsOneWidget);
        expect(tester.getSize(brandMarkFinder), const Size(28, 28));
        expect(
          tester.widget<BlinkBrandMark>(brandMarkFinder).size,
          equals(28.0),
        );

        final devBadgeText = tester.widget<Text>(find.text('DEV 开发通道'));
        expect(devBadgeText.style?.color, BlinkBrandColors.devPillText);
        final devBadgeContainer = tester.widget<Container>(
          find
              .ancestor(
                of: find.text('DEV 开发通道'),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (devBadgeContainer.decoration as BoxDecoration).color,
          BlinkBrandColors.devPill,
        );

        // Typography weights, tabular figures, and monospace stacks.
        expect(
          tester.widget<Text>(find.text('BLINK Dev')).style?.fontWeight,
          FontWeight.w700,
        );

        final versionText = tester.widget<SelectableText>(
          find.byKey(const Key('about_version')),
        );
        expect(
          versionText.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );

        final shaText = tester.widget<SelectableText>(
          find.byKey(const Key('about_git_sha')),
        );
        expect(shaText.style?.fontFamily, BlinkTypography.monoFontFamily);
        expect(
          shaText.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );

        final dataRootText = tester.widget<SelectableText>(
          find.byKey(const Key('about_data_root')),
        );
        expect(dataRootText.style?.fontFamily, BlinkTypography.monoFontFamily);
        expect(find.text('应用配置目录'), findsOneWidget);
      },
    );

    testWidgets(
      'renders production channel metadata and corrupt recovery notice',
      (tester) async {
        tester.view.physicalSize = const Size(960, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync('corrupted');

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink',
          identity: 'blink',
          version: '0.1.0',
          gitSha: '9988776655',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blink,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('corrupt_settings_notice')),
          findsOneWidget,
        );
        final corruptNotice = tester.widget<Text>(
          find.byKey(const Key('corrupt_settings_notice')),
        );
        expect(corruptNotice.style?.color, BlinkColorTokens.day.statusWarn);

        // Navigate to About category in Feishu Settings sidebar at 960x640.
        await tester.tap(find.byKey(const Key('settings_cat_about')));
        await tester.pumpAndSettle();

        expect(find.text('BLINK'), findsOneWidget);
        expect(find.text('正式通道'), findsOneWidget);
        expect(find.text('0.1.0'), findsOneWidget);
        expect(find.text('9988776'), findsOneWidget);
        expect(find.byKey(const Key('brand_mark')), findsOneWidget);

        final prodBadgeText = tester.widget<Text>(find.text('正式通道'));
        expect(prodBadgeText.style?.color, BlinkColorTokens.day.accentPrimary);
        final prodBadgeContainer = tester.widget<Container>(
          find
              .ancestor(of: find.text('正式通道'), matching: find.byType(Container))
              .first,
        );
        expect(
          (prodBadgeContainer.decoration as BoxDecoration).color,
          BlinkColorTokens.day.accentSubtle,
        );
      },
    );

    testWidgets(
      'adapts to system dark mode without overflow at 760x560 and 960x640',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync('{invalid');

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611240000',
          gitSha: 'deadbeefcafe',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        for (final viewport in const <Size>[Size(760, 560), Size(960, 640)]) {
          tester.view.physicalSize = viewport;
          await tester.pumpWidget(
            BlinkApp(
              controller: controller,
              initialVault: vault,
              filePicker: const NoopBlinkFilePicker(),
              enableMirrorExporter: false,
              initialDestination: BlinkNavDestination.settings,
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
          expect(scaffold.backgroundColor, BlinkColorTokens.dark.canvas);

          final corruptNotice = tester.widget<Text>(
            find.byKey(const Key('corrupt_settings_notice')),
          );
          expect(corruptNotice.style?.color, BlinkColorTokens.dark.statusWarn);
        }
      },
    );
  });
}
