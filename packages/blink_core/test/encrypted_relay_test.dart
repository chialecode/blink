import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_relay_sync_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group(
    'AC-05 & INV-03: E2EE WebDAV Async Relay & 0-Byte #private Sentinel',
    () {
      test('syncs E2EE batches/blobs with zero plaintext, enforces 0-byte #private exclusion, and recovers on new device', () async {
        final fakeDav = _FakeLoopbackWebDavServer(
          username: 'blink-user',
          password: 'synthetic-dav-password',
        );
        await fakeDav.start();
        addTearDown(fakeDav.stop);

        final cryptoEngine = SyncCrypto();
        final masterKey = cryptoEngine.generateMasterKey();
        final recoveryCode = cryptoEngine.encodeRecoveryCode(masterKey);

        final vaultA = await _openTempVault(tempRoot, 'dav-a', 'Phone-A');
        final vaultB = await _openTempVault(tempRoot, 'dav-b', 'New-Laptop-B');
        addTearDown(vaultA.checkpointAndClose);
        addTearDown(vaultB.checkpointAndClose);

        final davClientA = WebDavClient(
          baseUri: fakeDav.baseUri,
          username: 'blink-user',
          password: 'synthetic-dav-password',
        );
        final relayA = EncryptedRelayTransport(
          store: davClientA,
          masterKey: masterKey,
          localVaultId: vaultA.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultA.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultA.syncEngine,
        );
        addTearDown(relayA.close);

        // 1. Create a normal entry + attachment blob on Device A and sync to WebDAV relay.
        final normalBlobBytes = Uint8List.fromList(
          utf8.encode('NORMAL_ATTACHMENT_CONTENT_SENTINEL_12345'),
        );
        final normalBlob = await vaultA.blobs.putBytes(
          normalBlobBytes,
          mimeType: 'text/plain',
        );
        final normalEntry = await vaultA.raw.createEntry(
          bodyMd: '公开中继笔记 PLAINTEXT_SENTINEL_WEBDAV_42 #同步',
          imageBlobSha256s: <String>[normalBlob.sha256],
        );

        final run1 = await vaultA.syncEngine.syncWithTransport(relayA);
        expect(run1.pushedOps, equals(1));
        expect(run1.blobsUploaded, equals(1));
        expect(run1.skippedPrivateOps, equals(0));
        expect(vaultA.pendingOutboxCount, equals(0));

        // 2. Zero-plaintext inspection of EVERY stored WebDAV key and payload (`AC-05`).
        expect(fakeDav.objects.keys, isNotEmpty);
        expect(
          fakeDav.objects.keys.any((k) => k.contains('blink.db')),
          isFalse,
        );
        expect(
          fakeDav.objects.keys.any((k) => k.contains(normalBlob.sha256)),
          isFalse,
        );
        for (final entry in fakeDav.objects.entries) {
          final asText = utf8.decode(entry.value, allowMalformed: true);
          expect(asText, isNot(contains('PLAINTEXT_SENTINEL_WEBDAV_42')));
          expect(asText, isNot(contains('公开中继笔记')));
          expect(asText, isNot(contains('NORMAL_ATTACHMENT_CONTENT_SENTINEL')));
          expect(asText, isNot(contains(normalEntry.id)));
        }

        // 3. 0-BYTE #private RELAY EXCLUSION SENTINEL (`INV-03`, `AC-05`)!
        fakeDav.resetWriteCounters();
        final privBlob = await vaultA.blobs.putBytes(
          Uint8List.fromList(utf8.encode('PRIVATE_BINARY_SECRET_999')),
          mimeType: 'application/octet-stream',
        );
        final privEntry = await vaultA.raw.createEntry(
          bodyMd: '绝密个人日记 PRIVATE_ZERO_EGRESS_SENTINEL_99 #private',
          imageBlobSha256s: <String>[privBlob.sha256],
        );

        // Also create a normal entry offline and promote it to `#private` BEFORE syncing!
        final promotedEntry = await vaultA.raw.createEntry(
          bodyMd: '最初公开但随后加密的条目 PROMOTED_PRIVATE_SENTINEL_77',
        );
        await vaultA.raw.updateEntry(
          id: promotedEntry.id,
          bodyMd: '升级私密 PROMOTED_PRIVATE_SENTINEL_77 #private',
        );

        final privRun = await vaultA.syncEngine.syncWithTransport(relayA);
        expect(privRun.pushedOps, equals(0));
        expect(privRun.blobsUploaded, equals(0));
        expect(privRun.skippedPrivateOps, equals(3));
        // HARD ASSERTION: 0 PUT requests and 0 bytes uploaded to cloud relay!
        expect(fakeDav.putRequestCount, equals(0));
        expect(fakeDav.putTotalBytes, equals(0));
        // Private ops stay pending in local outbox so Direct LAN sync still delivers them!
        expect(vaultA.pendingOutboxCount, equals(3));

        // 4. Brand-new Device B imports ONLY the printable Recovery Code -> full E2EE convergence!
        final recoveredKey = cryptoEngine.decodeRecoveryCode(recoveryCode);
        final davClientB = WebDavClient(
          baseUri: fakeDav.baseUri,
          username: 'blink-user',
          password: 'synthetic-dav-password',
        );
        final relayB = EncryptedRelayTransport(
          store: davClientB,
          masterKey: recoveredKey,
          localVaultId: vaultB.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultB.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultB.syncEngine,
        );
        addTearDown(relayB.close);

        final recoverRun = await vaultB.syncEngine.syncWithTransport(relayB);
        expect(recoverRun.appliedOps, equals(1));
        expect(recoverRun.blobsDownloaded, equals(1));
        expect(
          (await vaultB.raw.getEntryById(normalEntry.id))?.bodyMd,
          equals(normalEntry.bodyMd),
        );
        expect(
          await vaultB.blobs.readBytes(normalBlob.sha256),
          equals(normalBlobBytes),
        );
        // Private entries never went to relay -> absent on B until Direct LAN sync!
        expect(await vaultB.raw.getEntryById(privEntry.id), isNull);
        expect(await vaultB.raw.getEntryById(promotedEntry.id), isNull);

        // 5. Wrong recovery key & wrong channel are rejected cleanly.
        final wrongKeyRelay = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: cryptoEngine.generateMasterKey(),
          localVaultId: vaultB.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: generateUuidV7(),
        );
        addTearDown(wrongKeyRelay.close);
        await expectLater(
          () => wrongKeyRelay.checkHealth(),
          throwsA(
            isA<BlinkException>().having(
              (e) => e.code,
              'code',
              BlinkErrorCode.authRequired,
            ),
          ),
        );

        final wrongChannelRelay = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: recoveredKey,
          localVaultId: vaultB.metadata.vaultId,
          expectedChannel: BlinkChannel.blink,
          localDeviceId: generateUuidV7(),
        );
        addTearDown(wrongChannelRelay.close);
        await expectLater(
          () => wrongChannelRelay.checkHealth(),
          throwsA(
            isA<BlinkException>().having(
              (e) => e.code,
              'code',
              BlinkErrorCode.channelMismatch,
            ),
          ),
        );

        // 6. Now connect Device A & Device B via Direct LAN -> `#private` entries sync cleanly!
        final directServer = DirectShelfServer(vault: vaultB);
        await directServer.start(host: '127.0.0.1', port: 0);
        addTearDown(directServer.stop);

        final code = directServer.createPairingCode();
        final unauth = DirectShelfTransport(
          baseUri: directServer.baseUri,
          expectedChannel: BlinkChannel.blinkDev,
        );
        addTearDown(unauth.close);
        final paired = await unauth.pair(
          pairingCode: code.code,
          deviceId: vaultA.localDeviceId,
          deviceName: vaultA.localDeviceName,
        );
        final directA = unauth.withDeviceToken(paired.deviceToken);
        addTearDown(directA.close);

        await vaultA.syncEngine.syncWithTransport(directA);
        expect(vaultA.pendingOutboxCount, equals(0));
        expect(
          (await vaultB.raw.getEntryById(privEntry.id))?.privacyLevel,
          equals(PrivacyLevel.private),
        );
        expect(
          (await vaultB.raw.getEntryById(promotedEntry.id))?.privacyLevel,
          equals(PrivacyLevel.private),
        );
        expect(
          await vaultB.blobs.readBytes(privBlob.sha256),
          equals(utf8.encode('PRIVATE_BINARY_SECRET_999')),
        );
      });

      test('blocks #private leakage across orphan tasks, purged entries, ai_synthesis, and excludePrivate=false override, and backfills when relay switch toggles off (INV-03, INV-05)', () async {
        final fakeDav = _FakeLoopbackWebDavServer(
          username: 'blink-user',
          password: 'synthetic-dav-password',
        );
        await fakeDav.start();
        addTearDown(fakeDav.stop);

        final masterKey = SyncCrypto().generateMasterKey();
        final vaultA = await _openTempVault(tempRoot, 'priv-hard-a', 'Phone-A');
        final vaultB = await _openTempVault(
          tempRoot,
          'priv-hard-b',
          'Laptop-B',
        );
        addTearDown(vaultB.checkpointAndClose);

        const sharedTransportId = 'relay:dav-toggle-test';
        final strictRelayA = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: masterKey,
          localVaultId: vaultA.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultA.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultA.syncEngine,
          transportId: sharedTransportId,
        );
        addTearDown(strictRelayA.close);

        // Initialize vault.meta.enc via a baseline normal sync.
        final baselineEntry = await vaultA.raw.createEntry(
          bodyMd: '公开基线笔记 BASELINE_NORMAL',
        );
        await vaultA.syncEngine.syncWithTransport(strictRelayA);
        fakeDav.resetWriteCounters();

        // Path A (P0): normal entry with task -> toggle task -> promote to #private & remove task (orphan soft-delete).
        final taskEntry = await vaultA.raw.createEntry(
          bodyMd: '待升级笔记\n- [ ] 敏感任务 ORPHAN_PRIVATE_TASK_88',
        );
        final task = (await vaultA.raw.listTasks()).single;
        await vaultA.raw.toggleTaskStatus(task.id);
        await vaultA.raw.updateEntry(
          id: taskEntry.id,
          bodyMd: '已移除子任务并升级私密 ORPHAN_PRIVATE_BODY_88 #private',
        );

        // Path B (P0): normal entry with blob promoted to #private then permanently purged.
        final purgedBlob = await vaultA.blobs.putBytes(
          Uint8List.fromList(utf8.encode('PURGED_PRIVATE_BLOB_77')),
          mimeType: 'application/octet-stream',
        );
        final purgedEntry = await vaultA.raw.createEntry(
          bodyMd: '将要清空的普通笔记',
          imageBlobSha256s: <String>[purgedBlob.sha256],
        );
        await vaultA.raw.updateEntry(
          id: purgedEntry.id,
          bodyMd: '升级后永久清空 PURGED_PRIVATE_BODY_77 #private',
        );
        await vaultA.raw.purgeEntryPermanently(purgedEntry.id);

        // Path C (P0): active #private entry + attachment blob, synced with explicit `excludePrivate: false`
        // against a relay configured with `excludePrivateFromRelay: true` -> MUST NOT bypass!
        final privBlob = await vaultA.blobs.putBytes(
          Uint8List.fromList(utf8.encode('STRICT_PRIVATE_BLOB_55')),
          mimeType: 'application/octet-stream',
        );
        final strictPrivEntry = await vaultA.raw.createEntry(
          bodyMd: '严格本地私密 STRICT_PRIVATE_BODY_55 #private',
          imageBlobSha256s: <String>[privBlob.sha256],
        );

        // Path D (P0): ai_synthesis with `privacy_scope = 'local_with_private'` (even if oplog privacy_level was 'normal').
        final synthId = generateUuidV7();
        final synthOpId = generateUuidV7();
        final synthNow = DateTime.now().toUtc().toIso8601String();
        final synthPayload = jsonEncode(<String, Object?>{
          'synth_kind': 'morning_brief',
          'period_key': '2026-11-27',
          'title': '私密总结',
          'summary_md': 'LOCAL_WITH_PRIVATE_SYNTH_99',
          'view_html': '<p>LOCAL_WITH_PRIVATE_SYNTH_99</p>',
        });
        final localDeviceIdA = vaultA.localDeviceId;
        await vaultA.checkpointAndClose();

        final rawDbPath = p.join(
          tempRoot.path,
          'priv-hard-a',
          'db',
          'blink.db',
        );
        final directDb = sq.sqlite3.open(rawDbPath);
        try {
          directDb.execute(
            "INSERT INTO ai_syntheses (id, synth_kind, period_key, title, privacy_scope, render_surface, summary_md, view_html, citations_json, model_id, source_agent, computed_at) "
            "VALUES (?, 'morning_brief', '2026-11-27', '私密总结', 'local_with_private', 'surface1_native', 'LOCAL_WITH_PRIVATE_SYNTH_99', '<p>ok</p>', '[]', 'm', 'a', ?)",
            <Object?>[synthId, synthNow],
          );
          directDb.execute(
            "INSERT INTO sync_oplog (device_id, client_op_id, hlc_ts, base_revision, entity_layer, entity_type, entity_id, op_type, op_origin, privacy_level, payload_json, created_at) "
            "VALUES (?, ?, '2026-11-27T10:00:00.000Z-0000-00000001', 0, 'ai', 'ai_synthesis', ?, 'upsert', 'mcp_capture', 'normal', ?, ?)",
            <Object?>[
              localDeviceIdA,
              synthOpId,
              synthId,
              synthPayload,
              synthNow,
            ],
          );
          directDb.execute(
            "INSERT INTO outbox_ops (client_op_id, device_id, hlc_ts, base_revision, entity_layer, entity_type, entity_id, op_type, privacy_level, payload_json, status, created_at) "
            "VALUES (?, ?, '2026-11-27T10:00:00.000Z-0000-00000001', 0, 'ai', 'ai_synthesis', ?, 'upsert', 'normal', ?, 'pending', ?)",
            <Object?>[
              synthOpId,
              localDeviceIdA,
              synthId,
              synthPayload,
              synthNow,
            ],
          );
        } finally {
          directDb.close();
        }

        final vaultAReopened = await _openTempVault(
          tempRoot,
          'priv-hard-a',
          'Phone-A',
        );
        addTearDown(vaultAReopened.checkpointAndClose);

        final strictRelayA2 = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: masterKey,
          localVaultId: vaultAReopened.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultAReopened.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultAReopened.syncEngine,
          transportId: sharedTransportId,
        );
        addTearDown(strictRelayA2.close);

        // Even with explicit `excludePrivate: false`, relay's `excludePrivateFromRelay: true`
        // MUST NOT be bypassed -> 0 PUT requests and 0 bytes uploaded!
        final blockedRun = await vaultAReopened.syncEngine.syncWithTransport(
          strictRelayA2,
          excludePrivate: false,
        );
        expect(blockedRun.pushedOps, equals(0));
        expect(blockedRun.blobsUploaded, equals(0));
        expect(blockedRun.skippedPrivateOps, greaterThanOrEqualTo(6));
        expect(fakeDav.putRequestCount, equals(0));
        expect(fakeDav.putTotalBytes, equals(0));
        // All skipped private ops MUST remain pending in `outbox_ops`!
        expect(vaultAReopened.pendingOutboxCount, greaterThanOrEqualTo(6));

        // P1 Toggle Switch: user explicitly opts in (`excludePrivateFromRelay: false`)
        // on the SAME transportId -> historical `#private` ops AND blobs MUST backfill!
        final optInRelayA = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: masterKey,
          localVaultId: vaultAReopened.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultAReopened.localDeviceId,
          excludePrivateFromRelay: false,
          stateStore: vaultAReopened.syncEngine,
          transportId: sharedTransportId,
        );
        addTearDown(optInRelayA.close);

        final backfillRun = await vaultAReopened.syncEngine.syncWithTransport(
          optInRelayA,
        );
        expect(backfillRun.pushedOps, greaterThanOrEqualTo(6));
        expect(
          backfillRun.blobsUploaded,
          equals(1),
        ); // strictPrivEntry's active privBlob
        expect(vaultAReopened.pendingOutboxCount, equals(0));

        // Device B pulls from relay and receives baseline + backfilled `#private` entry & blob!
        final relayB = EncryptedRelayTransport(
          store: WebDavClient(
            baseUri: fakeDav.baseUri,
            username: 'blink-user',
            password: 'synthetic-dav-password',
          ),
          masterKey: masterKey,
          localVaultId: vaultB.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultB.localDeviceId,
          excludePrivateFromRelay: false,
          stateStore: vaultB.syncEngine,
          transportId: sharedTransportId,
        );
        addTearDown(relayB.close);

        await vaultB.syncEngine.syncWithTransport(relayB);
        expect(
          (await vaultB.raw.getEntryById(baselineEntry.id))?.bodyMd,
          equals(baselineEntry.bodyMd),
        );
        final syncedPriv = await vaultB.raw.getEntryById(strictPrivEntry.id);
        expect(syncedPriv, isNotNull);
        expect(syncedPriv!.privacyLevel, equals(PrivacyLevel.private));
        expect(
          await vaultB.blobs.readBytes(privBlob.sha256),
          equals(utf8.encode('STRICT_PRIVATE_BLOB_55')),
        );
        final syncedTaskEntry = await vaultB.raw.getEntryById(taskEntry.id);
        expect(syncedTaskEntry!.privacyLevel, equals(PrivacyLevel.private));
      });
    },
  );

  group(
    'AC-05 & INV-03: E2EE S3 Async Relay (SigV4 + Pagination + Zero Plaintext)',
    () {
      test('converges across two devices via loopback SigV4 S3 relay with zero plaintext and 0-byte #private exclusion', () async {
        final fakeS3 = _FakeLoopbackS3Server(
          bucket: 'blink-relay-test',
          accessKeyId: 'BLINK_SYNTHETIC_ACCESS_KEY',
          maxKeysPerPage: 2,
        );
        await fakeS3.start();
        addTearDown(fakeS3.stop);

        final masterKey = SyncCrypto().generateMasterKey();
        final vaultA = await _openTempVault(tempRoot, 's3-a', 'Desktop-S3');
        final vaultB = await _openTempVault(tempRoot, 's3-b', 'Phone-S3');
        addTearDown(vaultA.checkpointAndClose);
        addTearDown(vaultB.checkpointAndClose);

        final relayA = EncryptedRelayTransport(
          store: S3Client(
            endpoint: fakeS3.baseUri,
            bucket: 'blink-relay-test',
            region: 'us-east-1',
            accessKeyId: 'BLINK_SYNTHETIC_ACCESS_KEY',
            secretAccessKey: 'synthetic-s3-secret-key-for-tests',
            keyPrefix: 'vault-prefix',
          ),
          masterKey: masterKey,
          localVaultId: vaultA.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultA.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultA.syncEngine,
        );
        final relayB = EncryptedRelayTransport(
          store: S3Client(
            endpoint: fakeS3.baseUri,
            bucket: 'blink-relay-test',
            region: 'us-east-1',
            accessKeyId: 'BLINK_SYNTHETIC_ACCESS_KEY',
            secretAccessKey: 'synthetic-s3-secret-key-for-tests',
            keyPrefix: 'vault-prefix',
          ),
          masterKey: masterKey,
          localVaultId: vaultB.metadata.vaultId,
          expectedChannel: BlinkChannel.blinkDev,
          localDeviceId: vaultB.localDeviceId,
          excludePrivateFromRelay: true,
          stateStore: vaultB.syncEngine,
        );
        addTearDown(relayA.close);
        addTearDown(relayB.close);

        // Create multiple batches on A to exercise S3 ListObjectsV2 pagination!
        final e1 = await vaultA.raw.createEntry(
          bodyMd: 'S3 批次一 S3_SENTINEL_ALPHA',
        );
        await vaultA.syncEngine.syncWithTransport(relayA);
        final e2 = await vaultA.raw.createEntry(
          bodyMd: 'S3 批次二 S3_SENTINEL_BETA',
        );
        await vaultA.syncEngine.syncWithTransport(relayA);
        final e3 = await vaultA.raw.createEntry(
          bodyMd: 'S3 批次三 S3_SENTINEL_GAMMA',
        );
        await vaultA.syncEngine.syncWithTransport(relayA);

        // Verify 0-byte `#private` sentinel on S3 relay.
        fakeS3.resetWriteCounters();
        await vaultA.raw.createEntry(
          bodyMd: 'S3 私密条目 S3_PRIVATE_SENTINEL #private',
        );
        final privRes = await vaultA.syncEngine.syncWithTransport(relayA);
        expect(privRes.skippedPrivateOps, equals(1));
        expect(fakeS3.putRequestCount, equals(0));
        expect(fakeS3.putTotalBytes, equals(0));

        // Verify ZERO plaintext across all S3 stored objects.
        for (final bytes in fakeS3.objects.values) {
          final text = utf8.decode(bytes, allowMalformed: true);
          expect(text, isNot(contains('S3_SENTINEL_ALPHA')));
          expect(text, isNot(contains('S3_SENTINEL_BETA')));
          expect(text, isNot(contains('S3_SENTINEL_GAMMA')));
          expect(text, isNot(contains('S3_PRIVATE_SENTINEL')));
        }

        // Device B pulls all 3 paginated batches and converges!
        final bEntry = await vaultB.raw.createEntry(bodyMd: 'B 端并发新笔记');
        final pullRes = await vaultB.syncEngine.syncWithTransport(relayB);
        expect(pullRes.appliedOps, equals(3));
        expect(
          (await vaultB.raw.getEntryById(e1.id))?.bodyMd,
          equals(e1.bodyMd),
        );
        expect(
          (await vaultB.raw.getEntryById(e2.id))?.bodyMd,
          equals(e2.bodyMd),
        );
        expect(
          (await vaultB.raw.getEntryById(e3.id))?.bodyMd,
          equals(e3.bodyMd),
        );

        // Device A pulls B's new note back.
        final aPull = await vaultA.syncEngine.syncWithTransport(relayA);
        expect(aPull.appliedOps, equals(1));
        expect(
          (await vaultA.raw.getEntryById(bEntry.id))?.bodyMd,
          equals(bEntry.bodyMd),
        );
      });
    },
  );
}

Future<VaultManager> _openTempVault(
  Directory root,
  String name,
  String deviceName,
) => VaultManager.open(
  VaultConfig(
    vaultDir: Directory(p.join(root.path, name)),
    expectedChannel: BlinkChannel.blinkDev,
    deviceName: deviceName,
    enableMirrorExporter: false,
  ),
);

/// Minimal quiet loopback-only RFC 4918 WebDAV test server (`127.0.0.1:0`).
final class _FakeLoopbackWebDavServer {
  _FakeLoopbackWebDavServer({required this.username, required this.password});

  final String username;
  final String password;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Set<String> collections = <String>{''};

  HttpServer? _server;
  int putRequestCount = 0;
  int putTotalBytes = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server!.port}/dav/');

  void resetWriteCounters() {
    putRequestCount = 0;
    putTotalBytes = 0;
  }

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final expectedAuth =
        'Basic ${base64Encode(utf8.encode('$username:$password'))}';
    if (req.headers.value(HttpHeaders.authorizationHeader) != expectedAuth) {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }

    var rel = req.uri.path;
    if (rel.startsWith('/dav/')) {
      rel = rel.substring('/dav/'.length);
    } else if (rel == '/dav') {
      rel = '';
    }
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    final cleanRel = rel.endsWith('/') ? rel.substring(0, rel.length - 1) : rel;

    switch (req.method) {
      case 'MKCOL':
        collections.add(cleanRel);
        req.response.statusCode = 201;
        await req.response.close();
      case 'PUT':
        final builder = BytesBuilder(copy: false);
        await for (final chunk in req) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        putRequestCount += 1;
        putTotalBytes += bytes.length;
        objects[cleanRel] = bytes;
        // Record ancestor collections automatically.
        final parts = cleanRel.split('/');
        for (var i = 1; i < parts.length; i++) {
          collections.add(parts.sublist(0, i).join('/'));
        }
        req.response.statusCode = 201;
        await req.response.close();
      case 'HEAD':
        req.response.statusCode = objects.containsKey(cleanRel) ? 200 : 404;
        await req.response.close();
      case 'GET':
        final data = objects[cleanRel];
        if (data == null) {
          req.response.statusCode = 404;
        } else {
          req.response.statusCode = 200;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        objects.remove(cleanRel);
        req.response.statusCode = 204;
        await req.response.close();
      case 'PROPFIND':
        await req.drain<void>();
        final depth = req.headers.value('depth') ?? '1';
        if (!collections.contains(cleanRel) && !objects.containsKey(cleanRel)) {
          req.response.statusCode = 404;
          await req.response.close();
          return;
        }
        final xml = StringBuffer(
          '<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">',
        );
        void addResp(String pathKey, {required bool isDir}) {
          final href = pathKey.isEmpty
              ? '/dav/'
              : (isDir ? '/dav/$pathKey/' : '/dav/$pathKey');
          final typeXml = isDir ? '<d:collection/>' : '';
          xml.write(
            '<d:response><d:href>$href</d:href>'
            '<d:propstat><d:prop><d:resourcetype>$typeXml</d:resourcetype></d:prop>'
            '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }

        addResp(cleanRel, isDir: collections.contains(cleanRel));
        if (depth != '0' && collections.contains(cleanRel)) {
          final prefix = cleanRel.isEmpty ? '' : '$cleanRel/';
          for (final dir in collections) {
            if (dir.isEmpty || !dir.startsWith(prefix)) {
              continue;
            }
            final rest = dir.substring(prefix.length);
            if (rest.isNotEmpty && !rest.contains('/')) {
              addResp(dir, isDir: true);
            }
          }
          for (final key in objects.keys) {
            if (!key.startsWith(prefix)) {
              continue;
            }
            final rest = key.substring(prefix.length);
            if (rest.isNotEmpty && !rest.contains('/')) {
              addResp(key, isDir: false);
            }
          }
        }
        xml.write('</d:multistatus>');
        req.response.statusCode = 207;
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          'application/xml; charset=utf-8',
        );
        req.response.write(xml.toString());
        await req.response.close();
      default:
        req.response.statusCode = 405;
        await req.response.close();
    }
  }
}

/// Minimal quiet loopback-only S3-compatible test server (`127.0.0.1:0`) with SigV4 header validation.
final class _FakeLoopbackS3Server {
  _FakeLoopbackS3Server({
    required this.bucket,
    required this.accessKeyId,
    this.maxKeysPerPage = 1000,
  });

  final String bucket;
  final String accessKeyId;
  final int maxKeysPerPage;
  final Map<String, Uint8List> objects = <String, Uint8List>{};

  HttpServer? _server;
  int putRequestCount = 0;
  int putTotalBytes = 0;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server!.port}');

  void resetWriteCounters() {
    putRequestCount = 0;
    putTotalBytes = 0;
  }

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final amzDate = req.headers.value('x-amz-date') ?? '';
    final contentSha = req.headers.value('x-amz-content-sha256') ?? '';
    if (!auth.startsWith('AWS4-HMAC-SHA256 Credential=$accessKeyId/') ||
        amzDate.isEmpty ||
        contentSha.isEmpty) {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }

    final bucketPrefix = '/$bucket';
    if (!req.uri.path.startsWith(bucketPrefix)) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }

    var key = req.uri.path.substring(bucketPrefix.length);
    if (key.startsWith('/')) {
      key = key.substring(1);
    }

    if (req.method == 'GET' && req.uri.queryParameters['list-type'] == '2') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final token =
          int.tryParse(req.uri.queryParameters['continuation-token'] ?? '') ??
          0;
      final maxKeys =
          int.tryParse(req.uri.queryParameters['max-keys'] ?? '') ??
          maxKeysPerPage;
      final effectivePageSize = maxKeys < maxKeysPerPage
          ? maxKeys
          : maxKeysPerPage;
      final matching = objects.keys.where((k) => k.startsWith(prefix)).toList()
        ..sort();
      final page = matching.skip(token).take(effectivePageSize).toList();
      final nextOffset = token + page.length;
      final isTruncated = nextOffset < matching.length;

      final xml = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        '<Name>$bucket</Name>'
        '<IsTruncated>$isTruncated</IsTruncated>',
      );
      if (isTruncated) {
        xml.write('<NextContinuationToken>$nextOffset</NextContinuationToken>');
      }
      for (final k in page) {
        xml.write(
          '<Contents><Key>$k</Key><Size>${objects[k]!.length}</Size></Contents>',
        );
      }
      xml.write('</ListBucketResult>');

      req.response.statusCode = 200;
      req.response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/xml; charset=utf-8',
      );
      req.response.write(xml.toString());
      await req.response.close();
      return;
    }

    switch (req.method) {
      case 'PUT':
        final builder = BytesBuilder(copy: false);
        await for (final chunk in req) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        putRequestCount += 1;
        putTotalBytes += bytes.length;
        objects[key] = bytes;
        req.response.statusCode = 200;
        await req.response.close();
      case 'HEAD':
        req.response.statusCode = objects.containsKey(key) ? 200 : 404;
        await req.response.close();
      case 'GET':
        final data = objects[key];
        if (data == null) {
          req.response.statusCode = 404;
        } else {
          req.response.statusCode = 200;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        objects.remove(key);
        req.response.statusCode = 204;
        await req.response.close();
      default:
        req.response.statusCode = 405;
        await req.response.close();
    }
  }
}
