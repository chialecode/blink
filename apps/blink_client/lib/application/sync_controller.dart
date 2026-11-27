import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';

import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/secret_store.dart';

/// Default TCP port for the desktop embedded `DirectShelfServer`.
const int kDefaultDirectSyncPort = 48231;

/// Supported Channel B E2EE async relay protocols.
enum RelayProtocol {
  webdav('webdav', 'WebDAV'),
  s3('s3', 'S3 兼容');

  const RelayProtocol(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static RelayProtocol? tryParse(Object? value) {
    if (value is! String) {
      return null;
    }
    for (final item in RelayProtocol.values) {
      if (item.wireValue == value) {
        return item;
      }
    }
    return null;
  }
}

/// Honest top-level sync state surfaced by [BlinkSyncController] (`INV-11`,
/// `docs/ui.md` §4.5).
enum BlinkSyncUiStatus {
  unconfigured,
  idleSynced,
  offlinePending,
  peerAsleep,
  syncing,
  conflictPending,
  deviceRevoked,
  channelMismatch,
  privacyBlocked,
  error,
}

/// Non-secret sync configuration persisted atomically to
/// `<dataRoot>/settings/sync.json` (`INV-07`, `INV-08`).
///
/// Zero tokens, master keys, passwords, or S3 secrets may ever appear here.
@immutable
class SyncClientConfig {
  const SyncClientConfig({
    this.autoSyncEnabled = true,
    this.desktopServerEnabled = false,
    this.desktopServerBindHost = '0.0.0.0',
    this.desktopServerPort = kDefaultDirectSyncPort,
    this.directEnabled = false,
    this.directPeerUrl,
    this.directPeerDeviceId,
    this.directPeerDeviceName,
    this.directPeerVaultId,
    this.relayEnabled = false,
    this.relayProtocol = RelayProtocol.webdav,
    this.relayEndpoint,
    this.relayUsername,
    this.relayBucket,
    this.relayRegion = 'us-east-1',
    this.relayKeyPrefix = 'blink',
    this.relayUsePathStyle = true,
    this.excludePrivateFromRelay = true,
  });

  final bool autoSyncEnabled;
  final bool desktopServerEnabled;
  final String desktopServerBindHost;
  final int desktopServerPort;
  final bool directEnabled;
  final String? directPeerUrl;
  final String? directPeerDeviceId;
  final String? directPeerDeviceName;
  final String? directPeerVaultId;
  final bool relayEnabled;
  final RelayProtocol relayProtocol;
  final String? relayEndpoint;
  final String? relayUsername;
  final String? relayBucket;
  final String relayRegion;
  final String relayKeyPrefix;
  final bool relayUsePathStyle;

  /// Physical `#private` cloud-relay exclusion toggle (defaults to `true`,
  /// `INV-03`, `AC-05`).
  final bool excludePrivateFromRelay;

  SyncClientConfig copyWith({
    bool? autoSyncEnabled,
    bool? desktopServerEnabled,
    String? desktopServerBindHost,
    int? desktopServerPort,
    bool? directEnabled,
    String? directPeerUrl,
    bool clearDirectPeer = false,
    String? directPeerDeviceId,
    String? directPeerDeviceName,
    String? directPeerVaultId,
    bool? relayEnabled,
    RelayProtocol? relayProtocol,
    String? relayEndpoint,
    bool clearRelayEndpoint = false,
    String? relayUsername,
    bool clearRelayUsername = false,
    String? relayBucket,
    bool clearRelayBucket = false,
    String? relayRegion,
    String? relayKeyPrefix,
    bool? relayUsePathStyle,
    bool? excludePrivateFromRelay,
  }) {
    return SyncClientConfig(
      autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
      desktopServerEnabled: desktopServerEnabled ?? this.desktopServerEnabled,
      desktopServerBindHost:
          desktopServerBindHost ?? this.desktopServerBindHost,
      desktopServerPort: desktopServerPort ?? this.desktopServerPort,
      directEnabled: directEnabled ?? this.directEnabled,
      directPeerUrl: clearDirectPeer
          ? null
          : (directPeerUrl ?? this.directPeerUrl),
      directPeerDeviceId: clearDirectPeer
          ? null
          : (directPeerDeviceId ?? this.directPeerDeviceId),
      directPeerDeviceName: clearDirectPeer
          ? null
          : (directPeerDeviceName ?? this.directPeerDeviceName),
      directPeerVaultId: clearDirectPeer
          ? null
          : (directPeerVaultId ?? this.directPeerVaultId),
      relayEnabled: relayEnabled ?? this.relayEnabled,
      relayProtocol: relayProtocol ?? this.relayProtocol,
      relayEndpoint: clearRelayEndpoint
          ? null
          : (relayEndpoint ?? this.relayEndpoint),
      relayUsername: clearRelayUsername
          ? null
          : (relayUsername ?? this.relayUsername),
      relayBucket: clearRelayBucket ? null : (relayBucket ?? this.relayBucket),
      relayRegion: relayRegion ?? this.relayRegion,
      relayKeyPrefix: relayKeyPrefix ?? this.relayKeyPrefix,
      relayUsePathStyle: relayUsePathStyle ?? this.relayUsePathStyle,
      excludePrivateFromRelay:
          excludePrivateFromRelay ?? this.excludePrivateFromRelay,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'autoSyncEnabled': autoSyncEnabled,
    'desktopServerEnabled': desktopServerEnabled,
    'desktopServerBindHost': desktopServerBindHost,
    'desktopServerPort': desktopServerPort,
    'directEnabled': directEnabled,
    if (directPeerUrl != null && directPeerUrl!.trim().isNotEmpty)
      'directPeerUrl': directPeerUrl!.trim(),
    if (directPeerDeviceId != null && directPeerDeviceId!.trim().isNotEmpty)
      'directPeerDeviceId': directPeerDeviceId!.trim(),
    if (directPeerDeviceName != null && directPeerDeviceName!.trim().isNotEmpty)
      'directPeerDeviceName': directPeerDeviceName!.trim(),
    if (directPeerVaultId != null && directPeerVaultId!.trim().isNotEmpty)
      'directPeerVaultId': directPeerVaultId!.trim(),
    'relayEnabled': relayEnabled,
    'relayProtocol': relayProtocol.wireValue,
    if (relayEndpoint != null && relayEndpoint!.trim().isNotEmpty)
      'relayEndpoint': relayEndpoint!.trim(),
    if (relayUsername != null && relayUsername!.trim().isNotEmpty)
      'relayUsername': relayUsername!.trim(),
    if (relayBucket != null && relayBucket!.trim().isNotEmpty)
      'relayBucket': relayBucket!.trim(),
    'relayRegion': relayRegion,
    'relayKeyPrefix': relayKeyPrefix,
    'relayUsePathStyle': relayUsePathStyle,
    'excludePrivateFromRelay': excludePrivateFromRelay,
  };

  /// Strictly parses [json]; returns `null` if any known field has an invalid
  /// type or out-of-range value so corrupt files are preserved (`INV-07`).
  static SyncClientConfig? tryFromJson(Map<String, Object?> json) {
    bool readBool(String key, bool fallback) {
      if (!json.containsKey(key) || json[key] == null) {
        return fallback;
      }
      final raw = json[key];
      if (raw is! bool) {
        throw const FormatException('Expected bool');
      }
      return raw;
    }

    String? readOptionalString(String key) {
      if (!json.containsKey(key) || json[key] == null) {
        return null;
      }
      final raw = json[key];
      if (raw is! String) {
        throw const FormatException('Expected String');
      }
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    try {
      final autoSync = readBool('autoSyncEnabled', true);
      final serverEnabled = readBool('desktopServerEnabled', false);
      final bindHost = readOptionalString('desktopServerBindHost') ?? '0.0.0.0';

      var serverPort = kDefaultDirectSyncPort;
      if (json.containsKey('desktopServerPort') &&
          json['desktopServerPort'] != null) {
        final rawPort = json['desktopServerPort'];
        if (rawPort is! int || rawPort < 0 || rawPort > 65535) {
          return null;
        }
        serverPort = rawPort;
      }

      final directEnabled = readBool('directEnabled', false);
      final relayEnabled = readBool('relayEnabled', false);

      var protocol = RelayProtocol.webdav;
      if (json.containsKey('relayProtocol') && json['relayProtocol'] != null) {
        final parsed = RelayProtocol.tryParse(json['relayProtocol']);
        if (parsed == null) {
          return null;
        }
        protocol = parsed;
      }

      return SyncClientConfig(
        autoSyncEnabled: autoSync,
        desktopServerEnabled: serverEnabled,
        desktopServerBindHost: bindHost,
        desktopServerPort: serverPort,
        directEnabled: directEnabled,
        directPeerUrl: readOptionalString('directPeerUrl'),
        directPeerDeviceId: readOptionalString('directPeerDeviceId'),
        directPeerDeviceName: readOptionalString('directPeerDeviceName'),
        directPeerVaultId: readOptionalString('directPeerVaultId'),
        relayEnabled: relayEnabled,
        relayProtocol: protocol,
        relayEndpoint: readOptionalString('relayEndpoint'),
        relayUsername: readOptionalString('relayUsername'),
        relayBucket: readOptionalString('relayBucket'),
        relayRegion: readOptionalString('relayRegion') ?? 'us-east-1',
        relayKeyPrefix: readOptionalString('relayKeyPrefix') ?? 'blink',
        relayUsePathStyle: readBool('relayUsePathStyle', true),
        excludePrivateFromRelay: readBool('excludePrivateFromRelay', true),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncClientConfig &&
          autoSyncEnabled == other.autoSyncEnabled &&
          desktopServerEnabled == other.desktopServerEnabled &&
          desktopServerBindHost == other.desktopServerBindHost &&
          desktopServerPort == other.desktopServerPort &&
          directEnabled == other.directEnabled &&
          directPeerUrl == other.directPeerUrl &&
          directPeerDeviceId == other.directPeerDeviceId &&
          directPeerDeviceName == other.directPeerDeviceName &&
          directPeerVaultId == other.directPeerVaultId &&
          relayEnabled == other.relayEnabled &&
          relayProtocol == other.relayProtocol &&
          relayEndpoint == other.relayEndpoint &&
          relayUsername == other.relayUsername &&
          relayBucket == other.relayBucket &&
          relayRegion == other.relayRegion &&
          relayKeyPrefix == other.relayKeyPrefix &&
          relayUsePathStyle == other.relayUsePathStyle &&
          excludePrivateFromRelay == other.excludePrivateFromRelay;

  @override
  int get hashCode => Object.hash(
    autoSyncEnabled,
    desktopServerEnabled,
    desktopServerBindHost,
    desktopServerPort,
    directEnabled,
    directPeerUrl,
    directPeerDeviceId,
    directPeerDeviceName,
    directPeerVaultId,
    relayEnabled,
    relayProtocol,
    relayEndpoint,
    relayUsername,
    relayBucket,
    relayRegion,
    relayKeyPrefix,
    relayUsePathStyle,
    excludePrivateFromRelay,
  );
}

/// Outcome of loading `<dataRoot>/settings/sync.json`.
class SyncSettingsLoadResult {
  const SyncSettingsLoadResult({
    required this.config,
    required this.recoveredFromCorrupt,
    this.preservedCorruptFile,
  });

  final SyncClientConfig config;
  final bool recoveredFromCorrupt;
  final File? preservedCorruptFile;
}

/// Atomic persistence store for non-secret `<dataRoot>/settings/sync.json`
/// with corrupt-file preservation (`INV-07`).
class SyncSettingsStore {
  SyncSettingsStore({required this.file, DateTime Function()? nowUtc})
    : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final File file;
  final DateTime Function() _nowUtc;

  SyncSettingsLoadResult loadSync() {
    final jsonResult = readJsonObjectOrDefaultSync(file, nowUtc: _nowUtc);
    if (jsonResult.wasCorrupt) {
      return SyncSettingsLoadResult(
        config: const SyncClientConfig(),
        recoveredFromCorrupt: true,
        preservedCorruptFile: jsonResult.preservedCorruptFile,
      );
    }
    if (!jsonResult.exists) {
      return const SyncSettingsLoadResult(
        config: SyncClientConfig(),
        recoveredFromCorrupt: false,
      );
    }
    final parsed = SyncClientConfig.tryFromJson(jsonResult.data);
    if (parsed == null) {
      final preserved = file.existsSync()
          ? preserveCorruptFileSync(file, nowUtc: _nowUtc)
          : null;
      return SyncSettingsLoadResult(
        config: const SyncClientConfig(),
        recoveredFromCorrupt: true,
        preservedCorruptFile: preserved,
      );
    }
    return SyncSettingsLoadResult(config: parsed, recoveredFromCorrupt: false);
  }

  void saveSync(SyncClientConfig config) {
    const encoder = JsonEncoder.withIndent('  ');
    final payload = '${encoder.convert(config.toJson())}\n';
    writeStringAtomicallySync(file, payload);
  }
}

/// In-memory bundle of relay credentials loaded on demand from [BlinkSecretStore].
@immutable
class RelaySecrets {
  const RelaySecrets({
    this.masterKey,
    this.webdavPassword,
    this.webdavBearerToken,
    this.s3AccessKeyId,
    this.s3SecretAccessKey,
    this.s3SessionToken,
  });

  final SyncMasterKey? masterKey;
  final String? webdavPassword;
  final String? webdavBearerToken;
  final String? s3AccessKeyId;
  final String? s3SecretAccessKey;
  final String? s3SessionToken;
}

typedef RelayStoreFactory = RelayObjectStore Function(
  SyncClientConfig config,
  RelaySecrets secrets,
);

/// Client-side M4 sync orchestrator (`INV-01`..`INV-11`, `DEC-032`).
///
/// Manages:
/// - OS-native secret storage via [BlinkSecretStore] (zero secrets in vault)
/// - Desktop embedded `DirectShelfServer` + `LanDiscovery` (`mdns_dart`)
/// - Auto & manual bidirectional sync over Channel A (Direct LAN/Tailscale)
///   and Channel B (E2EE WebDAV/S3 async relay with `#private` exclusion ON)
/// - Real-time SSE wakeup, debounced post-write sync, and app-resume sync
/// - Honest [BlinkSyncUiStatus] reporting and dual-copy conflict resolution
class BlinkSyncController extends ChangeNotifier {
  BlinkSyncController({
    required this.paths,
    required this.expectedChannel,
    BlinkSecretStore? secretStore,
    SyncSettingsStore? settingsStore,
    LanDiscovery? lanDiscovery,
    AndroidPlatformBridge androidBridge = const AndroidPlatformBridge(),
    RelayStoreFactory? relayStoreFactory,
    this.isQuiet = false,
    bool? isMobilePlatform,
    this.enableSseWakeup = true,
    this.writeDebounce = const Duration(milliseconds: 1200),
    this.sseReconnectBaseDelay = const Duration(seconds: 2),
    this.directRequestTimeout = const Duration(seconds: 10),
    this.onVaultDataChanged,
  }) : secretStore =
           secretStore ??
           createDefaultBlinkSecretStore(
             paths: paths,
             channel: expectedChannel,
             quietOverride: isQuiet,
             androidBridge: androidBridge,
           ),
       settingsStore =
           settingsStore ?? SyncSettingsStore(file: paths.syncSettingsFile),
       _lanDiscovery = lanDiscovery ?? LanDiscovery(enabled: !isQuiet),
       _androidBridge = androidBridge,
       _relayStoreFactory = relayStoreFactory ?? _defaultRelayStoreFactory,
       isMobile = isMobilePlatform ?? (Platform.isAndroid || Platform.isIOS);

  final BlinkPaths paths;
  final BlinkChannel expectedChannel;
  final BlinkSecretStore secretStore;
  final SyncSettingsStore settingsStore;
  final LanDiscovery _lanDiscovery;
  final AndroidPlatformBridge _androidBridge;
  final RelayStoreFactory _relayStoreFactory;
  final bool isQuiet;
  final bool isMobile;
  final bool enableSseWakeup;
  final Duration writeDebounce;
  final Duration sseReconnectBaseDelay;
  final Duration directRequestTimeout;
  final VoidCallback? onVaultDataChanged;

  final SyncCrypto _crypto = SyncCrypto();

  VaultManager? _vault;
  DirectShelfServer? _server;
  bool _initialized = false;
  bool _isStopping = false;
  bool _isDisposed = false;

  SyncClientConfig _config = const SyncClientConfig();
  bool _recoveredCorruptSyncSettings = false;

  BlinkSyncUiStatus _uiStatus = BlinkSyncUiStatus.unconfigured;
  int _pendingOutboxCount = 0;
  int _openConflictCount = 0;
  int _lastObservedSeqId = 0;
  int _lastObservedRemoteSeq = 0;
  DateTime? _lastSyncedAtUtc;
  List<SyncConflict> _openConflicts = const <SyncConflict>[];
  List<SyncDeviceRecord> _pairedDevices = const <SyncDeviceRecord>[];
  List<DiscoveredLanPeer> _discoveredPeers = const <DiscoveredLanPeer>[];
  List<String> _localHostAddresses = const <String>[];
  PairingCodeInfo? _activePairingCode;

  bool _isSyncing = false;
  bool _isDiscoveringPeers = false;
  bool _hasDirectDeviceToken = false;
  bool _hasRelayMasterKey = false;
  String? _relayMasterKeyId;
  bool _hasWebDavCredentials = false;
  bool _hasS3Credentials = false;
  String? _activeChannelLabel;
  BlinkErrorCode? _lastErrorCode;
  String? _lastErrorMessage;
  int _lastSkippedPrivateCount = 0;
  SyncRunResult? _lastRunResult;

  Future<SyncRunResult?>? _syncInFlight;
  Future<SyncRunResult?>? _followUpSyncFuture;
  bool _followUpManual = false;
  Timer? _writeDebounceTimer;
  Timer? _sseReconnectTimer;
  int _sseReconnectAttempt = 0;
  int _sseGeneration = 0;
  StreamSubscription<int>? _sseSub;
  DirectShelfTransport? _sseTransport;
  StreamSubscription<SyncStatusSnapshot>? _statusSub;
  StreamSubscription<List<SyncConflict>>? _conflictsSub;

  SyncClientConfig get config => _config;
  bool get recoveredCorruptSyncSettings => _recoveredCorruptSyncSettings;
  BlinkSyncUiStatus get uiStatus => _uiStatus;
  int get pendingOutboxCount => _pendingOutboxCount;
  int get openConflictCount => _openConflictCount;
  List<SyncConflict> get openConflicts => _openConflicts;
  DateTime? get lastSyncedAtUtc => _lastSyncedAtUtc;
  bool get isSyncing => _isSyncing;
  bool get isHostRunning => _server?.isRunning ?? false;
  bool get isLanAdvertising => _lanDiscovery.isAdvertising;
  bool get isDiscoveringPeers => _isDiscoveringPeers;
  String? get activeChannelLabel => _activeChannelLabel;
  BlinkErrorCode? get lastErrorCode => _lastErrorCode;
  String? get lastErrorMessage => _lastErrorMessage;
  int get lastSkippedPrivateCount => _lastSkippedPrivateCount;
  SyncRunResult? get lastRunResult => _lastRunResult;
  List<SyncDeviceRecord> get pairedDevices => _pairedDevices;
  List<DiscoveredLanPeer> get discoveredPeers => _discoveredPeers;
  List<String> get localHostAddresses => _localHostAddresses;
  int? get activeServerPort =>
      _server?.isRunning == true ? _server!.port : null;
  Uri? get activeServerBaseUri =>
      _server?.isRunning == true ? _server!.baseUri : null;
  bool get hasDirectDeviceToken => _hasDirectDeviceToken;
  bool get hasRelayMasterKey => _hasRelayMasterKey;
  String? get relayMasterKeyId => _relayMasterKeyId;
  bool get hasWebDavCredentials => _hasWebDavCredentials;
  bool get hasS3Credentials => _hasS3Credentials;
  bool get hasRelayCredentials => _hasWebDavCredentials || _hasS3Credentials;

  PairingCodeInfo? get activePairingCode {
    final code = _activePairingCode;
    if (code == null || code.isExpiredAt(DateTime.now().toUtc())) {
      return null;
    }
    return code;
  }

  bool get isDirectConfigured =>
      _config.directEnabled &&
      (_config.directPeerUrl?.trim().isNotEmpty ?? false) &&
      _hasDirectDeviceToken;

  bool get isRelayConfigured =>
      _config.relayEnabled &&
      (_config.relayEndpoint?.trim().isNotEmpty ?? false) &&
      _hasRelayMasterKey;

  bool get isConfigured => isDirectConfigured || isRelayConfigured;

  /// Loads persisted non-secret config (`sync.json`) and checks secret-store
  /// key presence without touching `<BLINK_VAULT_DIR>` (`INV-08`).
  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    final loaded = settingsStore.loadSync();
    _config = loaded.config;
    _recoveredCorruptSyncSettings = loaded.recoveredFromCorrupt;
    await _refreshSecretMetadata();
    _recomputeBaselineStatus();
    _safeNotify();
  }

  /// Binds an open [VaultManager], starts desktop host if enabled, connects
  /// SSE wakeup if paired, and runs non-blocking startup auto-sync (`INV-04`).
  Future<void> attachVault(VaultManager? vault) async {
    if (!_initialized) {
      await initialize();
    }
    await _detachCurrentVault();
    _isStopping = false;
    _vault = vault;
    if (vault == null || !vault.isOpen) {
      _pendingOutboxCount = 0;
      _openConflictCount = 0;
      _openConflicts = const <SyncConflict>[];
      _pairedDevices = const <SyncDeviceRecord>[];
      _recomputeBaselineStatus();
      _safeNotify();
      return;
    }

    final initialSnapshot = vault.syncEngine.getSyncStatus();
    _pendingOutboxCount = initialSnapshot.pendingOutboxCount;
    _openConflictCount = initialSnapshot.openConflictCount;
    _lastObservedSeqId = initialSnapshot.latestSeqId;
    _lastSyncedAtUtc = initialSnapshot.lastSyncedAtUtc;
    _openConflicts = await vault.syncEngine.listOpenConflicts();
    _pairedDevices = await vault.syncEngine.listDevices();

    _statusSub = vault.watchSyncStatus().listen(
      _handleVaultStatusSnapshot,
      onError: (_) {},
    );
    _conflictsSub = vault.watchOpenConflicts().listen((conflicts) {
      _openConflicts = conflicts;
      _openConflictCount = conflicts.length;
      if (!_isSyncing &&
          _openConflictCount > 0 &&
          _uiStatus != BlinkSyncUiStatus.deviceRevoked &&
          _uiStatus != BlinkSyncUiStatus.channelMismatch) {
        _uiStatus = BlinkSyncUiStatus.conflictPending;
      } else if (!_isSyncing &&
          _openConflictCount == 0 &&
          _uiStatus == BlinkSyncUiStatus.conflictPending) {
        _recomputeBaselineStatus();
      }
      _safeNotify();
    }, onError: (_) {});

    if (!isMobile && _config.desktopServerEnabled) {
      await _startDesktopHostInternal();
    }

    _recomputeBaselineStatus();
    _safeNotify();

    if (isDirectConfigured) {
      _startSseWakeupLoop();
    }
    if (_config.autoSyncEnabled && isConfigured) {
      unawaited(syncNow(manual: false));
    }
  }

  /// Triggered on `AppLifecycleState.resumed` (mobile & desktop foregrounding).
  void onAppResumed() {
    if (_isDisposed || _isStopping || _vault == null || !_vault!.isOpen) {
      return;
    }
    if (isDirectConfigured && _sseSub == null) {
      _sseReconnectAttempt = 0;
      _startSseWakeupLoop();
    }
    if (_config.autoSyncEnabled &&
        isConfigured &&
        _uiStatus != BlinkSyncUiStatus.deviceRevoked) {
      unawaited(syncNow(manual: false));
    }
  }

  /// Stops timers, subscriptions, SSE, in-flight syncs, LAN advertising, and
  /// embedded desktop HTTP server cleanly BEFORE mirror flush and SQLite WAL
  /// checkpoint (`INV-07`).
  Future<void> stopForShutdown() async {
    _isStopping = true;
    _writeDebounceTimer?.cancel();
    _writeDebounceTimer = null;
    await _cancelVaultSubscriptions();
    await _stopSseWakeupLoop();
    final inFlight = _syncInFlight;
    if (inFlight != null) {
      try {
        await inFlight.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    final followUp = _followUpSyncFuture;
    if (followUp != null) {
      try {
        await followUp.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await _stopDesktopHostInternal();
    if (Platform.isAndroid && !isQuiet) {
      await _androidBridge.releaseMulticastLock();
    }
  }

  /// Enables or disables the desktop embedded `DirectShelfServer` + mDNS
  /// advertising (`mdns_dart`, suppressed in `BLINK_QUIET=1`).
  Future<bool> setDesktopServerEnabled(
    bool enabled, {
    String? bindHost,
    int? port,
  }) async {
    if (isMobile && enabled) {
      _setError(
        BlinkErrorCode.invalidArgument,
        '移动端不支持开启桌面直连服务端，请作为同步客户端配对桌面端或启用 E2EE 中继。',
      );
      return false;
    }

    final nextHost = (bindHost != null && bindHost.trim().isNotEmpty)
        ? bindHost.trim()
        : _config.desktopServerBindHost;
    final nextPort = port ?? _config.desktopServerPort;
    if (nextPort < 0 || nextPort > 65535) {
      _setError(BlinkErrorCode.invalidArgument, '端口号必须在 0～65535 之间。');
      return false;
    }

    final configChanged =
        _config.desktopServerEnabled != enabled ||
        _config.desktopServerBindHost != nextHost ||
        _config.desktopServerPort != nextPort;
    _config = _config.copyWith(
      desktopServerEnabled: enabled,
      desktopServerBindHost: nextHost,
      desktopServerPort: nextPort,
    );
    if (configChanged) {
      settingsStore.saveSync(_config);
    }

    if (!enabled) {
      await _stopDesktopHostInternal();
      if (_uiStatus == BlinkSyncUiStatus.error) {
        _lastErrorCode = null;
        _lastErrorMessage = null;
        _recomputeBaselineStatus();
      }
      _safeNotify();
      return true;
    }

    await _stopDesktopHostInternal();
    final started = await _startDesktopHostInternal();
    if (!started) {
      _config = _config.copyWith(desktopServerEnabled: false);
      settingsStore.saveSync(_config);
    }
    _safeNotify();
    return started;
  }

  /// Generates a short-lived single-use pairing code in memory ONLY (`INV-08`).
  PairingCodeInfo? generatePairingCode({
    Duration ttl = const Duration(minutes: 5),
  }) {
    final server = _server;
    if (server == null || !server.isRunning) {
      return null;
    }
    _activePairingCode = server.createPairingCode(ttl: ttl);
    _safeNotify();
    return _activePairingCode;
  }

  /// Reloads paired device metadata from `sync_devices` (zero secret tokens).
  Future<void> refreshPairedDevices() async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return;
    }
    _pairedDevices = await vault.syncEngine.listDevices();
    _safeNotify();
  }

  /// Revokes a paired peer device immediately and closes its active SSE stream.
  Future<bool> revokePairedDevice(String deviceId) async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return false;
    }
    final bool revoked;
    if (_server != null && _server!.isRunning) {
      revoked = await _server!.revokeDevice(deviceId);
    } else {
      revoked = await vault.syncEngine.revokeDevice(deviceId);
    }
    await refreshPairedDevices();
    return revoked;
  }

  /// Refreshes local LAN & Tailscale (`100.64.0.0/10`) IPv4 addresses for
  /// display in Desktop Sync Host settings.
  Future<void> refreshLocalHostAddresses() async {
    final collected = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address.trim();
          if (ip.isNotEmpty && !collected.contains(ip)) {
            collected.add(ip);
          }
        }
      }
    } catch (_) {
      // Sandboxed/offline environments may forbid listing network interfaces.
    }
    if (!collected.contains('127.0.0.1')) {
      collected.add('127.0.0.1');
    }
    _localHostAddresses = List<String>.unmodifiable(collected);
    _safeNotify();
  }

  /// Toggles automatic background sync triggers.
  Future<void> setAutoSyncEnabled(bool enabled) async {
    if (_config.autoSyncEnabled == enabled) {
      return;
    }
    _config = _config.copyWith(autoSyncEnabled: enabled);
    settingsStore.saveSync(_config);
    if (!enabled) {
      _writeDebounceTimer?.cancel();
      _writeDebounceTimer = null;
      await _stopSseWakeupLoop();
    } else if (isConfigured && _vault != null && _vault!.isOpen) {
      if (isDirectConfigured && _sseSub == null) {
        _startSseWakeupLoop();
      }
      unawaited(syncNow(manual: false));
    }
    _safeNotify();
  }

  /// Browses LAN peers over `_blink-sync._tcp` (`mdns_dart`).
  ///
  /// On Android, acquires `WifiManager.MulticastLock` strictly for the
  /// duration of the scan and releases it in `finally`.
  Future<List<DiscoveredLanPeer>> discoverLanPeers({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (_isDiscoveringPeers) {
      return _discoveredPeers;
    }
    _isDiscoveringPeers = true;
    _safeNotify();

    var acquiredMulticast = false;
    try {
      if (Platform.isAndroid && !isQuiet) {
        acquiredMulticast = await _androidBridge.acquireMulticastLock();
      }
      final peers = await _lanDiscovery.discover(
        expectedChannel: expectedChannel,
        timeout: timeout,
      );
      final localId = _vault?.localDeviceId;
      final filtered = peers
          .where((peer) => localId == null || peer.deviceId != localId)
          .toList(growable: false);
      _discoveredPeers = filtered;

      // Auto-sync trigger on LAN peer discovery if a paired peer is found.
      if (isDirectConfigured) {
        for (final peer in filtered) {
          final matchesDevice =
              _config.directPeerDeviceId != null &&
              peer.deviceId == _config.directPeerDeviceId;
          final matchesVault =
              _config.directPeerVaultId != null &&
              peer.vaultId == _config.directPeerVaultId;
          if (matchesDevice || matchesVault) {
            final discoveredUrl = peer.baseUri.toString();
            if (_config.directPeerUrl != discoveredUrl) {
              _config = _config.copyWith(
                directPeerUrl: discoveredUrl,
                directPeerDeviceName: peer.deviceName,
              );
              settingsStore.saveSync(_config);
              _startSseWakeupLoop();
            }
            if (_config.autoSyncEnabled &&
                _uiStatus != BlinkSyncUiStatus.deviceRevoked) {
              unawaited(syncNow(manual: false));
            }
            break;
          }
        }
      }
      return filtered;
    } catch (_) {
      return _discoveredPeers;
    } finally {
      if (acquiredMulticast) {
        await _androidBridge.releaseMulticastLock();
      }
      _isDiscoveringPeers = false;
      _safeNotify();
    }
  }

  /// Pairs with a desktop `DirectShelfServer` or headless `blink sync serve`
  /// using a one-time pairing code, stores the issued bearer token ONLY in
  /// [BlinkSecretStore] (`INV-08`), and runs an initial bidirectional sync.
  Future<PairingResult?> pairWithDirectPeer({
    required String baseUrl,
    required String pairingCode,
    String? deviceName,
  }) async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      _setError(BlinkErrorCode.ioError, '便携库尚未就绪，无法配对同步节点。');
      return null;
    }
    if (_hasUriUserInfo(baseUrl)) {
      _setError(
        BlinkErrorCode.invalidArgument,
        '同步节点地址禁止在 URL 中内嵌用户名或密码，请仅填写主机地址与端口（INV-08）。',
      );
      return null;
    }
    final normalizedUri = _parseSyncUri(baseUrl);
    if (normalizedUri == null) {
      _setError(
        BlinkErrorCode.invalidArgument,
        '同步节点地址格式无效，请输入如 http://192.168.1.10:48231 或 Tailscale 地址。',
      );
      return null;
    }
    final cleanCode = pairingCode.trim();
    if (cleanCode.isEmpty) {
      _setError(BlinkErrorCode.invalidArgument, '请输入桌面端生成的一次性配对码。');
      return null;
    }

    final transport = DirectShelfTransport(
      baseUri: normalizedUri,
      expectedChannel: expectedChannel,
      requestTimeout: directRequestTimeout,
    );
    try {
      final health = await transport.checkHealth();
      final result = await transport.pair(
        pairingCode: cleanCode,
        deviceId: vault.localDeviceId,
        deviceName: (deviceName != null && deviceName.trim().isNotEmpty)
            ? deviceName.trim()
            : vault.localDeviceName,
      );
      if (result.channel != expectedChannel) {
        _applyBlinkException(
          BlinkException(
            code: BlinkErrorCode.channelMismatch,
            message:
                '对端通道为 ${result.channel.wireValue}，与当前通道 ${expectedChannel.wireValue} 不匹配。',
          ),
        );
        return null;
      }

      // Persist bearer token strictly in OS SecretStore (`INV-08`).
      await secretStore.write(
        BlinkSecretKeys.directDeviceToken,
        result.deviceToken,
      );
      _hasDirectDeviceToken = true;

      _config = _config.copyWith(
        directEnabled: true,
        directPeerUrl: normalizedUri.toString(),
        directPeerDeviceId: health.deviceId,
        directPeerDeviceName: health.deviceName.isNotEmpty
            ? health.deviceName
            : normalizedUri.host,
        directPeerVaultId: result.vaultId,
      );
      settingsStore.saveSync(_config);
      _lastErrorCode = null;
      _lastErrorMessage = null;
      _lastObservedRemoteSeq = health.latestSeqId;
      _safeNotify();

      await syncNow(manual: true);
      if (!_isDisposed && _uiStatus != BlinkSyncUiStatus.deviceRevoked) {
        _startSseWakeupLoop();
      }
      return result;
    } on BlinkException catch (error) {
      _applyBlinkException(error);
      return null;
    } on BlinkSecretStoreException catch (error) {
      _setError(BlinkErrorCode.ioError, '无法将设备令牌安全写入系统密钥库（${error.code}）。');
      return null;
    } catch (_) {
      _setError(BlinkErrorCode.ioError, '与同步节点配对失败，请检查地址、配对码与网络连接。');
      return null;
    } finally {
      transport.close();
    }
  }

  /// Removes paired direct peer config and deletes its bearer token from
  /// [BlinkSecretStore].
  Future<void> disconnectDirectPeer() async {
    await _stopSseWakeupLoop();
    try {
      await secretStore.delete(BlinkSecretKeys.directDeviceToken);
    } catch (_) {}
    _hasDirectDeviceToken = false;
    _config = _config.copyWith(directEnabled: false, clearDirectPeer: true);
    settingsStore.saveSync(_config);
    _lastErrorCode = null;
    _lastErrorMessage = null;
    _recomputeBaselineStatus();
    _safeNotify();
  }

  /// Toggles E2EE async relay on/off.
  Future<void> setRelayEnabled(bool enabled) async {
    if (_config.relayEnabled == enabled) {
      return;
    }
    _config = _config.copyWith(relayEnabled: enabled);
    settingsStore.saveSync(_config);
    _recomputeBaselineStatus();
    _safeNotify();
  }

  /// Toggles the `#private` cloud-relay exclusion guard (`INV-03`, defaults ON).
  Future<void> setExcludePrivateFromRelay(bool exclude) async {
    if (_config.excludePrivateFromRelay == exclude) {
      return;
    }
    _config = _config.copyWith(excludePrivateFromRelay: exclude);
    settingsStore.saveSync(_config);
    _safeNotify();
  }

  /// Generates a fresh 256-bit E2EE Vault Sync Master Key, stores it ONLY in
  /// [BlinkSecretStore] (`INV-08`), and returns the printable recovery code.
  Future<String> generateAndStoreRelayMasterKey() async {
    final masterKey = _crypto.generateMasterKey();
    await secretStore.write(
      BlinkSecretKeys.relayMasterKey,
      masterKey.toBase64Url(),
    );
    _hasRelayMasterKey = true;
    _relayMasterKeyId = masterKey.keyId;
    _recomputeBaselineStatus();
    _safeNotify();
    return _crypto.encodeRecoveryCode(masterKey);
  }

  /// Reads the E2EE master key from [BlinkSecretStore] on demand and encodes it
  /// as a printable `BLINK1-...` recovery code.
  Future<String?> exportRelayRecoveryCode() async {
    final raw = await secretStore.read(BlinkSecretKeys.relayMasterKey);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final key = SyncMasterKey.fromBase64Url(raw);
    return _crypto.encodeRecoveryCode(key);
  }

  /// Encodes a local QR transfer JSON payload (`blink_e2ee_v1`) on demand.
  Future<String?> exportRelayQrPayload() async {
    final vault = _vault;
    final raw = await secretStore.read(BlinkSecretKeys.relayMasterKey);
    if (vault == null || raw == null || raw.trim().isEmpty) {
      return null;
    }
    final key = SyncMasterKey.fromBase64Url(raw);
    return _crypto.encodeQrPayload(
      SyncKeyBundle(
        masterKey: key,
        vaultId: vault.metadata.vaultId,
        channel: expectedChannel,
        relayHint: _config.relayEndpoint == null
            ? null
            : <String, Object?>{
                'protocol': _config.relayProtocol.wireValue,
                'endpoint': _config.relayEndpoint,
                if (_config.relayBucket != null) 'bucket': _config.relayBucket,
              },
      ),
    );
  }

  /// Validates and imports a `BLINK1-...` recovery code (or `blink_e2ee_v1` QR
  /// JSON) strictly into [BlinkSecretStore] (`INV-08`).
  Future<bool> importRelayRecoveryCode(String rawInput) async {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) {
      _setError(BlinkErrorCode.invalidArgument, '请输入有效的 BLINK1 恢复码。');
      return false;
    }
    try {
      SyncMasterKey key;
      if (trimmed.startsWith('{')) {
        final bundle = _crypto.decodeQrPayload(trimmed);
        if (bundle.channel != expectedChannel) {
          _applyBlinkException(
            BlinkException(
              code: BlinkErrorCode.channelMismatch,
              message:
                  '恢复码通道为 ${bundle.channel.wireValue}，与当前通道 ${expectedChannel.wireValue} 不匹配。',
            ),
          );
          return false;
        }
        key = bundle.masterKey;
      } else {
        key = _crypto.decodeRecoveryCode(trimmed);
      }
      await secretStore.write(
        BlinkSecretKeys.relayMasterKey,
        key.toBase64Url(),
      );
      _hasRelayMasterKey = true;
      _relayMasterKeyId = key.keyId;
      _lastErrorCode = null;
      _lastErrorMessage = null;
      _recomputeBaselineStatus();
      _safeNotify();
      return true;
    } on BlinkException catch (error) {
      _applyBlinkException(error);
      return false;
    } on BlinkSecretStoreException catch (error) {
      _setError(BlinkErrorCode.ioError, '无法将主同步密钥写入系统安全密钥库（${error.code}）。');
      return false;
    }
  }

  /// Persists non-secret E2EE relay settings to `sync.json` and sensitive
  /// WebDAV/S3 credentials exclusively to [BlinkSecretStore] (`INV-08`).
  Future<bool> saveRelayConfiguration({
    required bool enabled,
    required RelayProtocol protocol,
    required String endpoint,
    String? username,
    String? password,
    String? bearerToken,
    String? bucket,
    String region = 'us-east-1',
    String keyPrefix = 'blink',
    bool usePathStyle = true,
    String? accessKeyId,
    String? secretAccessKey,
    String? sessionToken,
    bool? excludePrivateFromRelay,
  }) async {
    final trimmedEndpoint = endpoint.trim();
    if (trimmedEndpoint.isNotEmpty && _hasUriUserInfo(trimmedEndpoint)) {
      _setError(
        BlinkErrorCode.invalidArgument,
        '中继地址禁止在 URL 中内嵌用户名或密码，请将凭据填写到下方独立密钥输入框（仅存系统密钥库，INV-08）。',
      );
      return false;
    }
    final parsedEndpoint = trimmedEndpoint.isEmpty
        ? null
        : _parseSyncUri(trimmedEndpoint);
    if ((enabled && parsedEndpoint == null) ||
        (trimmedEndpoint.isNotEmpty && parsedEndpoint == null)) {
      _setError(
        BlinkErrorCode.invalidArgument,
        '中继地址格式无效，请输入完整的 http:// 或 https:// 地址。',
      );
      return false;
    }
    final normalizedEndpoint = parsedEndpoint?.toString();

    try {
      if (password != null && password.isNotEmpty) {
        await secretStore.write(BlinkSecretKeys.relayWebDavPassword, password);
      }
      if (bearerToken != null && bearerToken.isNotEmpty) {
        await secretStore.write(
          BlinkSecretKeys.relayWebDavBearerToken,
          bearerToken,
        );
      }
      if (accessKeyId != null && accessKeyId.isNotEmpty) {
        await secretStore.write(
          BlinkSecretKeys.relayS3AccessKeyId,
          accessKeyId,
        );
      }
      if (secretAccessKey != null && secretAccessKey.isNotEmpty) {
        await secretStore.write(
          BlinkSecretKeys.relayS3SecretAccessKey,
          secretAccessKey,
        );
      }
      if (sessionToken != null && sessionToken.isNotEmpty) {
        await secretStore.write(
          BlinkSecretKeys.relayS3SessionToken,
          sessionToken,
        );
      }
    } on BlinkSecretStoreException catch (error) {
      _setError(BlinkErrorCode.ioError, '无法将中继凭据安全写入系统密钥库（${error.code}）。');
      return false;
    }

    final cleanUsername = username?.trim();
    final cleanBucket = bucket?.trim();
    _config = _config.copyWith(
      relayEnabled: enabled,
      relayProtocol: protocol,
      relayEndpoint: normalizedEndpoint,
      clearRelayEndpoint: normalizedEndpoint == null,
      relayUsername: (cleanUsername == null || cleanUsername.isEmpty)
          ? null
          : cleanUsername,
      clearRelayUsername: cleanUsername == null || cleanUsername.isEmpty,
      relayBucket: (cleanBucket == null || cleanBucket.isEmpty)
          ? null
          : cleanBucket,
      clearRelayBucket: cleanBucket == null || cleanBucket.isEmpty,
      relayRegion: region.trim().isEmpty ? 'us-east-1' : region.trim(),
      relayKeyPrefix: keyPrefix.trim().isEmpty ? 'blink' : keyPrefix.trim(),
      relayUsePathStyle: usePathStyle,
      excludePrivateFromRelay:
          excludePrivateFromRelay ?? _config.excludePrivateFromRelay,
    );
    settingsStore.saveSync(_config);
    await _refreshSecretMetadata();
    _lastErrorCode = null;
    _lastErrorMessage = null;
    _recomputeBaselineStatus();
    _safeNotify();
    return true;
  }

  /// Executes a debounced, non-reentrant bidirectional sync cycle across
  /// configured Channel A (Direct) and/or Channel B (E2EE Relay).
  ///
  /// When called while another cycle is already in flight, coalesces concurrent
  /// callers into at most one follow-up cycle and awaits its completion so
  /// callers observe the converged post-sync state rather than an in-progress
  /// follow-up cycle.
  Future<SyncRunResult?> syncNow({bool manual = true}) {
    if (_isDisposed || _isStopping) {
      return Future<SyncRunResult?>.value(null);
    }
    if (_syncInFlight != null) {
      if (manual) {
        _followUpManual = true;
      }
      final existingFollowUp = _followUpSyncFuture;
      if (existingFollowUp != null) {
        return existingFollowUp;
      }
      final inFlight = _syncInFlight!;
      final completer = Completer<SyncRunResult?>();
      final followUpFuture = completer.future;
      _followUpSyncFuture = followUpFuture;
      unawaited(
        inFlight.whenComplete(() async {
          if (identical(_followUpSyncFuture, followUpFuture)) {
            _followUpSyncFuture = null;
          }
          final runManual = _followUpManual;
          _followUpManual = false;
          try {
            if (_isDisposed ||
                _isStopping ||
                !isConfigured ||
                (!runManual && _uiStatus == BlinkSyncUiStatus.deviceRevoked)) {
              completer.complete(null);
              return;
            }
            final result = await _startSyncFuture(manual: runManual);
            completer.complete(result);
          } catch (error, stack) {
            if (!completer.isCompleted) {
              completer.completeError(error, stack);
            }
          }
        }),
      );
      return followUpFuture;
    }
    return _startSyncFuture(manual: manual);
  }

  Future<SyncRunResult?> _startSyncFuture({required bool manual}) {
    final completer = Completer<SyncRunResult?>();
    final future = completer.future;
    _syncInFlight = future;
    unawaited(() async {
      try {
        final result = await _runSyncCycle(manual: manual);
        if (identical(_syncInFlight, future)) {
          _syncInFlight = null;
        }
        completer.complete(result);
      } catch (error, stack) {
        if (identical(_syncInFlight, future)) {
          _syncInFlight = null;
        }
        completer.completeError(error, stack);
      }
    }());
    return future;
  }

  /// Resolves a preserved dual-copy conflict by explicitly keeping the local
  /// device's text (`conflict.localBodyMd`), regardless of causal winner order.
  Future<SyncConflict?> resolveConflictKeepLocal(SyncConflict conflict) async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return null;
    }
    final mainEntry = await vault.raw.getEntryById(
      conflict.entityId,
      includeDeleted: true,
    );
    final choice =
        (mainEntry != null && mainEntry.bodyMd == conflict.localBodyMd)
        ? ConflictResolutionChoice.keepCurrent
        : ConflictResolutionChoice.keepConflictCopy;
    final resolved = await vault.syncEngine.resolveConflict(
      conflictId: conflict.id,
      resolution: choice,
      mergedBodyMd: choice == ConflictResolutionChoice.keepConflictCopy
          ? conflict.localBodyMd
          : null,
    );
    await _afterConflictResolved();
    return resolved;
  }

  /// Resolves a preserved dual-copy conflict by explicitly adopting the remote
  /// peer's text (`conflict.remoteBodyMd`), regardless of causal winner order.
  Future<SyncConflict?> resolveConflictKeepRemote(SyncConflict conflict) async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return null;
    }
    final mainEntry = await vault.raw.getEntryById(
      conflict.entityId,
      includeDeleted: true,
    );
    final choice =
        (mainEntry != null && mainEntry.bodyMd == conflict.remoteBodyMd)
        ? ConflictResolutionChoice.keepCurrent
        : ConflictResolutionChoice.keepConflictCopy;
    final resolved = await vault.syncEngine.resolveConflict(
      conflictId: conflict.id,
      resolution: choice,
      mergedBodyMd: choice == ConflictResolutionChoice.keepConflictCopy
          ? conflict.remoteBodyMd
          : null,
    );
    await _afterConflictResolved();
    return resolved;
  }

  /// Resolves a preserved dual-copy conflict with user-merged BFM content.
  Future<SyncConflict?> resolveConflictCustomMerge(
    SyncConflict conflict,
    String mergedBodyMd,
  ) async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return null;
    }
    final resolved = await vault.syncEngine.resolveConflict(
      conflictId: conflict.id,
      resolution: ConflictResolutionChoice.customMerge,
      mergedBodyMd: mergedBodyMd,
    );
    await _afterConflictResolved();
    return resolved;
  }

  Future<void> _afterConflictResolved() async {
    final vault = _vault;
    if (vault == null || !vault.isOpen) {
      return;
    }
    _openConflicts = await vault.syncEngine.listOpenConflicts();
    _openConflictCount = _openConflicts.length;
    _pendingOutboxCount = vault.syncEngine.getPendingOutboxCount();
    _recomputeBaselineStatus();
    _safeNotify();
    onVaultDataChanged?.call();
    if (_config.autoSyncEnabled && isConfigured) {
      _scheduleWriteDebouncedSync();
    }
  }

  Future<SyncRunResult?> _runSyncCycle({required bool manual}) async {
    final vault = _vault;
    if (_isDisposed || _isStopping || vault == null || !vault.isOpen) {
      return null;
    }
    if (!isConfigured) {
      _recomputeBaselineStatus();
      _safeNotify();
      return null;
    }

    _isSyncing = true;
    _uiStatus = BlinkSyncUiStatus.syncing;
    _lastErrorCode = null;
    _lastErrorMessage = null;
    _lastSkippedPrivateCount = 0;
    _safeNotify();

    SyncRunResult? combinedResult;
    var anySucceeded = false;
    BlinkException? directError;
    BlinkException? relayError;

    try {
      // 1. Channel A: Direct LAN/Tailscale sync first (full `#private` support).
      if (isDirectConfigured) {
        _activeChannelLabel = '局域网/Tailscale 直连';
        _safeNotify();
        final token = await secretStore.read(BlinkSecretKeys.directDeviceToken);
        final uri = _parseSyncUri(_config.directPeerUrl ?? '');
        if (token == null || token.isEmpty || uri == null) {
          directError = BlinkException(
            code: BlinkErrorCode.authRequired,
            message: '设备同步令牌缺失，请重新与桌面端配对。',
          );
        } else {
          final transport = DirectShelfTransport(
            baseUri: uri,
            expectedChannel: expectedChannel,
            deviceToken: token,
            requestTimeout: directRequestTimeout,
          );
          try {
            final res = await vault.syncEngine.syncWithTransport(transport);
            combinedResult = res;
            anySucceeded = true;
          } on BlinkException catch (error) {
            directError = error;
          } finally {
            transport.close();
          }
        }
      }

      // 2. Channel B: E2EE WebDAV/S3 async relay (runs when enabled, including
      //    graceful async fallback while desktop peer is asleep).
      final shouldTryRelay =
          isRelayConfigured &&
          (directError == null ||
              directError.code == BlinkErrorCode.peerAsleep);
      if (shouldTryRelay) {
        _activeChannelLabel = 'E2EE ${_config.relayProtocol.label} 异步中继';
        _safeNotify();
        final secrets = await _loadRelaySecrets();
        if (secrets.masterKey == null) {
          relayError = BlinkException(
            code: BlinkErrorCode.authRequired,
            message: '缺少 E2EE 主同步密钥，请先生成或导入恢复码。',
          );
        } else {
          RelayObjectStore? store;
          try {
            store = _relayStoreFactory(_config, secrets);
            final relayTransport = EncryptedRelayTransport(
              store: store,
              masterKey: secrets.masterKey!,
              localVaultId: vault.metadata.vaultId,
              expectedChannel: expectedChannel,
              localDeviceId: vault.localDeviceId,
              excludePrivateFromRelay: _config.excludePrivateFromRelay,
              stateStore: vault.syncEngine,
            );
            final res = await vault.syncEngine.syncWithTransport(
              relayTransport,
              excludePrivate: _config.excludePrivateFromRelay,
            );
            combinedResult = combinedResult == null
                ? res
                : _mergeRunResults(combinedResult, res);
            anySucceeded = true;
          } on BlinkException catch (error) {
            relayError = error;
          } finally {
            store?.close();
          }
        }
      }

      // Refresh live vault sync counters before finalizing status.
      if (vault.isOpen) {
        final snap = vault.syncEngine.getSyncStatus();
        _pendingOutboxCount = snap.pendingOutboxCount;
        _openConflictCount = snap.openConflictCount;
        _lastObservedSeqId = snap.latestSeqId;
        _lastSyncedAtUtc = snap.lastSyncedAtUtc;
        _openConflicts = await vault.syncEngine.listOpenConflicts();
      }

      _isSyncing = false;
      _lastRunResult = combinedResult;
      _lastSkippedPrivateCount = combinedResult?.skippedPrivateOps ?? 0;

      if (directError != null &&
          (directError.code == BlinkErrorCode.deviceRevoked ||
              directError.code == BlinkErrorCode.channelMismatch ||
              directError.code == BlinkErrorCode.protocolMismatch)) {
        _applyBlinkException(directError);
        if (directError.code == BlinkErrorCode.deviceRevoked) {
          await _stopSseWakeupLoop();
        }
      } else if (relayError != null && !anySucceeded) {
        _applyBlinkException(relayError);
      } else if (directError != null && !anySucceeded) {
        _applyBlinkException(directError);
      } else {
        if (_openConflictCount > 0) {
          _uiStatus = BlinkSyncUiStatus.conflictPending;
        } else if (_lastSkippedPrivateCount > 0 &&
            !isDirectConfigured &&
            _pendingOutboxCount > 0) {
          _uiStatus = BlinkSyncUiStatus.privacyBlocked;
          _lastErrorCode = BlinkErrorCode.privacyBlocked;
          _lastErrorMessage =
              '已按隐私策略拦截 $_lastSkippedPrivateCount 条 #private 变更经云中继同步，仅保留在本机等待局域网/Tailscale 直连同步。';
        } else if (directError != null &&
            directError.code == BlinkErrorCode.peerAsleep &&
            _pendingOutboxCount > 0) {
          _uiStatus = BlinkSyncUiStatus.peerAsleep;
          _lastErrorCode = BlinkErrorCode.peerAsleep;
          _lastErrorMessage = '桌面直连节点当前离线，已通过 E2EE 中继同步非私密条目。';
        } else if (_pendingOutboxCount > 0) {
          _uiStatus = BlinkSyncUiStatus.offlinePending;
        } else {
          _uiStatus = BlinkSyncUiStatus.idleSynced;
        }
      }

      if (combinedResult != null &&
          (combinedResult.appliedOps > 0 ||
              combinedResult.conflictsCreated > 0)) {
        onVaultDataChanged?.call();
      }
      _safeNotify();
      return combinedResult;
    } on BlinkSecretStoreException catch (error) {
      _isSyncing = false;
      _setError(
        BlinkErrorCode.authRequired,
        '无法从系统安全密钥库读取同步凭据（${error.code}）。',
      );
      return null;
    } catch (_) {
      _isSyncing = false;
      _setError(BlinkErrorCode.ioError, '同步过程中发生异常，本地变更已安全保留。');
      return null;
    }
  }

  Future<bool> _startDesktopHostInternal() async {
    final vault = _vault;
    if (vault == null || !vault.isOpen || isMobile) {
      return false;
    }
    final server = DirectShelfServer(vault: vault);
    try {
      await server.start(
        host: _config.desktopServerBindHost,
        port: _config.desktopServerPort,
      );
      _server = server;
      await refreshLocalHostAddresses();
      await refreshPairedDevices();

      if (!isQuiet) {
        final advertiseIp = _localHostAddresses.firstWhere(
          (ip) => ip != '127.0.0.1',
          orElse: () => '127.0.0.1',
        );
        try {
          await _lanDiscovery.startAdvertising(
            LanPeerAnnouncement(
              instanceName:
                  'blink-${expectedChannel.wireValue}-${vault.localDeviceId.substring(0, 8)}',
              channel: expectedChannel,
              vaultId: vault.metadata.vaultId,
              deviceId: vault.localDeviceId,
              deviceName: vault.localDeviceName,
              port: server.port,
              hostAddress: advertiseIp,
            ),
          );
        } catch (_) {
          // mDNS failure must not bring down the HTTP direct sync host.
        }
      }
      if (_uiStatus == BlinkSyncUiStatus.error) {
        _lastErrorCode = null;
        _lastErrorMessage = null;
        _recomputeBaselineStatus();
      }
      return true;
    } catch (error) {
      await server.stop();
      _server = null;
      _setError(
        BlinkErrorCode.ioError,
        '无法在 ${_config.desktopServerBindHost}:${_config.desktopServerPort} 启动桌面直连同步服务。',
      );
      return false;
    }
  }

  Future<void> _stopDesktopHostInternal() async {
    _activePairingCode = null;
    try {
      await _lanDiscovery.stopAdvertising();
    } catch (_) {}
    final server = _server;
    _server = null;
    if (server != null) {
      await server.stop();
    }
  }

  void _handleVaultStatusSnapshot(SyncStatusSnapshot snapshot) {
    final localAdvanced =
        !_isSyncing &&
        snapshot.latestSeqId > _lastObservedSeqId &&
        snapshot.pendingOutboxCount > 0;

    _pendingOutboxCount = snapshot.pendingOutboxCount;
    _openConflictCount = snapshot.openConflictCount;
    _lastSyncedAtUtc = snapshot.lastSyncedAtUtc;
    if (!_isSyncing) {
      _lastObservedSeqId = snapshot.latestSeqId;
    }

    if (!_isSyncing &&
        _uiStatus != BlinkSyncUiStatus.deviceRevoked &&
        _uiStatus != BlinkSyncUiStatus.channelMismatch &&
        _uiStatus != BlinkSyncUiStatus.peerAsleep &&
        _uiStatus != BlinkSyncUiStatus.privacyBlocked) {
      _recomputeBaselineStatus();
    }

    if (localAdvanced &&
        !_isStopping &&
        !_isDisposed &&
        _config.autoSyncEnabled &&
        isConfigured &&
        _uiStatus != BlinkSyncUiStatus.deviceRevoked) {
      _scheduleWriteDebouncedSync();
    }
    _safeNotify();
  }

  void _scheduleWriteDebouncedSync() {
    if (_isDisposed || _isStopping) {
      return;
    }
    _writeDebounceTimer?.cancel();
    _writeDebounceTimer = Timer(writeDebounce, () {
      if (!_isDisposed &&
          !_isStopping &&
          _config.autoSyncEnabled &&
          isConfigured) {
        unawaited(syncNow(manual: false));
      }
    });
  }

  void _startSseWakeupLoop() {
    if (_isDisposed ||
        _isStopping ||
        !enableSseWakeup ||
        !_config.autoSyncEnabled) {
      return;
    }
    unawaited(_connectSseOnce());
  }

  Future<void> _connectSseOnce() async {
    final generation = ++_sseGeneration;
    await _tearDownSseResources();
    if (generation != _sseGeneration ||
        _isDisposed ||
        _isStopping ||
        !enableSseWakeup ||
        !_config.autoSyncEnabled ||
        !isDirectConfigured ||
        _vault == null ||
        !_vault!.isOpen) {
      return;
    }
    final uri = _parseSyncUri(_config.directPeerUrl ?? '');
    if (uri == null) {
      return;
    }
    String? token;
    try {
      token = await secretStore.read(BlinkSecretKeys.directDeviceToken);
    } catch (_) {
      return;
    }
    if (generation != _sseGeneration ||
        token == null ||
        token.isEmpty ||
        _isDisposed ||
        _isStopping) {
      return;
    }

    final transport = DirectShelfTransport(
      baseUri: uri,
      expectedChannel: expectedChannel,
      deviceToken: token,
      requestTimeout: directRequestTimeout,
    );
    _sseTransport = transport;
    var receivedReady = false;

    _sseSub = transport.watchSeqEvents().listen(
      (remoteSeq) {
        if (generation != _sseGeneration || _isDisposed || _isStopping) {
          return;
        }
        _sseReconnectAttempt = 0;
        final wasAsleep = _uiStatus == BlinkSyncUiStatus.peerAsleep;
        final remoteAdvanced = remoteSeq > _lastObservedRemoteSeq;
        if (remoteSeq > _lastObservedRemoteSeq) {
          _lastObservedRemoteSeq = remoteSeq;
        }
        if (!receivedReady) {
          receivedReady = true;
          if (_config.autoSyncEnabled &&
              (wasAsleep || _pendingOutboxCount > 0 || remoteAdvanced)) {
            unawaited(syncNow(manual: false));
          }
          return;
        }
        if (_config.autoSyncEnabled) {
          unawaited(syncNow(manual: false));
        }
      },
      onError: (Object error) {
        if (generation != _sseGeneration || _isDisposed || _isStopping) {
          return;
        }
        if (error is BlinkException &&
            error.code == BlinkErrorCode.deviceRevoked) {
          _applyBlinkException(error);
          unawaited(_stopSseWakeupLoop());
          return;
        }
        _scheduleSseReconnect();
      },
      onDone: () {
        if (generation == _sseGeneration &&
            !_isDisposed &&
            !_isStopping &&
            isDirectConfigured &&
            _uiStatus != BlinkSyncUiStatus.deviceRevoked) {
          _scheduleSseReconnect();
        }
      },
      cancelOnError: true,
    );
  }

  void _scheduleSseReconnect() {
    if (_isDisposed ||
        _isStopping ||
        !isDirectConfigured ||
        _uiStatus == BlinkSyncUiStatus.deviceRevoked) {
      return;
    }
    _sseReconnectTimer?.cancel();
    final multiplier = 1 << _sseReconnectAttempt.clamp(0, 3);
    _sseReconnectAttempt = (_sseReconnectAttempt + 1).clamp(0, 4);
    final delay = Duration(
      milliseconds: sseReconnectBaseDelay.inMilliseconds * multiplier,
    );
    _sseReconnectTimer = Timer(delay, () {
      if (!_isDisposed && !_isStopping && isDirectConfigured) {
        unawaited(_connectSseOnce());
      }
    });
  }

  Future<void> _stopSseWakeupLoop() async {
    _sseGeneration++;
    await _tearDownSseResources();
  }

  Future<void> _tearDownSseResources() async {
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = null;
    final sub = _sseSub;
    _sseSub = null;
    await sub?.cancel();
    final transport = _sseTransport;
    _sseTransport = null;
    transport?.close(force: true);
  }

  Future<void> _refreshSecretMetadata() async {
    try {
      final token = await secretStore.read(BlinkSecretKeys.directDeviceToken);
      _hasDirectDeviceToken = token != null && token.isNotEmpty;
    } catch (_) {
      _hasDirectDeviceToken = false;
    }

    try {
      final masterRaw = await secretStore.read(BlinkSecretKeys.relayMasterKey);
      if (masterRaw != null && masterRaw.trim().isNotEmpty) {
        final key = SyncMasterKey.fromBase64Url(masterRaw);
        _hasRelayMasterKey = true;
        _relayMasterKeyId = key.keyId;
      } else {
        _hasRelayMasterKey = false;
        _relayMasterKeyId = null;
      }
    } catch (_) {
      _hasRelayMasterKey = false;
      _relayMasterKeyId = null;
    }

    try {
      final webdavPass = await secretStore.read(
        BlinkSecretKeys.relayWebDavPassword,
      );
      final webdavBearer = await secretStore.read(
        BlinkSecretKeys.relayWebDavBearerToken,
      );
      final s3Key = await secretStore.read(BlinkSecretKeys.relayS3AccessKeyId);
      final s3Secret = await secretStore.read(
        BlinkSecretKeys.relayS3SecretAccessKey,
      );
      _hasWebDavCredentials =
          (webdavPass != null && webdavPass.isNotEmpty) ||
          (webdavBearer != null && webdavBearer.isNotEmpty);
      _hasS3Credentials =
          (s3Key != null &&
          s3Key.isNotEmpty &&
          s3Secret != null &&
          s3Secret.isNotEmpty);
    } catch (_) {
      _hasWebDavCredentials = false;
      _hasS3Credentials = false;
    }
  }

  Future<RelaySecrets> _loadRelaySecrets() async {
    final masterRaw = await secretStore.read(BlinkSecretKeys.relayMasterKey);
    final masterKey = (masterRaw != null && masterRaw.trim().isNotEmpty)
        ? SyncMasterKey.fromBase64Url(masterRaw)
        : null;
    return RelaySecrets(
      masterKey: masterKey,
      webdavPassword: await secretStore.read(
        BlinkSecretKeys.relayWebDavPassword,
      ),
      webdavBearerToken: await secretStore.read(
        BlinkSecretKeys.relayWebDavBearerToken,
      ),
      s3AccessKeyId: await secretStore.read(BlinkSecretKeys.relayS3AccessKeyId),
      s3SecretAccessKey: await secretStore.read(
        BlinkSecretKeys.relayS3SecretAccessKey,
      ),
      s3SessionToken: await secretStore.read(
        BlinkSecretKeys.relayS3SessionToken,
      ),
    );
  }

  void _recomputeBaselineStatus() {
    if (_isSyncing) {
      _uiStatus = BlinkSyncUiStatus.syncing;
      return;
    }
    if (_openConflictCount > 0) {
      _uiStatus = BlinkSyncUiStatus.conflictPending;
      return;
    }
    if (!isConfigured) {
      _uiStatus = BlinkSyncUiStatus.unconfigured;
      return;
    }
    if (_pendingOutboxCount > 0) {
      _uiStatus = BlinkSyncUiStatus.offlinePending;
      return;
    }
    _uiStatus = BlinkSyncUiStatus.idleSynced;
  }

  void _applyBlinkException(BlinkException error) {
    _lastErrorCode = error.code;
    switch (error.code) {
      case BlinkErrorCode.peerAsleep:
        _uiStatus = BlinkSyncUiStatus.peerAsleep;
        _lastErrorMessage =
            '同步对端当前离线或休眠，$_pendingOutboxCount 项本地变更已安全排队，恢复在线后自动同步。';
      case BlinkErrorCode.deviceRevoked:
        _uiStatus = BlinkSyncUiStatus.deviceRevoked;
        _lastErrorMessage = '当前设备同步访问权限已被吊销，请重新获取配对码完成配对。';
      case BlinkErrorCode.channelMismatch:
      case BlinkErrorCode.protocolMismatch:
        _uiStatus = BlinkSyncUiStatus.channelMismatch;
        _lastErrorMessage =
            '同步节点通道或协议版本不匹配（当前通道：${expectedChannel.wireValue}）。';
      case BlinkErrorCode.privacyBlocked:
        _uiStatus = BlinkSyncUiStatus.privacyBlocked;
        _lastErrorMessage = '隐私策略拦截：#private 条目禁止经当前云中继传输。';
      case BlinkErrorCode.authRequired:
        _uiStatus = BlinkSyncUiStatus.error;
        _lastErrorMessage = '同步鉴权失败（auth_required），请核对配对码、主密钥或中继凭据。';
      default:
        _uiStatus = BlinkSyncUiStatus.error;
        _lastErrorMessage = '同步出错（${error.code.wireCode}）：${error.message}';
    }
    _safeNotify();
  }

  void _setError(BlinkErrorCode code, String message) {
    _lastErrorCode = code;
    _lastErrorMessage = message;
    _uiStatus = switch (code) {
      BlinkErrorCode.peerAsleep => BlinkSyncUiStatus.peerAsleep,
      BlinkErrorCode.deviceRevoked => BlinkSyncUiStatus.deviceRevoked,
      BlinkErrorCode.channelMismatch ||
      BlinkErrorCode.protocolMismatch => BlinkSyncUiStatus.channelMismatch,
      BlinkErrorCode.privacyBlocked => BlinkSyncUiStatus.privacyBlocked,
      _ => BlinkSyncUiStatus.error,
    };
    _safeNotify();
  }

  Future<void> _detachCurrentVault() async {
    _writeDebounceTimer?.cancel();
    _writeDebounceTimer = null;
    await _stopSseWakeupLoop();
    await _stopDesktopHostInternal();
    await _cancelVaultSubscriptions();
  }

  Future<void> _cancelVaultSubscriptions() async {
    await _statusSub?.cancel();
    await _conflictsSub?.cancel();
    _statusSub = null;
    _conflictsSub = null;
  }

  static bool _hasUriUserInfo(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final withScheme =
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'))
        ? trimmed
        : 'http://$trimmed';
    final parsed = Uri.tryParse(withScheme);
    return parsed != null && parsed.userInfo.isNotEmpty;
  }

  static Uri? _parseSyncUri(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final withScheme =
        (trimmed.startsWith('http://') || trimmed.startsWith('https://'))
        ? trimmed
        : 'http://$trimmed';
    final parsed = Uri.tryParse(withScheme);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https') ||
        parsed.host.trim().isEmpty ||
        parsed.userInfo.isNotEmpty) {
      return null;
    }
    return parsed;
  }

  static RelayObjectStore _defaultRelayStoreFactory(
    SyncClientConfig config,
    RelaySecrets secrets,
  ) {
    final endpoint = _parseSyncUri(config.relayEndpoint ?? '');
    if (endpoint == null) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid relay endpoint URL',
      );
    }
    switch (config.relayProtocol) {
      case RelayProtocol.webdav:
        return WebDavClient(
          baseUri: endpoint,
          username: config.relayUsername,
          password: secrets.webdavPassword,
          bearerToken: secrets.webdavBearerToken,
        );
      case RelayProtocol.s3:
        final bucket = config.relayBucket?.trim() ?? '';
        final accessKey = secrets.s3AccessKeyId?.trim() ?? '';
        final secretKey = secrets.s3SecretAccessKey?.trim() ?? '';
        if (bucket.isEmpty || accessKey.isEmpty || secretKey.isEmpty) {
          throw BlinkException(
            code: BlinkErrorCode.authRequired,
            message:
                'S3 bucket, Access Key ID, and Secret Access Key are required',
          );
        }
        return S3Client(
          endpoint: endpoint,
          bucket: bucket,
          region: config.relayRegion,
          accessKeyId: accessKey,
          secretAccessKey: secretKey,
          sessionToken: secrets.s3SessionToken,
          keyPrefix: config.relayKeyPrefix,
          usePathStyle: config.relayUsePathStyle,
        );
    }
  }

  static SyncRunResult _mergeRunResults(SyncRunResult a, SyncRunResult b) =>
      SyncRunResult(
        pushedOps: a.pushedOps + b.pushedOps,
        duplicateOps: a.duplicateOps + b.duplicateOps,
        pulledOps: a.pulledOps + b.pulledOps,
        appliedOps: a.appliedOps + b.appliedOps,
        skippedPrivateOps: a.skippedPrivateOps + b.skippedPrivateOps,
        conflictsCreated: a.conflictsCreated + b.conflictsCreated,
        blobsUploaded: a.blobsUploaded + b.blobsUploaded,
        blobsDownloaded: a.blobsDownloaded + b.blobsDownloaded,
        completedAtUtc: b.completedAtUtc,
      );

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isStopping = true;
    _isDisposed = true;
    _sseGeneration++;
    _writeDebounceTimer?.cancel();
    _sseReconnectTimer?.cancel();
    unawaited(stopForShutdown());
    unawaited(_lanDiscovery.dispose());
    super.dispose();
  }
}
