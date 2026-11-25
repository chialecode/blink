import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../search/fts_search_service.dart';
import '../utils/uuid_v7.dart';
import 'raw_repository.dart';

/// Compile-time `INV-01` & `INV-03` firewall for external CLI/MCP AI and derived-layer access.
///
/// Intentionally exposes ZERO `create`, `update`, `softDelete`, or `purge` methods on `raw_*`.
/// Under default [PrivacyScope.normalOnly], queries exclusively `v_normal_*` views & `fts_normal`,
/// returns `null` (or opaque [BlinkErrorCode.notFound] from [requireEntry]) for private IDs,
/// and redacts cross-privacy references inside returned entries.
abstract interface class ExternalAiRepository {
  PrivacyScope get scope;

  /// Returns `null` when missing OR when target is `#private` under [PrivacyScope.normalOnly].
  Future<RawEntry?> getEntry(String id);

  /// Throws opaque [BlinkException] (`BlinkErrorCode.notFound`) when missing OR
  /// when target is `#private` under [PrivacyScope.normalOnly] (zero existence side-channel).
  Future<RawEntry> requireEntry(String id);

  Future<List<RawEntry>> listEntries({int? sinceSeq, int limit = 50});

  Future<List<RawTask>> listTasks({TaskStatus? status, int limit = 100});

  Future<List<FtsSearchHit>> search(String query, {int limit = 20});

  /// Verifies `<blink-ref>` existence and privacy scope (`INV-03`, `INV-13`).
  Future<bool> isReferenceAccessible({
    required BfmLinkTargetKind kind,
    required String id,
  });

  /// Creates a live synchronous [BlinkRefValidator] for `packages/blink_sanitizer`
  /// enforcing both target existence and active [scope] isolation.
  BlinkRefValidator createRefValidator();

  /// Runs `packages/blink_sanitizer` with this repository's live [BlinkRefValidator]
  /// and active [scope].
  SanitizeResult sanitizeAndValidateHtml(
    String rawHtml, {
    required SanitizeProfile profile,
    HtmlProducer producer = HtmlProducer.aiDerived,
    bool compileSurface2Refs = true,
  });

  /// Derived-layer-only write (`ai_bfm_links`) for M3 verification & M6 MCP/CLI reuse (`INV-01`).
  Future<void> upsertBfmLinks(
    String srcType,
    String srcId,
    List<BfmLinkRecord> links,
  );
}

/// SQLite view-enforced implementation of [ExternalAiRepository].
final class SqliteExternalAiRepository implements ExternalAiRepository {
  SqliteExternalAiRepository({
    required this.scope,
    required this._dbProvider,
    required this._runWriteTx,
    required this._searchService,
    required this._bfm,
  });

  @override
  final PrivacyScope scope;

  final Database Function() _dbProvider;
  final T Function<T>(T Function(Database db) action) _runWriteTx;
  final FtsSearchService _searchService;
  final BfmEngine _bfm;

  static const BlinkHtmlSanitizer _sanitizer = BlinkHtmlSanitizer();

  @override
  Future<RawEntry?> getEntry(String id) async {
    final db = _dbProvider();
    final rows = scope == PrivacyScope.normalOnly
        ? db.select(
            'SELECT * FROM v_normal_entries WHERE id = ? LIMIT 1',
            <Object?>[id],
          )
        : db.select(
            'SELECT * FROM raw_entries WHERE id = ? AND deleted_at IS NULL LIMIT 1',
            <Object?>[id],
          );
    if (rows.isEmpty) {
      return null;
    }
    return _applyRedactionIfNeeded(db, rowToRawEntry(rows.first));
  }

  @override
  Future<RawEntry> requireEntry(String id) async {
    final entry = await getEntry(id);
    if (entry == null) {
      // Identical opaque error whether missing or `#private` (`INV-03`).
      throw BlinkException(
        code: BlinkErrorCode.notFound,
        message: 'Entry $id not found',
      );
    }
    return entry;
  }

  @override
  Future<List<RawEntry>> listEntries({int? sinceSeq, int limit = 50}) async {
    if (limit < 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'limit must be non-negative',
      );
    }
    final db = _dbProvider();
    final ResultSet rows;
    if (sinceSeq != null) {
      if (scope == PrivacyScope.normalOnly) {
        rows = db.select(
          'SELECT DISTINCT e.* FROM v_normal_entries e '
          'INNER JOIN sync_oplog o '
          "  ON o.entity_type = 'raw_entry' AND o.entity_id = e.id "
          "  AND o.privacy_level = 'normal' "
          'WHERE o.seq_id > ? '
          'ORDER BY e.updated_at DESC, e.id DESC LIMIT ?',
          <Object?>[sinceSeq, limit],
        );
      } else {
        rows = db.select(
          'SELECT DISTINCT e.* FROM raw_entries e '
          'INNER JOIN sync_oplog o '
          "  ON o.entity_type = 'raw_entry' AND o.entity_id = e.id "
          'WHERE e.deleted_at IS NULL AND o.seq_id > ? '
          'ORDER BY e.updated_at DESC, e.id DESC LIMIT ?',
          <Object?>[sinceSeq, limit],
        );
      }
    } else {
      rows = scope == PrivacyScope.normalOnly
          ? db.select(
              'SELECT * FROM v_normal_entries ORDER BY created_at DESC, id DESC LIMIT ?',
              <Object?>[limit],
            )
          : db.select(
              'SELECT * FROM raw_entries WHERE deleted_at IS NULL '
              'ORDER BY created_at DESC, id DESC LIMIT ?',
              <Object?>[limit],
            );
    }
    return rows
        .map((row) => _applyRedactionIfNeeded(db, rowToRawEntry(row)))
        .toList(growable: false);
  }

  @override
  Future<List<RawTask>> listTasks({TaskStatus? status, int limit = 100}) async {
    if (limit < 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'limit must be non-negative',
      );
    }
    final db = _dbProvider();
    final table = scope == PrivacyScope.normalOnly
        ? 'v_normal_tasks'
        : 'raw_tasks';
    final where = <String>[
      if (scope != PrivacyScope.normalOnly) 'deleted_at IS NULL',
      if (status != null) 'status = ?',
    ];
    final params = <Object?>[if (status != null) status.wireValue, limit];
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = db.select(
      'SELECT * FROM $table $whereSql ORDER BY created_at DESC, id DESC LIMIT ?',
      params,
    );
    return rows.map(rowToRawTask).toList(growable: false);
  }

  @override
  Future<List<FtsSearchHit>> search(String query, {int limit = 20}) {
    return _searchService.search(query, scope: scope, limit: limit);
  }

  @override
  Future<bool> isReferenceAccessible({
    required BfmLinkTargetKind kind,
    required String id,
  }) async {
    final status = _validateReferenceSync(
      kind: kind,
      id: id,
      activeScope: scope,
    );
    return status == BlinkRefValidationStatus.valid;
  }

  @override
  BlinkRefValidator createRefValidator() {
    return (BlinkRefTarget target, PrivacyScope requestedScope) {
      final effectiveScope =
          (scope == PrivacyScope.normalOnly ||
              requestedScope == PrivacyScope.normalOnly)
          ? PrivacyScope.normalOnly
          : PrivacyScope.localWithPrivate;
      if (target.kind == BlinkRefKind.titleQuery) {
        return BlinkRefValidationStatus.valid;
      }
      final id = target.id;
      if (id == null || id.isEmpty) {
        return BlinkRefValidationStatus.notFound;
      }
      final mappedKind = switch (target.kind) {
        BlinkRefKind.entry => BfmLinkTargetKind.entry,
        BlinkRefKind.annotation => BfmLinkTargetKind.annotation,
        BlinkRefKind.source => BfmLinkTargetKind.source,
        BlinkRefKind.titleQuery => BfmLinkTargetKind.titleQuery,
      };
      return _validateReferenceSync(
        kind: mappedKind,
        id: id,
        activeScope: effectiveScope,
      );
    };
  }

  @override
  SanitizeResult sanitizeAndValidateHtml(
    String rawHtml, {
    required SanitizeProfile profile,
    HtmlProducer producer = HtmlProducer.aiDerived,
    bool compileSurface2Refs = true,
  }) {
    return _sanitizer.sanitize(
      rawHtml,
      options: SanitizeOptions(
        profile: profile,
        producer: producer,
        privacyScope: scope,
        refValidator: createRefValidator(),
        compileSurface2Refs: compileSurface2Refs,
      ),
    );
  }

  @override
  Future<void> upsertBfmLinks(
    String srcType,
    String srcId,
    List<BfmLinkRecord> links,
  ) async {
    if (srcType != 'entry' && srcType != 'annotation') {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'srcType must be "entry" or "annotation"',
      );
    }
    if (scope == PrivacyScope.normalOnly) {
      final hasPrivate = links.any(
        (l) => l.privacyLevel == PrivacyLevel.private,
      );
      if (hasPrivate) {
        throw BlinkException(
          code: BlinkErrorCode.privacyBlocked,
          message: 'Cannot write private links under normal_only scope',
        );
      }
      // Also refuse writing derived links for a private source under normalOnly.
      final srcKind = srcType == 'entry'
          ? BfmLinkTargetKind.entry
          : BfmLinkTargetKind.annotation;
      final accessible = await isReferenceAccessible(kind: srcKind, id: srcId);
      if (!accessible) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Source $srcType/$srcId not found',
        );
      }
    }

    _runWriteTx<void>((db) {
      db.execute(
        'DELETE FROM ai_bfm_links WHERE src_type = ? AND src_id = ?',
        <Object?>[srcType, srcId],
      );
      for (final link in links) {
        db.execute(
          'INSERT INTO ai_bfm_links '
          '(id, src_type, src_id, target_kind, target_id, anchor, privacy_level) '
          'VALUES (?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            link.id.isEmpty ? generateUuidV7() : link.id,
            srcType,
            srcId,
            link.targetKind.wireValue,
            link.targetId,
            link.anchor,
            link.privacyLevel.wireValue,
          ],
        );
      }
    });
  }

  BlinkRefValidationStatus _validateReferenceSync({
    required BfmLinkTargetKind kind,
    required String id,
    required PrivacyScope activeScope,
  }) {
    final db = _dbProvider();
    switch (kind) {
      case BfmLinkTargetKind.titleQuery:
        return BlinkRefValidationStatus.valid;
      case BfmLinkTargetKind.entry:
        return _checkPrivacyTable(
          db,
          table: 'raw_entries',
          id: id,
          activeScope: activeScope,
        );
      case BfmLinkTargetKind.annotation:
        return _checkPrivacyTable(
          db,
          table: 'raw_annotations',
          id: id,
          activeScope: activeScope,
        );
      case BfmLinkTargetKind.source:
        return _checkPrivacyTable(
          db,
          table: 'raw_sources',
          id: id,
          activeScope: activeScope,
        );
      case BfmLinkTargetKind.ai:
        final synthRows = db.select(
          'SELECT privacy_scope FROM ai_syntheses WHERE id = ? LIMIT 1',
          <Object?>[id],
        );
        if (synthRows.isNotEmpty) {
          final synthScope = synthRows.first['privacy_scope'] as String;
          if (activeScope == PrivacyScope.normalOnly &&
              synthScope != PrivacyScope.normalOnly.wireValue) {
            return BlinkRefValidationStatus.privacyScopeViolation;
          }
          return BlinkRefValidationStatus.valid;
        }
        final principleRows = db.select(
          'SELECT privacy_level FROM ai_user_principles WHERE id = ? LIMIT 1',
          <Object?>[id],
        );
        if (principleRows.isNotEmpty) {
          final privacy = principleRows.first['privacy_level'] as String;
          if (activeScope == PrivacyScope.normalOnly &&
              privacy == PrivacyLevel.private.wireValue) {
            return BlinkRefValidationStatus.privacyScopeViolation;
          }
          return BlinkRefValidationStatus.valid;
        }
        return BlinkRefValidationStatus.notFound;
    }
  }

  BlinkRefValidationStatus _checkPrivacyTable(
    Database db, {
    required String table,
    required String id,
    required PrivacyScope activeScope,
  }) {
    final rows = db.select(
      'SELECT privacy_level FROM $table WHERE id = ? AND deleted_at IS NULL LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) {
      return BlinkRefValidationStatus.notFound;
    }
    final privacy = rows.first['privacy_level'] as String;
    if (activeScope == PrivacyScope.normalOnly &&
        privacy == PrivacyLevel.private.wireValue) {
      return BlinkRefValidationStatus.privacyScopeViolation;
    }
    return BlinkRefValidationStatus.valid;
  }

  RawEntry _applyRedactionIfNeeded(Database db, RawEntry entry) {
    if (scope != PrivacyScope.normalOnly) {
      return entry;
    }
    final privateIds = _collectPrivateIds(db);
    if (privateIds.isEmpty) {
      return entry;
    }
    final redactedBody = _bfm.redactPrivateReferences(
      entry.bodyMd,
      privateTargetIds: privateIds,
    );
    if (redactedBody == entry.bodyMd) {
      return entry;
    }
    return entry.copyWith(bodyMd: redactedBody);
  }

  static Set<String> _collectPrivateIds(Database db) {
    final ids = <String>{};
    for (final row in db.select(
      "SELECT id FROM raw_entries WHERE privacy_level = 'private'",
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM raw_sources WHERE privacy_level = 'private'",
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM raw_annotations WHERE privacy_level = 'private'",
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM ai_syntheses WHERE privacy_scope = 'local_with_private'",
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM ai_user_principles WHERE privacy_level = 'private'",
    )) {
      ids.add(row['id'] as String);
    }
    return ids;
  }
}
