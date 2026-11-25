import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blink_sanitizer/blink_sanitizer.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../errors/blink_error.dart';
import '../mirror/mirror_exporter.dart';
import '../models/blink_models.dart';
import '../repositories/external_ai_repository.dart';
import '../repositories/raw_repository.dart';
import '../search/fts_search_service.dart';
import '../storage/blob_store.dart';
import '../utils/atomic_io.dart';
import '../utils/hlc.dart';
import '../utils/uuid_v7.dart';
import 'vault_config.dart';
import 'vault_schema.dart';

/// Orchestrates `<BLINK_VAULT_DIR>` initialization, channel locking, SQLite WAL
/// transactions, isolated CJK FTS5, content-addressed blobs, repositories, and
/// open Markdown mirror exporting (`INV-01`..`INV-13`).
class VaultManager {
  VaultManager._({
    required this.config,
    required this.metadata,
    required this._mainDb,
    required this._ftsDb,
    required this._deviceId,
    required this._hlcClock,
  }) {
    _bfm = const BfmEngine();
    _fts = SqliteFtsSearchService(
      mainDbProvider: _requireMainDb,
      ftsDbProvider: _requireFtsDb,
      bfm: _bfm,
    );
    _blobs = SqliteBlobStore(
      vaultDir: config.vaultDir,
      dbProvider: _requireMainDb,
      runWriteTx: _runWriteTransaction,
      onMutated: () => _notifyMutation(triggerMirror: false),
    );
    _raw = SqliteRawRepository(
      dbProvider: _requireMainDb,
      runWriteTx: _runWriteTransaction,
      deviceIdProvider: () => _deviceId,
      hlcClock: _hlcClock,
      bfm: _bfm,
      fts: _fts,
      blobs: _blobs,
      onMutated: _notifyMutation,
      mutationStream: _mutationController.stream,
    );
    _externalAiNormal = SqliteExternalAiRepository(
      scope: PrivacyScope.normalOnly,
      dbProvider: _requireMainDb,
      runWriteTx: _runWriteTransaction,
      searchService: _fts,
      bfm: _bfm,
    );
    _externalAiPrivate = SqliteExternalAiRepository(
      scope: PrivacyScope.localWithPrivate,
      dbProvider: _requireMainDb,
      runWriteTx: _runWriteTransaction,
      searchService: _fts,
      bfm: _bfm,
    );
    _mirror = FileMirrorExporter(
      vaultDir: config.vaultDir,
      enabled: config.enableMirrorExporter,
      debounceDuration: config.mirrorDebounce,
      dbProvider: _requireMainDb,
      isVaultOpen: () => _isOpen,
      persistWatermarkSeq: _persistMirrorWatermarkSeq,
      initialWatermarkSeq: _readMirrorWatermarkSeq(_mainDb),
      bfm: _bfm,
    );
  }

  /// Opens or initializes `<BLINK_VAULT_DIR>` enforcing `INV-06`, `INV-07`, `INV-08`.
  static Future<VaultManager> open(VaultConfig config) async {
    final vaultDir = config.vaultDir;
    await vaultDir.create(recursive: true);

    final vaultJsonFile = File(p.join(vaultDir.path, 'vault.json'));
    final metadata = await _loadOrCreateVaultMetadata(
      vaultJsonFile: vaultJsonFile,
      expectedChannel: config.expectedChannel,
    );

    final dbDir = Directory(p.join(vaultDir.path, 'db'));
    final backupsDir = Directory(p.join(dbDir.path, 'backups'));
    final indexDir = Directory(p.join(vaultDir.path, 'index'));
    final blobsDir = Directory(p.join(vaultDir.path, 'blobs'));
    await Future.wait(<Future<Directory>>[
      dbDir.create(recursive: true),
      backupsDir.create(recursive: true),
      indexDir.create(recursive: true),
      blobsDir.create(recursive: true),
    ]);

    final mainDbPath = p.join(dbDir.path, 'blink.db');
    final ftsDbPath = p.join(indexDir.path, 'fts.db');

    Database? mainDb;
    Database? ftsDb;
    try {
      mainDb = sqlite3.open(mainDbPath);
      applyBlinkSqlitePragmas(mainDb);

      // Guard against future schema versions or channel tampering inside `blink.db`.
      _validateOrInitMainDatabase(
        mainDb,
        metadata: metadata,
        expectedChannel: config.expectedChannel,
      );

      final deviceId = _resolveOrPersistDeviceId(mainDb, config.deviceId);
      final hlcClock = HlcClock(nodeId: deviceId);
      _seedHlcFromDatabase(mainDb, hlcClock);

      ftsDb = sqlite3.open(ftsDbPath);
      applyBlinkSqlitePragmas(ftsDb);
      initializeFtsDatabaseSchema(ftsDb);

      return VaultManager._(
        config: config,
        metadata: metadata,
        mainDb: mainDb,
        ftsDb: ftsDb,
        deviceId: deviceId,
        hlcClock: hlcClock,
      );
    } catch (error) {
      ftsDb?.close();
      mainDb?.close();
      if (error is BlinkException) {
        rethrow;
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Failed to open vault: $error',
        cause: error,
      );
    }
  }

  final VaultConfig config;
  final VaultMetadata metadata;
  final Database _mainDb;
  final Database _ftsDb;
  final String _deviceId;
  final HlcClock _hlcClock;

  late final BfmEngine _bfm;
  late final SqliteFtsSearchService _fts;
  late final SqliteBlobStore _blobs;
  late final SqliteRawRepository _raw;
  late final SqliteExternalAiRepository _externalAiNormal;
  late final SqliteExternalAiRepository _externalAiPrivate;
  late final FileMirrorExporter _mirror;

  final StreamController<int> _mutationController =
      StreamController<int>.broadcast();
  int _mutationEpoch = 0;
  bool _isOpen = true;
  bool _isCriticalOperationRunning = false;

  bool get isOpen => _isOpen;

  /// `true` while `VACUUM INTO` hot backup or derived-store rebuild is running.
  bool get isCriticalOperationRunning => _isCriticalOperationRunning;

  RawRepository get raw => _raw;

  /// Default `PrivacyScope.normalOnly` external AI facade (`INV-01`, `INV-03`).
  ExternalAiRepository get externalAi => _externalAiNormal;

  ExternalAiRepository externalAiWithScope(PrivacyScope scope) =>
      scope == PrivacyScope.localWithPrivate
      ? _externalAiPrivate
      : _externalAiNormal;

  FtsSearchService get search => _fts;

  BlobStore get blobs => _blobs;

  BfmEngine get bfm => _bfm;

  MirrorExporter get mirror => _mirror;

  Future<VaultStats> getStats() async {
    final db = _requireMainDb();
    final activeEntries =
        (db
                .select(
                  'SELECT COUNT(*) AS c FROM raw_entries WHERE deleted_at IS NULL',
                )
                .first['c']
            as int?) ??
        0;
    final privateEntries =
        (db
                .select(
                  "SELECT COUNT(*) AS c FROM raw_entries WHERE deleted_at IS NULL AND privacy_level = 'private'",
                )
                .first['c']
            as int?) ??
        0;
    final trashedEntries =
        (db
                .select(
                  'SELECT COUNT(*) AS c FROM raw_entries WHERE deleted_at IS NOT NULL',
                )
                .first['c']
            as int?) ??
        0;
    final openTasks =
        (db
                .select(
                  "SELECT COUNT(*) AS c FROM raw_tasks WHERE deleted_at IS NULL AND status = 'open'",
                )
                .first['c']
            as int?) ??
        0;
    final blobRow = db
        .select(
          'SELECT COUNT(*) AS cnt, COALESCE(SUM(byte_size), 0) AS total_bytes FROM media_blobs',
        )
        .first;
    final totalBlobs = (blobRow['cnt'] as int?) ?? 0;
    final totalBlobBytes = (blobRow['total_bytes'] as int?) ?? 0;
    final latestSeqId =
        (db
                .select(
                  'SELECT COALESCE(MAX(seq_id), 0) AS max_seq FROM sync_oplog',
                )
                .first['max_seq']
            as int?) ??
        0;
    final mirrorWatermarkSeq = _readMirrorWatermarkSeq(db);

    return VaultStats(
      activeEntries: activeEntries,
      privateEntries: privateEntries,
      trashedEntries: trashedEntries,
      openTasks: openTasks,
      totalBlobs: totalBlobs,
      totalBlobBytes: totalBlobBytes,
      latestSeqId: latestSeqId,
      mirrorWatermarkSeq: mirrorWatermarkSeq,
    );
  }

  Stream<VaultStats> watchStats() {
    late StreamController<VaultStats> controller;
    StreamSubscription<int>? sub;

    Future<void> emitLatest() async {
      if (controller.isClosed || !_isOpen) {
        return;
      }
      try {
        final stats = await getStats();
        if (!controller.isClosed) {
          controller.add(stats);
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      }
    }

    controller = StreamController<VaultStats>.broadcast(
      onListen: () {
        unawaited(emitLatest());
        sub = _mutationController.stream.listen((_) {
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

  /// Creates an atomic `VACUUM INTO` hot snapshot (`< 1s`, `INV-07`) into [destFile]
  /// (defaults to `<BLINK_VAULT_DIR>/db/backups/blink-<utc>.db`).
  Future<VaultBackupResult> createHotBackup({File? destFile}) async {
    final db = _requireMainDb();
    final nowUtc = DateTime.now().toUtc();
    final target =
        destFile ??
        File(
          p.join(
            config.vaultDir.path,
            'db',
            'backups',
            'blink-${formatCompactUtcStamp(nowUtc)}.db',
          ),
        );
    await target.parent.create(recursive: true);
    final tempFile = siblingTempFile(target);

    _isCriticalOperationRunning = true;
    try {
      final escapedTmpPath = tempFile.path.replaceAll("'", "''");
      db.execute("VACUUM INTO '$escapedTmpPath';");

      // Open and flush the snapshot file descriptor to ensure durability before rename.
      final raf = await tempFile.open(mode: FileMode.append);
      try {
        await raf.flush();
      } finally {
        await raf.close();
      }

      final bytes = await tempFile.readAsBytes();
      final sha256Hex = crypto.sha256.convert(bytes).toString();
      await atomicRenameWithRetry(tempFile, target);

      return VaultBackupResult(
        backupFile: target,
        byteSize: bytes.length,
        sha256: sha256Hex,
        createdAtUtc: nowUtc,
      );
    } catch (error) {
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      if (error is BlinkException) {
        rethrow;
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'VACUUM INTO hot backup failed: $error',
        retryable: true,
        cause: error,
      );
    } finally {
      _isCriticalOperationRunning = false;
    }
  }

  /// `INV-09`: Wipes and deterministically rebuilds `index/fts.db`, `ai_bfm_links`
  /// (plus optional `ai_*` tables when [clearAiTables] is `true`), and `mirror/`
  /// from `raw_*` without touching a single byte of `raw_*`.
  Future<void> rebuildDerivedStores({bool clearAiTables = false}) async {
    _requireMainDb();
    _isCriticalOperationRunning = true;
    try {
      _runWriteTransaction<void>((db) {
        if (clearAiTables) {
          db.execute('DELETE FROM ai_entry_enrichments;');
          db.execute('DELETE FROM ai_task_candidates;');
          db.execute('DELETE FROM ai_echo_links;');
          db.execute('DELETE FROM ai_syntheses;');
          db.execute('DELETE FROM ai_user_principles;');
        }
        db.execute('DELETE FROM ai_bfm_links;');

        final entries = db.select(
          'SELECT id, body_md, privacy_level FROM raw_entries WHERE deleted_at IS NULL',
        );
        for (final row in entries) {
          final entryId = row['id'] as String;
          final bodyMd = row['body_md'] as String;
          final privacy = row['privacy_level'] as String;
          final parsed = _bfm.parse(bodyMd);
          for (final link in parsed.links) {
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
                privacy,
              ],
            );
          }
        }
      });

      await _fts.rebuildFromDatabase();
      if (config.enableMirrorExporter) {
        await _mirror.rebuildAll();
      }
      _notifyMutation(triggerMirror: false);
    } finally {
      _isCriticalOperationRunning = false;
    }
  }

  /// Clean shutdown hook (`INV-07`): flushes debounced mirror exporter, runs
  /// `PRAGMA wal_checkpoint(TRUNCATE)` on `blink.db` & `fts.db`, and closes all DB handles.
  Future<void> checkpointAndClose() async {
    if (!_isOpen) {
      return;
    }
    try {
      await _mirror.flushNow();
    } finally {
      await _mirror.dispose();
      _isOpen = false;
      try {
        checkpointSqliteTruncate(_ftsDb);
      } catch (_) {}
      try {
        checkpointSqliteTruncate(_mainDb);
      } catch (_) {}
      _ftsDb.close();
      _mainDb.close();
      if (!_mutationController.isClosed) {
        await _mutationController.close();
      }
    }
  }

  /// Convenience alias for [checkpointAndClose].
  Future<void> close() => checkpointAndClose();

  Database _requireMainDb() {
    if (!_isOpen) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'VaultManager is closed',
      );
    }
    return _mainDb;
  }

  Database _requireFtsDb() {
    if (!_isOpen) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'VaultManager is closed',
      );
    }
    return _ftsDb;
  }

  T _runWriteTransaction<T>(T Function(Database db) action) {
    final db = _requireMainDb();
    db.execute('BEGIN IMMEDIATE;');
    try {
      final result = action(db);
      db.execute('COMMIT;');
      return result;
    } catch (_) {
      try {
        db.execute('ROLLBACK;');
      } catch (_) {}
      rethrow;
    }
  }

  void _notifyMutation({required bool triggerMirror}) {
    _mutationEpoch += 1;
    if (!_mutationController.isClosed) {
      _mutationController.add(_mutationEpoch);
    }
    if (triggerMirror && config.enableMirrorExporter) {
      _mirror.scheduleExport();
    }
  }

  void _persistMirrorWatermarkSeq(int seqId) {
    if (!_isOpen) {
      return;
    }
    _runWriteTransaction<void>((db) {
      db.execute(
        "INSERT INTO vault_meta (key, value) VALUES ('mirror_watermark_seq', ?) "
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        <Object?>[seqId.toString()],
      );
    });
    _mutationEpoch += 1;
    if (!_mutationController.isClosed) {
      _mutationController.add(_mutationEpoch);
    }
  }

  static int _readMirrorWatermarkSeq(Database db) {
    final rows = db.select(
      "SELECT value FROM vault_meta WHERE key = 'mirror_watermark_seq' LIMIT 1",
    );
    if (rows.isEmpty) {
      return 0;
    }
    return int.tryParse(rows.first['value'] as String) ?? 0;
  }

  static Future<VaultMetadata> _loadOrCreateVaultMetadata({
    required File vaultJsonFile,
    required BlinkChannel expectedChannel,
  }) async {
    if (!await vaultJsonFile.exists()) {
      final created = VaultMetadata(
        formatVersion: currentVaultFormatVersion,
        schemaVersion: currentVaultSchemaVersion,
        vaultId: generateUuidV7(),
        channel: expectedChannel,
        createdAtUtc: DateTime.now().toUtc(),
      );
      final encoded = const JsonEncoder.withIndent('  ')
          .convert(created.toJson());
      await writeStringAtomically(vaultJsonFile, '$encoded\n');
      return created;
    }

    Map<String, Object?> json;
    try {
      final raw = await vaultJsonFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('vault.json root must be a JSON object');
      }
      json = decoded;
    } catch (error) {
      final preserved = await preserveCorruptFile(vaultJsonFile);
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message:
            'Corrupt vault.json preserved as ${p.basename(preserved.path)}',
        cause: error,
      );
    }

    final formatVersion = json['format_version'];
    final schemaVersion = json['schema_version'];
    final vaultId = json['vault_id'];
    final rawChannel = json['channel'];
    final rawCreatedAt = json['created_at_utc'];

    if (formatVersion is! int ||
        schemaVersion is! int ||
        vaultId is! String ||
        !isValidUuidV7(vaultId) ||
        rawChannel is! String ||
        rawCreatedAt is! String) {
      final preserved = await preserveCorruptFile(vaultJsonFile);
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message:
            'Malformed vault.json preserved as ${p.basename(preserved.path)}',
      );
    }

    if (formatVersion > currentVaultFormatVersion ||
        schemaVersion > currentVaultSchemaVersion) {
      throw BlinkException(
        code: BlinkErrorCode.protocolMismatch,
        message:
            'Vault requires newer BLINK version (format=$formatVersion, schema=$schemaVersion)',
      );
    }

    final channel = BlinkChannel.tryParse(rawChannel);
    if (channel == null) {
      final preserved = await preserveCorruptFile(vaultJsonFile);
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message:
            'Unknown channel in vault.json preserved as ${p.basename(preserved.path)}',
      );
    }
    if (channel != expectedChannel) {
      throw BlinkException(
        code: BlinkErrorCode.channelMismatch,
        message:
            'Vault channel "${channel.wireValue}" does not match expected channel "${expectedChannel.wireValue}"',
      );
    }

    final createdAt = DateTime.tryParse(rawCreatedAt)?.toUtc();
    if (createdAt == null) {
      final preserved = await preserveCorruptFile(vaultJsonFile);
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message:
            'Invalid timestamp in vault.json preserved as ${p.basename(preserved.path)}',
      );
    }

    return VaultMetadata(
      formatVersion: formatVersion,
      schemaVersion: schemaVersion,
      vaultId: vaultId,
      channel: channel,
      createdAtUtc: createdAt,
    );
  }

  static void _validateOrInitMainDatabase(
    Database db, {
    required VaultMetadata metadata,
    required BlinkChannel expectedChannel,
  }) {
    final metaTableExists = db
        .select(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'vault_meta'",
        )
        .isNotEmpty;

    if (metaTableExists) {
      final schemaRows = db.select(
        "SELECT value FROM vault_meta WHERE key = 'schema_version' LIMIT 1",
      );
      if (schemaRows.isNotEmpty) {
        final dbSchemaVersion = int.tryParse(
          schemaRows.first['value'] as String,
        );
        if (dbSchemaVersion != null &&
            dbSchemaVersion > currentVaultSchemaVersion) {
          throw BlinkException(
            code: BlinkErrorCode.protocolMismatch,
            message:
                'Database schema_version $dbSchemaVersion exceeds supported version $currentVaultSchemaVersion',
          );
        }
      }
      final channelRows = db.select(
        "SELECT value FROM vault_meta WHERE key = 'channel' LIMIT 1",
      );
      if (channelRows.isNotEmpty) {
        final dbChannel = channelRows.first['value'] as String;
        if (dbChannel != expectedChannel.wireValue) {
          throw BlinkException(
            code: BlinkErrorCode.channelMismatch,
            message:
                'Database channel "$dbChannel" does not match expected channel "${expectedChannel.wireValue}"',
          );
        }
      }
    }

    initializeMainDatabaseSchema(db);

    db.execute('BEGIN IMMEDIATE;');
    try {
      db.execute(
        "INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('schema_version', ?)",
        <Object?>[currentVaultSchemaVersion.toString()],
      );
      db.execute(
        "INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('vault_id', ?)",
        <Object?>[metadata.vaultId],
      );
      db.execute(
        "INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('channel', ?)",
        <Object?>[expectedChannel.wireValue],
      );
      db.execute(
        "INSERT OR IGNORE INTO vault_meta (key, value) VALUES ('mirror_watermark_seq', '0')",
      );
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  static String _resolveOrPersistDeviceId(
    Database db,
    String? configuredDeviceId,
  ) {
    if (configuredDeviceId != null && configuredDeviceId.trim().isNotEmpty) {
      db.execute(
        "INSERT INTO vault_meta (key, value) VALUES ('device_id', ?) "
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        <Object?>[configuredDeviceId.trim()],
      );
      return configuredDeviceId.trim();
    }
    final rows = db.select(
      "SELECT value FROM vault_meta WHERE key = 'device_id' LIMIT 1",
    );
    if (rows.isNotEmpty) {
      return rows.first['value'] as String;
    }
    final generated = generateUuidV7();
    db.execute(
      "INSERT INTO vault_meta (key, value) VALUES ('device_id', ?)",
      <Object?>[generated],
    );
    return generated;
  }

  static void _seedHlcFromDatabase(Database db, HlcClock clock) {
    final rows = db.select('SELECT MAX(hlc_ts) AS max_hlc FROM sync_oplog');
    final maxHlc = rows.first['max_hlc'] as String?;
    if (maxHlc != null && maxHlc.isNotEmpty) {
      clock.observe(maxHlc);
    }
  }
}
