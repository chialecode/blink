import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../bfm/bfm_engine.dart';
import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../storage/blob_store.dart';
import '../utils/uuid_v7.dart';
import 'sync_crypto.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

/// Minimal object-store backend contract implemented by [WebDavClient] and [S3Client].
abstract interface class RelayObjectStore {
  /// Stable identifier used in `sync_state` cursor keys.
  String get storeId;

  Future<void> checkConnection();

  Future<void> ensurePrefix(String prefix);

  Future<List<String>> listKeys(String prefix);

  Future<bool> exists(String key);

  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  });

  Future<Uint8List?> getBytes(String key);

  Future<void> deleteKey(String key);

  void close();
}

/// Client-side E2EE async relay implementing [SyncTransport] over WebDAV or S3 (`AC-05`, `INV-03`, `INV-08`).
///
/// Storage layout (NEVER uploads live `blink.db`):
/// - `vault.meta.enc`: encrypted vault metadata (`vault_id`, `channel`, `protocol_version`)
/// - `oplogs/<device_id>/<batch_uuidv7>.enc`: append-only immutable encrypted OpLog segments
/// - `blobs/<hmac_id>.enc`: blinded content-addressed encrypted attachments
///
/// Enforces physical [excludePrivateFromRelay] (default `true`): any op with
/// `privacy_level == 'private'` sends **0 bytes** to the relay store.
final class EncryptedRelayTransport implements SyncTransport {
  EncryptedRelayTransport({
    required this.store,
    required this.masterKey,
    required this.localVaultId,
    required this.expectedChannel,
    required this.localDeviceId,
    this.excludePrivateFromRelay = true,
    SyncCrypto? cryptoEngine,
    SyncStateStore? stateStore,
    String? transportId,
  }) : _crypto = cryptoEngine ?? SyncCrypto(),
       _stateStore = stateStore ?? _InMemorySyncStateStore(),
       transportId = transportId ?? 'relay:${store.storeId}';

  final RelayObjectStore store;
  final SyncMasterKey masterKey;
  final String localVaultId;
  final BlinkChannel expectedChannel;
  final String localDeviceId;

  /// Physical `#private` relay exclusion switch (`INV-03`, `AC-05`, default `true`).
  final bool excludePrivateFromRelay;

  final SyncCrypto _crypto;
  final SyncStateStore _stateStore;

  String? _canonicalRelayVaultId;
  final Map<String, String> _pendingDeviceWatermarks = <String, String>{};

  static const String _vaultMetaKey = 'vault.meta.enc';

  @override
  final String transportId;

  @override
  bool get isRelayTransport => true;

  /// Canonical `vault_id` negotiated via `vault.meta.enc` (discovered automatically
  /// on new-device recovery from a recovery code).
  String get effectiveVaultId => _canonicalRelayVaultId ?? localVaultId;

  void close() => store.close();

  @override
  Future<SyncPeerHealth> checkHealth() async {
    await store.checkConnection();
    final metaKey = await _crypto.deriveVaultMetaKey(masterKey);
    final existing = await store.getBytes(_vaultMetaKey);
    if (existing != null) {
      final decoded = await _crypto.decryptJsonObject(
        envelope: existing,
        key: metaKey,
        aadContext: _vaultMetaKey,
      );
      final channel = BlinkChannel.tryParse(decoded['channel'] as String?);
      final proto = decoded['protocol_version'];
      final relayVaultId = decoded['vault_id'] as String?;
      if (channel == null ||
          proto is! int ||
          relayVaultId == null ||
          relayVaultId.isEmpty) {
        throw BlinkException(
          code: BlinkErrorCode.ioError,
          message: 'Corrupt encrypted vault.meta.enc on relay',
        );
      }
      if (channel != expectedChannel) {
        throw BlinkException(
          code: BlinkErrorCode.channelMismatch,
          message:
              'Relay channel "${channel.wireValue}" != expected "${expectedChannel.wireValue}"',
        );
      }
      if (proto != currentSyncProtocolVersion) {
        throw BlinkException(
          code: BlinkErrorCode.protocolMismatch,
          message:
              'Relay protocol v$proto != expected v$currentSyncProtocolVersion',
        );
      }
      _canonicalRelayVaultId = relayVaultId;
      return SyncPeerHealth(
        channel: channel,
        protocolVersion: proto,
        vaultId: relayVaultId,
        deviceId: transportId,
        deviceName: 'Encrypted Relay (${store.storeId})',
        latestSeqId: 0,
      );
    }

    _canonicalRelayVaultId = localVaultId;
    final createdMeta = <String, Object?>{
      'vault_id': localVaultId,
      'channel': expectedChannel.wireValue,
      'protocol_version': currentSyncProtocolVersion,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    final encrypted = await _crypto.encryptJsonObject(
      payload: createdMeta,
      key: metaKey,
      aadContext: _vaultMetaKey,
    );
    await store.putBytes(_vaultMetaKey, encrypted);
    return SyncPeerHealth(
      channel: expectedChannel,
      protocolVersion: currentSyncProtocolVersion,
      vaultId: localVaultId,
      deviceId: transportId,
      deviceName: 'Encrypted Relay (${store.storeId})',
      latestSeqId: 0,
    );
  }

  @override
  Future<PushOpsResult> pushOps(List<SyncOpEnvelope> ops) async {
    if (_canonicalRelayVaultId == null) {
      await checkHealth();
    }
    final allowedOps = <SyncOpEnvelope>[];
    var skippedPrivate = 0;

    for (final op in ops) {
      if (excludePrivateFromRelay && _isPrivateEnvelope(op)) {
        // Hard physical exclusion before serialization/encryption (`INV-03`, `AC-05`).
        skippedPrivate += 1;
        continue;
      }
      allowedOps.add(op);
    }

    if (allowedOps.isEmpty) {
      // Zero bytes sent to relay!
      return PushOpsResult(
        acceptedCount: 0,
        duplicateCount: 0,
        latestSeqId: 0,
        skippedPrivateCount: skippedPrivate,
      );
    }

    final vaultId = effectiveVaultId;
    final batchId = generateUuidV7();
    final objectKey = 'oplogs/$localDeviceId/$batchId.enc';
    final oplogKey = await _crypto.deriveOplogKey(
      masterKey: masterKey,
      vaultId: vaultId,
    );

    final batchPayload = <String, Object?>{
      'batch_id': batchId,
      'vault_id': vaultId,
      'channel': expectedChannel.wireValue,
      'protocol_version': currentSyncProtocolVersion,
      'device_id': localDeviceId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'ops': allowedOps.map((op) => op.toJson()).toList(growable: false),
    };

    final encryptedBytes = await _crypto.encryptJsonObject(
      payload: batchPayload,
      key: oplogKey,
      aadContext: '$vaultId:$objectKey',
    );
    await store.putBytes(objectKey, encryptedBytes);

    return PushOpsResult(
      acceptedCount: allowedOps.length,
      duplicateCount: 0,
      latestSeqId: 0,
      acceptedClientOpIds: allowedOps
          .map((op) => op.clientOpId)
          .toList(growable: false),
      skippedPrivateCount: skippedPrivate,
    );
  }

  @override
  Future<PullOpsResult> pullOps({
    required int sinceSeq,
    int limit = 200,
  }) async {
    if (_canonicalRelayVaultId == null) {
      await checkHealth();
    }
    _pendingDeviceWatermarks.clear();

    final vaultId = effectiveVaultId;
    final oplogKey = await _crypto.deriveOplogKey(
      masterKey: masterKey,
      vaultId: vaultId,
    );

    final allKeys = await store.listKeys('oplogs');
    final perDeviceBatches = <String, List<({String fileName, String key})>>{};
    for (final key in allKeys) {
      if (!key.endsWith('.enc')) {
        continue;
      }
      final parts = key.split('/');
      if (parts.length != 3 || parts[0] != 'oplogs') {
        continue;
      }
      final remoteDeviceId = parts[1];
      final fileName = parts[2];
      if (remoteDeviceId == localDeviceId) {
        continue;
      }
      perDeviceBatches
          .putIfAbsent(
            remoteDeviceId,
            () => <({String fileName, String key})>[],
          )
          .add((fileName: fileName, key: key));
    }

    final collectedOps = <SyncOpEnvelope>[];
    final sortedDeviceIds = perDeviceBatches.keys.toList()..sort();

    for (final remoteDeviceId in sortedDeviceIds) {
      final batches = perDeviceBatches[remoteDeviceId]!
        ..sort((a, b) => a.fileName.compareTo(b.fileName));
      final wmKey = _deviceWatermarkKey(remoteDeviceId);
      final lastConsumed = _stateStore.read(wmKey) ?? '';

      String? highestConsumed;
      for (final batch in batches) {
        if (lastConsumed.isNotEmpty &&
            batch.fileName.compareTo(lastConsumed) <= 0) {
          continue;
        }
        final ciphertext = await store.getBytes(batch.key);
        if (ciphertext == null) {
          continue;
        }
        final decoded = await _crypto.decryptJsonObject(
          envelope: ciphertext,
          key: oplogKey,
          aadContext: '$vaultId:${batch.key}',
        );
        if (decoded['vault_id'] != vaultId) {
          throw BlinkException(
            code: BlinkErrorCode.protocolMismatch,
            message: 'Decrypted relay batch vault_id mismatch',
          );
        }
        if (decoded['channel'] != expectedChannel.wireValue) {
          throw BlinkException(
            code: BlinkErrorCode.channelMismatch,
            message: 'Decrypted relay batch channel mismatch',
          );
        }
        final rawOps = decoded['ops'];
        if (rawOps is List) {
          for (final item in rawOps) {
            if (item is Map) {
              collectedOps.add(
                SyncOpEnvelope.fromJson(
                  item.map(
                    (k, v) => MapEntry<String, Object?>(k.toString(), v),
                  ),
                ),
              );
            }
          }
        }
        highestConsumed = batch.fileName;
      }

      if (highestConsumed != null) {
        _pendingDeviceWatermarks[wmKey] = highestConsumed;
      }
    }

    collectedOps.sort(SyncOpEnvelope.compareCausalOrder);
    return PullOpsResult(
      ops: collectedOps,
      nextCursorSeq: sinceSeq,
      hasMore: false,
    );
  }

  @override
  Future<void> commitPullCursor(int nextCursorSeq) async {
    for (final entry in _pendingDeviceWatermarks.entries) {
      _stateStore.write(entry.key, entry.value);
    }
    _pendingDeviceWatermarks.clear();
  }

  @override
  Future<bool> hasBlob(String sha256) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    if (_canonicalRelayVaultId == null) {
      await checkHealth();
    }
    final key = await _blobObjectKey(sha256);
    return store.exists(key);
  }

  @override
  Future<void> uploadBlob({
    required String sha256,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    final actualSha = crypto.sha256.convert(bytes).toString();
    if (actualSha != sha256) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Blob bytes do not match SHA-256 before E2EE upload',
      );
    }
    if (_canonicalRelayVaultId == null) {
      await checkHealth();
    }
    final vaultId = effectiveVaultId;
    final key = await _blobObjectKey(sha256);
    final blobKey = await _crypto.deriveBlobKey(
      masterKey: masterKey,
      vaultId: vaultId,
    );
    // Prefix plaintext with a minimal JSON header so MIME type is encrypted too (`AC-05`).
    final wrapped = _packBlobPlaintext(mimeType: mimeType, bytes: bytes);
    final ciphertext = await _crypto.encryptBytes(
      plaintext: wrapped,
      key: blobKey,
      aadContext: '$vaultId:$key',
    );
    await store.putBytes(key, ciphertext);
  }

  @override
  Future<BlobRangeResponse> downloadBlobRange({
    required String sha256,
    int startOffset = 0,
    int? endOffsetInclusive,
  }) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    if (_canonicalRelayVaultId == null) {
      await checkHealth();
    }
    final vaultId = effectiveVaultId;
    final key = await _blobObjectKey(sha256);
    final ciphertext = await store.getBytes(key);
    if (ciphertext == null) {
      throw BlinkException(
        code: BlinkErrorCode.notFound,
        message: 'Encrypted blob not found on relay',
      );
    }
    final blobKey = await _crypto.deriveBlobKey(
      masterKey: masterKey,
      vaultId: vaultId,
    );
    final wrapped = await _crypto.decryptBytes(
      envelope: ciphertext,
      key: blobKey,
      aadContext: '$vaultId:$key',
    );
    final unpacked = _unpackBlobPlaintext(wrapped);
    final actualSha = crypto.sha256.convert(unpacked.bytes).toString();
    if (actualSha != sha256) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Decrypted relay blob failed SHA-256 integrity verification',
      );
    }

    final total = unpacked.bytes.length;
    if (startOffset == 0 &&
        (endOffsetInclusive == null || endOffsetInclusive >= total - 1)) {
      return BlobRangeResponse(
        bytes: unpacked.bytes,
        startOffset: 0,
        totalLength: total,
        isPartial: false,
        mimeType: unpacked.mimeType,
      );
    }

    final clampedStart = startOffset.clamp(0, total);
    final clampedEnd = endOffsetInclusive == null
        ? total
        : (endOffsetInclusive + 1).clamp(clampedStart, total);
    return BlobRangeResponse(
      bytes: Uint8List.sublistView(unpacked.bytes, clampedStart, clampedEnd),
      startOffset: clampedStart,
      totalLength: total,
      isPartial: clampedStart > 0 || clampedEnd < total,
      mimeType: unpacked.mimeType,
    );
  }

  Future<String> _blobObjectKey(String sha256) async {
    final blinded = await _crypto.blindBlobId(
      masterKey: masterKey,
      vaultId: effectiveVaultId,
      sha256: sha256,
    );
    return 'blobs/$blinded.enc';
  }

  String _deviceWatermarkKey(String remoteDeviceId) =>
      'relay_wm:$transportId:$remoteDeviceId';

  static const BfmEngine _bfm = BfmEngine();

  static bool _isPrivateEnvelope(SyncOpEnvelope op) {
    if (op.privacyLevel == PrivacyLevel.private) {
      return true;
    }
    if (op.payload['privacy_level'] == PrivacyLevel.private.wireValue) {
      return true;
    }
    if (op.payload['privacy_scope'] == 'local_with_private') {
      return true;
    }
    final bodyMd = op.payload['body_md'];
    if (bodyMd is String && _bfm.parse(bodyMd).hasPrivateToken) {
      return true;
    }
    final noteMd = op.payload['note_md'];
    if (noteMd is String && _bfm.parse(noteMd).hasPrivateToken) {
      return true;
    }
    return false;
  }

  static Uint8List _packBlobPlaintext({
    required String mimeType,
    required Uint8List bytes,
  }) {
    final mimeBytes = Uint8List.fromList(mimeType.codeUnits);
    if (mimeBytes.length > 0xFFFF) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'MIME type too long for encrypted blob envelope',
      );
    }
    final out = Uint8List(2 + mimeBytes.length + bytes.length);
    out[0] = (mimeBytes.length >> 8) & 0xFF;
    out[1] = mimeBytes.length & 0xFF;
    out.setAll(2, mimeBytes);
    out.setAll(2 + mimeBytes.length, bytes);
    return out;
  }

  static ({String mimeType, Uint8List bytes}) _unpackBlobPlaintext(
    Uint8List wrapped,
  ) {
    if (wrapped.length < 2) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Decrypted blob payload is malformed',
      );
    }
    final mimeLen = (wrapped[0] << 8) | wrapped[1];
    if (wrapped.length < 2 + mimeLen) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Decrypted blob MIME header truncated',
      );
    }
    final mimeType = String.fromCharCodes(
      Uint8List.sublistView(wrapped, 2, 2 + mimeLen),
    );
    final payload = Uint8List.fromList(
      Uint8List.sublistView(wrapped, 2 + mimeLen),
    );
    return (
      mimeType: mimeType.isEmpty ? 'application/octet-stream' : mimeType,
      bytes: payload,
    );
  }
}

final class _InMemorySyncStateStore implements SyncStateStore {
  final Map<String, String> _values = <String, String>{};

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) => _values[key] = value;
}
