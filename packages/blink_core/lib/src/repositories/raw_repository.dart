import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../search/fts_search_service.dart';
import '../storage/blob_store.dart';
import '../utils/hlc.dart';
import '../utils/uuid_v7.dart';

/// Filter criteria for [RawRepository.listEntries] and [RawRepository.watchEntries].
@immutable
final class EntryQuery {
  const EntryQuery({
    this.kinds,
    this.tag,
    this.privacyFilter,
    this.dateFromUtc,
    this.dateToUtc,
    this.includeDeleted = false,
    this.onlyDeleted = false,
    this.limit = 100,
    this.offset = 0,
  });

  final List<EntryKind>? kinds;
  final String? tag;
  final PrivacyLevel? privacyFilter;
  final DateTime? dateFromUtc;
  final DateTime? dateToUtc;
  final bool includeDeleted;
  final bool onlyDeleted;
  final int limit;
  final int offset;
}

/// Filter criteria for [RawRepository.listTasks] and [RawRepository.watchTasks].
@immutable
final class TaskQuery {
  const TaskQuery({
    this.statuses,
    this.focusDate,
    this.privacyFilter,
    this.includeDeleted = false,
  });

  final List<TaskStatus>? statuses;
  final String? focusDate;
  final PrivacyLevel? privacyFilter;
  final bool includeDeleted;
}

/// User & UI write path for the immutable Raw Layer (`INV-01`, `INV-04`, `INV-05`).
abstract interface class RawRepository {
  /// Single `BEGIN IMMEDIATE` transaction (`< 16ms`, `INV-04`):
  /// parses BFM v1, enforces `#private` unidirectional latch, inserts `raw_entries`,
  /// syncs endogenous `raw_tasks`, populates `ai_bfm_links`, appends `sync_oplog` + `outbox_ops`,
  /// updates `index/fts.db`, and schedules debounced mirror export.
  Future<RawEntry> createEntry({
    required String bodyMd,
    EntryKind entryKind = EntryKind.blink,
    bool privacyLocked = false,
    String? audioBlobSha256,
    List<String> imageBlobSha256s = const <String>[],
    String? sourceRefId,
    CaptureOrigin captureOrigin = CaptureOrigin.appUi,
  });

  /// Updates an existing raw entry, incrementing `revision`, enforcing unidirectional
  /// `#private` latch unless [allowPrivacyDowngrade] is explicitly `true`, reconciling
  /// `raw_tasks` & `ai_bfm_links`, updating `fts_normal`/`fts_private`, and recording OpLog/Outbox.
  Future<RawEntry> updateEntry({
    required String id,
    required String bodyMd,
    EntryKind? entryKind,
    bool? privacyLocked,
    List<String>? imageBlobSha256s,
    bool allowPrivacyDowngrade = false,
  });

  /// Soft-deletes into 30-day trash (`deleted_at = nowUtc`), removes from FTS,
  /// and schedules mirror archival.
  Future<void> softDeleteEntry(String id);

  /// Restores a soft-deleted entry from 30-day trash.
  Future<RawEntry> restoreEntry(String id);

  /// Lists soft-deleted entries currently in 30-day trash.
  Future<List<RawEntry>> listTrash({int limit = 100, int offset = 0});

  /// Permanently purges a single entry and runs `BlobStore.gcUnreferencedBlobs()` (`INV-12`).
  Future<int> purgeEntryPermanently(String id);

  /// Convenience alias for [purgeEntryPermanently].
  Future<int> permanentlyDeleteEntry(String id);

  /// Permanently purges all trashed entries older than [retention] and collects orphan blobs.
  Future<int> purgeExpiredTrash({
    Duration retention = const Duration(days: 30),
  });

  Future<RawEntry?> getEntryById(String id, {bool includeDeleted = false});

  Future<List<RawEntry>> listEntries([EntryQuery query = const EntryQuery()]);

  Stream<List<RawEntry>> watchEntries([EntryQuery query = const EntryQuery()]);

  Future<Map<String, int>> listTagCounts({PrivacyLevel? privacyFilter});

  Future<List<BfmLinkRecord>> getBacklinks(String targetId);

  /// Updates both `raw_tasks.status` AND the source `- [ ]`/`- [x]`/`- [>]`/`- [-]` line
  /// in `raw_entries.body_md` atomically (`FR-TASK-001`).
  Future<RawTask> updateTaskStatus({
    required String taskId,
    required TaskStatus status,
    String? focusDate,
  });

  /// Toggles a task between [TaskStatus.open] and [TaskStatus.done] atomically.
  Future<RawTask> toggleTaskStatus(String taskId);

  Future<List<RawTask>> listTasks([TaskQuery query = const TaskQuery()]);

  Stream<List<RawTask>> watchTasks([TaskQuery query = const TaskQuery()]);

  /// Crash-recovery draft slot (`FR-CAP-001`, `AC-02`; WAL-persisted, never enters `sync_oplog`/`mirror`).
  Future<void> saveDraft(EditorDraft draft);

  Future<EditorDraft?> loadDraft(String draftKey);

  Future<void> clearDraft(String draftKey);
}

/// SQLite WAL implementation of [RawRepository].
final class SqliteRawRepository implements RawRepository {
  SqliteRawRepository({
    required this._dbProvider,
    required this._runWriteTx,
    required this._deviceIdProvider,
    required this._hlcClock,
    required this._bfm,
    required this._fts,
    required this._blobs,
    required this._onMutated,
    required this._mutationStream,
  });

  final Database Function() _dbProvider;
  final T Function<T>(T Function(Database db) action) _runWriteTx;
  final String Function() _deviceIdProvider;
  final HlcClock _hlcClock;
  final BfmEngine _bfm;
  final SqliteFtsSearchService _fts;
  final BlobStore _blobs;
  final void Function({required bool triggerMirror}) _onMutated;
  final Stream<int> _mutationStream;

  @override
  Future<RawEntry> createEntry({
    required String bodyMd,
    EntryKind entryKind = EntryKind.blink,
    bool privacyLocked = false,
    String? audioBlobSha256,
    List<String> imageBlobSha256s = const <String>[],
    String? sourceRefId,
    CaptureOrigin captureOrigin = CaptureOrigin.appUi,
  }) async {
    _validateOptionalBlobSha(audioBlobSha256, field: 'audioBlobSha256');
    for (final sha in imageBlobSha256s) {
      _validateOptionalBlobSha(sha, field: 'imageBlobSha256s');
    }

    final parsed = _bfm.parse(bodyMd);
    final effectivePrivacy = (privacyLocked || parsed.hasPrivateToken)
        ? PrivacyLevel.private
        : PrivacyLevel.normal;
    final effectiveSourceRefId = sourceRefId ?? parsed.sourceRefId;
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final entryId = generateUuidV7(timestamp: nowUtc);
    final hlcTs = _hlcClock.next(nowUtc: nowUtc);
    final deviceId = _deviceIdProvider();

    late RawEntry created;
    final createdTasks = <RawTask>[];

    _runWriteTx<void>((db) {
      db.execute(
        'INSERT INTO raw_entries '
        '(id, entry_kind, body_md, audio_blob_sha256, image_blob_sha256s, '
        'source_ref_id, capture_origin, privacy_level, revision, hlc_ts, '
        'created_at, updated_at, deleted_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)',
        <Object?>[
          entryId,
          entryKind.wireValue,
          bodyMd,
          audioBlobSha256,
          jsonEncode(imageBlobSha256s),
          effectiveSourceRefId,
          captureOrigin.wireValue,
          effectivePrivacy.wireValue,
          1,
          hlcTs,
          nowIso,
          nowIso,
        ],
      );

      created = RawEntry(
        id: entryId,
        entryKind: entryKind,
        bodyMd: bodyMd,
        audioBlobSha256: audioBlobSha256,
        imageBlobSha256s: imageBlobSha256s,
        sourceRefId: effectiveSourceRefId,
        captureOrigin: captureOrigin,
        privacyLevel: effectivePrivacy,
        revision: 1,
        hlcTs: hlcTs,
        createdAtUtc: nowUtc,
        updatedAtUtc: nowUtc,
      );

      for (final taskItem in parsed.tasks) {
        final taskId = generateUuidV7(timestamp: nowUtc);
        final taskHlc = _hlcClock.next(nowUtc: nowUtc);
        final completedAtIso = taskItem.status == TaskStatus.done
            ? nowIso
            : null;
        db.execute(
          'INSERT INTO raw_tasks '
          '(id, title, status, origin_entry_id, origin_annotation_id, origin_line_index, '
          'focus_date, completed_at, privacy_level, revision, hlc_ts, created_at, updated_at, deleted_at) '
          'VALUES (?, ?, ?, ?, NULL, ?, NULL, ?, ?, 1, ?, ?, ?, NULL)',
          <Object?>[
            taskId,
            taskItem.title,
            taskItem.status.wireValue,
            entryId,
            taskItem.lineIndex,
            completedAtIso,
            effectivePrivacy.wireValue,
            taskHlc,
            nowIso,
            nowIso,
          ],
        );
        createdTasks.add(
          RawTask(
            id: taskId,
            title: taskItem.title,
            status: taskItem.status,
            originEntryId: entryId,
            completedAtUtc: completedAtIso != null ? nowUtc : null,
            privacyLevel: effectivePrivacy,
            revision: 1,
            hlcTs: taskHlc,
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
      }

      _replaceEntryBfmLinksInTx(
        db,
        entryId: entryId,
        links: parsed.links,
        privacyLevel: effectivePrivacy,
      );

      _appendOplogAndOutboxInTx(
        db,
        deviceId: deviceId,
        hlcTs: hlcTs,
        baseRevision: 0,
        entityLayer: 'raw',
        entityType: 'raw_entry',
        entityId: entryId,
        opType: 'create',
        opOrigin: captureOrigin.wireValue,
        privacyLevel: effectivePrivacy,
        payload: _entryOpPayload(created),
        createdAtIso: nowIso,
      );
    });

    _fts.indexEntrySync(created);
    for (final task in createdTasks) {
      _fts.indexTaskSync(task);
    }
    _onMutated(triggerMirror: true);
    return created;
  }

  @override
  Future<RawEntry> updateEntry({
    required String id,
    required String bodyMd,
    EntryKind? entryKind,
    bool? privacyLocked,
    List<String>? imageBlobSha256s,
    bool allowPrivacyDowngrade = false,
  }) async {
    if (imageBlobSha256s != null) {
      for (final sha in imageBlobSha256s) {
        _validateOptionalBlobSha(sha, field: 'imageBlobSha256s');
      }
    }

    final parsed = _bfm.parse(bodyMd);
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final hlcTs = _hlcClock.next(nowUtc: nowUtc);
    final deviceId = _deviceIdProvider();

    late RawEntry updated;
    final reconciledTasks = <RawTask>[];
    final removedTaskIds = <String>[];

    _runWriteTx<void>((db) {
      final existing = _fetchEntryByIdInTx(db, id, includeDeleted: true);
      if (existing == null) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Entry $id not found',
        );
      }

      final PrivacyLevel nextPrivacy;
      if (parsed.hasPrivateToken || privacyLocked == true) {
        nextPrivacy = PrivacyLevel.private;
      } else if (existing.isPrivate) {
        if (allowPrivacyDowngrade && privacyLocked == false) {
          nextPrivacy = PrivacyLevel.normal;
        } else {
          // Unidirectional latch: once private, stays private unless explicit user downgrade.
          nextPrivacy = PrivacyLevel.private;
        }
      } else {
        nextPrivacy = PrivacyLevel.normal;
      }

      final nextKind = entryKind ?? existing.entryKind;
      final nextImages = imageBlobSha256s ?? existing.imageBlobSha256s;
      final nextSourceRef = parsed.sourceRefId ?? existing.sourceRefId;
      final nextRevision = existing.revision + 1;

      db.execute(
        'UPDATE raw_entries SET entry_kind = ?, body_md = ?, image_blob_sha256s = ?, '
        'source_ref_id = ?, privacy_level = ?, revision = ?, hlc_ts = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[
          nextKind.wireValue,
          bodyMd,
          jsonEncode(nextImages),
          nextSourceRef,
          nextPrivacy.wireValue,
          nextRevision,
          hlcTs,
          nowIso,
          id,
        ],
      );

      updated = RawEntry(
        id: id,
        entryKind: nextKind,
        bodyMd: bodyMd,
        audioBlobSha256: existing.audioBlobSha256,
        imageBlobSha256s: nextImages,
        sourceRefId: nextSourceRef,
        captureOrigin: existing.captureOrigin,
        privacyLevel: nextPrivacy,
        revision: nextRevision,
        hlcTs: hlcTs,
        createdAtUtc: existing.createdAtUtc,
        updatedAtUtc: nowUtc,
        deletedAtUtc: existing.deletedAtUtc,
      );

      _reconcileEntryTasksInTx(
        db,
        entry: updated,
        parsedTasks: parsed.tasks,
        nowUtc: nowUtc,
        outActiveTasks: reconciledTasks,
        outRemovedTaskIds: removedTaskIds,
      );

      _replaceEntryBfmLinksInTx(
        db,
        entryId: id,
        links: parsed.links,
        privacyLevel: nextPrivacy,
      );

      _appendOplogAndOutboxInTx(
        db,
        deviceId: deviceId,
        hlcTs: hlcTs,
        baseRevision: existing.revision,
        entityLayer: 'raw',
        entityType: 'raw_entry',
        entityId: id,
        opType: 'update',
        opOrigin: 'app_ui',
        privacyLevel: nextPrivacy,
        payload: _entryOpPayload(updated),
        createdAtIso: nowIso,
      );
    });

    // Immediately removes from `fts_normal` when promoted to `private`.
    _fts.indexEntrySync(updated);
    for (final removedId in removedTaskIds) {
      _fts.removeDocumentSync(removedId);
    }
    for (final task in reconciledTasks) {
      _fts.indexTaskSync(task);
    }
    _onMutated(triggerMirror: true);
    return updated;
  }

  @override
  Future<void> softDeleteEntry(String id) async {
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final hlcTs = _hlcClock.next(nowUtc: nowUtc);
    final deviceId = _deviceIdProvider();
    final taskIdsToRemove = <String>[];

    _runWriteTx<void>((db) {
      final existing = _fetchEntryByIdInTx(db, id, includeDeleted: true);
      if (existing == null) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Entry $id not found',
        );
      }
      if (existing.isDeleted) {
        return;
      }

      db.execute(
        'UPDATE raw_entries SET deleted_at = ?, revision = ?, hlc_ts = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[nowIso, existing.revision + 1, hlcTs, nowIso, id],
      );

      final linkedTasks = db.select(
        'SELECT id FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[id],
      );
      for (final row in linkedTasks) {
        taskIdsToRemove.add(row['id'] as String);
      }
      db.execute(
        'UPDATE raw_tasks SET deleted_at = ?, updated_at = ?, hlc_ts = ? '
        'WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[nowIso, nowIso, hlcTs, id],
      );

      _appendOplogAndOutboxInTx(
        db,
        deviceId: deviceId,
        hlcTs: hlcTs,
        baseRevision: existing.revision,
        entityLayer: 'raw',
        entityType: 'raw_entry',
        entityId: id,
        opType: 'soft_delete',
        opOrigin: 'app_ui',
        privacyLevel: existing.privacyLevel,
        payload: <String, Object?>{'id': id, 'deleted_at': nowIso},
        createdAtIso: nowIso,
      );
    });

    _fts.removeDocumentSync(id);
    for (final taskId in taskIdsToRemove) {
      _fts.removeDocumentSync(taskId);
    }
    _onMutated(triggerMirror: true);
  }

  @override
  Future<RawEntry> restoreEntry(String id) async {
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final hlcTs = _hlcClock.next(nowUtc: nowUtc);
    final deviceId = _deviceIdProvider();
    late RawEntry restored;
    final restoredTasks = <RawTask>[];

    _runWriteTx<void>((db) {
      final existing = _fetchEntryByIdInTx(db, id, includeDeleted: true);
      if (existing == null) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Entry $id not found',
        );
      }

      final nextRev = existing.revision + 1;
      db.execute(
        'UPDATE raw_entries SET deleted_at = NULL, revision = ?, hlc_ts = ?, updated_at = ? '
        'WHERE id = ?',
        <Object?>[nextRev, hlcTs, nowIso, id],
      );
      db.execute(
        'UPDATE raw_tasks SET deleted_at = NULL, updated_at = ?, hlc_ts = ? '
        'WHERE origin_entry_id = ?',
        <Object?>[nowIso, hlcTs, id],
      );

      restored = existing.copyWith(
        revision: nextRev,
        hlcTs: hlcTs,
        updatedAtUtc: nowUtc,
        clearDeletedAt: true,
      );

      final taskRows = db.select(
        'SELECT * FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL',
        <Object?>[id],
      );
      for (final row in taskRows) {
        restoredTasks.add(rowToRawTask(row));
      }

      _appendOplogAndOutboxInTx(
        db,
        deviceId: deviceId,
        hlcTs: hlcTs,
        baseRevision: existing.revision,
        entityLayer: 'raw',
        entityType: 'raw_entry',
        entityId: id,
        opType: 'restore',
        opOrigin: 'app_ui',
        privacyLevel: restored.privacyLevel,
        payload: _entryOpPayload(restored),
        createdAtIso: nowIso,
      );
    });

    _fts.indexEntrySync(restored);
    for (final task in restoredTasks) {
      _fts.indexTaskSync(task);
    }
    _onMutated(triggerMirror: true);
    return restored;
  }

  @override
  Future<List<RawEntry>> listTrash({int limit = 100, int offset = 0}) =>
      listEntries(EntryQuery(onlyDeleted: true, limit: limit, offset: offset));

  @override
  Future<int> purgeEntryPermanently(String id) async {
    final removedTaskIds = <String>[];
    final purged = _runWriteTx<int>((db) {
      final existing = _fetchEntryByIdInTx(db, id, includeDeleted: true);
      if (existing == null) {
        return 0;
      }
      for (final row in db.select(
        'SELECT id FROM raw_tasks WHERE origin_entry_id = ?',
        <Object?>[id],
      )) {
        removedTaskIds.add(row['id'] as String);
      }
      db.execute('DELETE FROM raw_tasks WHERE origin_entry_id = ?', <Object?>[
        id,
      ]);
      db.execute(
        "DELETE FROM ai_bfm_links WHERE src_type = 'entry' AND src_id = ?",
        <Object?>[id],
      );
      db.execute(
        'DELETE FROM ai_entry_enrichments WHERE entry_id = ?',
        <Object?>[id],
      );
      db.execute('DELETE FROM raw_entries WHERE id = ?', <Object?>[id]);
      return 1;
    });

    if (purged > 0) {
      _fts.removeDocumentSync(id);
      for (final taskId in removedTaskIds) {
        _fts.removeDocumentSync(taskId);
      }
      await _blobs.gcUnreferencedBlobs();
      _onMutated(triggerMirror: true);
    }
    return purged;
  }

  @override
  Future<int> permanentlyDeleteEntry(String id) => purgeEntryPermanently(id);

  @override
  Future<int> purgeExpiredTrash({
    Duration retention = const Duration(days: 30),
  }) async {
    final cutoffIso = DateTime.now()
        .toUtc()
        .subtract(retention)
        .toIso8601String();
    final expiredIds = <String>[];
    final removedTaskIds = <String>[];

    _runWriteTx<void>((db) {
      final rows = db.select(
        'SELECT id FROM raw_entries WHERE deleted_at IS NOT NULL AND deleted_at <= ?',
        <Object?>[cutoffIso],
      );
      for (final row in rows) {
        expiredIds.add(row['id'] as String);
      }
      for (final entryId in expiredIds) {
        for (final tRow in db.select(
          'SELECT id FROM raw_tasks WHERE origin_entry_id = ?',
          <Object?>[entryId],
        )) {
          removedTaskIds.add(tRow['id'] as String);
        }
        db.execute('DELETE FROM raw_tasks WHERE origin_entry_id = ?', <Object?>[
          entryId,
        ]);
        db.execute(
          "DELETE FROM ai_bfm_links WHERE src_type = 'entry' AND src_id = ?",
          <Object?>[entryId],
        );
        db.execute(
          'DELETE FROM ai_entry_enrichments WHERE entry_id = ?',
          <Object?>[entryId],
        );
        db.execute('DELETE FROM raw_entries WHERE id = ?', <Object?>[entryId]);
      }
    });

    if (expiredIds.isNotEmpty) {
      for (final id in expiredIds) {
        _fts.removeDocumentSync(id);
      }
      for (final taskId in removedTaskIds) {
        _fts.removeDocumentSync(taskId);
      }
      await _blobs.gcUnreferencedBlobs();
      _onMutated(triggerMirror: true);
    }
    return expiredIds.length;
  }

  @override
  Future<RawEntry?> getEntryById(
    String id, {
    bool includeDeleted = false,
  }) async {
    return _fetchEntryByIdInTx(
      _dbProvider(),
      id,
      includeDeleted: includeDeleted,
    );
  }

  @override
  Future<List<RawEntry>> listEntries([
    EntryQuery query = const EntryQuery(),
  ]) async {
    if (query.limit < 0 || query.offset < 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'limit and offset must be non-negative',
      );
    }
    final db = _dbProvider();
    final where = <String>[];
    final params = <Object?>[];

    if (query.onlyDeleted) {
      where.add('deleted_at IS NOT NULL');
    } else if (!query.includeDeleted) {
      where.add('deleted_at IS NULL');
    }

    if (query.kinds != null && query.kinds!.isNotEmpty) {
      final placeholders = List<String>.filled(
        query.kinds!.length,
        '?',
      ).join(', ');
      where.add('entry_kind IN ($placeholders)');
      params.addAll(query.kinds!.map((k) => k.wireValue));
    }

    if (query.privacyFilter != null) {
      where.add('privacy_level = ?');
      params.add(query.privacyFilter!.wireValue);
    }

    if (query.dateFromUtc != null) {
      where.add('created_at >= ?');
      params.add(query.dateFromUtc!.toUtc().toIso8601String());
    }
    if (query.dateToUtc != null) {
      where.add('created_at <= ?');
      params.add(query.dateToUtc!.toUtc().toIso8601String());
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final orderSql = query.onlyDeleted
        ? 'ORDER BY deleted_at DESC, id DESC'
        : 'ORDER BY created_at DESC, id DESC';

    // When filtering by hierarchical tag, apply tag matching before limit/offset.
    if (query.tag != null && query.tag!.trim().isNotEmpty) {
      final normalizedQueryTag = query.tag!
          .trim()
          .replaceFirst(RegExp(r'^#+'), '')
          .toLowerCase();
      final rows = db.select(
        'SELECT * FROM raw_entries $whereSql $orderSql',
        params,
      );
      final matched = <RawEntry>[];
      for (final row in rows) {
        final entry = rowToRawEntry(row);
        final doc = _bfm.parse(entry.bodyMd);
        final hitsTag = doc.tags.any(
          (t) =>
              t == normalizedQueryTag || t.startsWith('$normalizedQueryTag/'),
        );
        if (hitsTag) {
          matched.add(entry);
        }
      }
      if (query.offset >= matched.length) {
        return const <RawEntry>[];
      }
      final end = (query.offset + query.limit).clamp(0, matched.length);
      return matched.sublist(query.offset, end);
    }

    params
      ..add(query.limit)
      ..add(query.offset);
    final rows = db.select(
      'SELECT * FROM raw_entries $whereSql $orderSql LIMIT ? OFFSET ?',
      params,
    );
    return rows.map(rowToRawEntry).toList(growable: false);
  }

  @override
  Stream<List<RawEntry>> watchEntries([EntryQuery query = const EntryQuery()]) {
    return _watchQuery(() => listEntries(query));
  }

  @override
  Future<Map<String, int>> listTagCounts({PrivacyLevel? privacyFilter}) async {
    final db = _dbProvider();
    final where = <String>['deleted_at IS NULL'];
    final params = <Object?>[];
    if (privacyFilter != null) {
      where.add('privacy_level = ?');
      params.add(privacyFilter.wireValue);
    }
    final rows = db.select(
      'SELECT body_md FROM raw_entries WHERE ${where.join(' AND ')}',
      params,
    );
    final counts = <String, int>{};
    for (final row in rows) {
      final doc = _bfm.parse(row['body_md'] as String);
      for (final tag in doc.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    return Map<String, int>.unmodifiable(counts);
  }

  @override
  Future<List<BfmLinkRecord>> getBacklinks(String targetId) async {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT id, src_type, src_id, target_kind, target_id, anchor, privacy_level '
      'FROM ai_bfm_links WHERE target_id = ? ORDER BY id ASC',
      <Object?>[targetId],
    );
    return rows.map(rowToBfmLink).toList(growable: false);
  }

  @override
  Future<RawTask> updateTaskStatus({
    required String taskId,
    required TaskStatus status,
    String? focusDate,
  }) async {
    final nowUtc = DateTime.now().toUtc();
    final nowIso = nowUtc.toIso8601String();
    final hlcTs = _hlcClock.next(nowUtc: nowUtc);
    final deviceId = _deviceIdProvider();

    late RawTask updatedTask;
    RawEntry? updatedSourceEntry;

    _runWriteTx<void>((db) {
      final taskRows = db.select(
        'SELECT * FROM raw_tasks WHERE id = ? LIMIT 1',
        <Object?>[taskId],
      );
      if (taskRows.isEmpty) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Task $taskId not found',
        );
      }
      final row = taskRows.first;
      final existingTask = rowToRawTask(row);
      final storedLineIndex = row['origin_line_index'] as int?;
      final nextFocusDate = focusDate ?? existingTask.focusDate;
      final completedAt = status == TaskStatus.done ? nowUtc : null;
      final nextTaskRev = existingTask.revision + 1;

      db.execute(
        'UPDATE raw_tasks SET status = ?, focus_date = ?, completed_at = ?, '
        'revision = ?, hlc_ts = ?, updated_at = ? WHERE id = ?',
        <Object?>[
          status.wireValue,
          nextFocusDate,
          completedAt?.toIso8601String(),
          nextTaskRev,
          hlcTs,
          nowIso,
          taskId,
        ],
      );

      updatedTask = RawTask(
        id: existingTask.id,
        title: existingTask.title,
        status: status,
        originEntryId: existingTask.originEntryId,
        originAnnotationId: existingTask.originAnnotationId,
        focusDate: nextFocusDate,
        completedAtUtc: completedAt,
        privacyLevel: existingTask.privacyLevel,
        revision: nextTaskRev,
        hlcTs: hlcTs,
        createdAtUtc: existingTask.createdAtUtc,
        updatedAtUtc: nowUtc,
        deletedAtUtc: existingTask.deletedAtUtc,
      );

      // Atomically sync the source BFM checkbox in `raw_entries.body_md` (`FR-TASK-001`).
      if (existingTask.originEntryId != null) {
        final sourceEntry = _fetchEntryByIdInTx(
          db,
          existingTask.originEntryId!,
          includeDeleted: true,
        );
        if (sourceEntry != null) {
          final parsed = _bfm.parse(sourceEntry.bodyMd);
          int? targetLineIndex;
          if (storedLineIndex != null &&
              parsed.tasks.any((t) => t.lineIndex == storedLineIndex)) {
            targetLineIndex = storedLineIndex;
          } else {
            for (final candidate in parsed.tasks) {
              if (candidate.title == existingTask.title) {
                targetLineIndex = candidate.lineIndex;
                break;
              }
            }
          }
          if (targetLineIndex != null) {
            final newBodyMd = _bfm.toggleTaskLine(
              sourceEntry.bodyMd,
              lineIndex: targetLineIndex,
              newStatus: status,
            );
            final entryHlc = _hlcClock.next(nowUtc: nowUtc);
            final nextEntryRev = sourceEntry.revision + 1;
            db.execute(
              'UPDATE raw_entries SET body_md = ?, revision = ?, hlc_ts = ?, updated_at = ? '
              'WHERE id = ?',
              <Object?>[
                newBodyMd,
                nextEntryRev,
                entryHlc,
                nowIso,
                sourceEntry.id,
              ],
            );
            updatedSourceEntry = sourceEntry.copyWith(
              bodyMd: newBodyMd,
              revision: nextEntryRev,
              hlcTs: entryHlc,
              updatedAtUtc: nowUtc,
            );
            _appendOplogAndOutboxInTx(
              db,
              deviceId: deviceId,
              hlcTs: entryHlc,
              baseRevision: sourceEntry.revision,
              entityLayer: 'raw',
              entityType: 'raw_entry',
              entityId: sourceEntry.id,
              opType: 'update',
              opOrigin: 'app_ui',
              privacyLevel: sourceEntry.privacyLevel,
              payload: _entryOpPayload(updatedSourceEntry!),
              createdAtIso: nowIso,
            );
          }
        }
      }

      _appendOplogAndOutboxInTx(
        db,
        deviceId: deviceId,
        hlcTs: hlcTs,
        baseRevision: existingTask.revision,
        entityLayer: 'raw',
        entityType: 'raw_task',
        entityId: taskId,
        opType: 'update',
        opOrigin: 'app_ui',
        privacyLevel: updatedTask.privacyLevel,
        payload: <String, Object?>{
          'id': updatedTask.id,
          'status': updatedTask.status.wireValue,
          'focus_date': updatedTask.focusDate,
          'revision': updatedTask.revision,
        },
        createdAtIso: nowIso,
      );
    });

    if (updatedSourceEntry != null) {
      _fts.indexEntrySync(updatedSourceEntry!);
    }
    _fts.indexTaskSync(updatedTask);
    _onMutated(triggerMirror: true);
    return updatedTask;
  }

  @override
  Future<RawTask> toggleTaskStatus(String taskId) async {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT status FROM raw_tasks WHERE id = ? LIMIT 1',
      <Object?>[taskId],
    );
    if (rows.isEmpty) {
      throw BlinkException(
        code: BlinkErrorCode.notFound,
        message: 'Task $taskId not found',
      );
    }
    final current =
        TaskStatus.tryParse(rows.first['status'] as String?) ?? TaskStatus.open;
    final nextStatus = current == TaskStatus.done
        ? TaskStatus.open
        : TaskStatus.done;
    return updateTaskStatus(taskId: taskId, status: nextStatus);
  }

  @override
  Future<List<RawTask>> listTasks([TaskQuery query = const TaskQuery()]) async {
    final db = _dbProvider();
    final where = <String>[];
    final params = <Object?>[];

    if (!query.includeDeleted) {
      where.add('deleted_at IS NULL');
    }
    if (query.statuses != null && query.statuses!.isNotEmpty) {
      final placeholders = List<String>.filled(
        query.statuses!.length,
        '?',
      ).join(', ');
      where.add('status IN ($placeholders)');
      params.addAll(query.statuses!.map((s) => s.wireValue));
    }
    if (query.focusDate != null) {
      where.add('focus_date = ?');
      params.add(query.focusDate);
    }
    if (query.privacyFilter != null) {
      where.add('privacy_level = ?');
      params.add(query.privacyFilter!.wireValue);
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = db.select(
      'SELECT * FROM raw_tasks $whereSql ORDER BY created_at DESC, id DESC',
      params,
    );
    return rows.map(rowToRawTask).toList(growable: false);
  }

  @override
  Stream<List<RawTask>> watchTasks([TaskQuery query = const TaskQuery()]) {
    return _watchQuery(() => listTasks(query));
  }

  @override
  Future<void> saveDraft(EditorDraft draft) async {
    if (draft.draftKey.trim().isEmpty) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'draftKey must not be empty',
      );
    }
    for (final sha in draft.imageBlobSha256s) {
      _validateOptionalBlobSha(sha, field: 'imageBlobSha256s');
    }
    _runWriteTx<void>((db) {
      db.execute(
        'INSERT INTO editor_drafts '
        '(draft_key, body_md, entry_kind, privacy_locked, image_blob_sha256s, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(draft_key) DO UPDATE SET '
        'body_md = excluded.body_md, '
        'entry_kind = excluded.entry_kind, '
        'privacy_locked = excluded.privacy_locked, '
        'image_blob_sha256s = excluded.image_blob_sha256s, '
        'updated_at = excluded.updated_at',
        <Object?>[
          draft.draftKey,
          draft.bodyMd,
          draft.entryKind.wireValue,
          draft.privacyLocked ? 1 : 0,
          jsonEncode(draft.imageBlobSha256s),
          draft.updatedAtUtc.toUtc().toIso8601String(),
        ],
      );
    });
    // Drafts never enter `sync_oplog` or `mirror/`.
  }

  @override
  Future<EditorDraft?> loadDraft(String draftKey) async {
    final db = _dbProvider();
    final rows = db.select(
      'SELECT draft_key, body_md, entry_kind, privacy_locked, image_blob_sha256s, updated_at '
      'FROM editor_drafts WHERE draft_key = ? LIMIT 1',
      <Object?>[draftKey],
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.first;
    return EditorDraft(
      draftKey: row['draft_key'] as String,
      bodyMd: row['body_md'] as String,
      entryKind:
          EntryKind.tryParse(row['entry_kind'] as String?) ?? EntryKind.blink,
      privacyLocked: (row['privacy_locked'] as int) != 0,
      imageBlobSha256s: decodeStringListJson(
        row['image_blob_sha256s'] as String?,
      ),
      updatedAtUtc: DateTime.parse(row['updated_at'] as String).toUtc(),
    );
  }

  @override
  Future<void> clearDraft(String draftKey) async {
    _runWriteTx<void>((db) {
      db.execute('DELETE FROM editor_drafts WHERE draft_key = ?', <Object?>[
        draftKey,
      ]);
    });
  }

  Stream<T> _watchQuery<T>(Future<T> Function() loader) {
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

  void _reconcileEntryTasksInTx(
    Database db, {
    required RawEntry entry,
    required List<BfmTaskItem> parsedTasks,
    required DateTime nowUtc,
    required List<RawTask> outActiveTasks,
    required List<String> outRemovedTaskIds,
  }) {
    final nowIso = nowUtc.toIso8601String();
    final existingRows = db.select(
      'SELECT * FROM raw_tasks WHERE origin_entry_id = ? AND deleted_at IS NULL '
      'ORDER BY origin_line_index ASC, created_at ASC',
      <Object?>[entry.id],
    );
    final remaining = existingRows.toList();

    for (final item in parsedTasks) {
      // Match existing task by exact lineIndex first, else by title.
      var matchedIndex = remaining.indexWhere(
        (r) => (r['origin_line_index'] as int?) == item.lineIndex,
      );
      if (matchedIndex < 0) {
        matchedIndex = remaining.indexWhere(
          (r) => (r['title'] as String) == item.title,
        );
      }

      if (matchedIndex >= 0) {
        final row = remaining.removeAt(matchedIndex);
        final prev = rowToRawTask(row);
        final nextRev = prev.revision + 1;
        final hlc = _hlcClock.next(nowUtc: nowUtc);
        final completedAt = item.status == TaskStatus.done
            ? (prev.completedAtUtc ?? nowUtc)
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
            nextRev,
            hlc,
            nowIso,
            prev.id,
          ],
        );
        outActiveTasks.add(
          RawTask(
            id: prev.id,
            title: item.title,
            status: item.status,
            originEntryId: entry.id,
            focusDate: prev.focusDate,
            completedAtUtc: completedAt,
            privacyLevel: entry.privacyLevel,
            revision: nextRev,
            hlcTs: hlc,
            createdAtUtc: prev.createdAtUtc,
            updatedAtUtc: nowUtc,
          ),
        );
      } else {
        final taskId = generateUuidV7(timestamp: nowUtc);
        final hlc = _hlcClock.next(nowUtc: nowUtc);
        final completedAt = item.status == TaskStatus.done ? nowUtc : null;
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
            hlc,
            nowIso,
            nowIso,
          ],
        );
        outActiveTasks.add(
          RawTask(
            id: taskId,
            title: item.title,
            status: item.status,
            originEntryId: entry.id,
            completedAtUtc: completedAt,
            privacyLevel: entry.privacyLevel,
            revision: 1,
            hlcTs: hlc,
            createdAtUtc: nowUtc,
            updatedAtUtc: nowUtc,
          ),
        );
      }
    }

    // Soft-delete tasks removed from `body_md`.
    for (final orphanRow in remaining) {
      final orphanId = orphanRow['id'] as String;
      outRemovedTaskIds.add(orphanId);
      db.execute(
        'UPDATE raw_tasks SET deleted_at = ?, updated_at = ? WHERE id = ?',
        <Object?>[nowIso, nowIso, orphanId],
      );
    }
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

  void _appendOplogAndOutboxInTx(
    Database db, {
    required String deviceId,
    required String hlcTs,
    required int baseRevision,
    required String entityLayer,
    required String entityType,
    required String entityId,
    required String opType,
    required String opOrigin,
    required PrivacyLevel privacyLevel,
    required Map<String, Object?> payload,
    required String createdAtIso,
  }) {
    final clientOpId = generateUuidV7();
    final payloadJson = jsonEncode(payload);
    db.execute(
      'INSERT INTO sync_oplog '
      '(device_id, client_op_id, hlc_ts, base_revision, entity_layer, entity_type, '
      'entity_id, op_type, op_origin, privacy_level, payload_json, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      <Object?>[
        deviceId,
        clientOpId,
        hlcTs,
        baseRevision,
        entityLayer,
        entityType,
        entityId,
        opType,
        opOrigin,
        privacyLevel.wireValue,
        payloadJson,
        createdAtIso,
      ],
    );
    db.execute(
      'INSERT INTO outbox_ops '
      '(client_op_id, device_id, hlc_ts, entity_layer, entity_type, entity_id, '
      'op_type, privacy_level, payload_json, status, created_at) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?)",
      <Object?>[
        clientOpId,
        deviceId,
        hlcTs,
        entityLayer,
        entityType,
        entityId,
        opType,
        privacyLevel.wireValue,
        payloadJson,
        createdAtIso,
      ],
    );
  }

  static RawEntry? _fetchEntryByIdInTx(
    Database db,
    String id, {
    required bool includeDeleted,
  }) {
    final sql = includeDeleted
        ? 'SELECT * FROM raw_entries WHERE id = ? LIMIT 1'
        : 'SELECT * FROM raw_entries WHERE id = ? AND deleted_at IS NULL LIMIT 1';
    final rows = db.select(sql, <Object?>[id]);
    if (rows.isEmpty) {
      return null;
    }
    return rowToRawEntry(rows.first);
  }

  static void _validateOptionalBlobSha(String? sha, {required String field}) {
    if (sha != null && !isValidBlobSha256(sha)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid SHA-256 hex digest in $field',
      );
    }
  }

  static Map<String, Object?> _entryOpPayload(RawEntry entry) =>
      <String, Object?>{
        'id': entry.id,
        'entry_kind': entry.entryKind.wireValue,
        'body_md': entry.bodyMd,
        'audio_blob_sha256': entry.audioBlobSha256,
        'image_blob_sha256s': entry.imageBlobSha256s,
        'source_ref_id': entry.sourceRefId,
        'capture_origin': entry.captureOrigin.wireValue,
        'privacy_level': entry.privacyLevel.wireValue,
        'revision': entry.revision,
        'hlc_ts': entry.hlcTs,
        'created_at': entry.createdAtUtc.toUtc().toIso8601String(),
        'updated_at': entry.updatedAtUtc.toUtc().toIso8601String(),
        'deleted_at': entry.deletedAtUtc?.toUtc().toIso8601String(),
      };
}

/// Converts a SQLite `raw_entries` / `v_normal_entries` row into [RawEntry].
RawEntry rowToRawEntry(Row row) => RawEntry(
  id: row['id'] as String,
  entryKind:
      EntryKind.tryParse(row['entry_kind'] as String?) ?? EntryKind.blink,
  bodyMd: row['body_md'] as String,
  audioBlobSha256: row['audio_blob_sha256'] as String?,
  imageBlobSha256s: decodeStringListJson(row['image_blob_sha256s'] as String?),
  sourceRefId: row['source_ref_id'] as String?,
  captureOrigin:
      CaptureOrigin.tryParse(row['capture_origin'] as String?) ??
      CaptureOrigin.appUi,
  privacyLevel:
      PrivacyLevel.tryParse(row['privacy_level'] as String?) ??
      PrivacyLevel.normal,
  revision: row['revision'] as int,
  hlcTs: row['hlc_ts'] as String,
  createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
  updatedAtUtc: DateTime.parse(row['updated_at'] as String).toUtc(),
  deletedAtUtc: row['deleted_at'] != null
      ? DateTime.parse(row['deleted_at'] as String).toUtc()
      : null,
);

/// Converts a SQLite `raw_tasks` / `v_normal_tasks` row into [RawTask].
RawTask rowToRawTask(Row row) => RawTask(
  id: row['id'] as String,
  title: row['title'] as String,
  status: TaskStatus.tryParse(row['status'] as String?) ?? TaskStatus.open,
  originEntryId: row['origin_entry_id'] as String?,
  originAnnotationId: row['origin_annotation_id'] as String?,
  focusDate: row['focus_date'] as String?,
  completedAtUtc: row['completed_at'] != null
      ? DateTime.parse(row['completed_at'] as String).toUtc()
      : null,
  privacyLevel:
      PrivacyLevel.tryParse(row['privacy_level'] as String?) ??
      PrivacyLevel.normal,
  revision: row['revision'] as int,
  hlcTs: row['hlc_ts'] as String,
  createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
  updatedAtUtc: DateTime.parse(row['updated_at'] as String).toUtc(),
  deletedAtUtc: row['deleted_at'] != null
      ? DateTime.parse(row['deleted_at'] as String).toUtc()
      : null,
);

/// Converts a SQLite `ai_bfm_links` / `v_normal_bfm_links` row into [BfmLinkRecord].
BfmLinkRecord rowToBfmLink(Row row) => BfmLinkRecord(
  id: row['id'] as String,
  srcType: row['src_type'] as String,
  srcId: row['src_id'] as String,
  targetKind:
      BfmLinkTargetKind.tryParse(row['target_kind'] as String?) ??
      BfmLinkTargetKind.titleQuery,
  targetId: row['target_id'] as String?,
  anchor: row['anchor'] as String?,
  privacyLevel:
      PrivacyLevel.tryParse(row['privacy_level'] as String?) ??
      PrivacyLevel.normal,
);

/// Decodes a JSON string array column into a typed `List<String>`.
List<String> decodeStringListJson(String? rawJson) {
  if (rawJson == null || rawJson.isEmpty) {
    return const <String>[];
  }
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is List) {
      return decoded.whereType<String>().toList(growable: false);
    }
  } catch (_) {}
  return const <String>[];
}
