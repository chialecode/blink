import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../models/blink_models.dart';

/// Wire protocol version for BLINK direct & relay sync (`X-Blink-Protocol: 2`).
const int currentSyncProtocolVersion = 2;

/// Layer classification carried by every [SyncOpEnvelope].
enum SyncEntityLayer {
  raw('raw'),
  ai('ai');

  const SyncEntityLayer(this.wireValue);

  final String wireValue;

  static SyncEntityLayer? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in SyncEntityLayer.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Lifecycle state of a preserved dual-copy text conflict (`sync_conflicts`).
enum SyncConflictStatus {
  open('open'),
  resolved('resolved');

  const SyncConflictStatus(this.wireValue);

  final String wireValue;

  static SyncConflictStatus? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in SyncConflictStatus.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// User resolution action for a [SyncConflict].
enum ConflictResolutionChoice {
  /// Keep the current main entry body and soft-delete the conflict copy.
  keepCurrent('keep_current'),

  /// Replace the main entry body with the conflict copy's content and soft-delete the copy.
  keepConflictCopy('keep_conflict_copy'),

  /// Keep both the main entry and the conflict copy as separate entries.
  keepBoth('keep_both'),

  /// Replace the main entry body with user-supplied `mergedBodyMd` and soft-delete the copy.
  customMerge('custom_merge');

  const ConflictResolutionChoice(this.wireValue);

  final String wireValue;

  static ConflictResolutionChoice? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in ConflictResolutionChoice.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Honest sync connection state surfaced across platforms (`INV-11`).
enum SyncConnectionState {
  idle,
  syncing,
  online,
  peerAsleep,
  authRequired,
  deviceRevoked,
  privacyBlocked,
  error,
}

/// Canonical causal OpLog envelope shared by local SQLite, direct `shelf` sync,
/// and E2EE WebDAV/S3 async relay (`INV-05`).
@immutable
final class SyncOpEnvelope {
  SyncOpEnvelope({
    this.seqId,
    required this.deviceId,
    this.deviceName,
    required this.clientOpId,
    required this.hlcTs,
    required this.baseRevision,
    required this.entityLayer,
    required this.entityType,
    required this.entityId,
    required this.opType,
    required this.opOrigin,
    required this.privacyLevel,
    required Map<String, Object?> payload,
    required this.createdAtUtc,
  }) : payload = Map<String, Object?>.unmodifiable(payload);

  final int? seqId;
  final String deviceId;
  final String? deviceName;
  final String clientOpId;
  final String hlcTs;
  final int baseRevision;
  final SyncEntityLayer entityLayer;
  final String entityType;
  final String entityId;
  final String opType;
  final String opOrigin;
  final PrivacyLevel privacyLevel;
  final Map<String, Object?> payload;
  final DateTime createdAtUtc;

  String get payloadJson => jsonEncode(payload);

  /// Deterministic total causal order `(hlc_ts, device_id, client_op_id)` (`INV-05`).
  static int compareCausalOrder(SyncOpEnvelope a, SyncOpEnvelope b) {
    final hlcCmp = a.hlcTs.compareTo(b.hlcTs);
    if (hlcCmp != 0) {
      return hlcCmp;
    }
    final devCmp = a.deviceId.compareTo(b.deviceId);
    if (devCmp != 0) {
      return devCmp;
    }
    return a.clientOpId.compareTo(b.clientOpId);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (seqId != null) 'seq_id': seqId,
    'device_id': deviceId,
    if (deviceName != null && deviceName!.isNotEmpty) 'device_name': deviceName,
    'client_op_id': clientOpId,
    'hlc_ts': hlcTs,
    'base_revision': baseRevision,
    'entity_layer': entityLayer.wireValue,
    'entity_type': entityType,
    'entity_id': entityId,
    'op_type': opType,
    'op_origin': opOrigin,
    'privacy_level': privacyLevel.wireValue,
    'payload': payload,
    'created_at': createdAtUtc.toUtc().toIso8601String(),
  };

  factory SyncOpEnvelope.fromJson(Map<String, Object?> json) {
    final rawPayload = json['payload'];
    Map<String, Object?> decodedPayload;
    if (rawPayload is Map<String, Object?>) {
      decodedPayload = rawPayload;
    } else if (rawPayload is Map) {
      decodedPayload = rawPayload.map(
        (key, value) => MapEntry<String, Object?>(key.toString(), value),
      );
    } else if (json['payload_json'] is String) {
      final parsed = jsonDecode(json['payload_json'] as String);
      if (parsed is Map) {
        decodedPayload = parsed.map(
          (key, value) => MapEntry<String, Object?>(key.toString(), value),
        );
      } else {
        throw const FormatException('payload_json must decode to an object');
      }
    } else {
      throw const FormatException('SyncOpEnvelope missing payload object');
    }

    final layer = SyncEntityLayer.tryParse(json['entity_layer'] as String?);
    final privacy = PrivacyLevel.tryParse(json['privacy_level'] as String?);
    final deviceId = json['device_id'] as String?;
    final clientOpId = json['client_op_id'] as String?;
    final hlcTs = json['hlc_ts'] as String?;
    final entityType = json['entity_type'] as String?;
    final entityId = json['entity_id'] as String?;
    final opType = json['op_type'] as String?;
    final createdRaw = json['created_at'] as String?;
    if (layer == null ||
        privacy == null ||
        deviceId == null ||
        deviceId.isEmpty ||
        clientOpId == null ||
        clientOpId.isEmpty ||
        hlcTs == null ||
        hlcTs.isEmpty ||
        entityType == null ||
        entityType.isEmpty ||
        entityId == null ||
        entityId.isEmpty ||
        opType == null ||
        opType.isEmpty ||
        createdRaw == null) {
      throw const FormatException('SyncOpEnvelope missing required fields');
    }

    final createdAt = DateTime.tryParse(createdRaw)?.toUtc();
    if (createdAt == null) {
      throw const FormatException('SyncOpEnvelope has invalid created_at');
    }

    final rawSeq = json['seq_id'];
    final rawBaseRev = json['base_revision'];
    return SyncOpEnvelope(
      seqId: rawSeq is int ? rawSeq : null,
      deviceId: deviceId,
      deviceName: json['device_name'] as String?,
      clientOpId: clientOpId,
      hlcTs: hlcTs,
      baseRevision: rawBaseRev is int ? rawBaseRev : 0,
      entityLayer: layer,
      entityType: entityType,
      entityId: entityId,
      opType: opType,
      opOrigin: (json['op_origin'] as String?) ?? 'app_ui',
      privacyLevel: privacy,
      payload: decodedPayload,
      createdAtUtc: createdAt,
    );
  }
}

/// Preserved dual-copy conflict record stored in `sync_conflicts` (`INV-01`, `INV-05`).
@immutable
final class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.localCopyId,
    required this.remoteDeviceId,
    required this.remoteDeviceName,
    required this.remoteHlcTs,
    required this.localBodyMd,
    required this.remoteBodyMd,
    required this.status,
    this.resolution,
    required this.createdAtUtc,
    this.resolvedAtUtc,
  });

  final String id;
  final String entityType;
  final String entityId;
  final String localCopyId;
  final String remoteDeviceId;
  final String remoteDeviceName;
  final String remoteHlcTs;
  final String localBodyMd;
  final String remoteBodyMd;
  final SyncConflictStatus status;
  final String? resolution;
  final DateTime createdAtUtc;
  final DateTime? resolvedAtUtc;

  bool get isOpen => status == SyncConflictStatus.open;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncConflict &&
          id == other.id &&
          entityType == other.entityType &&
          entityId == other.entityId &&
          localCopyId == other.localCopyId &&
          remoteDeviceId == other.remoteDeviceId &&
          remoteDeviceName == other.remoteDeviceName &&
          remoteHlcTs == other.remoteHlcTs &&
          localBodyMd == other.localBodyMd &&
          remoteBodyMd == other.remoteBodyMd &&
          status == other.status &&
          resolution == other.resolution &&
          createdAtUtc.isAtSameMomentAs(other.createdAtUtc) &&
          ((resolvedAtUtc == null && other.resolvedAtUtc == null) ||
              (resolvedAtUtc != null &&
                  other.resolvedAtUtc != null &&
                  resolvedAtUtc!.isAtSameMomentAs(other.resolvedAtUtc!)));

  @override
  int get hashCode => Object.hash(
    id,
    entityType,
    entityId,
    localCopyId,
    remoteDeviceId,
    remoteDeviceName,
    remoteHlcTs,
    localBodyMd,
    remoteBodyMd,
    status,
    resolution,
    createdAtUtc.toUtc(),
    resolvedAtUtc?.toUtc(),
  );
}

/// Registered sync peer stored in `sync_devices` (stores ONLY `token_sha256`, `INV-08`).
@immutable
final class SyncDeviceRecord {
  const SyncDeviceRecord({
    required this.deviceId,
    required this.deviceName,
    required this.tokenSha256,
    this.revokedAtUtc,
    this.lastSeenAtUtc,
    required this.createdAtUtc,
  });

  final String deviceId;
  final String deviceName;
  final String tokenSha256;
  final DateTime? revokedAtUtc;
  final DateTime? lastSeenAtUtc;
  final DateTime createdAtUtc;

  bool get isRevoked => revokedAtUtc != null;

  /// Wire-safe serialization (explicitly omits `token_sha256`).
  Map<String, Object?> toPublicJson() => <String, Object?>{
    'device_id': deviceId,
    'device_name': deviceName,
    'revoked_at': revokedAtUtc?.toUtc().toIso8601String(),
    'last_seen_at': lastSeenAtUtc?.toUtc().toIso8601String(),
    'created_at': createdAtUtc.toUtc().toIso8601String(),
  };

  factory SyncDeviceRecord.fromPublicJson(Map<String, Object?> json) =>
      SyncDeviceRecord(
        deviceId: json['device_id'] as String,
        deviceName: (json['device_name'] as String?) ?? '',
        tokenSha256: '',
        revokedAtUtc: json['revoked_at'] is String
            ? DateTime.parse(json['revoked_at'] as String).toUtc()
            : null,
        lastSeenAtUtc: json['last_seen_at'] is String
            ? DateTime.parse(json['last_seen_at'] as String).toUtc()
            : null,
        createdAtUtc: DateTime.parse(json['created_at'] as String).toUtc(),
      );
}

/// Response returned by `GET /api/v1/health`.
@immutable
final class SyncPeerHealth {
  const SyncPeerHealth({
    required this.channel,
    required this.protocolVersion,
    required this.vaultId,
    required this.deviceId,
    required this.deviceName,
    required this.latestSeqId,
  });

  final BlinkChannel channel;
  final int protocolVersion;
  final String vaultId;
  final String deviceId;
  final String deviceName;
  final int latestSeqId;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': true,
    'channel': channel.wireValue,
    'protocol_version': protocolVersion,
    'vault_id': vaultId,
    'device_id': deviceId,
    'device_name': deviceName,
    'latest_seq_id': latestSeqId,
  };

  factory SyncPeerHealth.fromJson(Map<String, Object?> json) {
    final channel = BlinkChannel.tryParse(json['channel'] as String?);
    final proto = json['protocol_version'];
    final vaultId = json['vault_id'] as String?;
    final deviceId = json['device_id'] as String?;
    if (channel == null ||
        proto is! int ||
        vaultId == null ||
        deviceId == null) {
      throw const FormatException('Invalid SyncPeerHealth JSON');
    }
    return SyncPeerHealth(
      channel: channel,
      protocolVersion: proto,
      vaultId: vaultId,
      deviceId: deviceId,
      deviceName: (json['device_name'] as String?) ?? '',
      latestSeqId: (json['latest_seq_id'] as int?) ?? 0,
    );
  }
}

/// Response returned by `GET /api/v1/capabilities`.
@immutable
final class SyncCapabilities {
  const SyncCapabilities({
    required this.protocolVersion,
    required this.channel,
    required this.supportsSse,
    required this.supportsBlobRange,
    required this.supportsE2eeRelay,
    required this.maxBatchSize,
  });

  final int protocolVersion;
  final BlinkChannel channel;
  final bool supportsSse;
  final bool supportsBlobRange;
  final bool supportsE2eeRelay;
  final int maxBatchSize;

  Map<String, Object?> toJson() => <String, Object?>{
    'protocol_version': protocolVersion,
    'channel': channel.wireValue,
    'supports_sse': supportsSse,
    'supports_blob_range': supportsBlobRange,
    'supports_e2ee_relay': supportsE2eeRelay,
    'max_batch_size': maxBatchSize,
  };

  factory SyncCapabilities.fromJson(Map<String, Object?> json) {
    final channel = BlinkChannel.tryParse(json['channel'] as String?);
    final proto = json['protocol_version'];
    if (channel == null || proto is! int) {
      throw const FormatException('Invalid SyncCapabilities JSON');
    }
    return SyncCapabilities(
      protocolVersion: proto,
      channel: channel,
      supportsSse: json['supports_sse'] == true,
      supportsBlobRange: json['supports_blob_range'] == true,
      supportsE2eeRelay: json['supports_e2ee_relay'] == true,
      maxBatchSize: (json['max_batch_size'] as int?) ?? 500,
    );
  }
}

/// Short-lived, single-use pairing code issued by `DirectShelfServer` (memory-only, `INV-08`).
@immutable
final class PairingCodeInfo {
  const PairingCodeInfo({required this.code, required this.expiresAtUtc});

  final String code;
  final DateTime expiresAtUtc;

  bool isExpiredAt(DateTime nowUtc) => !nowUtc.toUtc().isBefore(expiresAtUtc);
}

/// One-time credential bundle returned by `POST /api/v1/auth/pair`.
/// Callers must persist [deviceToken] strictly in OS native SecretStore (`INV-08`).
@immutable
final class PairingResult {
  const PairingResult({
    required this.deviceId,
    required this.deviceName,
    required this.deviceToken,
    required this.vaultId,
    required this.channel,
    required this.protocolVersion,
  });

  final String deviceId;
  final String deviceName;
  final String deviceToken;
  final String vaultId;
  final BlinkChannel channel;
  final int protocolVersion;

  Map<String, Object?> toJson() => <String, Object?>{
    'device_id': deviceId,
    'device_name': deviceName,
    'device_token': deviceToken,
    'vault_id': vaultId,
    'channel': channel.wireValue,
    'protocol_version': protocolVersion,
  };

  factory PairingResult.fromJson(Map<String, Object?> json) {
    final channel = BlinkChannel.tryParse(json['channel'] as String?);
    final proto = json['protocol_version'];
    final deviceId = json['device_id'] as String?;
    final token = json['device_token'] as String?;
    final vaultId = json['vault_id'] as String?;
    if (channel == null ||
        proto is! int ||
        deviceId == null ||
        token == null ||
        vaultId == null) {
      throw const FormatException('Invalid PairingResult JSON');
    }
    return PairingResult(
      deviceId: deviceId,
      deviceName: (json['device_name'] as String?) ?? '',
      deviceToken: token,
      vaultId: vaultId,
      channel: channel,
      protocolVersion: proto,
    );
  }
}

/// Result of `SyncTransport.pushOps`.
@immutable
final class PushOpsResult {
  PushOpsResult({
    required this.acceptedCount,
    required this.duplicateCount,
    required this.latestSeqId,
    List<String> acceptedClientOpIds = const <String>[],
    this.skippedPrivateCount = 0,
  }) : acceptedClientOpIds = List<String>.unmodifiable(acceptedClientOpIds);

  final int acceptedCount;
  final int duplicateCount;
  final int latestSeqId;
  final List<String> acceptedClientOpIds;
  final int skippedPrivateCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'accepted_count': acceptedCount,
    'duplicate_count': duplicateCount,
    'latest_seq_id': latestSeqId,
    'accepted_client_op_ids': acceptedClientOpIds,
    if (skippedPrivateCount > 0) 'skipped_private_count': skippedPrivateCount,
  };

  factory PushOpsResult.fromJson(Map<String, Object?> json) {
    final rawIds = json['accepted_client_op_ids'];
    final ids = rawIds is List
        ? rawIds.whereType<String>().toList(growable: false)
        : const <String>[];
    return PushOpsResult(
      acceptedCount: (json['accepted_count'] as int?) ?? 0,
      duplicateCount: (json['duplicate_count'] as int?) ?? 0,
      latestSeqId: (json['latest_seq_id'] as int?) ?? 0,
      acceptedClientOpIds: ids,
      skippedPrivateCount: (json['skipped_private_count'] as int?) ?? 0,
    );
  }
}

/// Result of `SyncTransport.pullOps`.
@immutable
final class PullOpsResult {
  PullOpsResult({
    required List<SyncOpEnvelope> ops,
    required this.nextCursorSeq,
    required this.hasMore,
  }) : ops = List<SyncOpEnvelope>.unmodifiable(ops);

  final List<SyncOpEnvelope> ops;
  final int nextCursorSeq;
  final bool hasMore;

  Map<String, Object?> toJson() => <String, Object?>{
    'ops': ops.map((op) => op.toJson()).toList(growable: false),
    'next_cursor_seq': nextCursorSeq,
    'has_more': hasMore,
  };

  factory PullOpsResult.fromJson(Map<String, Object?> json) {
    final rawOps = json['ops'];
    final parsedOps = <SyncOpEnvelope>[];
    if (rawOps is List) {
      for (final item in rawOps) {
        if (item is Map) {
          parsedOps.add(
            SyncOpEnvelope.fromJson(
              item.map((k, v) => MapEntry<String, Object?>(k.toString(), v)),
            ),
          );
        }
      }
    }
    return PullOpsResult(
      ops: parsedOps,
      nextCursorSeq: (json['next_cursor_seq'] as int?) ?? 0,
      hasMore: json['has_more'] == true,
    );
  }
}

/// Result of `SyncTransport.downloadBlobRange`.
@immutable
final class BlobRangeResponse {
  const BlobRangeResponse({
    required this.bytes,
    required this.startOffset,
    required this.totalLength,
    required this.isPartial,
    required this.mimeType,
  });

  final Uint8List bytes;
  final int startOffset;
  final int totalLength;
  final bool isPartial;
  final String mimeType;
}

/// Result of local causal OpLog ingestion (`SyncEngine.ingestRemoteOps`).
@immutable
final class IngestOpsResult {
  IngestOpsResult({
    required this.acceptedCount,
    required this.duplicateCount,
    required this.conflictsCreated,
    required this.latestSeqId,
    List<String> acceptedClientOpIds = const <String>[],
    List<String> referencedBlobSha256s = const <String>[],
  }) : acceptedClientOpIds = List<String>.unmodifiable(acceptedClientOpIds),
       referencedBlobSha256s = List<String>.unmodifiable(referencedBlobSha256s);

  final int acceptedCount;
  final int duplicateCount;
  final int conflictsCreated;
  final int latestSeqId;
  final List<String> acceptedClientOpIds;
  final List<String> referencedBlobSha256s;
}

/// Summary of one bidirectional sync cycle (`SyncEngine.syncWithTransport`).
@immutable
final class SyncRunResult {
  const SyncRunResult({
    required this.pushedOps,
    required this.duplicateOps,
    required this.pulledOps,
    required this.appliedOps,
    required this.skippedPrivateOps,
    required this.conflictsCreated,
    required this.blobsUploaded,
    required this.blobsDownloaded,
    required this.completedAtUtc,
  });

  final int pushedOps;
  final int duplicateOps;
  final int pulledOps;
  final int appliedOps;
  final int skippedPrivateOps;
  final int conflictsCreated;
  final int blobsUploaded;
  final int blobsDownloaded;
  final DateTime completedAtUtc;
}

/// Live snapshot emitted by `VaultManager.watchSyncStatus`.
@immutable
final class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.pendingOutboxCount,
    required this.openConflictCount,
    required this.latestSeqId,
    this.lastSyncedAtUtc,
  });

  final int pendingOutboxCount;
  final int openConflictCount;
  final int latestSeqId;
  final DateTime? lastSyncedAtUtc;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStatusSnapshot &&
          pendingOutboxCount == other.pendingOutboxCount &&
          openConflictCount == other.openConflictCount &&
          latestSeqId == other.latestSeqId &&
          ((lastSyncedAtUtc == null && other.lastSyncedAtUtc == null) ||
              (lastSyncedAtUtc != null &&
                  other.lastSyncedAtUtc != null &&
                  lastSyncedAtUtc!.isAtSameMomentAs(other.lastSyncedAtUtc!)));

  @override
  int get hashCode => Object.hash(
    pendingOutboxCount,
    openConflictCount,
    latestSeqId,
    lastSyncedAtUtc?.toUtc(),
  );
}
