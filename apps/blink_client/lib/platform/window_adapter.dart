import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart' as wm;

import 'package:blink_client/platform/lifecycle.dart';

/// Native desktop window adapter backed by `window_manager 0.7.0`.
class NativeDesktopWindowAdapter implements DesktopWindowAdapter {
  wm.Window? _window;
  wm.ListenerId? _listenerId;
  VoidCallback? _onCloseRequested;
  bool _allowClose = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  wm.Window? _resolveWindow() {
    if (!_isDesktop) {
      return null;
    }
    return _window ??= wm.WindowManager.instance.getCurrent();
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

    _listenerId ??= window.addListener((event) {
      if (event case wm.WindowCloseRequestedEvent(:final request)) {
        if (_allowClose) {
          return;
        }
        request.cancel();
        _onCloseRequested?.call();
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
    if (window != null && listenerId != null) {
      window.removeListener(listenerId);
    }
    _listenerId = null;
    window?.close();
    _window = null;
  }
}
