import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../repositories/raw_repository.dart';
import '../search/fts_search_service.dart';
import '../storage/blob_store.dart';
import '../utils/hlc.dart';
import '../utils/uuid_v7.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

/// Deterministic causal OpLog convergence engine, dual-copy conflict manager,
/// `#private` relay guard, and device registry (`INV-01`, `INV-03`, `INV-05`, `INV-07`, `INV-08`).
final class SyncEngine implements SyncStateStore {
  SyncEngine({
    required this._dbProvider,
    required this._runWriteTx,
    required this._deviceIdProvider,
    required this._deviceNameProvider,
    required this._hlcClock,
    required this._bfm,
    required this._fts,
    required this._blobs,
    required this._rawRepository,
    required this._onMutated,
    required this._mutationStream,
  });

  final Database Function() _dbProvider;
  final T Function<T>(T Function(Database db) action) _runWriteTx;
  final String Function() _deviceIdProvider;
  final String Function() _deviceNameProvider;
  final HlcClock _hlcClock;
  final BfmEngine _bfm;
  final SqliteFtsSearchService _fts;
  final BlobStore _blobs;
  final RawRepository _rawRepository;
  final void Function({required bool triggerMirror}) _onMutated;
  final Stream<int> _mutationStream;

  final StreamController<int> _seqController =
      StreamController<int>.broadcast();
  int _lastBroadcastSeq = 0;

  /// Broadcast stream emitting strictly increasing `sync_oplog.seq_id` values
  /// whenever local writes or remote sync ingestion advances the OpLog.
  Stream<int> get seqStream => _seqController.stream;

  /// Notifies SSE listeners if local writes advanced `sync_oplog.seq_id`.
  void notifyLocalSeqAdvanced() {
    if (_seqController.isClosed) {
      return;
    }
    try {
      final latest = getLatestSeqId();
      if (latest > _lastBroadcastSeq) {
        _lastBroadcastSeq = latest;
        _seqController.add(latest);
      }
    } catch (_) {
      // Ignore if vault is closing.
    }
  }

  /// Releases broadcast stream resources during vault shutdown.
  Future<void> dispose() async {
    if (!_seqController.isClosed) {
      await _seqController.close();
    }
  }

  @override
  String? read(String key) {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT value FROM sync_state WHERE key = ? LIMIT 1',
      <Object?>[key],
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String;
  }

  @override
  void write(String key, String value) {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    _runWriteTx<void>((db) {
      db.execute(
        'INSERT INTO sync_state (key, value, updated_at) VALUES (?, ?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
        <Object?>[key, value, nowIso],
      );
    });
  }

  int getLatestSeqId() {
    final db = _dbProvider();
    return (db
                .select(
                  'SELECT COALESCE(MAX(seq_id), 0) AS max_seq FROM sync_oplog',
                )
                .first['max_seq']
            as int?) ??
        0;
  }

  int getPendingOutboxCount() {
    final db = _dbProvider();
    return (db
                .select(
                  "SELECT COUNT(*) AS c FROM outbox_ops WHERE status = 'pending'",
                )
                .first['c']
            as int?) ??
        0;
  }

  int getOpenConflictCount() {
    final db = _dbProvider();
    return (db
                .select(
                  "SELECT COUNT(*) AS c FROM sync_conflicts WHERE status = 'open'",
                )
                .first['c']
            as int?) ??
        0;
  }

  DateTime? getLastSyncedAtUtc() {
    final raw = read('last_synced_at_utc');
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toUtc();
  }

  SyncStatusSnapshot getSyncStatus() => SyncStatusSnapshot(
    pendingOutboxCount: getPendingOutboxCount(),
    openConflictCount: getOpenConflictCount(),
    latestSeqId: getLatestSeqId(),
    lastSyncedAtUtc: getLastSyncedAtUtc(),
  );

  Stream<int> watchPendingOutboxCount() =>
      _watch(() async => getPendingOutboxCount());

  Stream<List<SyncConflict>> watchOpenConflicts() => _watch(listOpenConflicts);

  Stream<SyncStatusSnapshot> watchSyncStatus() =>
      _watch(() async => getSyncStatus());

  Future<List<SyncConflict>> listOpenConflicts() =>
      listConflicts(status: SyncConflictStatus.open);

  Future<List<SyncConflict>> listConflicts({SyncConflictStatus? status}) async {
    final db = _dbProvider();
    final ResultSet rows;
    if (status != null) {
      rows = db.select(
        'SELECT * FROM sync_conflicts WHERE status = ? ORDER BY created_at DESC, id DESC',
        <Object?>[status.wireValue],
      );
    } else {
      rows = db.select(
        'SELECT * FROM sync_conflicts ORDER BY created_at DESC, id DESC',
      );
    }
    return rows.map(_rowToConflict).toList(growable: false);
  }

  /// Resolves a preserved dual-copy conflict and emits clean causal updates if
  /// the main entry body changed (`INV-01`, `INV-05`).
  Future<SyncConflict> resolveConflict({
    required String conflictId,
    required ConflictResolutionChoice resolution,
    String? mergedBodyMd,
  }) async {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT * FROM sync_conflicts WHERE id = ? LIMIT 1',
      <Object?>[conflictId],
    );
    if (rows.isEmpty) {
      throw BlinkException(
        code: BlinkErrorCode.notFound,
        message: 'Conflict $conflictId not found',
      );
    }
    final conflict = _rowToConflict(rows.first);

    if (conflict.entityType == 'raw_entry') {
      switch (resolution) {
        case ConflictResolutionChoice.keepCurrent:
          await _softDeleteCopyIfPresent(conflict.localCopyId);
        case ConflictResolutionChoice.keepConflictCopy:
          final mainEntry = await _rawRepository.getEntryById(
            conflict.entityId,
            includeDeleted: true,
          );
          if (mainEntry == null) {
            throw BlinkException(
              code: BlinkErrorCode.notFound,
              message: 'Conflict target entry ${conflict.entityId} not found',
            );
          }
          final targetBody =
              mergedBodyMd ??
              (mainEntry.bodyMd == conflict.localBodyMd
                  ? conflict.remoteBodyMd
                  : conflict.localBodyMd);
          await _rawRepository.updateEntry(
            id: conflict.entityId,
            bodyMd: targetBody,
          );
          await _softDeleteCopyIfPresent(conflict.localCopyId);
        case ConflictResolutionChoice.keepBoth:
          // Preserve both entries intact; only close the conflict record.
          break;
        case ConflictResolutionChoice.customMerge:
          if (mergedBodyMd == null) {
            throw BlinkException(
              code: BlinkErrorCode.invalidArgument,
              message: 'mergedBodyMd is required for customMerge resolution',
            );
          }
          await _rawRepository.updateEntry(
            id: conflict.entityId,
            bodyMd: mergedBodyMd,
          );
          await _softDeleteCopyIfPresent(conflict.localCopyId);
      }
    } else if (conflict.entityType == 'raw_annotation') {
      if (resolution == ConflictResolutionChoice.keepConflictCopy ||
          resolution == ConflictResolutionChoice.customMerge) {
        final nextNote = resolution == ConflictResolutionChoice.customMerge
            ? mergedBodyMd
            : (mergedBodyMd ?? conflict.remoteBodyMd);
        if (nextNote == null) {
          throw BlinkException(
            code: BlinkErrorCode.invalidArgument,
            message: 'mergedBodyMd is required for customMerge resolution',
          );
        }
        final nowUtc = DateTime.now().toUtc();
        final nowIso = nowUtc.toIso8601String();
        final hlcTs = _hlcClock.next(nowUtc: nowUtc);
        _runWriteTx<void>((txDb) {
          txDb.execute(
            'UPDATE raw_annotations SET note_md = ?, revision = revision + 1, '
            'hlc_ts = ?, updated_at = ? WHERE id = ?',
            <Object?>[nextNote, hlcTs, nowIso, conflict.entityId],
          );
        });
      }
    }

    final resolvedAtUtc = DateTime.now().toUtc();
    final resolvedAtIso = resolvedAtUtc.toIso8601String();
    _runWriteTx<void>((txDb) {
      txDb.execute(
        "UPDATE sync_conflicts SET status = 'resolved', resolution = ?, resolved_at = ? "
        'WHERE id = ?',
        <Object?>[resolution.wireValue, resolvedAtIso, conflictId],
      );
    });
    _onMutated(triggerMirror: true);

    return SyncConflict(
      id: conflict.id,
      entityType: conflict.entityType,
      entityId: conflict.entityId,
      localCopyId: conflict.localCopyId,
      remoteDeviceId: conflict.remoteDeviceId,
      remoteDeviceName: conflict.remoteDeviceName,
      remoteHlcTs: conflict.remoteHlcTs,
      localBodyMd: conflict.localBodyMd,
      remoteBodyMd: conflict.remoteBodyMd,
      status: SyncConflictStatus.resolved,
      resolution: resolution.wireValue,
      createdAtUtc: conflict.createdAtUtc,
      resolvedAtUtc: resolvedAtUtc,
    );
  }

  /// Reads OpLog envelopes with `seq_id > sinceSeq` for `GET /api/v1/sync/pull`.
  Future<PullOpsResult> readOplogSince({
    required int sinceSeq,
    int limit = 200,
  }) async {
    if (sinceSeq < 0 || limit <= 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'sinceSeq must be >= 0 and limit must be > 0',
      );
    }
    final db = _dbProvider();
    final clampedLimit = limit.clamp(1, 1000);
    final rows = db.select(
      'SELECT o.*, d.device_name AS known_device_name '
      'FROM sync_oplog o '
      'LEFT JOIN sync_devices d ON d.device_id = o.device_id '
      'WHERE o.seq_id > ? '
      'ORDER BY o.seq_id ASC '
      'LIMIT ?',
      <Object?>[sinceSeq, clampedLimit + 1],
    );

    final hasMore = rows.length > clampedLimit;
    final slice = hasMore ? rows.take(clampedLimit) : rows;
    final localId = _deviceIdProvider();
    final localName = _deviceNameProvider();
    final ops = <SyncOpEnvelope>[];
    var nextCursor = sinceSeq;

    for (final row in slice) {
      final op = _oplogRowToEnvelope(
        row,
        localDeviceId: localId,
        localDeviceName: localName,
      );
      ops.add(op);
      if (op.seqId != null && op.seqId! > nextCursor) {
        nextCursor = op.seqId!;
      }
    }

    return PullOpsResult(ops: ops, nextCursorSeq: nextCursor, hasMore: hasMore);
  }

  /// Idempotently ingests remote causal OpLog envelopes, applying each unseen
  /// `(device_id, client_op_id)` in deterministic `(hlc_ts, device_id, client_op_id)` order.
  ///
  /// Applied remote ops update local tables, FTS, and mirror/UI streams, and are
  /// NEVER echoed back into `outbox_ops` (`INV-05`).
  Future<IngestOpsResult> ingestRemoteOps(List<SyncOpEnvelope> rawOps) async {
    if (rawOps.isEmpty) {
      return IngestOpsResult(
        acceptedCount: 0,
        duplicateCount: 0,
        conflictsCreated: 0,
        latestSeqId: getLatestSeqId(),
      );
    }

    final sortedOps = List<SyncOpEnvelope>.of(rawOps)
      ..sort(SyncOpEnvelope.compareCausalOrder);

    var acceptedCount = 0;
    var duplicateCount = 0;
    var conflictsCreated = 0;
    final acceptedClientOpIds = <String>[];
    final duplicateClientOpIds = <String>[];
    final referencedBlobs = <String>{};
    final entriesToIndex = <RawEntry>[];
    final tasksToIndex = <RawTask>[];
    final docsToRemoveFromFts = <String>[];

    final latestSeqId = _runWriteTx<int>((db) {
      for (final op in sortedOps) {
        final existingOp = db.select(
          'SELECT seq_id FROM sync_oplog WHERE device_id = ? AND client_op_id = ? LIMIT 1',
          <Object?>[op.deviceId, op.clientOpId],
        );
        if (existingOp.isNotEmpty) {
          duplicateCount += 1;
          duplicateClientOpIds.add(op.clientOpId);
          continue;
        }

        _hlcClock.observe(op.hlcTs);
        db.execute(
          'INSERT INTO sync_oplog '
          '(device_id, client_op_id, hlc_ts, base_revision, entity_layer, entity_type, '
          'entity_id, op_type, op_origin, privacy_level, payload_json, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            op.deviceId,
            op.clientOpId,
            op.hlcTs,
            op.baseRevision,
            op.entityLayer.wireValue,
            op.entityType,
            op.entityId,
            op.opType,
            op.opOrigin,
            op.privacyLevel.wireValue,
            op.payloadJson,
            op.createdAtUtc.toUtc().toIso8601String(),
          ],
        );

        acceptedCount += 1;
        acceptedClientOpIds.add(op.clientOpId);
        _collectPayloadBlobShas(op.payload, referencedBlobs);

        final createdConflict = _applySingleOpInTx(
          db,
          op,
          entriesToIndex: entriesToIndex,
          tasksToIndex: tasksToIndex,
          docsToRemoveFromFts: docsToRemoveFromFts,
        );
        if (createdConflict) {
          conflictsCreated += 1;
        }
      }

      return (db
                  .select(
                    'SELECT COALESCE(MAX(seq_id), 0) AS max_seq FROM sync_oplog',
                  )
                  .first['max_seq']
              as int?) ??
          0;
    });

    if (acceptedCount > 0) {
      for (final docId in docsToRemoveFromFts) {
        _fts.removeDocumentSync(docId);
      }
      for (final entry in entriesToIndex) {
        _fts.indexEntrySync(entry);
      }
      for (final task in tasksToIndex) {
        _fts.indexTaskSync(task);
      }
      _onMutated(triggerMirror: true);
      if (!_seqController.isClosed && latestSeqId > _lastBroadcastSeq) {
        _lastBroadcastSeq = latestSeqId;
        _seqController.add(latestSeqId);
      }
    }

    return IngestOpsResult(
      acceptedCount: acceptedCount,
      duplicateCount: duplicateCount,
      conflictsCreated: conflictsCreated,
      latestSeqId: latestSeqId,
      acceptedClientOpIds: acceptedClientOpIds,
      duplicateClientOpIds: duplicateClientOpIds,
      referencedBlobSha256s: referencedBlobs.toList(growable: false),
    );
  }

  /// Executes one full push + pull + blob-reconciliation sync cycle against [transport].
  Future<SyncRunResult> syncWithTransport(
    SyncTransport transport, {
    bool? excludePrivate,
    int pushBatchSize = 200,
    int pullBatchSize = 200,
    int blobDownloadChunkSize = 262144,
  }) async {
    if (pushBatchSize <= 0 ||
        pullBatchSize <= 0 ||
        blobDownloadChunkSize <= 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Batch and chunk sizes must be positive integers',
      );
    }

    // Enforce transport-level `#private` exclusion (`INV-03`): if the transport
    // itself enforces `excludesPrivateOps == true`, callers cannot bypass it.
    final effectiveExcludePrivate =
        (excludePrivate ?? transport.excludesPrivateOps) ||
        transport.excludesPrivateOps;

    await transport.checkHealth();

    final legacyPushCursorKey = 'push_seq:${transport.transportId}';
    final pushNormalCursorKey = 'push_seq_normal:${transport.transportId}';
    final pushPrivateCursorKey = 'push_seq_private:${transport.transportId}';
    final pullCursorKey = 'pull_seq:${transport.transportId}';

    final legacyPushSeq = int.tryParse(read(legacyPushCursorKey) ?? '') ?? 0;
    final lastNormalSeq =
        int.tryParse(read(pushNormalCursorKey) ?? '') ?? legacyPushSeq;
    final lastPrivateSeq =
        int.tryParse(read(pushPrivateCursorKey) ?? '') ??
        (transport.isRelayTransport ? 0 : lastNormalSeq);

    final minScanSeq = effectiveExcludePrivate
        ? lastNormalSeq
        : (lastNormalSeq < lastPrivateSeq ? lastNormalSeq : lastPrivateSeq);
    final candidateOps = _readLocalOpsAfterSeq(minScanSeq);

    final opsToPush = <SyncOpEnvelope>[];
    final opIsPrivateByClientId = <String, bool>{};
    var skippedPrivateOps = 0;
    var highestScannedSeq = lastNormalSeq;

    for (final op in candidateOps) {
      final seq = op.seqId ?? 0;
      if (seq > highestScannedSeq) {
        highestScannedSeq = seq;
      }
      final isPriv = _isOpOrCurrentEntityPrivate(op);
      opIsPrivateByClientId[op.clientOpId] = isPriv;

      if (isPriv) {
        if (effectiveExcludePrivate) {
          if (seq > lastNormalSeq) {
            skippedPrivateOps += 1;
          }
          // Leave `push_seq_private` unchanged so disabling exclusion later
          // backfills all historical `#private` ops cleanly.
          continue;
        }
        if (seq <= lastPrivateSeq) {
          continue;
        }
        opsToPush.add(op);
      } else {
        if (seq <= lastNormalSeq) {
          continue;
        }
        opsToPush.add(op);
      }
    }

    var blobsUploaded = 0;
    var pushedOps = 0;
    var duplicateOps = 0;
    var currentNormalSeq = lastNormalSeq;
    var currentPrivateSeq = lastPrivateSeq;
    final uploadedBlobsThisRun = <String>{};

    for (var offset = 0; offset < opsToPush.length; offset += pushBatchSize) {
      final end = (offset + pushBatchSize).clamp(0, opsToPush.length);
      final chunk = opsToPush.sublist(offset, end);

      final blobsToUpload = _collectUploadableBlobs(
        chunk,
        excludePrivate: effectiveExcludePrivate,
      );
      for (final sha256 in blobsToUpload) {
        if (!uploadedBlobsThisRun.add(sha256)) {
          continue;
        }
        if (await transport.hasBlob(sha256)) {
          continue;
        }
        final meta = await _blobs.getMetadata(sha256);
        final bytes = await _blobs.readBytes(sha256);
        if (meta == null || bytes == null) {
          continue;
        }
        final verifiedSha = crypto.sha256.convert(bytes).toString();
        if (verifiedSha != sha256) {
          throw BlinkException(
            code: BlinkErrorCode.ioError,
            message: 'Local blob integrity check failed for $sha256',
          );
        }
        await transport.uploadBlob(
          sha256: sha256,
          bytes: bytes,
          mimeType: meta.mimeType,
        );
        blobsUploaded += 1;
      }

      final pushRes = await transport.pushOps(chunk);
      pushedOps += pushRes.acceptedCount;
      duplicateOps += pushRes.duplicateCount;
      skippedPrivateOps += pushRes.skippedPrivateCount;

      var ackIds = pushRes.acknowledgedClientOpIds;
      if (ackIds.isEmpty &&
          pushRes.skippedPrivateCount == 0 &&
          (pushRes.acceptedCount + pushRes.duplicateCount) == chunk.length) {
        ackIds = chunk.map((op) => op.clientOpId).toList(growable: false);
      }
      final ackSet = ackIds.toSet();
      _markOutboxOpsSent(ackIds);

      var chunkMaxNormal = currentNormalSeq;
      var chunkMaxPrivate = currentPrivateSeq;
      for (final op in chunk) {
        final seq = op.seqId ?? 0;
        if (!ackSet.contains(op.clientOpId)) {
          continue;
        }
        if (opIsPrivateByClientId[op.clientOpId] == true) {
          if (seq > chunkMaxPrivate) {
            chunkMaxPrivate = seq;
          }
        } else {
          if (seq > chunkMaxNormal) {
            chunkMaxNormal = seq;
          }
        }
      }
      if (chunkMaxNormal > currentNormalSeq) {
        currentNormalSeq = chunkMaxNormal;
        write(pushNormalCursorKey, currentNormalSeq.toString());
      }
      if (chunkMaxPrivate > currentPrivateSeq) {
        currentPrivateSeq = chunkMaxPrivate;
        write(pushPrivateCursorKey, currentPrivateSeq.toString());
      }
    }

    // When private ops were intentionally skipped, advance only the normal lane
    // past the highest scanned seq so they are not re-scanned on every normal sync,
    // while keeping `push_seq_private` untouched for future backfill.
    if (effectiveExcludePrivate && highestScannedSeq > currentNormalSeq) {
      currentNormalSeq = highestScannedSeq;
      write(pushNormalCursorKey, currentNormalSeq.toString());
    }

    var pulledOps = 0;
    var appliedOps = 0;
    var conflictsCreated = 0;
    var blobsDownloaded = 0;
    var pullCursor = int.tryParse(read(pullCursorKey) ?? '') ?? 0;

    while (true) {
      final pullRes = await transport.pullOps(
        sinceSeq: pullCursor,
        limit: pullBatchSize,
      );
      pulledOps += pullRes.ops.length;

      if (pullRes.ops.isNotEmpty) {
        final ingestRes = await ingestRemoteOps(pullRes.ops);
        appliedOps += ingestRes.acceptedCount;
        conflictsCreated += ingestRes.conflictsCreated;

        for (final sha256 in ingestRes.referencedBlobSha256s) {
          final existingFile = await _blobs.resolveFile(sha256);
          if (existingFile != null) {
            continue;
          }
          if (!await transport.hasBlob(sha256)) {
            continue;
          }
          final downloaded = await _downloadVerifiedBlob(
            transport,
            sha256: sha256,
            chunkSize: blobDownloadChunkSize,
          );
          await _blobs.putBytes(
            downloaded.bytes,
            mimeType: downloaded.mimeType,
          );
          blobsDownloaded += 1;
        }
      }

      if (pullRes.nextCursorSeq > pullCursor) {
        pullCursor = pullRes.nextCursorSeq;
        write(pullCursorKey, pullCursor.toString());
      }
      await transport.commitPullCursor(pullCursor);

      if (!pullRes.hasMore) {
        break;
      }
    }

    final completedAtUtc = DateTime.now().toUtc();
    write('last_synced_at_utc', completedAtUtc.toIso8601String());
    _onMutated(triggerMirror: false);

    return SyncRunResult(
      pushedOps: pushedOps,
      duplicateOps: duplicateOps,
      pulledOps: pulledOps,
      appliedOps: appliedOps,
      skippedPrivateOps: skippedPrivateOps,
      conflictsCreated: conflictsCreated,
      blobsUploaded: blobsUploaded,
      blobsDownloaded: blobsDownloaded,
      completedAtUtc: completedAtUtc,
    );
  }

  /// Registers or re-pairs a peer device storing ONLY `tokenSha256` (`INV-08`).
  Future<SyncDeviceRecord> registerOrUpdateDevice({
    required String deviceId,
    required String deviceName,
    required String tokenSha256,
  }) async {
    if (deviceId.trim().isEmpty || !isValidBlobSha256(tokenSha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid deviceId or tokenSha256',
      );
    }
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final trimmedId = deviceId.trim();
    final trimmedName = deviceName.trim().isEmpty
        ? _shortDeviceLabel(trimmedId)
        : deviceName.trim();

    _runWriteTx<void>((db) {
      db.execute(
        'INSERT INTO sync_devices '
        '(device_id, device_name, token_sha256, revoked_at, last_seen_at, created_at) '
        'VALUES (?, ?, ?, NULL, ?, ?) '
        'ON CONFLICT(device_id) DO UPDATE SET '
        'device_name = excluded.device_name, '
        'token_sha256 = excluded.token_sha256, '
        'revoked_at = NULL, '
        'last_seen_at = excluded.last_seen_at',
        <Object?>[trimmedId, trimmedName, tokenSha256, nowIso, nowIso],
      );
    });
    _onMutated(triggerMirror: false);
    return SyncDeviceRecord(
      deviceId: trimmedId,
      deviceName: trimmedName,
      tokenSha256: tokenSha256,
      lastSeenAtUtc: nowUtc,
      createdAtUtc: nowUtc,
    );
  }

  /// Looks up a registered device by its token's `SHA-256` hex hash using
  /// constant-time digest verification.
  Future<SyncDeviceRecord?> findDeviceByTokenSha256(String tokenSha256) async {
    if (!isValidBlobSha256(tokenSha256)) {
      return null;
    }
    final db = _dbProvider();
    final rows = db.select('SELECT * FROM sync_devices');
    SyncDeviceRecord? matched;
    for (final row in rows) {
      final candidate = row['token_sha256'] as String;
      if (_constantTimeEqualsAscii(candidate, tokenSha256)) {
        matched = _rowToDevice(row);
      }
    }
    return matched;
  }

  Future<List<SyncDeviceRecord>> listDevices() async {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT * FROM sync_devices ORDER BY created_at DESC, device_id ASC',
    );
    return rows.map(_rowToDevice).toList(growable: false);
  }

  Future<bool> revokeDevice(String deviceId) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final changed = _runWriteTx<bool>((db) {
      final existing = db.select(
        'SELECT device_id FROM sync_devices WHERE device_id = ? LIMIT 1',
        <Object?>[deviceId],
      );
      if (existing.isEmpty) {
        return false;
      }
      db.execute(
        'UPDATE sync_devices SET revoked_at = ? WHERE device_id = ?',
        <Object?>[nowIso, deviceId],
      );
      return true;
    });
    if (changed) {
      _onMutated(triggerMirror: false);
    }
    return changed;
  }

  Future<void> touchDeviceLastSeen(String deviceId) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    _runWriteTx<void>((db) {
      db.execute(
        'UPDATE sync_devices SET last_seen_at = ? WHERE device_id = ?',
        <Object?>[nowIso, deviceId],
      );
    });
  }

  List<SyncOpEnvelope> _readLocalOpsAfterSeq(int afterSeq) {
    final db = _dbProvider();
    final localId = _deviceIdProvider();
    final localName = _deviceNameProvider();
    final rows = db.select(
      'SELECT * FROM sync_oplog '
      'WHERE device_id = ? AND seq_id > ? '
      'ORDER BY seq_id ASC',
      <Object?>[localId, afterSeq],
    );
    return rows
        .map(
          (row) => _oplogRowToEnvelope(
            row,
            localDeviceId: localId,
            localDeviceName: localName,
          ),
        )
        .toList(growable: false);
  }

  bool _isOpOrCurrentEntityPrivate(SyncOpEnvelope op) {
    if (op.privacyLevel == PrivacyLevel.private) {
      return true;
    }
    final payloadPrivacy = PrivacyLevel.tryParse(
      op.payload['privacy_level'] as String?,
    );
    if (payloadPrivacy == PrivacyLevel.private) {
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
    final embeddedTasks = op.payload['tasks'];
    if (embeddedTasks is List) {
      for (final item in embeddedTasks) {
        if (item is Map &&
            item['privacy_level'] == PrivacyLevel.private.wireValue) {
          return true;
        }
      }
    }

    final db = _dbProvider();
    // Defense-in-depth (`INV-03`): if any historical OpLog row for this entity
    // was ever upgraded to `private`, keep it private even after permanent purge.
    if (db.select(
      "SELECT 1 FROM sync_oplog WHERE entity_type = ? AND entity_id = ? AND privacy_level = 'private' LIMIT 1",
      <Object?>[op.entityType, op.entityId],
    ).isNotEmpty) {
      return true;
    }

    switch (op.entityType) {
      case 'raw_entry':
        return db.select(
          "SELECT 1 FROM raw_entries WHERE id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'raw_task':
        final taskRows = db.select(
          'SELECT privacy_level, origin_entry_id FROM raw_tasks WHERE id = ? LIMIT 1',
          <Object?>[op.entityId],
        );
        String? originEntryId = op.payload['origin_entry_id'] as String?;
        if (taskRows.isNotEmpty) {
          if (taskRows.first['privacy_level'] ==
              PrivacyLevel.private.wireValue) {
            return true;
          }
          originEntryId ??= taskRows.first['origin_entry_id'] as String?;
        }
        if (originEntryId != null && originEntryId.isNotEmpty) {
          if (db.select(
            "SELECT 1 FROM raw_entries WHERE id = ? AND privacy_level = 'private' LIMIT 1",
            <Object?>[originEntryId],
          ).isNotEmpty) {
            return true;
          }
          if (db.select(
            "SELECT 1 FROM sync_oplog WHERE entity_type = 'raw_entry' AND entity_id = ? AND privacy_level = 'private' LIMIT 1",
            <Object?>[originEntryId],
          ).isNotEmpty) {
            return true;
          }
        }
        return false;
      case 'raw_source':
        return db.select(
          "SELECT 1 FROM raw_sources WHERE id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'raw_annotation':
        final annRows = db.select(
          'SELECT privacy_level, source_id FROM raw_annotations WHERE id = ? LIMIT 1',
          <Object?>[op.entityId],
        );
        String? sourceId = op.payload['source_id'] as String?;
        if (annRows.isNotEmpty) {
          if (annRows.first['privacy_level'] ==
              PrivacyLevel.private.wireValue) {
            return true;
          }
          sourceId ??= annRows.first['source_id'] as String?;
        }
        if (sourceId != null && sourceId.isNotEmpty) {
          if (db.select(
            "SELECT 1 FROM raw_sources WHERE id = ? AND privacy_level = 'private' LIMIT 1",
            <Object?>[sourceId],
          ).isNotEmpty) {
            return true;
          }
          if (db.select(
            "SELECT 1 FROM sync_oplog WHERE entity_type = 'raw_source' AND entity_id = ? AND privacy_level = 'private' LIMIT 1",
            <Object?>[sourceId],
          ).isNotEmpty) {
            return true;
          }
        }
        return false;
      case 'ai_entry_enrichment':
        if (db.select(
          "SELECT 1 FROM ai_entry_enrichments WHERE entry_id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty) {
          return true;
        }
        return db.select(
          "SELECT 1 FROM raw_entries WHERE id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'ai_task_candidate':
        return db.select(
          "SELECT 1 FROM ai_task_candidates WHERE id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'ai_user_principle':
        return db.select(
          "SELECT 1 FROM ai_user_principles WHERE id = ? AND privacy_level = 'private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'ai_synthesis':
        return db.select(
          "SELECT 1 FROM ai_syntheses WHERE id = ? AND privacy_scope = 'local_with_private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      case 'ai_echo_link':
        return db.select(
          "SELECT 1 FROM ai_echo_links WHERE id = ? AND privacy_scope = 'local_with_private' LIMIT 1",
          <Object?>[op.entityId],
        ).isNotEmpty;
      default:
        return false;
    }
  }

  List<String> _collectUploadableBlobs(
    List<SyncOpEnvelope> normalOps, {
    required bool excludePrivate,
  }) {
    final candidates = <String>{};
    for (final op in normalOps) {
      _collectPayloadBlobShas(op.payload, candidates);
    }
    if (!excludePrivate || candidates.isEmpty) {
      return candidates.toList(growable: false);
    }

    // Defense-in-depth (`INV-03`): ensure no candidate blob is referenced solely
    // by `#private` entities in the live database.
    final db = _dbProvider();
    final normalReferenced = <String>{};
    for (final row in db.select(
      "SELECT audio_blob_sha256, image_blob_sha256s FROM raw_entries WHERE privacy_level = 'normal'",
    )) {
      final audio = row['audio_blob_sha256'] as String?;
      if (audio != null && isValidBlobSha256(audio)) {
        normalReferenced.add(audio);
      }
      normalReferenced.addAll(
        decodeStringListJson(row['image_blob_sha256s'] as String?),
      );
    }
    for (final row in db.select(
      "SELECT file_blob_sha256, cover_blob_sha256 FROM raw_sources WHERE privacy_level = 'normal'",
    )) {
      final fileSha = row['file_blob_sha256'] as String?;
      if (fileSha != null && isValidBlobSha256(fileSha)) {
        normalReferenced.add(fileSha);
      }
      final coverSha = row['cover_blob_sha256'] as String?;
      if (coverSha != null && isValidBlobSha256(coverSha)) {
        normalReferenced.add(coverSha);
      }
    }

    return candidates
        .where((sha) => normalReferenced.contains(sha))
        .toList(growable: false);
  }

  void _markOutboxOpsSent(List<String> clientOpIds) {
    if (clientOpIds.isEmpty) {
      return;
    }
    _runWriteTx<void>((db) {
      final stmt = db.prepare(
        "UPDATE outbox_ops SET status = 'sent' WHERE client_op_id = ?",
      );
      try {
        for (final opId in clientOpIds) {
          stmt.execute(<Object?>[opId]);
        }
      } finally {
        stmt.close();
      }
    });
  }

  Future<({Uint8List bytes, String mimeType})> _downloadVerifiedBlob(
    SyncTransport transport, {
    required String sha256,
    required int chunkSize,
  }) async {
    final buffer = BytesBuilder(copy: false);
    var offset = 0;
    int? totalLength;
    var mimeType = 'application/octet-stream';

    while (true) {
      final endInclusive = offset + chunkSize - 1;
      final res = await transport.downloadBlobRange(
        sha256: sha256,
        startOffset: offset,
        endOffsetInclusive: endInclusive,
      );
      mimeType = res.mimeType;
      totalLength ??= res.totalLength;
      buffer.add(res.bytes);
      offset += res.bytes.length;

      if (!res.isPartial || res.bytes.isEmpty || offset >= totalLength) {
        break;
      }
    }

    final bytes = buffer.takeBytes();
    final actualSha = crypto.sha256.convert(bytes).toString();
    if (actualSha != sha256) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message:
            'Downloaded blob SHA-256 verification failed: expected $sha256, got $actualSha',
      );
    }
    return (bytes: bytes, mimeType: mimeType);
  }

  Future<void> _softDeleteCopyIfPresent(String copyId) async {
    // Conflict copies are local-only preservation entries that are never
    // published to `sync_oplog`/`outbox_ops`; soft-delete them locally without
    // broadcasting an unknown `soft_delete` op to peers (`INV-05`).
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final hlcTs = _hlcClock.next();
    final taskIdsToRemove = <String>[];
    final deleted = _runWriteTx<bool>((db) {
      final rows = db.select(
        'SELECT deleted_at FROM raw_entries WHERE id = ? LIMIT 1',
        <Object?>[copyId],
      );
      if (rows.isEmpty || rows.first['deleted_at'] != null) {
        return false;
      }
      db.execute(
        'UPDATE raw_entries SET deleted_at = ?, updated_at = ?, hlc_ts = ? '
        'WHERE id = ?',
        <Object?>[nowIso, nowIso, hlcTs, copyId],
      );
      for (final row in db.select(
        'SELECT id FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[copyId],
      )) {
        taskIdsToRemove.add(row['id'] as String);
      }
      db.execute(
        'UPDATE raw_tasks SET deleted_at = ?, updated_at = ?, hlc_ts = ? '
        'WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[nowIso, nowIso, hlcTs, copyId],
      );
      return true;
    });
    if (deleted) {
      _fts.removeDocumentSync(copyId);
      for (final taskId in taskIdsToRemove) {
        _fts.removeDocumentSync(taskId);
      }
    }
  }

  bool _applySingleOpInTx(
    Database db,
    SyncOpEnvelope op, {
    required List<RawEntry> entriesToIndex,
    required List<RawTask> tasksToIndex,
    required List<String> docsToRemoveFromFts,
  }) {
    if (op.entityLayer == SyncEntityLayer.ai) {
      _applyAiDerivedOpInTx(db, op);
      return false;
    }

    switch (op.entityType) {
      case 'raw_entry':
        return _applyRawEntryOpInTx(
          db,
          op,
          entriesToIndex: entriesToIndex,
          tasksToIndex: tasksToIndex,
          docsToRemoveFromFts: docsToRemoveFromFts,
        );
      case 'raw_task':
        _applyRawTaskOpInTx(
          db,
          op,
          tasksToIndex: tasksToIndex,
          docsToRemoveFromFts: docsToRemoveFromFts,
        );
        return false;
      case 'raw_annotation':
        return _applyRawAnnotationOpInTx(db, op);
      case 'raw_source':
        _applyRawSourceOpInTx(db, op);
        return false;
      default:
        return false;
    }
  }

  bool _applyRawEntryOpInTx(
    Database db,
    SyncOpEnvelope op, {
    required List<RawEntry> entriesToIndex,
    required List<RawTask> tasksToIndex,
    required List<String> docsToRemoveFromFts,
  }) {
    final existingRows = db.select(
      'SELECT * FROM raw_entries WHERE id = ? LIMIT 1',
      <Object?>[op.entityId],
    );
    final existing = existingRows.isEmpty
        ? null
        : rowToRawEntry(existingRows.first);

    final payload = op.payload;
    final remoteBodyMd = payload['body_md'] as String?;
    final remoteParsed = remoteBodyMd != null ? _bfm.parse(remoteBodyMd) : null;
    final payloadPrivacy =
        PrivacyLevel.tryParse(payload['privacy_level'] as String?) ??
        op.privacyLevel;
    final remoteIsPrivate =
        op.privacyLevel == PrivacyLevel.private ||
        payloadPrivacy == PrivacyLevel.private ||
        (remoteParsed?.hasPrivateToken ?? false);

    // Case 1: Brand new entry on this device -> zero-conflict union insert.
    if (existing == null) {
      if (remoteBodyMd == null && op.opType == 'soft_delete') {
        return false;
      }
      final bodyMd = remoteBodyMd ?? '';
      final parsed = remoteParsed ?? _bfm.parse(bodyMd);
      final effectivePrivacy = remoteIsPrivate
          ? PrivacyLevel.private
          : PrivacyLevel.normal;
      final kind =
          EntryKind.tryParse(payload['entry_kind'] as String?) ??
          EntryKind.blink;
      final audioSha = _validShaOrNull(payload['audio_blob_sha256'] as String?);
      final imageShas = _extractStringList(payload['image_blob_sha256s'])
          .where(isValidBlobSha256)
          .toList(growable: false);
      final sourceRefId =
          (payload['source_ref_id'] as String?) ?? parsed.sourceRefId;
      final captureOrigin =
          CaptureOrigin.tryParse(payload['capture_origin'] as String?) ??
          CaptureOrigin.tryParse(op.opOrigin) ??
          CaptureOrigin.appUi;
      final rev = (payload['revision'] as int?) ?? (op.baseRevision + 1);
      final createdAt =
          _parseUtcOrNull(payload['created_at'] as String?) ?? op.createdAtUtc;
      final updatedAt =
          _parseUtcOrNull(payload['updated_at'] as String?) ?? op.createdAtUtc;
      final deletedAt = _parseUtcOrNull(payload['deleted_at'] as String?);

      db.execute(
        'INSERT INTO raw_entries '
        '(id, entry_kind, body_md, audio_blob_sha256, image_blob_sha256s, '
        'source_ref_id, capture_origin, privacy_level, revision, hlc_ts, '
        'created_at, updated_at, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          op.entityId,
          kind.wireValue,
          bodyMd,
          audioSha,
          jsonEncode(imageShas),
          sourceRefId,
          captureOrigin.wireValue,
          effectivePrivacy.wireValue,
          rev,
          op.hlcTs,
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
          deletedAt?.toIso8601String(),
        ],
      );
      _writeEntryTipInTx(
        db,
        op.entityId,
        deviceId: op.deviceId,
        remoteRev: rev,
        localRev: rev,
        nowIso: updatedAt.toIso8601String(),
      );

      final inserted = RawEntry(
        id: op.entityId,
        entryKind: kind,
        bodyMd: bodyMd,
        audioBlobSha256: audioSha,
        imageBlobSha256s: imageShas,
        sourceRefId: sourceRefId,
        captureOrigin: captureOrigin,
        privacyLevel: effectivePrivacy,
        revision: rev,
        hlcTs: op.hlcTs,
        createdAtUtc: createdAt,
        updatedAtUtc: updatedAt,
        deletedAtUtc: deletedAt,
      );

      _syncEntryTasksFromRemoteInTx(
        db,
        entry: inserted,
        payloadTasks: payload['tasks'],
        parsedTasks: parsed.tasks,
        outTasksToIndex: tasksToIndex,
        outTaskIdsToRemove: docsToRemoveFromFts,
      );
      _replaceEntryBfmLinksInTx(
        db,
        entryId: inserted.id,
        links: parsed.links,
        privacyLevel: effectivePrivacy,
      );
      if (inserted.isDeleted) {
        docsToRemoveFromFts.add(inserted.id);
      } else {
        entriesToIndex.add(inserted);
      }
      return false;
    }

    // Case 2: Entry already exists locally.
    // Unidirectional `#private` latch: `private` ALWAYS wins (`INV-03`).
    final effectivePrivacy = (existing.isPrivate || remoteIsPrivate)
        ? PrivacyLevel.private
        : PrivacyLevel.normal;
    if (effectivePrivacy == PrivacyLevel.private && !existing.isPrivate) {
      final activeTasksToMove = db.select(
        "SELECT * FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL AND privacy_level != 'private'",
        <Object?>[existing.id],
      );
      db.execute(
        "UPDATE raw_tasks SET privacy_level = 'private' WHERE origin_entry_id = ?",
        <Object?>[existing.id],
      );
      for (final row in activeTasksToMove) {
        final task = rowToRawTask(row);
        tasksToIndex.add(
          RawTask(
            id: task.id,
            title: task.title,
            status: task.status,
            originEntryId: task.originEntryId,
            originAnnotationId: task.originAnnotationId,
            focusDate: task.focusDate,
            completedAtUtc: task.completedAtUtc,
            privacyLevel: PrivacyLevel.private,
            revision: task.revision,
            hlcTs: task.hlcTs,
            createdAtUtc: task.createdAtUtc,
            updatedAtUtc: task.updatedAtUtc,
            deletedAtUtc: task.deletedAtUtc,
          ),
        );
      }
      db.execute(
        "UPDATE sync_oplog SET privacy_level = 'private' "
        'WHERE entity_id = ? '
        "   OR (entity_type = 'raw_task' AND entity_id IN ("
        '        SELECT id FROM raw_tasks WHERE origin_entry_id = ?'
        '      ))',
        <Object?>[existing.id, existing.id],
      );
      db.execute(
        "UPDATE outbox_ops SET privacy_level = 'private' "
        'WHERE entity_id = ? '
        "   OR (entity_type = 'raw_task' AND entity_id IN ("
        '        SELECT id FROM raw_tasks WHERE origin_entry_id = ?'
        '      ))',
        <Object?>[existing.id, existing.id],
      );
    }

    final existingTip = _readEntryTipInTx(db, existing.id);

    // Subcase 2a: Incoming soft_delete tombstone.
    if (op.opType == 'soft_delete') {
      final concurrentLocalEdit =
          !existing.isDeleted &&
          (op.baseRevision < existing.revision ||
              existing.hlcTs.compareTo(op.hlcTs) > 0);
      if (concurrentLocalEdit) {
        // Delete tombstone vs concurrent edit -> edit wins (stays alive), still apply `#private` latch.
        final mergedHlc = _maxHlc(existing.hlcTs, op.hlcTs);
        final nextRev = existing.revision + 1;
        final nowIso = DateTime.now().toUtc().toIso8601String();
        db.execute(
          'UPDATE raw_entries SET privacy_level = ?, revision = ?, hlc_ts = ?, updated_at = ? '
          'WHERE id = ?',
          <Object?>[
            effectivePrivacy.wireValue,
            nextRev,
            mergedHlc,
            nowIso,
            existing.id,
          ],
        );
        if (existingTip != null && existingTip.localRev == existing.revision) {
          _writeEntryTipInTx(
            db,
            existing.id,
            deviceId: existingTip.deviceId,
            remoteRev: existingTip.remoteRev,
            localRev: nextRev,
            nowIso: nowIso,
          );
        }
        final kept = existing.copyWith(
          privacyLevel: effectivePrivacy,
          revision: nextRev,
          hlcTs: mergedHlc,
        );
        entriesToIndex.add(kept);
        return false;
      }

      final deletedAt =
          _parseUtcOrNull(payload['deleted_at'] as String?) ?? op.createdAtUtc;
      final deletedIso = deletedAt.toIso8601String();
      final mergedHlc = _maxHlc(existing.hlcTs, op.hlcTs);
      final nextRev = _maxInt(
        existing.revision + 1,
        (payload['revision'] as int?) ?? (existing.revision + 1),
      );
      db.execute(
        'UPDATE raw_entries SET deleted_at = ?, privacy_level = ?, revision = ?, '
        'hlc_ts = ?, updated_at = ? WHERE id = ?',
        <Object?>[
          deletedIso,
          effectivePrivacy.wireValue,
          nextRev,
          mergedHlc,
          deletedIso,
          existing.id,
        ],
      );
      _deleteSyncStateInTx(db, _entryTipKey(existing.id));
      for (final row in db.select(
        'SELECT id FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[existing.id],
      )) {
        docsToRemoveFromFts.add(row['id'] as String);
      }
      db.execute(
        'UPDATE raw_tasks SET deleted_at = ?, updated_at = ?, hlc_ts = ? '
        'WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[deletedIso, deletedIso, mergedHlc, existing.id],
      );
      docsToRemoveFromFts.add(existing.id);
      return false;
    }

    // Subcase 2b: Incoming create/update/restore while local row is soft-deleted -> resurrect!
    final incomingBody = remoteBodyMd ?? existing.bodyMd;
    final incomingParsed = remoteParsed ?? _bfm.parse(incomingBody);
    final incomingImages = _extractStringList(payload['image_blob_sha256s'])
        .where(isValidBlobSha256)
        .toList(growable: false);
    final mergedImages = _unionStrings(
      existing.imageBlobSha256s,
      incomingImages,
    );
    final incomingKind =
        EntryKind.tryParse(payload['entry_kind'] as String?) ??
        existing.entryKind;
    final incomingAudio =
        _validShaOrNull(payload['audio_blob_sha256'] as String?) ??
        existing.audioBlobSha256;
    final incomingSourceRef =
        (payload['source_ref_id'] as String?) ??
        incomingParsed.sourceRefId ??
        existing.sourceRefId;
    final remoteRev = (payload['revision'] as int?) ?? (op.baseRevision + 1);
    final updatedAt =
        _parseUtcOrNull(payload['updated_at'] as String?) ?? op.createdAtUtc;

    if (existing.isDeleted) {
      final mergedHlc = _maxHlc(existing.hlcTs, op.hlcTs);
      final nextRev = _maxInt(existing.revision, remoteRev) + 1;
      db.execute(
        'UPDATE raw_entries SET entry_kind = ?, body_md = ?, audio_blob_sha256 = ?, '
        'image_blob_sha256s = ?, source_ref_id = ?, privacy_level = ?, '
        'revision = ?, hlc_ts = ?, updated_at = ?, deleted_at = NULL '
        'WHERE id = ?',
        <Object?>[
          incomingKind.wireValue,
          incomingBody,
          incomingAudio,
          jsonEncode(mergedImages),
          incomingSourceRef,
          effectivePrivacy.wireValue,
          nextRev,
          mergedHlc,
          updatedAt.toIso8601String(),
          existing.id,
        ],
      );
      _writeEntryTipInTx(
        db,
        existing.id,
        deviceId: op.deviceId,
        remoteRev: remoteRev,
        localRev: nextRev,
        nowIso: updatedAt.toIso8601String(),
      );
      final resurrected = existing.copyWith(
        entryKind: incomingKind,
        bodyMd: incomingBody,
        audioBlobSha256: incomingAudio,
        imageBlobSha256s: mergedImages,
        sourceRefId: incomingSourceRef,
        privacyLevel: effectivePrivacy,
        revision: nextRev,
        hlcTs: mergedHlc,
        updatedAtUtc: updatedAt,
        clearDeletedAt: true,
      );
      _syncEntryTasksFromRemoteInTx(
        db,
        entry: resurrected,
        payloadTasks: payload['tasks'],
        parsedTasks: incomingParsed.tasks,
        outTasksToIndex: tasksToIndex,
        outTaskIdsToRemove: docsToRemoveFromFts,
      );
      _replaceEntryBfmLinksInTx(
        db,
        entryId: resurrected.id,
        links: incomingParsed.links,
        privacyLevel: effectivePrivacy,
      );
      entriesToIndex.add(resurrected);
      return false;
    }

    // Subcase 2c: Both active — check for linear continuation of winning remote branch
    // before flagging a concurrent divergent body edit (`INV-01`, `INV-05`).
    final isLinearContinuationOfWinningBranch =
        existingTip != null &&
        existingTip.localRev == existing.revision &&
        existingTip.deviceId == op.deviceId &&
        op.baseRevision >= existingTip.remoteRev;
    final isConcurrentBodyConflict =
        !isLinearContinuationOfWinningBranch &&
        op.baseRevision < existing.revision &&
        incomingBody != existing.bodyMd;

    if (!isConcurrentBodyConflict) {
      final mergedHlc = _maxHlc(existing.hlcTs, op.hlcTs);
      final nextRev = _maxInt(existing.revision + 1, remoteRev);
      final targetImages =
          (op.baseRevision >= existing.revision ||
                  isLinearContinuationOfWinningBranch) &&
              payload.containsKey('image_blob_sha256s')
          ? incomingImages
          : mergedImages;
      db.execute(
        'UPDATE raw_entries SET entry_kind = ?, body_md = ?, audio_blob_sha256 = ?, '
        'image_blob_sha256s = ?, source_ref_id = ?, privacy_level = ?, '
        'revision = ?, hlc_ts = ?, updated_at = ? WHERE id = ?',
        <Object?>[
          incomingKind.wireValue,
          incomingBody,
          incomingAudio,
          jsonEncode(targetImages),
          incomingSourceRef,
          effectivePrivacy.wireValue,
          nextRev,
          mergedHlc,
          updatedAt.toIso8601String(),
          existing.id,
        ],
      );
      _writeEntryTipInTx(
        db,
        existing.id,
        deviceId: op.deviceId,
        remoteRev: remoteRev,
        localRev: nextRev,
        nowIso: updatedAt.toIso8601String(),
      );
      if (isLinearContinuationOfWinningBranch) {
        db.execute(
          'UPDATE sync_conflicts SET remote_body_md = ?, remote_hlc_ts = ? '
          "WHERE entity_type = 'raw_entry' AND entity_id = ? "
          "  AND remote_device_id = ? AND status = 'open'",
          <Object?>[incomingBody, op.hlcTs, existing.id, op.deviceId],
        );
      }
      final updated = existing.copyWith(
        entryKind: incomingKind,
        bodyMd: incomingBody,
        audioBlobSha256: incomingAudio,
        imageBlobSha256s: targetImages,
        sourceRefId: incomingSourceRef,
        privacyLevel: effectivePrivacy,
        revision: nextRev,
        hlcTs: mergedHlc,
        updatedAtUtc: updatedAt,
      );
      _syncEntryTasksFromRemoteInTx(
        db,
        entry: updated,
        payloadTasks: payload['tasks'],
        parsedTasks: incomingParsed.tasks,
        outTasksToIndex: tasksToIndex,
        outTaskIdsToRemove: docsToRemoveFromFts,
      );
      _replaceEntryBfmLinksInTx(
        db,
        entryId: updated.id,
        links: incomingParsed.links,
        privacyLevel: effectivePrivacy,
      );
      entriesToIndex.add(updated);
      return false;
    }

    // Dual-copy conflict preservation (`INV-01`, `INV-05`, `data-and-sync.md` §5.2).
    final existingCausal = _lookupExistingCausalTripleInTx(
      db,
      entityType: 'raw_entry',
      entityId: existing.id,
      fallbackHlcTs: existing.hlcTs,
      excludeClientOpId: op.clientOpId,
    );
    final cmp = _compareCausalTriples(
      op.hlcTs,
      op.deviceId,
      op.clientOpId,
      existingCausal.hlcTs,
      existingCausal.deviceId,
      existingCausal.clientOpId,
    );
    final remoteWins = cmp > 0;

    final winningBody = remoteWins ? incomingBody : existing.bodyMd;
    final losingBody = remoteWins ? existing.bodyMd : incomingBody;
    final remoteDisplayName =
        (op.deviceName != null && op.deviceName!.trim().isNotEmpty)
        ? op.deviceName!.trim()
        : _lookupDeviceNameInTx(db, op.deviceId);
    final losingDeviceName = remoteWins
        ? _lookupDeviceNameInTx(db, existingCausal.deviceId)
        : remoteDisplayName;
    final losingTimeUtc = remoteWins ? existing.updatedAtUtc : updatedAt;

    final mergedHlc = _maxHlc(existing.hlcTs, op.hlcTs);
    final nextRev = _maxInt(existing.revision, remoteRev) + 1;
    final winningParsed = _bfm.parse(winningBody);
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();

    db.execute(
      'UPDATE raw_entries SET entry_kind = ?, body_md = ?, audio_blob_sha256 = ?, '
      'image_blob_sha256s = ?, source_ref_id = ?, privacy_level = ?, '
      'revision = ?, hlc_ts = ?, updated_at = ? WHERE id = ?',
      <Object?>[
        incomingKind.wireValue,
        winningBody,
        incomingAudio,
        jsonEncode(mergedImages),
        winningParsed.sourceRefId ?? incomingSourceRef,
        effectivePrivacy.wireValue,
        nextRev,
        mergedHlc,
        nowIso,
        existing.id,
      ],
    );

    final winningEntry = existing.copyWith(
      entryKind: incomingKind,
      bodyMd: winningBody,
      audioBlobSha256: incomingAudio,
      imageBlobSha256s: mergedImages,
      sourceRefId: winningParsed.sourceRefId ?? incomingSourceRef,
      privacyLevel: effectivePrivacy,
      revision: nextRev,
      hlcTs: mergedHlc,
      updatedAtUtc: nowUtc,
    );
    _syncEntryTasksFromRemoteInTx(
      db,
      entry: winningEntry,
      payloadTasks: remoteWins ? payload['tasks'] : null,
      parsedTasks: winningParsed.tasks,
      outTasksToIndex: tasksToIndex,
      outTaskIdsToRemove: docsToRemoveFromFts,
    );
    _replaceEntryBfmLinksInTx(
      db,
      entryId: winningEntry.id,
      links: winningParsed.links,
      privacyLevel: effectivePrivacy,
    );
    entriesToIndex.add(winningEntry);

    final copyHlc = _hlcClock.next(nowUtc: nowUtc);
    final copyHeader =
        '[离线冲突副本 · $losingDeviceName ${losingTimeUtc.toUtc().toIso8601String()}]';
    final copyBodyMd =
        '$copyHeader\n来源条目：[[entry:${existing.id}|原文条目]]\n\n$losingBody';
    final copyParsed = _bfm.parse(copyBodyMd);
    final copyImages = remoteWins ? existing.imageBlobSha256s : incomingImages;

    // If this op linearly extends an existing open conflict branch from the
    // same remote device, update that conflict & copy in-place instead of
    // spawning a second spurious conflict copy (`INV-05`).
    final losingTip = _readEntryLosingTipInTx(db, existing.id, op.deviceId);
    final canUpdateExistingOpenConflict =
        losingTip != null &&
        op.baseRevision >= losingTip.remoteRev &&
        db.select(
          "SELECT 1 FROM sync_conflicts WHERE id = ? AND status = 'open' LIMIT 1",
          <Object?>[losingTip.conflictId],
        ).isNotEmpty &&
        db.select(
          'SELECT 1 FROM raw_entries WHERE id = ? AND deleted_at IS NULL LIMIT 1',
          <Object?>[losingTip.copyId],
        ).isNotEmpty;

    if (canUpdateExistingOpenConflict) {
      db.execute(
        'UPDATE raw_entries SET body_md = ?, image_blob_sha256s = ?, '
        'privacy_level = ?, hlc_ts = ?, updated_at = ? WHERE id = ?',
        <Object?>[
          copyBodyMd,
          jsonEncode(copyImages),
          effectivePrivacy.wireValue,
          copyHlc,
          nowIso,
          losingTip.copyId,
        ],
      );
      final updatedCopyRow = db.select(
        'SELECT * FROM raw_entries WHERE id = ? LIMIT 1',
        <Object?>[losingTip.copyId],
      ).single;
      _replaceEntryBfmLinksInTx(
        db,
        entryId: losingTip.copyId,
        links: copyParsed.links,
        privacyLevel: effectivePrivacy,
      );
      entriesToIndex.add(rowToRawEntry(updatedCopyRow));

      if (remoteWins) {
        db.execute(
          'UPDATE sync_conflicts SET remote_hlc_ts = ?, local_body_md = ?, remote_body_md = ? '
          'WHERE id = ?',
          <Object?>[
            op.hlcTs,
            existing.bodyMd,
            incomingBody,
            losingTip.conflictId,
          ],
        );
        _deleteSyncStateInTx(db, _entryLosingTipKey(existing.id, op.deviceId));
        _writeEntryTipInTx(
          db,
          existing.id,
          deviceId: op.deviceId,
          remoteRev: remoteRev,
          localRev: nextRev,
          nowIso: nowIso,
        );
      } else {
        db.execute(
          'UPDATE sync_conflicts SET remote_hlc_ts = ?, remote_body_md = ? '
          'WHERE id = ?',
          <Object?>[op.hlcTs, incomingBody, losingTip.conflictId],
        );
        if (existingTip != null && existingTip.localRev == existing.revision) {
          _writeEntryTipInTx(
            db,
            existing.id,
            deviceId: existingTip.deviceId,
            remoteRev: existingTip.remoteRev,
            localRev: nextRev,
            nowIso: nowIso,
          );
        }
        _writeEntryLosingTipInTx(
          db,
          existing.id,
          op.deviceId,
          remoteRev: remoteRev,
          conflictId: losingTip.conflictId,
          copyId: losingTip.copyId,
          nowIso: nowIso,
        );
      }
      return false;
    }

    // Create preserved conflict copy entry (`[离线冲突副本 · <设备名> <UTC时间>]`).
    final copyId = generateUuidV7(timestamp: nowUtc);
    final conflictId = generateUuidV7(timestamp: nowUtc);

    db.execute(
      'INSERT INTO raw_entries '
      '(id, entry_kind, body_md, audio_blob_sha256, image_blob_sha256s, '
      'source_ref_id, capture_origin, privacy_level, revision, hlc_ts, '
      'created_at, updated_at, deleted_at) '
      'VALUES (?, ?, ?, NULL, ?, ?, ?, ?, 1, ?, ?, ?, NULL)',
      <Object?>[
        copyId,
        existing.entryKind.wireValue,
        copyBodyMd,
        jsonEncode(copyImages),
        existing.sourceRefId,
        CaptureOrigin.appUi.wireValue,
        effectivePrivacy.wireValue,
        copyHlc,
        nowIso,
        nowIso,
      ],
    );
    final copyEntry = RawEntry(
      id: copyId,
      entryKind: existing.entryKind,
      bodyMd: copyBodyMd,
      imageBlobSha256s: copyImages,
      sourceRefId: existing.sourceRefId,
      captureOrigin: CaptureOrigin.appUi,
      privacyLevel: effectivePrivacy,
      revision: 1,
      hlcTs: copyHlc,
      createdAtUtc: nowUtc,
      updatedAtUtc: nowUtc,
    );
    _replaceEntryBfmLinksInTx(
      db,
      entryId: copyId,
      links: copyParsed.links,
      privacyLevel: effectivePrivacy,
    );
    entriesToIndex.add(copyEntry);

    db.execute(
      'INSERT INTO sync_conflicts '
      '(id, entity_type, entity_id, local_copy_id, remote_device_id, remote_device_name, '
      'remote_hlc_ts, local_body_md, remote_body_md, status, resolution, created_at, resolved_at) '
      "VALUES (?, 'raw_entry', ?, ?, ?, ?, ?, ?, ?, 'open', NULL, ?, NULL)",
      <Object?>[
        conflictId,
        existing.id,
        copyId,
        op.deviceId,
        remoteDisplayName,
        op.hlcTs,
        existing.bodyMd,
        incomingBody,
        nowIso,
      ],
    );

    if (remoteWins) {
      _writeEntryTipInTx(
        db,
        existing.id,
        deviceId: op.deviceId,
        remoteRev: remoteRev,
        localRev: nextRev,
        nowIso: nowIso,
      );
    } else {
      if (existingTip != null && existingTip.localRev == existing.revision) {
        _writeEntryTipInTx(
          db,
          existing.id,
          deviceId: existingTip.deviceId,
          remoteRev: existingTip.remoteRev,
          localRev: nextRev,
          nowIso: nowIso,
        );
      }
      _writeEntryLosingTipInTx(
        db,
        existing.id,
        op.deviceId,
        remoteRev: remoteRev,
        conflictId: conflictId,
        copyId: copyId,
        nowIso: nowIso,
      );
    }
    return true;
  }

  void _applyRawTaskOpInTx(
    Database db,
    SyncOpEnvelope op, {
    required List<RawTask> tasksToIndex,
    required List<String> docsToRemoveFromFts,
  }) {
    final payload = op.payload;
    final rows = db.select(
      'SELECT * FROM raw_tasks WHERE id = ? LIMIT 1',
      <Object?>[op.entityId],
    );
    final payloadOriginEntryId = payload['origin_entry_id'] as String?;
    final existingOriginEntryId = rows.isEmpty
        ? null
        : rows.first['origin_entry_id'] as String?;
    final originEntryId = payloadOriginEntryId ?? existingOriginEntryId;
    final parentIsPrivate =
        originEntryId != null &&
        originEntryId.isNotEmpty &&
        (db.select(
              "SELECT 1 FROM raw_entries WHERE id = ? AND privacy_level = 'private' LIMIT 1",
              <Object?>[originEntryId],
            ).isNotEmpty ||
            db.select(
              "SELECT 1 FROM sync_oplog WHERE entity_type = 'raw_entry' AND entity_id = ? AND privacy_level = 'private' LIMIT 1",
              <Object?>[originEntryId],
            ).isNotEmpty);
    final remotePrivacy = parentIsPrivate
        ? PrivacyLevel.private
        : (PrivacyLevel.tryParse(payload['privacy_level'] as String?) ??
              op.privacyLevel);
    final status =
        TaskStatus.tryParse(payload['status'] as String?) ?? TaskStatus.open;
    final focusDate = payload['focus_date'] as String?;
    final completedAt = _parseUtcOrNull(payload['completed_at'] as String?);
    final deletedAt = _parseUtcOrNull(payload['deleted_at'] as String?);
    final updatedAt =
        _parseUtcOrNull(payload['updated_at'] as String?) ?? op.createdAtUtc;
    final createdAt =
        _parseUtcOrNull(payload['created_at'] as String?) ?? op.createdAtUtc;

    if (rows.isEmpty) {
      final title = payload['title'] as String?;
      if (title == null) {
        return;
      }
      final rev = (payload['revision'] as int?) ?? 1;
      db.execute(
        'INSERT INTO raw_tasks '
        '(id, title, status, origin_entry_id, origin_annotation_id, origin_line_index, '
        'focus_date, completed_at, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          op.entityId,
          title,
          status.wireValue,
          payload['origin_entry_id'] as String?,
          payload['origin_annotation_id'] as String?,
          payload['origin_line_index'] as int?,
          focusDate,
          completedAt?.toIso8601String(),
          remotePrivacy.wireValue,
          rev,
          op.hlcTs,
          createdAt.toIso8601String(),
          updatedAt.toIso8601String(),
          deletedAt?.toIso8601String(),
        ],
      );
      final inserted = RawTask(
        id: op.entityId,
        title: title,
        status: status,
        originEntryId: payload['origin_entry_id'] as String?,
        originAnnotationId: payload['origin_annotation_id'] as String?,
        focusDate: focusDate,
        completedAtUtc: completedAt,
        privacyLevel: remotePrivacy,
        revision: rev,
        hlcTs: op.hlcTs,
        createdAtUtc: createdAt,
        updatedAtUtc: updatedAt,
        deletedAtUtc: deletedAt,
      );
      if (inserted.isDeleted) {
        docsToRemoveFromFts.add(inserted.id);
      } else {
        tasksToIndex.add(inserted);
      }
      return;
    }

    final existing = rowToRawTask(rows.first);
    final effectivePrivacy =
        (existing.isPrivate || remotePrivacy == PrivacyLevel.private)
        ? PrivacyLevel.private
        : PrivacyLevel.normal;
    if (op.hlcTs.compareTo(existing.hlcTs) < 0) {
      // Older HLC loses on scalar fields, but still enforce `#private` latch if escalated.
      if (effectivePrivacy != existing.privacyLevel) {
        db.execute(
          'UPDATE raw_tasks SET privacy_level = ? WHERE id = ?',
          <Object?>[effectivePrivacy.wireValue, existing.id],
        );
        tasksToIndex.add(
          RawTask(
            id: existing.id,
            title: existing.title,
            status: existing.status,
            originEntryId: existing.originEntryId,
            originAnnotationId: existing.originAnnotationId,
            focusDate: existing.focusDate,
            completedAtUtc: existing.completedAtUtc,
            privacyLevel: effectivePrivacy,
            revision: existing.revision,
            hlcTs: existing.hlcTs,
            createdAtUtc: existing.createdAtUtc,
            updatedAtUtc: existing.updatedAtUtc,
            deletedAtUtc: existing.deletedAtUtc,
          ),
        );
      }
      return;
    }

    final nextTitle = (payload['title'] as String?) ?? existing.title;
    final nextFocus = payload.containsKey('focus_date')
        ? focusDate
        : existing.focusDate;
    final nextCompleted = status == TaskStatus.done
        ? (completedAt ?? existing.completedAtUtc ?? updatedAt)
        : null;
    final nextRev = _maxInt(
      existing.revision + 1,
      (payload['revision'] as int?) ?? (existing.revision + 1),
    );

    db.execute(
      'UPDATE raw_tasks SET title = ?, status = ?, focus_date = ?, completed_at = ?, '
      'privacy_level = ?, revision = ?, hlc_ts = ?, updated_at = ?, deleted_at = ? '
      'WHERE id = ?',
      <Object?>[
        nextTitle,
        status.wireValue,
        nextFocus,
        nextCompleted?.toIso8601String(),
        effectivePrivacy.wireValue,
        nextRev,
        op.hlcTs,
        updatedAt.toIso8601String(),
        deletedAt?.toIso8601String(),
        existing.id,
      ],
    );
    final updated = RawTask(
      id: existing.id,
      title: nextTitle,
      status: status,
      originEntryId: existing.originEntryId,
      originAnnotationId: existing.originAnnotationId,
      focusDate: nextFocus,
      completedAtUtc: nextCompleted,
      privacyLevel: effectivePrivacy,
      revision: nextRev,
      hlcTs: op.hlcTs,
      createdAtUtc: existing.createdAtUtc,
      updatedAtUtc: updatedAt,
      deletedAtUtc: deletedAt,
    );
    if (updated.isDeleted) {
      docsToRemoveFromFts.add(updated.id);
    } else {
      tasksToIndex.add(updated);
    }
  }

  bool _applyRawAnnotationOpInTx(Database db, SyncOpEnvelope op) {
    final payload = op.payload;
    final existingRows = db.select(
      'SELECT * FROM raw_annotations WHERE id = ? LIMIT 1',
      <Object?>[op.entityId],
    );
    final remoteNoteMd = payload['note_md'] as String?;
    final remotePrivacy =
        PrivacyLevel.tryParse(payload['privacy_level'] as String?) ??
        op.privacyLevel;
    final remoteIsPrivate =
        remotePrivacy == PrivacyLevel.private ||
        (remoteNoteMd != null && _bfm.parse(remoteNoteMd).hasPrivateToken);

    if (existingRows.isEmpty) {
      final sourceId = payload['source_id'] as String?;
      final anchorKind = payload['anchor_kind'] as String?;
      final anchorJson = payload['anchor_json'] is String
          ? payload['anchor_json'] as String
          : jsonEncode(payload['anchor_json'] ?? const <String, Object?>{});
      final quotedExcerpt = payload['quoted_excerpt'] as String?;
      if (sourceId == null || anchorKind == null || quotedExcerpt == null) {
        return false;
      }
      final sourceExists = db.select(
        'SELECT 1 FROM raw_sources WHERE id = ? LIMIT 1',
        <Object?>[sourceId],
      ).isNotEmpty;
      if (!sourceExists) {
        return false;
      }
      final nowIso = op.createdAtUtc.toIso8601String();
      db.execute(
        'INSERT INTO raw_annotations '
        '(id, source_id, anchor_kind, anchor_json, quoted_excerpt, note_md, style_token, '
        'anchor_status, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          op.entityId,
          sourceId,
          anchorKind,
          anchorJson,
          quotedExcerpt,
          remoteNoteMd ?? '',
          (payload['style_token'] as String?) ?? 'highlight_yellow',
          (payload['anchor_status'] as String?) ?? 'exact',
          remoteIsPrivate
              ? PrivacyLevel.private.wireValue
              : PrivacyLevel.normal.wireValue,
          (payload['revision'] as int?) ?? 1,
          op.hlcTs,
          (payload['created_at'] as String?) ?? nowIso,
          (payload['updated_at'] as String?) ?? nowIso,
          payload['deleted_at'] as String?,
        ],
      );
      return false;
    }

    final existing = existingRows.first;
    final existingPrivacy =
        PrivacyLevel.tryParse(existing['privacy_level'] as String?) ??
        PrivacyLevel.normal;
    final effectivePrivacy =
        (existingPrivacy == PrivacyLevel.private || remoteIsPrivate)
        ? PrivacyLevel.private
        : PrivacyLevel.normal;
    final existingNote = existing['note_md'] as String;
    final existingRev = existing['revision'] as int;
    final existingHlc = existing['hlc_ts'] as String;
    final existingDeleted = existing['deleted_at'] as String?;

    if (op.opType == 'soft_delete') {
      if (existingDeleted == null &&
          (op.baseRevision < existingRev ||
              existingHlc.compareTo(op.hlcTs) > 0)) {
        return false;
      }
      db.execute(
        'UPDATE raw_annotations SET deleted_at = ?, privacy_level = ?, '
        'revision = ?, hlc_ts = ?, updated_at = ? WHERE id = ?',
        <Object?>[
          (payload['deleted_at'] as String?) ??
              op.createdAtUtc.toIso8601String(),
          effectivePrivacy.wireValue,
          existingRev + 1,
          _maxHlc(existingHlc, op.hlcTs),
          op.createdAtUtc.toIso8601String(),
          op.entityId,
        ],
      );
      return false;
    }

    final nextNote = remoteNoteMd ?? existingNote;
    final isConflict =
        existingDeleted == null &&
        op.baseRevision < existingRev &&
        nextNote != existingNote;
    final mergedHlc = _maxHlc(existingHlc, op.hlcTs);
    final nextRev =
        _maxInt(existingRev, (payload['revision'] as int?) ?? existingRev) + 1;

    if (!isConflict) {
      db.execute(
        'UPDATE raw_annotations SET note_md = ?, privacy_level = ?, revision = ?, '
        'hlc_ts = ?, updated_at = ?, deleted_at = NULL WHERE id = ?',
        <Object?>[
          nextNote,
          effectivePrivacy.wireValue,
          nextRev,
          mergedHlc,
          (payload['updated_at'] as String?) ??
              op.createdAtUtc.toIso8601String(),
          op.entityId,
        ],
      );
      return false;
    }

    final remoteWins = op.hlcTs.compareTo(existingHlc) > 0;
    final winningNote = remoteWins ? nextNote : existingNote;
    db.execute(
      'UPDATE raw_annotations SET note_md = ?, privacy_level = ?, revision = ?, '
      'hlc_ts = ?, updated_at = ?, deleted_at = NULL WHERE id = ?',
      <Object?>[
        winningNote,
        effectivePrivacy.wireValue,
        nextRev,
        mergedHlc,
        DateTime.now().toUtc().toIso8601String(),
        op.entityId,
      ],
    );
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final remoteName = (op.deviceName != null && op.deviceName!.isNotEmpty)
        ? op.deviceName!
        : _lookupDeviceNameInTx(db, op.deviceId);
    db.execute(
      'INSERT INTO sync_conflicts '
      '(id, entity_type, entity_id, local_copy_id, remote_device_id, remote_device_name, '
      'remote_hlc_ts, local_body_md, remote_body_md, status, resolution, created_at, resolved_at) '
      "VALUES (?, 'raw_annotation', ?, ?, ?, ?, ?, ?, ?, 'open', NULL, ?, NULL)",
      <Object?>[
        generateUuidV7(),
        op.entityId,
        op.entityId,
        op.deviceId,
        remoteName,
        op.hlcTs,
        existingNote,
        nextNote,
        nowIso,
      ],
    );
    return true;
  }

  void _applyRawSourceOpInTx(Database db, SyncOpEnvelope op) {
    final payload = op.payload;
    final rows = db.select(
      'SELECT * FROM raw_sources WHERE id = ? LIMIT 1',
      <Object?>[op.entityId],
    );
    final remotePrivacy =
        PrivacyLevel.tryParse(payload['privacy_level'] as String?) ??
        op.privacyLevel;
    final progressRaw = payload['reading_progress_json'];
    final progressJson = progressRaw is String
        ? progressRaw
        : jsonEncode(progressRaw ?? const <String, Object?>{});
    final nowIso = op.createdAtUtc.toIso8601String();

    if (rows.isEmpty) {
      final sourceKind = payload['source_kind'] as String?;
      final title = payload['title'] as String?;
      if (sourceKind == null || title == null) {
        return;
      }
      final authorsRaw = payload['authors_json'];
      final authorsJson = authorsRaw is String
          ? authorsRaw
          : jsonEncode(authorsRaw ?? const <Object?>[]);
      db.execute(
        'INSERT INTO raw_sources '
        '(id, source_kind, title, authors_json, origin_url, file_blob_sha256, '
        'cover_blob_sha256, ast_version, ingest_state, ingest_error, text_layer, '
        'reading_progress_json, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          op.entityId,
          sourceKind,
          title,
          authorsJson,
          payload['origin_url'] as String?,
          _validShaOrNull(payload['file_blob_sha256'] as String?),
          _validShaOrNull(payload['cover_blob_sha256'] as String?),
          (payload['ast_version'] as int?) ?? 1,
          (payload['ingest_state'] as String?) ?? 'queued',
          payload['ingest_error'] as String?,
          (payload['text_layer'] as String?) ?? 'not_applicable',
          progressJson,
          remotePrivacy.wireValue,
          (payload['revision'] as int?) ?? 1,
          op.hlcTs,
          (payload['created_at'] as String?) ?? nowIso,
          (payload['updated_at'] as String?) ?? nowIso,
          payload['deleted_at'] as String?,
        ],
      );
      return;
    }

    final existing = rows.first;
    final existingHlc = existing['hlc_ts'] as String;
    final existingPrivacy =
        PrivacyLevel.tryParse(existing['privacy_level'] as String?) ??
        PrivacyLevel.normal;
    final effectivePrivacy =
        (existingPrivacy == PrivacyLevel.private ||
            remotePrivacy == PrivacyLevel.private)
        ? PrivacyLevel.private
        : PrivacyLevel.normal;

    if (op.hlcTs.compareTo(existingHlc) >= 0) {
      db.execute(
        'UPDATE raw_sources SET reading_progress_json = ?, privacy_level = ?, '
        'revision = revision + 1, hlc_ts = ?, updated_at = ?, deleted_at = ? WHERE id = ?',
        <Object?>[
          progressJson,
          effectivePrivacy.wireValue,
          op.hlcTs,
          (payload['updated_at'] as String?) ?? nowIso,
          payload['deleted_at'] as String?,
          op.entityId,
        ],
      );
    } else if (effectivePrivacy != existingPrivacy) {
      db.execute(
        'UPDATE raw_sources SET privacy_level = ? WHERE id = ?',
        <Object?>[effectivePrivacy.wireValue, op.entityId],
      );
    }
  }

  /// Applies derived `ai_*` projection ops by `(computed_at, hlc_ts)` LWW.
  /// Strictly NEVER modifies any `raw_*` table (`INV-01`).
  void _applyAiDerivedOpInTx(Database db, SyncOpEnvelope op) {
    final payload = op.payload;
    final computedAt =
        (payload['computed_at'] as String?) ??
        op.createdAtUtc.toIso8601String();

    switch (op.entityType) {
      case 'ai_entry_enrichment':
        final existing = db.select(
          'SELECT computed_at FROM ai_entry_enrichments WHERE entry_id = ? LIMIT 1',
          <Object?>[op.entityId],
        );
        if (existing.isNotEmpty &&
            computedAt.compareTo(existing.first['computed_at'] as String) < 0) {
          return;
        }
        db.execute(
          'INSERT INTO ai_entry_enrichments '
          '(entry_id, intent_tags_json, matched_source_ids_json, verbatim_transcript_text, '
          'clean_transcript_md, ocr_extracted_quote, model_id, source_agent, privacy_level, computed_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(entry_id) DO UPDATE SET '
          'intent_tags_json = excluded.intent_tags_json, '
          'matched_source_ids_json = excluded.matched_source_ids_json, '
          'verbatim_transcript_text = excluded.verbatim_transcript_text, '
          'clean_transcript_md = excluded.clean_transcript_md, '
          'ocr_extracted_quote = excluded.ocr_extracted_quote, '
          'model_id = excluded.model_id, '
          'source_agent = excluded.source_agent, '
          'privacy_level = excluded.privacy_level, '
          'computed_at = excluded.computed_at',
          <Object?>[
            op.entityId,
            _ensureJsonArrayString(payload['intent_tags_json']),
            _ensureJsonArrayString(payload['matched_source_ids_json']),
            payload['verbatim_transcript_text'] as String?,
            payload['clean_transcript_md'] as String?,
            payload['ocr_extracted_quote'] as String?,
            (payload['model_id'] as String?) ?? '',
            (payload['source_agent'] as String?) ?? '',
            op.privacyLevel.wireValue,
            computedAt,
          ],
        );
      case 'ai_synthesis':
        final existing = db.select(
          'SELECT computed_at FROM ai_syntheses WHERE id = ? LIMIT 1',
          <Object?>[op.entityId],
        );
        if (existing.isNotEmpty &&
            computedAt.compareTo(existing.first['computed_at'] as String) < 0) {
          return;
        }
        final synthKind = payload['synth_kind'] as String?;
        final periodKey = payload['period_key'] as String?;
        final title = payload['title'] as String?;
        final summaryMd = payload['summary_md'] as String?;
        final viewHtml = payload['view_html'] as String?;
        if (synthKind == null ||
            periodKey == null ||
            title == null ||
            summaryMd == null ||
            viewHtml == null) {
          return;
        }
        final privacyScope =
            (payload['privacy_scope'] as String?) ??
            (op.privacyLevel == PrivacyLevel.private
                ? 'local_with_private'
                : 'normal_only');
        db.execute(
          'INSERT INTO ai_syntheses '
          '(id, synth_kind, period_key, target_source_id, title, privacy_scope, '
          'render_surface, summary_md, view_html, artifact_html, citations_json, '
          'model_id, source_agent, computed_at) '
          'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET '
          'title = excluded.title, '
          'privacy_scope = excluded.privacy_scope, '
          'render_surface = excluded.render_surface, '
          'summary_md = excluded.summary_md, '
          'view_html = excluded.view_html, '
          'artifact_html = excluded.artifact_html, '
          'citations_json = excluded.citations_json, '
          'model_id = excluded.model_id, '
          'source_agent = excluded.source_agent, '
          'computed_at = excluded.computed_at',
          <Object?>[
            op.entityId,
            synthKind,
            periodKey,
            payload['target_source_id'] as String?,
            title,
            privacyScope,
            (payload['render_surface'] as String?) ?? 'surface1_native',
            summaryMd,
            viewHtml,
            payload['artifact_html'] as String?,
            _ensureJsonArrayString(payload['citations_json']),
            (payload['model_id'] as String?) ?? '',
            (payload['source_agent'] as String?) ?? '',
            computedAt,
          ],
        );
      default:
        break;
    }
  }

  void _syncEntryTasksFromRemoteInTx(
    Database db, {
    required RawEntry entry,
    required Object? payloadTasks,
    required List<BfmTaskItem> parsedTasks,
    required List<RawTask> outTasksToIndex,
    required List<String> outTaskIdsToRemove,
  }) {
    if (payloadTasks is List) {
      final seenIds = <String>{};
      for (final raw in payloadTasks) {
        if (raw is! Map) {
          continue;
        }
        final id = raw['id'] as String?;
        final title = raw['title'] as String?;
        if (id == null || title == null) {
          continue;
        }
        seenIds.add(id);
        final status =
            TaskStatus.tryParse(raw['status'] as String?) ?? TaskStatus.open;
        final originLine = raw['origin_line_index'] as int?;
        final focusDate = raw['focus_date'] as String?;
        final completedAt = _parseUtcOrNull(raw['completed_at'] as String?);
        final deletedAt = _parseUtcOrNull(raw['deleted_at'] as String?);
        final createdAt =
            _parseUtcOrNull(raw['created_at'] as String?) ?? entry.createdAtUtc;
        final updatedAt =
            _parseUtcOrNull(raw['updated_at'] as String?) ?? entry.updatedAtUtc;
        final rev = (raw['revision'] as int?) ?? 1;
        final hlc = (raw['hlc_ts'] as String?) ?? entry.hlcTs;
        final privacy = entry.isPrivate
            ? PrivacyLevel.private
            : (PrivacyLevel.tryParse(raw['privacy_level'] as String?) ??
                  entry.privacyLevel);

        final existingTaskRows = db.select(
          'SELECT * FROM raw_tasks WHERE id = ? LIMIT 1',
          <Object?>[id],
        );
        if (existingTaskRows.isNotEmpty) {
          final existingTask = rowToRawTask(existingTaskRows.first);
          if (hlc.compareTo(existingTask.hlcTs) < 0) {
            if (privacy == PrivacyLevel.private && !existingTask.isPrivate) {
              db.execute(
                "UPDATE raw_tasks SET privacy_level = 'private' WHERE id = ?",
                <Object?>[id],
              );
              outTasksToIndex.add(
                RawTask(
                  id: existingTask.id,
                  title: existingTask.title,
                  status: existingTask.status,
                  originEntryId: existingTask.originEntryId,
                  originAnnotationId: existingTask.originAnnotationId,
                  focusDate: existingTask.focusDate,
                  completedAtUtc: existingTask.completedAtUtc,
                  privacyLevel: PrivacyLevel.private,
                  revision: existingTask.revision,
                  hlcTs: existingTask.hlcTs,
                  createdAtUtc: existingTask.createdAtUtc,
                  updatedAtUtc: existingTask.updatedAtUtc,
                  deletedAtUtc: existingTask.deletedAtUtc,
                ),
              );
            }
            continue;
          }
        }

        db.execute(
          'INSERT INTO raw_tasks '
          '(id, title, status, origin_entry_id, origin_annotation_id, origin_line_index, '
          'focus_date, completed_at, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
          'VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET '
          'title = excluded.title, status = excluded.status, '
          'origin_line_index = excluded.origin_line_index, '
          'focus_date = excluded.focus_date, completed_at = excluded.completed_at, '
          'privacy_level = excluded.privacy_level, revision = excluded.revision, '
          'hlc_ts = excluded.hlc_ts, updated_at = excluded.updated_at, '
          'deleted_at = excluded.deleted_at',
          <Object?>[
            id,
            title,
            status.wireValue,
            entry.id,
            originLine,
            focusDate,
            completedAt?.toIso8601String(),
            privacy.wireValue,
            rev,
            hlc,
            createdAt.toIso8601String(),
            updatedAt.toIso8601String(),
            deletedAt?.toIso8601String(),
          ],
        );
        final task = RawTask(
          id: id,
          title: title,
          status: status,
          originEntryId: entry.id,
          focusDate: focusDate,
          completedAtUtc: completedAt,
          privacyLevel: privacy,
          revision: rev,
          hlcTs: hlc,
          createdAtUtc: createdAt,
          updatedAtUtc: updatedAt,
          deletedAtUtc: deletedAt,
        );
        if (task.isDeleted) {
          outTaskIdsToRemove.add(task.id);
        } else {
          outTasksToIndex.add(task);
        }
      }
      return;
    }

    // Fallback when remote payload omitted explicit task IDs: reconcile from BFM body.
    final nowIso = entry.updatedAtUtc.toUtc().toIso8601String();
    final existingRows = db.select(
      'SELECT * FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL '
      'ORDER BY origin_line_index ASC, created_at ASC',
      <Object?>[entry.id],
    ).toList();

    for (final item in parsedTasks) {
      var matchedIndex = existingRows.indexWhere(
        (r) => (r['origin_line_index'] as int?) == item.lineIndex,
      );
      if (matchedIndex < 0) {
        matchedIndex = existingRows.indexWhere(
          (r) => (r['title'] as String) == item.title,
        );
      }
      if (matchedIndex >= 0) {
        final row = existingRows.removeAt(matchedIndex);
        final prev = rowToRawTask(row);
        final completedAt = item.status == TaskStatus.done
            ? (prev.completedAtUtc ?? entry.updatedAtUtc)
            : null;
        db.execute(
          'UPDATE raw_tasks SET title = ?, status = ?, origin_line_index = ?, '
          'completed_at = ?, privacy_level = ?, revision = ?, hlc_ts = ?, updated_at = ? '
          'WHERE id = ?',
          <Object?>[
            item.title,
            item.status.wireValue,
            item.lineIndex,
            completedAt?.toIso8601String(),
            entry.privacyLevel.wireValue,
            prev.revision + 1,
            entry.hlcTs,
            nowIso,
            prev.id,
          ],
        );
        outTasksToIndex.add(
          RawTask(
            id: prev.id,
            title: item.title,
            status: item.status,
            originEntryId: entry.id,
            focusDate: prev.focusDate,
            completedAtUtc: completedAt,
            privacyLevel: entry.privacyLevel,
            revision: prev.revision + 1,
            hlcTs: entry.hlcTs,
            createdAtUtc: prev.createdAtUtc,
            updatedAtUtc: entry.updatedAtUtc,
          ),
        );
      } else {
        final taskId = generateUuidV7(timestamp: entry.updatedAtUtc);
        final completedAt = item.status == TaskStatus.done
            ? entry.updatedAtUtc
            : null;
        db.execute(
          'INSERT INTO raw_tasks '
          '(id, title, status, origin_entry_id, origin_annotation_id, origin_line_index, '
          'focus_date, completed_at, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
          'VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?, 1, ?, ?, ?, NULL)',
          <Object?>[
            taskId,
            item.title,
            item.status.wireValue,
            entry.id,
            item.lineIndex,
            completedAt?.toIso8601String(),
            entry.privacyLevel.wireValue,
            entry.hlcTs,
            nowIso,
            nowIso,
          ],
        );
        outTasksToIndex.add(
          RawTask(
            id: taskId,
            title: item.title,
            status: item.status,
            originEntryId: entry.id,
            completedAtUtc: completedAt,
            privacyLevel: entry.privacyLevel,
            revision: 1,
            hlcTs: entry.hlcTs,
            createdAtUtc: entry.updatedAtUtc,
            updatedAtUtc: entry.updatedAtUtc,
          ),
        );
      }
    }

    for (final orphan in existingRows) {
      final orphanId = orphan['id'] as String;
      outTaskIdsToRemove.add(orphanId);
      db.execute(
        'UPDATE raw_tasks SET deleted_at = ?, updated_at = ?, '
        "privacy_level = CASE WHEN ? = 'private' THEN 'private' ELSE privacy_level END "
        'WHERE id = ?',
        <Object?>[nowIso, nowIso, entry.privacyLevel.wireValue, orphanId],
      );
    }
  }

  static String _entryTipKey(String entityId) => 'entry_tip:$entityId';

  static String _entryLosingTipKey(String entityId, String deviceId) =>
      'entry_losing_tip:$entityId:$deviceId';

  static String? _readSyncStateInTx(Database db, String key) {
    final rows = db.select(
      'SELECT value FROM sync_state WHERE key = ? LIMIT 1',
      <Object?>[key],
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String;
  }

  static void _writeSyncStateInTx(
    Database db,
    String key,
    String value,
    String nowIso,
  ) {
    db.execute(
      'INSERT INTO sync_state (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at',
      <Object?>[key, value, nowIso],
    );
  }

  static void _deleteSyncStateInTx(Database db, String key) {
    db.execute('DELETE FROM sync_state WHERE key = ?', <Object?>[key]);
  }

  static ({String deviceId, int remoteRev, int localRev})? _readEntryTipInTx(
    Database db,
    String entityId,
  ) {
    final raw = _readSyncStateInTx(db, _entryTipKey(entityId));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final deviceId = decoded['device_id'];
        final remoteRev = decoded['remote_rev'];
        final localRev = decoded['local_rev'];
        if (deviceId is String && remoteRev is int && localRev is int) {
          return (deviceId: deviceId, remoteRev: remoteRev, localRev: localRev);
        }
      }
    } catch (_) {}
    return null;
  }

  static void _writeEntryTipInTx(
    Database db,
    String entityId, {
    required String deviceId,
    required int remoteRev,
    required int localRev,
    required String nowIso,
  }) {
    _writeSyncStateInTx(
      db,
      _entryTipKey(entityId),
      jsonEncode(<String, Object?>{
        'device_id': deviceId,
        'remote_rev': remoteRev,
        'local_rev': localRev,
      }),
      nowIso,
    );
  }

  static ({int remoteRev, String conflictId, String copyId})?
  _readEntryLosingTipInTx(Database db, String entityId, String deviceId) {
    final raw = _readSyncStateInTx(db, _entryLosingTipKey(entityId, deviceId));
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final remoteRev = decoded['remote_rev'];
        final conflictId = decoded['conflict_id'];
        final copyId = decoded['copy_id'];
        if (remoteRev is int && conflictId is String && copyId is String) {
          return (remoteRev: remoteRev, conflictId: conflictId, copyId: copyId);
        }
      }
    } catch (_) {}
    return null;
  }

  static void _writeEntryLosingTipInTx(
    Database db,
    String entityId,
    String deviceId, {
    required int remoteRev,
    required String conflictId,
    required String copyId,
    required String nowIso,
  }) {
    _writeSyncStateInTx(
      db,
      _entryLosingTipKey(entityId, deviceId),
      jsonEncode(<String, Object?>{
        'remote_rev': remoteRev,
        'conflict_id': conflictId,
        'copy_id': copyId,
      }),
      nowIso,
    );
  }

  void _replaceEntryBfmLinksInTx(
    Database db, {
    required String entryId,
    required List<BfmParsedLink> links,
    required PrivacyLevel privacyLevel,
  }) {
    db.execute(
      "DELETE FROM ai_bfm_links WHERE src_type = 'entry' AND src_id = ?",
      <Object?>[entryId],
    );
    for (final link in links) {
      db.execute(
        'INSERT INTO ai_bfm_links '
        '(id, src_type, src_id, target_kind, target_id, anchor, privacy_level) '
        "VALUES (?, 'entry', ?, ?, ?, ?, ?)",
        <Object?>[
          generateUuidV7(),
          entryId,
          link.targetKind.wireValue,
          link.targetId,
          link.anchor,
          privacyLevel.wireValue,
        ],
      );
    }
  }

  ({String hlcTs, String deviceId, String clientOpId})
  _lookupExistingCausalTripleInTx(
    Database db, {
    required String entityType,
    required String entityId,
    required String fallbackHlcTs,
    required String excludeClientOpId,
  }) {
    final rows = db.select(
      'SELECT hlc_ts, device_id, client_op_id FROM sync_oplog '
      'WHERE entity_type = ? AND entity_id = ? AND client_op_id != ? '
      'ORDER BY hlc_ts DESC, device_id DESC, client_op_id DESC LIMIT 1',
      <Object?>[entityType, entityId, excludeClientOpId],
    );
    if (rows.isNotEmpty) {
      final row = rows.first;
      return (
        hlcTs: row['hlc_ts'] as String,
        deviceId: row['device_id'] as String,
        clientOpId: row['client_op_id'] as String,
      );
    }
    return (
      hlcTs: fallbackHlcTs,
      deviceId: _deviceIdProvider(),
      clientOpId: '',
    );
  }

  String _lookupDeviceNameInTx(Database db, String deviceId) {
    if (deviceId == _deviceIdProvider()) {
      return _deviceNameProvider();
    }
    final rows = db.select(
      'SELECT device_name FROM sync_devices WHERE device_id = ? LIMIT 1',
      <Object?>[deviceId],
    );
    if (rows.isNotEmpty) {
      final name = (rows.first['device_name'] as String).trim();
      if (name.isNotEmpty) {
        return name;
      }
    }
    return _shortDeviceLabel(deviceId);
  }

  Stream<T> _watch<T>(Future<T> Function() loader) {
    late StreamController<T> controller;
    StreamSubscription<int>? sub;

    Future<void> emitLatest() async {
      if (controller.isClosed) {
        return;
      }
      try {
        final data = await loader();
        if (!controller.isClosed) {
          controller.add(data);
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller = StreamController<T>.broadcast(
      onListen: () {
        unawaited(emitLatest());
        sub = _mutationStream.listen((_) {
          unawaited(emitLatest());
        });
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  static SyncOpEnvelope _oplogRowToEnvelope(
    Row row, {
    required String localDeviceId,
    required String localDeviceName,
  }) {
    final deviceId = row['device_id'] as String;
    String? deviceName;
    if (deviceId == localDeviceId) {
      deviceName = localDeviceName;
    } else if (row.keys.contains('known_device_name')) {
      deviceName = row['known_device_name'] as String?;
    }
    final decoded = jsonDecode(row['payload_json'] as String);
    final payload = decoded is Map
        ? decoded.map((k, v) => MapEntry<String, Object?>(k.toString(), v))
        : const <String, Object?>{};
    return SyncOpEnvelope(
      seqId: row['seq_id'] as int,
      deviceId: deviceId,
      deviceName: deviceName,
      clientOpId: row['client_op_id'] as String,
      hlcTs: row['hlc_ts'] as String,
      baseRevision: row['base_revision'] as int,
      entityLayer:
          SyncEntityLayer.tryParse(row['entity_layer'] as String?) ??
          SyncEntityLayer.raw,
      entityType: row['entity_type'] as String,
      entityId: row['entity_id'] as String,
      opType: row['op_type'] as String,
      opOrigin: row['op_origin'] as String,
      privacyLevel:
          PrivacyLevel.tryParse(row['privacy_level'] as String?) ??
          PrivacyLevel.normal,
      payload: payload,
      createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
    );
  }

  static SyncConflict _rowToConflict(Row row) => SyncConflict(
    id: row['id'] as String,
    entityType: row['entity_type'] as String,
    entityId: row['entity_id'] as String,
    localCopyId: row['local_copy_id'] as String,
    remoteDeviceId: row['remote_device_id'] as String,
    remoteDeviceName: (row['remote_device_name'] as String?) ?? '',
    remoteHlcTs: row['remote_hlc_ts'] as String,
    localBodyMd: row['local_body_md'] as String,
    remoteBodyMd: row['remote_body_md'] as String,
    status:
        SyncConflictStatus.tryParse(row['status'] as String?) ??
        SyncConflictStatus.open,
    resolution: row['resolution'] as String?,
    createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
    resolvedAtUtc: row['resolved_at'] != null
        ? DateTime.parse(row['resolved_at'] as String).toUtc()
        : null,
  );

  static SyncDeviceRecord _rowToDevice(Row row) => SyncDeviceRecord(
    deviceId: row['device_id'] as String,
    deviceName: row['device_name'] as String,
    tokenSha256: row['token_sha256'] as String,
    revokedAtUtc: row['revoked_at'] != null
        ? DateTime.parse(row['revoked_at'] as String).toUtc()
        : null,
    lastSeenAtUtc: row['last_seen_at'] != null
        ? DateTime.parse(row['last_seen_at'] as String).toUtc()
        : null,
    createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
  );

  static void _collectPayloadBlobShas(
    Map<String, Object?> payload,
    Set<String> out,
  ) {
    for (final key in const <String>[
      'audio_blob_sha256',
      'file_blob_sha256',
      'cover_blob_sha256',
    ]) {
      final value = payload[key];
      if (value is String && isValidBlobSha256(value)) {
        out.add(value);
      }
    }
    final images = payload['image_blob_sha256s'];
    for (final sha in _extractStringList(images)) {
      if (isValidBlobSha256(sha)) {
        out.add(sha);
      }
    }
  }

  static List<String> _extractStringList(Object? raw) {
    if (raw is List) {
      return raw.whereType<String>().toList(growable: false);
    }
    if (raw is String) {
      return decodeStringListJson(raw);
    }
    return const <String>[];
  }

  static List<String> _unionStrings(List<String> first, List<String> second) {
    final result = <String>[];
    final seen = <String>{};
    for (final s in first) {
      if (seen.add(s)) {
        result.add(s);
      }
    }
    for (final s in second) {
      if (seen.add(s)) {
        result.add(s);
      }
    }
    return result;
  }

  static String? _validShaOrNull(String? raw) =>
      raw != null && isValidBlobSha256(raw) ? raw : null;

  static DateTime? _parseUtcOrNull(String? raw) =>
      raw == null ? null : DateTime.tryParse(raw)?.toUtc();

  static String _maxHlc(String a, String b) => a.compareTo(b) >= 0 ? a : b;

  static int _maxInt(int a, int b) => a >= b ? a : b;

  static int _compareCausalTriples(
    String hlcA,
    String devA,
    String opA,
    String hlcB,
    String devB,
    String opB,
  ) {
    final hlcCmp = hlcA.compareTo(hlcB);
    if (hlcCmp != 0) {
      return hlcCmp;
    }
    final devCmp = devA.compareTo(devB);
    if (devCmp != 0) {
      return devCmp;
    }
    return opA.compareTo(opB);
  }

  static String _shortDeviceLabel(String deviceId) =>
      deviceId.length <= 8 ? deviceId : deviceId.substring(0, 8);

  static String _ensureJsonArrayString(Object? raw) {
    if (raw is String) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is List) {
          return raw;
        }
      } catch (_) {}
    } else if (raw is List) {
      return jsonEncode(raw);
    }
    return '[]';
  }

  static bool _constantTimeEqualsAscii(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
