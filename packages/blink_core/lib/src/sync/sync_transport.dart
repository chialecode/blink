import 'dart:typed_data';

import 'sync_models.dart';

/// Unified transport contract shared by Channel A (Direct LAN/Tailscale `shelf`)
/// and Channel B (Client-side E2EE WebDAV / S3 async relay) (`DEC-023`, `INV-05`).
abstract interface class SyncTransport {
  /// Stable identifier used to persist cursors in `sync_state`.
  String get transportId;

  /// Whether this transport uses an untrusted async relay (enabling `#private` relay exclusion).
  bool get isRelayTransport;

  /// Probes remote peer/relay availability and validates channel & protocol compatibility.
  Future<SyncPeerHealth> checkHealth();

  /// Idempotently pushes local causal OpLog envelopes (`(device_id, client_op_id)` deduped).
  Future<PushOpsResult> pushOps(List<SyncOpEnvelope> ops);

  /// Pulls remote OpLog envelopes strictly after [sinceSeq] (or relay watermarks).
  Future<PullOpsResult> pullOps({required int sinceSeq, int limit = 200});

  /// Commits any pending pull watermarks after the caller has durably ingested pulled ops.
  Future<void> commitPullCursor(int nextCursorSeq);

  /// Checks whether the remote peer/relay already holds blob [sha256].
  Future<bool> hasBlob(String sha256);

  /// Uploads raw (Channel A) or E2EE-encrypted (Channel B) blob bytes verified by [sha256].
  Future<void> uploadBlob({
    required String sha256,
    required Uint8List bytes,
    required String mimeType,
  });

  /// Downloads a full or partial byte range for blob [sha256] (`Range` resume on Channel A).
  Future<BlobRangeResponse> downloadBlobRange({
    required String sha256,
    int startOffset = 0,
    int? endOffsetInclusive,
  });
}

/// Optional key-value state callback backed by `sync_state` for transports
/// that maintain per-device relay watermarks.
abstract interface class SyncStateStore {
  String? read(String key);
  void write(String key, String value);
}
