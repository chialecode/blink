import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
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
  group('BlinkApp desktop shell widget tests (M2-K02)', () {
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

        await tester.pumpWidget(BlinkApp(controller: controller));
        await tester.pumpAndSettle();

        expect(find.text('BLINK Dev'), findsOneWidget);
        expect(find.text('DEV 开发通道'), findsOneWidget);
        expect(find.text('0.1.0-dev.202611221600'), findsOneWidget);
        expect(find.text('blink-dev'), findsNWidgets(2));
        expect(find.text('a1b2c3d'), findsOneWidget);
        expect(find.text(tempDir.path), findsOneWidget);

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

        await tester.pumpWidget(BlinkApp(controller: controller));
        await tester.pumpAndSettle();

        expect(find.text('BLINK'), findsOneWidget);
        expect(find.text('正式通道'), findsOneWidget);
        expect(find.text('0.1.0'), findsOneWidget);
        expect(find.text('9988776'), findsOneWidget);
        expect(
          find.byKey(const Key('corrupt_settings_notice')),
          findsOneWidget,
        );
      },
    );
  });
}
