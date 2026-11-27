import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/control_protocol.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/paths.dart';

/// Minimum desktop main window width (`NFR-PLAT-001`).
const double kMinDesktopWindowWidth = 760;

/// Minimum desktop main window height (`NFR-PLAT-001`).
const double kMinDesktopWindowHeight = 560;

/// Snapshot of desktop window geometry captured before shutdown.
class WindowGeometrySnapshot {
  const WindowGeometrySnapshot({
    required this.width,
    required this.height,
    required this.maximized,
  });

  final double width;
  final double height;
  final bool maximized;
}

/// Platform window operations abstracted for unit testing.
abstract interface class DesktopWindowAdapter {
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  });

  Future<void> showAndFocus();

  Future<void> hideToTray();

  Future<void> minimizeToTaskbar();

  Future<bool> isVisible();

  Future<WindowGeometrySnapshot?> captureGeometry();

  Future<void> destroy();
}

/// Platform system-tray operations abstracted for unit testing.
abstract interface class DesktopTrayAdapter {
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  });

  Future<void> recreate();

  Future<void> destroy();
}

/// Reason recorded into `<dataRoot>/run/lifecycle.json` during clean exit.
enum ExitReason {
  trayQuit('tray_quit'),
  closeButton('close_button'),
  quitForUpdate('quit_for_update');

  const ExitReason(this.wireValue);

  final String wireValue;
}

/// Schema of `<dataRoot>/run/lifecycle.json`.
class LifecycleRecord {
  const LifecycleRecord({
    required this.exitReason,
    required this.windowWasVisible,
    required this.version,
    required this.identity,
    required this.timestampUtc,
  });

  final String exitReason;
  final bool windowWasVisible;
  final String version;
  final String identity;
  final String timestampUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'exitReason': exitReason,
    'windowWasVisible': windowWasVisible,
    'version': version,
    'identity': identity,
    'timestampUtc': timestampUtc,
  };
}

typedef BusyCheck = Future<bool> Function();
typedef ProcessExitFn = void Function(int code);
typedef CleanupHook = Future<void> Function();

/// Unified desktop lifecycle state machine (architecture §4.3).
///
/// Coordinates startup (`normal`, `--background`, `BLINK_QUIET=1`), tray
/// availability fallback, close button policy (`hideToTray` vs `exitApp`),
/// control pipe commands, and the shared save-and-exit sequence.
class DesktopLifecycleController extends ChangeNotifier {
  DesktopLifecycleController({
    required this.buildInfo,
    required this.paths,
    required this.settingsStore,
    required this.windowAdapter,
    required this.trayAdapter,
    BusyCheck? isBusy,
    this.onFlushBeforeShutdown,
    this._onBeforeExit,
    ProcessExitFn? exitProcess,
    DateTime Function()? nowUtc,
    this._deferredExitDelay = Duration.zero,
  }) : _isBusy = isBusy ?? _alwaysIdle,
       _exitProcess = exitProcess ?? _noopExit,
       _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final BlinkBuildInfo buildInfo;
  final BlinkPaths paths;
  final DesktopSettingsStore settingsStore;
  final DesktopWindowAdapter windowAdapter;
  final DesktopTrayAdapter trayAdapter;
  final BusyCheck _isBusy;
  CleanupHook? onFlushBeforeShutdown;
  final CleanupHook? _onBeforeExit;
  final ProcessExitFn _exitProcess;
  final DateTime Function() _nowUtc;
  final Duration _deferredExitDelay;

  /// Registers or replaces the vault/draft shutdown flush callback executed
  /// before `lifecycle.json` is written and before process exit.
  void setShutdownFlushHook(CleanupHook? hook) {
    onFlushBeforeShutdown = hook;
  }

  DesktopSettings _settings = const DesktopSettings();
  bool _recoveredCorruptSettings = false;
  bool _quiet = false;
  bool _trayAvailable = false;
  bool _windowVisible = false;
  bool _isShuttingDown = false;
  bool _exited = false;
  Timer? _deferredExitTimer;
  Object? _lastShutdownPersistenceError;

  DesktopSettings get settings => _settings;

  /// First error raised while persisting shutdown state (window geometry,
  /// `lifecycle.json`, tray removal); `null` when everything succeeded.
  Object? get lastShutdownPersistenceError => _lastShutdownPersistenceError;
  bool get recoveredCorruptSettings => _recoveredCorruptSettings;
  bool get isQuiet => _quiet;
  bool get isTrayAvailable => _trayAvailable;
  bool get isWindowVisible => _windowVisible;
  bool get isShuttingDown => _isShuttingDown;

  static Future<bool> _alwaysIdle() async => false;
  static void _noopExit(int _) {}

  /// Runs startup policy for the primary (or source-build) instance.
  Future<void> initializeStartup(LaunchOptions options) async {
    _quiet = options.quiet;
    final loaded = settingsStore.loadSync();
    _settings = loaded.settings;
    _recoveredCorruptSettings = loaded.recoveredFromCorrupt;
    notifyListeners();

    if (_quiet) {
      // Quiet smoke/rehearsal mode: never show window, never create tray,
      // never invoke any focus API.
      _trayAvailable = false;
      _windowVisible = false;
      return;
    }

    await windowAdapter.configure(
      title: buildInfo.productName,
      minWidth: kMinDesktopWindowWidth,
      minHeight: kMinDesktopWindowHeight,
      onCloseRequested: () {
        unawaited(handleCloseButton());
      },
    );

    _trayAvailable = await trayAdapter.init(
      iconAssetPath: buildInfo.trayIconAssetPath,
      tooltip: '${buildInfo.productName} (${buildInfo.version})',
      onOpen: () {
        unawaited(handleOpenRequest());
      },
      onQuit: () {
        unawaited(performShutdown(ExitReason.trayQuit));
      },
    );

    if (options.isBackground) {
      if (_trayAvailable) {
        // Window already starts hidden natively; stay out of taskbar/focus.
        _windowVisible = false;
      } else {
        // Tray unavailable fallback: minimize to taskbar rather than hiding
        // without any way for the user to reopen.
        await windowAdapter.minimizeToTaskbar();
        _windowVisible = false;
      }
      return;
    }

    await windowAdapter.showAndFocus();
    _windowVisible = true;
  }

  /// Persists a new close-button behavior atomically to `settings/desktop.json`.
  void updateCloseButtonBehavior(CloseButtonBehavior behavior) {
    if (_settings.closeButtonBehavior == behavior) {
      return;
    }
    _settings = _settings.copyWith(closeButtonBehavior: behavior);
    settingsStore.saveSync(_settings);
    notifyListeners();
  }

  /// Persists the preferred surface mode (`null` = follow OS system theme)
  /// atomically to `settings/desktop.json`.
  void updateSurfaceMode(DesktopSurfacePreference? mode) {
    if (_settings.surfaceMode == mode) {
      return;
    }
    _settings = mode == null
        ? _settings.copyWith(clearSurfaceMode: true)
        : _settings.copyWith(surfaceMode: mode);
    settingsStore.saveSync(_settings);
    notifyListeners();
  }

  /// Persists an optional custom portable vault path (`null` = default channel
  /// vault under Documents or sandbox) atomically to `settings/desktop.json`.
  void updateCustomVaultPath(String? path) {
    final normalized = path?.trim();
    final effective = (normalized == null || normalized.isEmpty)
        ? null
        : normalized;
    if (_settings.customVaultPath == effective) {
      return;
    }
    _settings = effective == null
        ? _settings.copyWith(clearCustomVaultPath: true)
        : _settings.copyWith(customVaultPath: effective);
    settingsStore.saveSync(_settings);
    notifyListeners();
  }

  /// Restores and focuses the main window (from tray click or `focus` command).
  Future<void> handleOpenRequest() async {
    if (_quiet || _isShuttingDown) {
      return;
    }
    await windowAdapter.showAndFocus();
    _windowVisible = true;
  }

  /// Handles clicking the native window close button.
  Future<void> handleCloseButton() async {
    if (_isShuttingDown) {
      return;
    }
    if (_settings.closeButtonBehavior == CloseButtonBehavior.hideToTray &&
        _trayAvailable) {
      await windowAdapter.hideToTray();
      _windowVisible = false;
      return;
    }
    await performShutdown(ExitReason.closeButton);
  }

  /// Re-registers the tray icon when Windows broadcasts `TaskbarCreated`.
  Future<void> handleTaskbarCreated() async {
    if (_quiet || _isShuttingDown || !_trayAvailable) {
      return;
    }
    await trayAdapter.recreate();
  }

  /// Executes one control-pipe command on the UI isolate.
  Future<ControlResponse> handleControlCommand(ControlCommand command) async {
    switch (command) {
      case ControlCommand.ping:
        return const ControlResponse.ok();
      case ControlCommand.focus:
        if (!_quiet && !_isShuttingDown) {
          await handleOpenRequest();
        }
        return const ControlResponse.ok();
      case ControlCommand.quitForUpdate:
        final accepted = await performShutdown(
          ExitReason.quitForUpdate,
          deferExit: true,
        );
        if (!accepted) {
          return const ControlResponse.error('busy');
        }
        return const ControlResponse.ok();
    }
  }

  /// Shared save-and-exit sequence for tray quit, close-to-exit, and
  /// `quit-for-update` (architecture §4.3).
  ///
  /// Returns `false` if the app is currently busy and refuses shutdown.
  Future<bool> performShutdown(
    ExitReason reason, {
    bool deferExit = false,
  }) async {
    if (_isShuttingDown) {
      return true;
    }
    if (await _isBusy()) {
      return false;
    }
    _isShuttingDown = true;

    // Once `_isShuttingDown` is set, every later request short-circuits to
    // `true`, so a persistence failure must never strand the process
    // half-shut-down (tray quit dead, `quit-for-update` replying ok forever).
    // Geometry and `lifecycle.json` are best-effort diagnostics; the failure
    // is kept in [lastShutdownPersistenceError] and the exit still completes.
    var wasVisible = false;
    try {
      wasVisible = _quiet ? false : await windowAdapter.isVisible();
      if (!_quiet) {
        final geometry = await windowAdapter.captureGeometry();
        if (geometry != null) {
          final updated = _settings.copyWith(
            windowWidth: geometry.width,
            windowHeight: geometry.height,
            windowMaximized: geometry.maximized,
          );
          if (updated != _settings) {
            _settings = updated;
            settingsStore.saveSync(_settings);
          }
        }
      }
    } catch (error) {
      _lastShutdownPersistenceError = error;
    }

    // Flush active drafts, mirror exporter, and SQLite WAL checkpoint BEFORE
    // writing lifecycle.json or exiting (`INV-07`). Any error is captured into
    // `lastShutdownPersistenceError` without blocking exit.
    if (onFlushBeforeShutdown != null) {
      try {
        await onFlushBeforeShutdown!();
      } catch (error) {
        _lastShutdownPersistenceError ??= error;
      }
    }

    try {
      final record = LifecycleRecord(
        exitReason: reason.wireValue,
        windowWasVisible: wasVisible,
        version: buildInfo.version,
        identity: buildInfo.identity,
        timestampUtc: _nowUtc().toUtc().toIso8601String(),
      );
      const encoder = JsonEncoder.withIndent('  ');
      writeStringAtomicallySync(
        paths.lifecycleFile,
        '${encoder.convert(record.toJson())}\n',
      );
    } catch (error) {
      _lastShutdownPersistenceError ??= error;
    }

    if (_trayAvailable) {
      _trayAvailable = false;
      try {
        await trayAdapter.destroy();
      } catch (error) {
        _lastShutdownPersistenceError ??= error;
      }
    }
    _windowVisible = false;

    if (deferExit && _deferredExitDelay > Duration.zero) {
      // Give the control pipe isolate a brief window to flush `{"ok": true}`
      // to the caller before terminating the process.
      _deferredExitTimer?.cancel();
      _deferredExitTimer = Timer(_deferredExitDelay, () {
        unawaited(_finalizeExit());
      });
    } else {
      await _finalizeExit();
    }

    return true;
  }

  Future<void> _finalizeExit() async {
    if (_exited) {
      return;
    }
    _exited = true;
    if (_onBeforeExit != null) {
      await _onBeforeExit();
    }
    if (!_quiet) {
      await windowAdapter.destroy();
    }
    _exitProcess(0);
  }

  @override
  void dispose() {
    _deferredExitTimer?.cancel();
    super.dispose();
  }
}
