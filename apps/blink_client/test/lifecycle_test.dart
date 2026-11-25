import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/control_protocol.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';

class _FakeWindowAdapter implements DesktopWindowAdapter {
  int configureCalls = 0;
  int showAndFocusCalls = 0;
  int hideToTrayCalls = 0;
  int minimizeCalls = 0;
  int destroyCalls = 0;
  bool visible = false;
  double? configuredMinWidth;
  double? configuredMinHeight;
  String? configuredTitle;
  VoidCallback? onCloseRequested;
  WindowGeometrySnapshot? geometryToReport = const WindowGeometrySnapshot(
    width: 980,
    height: 680,
    maximized: false,
  );

  @override
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  }) async {
    configureCalls++;
    configuredTitle = title;
    configuredMinWidth = minWidth;
    configuredMinHeight = minHeight;
    this.onCloseRequested = onCloseRequested;
  }

  @override
  Future<void> showAndFocus() async {
    showAndFocusCalls++;
    visible = true;
  }

  @override
  Future<void> hideToTray() async {
    hideToTrayCalls++;
    visible = false;
  }

  @override
  Future<void> minimizeToTaskbar() async {
    minimizeCalls++;
    visible = false;
  }

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<WindowGeometrySnapshot?> captureGeometry() async => geometryToReport;

  @override
  Future<void> destroy() async {
    destroyCalls++;
    visible = false;
  }
}

class _FakeTrayAdapter implements DesktopTrayAdapter {
  bool initSucceeds = true;
  int initCalls = 0;
  int recreateCalls = 0;
  int destroyCalls = 0;
  String? iconAssetPath;
  String? tooltip;
  VoidCallback? onOpen;
  VoidCallback? onQuit;

  @override
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) async {
    initCalls++;
    this.iconAssetPath = iconAssetPath;
    this.tooltip = tooltip;
    this.onOpen = onOpen;
    this.onQuit = onQuit;
    return initSucceeds;
  }

  @override
  Future<void> recreate() async {
    recreateCalls++;
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
  }
}

void main() {
  group('DesktopLifecycleController (M2-K04)', () {
    late Directory tempDir;
    late BlinkPaths paths;
    late BlinkBuildInfo buildInfo;
    late DesktopSettingsStore store;
    late _FakeWindowAdapter window;
    late _FakeTrayAdapter tray;
    late List<int> exitCodes;
    late DateTime fixedUtc;

    DesktopLifecycleController buildController({
      bool busy = false,
      bool trayInitSucceeds = true,
    }) {
      tray.initSucceeds = trayInitSucceeds;
      return DesktopLifecycleController(
        buildInfo: buildInfo,
        paths: paths,
        settingsStore: store,
        windowAdapter: window,
        trayAdapter: tray,
        isBusy: () async => busy,
        exitProcess: exitCodes.add,
        nowUtc: () => fixedUtc,
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_lifecycle_test_');
      paths = BlinkPaths(dataRoot: tempDir);
      buildInfo = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev-test',
        version: '0.1.0-dev.202611221600',
        gitSha: '1234567890abcdef',
      );
      store = DesktopSettingsStore(file: paths.desktopSettingsFile);
      window = _FakeWindowAdapter();
      tray = _FakeTrayAdapter();
      exitCodes = <int>[];
      fixedUtc = DateTime.utc(2026, 11, 22, 16, 45, 0);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'normal startup configures 760x560 minimum, creates tray, shows window',
      () async {
        final controller = buildController();
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        expect(window.configureCalls, 1);
        expect(window.configuredMinWidth, 760);
        expect(window.configuredMinHeight, 560);
        expect(window.configuredTitle, 'BLINK Dev Test');
        expect(window.showAndFocusCalls, 1);
        expect(tray.initCalls, 1);
        expect(tray.iconAssetPath, 'assets/icons/blink-dev.ico');
        expect(controller.isWindowVisible, isTrue);
        expect(controller.isTrayAvailable, isTrue);
      },
    );

    test('close button hides to tray by default without exiting', () async {
      final controller = buildController();
      await controller.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );

      await controller.handleCloseButton();

      expect(window.hideToTrayCalls, 1);
      expect(controller.isWindowVisible, isFalse);
      expect(exitCodes, isEmpty);
      expect(paths.lifecycleFile.existsSync(), isFalse);
    });

    test(
      'close button exits through shared sequence when configured to exit',
      () async {
        final controller = buildController();
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );
        controller.updateCloseButtonBehavior(CloseButtonBehavior.exitApp);

        await controller.handleCloseButton();

        expect(exitCodes, const <int>[0]);
        expect(tray.destroyCalls, 1);
        expect(window.destroyCalls, 1);

        final lifecycle = jsonDecode(
          paths.lifecycleFile.readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(lifecycle['exitReason'], 'close_button');
        expect(lifecycle['windowWasVisible'], isTrue);
        expect(lifecycle['version'], '0.1.0-dev.202611221600');
        expect(lifecycle['identity'], 'blink-dev-test');
        expect(lifecycle['timestampUtc'], fixedUtc.toIso8601String());
      },
    );

    test('tray quit uses shared sequence and writes lifecycle.json', () async {
      final controller = buildController();
      await controller.initializeStartup(
        const LaunchOptions(mode: LaunchMode.background, quiet: false),
      );

      expect(window.showAndFocusCalls, 0);
      expect(window.minimizeCalls, 0);
      expect(controller.isWindowVisible, isFalse);

      await controller.performShutdown(ExitReason.trayQuit);

      expect(exitCodes, const <int>[0]);
      expect(tray.destroyCalls, 1);
      final lifecycle = jsonDecode(
        paths.lifecycleFile.readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(lifecycle['exitReason'], 'tray_quit');
      expect(lifecycle['windowWasVisible'], isFalse);
    });

    test(
      '--background falls back to minimize when tray initialization fails',
      () async {
        final controller = buildController(trayInitSucceeds: false);
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.background, quiet: false),
        );

        expect(controller.isTrayAvailable, isFalse);
        expect(window.showAndFocusCalls, 0);
        expect(window.minimizeCalls, 1);
      },
    );

    test('quit-for-update replies ok, writes lifecycle.json, removes tray, and exits', () async {
      final controller = buildController();
      await controller.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );

      final pingResp = await controller.handleControlCommand(
        ControlCommand.ping,
      );
      expect(pingResp, const ControlResponse.ok());

      final quitResp = await controller.handleControlCommand(
        ControlCommand.quitForUpdate,
      );
      expect(quitResp, const ControlResponse.ok());
      expect(exitCodes, const <int>[0]);
      expect(tray.destroyCalls, 1);

      final lifecycle = jsonDecode(
        paths.lifecycleFile.readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(lifecycle['exitReason'], 'quit_for_update');
      expect(lifecycle['windowWasVisible'], isTrue);
      expect(lifecycle['version'], '0.1.0-dev.202611221600');
      expect(lifecycle['identity'], 'blink-dev-test');
    });

    test(
      'quit-for-update still exits when lifecycle.json cannot be written',
      () async {
        final controller = buildController();
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.background, quiet: false),
        );
        // A directory squatting on the target path makes the atomic rename
        // fail deterministically on every platform.
        Directory(paths.lifecycleFile.path).createSync(recursive: true);

        final resp = await controller.handleControlCommand(
          ControlCommand.quitForUpdate,
        );

        expect(resp, const ControlResponse.ok());
        expect(exitCodes, const <int>[0]);
        expect(tray.destroyCalls, 1);
        expect(window.destroyCalls, 1);
        expect(controller.lastShutdownPersistenceError, isNotNull);
      },
    );

    test('quit-for-update replies busy and stays running when busy', () async {
      final controller = buildController(busy: true);
      await controller.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: false),
      );

      final resp = await controller.handleControlCommand(
        ControlCommand.quitForUpdate,
      );
      expect(resp, const ControlResponse.error('busy'));
      expect(exitCodes, isEmpty);
      expect(tray.destroyCalls, 0);
      expect(paths.lifecycleFile.existsSync(), isFalse);
    });

    test(
      'BLINK_QUIET=1 never shows window, creates tray, or focuses',
      () async {
        final controller = buildController();
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: true),
        );

        expect(window.configureCalls, 0);
        expect(window.showAndFocusCalls, 0);
        expect(window.minimizeCalls, 0);
        expect(tray.initCalls, 0);

        final focusResp = await controller.handleControlCommand(
          ControlCommand.focus,
        );
        expect(focusResp, const ControlResponse.ok());
        expect(window.showAndFocusCalls, 0);

        final quitResp = await controller.handleControlCommand(
          ControlCommand.quitForUpdate,
        );
        expect(quitResp, const ControlResponse.ok());
        expect(exitCodes, const <int>[0]);
        final lifecycle = jsonDecode(
          paths.lifecycleFile.readAsStringSync(),
        ) as Map<String, dynamic>;
        expect(lifecycle['exitReason'], 'quit_for_update');
        expect(lifecycle['windowWasVisible'], isFalse);
      },
    );

    test(
      'TaskbarCreated triggers tray recreation when tray is active',
      () async {
        final controller = buildController();
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.background, quiet: false),
        );

        await controller.handleTaskbarCreated();
        expect(tray.recreateCalls, 1);
      },
    );

    test('onFlushBeforeShutdown executes before lifecycle.json across all exit reasons', () async {
      for (final reason in ExitReason.values) {
        final order = <String>[];
        final subDir = Directory.systemTemp.createTempSync(
          'blink_flush_order_',
        );
        addTearDown(() {
          if (subDir.existsSync()) {
            subDir.deleteSync(recursive: true);
          }
        });
        final subPaths = BlinkPaths(dataRoot: subDir);
        final subExitCodes = <int>[];
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: subPaths,
          settingsStore: DesktopSettingsStore(
            file: subPaths.desktopSettingsFile,
          ),
          windowAdapter: _FakeWindowAdapter(),
          trayAdapter: _FakeTrayAdapter(),
          onFlushBeforeShutdown: () async {
            expect(subPaths.lifecycleFile.existsSync(), isFalse);
            order.add('flush');
          },
          onBeforeExit: () async {
            expect(subPaths.lifecycleFile.existsSync(), isTrue);
            order.add('before_exit');
          },
          exitProcess: subExitCodes.add,
          nowUtc: () => fixedUtc,
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        await controller.performShutdown(reason);

        expect(order, const <String>['flush', 'before_exit']);
        expect(subExitCodes, const <int>[0]);
        expect(controller.lastShutdownPersistenceError, isNull);
      }
    });

    test(
      'onFlushBeforeShutdown error is recorded without blocking exit',
      () async {
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: window,
          trayAdapter: tray,
          onFlushBeforeShutdown: () async {
            throw StateError('simulated wal flush failure');
          },
          exitProcess: exitCodes.add,
          nowUtc: () => fixedUtc,
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final ok = await controller.performShutdown(ExitReason.quitForUpdate);

        expect(ok, isTrue);
        expect(exitCodes, const <int>[0]);
        expect(paths.lifecycleFile.existsSync(), isTrue);
        expect(controller.lastShutdownPersistenceError, isA<StateError>());
      },
    );
  });
}
