import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../models/blink_models.dart';

/// A single BM25-ranked search result returned by [FtsSearchService.search].
@immutable
final class FtsSearchHit {
  const FtsSearchHit({
    required this.docId,
    required this.docKind,
    required this.snippet,
    required this.rank,
    required this.privacyLevel,
    required this.updatedAtUtc,
  });

  final String docId;
  final String docKind;
  final String snippet;
  final double rank;
  final PrivacyLevel privacyLevel;
  final DateTime updatedAtUtc;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FtsSearchHit &&
          docId == other.docId &&
          docKind == other.docKind &&
          snippet == other.snippet &&
          rank == other.rank &&
          privacyLevel == other.privacyLevel &&
          updatedAtUtc.isAtSameMomentAs(other.updatedAtUtc);

  @override
  int get hashCode => Object.hash(
    docId,
    docKind,
    snippet,
    rank,
    privacyLevel,
    updatedAtUtc.toUtc(),
  );
}

/// Deterministic `.runes` CJK pre-tokenizer shared by indexing and query building.
///
/// Separates every CJK ideograph / Kana / Hangul scalar value with spaces so
/// SQLite's built-in `unicode61 remove_diacritics 2` tokenizer indexes single
/// characters, bigrams, long Chinese phrases, and mixed CJK/Latin queries
/// without external FTS5 native extensions (`INV-09`).
String cjkFtsPretokenize(String plainText) {
  if (plainText.isEmpty) {
    return '';
  }
  final out = StringBuffer();
  var prevWasSpace = true;

  for (final rune in plainText.runes) {
    if (_isCjkTokenRune(rune)) {
      if (!prevWasSpace) {
        out.write(' ');
      }
      out.writeCharCode(rune);
      out.write(' ');
      prevWasSpace = true;
    } else if (_isWhitespaceRune(rune)) {
      if (!prevWasSpace) {
        out.write(' ');
        prevWasSpace = true;
      }
    } else {
      out.writeCharCode(rune);
      prevWasSpace = false;
    }
  }
  return out.toString().trim();
}

/// Converts raw user input into safe FTS5 `MATCH` syntax:
/// - Contiguous CJK runs (`>= 2` runes) become exact adjacent phrases `"字 词"`.
/// - Alphanumeric / Latin tokens are safely quoted so FTS5 operators (`AND`, `OR`,
///   `NOT`, `NEAR`, `:`, `*`, `"`, `^`, `(`, `)`) can never cause syntax errors or injection.
/// - Returns empty string if no searchable terms remain.
String buildSafeFtsMatchQuery(String rawUserQuery) {
  if (rawUserQuery.trim().isEmpty) {
    return '';
  }
  final terms = <String>[];
  final cjkRun = <String>[];
  final wordRun = StringBuffer();

  void flushCjk() {
    if (cjkRun.isEmpty) {
      return;
    }
    terms.add('"${cjkRun.join(' ')}"');
    cjkRun.clear();
  }

  void flushWord() {
    if (wordRun.isEmpty) {
      return;
    }
    final token = wordRun.toString().replaceAll('"', '');
    if (token.isNotEmpty) {
      terms.add('"$token"');
    }
    wordRun.clear();
  }

  for (final rune in rawUserQuery.runes) {
    if (_isCjkTokenRune(rune)) {
      flushWord();
      cjkRun.add(String.fromCharCode(rune));
    } else if (_isWordRune(rune)) {
      flushCjk();
      wordRun.writeCharCode(rune);
    } else {
      flushCjk();
      flushWord();
    }
  }
  flushCjk();
  flushWord();

  return terms.join(' ');
}

/// Isolated `index/fts.db` CJK FTS5 search service (`INV-03`, `INV-09`).
abstract interface class FtsSearchService {
  Future<List<FtsSearchHit>> search(
    String query, {
    PrivacyScope scope = PrivacyScope.localWithPrivate,
    List<String>? docKinds,
    int limit = 50,
  });

  Future<void> indexEntry(RawEntry entry);

  Future<void> removeDocument(String docId);

  /// Wipes and deterministically rebuilds `index/fts.db` from `raw_*` (`INV-09`).
  Future<void> rebuildFromDatabase();
}

/// SQLite FTS5 implementation backed by isolated `index/fts.db`.
final class SqliteFtsSearchService implements FtsSearchService {
  SqliteFtsSearchService({
    required this._mainDbProvider,
    required this._ftsDbProvider,
    required this._bfm,
  });

  final Database Function() _mainDbProvider;
  final Database Function() _ftsDbProvider;
  final BfmEngine _bfm;

  @override
  Future<List<FtsSearchHit>> search(
    String query, {
    PrivacyScope scope = PrivacyScope.localWithPrivate,
    List<String>? docKinds,
    int limit = 50,
  }) async {
    if (limit <= 0) {
      return const <FtsSearchHit>[];
    }
    final matchExpr = buildSafeFtsMatchQuery(query);
    if (matchExpr.isEmpty) {
      return const <FtsSearchHit>[];
    }

    final ftsDb = _ftsDbProvider();
    final hits = <FtsSearchHit>[
      ..._queryTable(
        ftsDb,
        table: 'fts_normal',
        privacyLevel: PrivacyLevel.normal,
        matchExpr: matchExpr,
        docKinds: docKinds,
        limit: limit,
      ),
      if (scope == PrivacyScope.localWithPrivate)
        ..._queryTable(
          ftsDb,
          table: 'fts_private',
          privacyLevel: PrivacyLevel.private,
          matchExpr: matchExpr,
          docKinds: docKinds,
          limit: limit,
        ),
    ];

    hits.sort((a, b) {
      final rankCmp = a.rank.compareTo(
        b.rank,
      ); // SQLite BM25: more negative = better match.
      if (rankCmp != 0) {
        return rankCmp;
      }
      return b.updatedAtUtc.compareTo(a.updatedAtUtc);
    });

    if (hits.length > limit) {
      return hits.sublist(0, limit);
    }
    return hits;
  }

  /// Synchronous helper used inside `RawRepository` write paths so `fts_normal`/`fts_private`
  /// stay strictly synchronized with `raw_entries`.
  void indexEntrySync(RawEntry entry) {
    final ftsDb = _ftsDbProvider();
    ftsDb.execute('BEGIN IMMEDIATE;');
    try {
      _removeDocInTx(ftsDb, entry.id);
      if (!entry.isDeleted) {
        final plain = _bfm.toPlainText(entry.bodyMd);
        final tokenized = cjkFtsPretokenize(plain);
        final targetTable = entry.isPrivate ? 'fts_private' : 'fts_normal';
        ftsDb.execute(
          'INSERT INTO $targetTable (doc_id, doc_kind, updated_at, content) '
          'VALUES (?, ?, ?, ?)',
          <Object?>[
            entry.id,
            'entry',
            entry.updatedAtUtc.toUtc().toIso8601String(),
            tokenized,
          ],
        );
      }
      ftsDb.execute('COMMIT;');
    } catch (_) {
      ftsDb.execute('ROLLBACK;');
      rethrow;
    }
  }

  /// Synchronous helper to index or remove a single `RawTask`.
  void indexTaskSync(RawTask task) {
    final ftsDb = _ftsDbProvider();
    ftsDb.execute('BEGIN IMMEDIATE;');
    try {
      _removeDocInTx(ftsDb, task.id);
      if (!task.isDeleted) {
        final tokenized = cjkFtsPretokenize(task.title);
        final targetTable = task.isPrivate ? 'fts_private' : 'fts_normal';
        ftsDb.execute(
          'INSERT INTO $targetTable (doc_id, doc_kind, updated_at, content) '
          'VALUES (?, ?, ?, ?)',
          <Object?>[
            task.id,
            'task',
            task.updatedAtUtc.toUtc().toIso8601String(),
            tokenized,
          ],
        );
      }
      ftsDb.execute('COMMIT;');
    } catch (_) {
      ftsDb.execute('ROLLBACK;');
      rethrow;
    }
  }

  void removeDocumentSync(String docId) {
    final ftsDb = _ftsDbProvider();
    ftsDb.execute('BEGIN IMMEDIATE;');
    try {
      _removeDocInTx(ftsDb, docId);
      ftsDb.execute('COMMIT;');
    } catch (_) {
      ftsDb.execute('ROLLBACK;');
      rethrow;
    }
  }

  @override
  Future<void> indexEntry(RawEntry entry) async {
    indexEntrySync(entry);
  }

  @override
  Future<void> removeDocument(String docId) async {
    removeDocumentSync(docId);
  }

  @override
  Future<void> rebuildFromDatabase() async {
    final mainDb = _mainDbProvider();
    final ftsDb = _ftsDbProvider();

    final entryRows = mainDb.select(
      'SELECT id, body_md, privacy_level, updated_at '
      'FROM raw_entries WHERE deleted_at IS NULL',
    );
    final taskRows = mainDb.select(
      'SELECT id, title, privacy_level, updated_at '
      'FROM raw_tasks WHERE deleted_at IS NULL',
    );

    ftsDb.execute('BEGIN IMMEDIATE;');
    try {
      ftsDb.execute('DELETE FROM fts_normal;');
      ftsDb.execute('DELETE FROM fts_private;');

      final insertNormal = ftsDb.prepare(
        'INSERT INTO fts_normal (doc_id, doc_kind, updated_at, content) VALUES (?, ?, ?, ?)',
      );
      final insertPrivate = ftsDb.prepare(
        'INSERT INTO fts_private (doc_id, doc_kind, updated_at, content) VALUES (?, ?, ?, ?)',
      );
      try {
        for (final row in entryRows) {
          final id = row['id'] as String;
          final bodyMd = row['body_md'] as String;
          final privacy = row['privacy_level'] as String;
          final updatedAt = row['updated_at'] as String;
          final tokenized = cjkFtsPretokenize(_bfm.toPlainText(bodyMd));
          final stmt = privacy == PrivacyLevel.private.wireValue
              ? insertPrivate
              : insertNormal;
          stmt.execute(<Object?>[id, 'entry', updatedAt, tokenized]);
        }

        for (final row in taskRows) {
          final id = row['id'] as String;
          final title = row['title'] as String;
          final privacy = row['privacy_level'] as String;
          final updatedAt = row['updated_at'] as String;
          final tokenized = cjkFtsPretokenize(title);
          final stmt = privacy == PrivacyLevel.private.wireValue
              ? insertPrivate
              : insertNormal;
          stmt.execute(<Object?>[id, 'task', updatedAt, tokenized]);
        }
      } finally {
        insertNormal.close();
        insertPrivate.close();
      }
      ftsDb.execute('COMMIT;');
    } catch (_) {
      ftsDb.execute('ROLLBACK;');
      rethrow;
    }
  }

  void _removeDocInTx(Database ftsDb, String docId) {
    ftsDb.execute('DELETE FROM fts_normal WHERE doc_id = ?', <Object?>[docId]);
    ftsDb.execute('DELETE FROM fts_private WHERE doc_id = ?', <Object?>[docId]);
  }

  List<FtsSearchHit> _queryTable(
    Database ftsDb, {
    required String table,
    required PrivacyLevel privacyLevel,
    required String matchExpr,
    required List<String>? docKinds,
    required int limit,
  }) {
    final params = <Object?>[matchExpr];
    final kindClause = StringBuffer();
    if (docKinds != null && docKinds.isNotEmpty) {
      final placeholders = List<String>.filled(docKinds.length, '?').join(', ');
      kindClause.write(' AND doc_kind IN ($placeholders)');
      params.addAll(docKinds);
    }
    params.add(limit);

    final rows = ftsDb.select(
      'SELECT doc_id, doc_kind, updated_at, '
      "snippet($table, 3, '[', ']', '...', 16) AS hit_snippet, "
      'bm25($table) AS score '
      'FROM $table '
      'WHERE $table MATCH ?$kindClause '
      'ORDER BY score ASC, updated_at DESC '
      'LIMIT ?',
      params,
    );

    return rows
        .map(
          (row) => FtsSearchHit(
            docId: row['doc_id'] as String,
            docKind: row['doc_kind'] as String,
            snippet: (row['hit_snippet'] as String? ?? '').trim(),
            rank: (row['score'] as num?)?.toDouble() ?? 0.0,
            privacyLevel: privacyLevel,
            updatedAtUtc: DateTime.parse(row['updated_at'] as String).toUtc(),
          ),
        )
        .toList(growable: false);
  }
}

bool _isCjkTokenRune(int rune) =>
    // CJK Unified Ideographs & Extension A
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    // CJK Compatibility Ideographs
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    // Hiragana & Katakana
    (rune >= 0x3040 && rune <= 0x30FF) ||
    (rune >= 0x31F0 && rune <= 0x31FF) ||
    // Hangul Syllables & Jamo
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x3130 && rune <= 0x318F) ||
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    // CJK Extensions B..G
    (rune >= 0x20000 && rune <= 0x323AF);

bool _isWhitespaceRune(int rune) =>
    rune == 0x20 ||
    rune == 0x09 ||
    rune == 0x0A ||
    rune == 0x0D ||
    rune == 0x3000;

bool _isWordRune(int rune) =>
    (rune >= 0x30 && rune <= 0x39) || // 0-9
    (rune >= 0x41 && rune <= 0x5A) || // A-Z
    (rune >= 0x61 && rune <= 0x7A) || // a-z
    rune == 0x5F || // _
    (rune >= 0x00C0 && rune <= 0x024F); // Latin accented letters
