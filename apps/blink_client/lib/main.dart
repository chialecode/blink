import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/control_protocol.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/tray.dart';
import 'package:blink_client/platform/window_adapter.dart';
import 'package:blink_client/platform/windows/control_pipe.dart';
import 'package:blink_client/platform/windows/single_instance.dart';

const MethodChannel _kDesktopShellChannel = MethodChannel(
  'io.github.chialecode.blink/desktop_shell',
);

Future<void> main(List<String> args) async {
  final options = parseLaunchOptions(args);
  final buildInfo = BlinkBuildInfo.fromEnvironment();
  final paths = BlinkPaths.resolve(buildInfo);

  SingleInstanceLock? singleInstanceLock;

  // Source builds (empty BLINK_IDENTITY) never claim a mutex or control pipe.
  if (Platform.isWindows && !buildInfo.isSourceBuild) {
    final mutexName = buildInfo.mutexName!;
    final pipeName = buildInfo.controlPipeName!;

    if (options.isQuitForUpdate) {
      if (!SingleInstanceLock.isRunning(mutexName)) {
        exit(0);
      }
      final result = await ControlPipeClient.sendCommand(
        pipeName,
        ControlCommand.quitForUpdate,
        retryOnNotFound: true,
      );
      _writeStdoutBestEffort(result.response?.encodeLine());
      exit(result.exitCodeForQuitForUpdate);
    }

    final lock = SingleInstanceLock.acquire(mutexName);
    if (!lock.isPrimary) {
      if (options.isBackground) {
        exit(0);
      }
      final result = await ControlPipeClient.sendCommand(
        pipeName,
        ControlCommand.focus,
        retryOnNotFound: true,
        // Quiet smoke runs never touch foreground APIs (§3.1).
        grantForegroundToServer: !options.quiet,
      );
      _writeStdoutBestEffort(result.response?.encodeLine());
      exit(result.exitCodeForFocus);
    }
    singleInstanceLock = lock;
  } else if (options.isQuitForUpdate) {
    // Source builds or non-Windows runs have no installed single instance.
    exit(0);
  }

  WidgetsFlutterBinding.ensureInitialized();

  ControlPipeServer? pipeServer;
  final settingsStore = DesktopSettingsStore(file: paths.desktopSettingsFile);
  final windowAdapter = NativeDesktopWindowAdapter();
  final trayAdapter = NativeDesktopTrayAdapter();

  final controller = DesktopLifecycleController(
    buildInfo: buildInfo,
    paths: paths,
    settingsStore: settingsStore,
    windowAdapter: windowAdapter,
    trayAdapter: trayAdapter,
    deferredExitDelay: const Duration(milliseconds: 80),
    onBeforeExit: () async {
      await pipeServer?.stop();
      pipeServer = null;
      singleInstanceLock?.release();
      singleInstanceLock = null;
    },
    exitProcess: exit,
  );

  _kDesktopShellChannel.setMethodCallHandler((call) async {
    if (call.method == 'onTaskbarCreated') {
      await controller.handleTaskbarCreated();
    }
  });

  await controller.initializeStartup(options);

  if (Platform.isWindows && !buildInfo.isSourceBuild) {
    final pipeName = buildInfo.controlPipeName!;
    try {
      pipeServer = await ControlPipeServer.start(
        pipeName: pipeName,
        onCommand: controller.handleControlCommand,
      );
    } catch (_) {
      await trayAdapter.destroy();
      if (!options.quiet) {
        await windowAdapter.destroy();
      }
      singleInstanceLock?.release();
      exit(1);
    }
  }

  runApp(BlinkApp(controller: controller));
}

void _writeStdoutBestEffort(String? line) {
  if (line == null || line.isEmpty) {
    return;
  }
  try {
    stdout.write(line);
  } catch (_) {
    // GUI-subsystem Windows executables may have no attached stdout handle.
  }
}
