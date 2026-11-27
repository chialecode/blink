import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:blink_core/blink_core.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_direct_sync_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('AC-04: Direct LAN/Tailscale shelf Sync, Pairing, Revocation, SSE & Range Blobs', () {
    test('pairs with single-use code, hashes token in DB (INV-08), syncs ops/blobs with Range & SSE, and revokes cleanly', () async {
      final serverVaultDir = Directory(p.join(tempRoot.path, 'server-vault'));
      final clientVaultDir = Directory(p.join(tempRoot.path, 'client-vault'));

      final serverVault = await VaultManager.open(
        VaultConfig(
          vaultDir: serverVaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          deviceName: 'Desktop-Host',
          enableMirrorExporter: false,
        ),
      );
      final clientVault = await VaultManager.open(
        VaultConfig(
          vaultDir: clientVaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          deviceName: 'Mobile-Peer',
          enableMirrorExporter: false,
        ),
      );
      final server = DirectShelfServer(vault: serverVault);
      await server.start(host: '127.0.0.1', port: 0);

      addTearDown(() async {
        await server.stop();
        await clientVault.checkpointAndClose();
        await serverVault.checkpointAndClose();
      });

      final unauthTransport = DirectShelfTransport(
        baseUri: server.baseUri,
        expectedChannel: BlinkChannel.blinkDev,
      );
      addTearDown(unauthTransport.close);

      // 1. Health check works without authentication.
      final health = await unauthTransport.checkHealth();
      expect(health.channel, equals(BlinkChannel.blinkDev));
      expect(health.protocolVersion, equals(currentSyncProtocolVersion));
      expect(health.vaultId, equals(serverVault.metadata.vaultId));

      // 2. Unauthenticated pull is rejected with authRequired.
      await expectLater(
        () => unauthTransport.pullOps(sinceSeq: 0),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );

      // 3. Channel mismatch & protocol mismatch guards (`INV-06`).
      final wrongChannelTransport = DirectShelfTransport(
        baseUri: server.baseUri,
        expectedChannel: BlinkChannel.blink,
      );
      addTearDown(wrongChannelTransport.close);
      await expectLater(
        () => wrongChannelTransport.checkHealth(),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.channelMismatch,
          ),
        ),
      );

      final wrongProtoTransport = DirectShelfTransport(
        baseUri: server.baseUri,
        expectedChannel: BlinkChannel.blinkDev,
        protocolVersion: 1,
      );
      addTearDown(wrongProtoTransport.close);
      await expectLater(
        () => wrongProtoTransport.pair(
          pairingCode: '0000-0000',
          deviceId: clientVault.localDeviceId,
          deviceName: 'Mobile-Peer',
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.protocolMismatch,
          ),
        ),
      );

      // 4. Single-use pairing code exchange (and expired code rejection).
      final expiredCode = server.createPairingCode(ttl: Duration.zero);
      await expectLater(
        () => unauthTransport.pair(
          pairingCode: expiredCode.code,
          deviceId: clientVault.localDeviceId,
          deviceName: clientVault.localDeviceName,
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );

      final pairCode = server.createPairingCode();
      final paired = await unauthTransport.pair(
        pairingCode: pairCode.code,
        deviceId: clientVault.localDeviceId,
        deviceName: clientVault.localDeviceName,
      );
      expect(paired.deviceToken, isNotEmpty);
      expect(paired.vaultId, equals(serverVault.metadata.vaultId));

      // Reusing the same pairing code MUST fail (single-use!).
      await expectLater(
        () => unauthTransport.pair(
          pairingCode: pairCode.code,
          deviceId: generateUuidV7(),
          deviceName: 'Replay-Attacker',
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.authRequired,
          ),
        ),
      );

      // INV-08: Verify `sync_devices` stores ONLY SHA-256 hash, NEVER raw token!
      final dbProbe = sq.sqlite3.open(
        p.join(serverVaultDir.path, 'db', 'blink.db'),
        mode: sq.OpenMode.readOnly,
      );
      try {
        final row = dbProbe.select(
          'SELECT token_sha256 FROM sync_devices WHERE device_id = ?',
          <Object?>[clientVault.localDeviceId],
        ).single;
        final storedHash = row['token_sha256'] as String;
        expect(storedHash, isNot(equals(paired.deviceToken)));
        expect(isValidBlobSha256(storedHash), isTrue);
      } finally {
        dbProbe.close();
      }

      final authedTransport = unauthTransport.withDeviceToken(
        paired.deviceToken,
        transportId: 'direct:${serverVault.metadata.vaultId}',
      );
      addTearDown(authedTransport.close);

      // 5. Capabilities & device listing.
      final caps = await authedTransport.getCapabilities();
      expect(caps.supportsSse, isTrue);
      expect(caps.supportsBlobRange, isTrue);
      final devices = await authedTransport.listDevices();
      expect(
        devices.map((d) => d.deviceId),
        contains(clientVault.localDeviceId),
      );

      // 6. SSE real-time wakeup when server OpLog advances.
      final sseSeqs = <int>[];
      final sseCompleter = Completer<void>();
      final sseSub = authedTransport.watchSeqEvents().listen((seq) {
        sseSeqs.add(seq);
        if (seq > 0 && !sseCompleter.isCompleted) {
          sseCompleter.complete();
        }
      });
      addTearDown(sseSub.cancel);

      // 7. Create entry + 20 KiB binary blob on server and entry on client.
      final blobBytes = Uint8List.fromList(
        List<int>.generate(20 * 1024, (i) => (i * 31 + 7) & 0xFF),
      );
      final serverBlob = await serverVault.blobs.putBytes(
        blobBytes,
        mimeType: 'application/octet-stream',
      );
      final serverEntry = await serverVault.raw.createEntry(
        bodyMd: '服务端大附件笔记 #直连同步',
        imageBlobSha256s: <String>[serverBlob.sha256],
      );
      final clientEntry = await clientVault.raw.createEntry(
        bodyMd: '移动端离线闪念 #直连同步',
      );

      await sseCompleter.future.timeout(const Duration(seconds: 5));
      expect(sseSeqs, contains(greaterThan(0)));

      // Sync client <-> server using small 4 KiB chunks to exercise HTTP 206 Range resume!
      final run = await clientVault.syncEngine.syncWithTransport(
        authedTransport,
        blobDownloadChunkSize: 4096,
      );
      expect(run.pushedOps, equals(1));
      expect(run.appliedOps, equals(1));
      expect(run.blobsDownloaded, equals(1));
      expect(clientVault.pendingOutboxCount, equals(0));

      // Verify exact Range slice response directly too.
      final slice = await authedTransport.downloadBlobRange(
        sha256: serverBlob.sha256,
        startOffset: 100,
        endOffsetInclusive: 299,
      );
      expect(slice.isPartial, isTrue);
      expect(slice.startOffset, equals(100));
      expect(slice.totalLength, equals(blobBytes.length));
      expect(slice.bytes, equals(blobBytes.sublist(100, 300)));

      // Verify both vaults converged with byte-exact blob.
      expect(
        (await clientVault.raw.getEntryById(serverEntry.id))?.bodyMd,
        equals(serverEntry.bodyMd),
      );
      expect(
        (await serverVault.raw.getEntryById(clientEntry.id))?.bodyMd,
        equals(clientEntry.bodyMd),
      );
      expect(
        await clientVault.blobs.readBytes(serverBlob.sha256),
        equals(blobBytes),
      );

      // 8. Corrupted blob upload MUST be rejected by server SHA-256 verification (`INV-07`).
      final bogusSha = crypto.sha256.convert(<int>[1, 2, 3, 4]).toString();
      await expectLater(
        () => authedTransport.uploadBlob(
          sha256: bogusSha,
          bytes: Uint8List.fromList(<int>[9, 9, 9, 9]),
          mimeType: 'application/octet-stream',
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.invalidArgument,
          ),
        ),
      );
      expect(await serverVault.blobs.resolveFile(bogusSha), isNull);

      // 8b. Re-pushing the exact same client_op_id batch is idempotent (INV-05).
      final replayBatch =
          (await clientVault.syncEngine.readOplogSince(sinceSeq: 0)).ops
              .where((op) => op.deviceId == clientVault.localDeviceId)
              .toList(growable: false);
      final replayPush = await authedTransport.pushOps(replayBatch);
      expect(replayPush.acceptedCount, equals(0));
      expect(replayPush.duplicateCount, equals(replayBatch.length));

      // 8c. End-to-end concurrent edit conflict + #private latch over HTTP (AC-04).
      await serverVault.raw.updateEntry(
        id: serverEntry.id,
        bodyMd: '桌面并发修改 琥珀关键词',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await clientVault.raw.updateEntry(
        id: serverEntry.id,
        bodyMd: '手机并发升级私密 琥珀关键词 #private',
      );
      await clientVault.syncEngine.syncWithTransport(authedTransport);
      final syncedServerEntry = await serverVault.raw.getEntryById(
        serverEntry.id,
      );
      final syncedClientEntry = await clientVault.raw.getEntryById(
        serverEntry.id,
      );
      expect(syncedServerEntry!.privacyLevel, equals(PrivacyLevel.private));
      expect(syncedClientEntry!.privacyLevel, equals(PrivacyLevel.private));
      expect(serverVault.openConflictCount, equals(1));
      expect(
        await serverVault.search.search(
          '琥珀关键词',
          scope: PrivacyScope.normalOnly,
        ),
        isEmpty,
      );

      // 9. Revoking the device immediately rejects subsequent requests with `deviceRevoked`.
      expect(await server.revokeDevice(clientVault.localDeviceId), isTrue);
      await expectLater(
        () => authedTransport.pullOps(sinceSeq: 0),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.deviceRevoked,
          ),
        ),
      );
    });

    test('maps unreachable peer to honest peerAsleep error (INV-11) and isolates LAN discovery channels', () async {
      // Reserve and immediately close a loopback port to guarantee connection refused.
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final unusedPort = probe.port;
      await probe.close();

      final asleepTransport = DirectShelfTransport(
        baseUri: Uri.parse('http://127.0.0.1:$unusedPort'),
        expectedChannel: BlinkChannel.blinkDev,
        requestTimeout: const Duration(seconds: 2),
      );
      addTearDown(asleepTransport.close);

      await expectLater(
        () => asleepTransport.checkHealth(),
        throwsA(
          isA<BlinkException>()
              .having((e) => e.code, 'code', BlinkErrorCode.peerAsleep)
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );

      // LAN Discovery channel isolation via deterministic in-memory adapter (zero multicast!).
      final registry = <LanPeerAnnouncement>[];
      final prodDiscovery = LanDiscovery(
        adapter: InMemoryLanDiscoveryAdapter(sharedRegistry: registry),
      );
      final devDiscovery = LanDiscovery(
        adapter: InMemoryLanDiscoveryAdapter(sharedRegistry: registry),
      );
      addTearDown(prodDiscovery.dispose);
      addTearDown(devDiscovery.dispose);

      await prodDiscovery.startAdvertising(
        LanPeerAnnouncement(
          instanceName: 'blink-prod-node',
          channel: BlinkChannel.blink,
          vaultId: generateUuidV7(),
          deviceId: generateUuidV7(),
          deviceName: 'Prod-PC',
          port: 8765,
          hostAddress: '127.0.0.1',
        ),
      );
      await devDiscovery.startAdvertising(
        LanPeerAnnouncement(
          instanceName: 'blink-dev-node',
          channel: BlinkChannel.blinkDev,
          vaultId: generateUuidV7(),
          deviceId: generateUuidV7(),
          deviceName: 'Dev-PC',
          port: 8766,
          hostAddress: '127.0.0.1',
        ),
      );

      final devPeers = await devDiscovery.discover(
        expectedChannel: BlinkChannel.blinkDev,
      );
      expect(devPeers, hasLength(1));
      expect(devPeers.single.deviceName, equals('Dev-PC'));
      expect(devPeers.single.channel, equals(BlinkChannel.blinkDev));
      expect(devPeers.single.port, equals(8766));

      // BLINK_QUIET=1 must select NoopLanDiscoveryAdapter without opening sockets.
      final quietDiscovery = LanDiscovery(
        environment: const <String, String>{'BLINK_QUIET': '1'},
      );
      await quietDiscovery.startAdvertising(
        LanPeerAnnouncement(
          instanceName: 'quiet-node',
          channel: BlinkChannel.blinkDev,
          vaultId: generateUuidV7(),
          deviceId: generateUuidV7(),
          deviceName: 'Quiet',
          port: 8767,
        ),
      );
      expect(
        await quietDiscovery.discover(expectedChannel: BlinkChannel.blinkDev),
        isEmpty,
      );
      await quietDiscovery.dispose();
    });
  });
}
