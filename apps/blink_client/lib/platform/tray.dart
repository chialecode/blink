import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart' as tray;

import 'package:blink_client/platform/lifecycle.dart';

/// Native desktop system tray adapter backed by `tray_manager 0.9.0`.
///
/// Displays the channel-specific icon (`blink.ico` vs `blink-dev.ico`), handles
/// left-click open and right-click context menu ("打开" / "退出"), and supports
/// re-registration after Windows Explorer `TaskbarCreated` broadcasts.
class NativeDesktopTrayAdapter implements DesktopTrayAdapter {
  tray.TrayIcon? _trayIcon;
  tray.Image? _iconImage;
  tray.Menu? _menu;
  tray.MenuItem? _openItem;
  tray.MenuItem? _quitItem;
  tray.ListenerId? _trayListenerId;
  tray.ListenerId? _menuListenerId;

  String? _iconAssetPath;
  String? _tooltip;
  VoidCallback? _onOpen;
  VoidCallback? _onQuit;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) async {
    _iconAssetPath = iconAssetPath;
    _tooltip = tooltip;
    _onOpen = onOpen;
    _onQuit = onQuit;
    return _createTrayIcon();
  }

  Future<bool> _createTrayIcon() async {
    if (!_isDesktop) {
      return false;
    }
    try {
      if (!tray.TrayManager.instance.isSupported()) {
        return false;
      }

      await destroy();

      final icon = tray.TrayIcon.create();
      if (icon == null) {
        return false;
      }

      final assetPath = _iconAssetPath;
      tray.Image? image;
      if (assetPath != null && assetPath.isNotEmpty) {
        image = tray.ImageAsset.fromAsset(assetPath);
      }

      final menu = tray.Menu.create();
      final openItem = tray.MenuItem.createWithLabelAndType(
        '打开',
        tray.MenuItemType.normal,
      );
      final quitItem = tray.MenuItem.createWithLabelAndType(
        '退出',
        tray.MenuItemType.normal,
      );

      if (menu == null || openItem == null || quitItem == null) {
        openItem?.dispose();
        quitItem?.dispose();
        menu?.dispose();
        image?.dispose();
        icon.dispose();
        return false;
      }

      menu.addItem(openItem);
      menu.addSeparator();
      menu.addItem(quitItem);

      final openItemId = openItem.id;
      final quitItemId = quitItem.id;

      final menuListenerId = menu.addListener((event) {
        if (event case tray.MenuItemClickedEvent(:final itemId)) {
          if (itemId == openItemId) {
            _onOpen?.call();
          } else if (itemId == quitItemId) {
            _onQuit?.call();
          }
        }
      });

      final trayListenerId = icon.addListener((event) {
        switch (event) {
          case tray.TrayIconClickedEvent():
          case tray.TrayIconDoubleClickedEvent():
            _onOpen?.call();
          case tray.TrayIconRightClickedEvent():
            // Right-click menu is opened natively via ContextMenuTrigger.
            break;
        }
      });

      if (image != null) {
        icon.icon = image;
      }
      if (_tooltip != null) {
        icon.setTooltip(_tooltip);
      }
      icon.setContextMenu(menu);
      icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);

      final shown = icon.setVisible(true);
      if (!shown) {
        icon.removeListener(trayListenerId);
        menu.removeListener(menuListenerId);
        openItem.dispose();
        quitItem.dispose();
        menu.dispose();
        image?.dispose();
        icon.dispose();
        return false;
      }

      _trayIcon = icon;
      _iconImage = image;
      _menu = menu;
      _openItem = openItem;
      _quitItem = quitItem;
      _trayListenerId = trayListenerId;
      _menuListenerId = menuListenerId;
      return true;
    } catch (_) {
      await destroy();
      return false;
    }
  }

  @override
  Future<void> recreate() async {
    if (!_isDesktop || _onOpen == null || _onQuit == null) {
      return;
    }
    await _createTrayIcon();
  }

  @override
  Future<void> destroy() async {
    final icon = _trayIcon;
    final trayListenerId = _trayListenerId;
    if (icon != null && trayListenerId != null) {
      icon.removeListener(trayListenerId);
    }
    _trayListenerId = null;

    final menu = _menu;
    final menuListenerId = _menuListenerId;
    if (menu != null && menuListenerId != null) {
      menu.removeListener(menuListenerId);
    }
    _menuListenerId = null;

    if (icon != null) {
      icon.setVisible(false);
      icon.setContextMenu(null);
      icon.dispose();
    }
    _trayIcon = null;

    _openItem?.dispose();
    _openItem = null;
    _quitItem?.dispose();
    _quitItem = null;
    menu?.dispose();
    _menu = null;

    _iconImage?.dispose();
    _iconImage = null;
  }
}
