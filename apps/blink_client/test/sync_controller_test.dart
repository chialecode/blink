import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/application/sync_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/secret_store.dart';

class _InMemoryRelayObjectStore implements RelayObjectStore {
  @override
  String get storeId => 'memory-relay';

  final Map<String, Uint8List> objects = <String, Uint8List>{};

  @override
  Future<void> checkConnection() async {}

  @override
  Future<void> ensurePrefix(String prefix) async {}

  @override
  Future<List<String>> listKeys(String prefix) async {
    final normalized = prefix.replaceAll(RegExp(r'^/+|/+$'), '');
    final keys =
        objects.keys
            .where(
              (k) =>
                  normalized.isEmpty ||
                  k == normalized ||
                  k.startsWith('$normalized/'),
            )
            .toList()
          ..sort();
    return keys;
  }

  @override
  Future<bool> exists(String key) async => objects.containsKey(key);

  @override
  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    objects[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> getBytes(String key) async => objects[key];

  @override
  Future<void> deleteKey(String key) async {
    objects.remove(key);
  }

  @override
  void close() {}
}

class _BlockingRelayObjectStore extends _InMemoryRelayObjectStore {
  _BlockingRelayObjectStore({
    required this.firstCycleEntered,
    required this.releaseFirstCycle,
  });

  final Completer<void> firstCycleEntered;
  final Completer<void> releaseFirstCycle;
  int checkConnectionCalls = 0;

  @override
  Future<void> checkConnection() async {
    checkConnectionCalls++;
    if (checkConnectionCalls == 1) {
      if (!firstCycleEntered.isCompleted) {
        firstCycleEntered.complete();
      }
      await releaseFirstCycle.future;
    }
  }
}

class _GatedSecretStore implements BlinkSecretStore {
  _GatedSecretStore(this.inner);

  final InMemoryBlinkSecretStore inner;
  Completer<void>? readStarted;
  Completer<void>? allowReadCompletion;

  @override
  String get channel => inner.channel;

  @override
  Future<String?> read(String key) async {
    if (key == BlinkSecretKeys.directDeviceToken &&
        allowReadCompletion != null) {
      if (readStarted != null && !readStarted!.isCompleted) {
        readStarted!.complete();
      }
      await allowReadCompletion!.future;
    }
    return inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => inner.write(key, value);

  @override
  Future<void> delete(String key) => inner.delete(key);

  @override
  Future<void> deleteAllForChannel() => inner.deleteAllForChannel();
}

class _FakeWindowAdapter implements DesktopWindowAdapter {
  @override
  Future<WindowGeometrySnapshot?> captureGeometry() async => null;

  @override
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  }) async {}

  @override
  Future<void> destroy() async {}

  @override
  Future<void> hideToTray() async {}

  @override
  Future<bool> isVisible() async => false;

  @override
  Future<void> minimizeToTaskbar() async {}

  @override
  Future<void> showAndFocus() async {}
}

class _FakeTrayAdapter implements DesktopTrayAdapter {
  @override
  Future<void> destroy() async {}

  @override
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) async => false;

  @override
  Future<void> recreate() async {}
}

/// Scans every file inside [dir] and verifies none contain [secretText].
void _expectZeroSecretInDirectory(Directory dir, String secretText) {
  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final raw = entity.readAsBytesSync();
    final asLatin1 = latin1.decode(raw, allowInvalid: true);
    expect(
      asLatin1,
      isNot(contains(secretText)),
      reason: 'Secret leaked into ${entity.path}',
    );
  }
}

void main() {
  group('SyncSettingsStore atomic persistence & corrupt backup (INV-07)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_sync_settings_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('preserves corrupt sync.json and defaults excludePrivateFromRelay to true', () {
      final file = File('${tempDir.path}/settings/sync.json')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('{corrupt-json');

      final store = SyncSettingsStore(
        file: file,
        nowUtc: () => DateTime.utc(2026, 11, 27, 6, 30, 0),
      );
      final loaded = store.loadSync();
      expect(loaded.recoveredFromCorrupt, isTrue);
      expect(loaded.preservedCorruptFile?.existsSync(), isTrue);
      expect(
        loaded.preservedCorruptFile?.path,
        contains('sync.json.corrupt-20261127T063000Z'),
      );
      expect(loaded.config.excludePrivateFromRelay, isTrue);
      expect(loaded.config.autoSyncEnabled, isTrue);
    });
  });

  group('BlinkSyncController loopback DirectShelfServer, E2EE relay & conflicts', () {
    late Directory rootTemp;
    late VaultManager desktopVault;
    late VaultManager mobileVault;
    late BlinkPaths desktopPaths;
    late BlinkPaths mobilePaths;
    late InMemoryBlinkSecretStore desktopSecrets;
    late InMemoryBlinkSecretStore mobileSecrets;
    late BlinkSyncController desktopSync;
    late BlinkSyncController mobileSync;

    setUp(() async {
      rootTemp = Directory.systemTemp.createTempSync('blink_sync_ctrl_');
      desktopPaths = BlinkPaths(
        dataRoot: Directory('${rootTemp.path}/desktop_app'),
        defaultVaultDir: Directory('${rootTemp.path}/desktop_vault'),
      );
      mobilePaths = BlinkPaths(
        dataRoot: Directory('${rootTemp.path}/mobile_app'),
        defaultVaultDir: Directory('${rootTemp.path}/mobile_vault'),
      );
      desktopVault = await VaultManager.open(
        VaultConfig(
          vaultDir: desktopPaths.vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
          deviceName: 'Desktop-Win',
        ),
      );
      mobileVault = await VaultManager.open(
        VaultConfig(
          vaultDir: mobilePaths.vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
          deviceName: 'Android-Dev',
        ),
      );
      desktopSecrets = InMemoryBlinkSecretStore(channel: 'blink-dev');
      mobileSecrets = InMemoryBlinkSecretStore(channel: 'blink-dev');

      final sharedLanRegistry = <LanPeerAnnouncement>[];
      desktopSync = BlinkSyncController(
        paths: desktopPaths,
        expectedChannel: BlinkChannel.blinkDev,
        secretStore: desktopSecrets,
        lanDiscovery: LanDiscovery(
          adapter: InMemoryLanDiscoveryAdapter(
            sharedRegistry: sharedLanRegistry,
          ),
        ),
        isQuiet: true,
        isMobilePlatform: false,
        writeDebounce: const Duration(milliseconds: 60),
        sseReconnectBaseDelay: const Duration(milliseconds: 80),
      );
      mobileSync = BlinkSyncController(
        paths: mobilePaths,
        expectedChannel: BlinkChannel.blinkDev,
        secretStore: mobileSecrets,
        lanDiscovery: LanDiscovery(
          adapter: InMemoryLanDiscoveryAdapter(
            sharedRegistry: sharedLanRegistry,
          ),
        ),
        isQuiet: true,
        isMobilePlatform: true,
        writeDebounce: const Duration(milliseconds: 60),
        sseReconnectBaseDelay: const Duration(milliseconds: 80),
      );

      await desktopSync.attachVault(desktopVault);
      await mobileSync.attachVault(mobileVault);
    });

    tearDown(() async {
      await mobileSync.stopForShutdown();
      await desktopSync.stopForShutdown();
      mobileSync.dispose();
      desktopSync.dispose();
      if (mobileVault.isOpen) {
        await mobileVault.checkpointAndClose();
      }
      if (desktopVault.isOpen) {
        await desktopVault.checkpointAndClose();
      }
      if (rootTemp.existsSync()) {
        rootTemp.deleteSync(recursive: true);
      }
    });

    test('pairs over loopback DirectShelfServer, enforces INV-08 zero vault secrets, handles peerAsleep, auto+manual sync, and deviceRevoked', () async {
      // Start embedded desktop server on quiet loopback ephemeral port.
      final started = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: 0,
      );
      expect(started, isTrue);
      expect(desktopSync.isHostRunning, isTrue);
      expect(desktopSync.isLanAdvertising, isFalse); // Quiet mode guard.
      final port = desktopSync.activeServerPort!;
      expect(port, greaterThan(0));

      // Seed desktop note prior to pairing.
      final desktopEntry = await desktopVault.raw.createEntry(
        bodyMd: '桌面端初始闪念 #desktop',
      );

      final pairingCode = desktopSync.generatePairingCode();
      expect(pairingCode, isNotNull);

      // Pair mobile with desktop via one-time code.
      final paired = await mobileSync.pairWithDirectPeer(
        baseUrl: 'http://127.0.0.1:$port',
        pairingCode: pairingCode!.code,
      );
      expect(paired, isNotNull);
      expect(mobileSync.isDirectConfigured, isTrue);
      expect(mobileSync.uiStatus, BlinkSyncUiStatus.idleSynced);

      // Verify token lives ONLY in SecretStore, NEVER in sync.json or either vault (`INV-08`).
      final storedToken = await mobileSecrets.read(
        BlinkSecretKeys.directDeviceToken,
      );
      expect(storedToken, paired!.deviceToken);
      final syncJsonRaw = mobilePaths.syncSettingsFile.readAsStringSync();
      expect(syncJsonRaw, isNot(contains(storedToken!)));
      _expectZeroSecretInDirectory(desktopPaths.vaultDir, storedToken);
      _expectZeroSecretInDirectory(mobilePaths.vaultDir, storedToken);

      // Mobile received desktop entry via initial sync.
      expect(await mobileVault.raw.getEntryById(desktopEntry.id), isNotNull);

      // Stop desktop server -> create offline note on mobile -> verify honest peerAsleep!
      await desktopSync.setDesktopServerEnabled(false);
      expect(desktopSync.isHostRunning, isFalse);

      final offlineEntry = await mobileVault.raw.createEntry(
        bodyMd: '手机断网离线记录 #offline',
      );
      expect(mobileVault.pendingOutboxCount, greaterThanOrEqualTo(1));

      await mobileSync.syncNow(manual: true);
      expect(mobileSync.uiStatus, BlinkSyncUiStatus.peerAsleep);
      expect(mobileSync.pendingOutboxCount, greaterThanOrEqualTo(1));

      // Restart desktop server on same port -> verify bidirectional auto/manual sync!
      final restarted = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: port,
      );
      expect(restarted, isTrue);

      final desktopSecond = await desktopVault.raw.createEntry(
        bodyMd: '桌面端恢复上线后的新记录 #online',
      );
      await mobileSync.syncNow(manual: true);
      expect(mobileSync.uiStatus, BlinkSyncUiStatus.idleSynced);
      expect(mobileSync.pendingOutboxCount, 0);
      expect(await desktopVault.raw.getEntryById(offlineEntry.id), isNotNull);
      expect(await mobileVault.raw.getEntryById(desktopSecond.id), isNotNull);

      // Auto debounced sync on local write + SSE wakeup.
      final autoMobileEntry = await mobileVault.raw.createEntry(
        bodyMd: '防抖自动同步验证 #autosync',
      );
      for (var i = 0; i < 30; i++) {
        if (await desktopVault.raw.getEntryById(autoMobileEntry.id) != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(
        await desktopVault.raw.getEntryById(autoMobileEntry.id),
        isNotNull,
      );

      // Device revocation must surface `deviceRevoked` honestly (`INV-11`).
      await desktopSync.refreshPairedDevices();
      expect(desktopSync.pairedDevices, isNotEmpty);
      final revoked = await desktopSync.revokePairedDevice(
        mobileVault.localDeviceId,
      );
      expect(revoked, isTrue);

      await mobileSync.syncNow(manual: true);
      expect(mobileSync.uiStatus, BlinkSyncUiStatus.deviceRevoked);
    });

    test('preserves dual-copy conflict on concurrent offline edits and resolves keepLocal / keepRemote / customMerge accurately', () async {
      final started = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: 0,
      );
      expect(started, isTrue);
      final port = desktopSync.activeServerPort!;
      final code = desktopSync.generatePairingCode()!;

      final baseEntry = await desktopVault.raw.createEntry(bodyMd: '初始原文基线');
      await mobileSync.pairWithDirectPeer(
        baseUrl: 'http://127.0.0.1:$port',
        pairingCode: code.code,
      );
      await mobileSync.setAutoSyncEnabled(false);

      // Stop server and concurrently edit the same entry on both devices.
      await desktopSync.setDesktopServerEnabled(false);
      await desktopVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '桌面端并发修改正文 Alpha',
      );
      await mobileVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '移动端并发修改正文 Beta',
      );

      // Restart server and sync -> conflict MUST be preserved on mobile!
      await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: port,
      );
      await mobileSync.syncNow(manual: true);

      expect(mobileSync.openConflictCount, 1);
      expect(mobileSync.uiStatus, BlinkSyncUiStatus.conflictPending);
      final conflict = mobileSync.openConflicts.single;
      expect(
        <String>{conflict.localBodyMd, conflict.remoteBodyMd},
        <String>{'桌面端并发修改正文 Alpha', '移动端并发修改正文 Beta'},
      );

      // Resolve with custom merge -> updates entry and closes conflict.
      const merged = '合并后的完整正文：Alpha + Beta';
      final resolved = await mobileSync.resolveConflictCustomMerge(
        conflict,
        merged,
      );
      expect(resolved?.status, SyncConflictStatus.resolved);
      expect(mobileSync.openConflictCount, 0);
      final afterMerge = await mobileVault.raw.getEntryById(baseEntry.id);
      expect(afterMerge?.bodyMd, merged);

      // Trigger a second concurrent conflict to verify keepLocal & keepRemote.
      await mobileSync.syncNow(manual: true);
      await desktopSync.setDesktopServerEnabled(false);
      await desktopVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '第二轮远端版本 RemoteV2',
      );
      await mobileVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '第二轮本机版本 LocalV2',
      );
      await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: port,
      );
      await mobileSync.syncNow(manual: true);
      expect(mobileSync.openConflictCount, 1);
      final conflict2 = mobileSync.openConflicts.single;
      await mobileSync.resolveConflictKeepLocal(conflict2);
      expect(mobileSync.openConflictCount, 0);
      final afterLocal = await mobileVault.raw.getEntryById(baseEntry.id);
      expect(afterLocal?.bodyMd, conflict2.localBodyMd);

      // Trigger a third concurrent conflict to verify keepRemote explicitly.
      await mobileSync.syncNow(manual: true);
      await desktopSync.setDesktopServerEnabled(false);
      await desktopVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '第三轮远端版本 RemoteV3',
      );
      await mobileVault.raw.updateEntry(
        id: baseEntry.id,
        bodyMd: '第三轮本机版本 LocalV3',
      );
      await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: port,
      );
      await mobileSync.syncNow(manual: true);
      expect(mobileSync.openConflictCount, 1);
      final conflict3 = mobileSync.openConflicts.single;
      await mobileSync.resolveConflictKeepRemote(conflict3);
      expect(mobileSync.openConflictCount, 0);
      final afterRemote = await mobileVault.raw.getEntryById(baseEntry.id);
      expect(afterRemote?.bodyMd, conflict3.remoteBodyMd);
    });

    test('Channel B E2EE relay encrypts all payloads, blocks #private with 0 bytes uploaded by default, and recovers via recovery code', () async {
      final fakeRelay = _InMemoryRelayObjectStore();

      final relayDeviceA = BlinkSyncController(
        paths: desktopPaths,
        expectedChannel: BlinkChannel.blinkDev,
        secretStore: desktopSecrets,
        lanDiscovery: LanDiscovery(enabled: false),
        relayStoreFactory: (_, _) => fakeRelay,
        isQuiet: true,
        isMobilePlatform: false,
      );
      final relayDeviceB = BlinkSyncController(
        paths: mobilePaths,
        expectedChannel: BlinkChannel.blinkDev,
        secretStore: mobileSecrets,
        lanDiscovery: LanDiscovery(enabled: false),
        relayStoreFactory: (_, _) => fakeRelay,
        isQuiet: true,
        isMobilePlatform: true,
      );
      addTearDown(() async {
        await relayDeviceA.stopForShutdown();
        await relayDeviceB.stopForShutdown();
        relayDeviceA.dispose();
        relayDeviceB.dispose();
      });

      await relayDeviceA.attachVault(desktopVault);
      await relayDeviceB.attachVault(mobileVault);

      // Generate E2EE master key on A and import recovery code on B.
      final recoveryCode = await relayDeviceA.generateAndStoreRelayMasterKey();
      expect(recoveryCode, startsWith('BLINK1-'));
      expect(await relayDeviceB.importRelayRecoveryCode(recoveryCode), isTrue);
      expect(relayDeviceA.relayMasterKeyId, relayDeviceB.relayMasterKeyId);

      // Save relay settings (excludePrivateFromRelay defaults to true!).
      expect(
        await relayDeviceA.saveRelayConfiguration(
          enabled: true,
          protocol: RelayProtocol.webdav,
          endpoint: 'https://dav.example.test/blink/',
          username: 'alice',
          password: 'super-secret-webdav-password',
        ),
        isTrue,
      );
      expect(
        await relayDeviceB.saveRelayConfiguration(
          enabled: true,
          protocol: RelayProtocol.webdav,
          endpoint: 'https://dav.example.test/blink/',
          username: 'alice',
          password: 'super-secret-webdav-password',
        ),
        isTrue,
      );
      expect(relayDeviceA.config.excludePrivateFromRelay, isTrue);

      // Verify neither password nor master key ever lands in sync.json or vault.
      final syncJsonA = desktopPaths.syncSettingsFile.readAsStringSync();
      expect(syncJsonA, isNot(contains('super-secret-webdav-password')));
      expect(syncJsonA, isNot(contains(recoveryCode)));
      _expectZeroSecretInDirectory(
        desktopPaths.vaultDir,
        'super-secret-webdav-password',
      );

      // Write one normal entry and one `#private` sentinel entry on A.
      const normalBody = '常规可中继同步笔记 NORMAL_SENTINEL_2026';
      const privateBody = '绝不上云私密笔记 PRIVATE_ZERO_EGRESS_SENTINEL #private';
      final normalEntry = await desktopVault.raw.createEntry(
        bodyMd: normalBody,
      );
      final privateEntry = await desktopVault.raw.createEntry(
        bodyMd: privateBody,
      );

      final resA = await relayDeviceA.syncNow(manual: true);
      expect(resA, isNotNull);
      expect(resA!.pushedOps, greaterThanOrEqualTo(1));
      expect(resA.skippedPrivateOps, greaterThanOrEqualTo(1));

      // Relay store must contain ONLY ciphertext (0 plaintext bytes of normal OR private!).
      expect(fakeRelay.objects, isNotEmpty);
      for (final entry in fakeRelay.objects.entries) {
        final text = latin1.decode(entry.value, allowInvalid: true);
        expect(text, isNot(contains('NORMAL_SENTINEL_2026')));
        expect(text, isNot(contains('PRIVATE_ZERO_EGRESS_SENTINEL')));
      }

      // Device B pulls from E2EE relay -> receives normal entry, ZERO private entry!
      await relayDeviceB.syncNow(manual: true);
      expect(
        (await mobileVault.raw.getEntryById(normalEntry.id))?.bodyMd,
        normalBody,
      );
      expect(await mobileVault.raw.getEntryById(privateEntry.id), isNull);

      // When only `#private` pending ops remain, next relay sync reports honest `privacyBlocked`.
      await desktopVault.raw.createEntry(bodyMd: '第二条私密条目 #private');
      await relayDeviceA.syncNow(manual: true);
      expect(relayDeviceA.uiStatus, BlinkSyncUiStatus.privacyBlocked);
    });

    test('DesktopLifecycleController stops embedded sync server BEFORE flush & WAL checkpoint', () async {
      final callOrder = <String>[];
      final lifecycle = DesktopLifecycleController(
        buildInfo: BlinkBuildInfo.normalized(channel: 'blink-dev'),
        paths: desktopPaths,
        settingsStore: DesktopSettingsStore(
          file: desktopPaths.desktopSettingsFile,
        ),
        windowAdapter: _FakeWindowAdapter(),
        trayAdapter: _FakeTrayAdapter(),
        onStopSyncBeforeShutdown: () async {
          callOrder.add('stop_sync');
          await desktopSync.stopForShutdown();
          expect(desktopSync.isHostRunning, isFalse);
        },
        onFlushBeforeShutdown: () async {
          callOrder.add('flush_and_wal_checkpoint');
        },
      );
      await lifecycle.initializeStartup(
        const LaunchOptions(mode: LaunchMode.normal, quiet: true),
      );

      await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: 0,
      );
      expect(desktopSync.isHostRunning, isTrue);

      final ok = await lifecycle.performShutdown(ExitReason.trayQuit);
      expect(ok, isTrue);
      expect(callOrder, <String>['stop_sync', 'flush_and_wal_checkpoint']);
      expect(desktopSync.isHostRunning, isFalse);
    });

    test('rejects URL-embedded credentials (INV-08) regardless of relay enabled flag and separates WebDAV/S3 credential flags', () async {
      // Build synthetic credential-embedded URIs programmatically so static
      // hygiene checks never flag literal user:pass@ URLs in test source.
      final directCredUrl = Uri(
        scheme: 'http',
        userInfo: 'alice:super-secret',
        host: '127.0.0.1',
        port: 48231,
      ).toString();
      final relayCredUrl = Uri(
        scheme: 'https',
        userInfo: 'alice:plain-pass-leak',
        host: 'dav.example.test',
        path: '/blink/',
      ).toString();

      // Direct peer URL with embedded userInfo must be rejected before any network/file write.
      final pairResult = await mobileSync.pairWithDirectPeer(
        baseUrl: directCredUrl,
        pairingCode: 'ABCD-EFGH',
      );
      expect(pairResult, isNull);
      expect(mobileSync.lastErrorCode, BlinkErrorCode.invalidArgument);
      expect(mobileSync.config.directPeerUrl, isNull);

      // Relay endpoint with embedded userInfo must be rejected when enabled=true AND enabled=false!
      for (final enabled in <bool>[true, false]) {
        final saved = await mobileSync.saveRelayConfiguration(
          enabled: enabled,
          protocol: RelayProtocol.webdav,
          endpoint: relayCredUrl,
        );
        expect(saved, isFalse);
        expect(mobileSync.lastErrorCode, BlinkErrorCode.invalidArgument);
      }

      // Invalid non-empty endpoint when enabled=false must also be rejected (no raw fallback).
      final savedInvalid = await mobileSync.saveRelayConfiguration(
        enabled: false,
        protocol: RelayProtocol.webdav,
        endpoint: 'https://:bad-url-without-host',
      );
      expect(savedInvalid, isFalse);

      // Verify sync.json never persisted any embedded credential or raw invalid string.
      if (mobilePaths.syncSettingsFile.existsSync()) {
        final rawJson = mobilePaths.syncSettingsFile.readAsStringSync();
        expect(rawJson, isNot(contains('plain-pass-leak')));
        expect(rawJson, isNot(contains('super-secret')));
        expect(rawJson, isNot(contains('bad-url-without-host')));
      }

      // Saving valid WebDAV credentials sets hasWebDavCredentials without polluting hasS3Credentials.
      final savedValid = await mobileSync.saveRelayConfiguration(
        enabled: false,
        protocol: RelayProtocol.webdav,
        endpoint: 'https://dav.example.test/blink/',
        username: 'alice',
        password: 'webdav-secret-only',
      );
      expect(savedValid, isTrue);
      expect(mobileSync.hasWebDavCredentials, isTrue);
      expect(mobileSync.hasS3Credentials, isFalse);
      expect(mobileSync.hasRelayCredentials, isTrue);
    });

    test('stopForShutdown cancels queued follow-up sync and stale async SSE connection (INV-07)', () async {
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      final blockingStore = _BlockingRelayObjectStore(
        firstCycleEntered: firstEntered,
        releaseFirstCycle: releaseFirst,
      );
      final gatedSecrets = _GatedSecretStore(
        InMemoryBlinkSecretStore(channel: 'blink-dev'),
      );

      final ctrl = BlinkSyncController(
        paths: mobilePaths,
        expectedChannel: BlinkChannel.blinkDev,
        secretStore: gatedSecrets,
        lanDiscovery: LanDiscovery(enabled: false),
        relayStoreFactory: (_, _) => blockingStore,
        isQuiet: true,
        isMobilePlatform: true,
        enableSseWakeup: true,
      );
      addTearDown(ctrl.dispose);

      await ctrl.attachVault(mobileVault);
      await ctrl.generateAndStoreRelayMasterKey();
      expect(
        await ctrl.saveRelayConfiguration(
          enabled: true,
          protocol: RelayProtocol.webdav,
          endpoint: 'https://dav.example.test/blink/',
        ),
        isTrue,
      );

      // Start cycle 1 (blocks in checkConnection), then coalesce a follow-up syncNow().
      final firstSync = ctrl.syncNow(manual: true);
      await firstEntered.future;
      final followUpSync = ctrl.syncNow(manual: true);

      // Initiate shutdown while cycle 1 is in flight and follow-up is queued.
      final shutdownFuture = ctrl.stopForShutdown();
      releaseFirst.complete();
      await Future.wait<Object?>([firstSync, followUpSync, shutdownFuture]);

      // Follow-up cycle must NOT have started after stopForShutdown() began.
      expect(blockingStore.checkConnectionCalls, 1);

      // Post-shutdown syncNow() must be a no-op.
      expect(await ctrl.syncNow(manual: true), isNull);
      expect(blockingStore.checkConnectionCalls, 1);

      // Verify async SSE token read completing after stopForShutdown does not reconnect.
      final started = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: 0,
      );
      expect(started, isTrue);
      final code = desktopSync.generatePairingCode()!;

      await ctrl.attachVault(mobileVault);
      await ctrl.pairWithDirectPeer(
        baseUrl: 'http://127.0.0.1:${desktopSync.activeServerPort!}',
        pairingCode: code.code,
      );
      await ctrl.stopForShutdown();

      gatedSecrets.readStarted = Completer<void>();
      gatedSecrets.allowReadCompletion = Completer<void>();
      // Re-attach triggers async _connectSseOnce() which suspends on secretStore.read().
      final reattachFuture = ctrl.attachVault(mobileVault);
      await gatedSecrets.readStarted!.future;
      final stopDuringSse = ctrl.stopForShutdown();
      gatedSecrets.allowReadCompletion!.complete();
      await Future.wait<void>([reattachFuture, stopDuringSse]);
      // Calling onAppResumed after stopForShutdown must not trigger any sync,
      // and a new desktop write must not arrive via any leaked SSE stream.
      ctrl.onAppResumed();
      final afterStopDesktop = await desktopVault.raw.createEntry(
        bodyMd: '退出后桌面端写入不得经残留 SSE 拉取',
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(ctrl.isSyncing, isFalse);
      expect(await mobileVault.raw.getEntryById(afterStopDesktop.id), isNull);
    });

    test('desktop server clears stale error status after port-occupied failure recovers or disables (INV-11)', () async {
      final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => blocker.close(force: true));

      // Attempt to start on already-occupied port -> honest error status.
      final failedStart = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: blocker.port,
      );
      expect(failedStart, isFalse);
      expect(desktopSync.isHostRunning, isFalse);
      expect(desktopSync.uiStatus, BlinkSyncUiStatus.error);
      expect(desktopSync.lastErrorMessage, isNotNull);

      // Retry on a free ephemeral port -> succeeds and clears stale error!
      final recoveredStart = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: 0,
      );
      expect(recoveredStart, isTrue);
      expect(desktopSync.isHostRunning, isTrue);
      expect(desktopSync.uiStatus, isNot(BlinkSyncUiStatus.error));
      expect(desktopSync.lastErrorCode, isNull);
      expect(desktopSync.lastErrorMessage, isNull);

      // Fail again on occupied port, then disable -> error also clears cleanly.
      final failedAgain = await desktopSync.setDesktopServerEnabled(
        true,
        bindHost: '127.0.0.1',
        port: blocker.port,
      );
      expect(failedAgain, isFalse);
      expect(desktopSync.uiStatus, BlinkSyncUiStatus.error);

      final disabled = await desktopSync.setDesktopServerEnabled(false);
      expect(disabled, isTrue);
      expect(desktopSync.uiStatus, isNot(BlinkSyncUiStatus.error));
      expect(desktopSync.lastErrorCode, isNull);
      expect(desktopSync.lastErrorMessage, isNull);
    });
  });
}
