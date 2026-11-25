import 'dart:io';

import 'package:blink_client/platform/build_info.dart';

/// Resolves per-identity / per-channel data paths (`INV-06`).
///
/// On Windows, defaults to `%LOCALAPPDATA%\<identity-or-channel>` unless
/// overridden by `BLINK_DATA_DIR`, and never writes to `%APPDATA%` or `~/.blink`.
class BlinkPaths {
  const BlinkPaths({required this.dataRoot, this.vaultDirOverride});

  /// Resolves application paths from [buildInfo] and environment variables.
  factory BlinkPaths.resolve(
    BlinkBuildInfo buildInfo, {
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
    bool? isLinux,
    String? fallbackTempPath,
  }) {
    final env = environment ?? Platform.environment;
    final win = isWindows ?? Platform.isWindows;
    final mac = isMacOS ?? Platform.isMacOS;
    final lin = isLinux ?? Platform.isLinux;
    final sep = win ? r'\' : '/';

    final rawVaultOverride = env['BLINK_VAULT_DIR']?.trim() ?? '';
    final vaultOverride = rawVaultOverride.isNotEmpty
        ? Directory(rawVaultOverride)
        : null;

    final override = env['BLINK_DATA_DIR']?.trim() ?? '';
    if (override.isNotEmpty) {
      return BlinkPaths(
        dataRoot: Directory(override),
        vaultDirOverride: vaultOverride,
      );
    }

    final segment = buildInfo.pathSegment;

    if (win) {
      final localAppData = _readEnvCaseInsensitive(env, 'LOCALAPPDATA');
      if (localAppData.isNotEmpty) {
        return BlinkPaths(
          dataRoot: Directory(_joinPath(localAppData, segment, sep)),
          vaultDirOverride: vaultOverride,
        );
      }
      final userProfile = _readEnvCaseInsensitive(env, 'USERPROFILE');
      if (userProfile.isNotEmpty) {
        return BlinkPaths(
          dataRoot: Directory(
            _joinPath(
              _joinPath(_joinPath(userProfile, 'AppData', sep), 'Local', sep),
              segment,
              sep,
            ),
          ),
          vaultDirOverride: vaultOverride,
        );
      }
    } else if (mac) {
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return BlinkPaths(
          dataRoot: Directory(
            _joinPath(
              _joinPath(
                _joinPath(home, 'Library', sep),
                'Application Support',
                sep,
              ),
              segment,
              sep,
            ),
          ),
          vaultDirOverride: vaultOverride,
        );
      }
    } else if (lin) {
      final xdgData = env['XDG_DATA_HOME']?.trim() ?? '';
      if (xdgData.isNotEmpty) {
        return BlinkPaths(
          dataRoot: Directory(_joinPath(xdgData, segment, sep)),
          vaultDirOverride: vaultOverride,
        );
      }
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return BlinkPaths(
          dataRoot: Directory(
            _joinPath(
              _joinPath(_joinPath(home, '.local', sep), 'share', sep),
              segment,
              sep,
            ),
          ),
          vaultDirOverride: vaultOverride,
        );
      }
    }

    final base = fallbackTempPath ?? Directory.systemTemp.path;
    return BlinkPaths(
      dataRoot: Directory(_joinPath(base, segment, sep)),
      vaultDirOverride: vaultOverride,
    );
  }

  /// Root data directory for this channel/identity.
  final Directory dataRoot;

  /// Optional explicit vault directory override from `BLINK_VAULT_DIR`.
  final Directory? vaultDirOverride;

  /// Whether `BLINK_VAULT_DIR` explicitly overrides the default vault location.
  bool get hasVaultDirOverride => vaultDirOverride != null;

  /// Active single-folder portable vault directory (`BLINK_VAULT_DIR` override
  /// or `<dataRoot>/vault`).
  Directory get vaultDir =>
      vaultDirOverride ??
      Directory(_joinPath(dataRoot.path, 'vault', Platform.pathSeparator));

  /// Resolves the effective vault directory honoring `BLINK_VAULT_DIR` first,
  /// then an optional user-configured [customVaultPath], else `<dataRoot>/vault`.
  Directory resolveEffectiveVaultDir({String? customVaultPath}) {
    if (vaultDirOverride != null) {
      return vaultDirOverride!;
    }
    final custom = customVaultPath?.trim() ?? '';
    if (custom.isNotEmpty) {
      return Directory(custom);
    }
    return vaultDir;
  }

  /// Channel-isolated WebView2 data directory (`<dataRoot>/webview2`).
  Directory get webview2Dir =>
      Directory(_joinPath(dataRoot.path, 'webview2', Platform.pathSeparator));

  /// Directory containing desktop settings files (`<dataRoot>/settings`).
  Directory get settingsDir =>
      Directory(_joinPath(dataRoot.path, 'settings', Platform.pathSeparator));

  /// Desktop settings file (`<dataRoot>/settings/desktop.json`).
  File get desktopSettingsFile =>
      File(_joinPath(settingsDir.path, 'desktop.json', Platform.pathSeparator));

  /// Runtime state directory (`<dataRoot>/run`).
  Directory get runDir =>
      Directory(_joinPath(dataRoot.path, 'run', Platform.pathSeparator));

  /// Clean-exit lifecycle receipt (`<dataRoot>/run/lifecycle.json`).
  File get lifecycleFile =>
      File(_joinPath(runDir.path, 'lifecycle.json', Platform.pathSeparator));

  static String _readEnvCaseInsensitive(Map<String, String> env, String key) {
    final exact = env[key]?.trim() ?? '';
    if (exact.isNotEmpty) {
      return exact;
    }
    final upper = key.toUpperCase();
    for (final entry in env.entries) {
      if (entry.key.toUpperCase() == upper) {
        final trimmed = entry.value.trim();
        if (trimmed.isNotEmpty) {
          return trimmed;
        }
      }
    }
    return '';
  }

  static String _joinPath(String base, String child, String sep) {
    if (base.isEmpty) {
      return child;
    }
    final normalizedBase = base.endsWith('/') || base.endsWith(r'\')
        ? base.substring(0, base.length - 1)
        : base;
    return '$normalizedBase$sep$child';
  }
}
