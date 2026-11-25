import 'dart:io';

import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/windows/win32_bindings.dart';

/// Resolves BLINK's 3-root directory architecture (`DEC-031`, `INV-06`):
///
/// 1. **App local state (`dataRoot`)**: `settings/`, `run/`, `webview2/`,
///    `credentials/`, `logs/`, `cache/` — stored in OS app-local storage
///    (`%LOCALAPPDATA%\<identity>` on Windows, never `%APPDATA%` or `~/.blink`).
/// 2. **Default portable vault (`defaultVaultDir`)**: `vault.json`, `db/`,
///    `index/`, `blobs/`, `mirror/` — stored under the user's Documents folder
///    (`<Documents>\<identity>` via `SHGetKnownFolderPath(FOLDERID_Documents)`
///    on Windows) for installed builds, or inside `<dataRoot>/vault` when
///    `BLINK_DATA_DIR` isolates the run.
/// 3. **Source-build sandbox (empty `BLINK_IDENTITY`)**: isolated under the
///    Git-ignored repository `<repoRoot>/.local/blink-dev/{app,vault}` (or
///    `<systemTemp>/blink-source-dev/{app,vault}` if outside a repository),
///    never sharing directories with installed `blink` or `blink-dev`.
class BlinkPaths {
  const BlinkPaths({
    required Directory dataRoot,
    Directory? defaultVaultDir,
    Directory? vaultDirOverride,
  }) : this._(
         dataRoot,
         defaultVaultDir,
         vaultDirOverride,
         const <String>[],
         null,
         null,
       );

  const BlinkPaths._(
    this.dataRoot,
    this._defaultVaultDir,
    this.vaultDirOverride,
    this._forbiddenRoots,
    this._isWindowsContext,
    this._canonicalBaseDir,
  );

  /// Resolves application local state and default portable vault paths from
  /// [buildInfo] and environment variables while enforcing channel isolation.
  factory BlinkPaths.resolve(
    BlinkBuildInfo buildInfo, {
    Map<String, String>? environment,
    bool? isWindows,
    bool? isMacOS,
    bool? isLinux,
    String? fallbackTempPath,
    String? Function()? resolveSystemDocumentsDir,
    Directory? repoRootOverride,
    Directory? currentDirectoryOverride,
    String? executablePathOverride,
  }) {
    final env = environment ?? Platform.environment;
    final win = isWindows ?? Platform.isWindows;
    final mac = isMacOS ?? Platform.isMacOS;
    final lin = isLinux ?? Platform.isLinux;
    final sep = win ? r'\' : '/';

    final rawDataOverride = _readEnvCaseInsensitive(env, 'BLINK_DATA_DIR');
    final hasExplicitDataDir = rawDataOverride.isNotEmpty;
    final rawVaultOverride = _readEnvCaseInsensitive(env, 'BLINK_VAULT_DIR');
    final vaultOverride = rawVaultOverride.isNotEmpty
        ? Directory(rawVaultOverride)
        : null;
    final rawDocumentsOverride = _readEnvCaseInsensitive(
      env,
      'BLINK_DOCUMENTS_DIR',
    );

    // Issue #21: Source builds targeting the formal production channel `blink`
    // are refused unless both explicit opt-in (`BLINK_ALLOW_SOURCE_PROD=1`)
    // and an explicit isolated `BLINK_DATA_DIR` are supplied.
    if (buildInfo.isSourceBuild && buildInfo.isProductionChannel) {
      final allowSourceProd =
          _readEnvCaseInsensitive(env, 'BLINK_ALLOW_SOURCE_PROD') == '1';
      if (!allowSourceProd || !hasExplicitDataDir) {
        throw StateError(
          'Source build cannot run with production channel "blink" unless '
          'BLINK_ALLOW_SOURCE_PROD=1 and an isolated BLINK_DATA_DIR are set.',
        );
      }
    }

    // Only invoke the real Win32 Known Folder API when running against the real
    // process environment (`environment == null`) or when explicitly injected.
    final String? Function()? documentsQuery =
        resolveSystemDocumentsDir ??
        (environment == null && win ? queryKnownFolderDocuments : null);

    final systemDocumentsDir = _resolveSystemDocumentsDir(
      env: env,
      win: win,
      mac: mac,
      lin: lin,
      sep: sep,
      documentsQuery: documentsQuery,
    );

    final canonicalBase = _canonicalBasePath(
      win: win,
      currentDirectoryOverride: currentDirectoryOverride,
    );

    // Collect canonical forbidden roots for channel isolation guard (`INV-06`).
    final forbiddenRoots = _collectForbiddenRoots(
      buildInfo: buildInfo,
      env: env,
      win: win,
      mac: mac,
      lin: lin,
      sep: sep,
      systemDocumentsDir: systemDocumentsDir,
      envDocumentsOverride: rawDocumentsOverride,
      canonicalBase: canonicalBase,
    );

    final segment = buildInfo.pathSegment;

    // 1. Resolve `dataRoot` (App Local State).
    // Precedence: BLINK_DATA_DIR > source build `.local/blink-dev/app` >
    // installed OS app-local > temp fallback.
    late final Directory resolvedDataRoot;
    Directory? sourceSandboxRoot;
    if (hasExplicitDataDir) {
      resolvedDataRoot = Directory(rawDataOverride);
    } else if (buildInfo.isSourceBuild) {
      sourceSandboxRoot = _resolveSourceSandboxBase(
        sep: sep,
        fallbackTempPath: fallbackTempPath,
        repoRootOverride: repoRootOverride,
        currentDirectoryOverride: currentDirectoryOverride,
        executablePathOverride: executablePathOverride,
      );
      resolvedDataRoot = Directory(
        _joinPath(sourceSandboxRoot.path, 'app', sep),
      );
    } else {
      final osAppLocal = _resolveOsAppLocalRoot(
        segment: segment,
        env: env,
        win: win,
        mac: mac,
        lin: lin,
        sep: sep,
      );
      if (osAppLocal != null) {
        resolvedDataRoot = Directory(osAppLocal);
      } else {
        final base = fallbackTempPath ?? Directory.systemTemp.path;
        resolvedDataRoot = Directory(_joinPath(base, segment, sep));
      }
    }

    // 2. Resolve `defaultVaultDir` (User Data / Portable Vault).
    // Precedence (before `BLINK_VAULT_DIR` & `customVaultPath`):
    //   explicit BLINK_DATA_DIR -> `<dataRoot>/vault`
    //   source build -> `<sourceSandboxRoot>/vault`
    //   installed -> `<BLINK_DOCUMENTS_DIR or systemDocumentsDir>/<identity>`
    //   fallback -> `<dataRoot>/vault`
    late final Directory resolvedDefaultVaultDir;
    if (hasExplicitDataDir) {
      resolvedDefaultVaultDir = Directory(
        _joinPath(resolvedDataRoot.path, 'vault', sep),
      );
    } else if (buildInfo.isSourceBuild) {
      final sandbox =
          sourceSandboxRoot ??
          _resolveSourceSandboxBase(
            sep: sep,
            fallbackTempPath: fallbackTempPath,
            repoRootOverride: repoRootOverride,
            currentDirectoryOverride: currentDirectoryOverride,
            executablePathOverride: executablePathOverride,
          );
      resolvedDefaultVaultDir = Directory(
        _joinPath(sandbox.path, 'vault', sep),
      );
    } else {
      final docsBase = rawDocumentsOverride.isNotEmpty
          ? rawDocumentsOverride
          : systemDocumentsDir;
      if (docsBase != null && docsBase.isNotEmpty) {
        resolvedDefaultVaultDir = Directory(_joinPath(docsBase, segment, sep));
      } else {
        resolvedDefaultVaultDir = Directory(
          _joinPath(resolvedDataRoot.path, 'vault', sep),
        );
      }
    }

    final result = BlinkPaths._(
      resolvedDataRoot,
      resolvedDefaultVaultDir,
      vaultOverride,
      forbiddenRoots,
      win,
      canonicalBase,
    );

    // Enforce channel isolation guard on all resolved roots.
    result.assertAllowedPath(resolvedDataRoot.path, label: 'dataRoot');
    result.assertAllowedPath(
      resolvedDefaultVaultDir.path,
      label: 'defaultVaultDir',
    );
    if (vaultOverride != null) {
      result.assertAllowedPath(vaultOverride.path, label: 'BLINK_VAULT_DIR');
    }

    return result;
  }

  /// Root app-local state directory (`settings/`, `run/`, `webview2/`,
  /// `credentials/`, `logs/`, `cache/`).
  final Directory dataRoot;

  final Directory? _defaultVaultDir;

  /// Optional explicit vault directory override from `BLINK_VAULT_DIR`.
  final Directory? vaultDirOverride;

  final List<String> _forbiddenRoots;
  final bool? _isWindowsContext;
  final String? _canonicalBaseDir;

  /// Whether `BLINK_VAULT_DIR` explicitly overrides the default vault location.
  bool get hasVaultDirOverride => vaultDirOverride != null;

  /// Default single-folder portable vault directory when neither
  /// `BLINK_VAULT_DIR` nor `DesktopSettings.customVaultPath` is set.
  Directory get defaultVaultDir =>
      _defaultVaultDir ??
      Directory(_joinPath(dataRoot.path, 'vault', Platform.pathSeparator));

  /// Active single-folder portable vault directory (`BLINK_VAULT_DIR` override
  /// or [defaultVaultDir]).
  Directory get vaultDir => vaultDirOverride ?? defaultVaultDir;

  /// Resolves the effective vault directory honoring `BLINK_VAULT_DIR` first,
  /// then an optional user-configured [customVaultPath], else [defaultVaultDir].
  Directory resolveEffectiveVaultDir({String? customVaultPath}) {
    if (vaultDirOverride != null) {
      return vaultDirOverride!;
    }
    final custom = customVaultPath?.trim() ?? '';
    if (custom.isNotEmpty) {
      return Directory(custom);
    }
    return defaultVaultDir;
  }

  /// Returns `true` if [candidatePath] overlaps any protected channel root
  /// forbidden for the current build/identity (`INV-06`).
  bool isForbiddenTargetPath(String candidatePath) {
    if (_forbiddenRoots.isEmpty) {
      return false;
    }
    final win = _isWindowsContext ?? Platform.isWindows;
    final canonical = _canonicalizePath(
      candidatePath,
      isWindows: win,
      canonicalBase: _canonicalBaseDir,
    );
    for (final forbidden in _forbiddenRoots) {
      if (_pathsOverlap(canonical, forbidden)) {
        return true;
      }
    }
    return false;
  }

  /// Throws a [StateError] if [candidatePath] overlaps any protected channel
  /// root forbidden for the current build/identity (`INV-06`).
  void assertAllowedPath(String candidatePath, {String label = 'path'}) {
    if (_forbiddenRoots.isEmpty) {
      return;
    }
    final win = _isWindowsContext ?? Platform.isWindows;
    final canonical = _canonicalizePath(
      candidatePath,
      isWindows: win,
      canonicalBase: _canonicalBaseDir,
    );
    for (final forbidden in _forbiddenRoots) {
      if (_pathsOverlap(canonical, forbidden)) {
        throw StateError(
          'Channel isolation violation: $label ("$candidatePath") overlaps '
          'protected root "$forbidden".',
        );
      }
    }
  }

  /// Returns `true` when [path] appears to sit inside a OneDrive sync folder.
  static bool isOneDrivePath(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return _oneDriveSegmentRe.hasMatch(normalized);
  }

  static final RegExp _oneDriveSegmentRe = RegExp(
    r'(?:^|[\\/])onedrive(?:\s*-|[\\/]|$)',
    caseSensitive: false,
  );

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

  static Directory _resolveSourceSandboxBase({
    required String sep,
    required String? fallbackTempPath,
    required Directory? repoRootOverride,
    required Directory? currentDirectoryOverride,
    required String? executablePathOverride,
  }) {
    final repoRoot =
        repoRootOverride ??
        _discoverRepoRoot(
          currentDirectoryOverride: currentDirectoryOverride,
          executablePathOverride: executablePathOverride,
        );
    if (repoRoot != null) {
      return Directory(
        _joinPath(_joinPath(repoRoot.path, '.local', sep), 'blink-dev', sep),
      );
    }
    final tempBase = fallbackTempPath ?? Directory.systemTemp.path;
    return Directory(_joinPath(tempBase, 'blink-source-dev', sep));
  }

  static Directory? _discoverRepoRoot({
    required Directory? currentDirectoryOverride,
    required String? executablePathOverride,
  }) {
    final candidates = <Directory>[
      currentDirectoryOverride ?? Directory.current,
    ];
    if (executablePathOverride != null &&
        executablePathOverride.trim().isNotEmpty) {
      candidates.add(File(executablePathOverride.trim()).parent);
    } else if (currentDirectoryOverride == null) {
      final resolvedExe = Platform.resolvedExecutable.trim();
      if (resolvedExe.isNotEmpty) {
        candidates.add(File(resolvedExe).parent);
      }
    }

    for (final start in candidates) {
      final found = _walkUpForRepoRoot(start);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  static Directory? _walkUpForRepoRoot(Directory start) {
    var current = start.absolute;
    for (var depth = 0; depth < 32; depth++) {
      if (_isRepoRoot(current)) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    return null;
  }

  static bool _isRepoRoot(Directory dir) {
    final sep = Platform.pathSeparator;
    // `.git` may be a directory (clone) or a file (git worktree).
    final gitPath = _joinPath(dir.path, '.git', sep);
    if (FileSystemEntity.typeSync(gitPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return true;
    }
    // Fall back to workspace root `pubspec.yaml` (must declare `workspace:`).
    final pubspec = File(_joinPath(dir.path, 'pubspec.yaml', sep));
    if (pubspec.existsSync()) {
      try {
        final content = pubspec.readAsStringSync();
        if (_workspacePubspecRe.hasMatch(content)) {
          return true;
        }
      } catch (_) {
        // Unreadable pubspec cannot confirm workspace root.
      }
    }
    return false;
  }

  static final RegExp _workspacePubspecRe = RegExp(
    r'^workspace\s*:',
    multiLine: true,
  );

  static String? _resolveOsAppLocalRoot({
    required String segment,
    required Map<String, String> env,
    required bool win,
    required bool mac,
    required bool lin,
    required String sep,
  }) {
    if (win) {
      final localAppData = _readEnvCaseInsensitive(env, 'LOCALAPPDATA');
      if (localAppData.isNotEmpty) {
        return _joinPath(localAppData, segment, sep);
      }
      final userProfile = _readEnvCaseInsensitive(env, 'USERPROFILE');
      if (userProfile.isNotEmpty) {
        return _joinPath(
          _joinPath(_joinPath(userProfile, 'AppData', sep), 'Local', sep),
          segment,
          sep,
        );
      }
    } else if (mac) {
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return _joinPath(
          _joinPath(
            _joinPath(home, 'Library', sep),
            'Application Support',
            sep,
          ),
          segment,
          sep,
        );
      }
    } else if (lin) {
      final xdgData = env['XDG_DATA_HOME']?.trim() ?? '';
      if (xdgData.isNotEmpty) {
        return _joinPath(xdgData, segment, sep);
      }
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return _joinPath(
          _joinPath(_joinPath(home, '.local', sep), 'share', sep),
          segment,
          sep,
        );
      }
    }
    return null;
  }

  static String? _resolveSystemDocumentsDir({
    required Map<String, String> env,
    required bool win,
    required bool mac,
    required bool lin,
    required String sep,
    required String? Function()? documentsQuery,
  }) {
    final queried = documentsQuery?.call()?.trim() ?? '';
    if (queried.isNotEmpty) {
      return queried;
    }
    if (win) {
      final userProfile = _readEnvCaseInsensitive(env, 'USERPROFILE');
      if (userProfile.isNotEmpty) {
        return _joinPath(userProfile, 'Documents', sep);
      }
      return null;
    }
    if (mac) {
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return _joinPath(home, 'Documents', sep);
      }
      return null;
    }
    if (lin) {
      final xdgDocs = env['XDG_DOCUMENTS_DIR']?.trim() ?? '';
      if (xdgDocs.isNotEmpty) {
        return xdgDocs;
      }
      final home = env['HOME']?.trim() ?? '';
      if (home.isNotEmpty) {
        return _joinPath(home, 'Documents', sep);
      }
      return null;
    }
    return null;
  }

  static List<String> _collectForbiddenRoots({
    required BlinkBuildInfo buildInfo,
    required Map<String, String> env,
    required bool win,
    required bool mac,
    required bool lin,
    required String sep,
    required String? systemDocumentsDir,
    required String envDocumentsOverride,
    required String canonicalBase,
  }) {
    final isTestIdentity = buildInfo.identity.endsWith('-test');
    final isNonProd =
        buildInfo.isSourceBuild ||
        !buildInfo.isProductionChannel ||
        isTestIdentity;
    if (!isNonProd) {
      return const <String>[];
    }

    final guardedSegments = <String>['blink', if (isTestIdentity) 'blink-dev'];
    final collected = <String>{};

    void addCandidate(String? rawPath) {
      if (rawPath == null || rawPath.trim().isEmpty) {
        return;
      }
      collected.add(
        _canonicalizePath(
          rawPath,
          isWindows: win,
          canonicalBase: canonicalBase,
        ),
      );
    }

    for (final seg in guardedSegments) {
      addCandidate(
        _resolveOsAppLocalRoot(
          segment: seg,
          env: env,
          win: win,
          mac: mac,
          lin: lin,
          sep: sep,
        ),
      );
      if (systemDocumentsDir != null && systemDocumentsDir.isNotEmpty) {
        addCandidate(_joinPath(systemDocumentsDir, seg, sep));
      }
      if (envDocumentsOverride.isNotEmpty) {
        addCandidate(_joinPath(envDocumentsOverride, seg, sep));
      }
      if (win) {
        final userProfile = _readEnvCaseInsensitive(env, 'USERPROFILE');
        if (userProfile.isNotEmpty) {
          addCandidate(
            _joinPath(_joinPath(userProfile, 'Documents', sep), seg, sep),
          );
        }
      }
    }

    return collected.toList(growable: false);
  }

  static String _canonicalBasePath({
    required bool win,
    required Directory? currentDirectoryOverride,
  }) {
    if (win == Platform.isWindows) {
      return (currentDirectoryOverride ?? Directory.current).absolute.path;
    }
    return '/__blink_virtual_cwd__';
  }

  static String _canonicalizePath(
    String rawPath, {
    required bool isWindows,
    String? canonicalBase,
  }) {
    var path = rawPath.trim();
    if (isWindows && path.startsWith(r'\\?\')) {
      path = path.substring(4);
    }

    // Resolve symlinks / NTFS junctions on the deepest existing prefix when
    // targeting the live host OS.
    if (isWindows == Platform.isWindows && path.isNotEmpty) {
      path = _resolveDeepestExistingSymlink(path, isWindows: isWindows);
      if (isWindows && path.startsWith(r'\\?\')) {
        path = path.substring(4);
      }
    }

    var slashed = path.replaceAll(r'\', '/');
    if (!_isAbsolutePath(slashed, isWindows: isWindows) &&
        canonicalBase != null &&
        canonicalBase.isNotEmpty) {
      final baseSlashed = canonicalBase.replaceAll(r'\', '/');
      slashed = '$baseSlashed/$slashed';
    }

    String prefix = '';
    var rest = slashed;
    if (isWindows && _windowsDriveRe.hasMatch(rest)) {
      prefix = '${rest.substring(0, 2).toLowerCase()}/';
      rest = rest.substring(2);
    } else if (rest.startsWith('//')) {
      prefix = '//';
      rest = rest.substring(2);
    } else if (rest.startsWith('/')) {
      prefix = '/';
      rest = rest.substring(1);
    }

    final segments = <String>[];
    for (final rawSeg in rest.split('/')) {
      if (rawSeg.isEmpty || rawSeg == '.') {
        continue;
      }
      if (rawSeg == '..') {
        if (segments.isNotEmpty && segments.last != '..') {
          segments.removeLast();
        } else if (prefix.isEmpty) {
          segments.add('..');
        }
      } else {
        segments.add(rawSeg);
      }
    }

    var normalized = '$prefix${segments.join('/')}';
    if (normalized.length > 1 &&
        normalized.endsWith('/') &&
        !(isWindows && normalized.length == 3 && normalized[1] == ':')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return isWindows ? normalized.toLowerCase() : normalized;
  }

  static String _resolveDeepestExistingSymlink(
    String rawPath, {
    required bool isWindows,
  }) {
    final sep = isWindows ? r'\' : '/';
    // Only traverse disk symlinks for paths that exist or have an existing
    // absolute/explicit prefix on disk.
    final initialType = FileSystemEntity.typeSync(rawPath, followLinks: false);
    if (initialType != FileSystemEntityType.notFound) {
      try {
        return Directory(rawPath).resolveSymbolicLinksSync();
      } catch (_) {
        return rawPath;
      }
    }

    final isAbs = _isAbsolutePath(
      rawPath.replaceAll(r'\', '/'),
      isWindows: isWindows,
    );
    if (!isAbs) {
      return rawPath;
    }

    final pending = <String>[];
    var probe = Directory(rawPath);
    for (var i = 0; i < 64; i++) {
      final parent = probe.parent;
      if (parent.path == probe.path) {
        return rawPath;
      }
      final name = _basename(probe.path);
      if (name.isNotEmpty) {
        pending.add(name);
      }
      probe = parent;
      if (FileSystemEntity.typeSync(probe.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        try {
          var resolved = probe.resolveSymbolicLinksSync();
          for (final seg in pending.reversed) {
            resolved = _joinPath(resolved, seg, sep);
          }
          return resolved;
        } catch (_) {
          return rawPath;
        }
      }
    }
    return rawPath;
  }

  static String _basename(String path) {
    var trimmed = path;
    while (trimmed.length > 1 &&
        (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    final idxSlash = trimmed.lastIndexOf('/');
    final idxBackslash = trimmed.lastIndexOf(r'\');
    final idx = idxSlash > idxBackslash ? idxSlash : idxBackslash;
    if (idx < 0) {
      return trimmed;
    }
    return trimmed.substring(idx + 1);
  }

  static bool _isAbsolutePath(String slashedPath, {required bool isWindows}) {
    if (slashedPath.startsWith('/')) {
      return true;
    }
    return isWindows && _windowsDriveRe.hasMatch(slashedPath);
  }

  static final RegExp _windowsDriveRe = RegExp(r'^[A-Za-z]:[/\\]?');

  static bool _pathsOverlap(String candidate, String forbidden) {
    if (candidate == forbidden) {
      return true;
    }
    final candidatePrefix = candidate.endsWith('/') ? candidate : '$candidate/';
    final forbiddenPrefix = forbidden.endsWith('/') ? forbidden : '$forbidden/';
    return candidate.startsWith(forbiddenPrefix) ||
        forbidden.startsWith(candidatePrefix);
  }

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
