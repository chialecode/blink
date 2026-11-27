import 'dart:convert';
import 'dart:io';

import 'package:blink_client/platform/atomic_io.dart';

/// User-configurable appearance surface preference (`null` = follow system).
enum DesktopSurfacePreference {
  day('day', '日间清朗'),
  sepia('sepia', '暖纸伴读'),
  dark('dark', '夜间低眩光');

  const DesktopSurfacePreference(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static DesktopSurfacePreference? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final item in DesktopSurfacePreference.values) {
      if (item.wireValue == value) {
        return item;
      }
    }
    return null;
  }
}

/// User-configurable behavior when the main window close button is clicked.
enum CloseButtonBehavior {
  hideToTray('hide_to_tray', '隐藏到托盘'),
  exitApp('exit_app', '直接退出');

  const CloseButtonBehavior(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static CloseButtonBehavior? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final item in CloseButtonBehavior.values) {
      if (item.wireValue == value) {
        return item;
      }
    }
    return null;
  }
}

/// Persisted desktop shell settings stored at `<dataRoot>/settings/desktop.json`.
class DesktopSettings {
  const DesktopSettings({
    this.closeButtonBehavior = CloseButtonBehavior.hideToTray,
    this.windowWidth,
    this.windowHeight,
    this.windowMaximized,
    this.surfaceMode,
    this.customVaultPath,
  });

  final CloseButtonBehavior closeButtonBehavior;
  final double? windowWidth;
  final double? windowHeight;
  final bool? windowMaximized;

  /// Optional theme surface override (`null` follows OS light/dark system theme).
  final DesktopSurfacePreference? surfaceMode;

  /// Optional custom `<BLINK_VAULT_DIR>` path (`null` uses the channel's
  /// default portable vault directory under Documents or the active sandbox).
  final String? customVaultPath;

  DesktopSettings copyWith({
    CloseButtonBehavior? closeButtonBehavior,
    double? windowWidth,
    double? windowHeight,
    bool? windowMaximized,
    DesktopSurfacePreference? surfaceMode,
    bool clearSurfaceMode = false,
    String? customVaultPath,
    bool clearCustomVaultPath = false,
  }) {
    return DesktopSettings(
      closeButtonBehavior: closeButtonBehavior ?? this.closeButtonBehavior,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowMaximized: windowMaximized ?? this.windowMaximized,
      surfaceMode: clearSurfaceMode ? null : (surfaceMode ?? this.surfaceMode),
      customVaultPath: clearCustomVaultPath
          ? null
          : (customVaultPath ?? this.customVaultPath),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'closeButtonBehavior': closeButtonBehavior.wireValue,
      if (windowWidth != null) 'windowWidth': windowWidth,
      if (windowHeight != null) 'windowHeight': windowHeight,
      if (windowMaximized != null) 'windowMaximized': windowMaximized,
      if (surfaceMode != null) 'surfaceMode': surfaceMode!.wireValue,
      if (customVaultPath != null && customVaultPath!.trim().isNotEmpty)
        'customVaultPath': customVaultPath!.trim(),
    };
  }

  /// Parses [json] strictly; returns null if any known field has an invalid
  /// type or unsupported enum value so callers can preserve the corrupt file.
  static DesktopSettings? tryFromJson(Map<String, Object?> json) {
    CloseButtonBehavior behavior = CloseButtonBehavior.hideToTray;
    if (json.containsKey('closeButtonBehavior')) {
      final parsed = CloseButtonBehavior.tryParse(json['closeButtonBehavior']);
      if (parsed == null) {
        return null;
      }
      behavior = parsed;
    }

    double? width;
    if (json.containsKey('windowWidth') && json['windowWidth'] != null) {
      final raw = json['windowWidth'];
      if (raw is! num || !raw.isFinite || raw <= 0) {
        return null;
      }
      width = raw.toDouble();
    }

    double? height;
    if (json.containsKey('windowHeight') && json['windowHeight'] != null) {
      final raw = json['windowHeight'];
      if (raw is! num || !raw.isFinite || raw <= 0) {
        return null;
      }
      height = raw.toDouble();
    }

    bool? maximized;
    if (json.containsKey('windowMaximized') &&
        json['windowMaximized'] != null) {
      final raw = json['windowMaximized'];
      if (raw is! bool) {
        return null;
      }
      maximized = raw;
    }

    DesktopSurfacePreference? surfaceMode;
    if (json.containsKey('surfaceMode') && json['surfaceMode'] != null) {
      final parsed = DesktopSurfacePreference.tryParse(json['surfaceMode']);
      if (parsed == null) {
        return null;
      }
      surfaceMode = parsed;
    }

    String? customVaultPath;
    if (json.containsKey('customVaultPath') &&
        json['customVaultPath'] != null) {
      final raw = json['customVaultPath'];
      if (raw is! String) {
        return null;
      }
      final trimmed = raw.trim();
      customVaultPath = trimmed.isEmpty ? null : trimmed;
    }

    return DesktopSettings(
      closeButtonBehavior: behavior,
      windowWidth: width,
      windowHeight: height,
      windowMaximized: maximized,
      surfaceMode: surfaceMode,
      customVaultPath: customVaultPath,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is DesktopSettings &&
        other.closeButtonBehavior == closeButtonBehavior &&
        other.windowWidth == windowWidth &&
        other.windowHeight == windowHeight &&
        other.windowMaximized == windowMaximized &&
        other.surfaceMode == surfaceMode &&
        other.customVaultPath == customVaultPath;
  }

  @override
  int get hashCode => Object.hash(
    closeButtonBehavior,
    windowWidth,
    windowHeight,
    windowMaximized,
    surfaceMode,
    customVaultPath,
  );
}

/// Outcome of loading [DesktopSettings] from disk.
class DesktopSettingsLoadResult {
  const DesktopSettingsLoadResult({
    required this.settings,
    required this.recoveredFromCorrupt,
    this.preservedCorruptFile,
  });

  final DesktopSettings settings;
  final bool recoveredFromCorrupt;
  final File? preservedCorruptFile;
}

/// Atomic persistence store for `<dataRoot>/settings/desktop.json`.
class DesktopSettingsStore {
  DesktopSettingsStore({required this.file, DateTime Function()? nowUtc})
    : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final File file;
  final DateTime Function() _nowUtc;

  DesktopSettingsLoadResult loadSync() {
    final jsonResult = readJsonObjectOrDefaultSync(file, nowUtc: _nowUtc);
    if (jsonResult.wasCorrupt) {
      return DesktopSettingsLoadResult(
        settings: const DesktopSettings(),
        recoveredFromCorrupt: true,
        preservedCorruptFile: jsonResult.preservedCorruptFile,
      );
    }
    if (!jsonResult.exists) {
      return const DesktopSettingsLoadResult(
        settings: DesktopSettings(),
        recoveredFromCorrupt: false,
      );
    }

    final parsed = DesktopSettings.tryFromJson(jsonResult.data);
    if (parsed == null) {
      final preserved = file.existsSync()
          ? preserveCorruptFileSync(file, nowUtc: _nowUtc)
          : null;
      return DesktopSettingsLoadResult(
        settings: const DesktopSettings(),
        recoveredFromCorrupt: true,
        preservedCorruptFile: preserved,
      );
    }

    return DesktopSettingsLoadResult(
      settings: parsed,
      recoveredFromCorrupt: false,
    );
  }

  void saveSync(DesktopSettings settings) {
    const encoder = JsonEncoder.withIndent('  ');
    final payload = '${encoder.convert(settings.toJson())}\n';
    writeStringAtomicallySync(file, payload);
  }
}
