import 'dart:convert';
import 'dart:io';

import 'package:blink_client/platform/atomic_io.dart';

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
  });

  final CloseButtonBehavior closeButtonBehavior;
  final double? windowWidth;
  final double? windowHeight;
  final bool? windowMaximized;

  DesktopSettings copyWith({
    CloseButtonBehavior? closeButtonBehavior,
    double? windowWidth,
    double? windowHeight,
    bool? windowMaximized,
  }) {
    return DesktopSettings(
      closeButtonBehavior: closeButtonBehavior ?? this.closeButtonBehavior,
      windowWidth: windowWidth ?? this.windowWidth,
      windowHeight: windowHeight ?? this.windowHeight,
      windowMaximized: windowMaximized ?? this.windowMaximized,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'closeButtonBehavior': closeButtonBehavior.wireValue,
      if (windowWidth != null) 'windowWidth': windowWidth,
      if (windowHeight != null) 'windowHeight': windowHeight,
      if (windowMaximized != null) 'windowMaximized': windowMaximized,
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

    return DesktopSettings(
      closeButtonBehavior: behavior,
      windowWidth: width,
      windowHeight: height,
      windowMaximized: maximized,
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
        other.windowMaximized == windowMaximized;
  }

  @override
  int get hashCode => Object.hash(
    closeButtonBehavior,
    windowWidth,
    windowHeight,
    windowMaximized,
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
