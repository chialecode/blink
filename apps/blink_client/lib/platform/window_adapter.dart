import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'package:blink_client/platform/lifecycle.dart';

/// Native desktop window adapter backed by `window_manager 0.7.0`.
///
/// Configures an immersive borderless desktop frame (`TitleBarStyle.hidden`)
/// while preserving native Win32/DWM edge resizing, drop shadow, Windows 11
/// rounded corners, Aero Snap, Snap Layouts (`setMaximizeButtonBounds`), and
/// silent `--background` / `BLINK_QUIET=1` startup.
class NativeDesktopWindowAdapter implements DesktopWindowChromeAdapter {
  wm.Window? _window;
  wm.ListenerId? _listenerId;
  VoidCallback? _onCloseRequested;
  bool _allowClose = false;
  bool? _lastMaximized;
  final StreamController<bool> _maximizedController =
      StreamController<bool>.broadcast();

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  bool get supportsCustomWindowChrome => _isDesktop;

  @override
  bool get usesLeadingSystemWindowControls => !kIsWeb && Platform.isMacOS;

  @override
  Stream<bool> get maximizedChanges => _maximizedController.stream;

  wm.Window? _resolveWindow() {
    if (!_isDesktop) {
      return null;
    }
    return _window ??= wm.WindowManager.instance.getCurrent();
  }

  void _emitMaximized(bool maximized) {
    if (_lastMaximized == maximized || _maximizedController.isClosed) {
      return;
    }
    _lastMaximized = maximized;
    _maximizedController.add(maximized);
  }

  @override
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  }) async {
    _onCloseRequested = onCloseRequested;
    final window = _resolveWindow();
    if (window == null) {
      return;
    }

    window.title = title;
    window.minimumSize = Size(minWidth, minHeight).toNative();
    window.titleBarStyle = wm.TitleBarStyle.hidden;
    if (Platform.isMacOS) {
      window.isWindowControlButtonsVisible = true;
    }
    _lastMaximized = window.isMaximized;

    _listenerId ??= window.addListener((event) {
      switch (event) {
        case wm.WindowCloseRequestedEvent(:final request):
          if (_allowClose) {
            return;
          }
          request.cancel();
          _onCloseRequested?.call();
        case wm.WindowMaximizedEvent():
          _emitMaximized(true);
        case wm.WindowRestoredEvent():
        case wm.WindowResizedEvent():
          _emitMaximized(window.isMaximized);
        default:
          break;
      }
    });
  }

  @override
  Future<void> showAndFocus() async {
    final window = _resolveWindow();
    if (window == null) {
      return;
    }
    window.isVisibleInTaskbar = true;
    if (window.isMinimized) {
      window.restore();
    }
    window.show();
    window.focus();
  }

  @override
  Future<void> hideToTray() async {
    final window = _resolveWindow();
    if (window == null) {
      return;
    }
    window.hide();
  }

  @override
  Future<void> minimizeToTaskbar() async {
    final window = _resolveWindow();
    if (window == null) {
      return;
    }
    window.isVisibleInTaskbar = true;
    window.minimize();
  }

  @override
  Future<void> startDragging() async {
    final window = _resolveWindow();
    if (window == null) {
      return;
    }
    window.startDragging();
  }

  @override
  Future<void> toggleMaximize() async {
    final window = _resolveWindow();
    if (window == null) {
      return;
    }
    if (window.isMaximized) {
      window.unmaximize();
      _emitMaximized(false);
    } else {
      window.maximize();
      _emitMaximized(true);
    }
  }

  @override
  Future<bool> isMaximized() async {
    final window = _resolveWindow();
    if (window == null) {
      return false;
    }
    final maximized = window.isMaximized;
    _lastMaximized = maximized;
    return maximized;
  }

  @override
  Future<void> showSystemMenu(Offset position) async {
    final window = _resolveWindow();
    if (window == null || !wm.Window.isSystemMenuSupported()) {
      return;
    }
    window.showSystemMenu(position.toNative());
  }

  @override
  void setMaximizeButtonBounds(Rect? bounds) {
    final window = _resolveWindow();
    if (window == null || !wm.Window.isMaximizeButtonBoundsSupported()) {
      return;
    }
    window.setMaximizeButtonBounds((bounds ?? Rect.zero).toNative());
  }

  @override
  Future<bool> isVisible() async {
    final window = _resolveWindow();
    if (window == null) {
      return false;
    }
    return window.isVisible && !window.isMinimized;
  }

  @override
  Future<WindowGeometrySnapshot?> captureGeometry() async {
    final window = _resolveWindow();
    if (window == null) {
      return null;
    }
    final sz = window.size;
    if (sz.width <= 0 || sz.height <= 0) {
      return null;
    }
    return WindowGeometrySnapshot(
      width: sz.width,
      height: sz.height,
      maximized: window.isMaximized,
    );
  }

  @override
  Future<void> destroy() async {
    _allowClose = true;
    final window = _window;
    final listenerId = _listenerId;
    if (window != null) {
      if (wm.Window.isMaximizeButtonBoundsSupported()) {
        window.setMaximizeButtonBounds(Rect.zero.toNative());
      }
      if (listenerId != null) {
        window.removeListener(listenerId);
      }
    }
    _listenerId = null;
    window?.close();
    _window = null;
    if (!_maximizedController.isClosed) {
      await _maximizedController.close();
    }
  }
}
