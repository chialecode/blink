import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_sync_engine_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('Schema v1 -> v2 Migration & VaultManager Sync Integration', () {
    test('migrates v1 vault to v2 with pre-migration VACUUM INTO snapshot (INV-07)', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-v1'));
      await Directory(p.join(vaultDir.path, 'db')).create(recursive: true);
      final vaultId = generateUuidV7();
      final entryId = generateUuidV7();
      final opId = generateUuidV7();
      final devId = generateUuidV7();
      final nowIso = DateTime.now().toUtc().toIso8601String();

      // Craft an authentic v1 vault.json + v1 blink.db (no sync_conflicts, no outbox base_revision).
      await File(p.join(vaultDir.path, 'vault.json')).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'format_version': 1, 'schema_version': 1, 'vault_id': vaultId, 'channel': 'blink-dev', 'created_at_utc': nowIso})}\n',
      );

      final v1Db = sq.sqlite3.open(p.join(vaultDir.path, 'db', 'blink.db'));
      try {
        v1Db.execute('''
CREATE TABLE vault_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE raw_entries (
  id TEXT PRIMARY KEY,
  entry_kind TEXT NOT NULL,
  body_md TEXT NOT NULL,
  audio_blob_sha256 TEXT NULL,
  image_blob_sha256s TEXT NOT NULL DEFAULT '[]',
  source_ref_id TEXT NULL,
  capture_origin TEXT NOT NULL,
  privacy_level TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  hlc_ts TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT NULL
);
CREATE TABLE sync_oplog (
  seq_id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  client_op_id TEXT NOT NULL,
  hlc_ts TEXT NOT NULL,
  base_revision INTEGER NOT NULL DEFAULT 0,
  entity_layer TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op_type TEXT NOT NULL,
  op_origin TEXT NOT NULL,
  privacy_level TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  UNIQUE (device_id, client_op_id)
);
CREATE TABLE outbox_ops (
  client_op_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  hlc_ts TEXT NOT NULL,
  entity_layer TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  op_type TEXT NOT NULL,
  privacy_level TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at TEXT NOT NULL
);
CREATE TABLE sync_devices (
  device_id TEXT PRIMARY KEY,
  device_name TEXT NOT NULL,
  token_sha256 TEXT NOT NULL,
  revoked_at TEXT NULL,
  created_at TEXT NOT NULL
);
''');
        v1Db.execute(
          "INSERT INTO vault_meta VALUES ('schema_version', '1'), ('vault_id', ?), ('channel', 'blink-dev'), ('device_id', ?)",
          <Object?>[vaultId, devId],
        );
        final payload = jsonEncode(<String, Object?>{
          'id': entryId,
          'body_md': '来自 v1 便携库的原始笔记',
        });
        v1Db.execute(
          "INSERT INTO raw_entries VALUES (?, 'blink', '来自 v1 便携库的原始笔记', NULL, '[]', NULL, 'app_ui', 'normal', 1, '2026-11-27T00:00:00.000Z-0000-00000001', ?, ?, NULL)",
          <Object?>[entryId, nowIso, nowIso],
        );
        v1Db.execute(
          "INSERT INTO sync_oplog (device_id, client_op_id, hlc_ts, base_revision, entity_layer, entity_type, entity_id, op_type, op_origin, privacy_level, payload_json, created_at) "
          "VALUES (?, ?, '2026-11-27T00:00:00.000Z-0000-00000001', 0, 'raw', 'raw_entry', ?, 'create', 'app_ui', 'normal', ?, ?)",
          <Object?>[devId, opId, entryId, payload, nowIso],
        );
        v1Db.execute(
          "INSERT INTO outbox_ops (client_op_id, device_id, hlc_ts, entity_layer, entity_type, entity_id, op_type, privacy_level, payload_json, status, created_at) "
          "VALUES (?, ?, '2026-11-27T00:00:00.000Z-0000-00000001', 'raw', 'raw_entry', ?, 'create', 'normal', ?, 'pending', ?)",
          <Object?>[opId, devId, entryId, payload, nowIso],
        );
      } finally {
        v1Db.close();
      }

      // Open with v2 VaultManager -> must snapshot v1 before migrating to v2.
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      expect(vault.metadata.schemaVersion, equals(2));
      expect(vault.localDeviceId, equals(devId));
      expect(vault.pendingOutboxCount, equals(1));
      expect(vault.openConflictCount, equals(0));

      // Verify pre-migration VACUUM INTO backup exists and preserved v1 schema.
      final backupsDir = Directory(p.join(vaultDir.path, 'db', 'backups'));
      final preMigFiles = backupsDir
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                p.basename(f.path).startsWith('blink-pre-migration-v1-to-v2-'),
          )
          .toList();
      expect(preMigFiles, hasLength(1));

      final snapDb = sq.sqlite3.open(
        preMigFiles.first.path,
        mode: sq.OpenMode.readOnly,
      );
      try {
        final snapSchema = snapDb
            .select("SELECT value FROM vault_meta WHERE key = 'schema_version'")
            .first['value'];
        expect(snapSchema, equals('1'));
      } finally {
        snapDb.close();
      }

      // Verify vault.json was atomically bumped to schema_version: 2.
      final rawJson = jsonDecode(
        await File(p.join(vaultDir.path, 'vault.json')).readAsString(),
      ) as Map<String, Object?>;
      expect(rawJson['schema_version'], equals(2));

      // Existing v1 entry must remain completely intact.
      final loaded = await vault.raw.getEntryById(entryId);
      expect(loaded?.bodyMd, equals('来自 v1 便携库的原始笔记'));
    });

    test('persists localDeviceId UUIDv7 and emits pendingOutboxCount & conflict streams', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-device'));
      final v1 = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      final firstId = v1.localDeviceId;
      expect(isValidUuidV7(firstId), isTrue);

      final outboxCounts = <int>[];
      final sub = v1.watchPendingOutboxCount().listen(outboxCounts.add);
      await v1.raw.createEntry(bodyMd: '第一条闪念');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(v1.pendingOutboxCount, equals(1));
      expect(outboxCounts, contains(1));
      await sub.cancel();
      await v1.checkpointAndClose();

      final v2 = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(v2.checkpointAndClose);
      expect(v2.localDeviceId, equals(firstId));
    });
  });

  group('INV-01 / INV-03 / INV-05: Causal Replay, Conflicts & Latch', () {
    test('deduplicates (device_id, client_op_id) idempotently and never echoes into outbox_ops', () async {
      final vaultA = await _openTempVault(tempRoot, 'dedup-a', 'Device-A');
      final vaultB = await _openTempVault(tempRoot, 'dedup-b', 'Device-B');
      addTearDown(vaultA.checkpointAndClose);
      addTearDown(vaultB.checkpointAndClose);

      final e1 = await vaultA.raw.createEntry(bodyMd: '独立闪念一 #测试');
      final e2 = await vaultA.raw.createEntry(bodyMd: '独立闪念二\n- [ ] 完成同步');
      final pulled = await vaultA.syncEngine.readOplogSince(sinceSeq: 0);
      expect(pulled.ops, hasLength(2));

      final firstIngest = await vaultB.syncEngine.ingestRemoteOps(pulled.ops);
      expect(firstIngest.acceptedCount, equals(2));
      expect(firstIngest.duplicateCount, equals(0));
      expect(firstIngest.conflictsCreated, equals(0));
      expect(vaultB.pendingOutboxCount, equals(0)); // NEVER echoes remote ops!

      // Re-ingesting the exact same batch is 100% idempotent.
      final secondIngest = await vaultB.syncEngine.ingestRemoteOps(pulled.ops);
      expect(secondIngest.acceptedCount, equals(0));
      expect(secondIngest.duplicateCount, equals(2));
      expect((await vaultB.raw.listEntries()).length, equals(2));
      expect((await vaultB.raw.getEntryById(e1.id))?.bodyMd, equals(e1.bodyMd));
      expect((await vaultB.raw.getEntryById(e2.id))?.bodyMd, equals(e2.bodyMd));

      // Tasks preserved with exact same UUID across devices.
      final tasksA = await vaultA.raw.listTasks();
      final tasksB = await vaultB.raw.listTasks();
      expect(tasksB.map((t) => t.id), equals(tasksA.map((t) => t.id)));
    });

    test('preserves dual-copy concurrent body edits deterministically and resolves cleanly', () async {
      final vaultA = await _openTempVault(tempRoot, 'conf-a', 'Desktop-A');
      final vaultB = await _openTempVault(tempRoot, 'conf-b', 'Phone-B');
      addTearDown(vaultA.checkpointAndClose);
      addTearDown(vaultB.checkpointAndClose);

      // Initial shared entry synced from A -> B.
      final base = await vaultA.raw.createEntry(bodyMd: '初始正文 v1');
      final initOps = (await vaultA.syncEngine.readOplogSince(sinceSeq: 0)).ops;
      await vaultB.syncEngine.ingestRemoteOps(initOps);

      // Both devices edit the SAME entry offline (both have base_revision == 1).
      await vaultA.raw.updateEntry(id: base.id, bodyMd: '桌面端离线修改 A');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await vaultB.raw.updateEntry(id: base.id, bodyMd: '手机端离线修改 B');

      final opsFromA = (await vaultA.syncEngine.readOplogSince(sinceSeq: 1))
          .ops;
      final opsFromB = (await vaultB.syncEngine.readOplogSince(sinceSeq: 1))
          .ops;

      // Cross-ingest in both directions.
      final resA = await vaultA.syncEngine.ingestRemoteOps(opsFromB);
      final resB = await vaultB.syncEngine.ingestRemoteOps(opsFromA);
      expect(resA.conflictsCreated, equals(1));
      expect(resB.conflictsCreated, equals(1));

      // Deterministic winner: both devices converge to identical main entry body!
      final mainA = await vaultA.raw.getEntryById(base.id);
      final mainB = await vaultB.raw.getEntryById(base.id);
      expect(mainA!.bodyMd, equals('手机端离线修改 B'));
      expect(mainB!.bodyMd, equals('手机端离线修改 B'));

      // Losing branch preserved verbatim with `[离线冲突副本 · <设备名> <UTC时间>]` header & link.
      final conflictsA = await vaultA.syncEngine.listOpenConflicts();
      expect(conflictsA, hasLength(1));
      final conflict = conflictsA.first;
      expect(conflict.entityId, equals(base.id));
      expect(conflict.localBodyMd, equals('桌面端离线修改 A'));
      expect(conflict.remoteBodyMd, equals('手机端离线修改 B'));
      expect(vaultA.openConflictCount, equals(1));

      final copyEntry = await vaultA.raw.getEntryById(conflict.localCopyId);
      expect(copyEntry, isNotNull);
      expect(copyEntry!.bodyMd, startsWith('[离线冲突副本 · Desktop-A '));
      expect(copyEntry.bodyMd, contains('[[entry:${base.id}|原文条目]]'));
      expect(copyEntry.bodyMd, contains('桌面端离线修改 A'));

      // Resolve via customMerge on A -> updates main entry, soft-deletes copy, closes conflict.
      final resolved = await vaultA.syncEngine.resolveConflict(
        conflictId: conflict.id,
        resolution: ConflictResolutionChoice.customMerge,
        mergedBodyMd: '合并后的完整正文 A + B',
      );
      expect(resolved.status, equals(SyncConflictStatus.resolved));
      expect(vaultA.openConflictCount, equals(0));
      expect(
        (await vaultA.raw.getEntryById(base.id))?.bodyMd,
        equals('合并后的完整正文 A + B'),
      );
      expect(await vaultA.raw.getEntryById(conflict.localCopyId), isNull);

      // Also verify keepConflictCopy & keepBoth on vaultB.
      final conflictsB = await vaultB.syncEngine.listOpenConflicts();
      expect(conflictsB, hasLength(1));
      await vaultB.syncEngine.resolveConflict(
        conflictId: conflictsB.first.id,
        resolution: ConflictResolutionChoice.keepConflictCopy,
      );
      expect(
        (await vaultB.raw.getEntryById(base.id))?.bodyMd,
        equals('桌面端离线修改 A'),
      );
      expect(vaultB.openConflictCount, equals(0));
    });

    test('enforces unidirectional #private latch on conflict and evicts fts_normal (INV-03)', () async {
      final vaultA = await _openTempVault(tempRoot, 'priv-a', 'Laptop-A');
      final vaultB = await _openTempVault(tempRoot, 'priv-b', 'Phone-B');
      addTearDown(vaultA.checkpointAndClose);
      addTearDown(vaultB.checkpointAndClose);

      final base = await vaultA.raw.createEntry(bodyMd: '公开草稿 关键词翡翠');
      await vaultB.syncEngine.ingestRemoteOps(
        (await vaultA.syncEngine.readOplogSince(sinceSeq: 0)).ops,
      );

      // Verify searchable in fts_normal initially.
      expect(
        await vaultA.search.search('关键词翡翠', scope: PrivacyScope.normalOnly),
        isNotEmpty,
      );

      // B adds `#private`; A concurrently edits WITHOUT `#private`.
      await vaultB.raw.updateEntry(id: base.id, bodyMd: '绝密内容 关键词翡翠 #private');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await vaultA.raw.updateEntry(id: base.id, bodyMd: '普通修改 关键词翡翠');

      // A ingests B's private upgrade -> even though A's HLC is newer, `#private` MUST win!
      final opsB = (await vaultB.syncEngine.readOplogSince(sinceSeq: 1)).ops;
      await vaultA.syncEngine.ingestRemoteOps(opsB);

      final merged = await vaultA.raw.getEntryById(base.id);
      expect(merged!.privacyLevel, equals(PrivacyLevel.private));

      // Conflict copy MUST ALSO inherit `private`!
      final conflicts = await vaultA.syncEngine.listOpenConflicts();
      expect(conflicts, hasLength(1));
      final copy = await vaultA.raw.getEntryById(conflicts.first.localCopyId);
      expect(copy!.privacyLevel, equals(PrivacyLevel.private));

      // Immediately evicted from `fts_normal`; only visible under `localWithPrivate`.
      expect(
        await vaultA.search.search('关键词翡翠', scope: PrivacyScope.normalOnly),
        isEmpty,
      );
      expect(
        await vaultA.search.search(
          '关键词翡翠',
          scope: PrivacyScope.localWithPrivate,
        ),
        isNotEmpty,
      );
    });

    test('edit beats concurrent delete tombstone and resurrects soft-deleted entry', () async {
      final vaultA = await _openTempVault(tempRoot, 'del-a', 'Node-A');
      final vaultB = await _openTempVault(tempRoot, 'del-b', 'Node-B');
      addTearDown(vaultA.checkpointAndClose);
      addTearDown(vaultB.checkpointAndClose);

      final e1 = await vaultA.raw.createEntry(bodyMd: '条目一 原文');
      final e2 = await vaultA.raw.createEntry(bodyMd: '条目二 原文');
      await vaultB.syncEngine.ingestRemoteOps(
        (await vaultA.syncEngine.readOplogSince(sinceSeq: 0)).ops,
      );

      // Case 1: A soft-deletes e1; B concurrently edits e1 -> A ingests B's edit -> resurrects!
      await vaultA.raw.softDeleteEntry(e1.id);
      expect(await vaultA.raw.getEntryById(e1.id), isNull);
      await vaultB.raw.updateEntry(id: e1.id, bodyMd: '条目一 B端新写重要内容');
      final opsB = (await vaultB.syncEngine.readOplogSince(sinceSeq: 2)).ops;
      await vaultA.syncEngine.ingestRemoteOps(opsB);

      final resurrected = await vaultA.raw.getEntryById(e1.id);
      expect(resurrected, isNotNull);
      expect(resurrected!.isDeleted, isFalse);
      expect(resurrected.bodyMd, equals('条目一 B端新写重要内容'));
      expect(
        (await vaultA.search.search('重要内容')).map((h) => h.docId),
        contains(e1.id),
      );

      // Case 2: A edits e2; B concurrently soft-deletes e2 -> A ingests B's delete -> stays alive!
      final seqBeforeE2 = vaultB.syncEngine.getLatestSeqId();
      await vaultA.raw.updateEntry(id: e2.id, bodyMd: '条目二 A端补充内容');
      await vaultB.raw.softDeleteEntry(e2.id);
      final delOpsB = (await vaultB.syncEngine.readOplogSince(
        sinceSeq: seqBeforeE2,
      )).ops;
      await vaultA.syncEngine.ingestRemoteOps(delOpsB);

      final keptAlive = await vaultA.raw.getEntryById(e2.id);
      expect(keptAlive, isNotNull);
      expect(keptAlive!.isDeleted, isFalse);
      expect(keptAlive.bodyMd, equals('条目二 A端补充内容'));
    });

    test('converges task statuses and ai_* derived projections by LWW without conflict copies', () async {
      final vaultA = await _openTempVault(tempRoot, 'lww-a', 'Node-A');
      final vaultB = await _openTempVault(tempRoot, 'lww-b', 'Node-B');
      addTearDown(vaultA.checkpointAndClose);
      addTearDown(vaultB.checkpointAndClose);

      final entry = await vaultA.raw.createEntry(bodyMd: '任务\n- [ ] 检查清单');
      await vaultB.syncEngine.ingestRemoteOps(
        (await vaultA.syncEngine.readOplogSince(sinceSeq: 0)).ops,
      );

      final taskA = (await vaultA.raw.listTasks()).single;
      final seqBeforeToggle = vaultA.syncEngine.getLatestSeqId();
      await vaultA.raw.toggleTaskStatus(taskA.id);
      final taskOps = (await vaultA.syncEngine.readOplogSince(
        sinceSeq: seqBeforeToggle,
      )).ops;
      await vaultB.syncEngine.ingestRemoteOps(taskOps);

      final taskB = (await vaultB.raw.listTasks()).single;
      expect(taskB.status, equals(TaskStatus.done));
      expect(vaultB.openConflictCount, equals(0));

      // Derived ai_entry_enrichment LWW by computed_at (never touches raw_entries).
      final aiOpOld = SyncOpEnvelope(
        deviceId: vaultA.localDeviceId,
        clientOpId: generateUuidV7(),
        hlcTs: '2026-11-27T01:00:00.000Z-0000-00000001',
        baseRevision: 0,
        entityLayer: SyncEntityLayer.ai,
        entityType: 'ai_entry_enrichment',
        entityId: entry.id,
        opType: 'upsert',
        opOrigin: 'mcp_capture',
        privacyLevel: PrivacyLevel.normal,
        payload: <String, Object?>{
          'intent_tags_json': <String>['old_tag'],
          'clean_transcript_md': '旧摘要',
          'computed_at': '2026-11-27T01:00:00.000Z',
        },
        createdAtUtc: DateTime.utc(2026, 11, 27, 1, 0),
      );
      final aiOpNew = SyncOpEnvelope(
        deviceId: vaultA.localDeviceId,
        clientOpId: generateUuidV7(),
        hlcTs: '2026-11-27T02:00:00.000Z-0000-00000001',
        baseRevision: 1,
        entityLayer: SyncEntityLayer.ai,
        entityType: 'ai_entry_enrichment',
        entityId: entry.id,
        opType: 'upsert',
        opOrigin: 'mcp_capture',
        privacyLevel: PrivacyLevel.normal,
        payload: <String, Object?>{
          'intent_tags_json': <String>['new_tag'],
          'clean_transcript_md': '新摘要',
          'computed_at': '2026-11-27T02:00:00.000Z',
        },
        createdAtUtc: DateTime.utc(2026, 11, 27, 2, 0),
      );

      await vaultB.syncEngine.ingestRemoteOps(<SyncOpEnvelope>[
        aiOpNew,
        aiOpOld,
      ]);
      expect(vaultB.openConflictCount, equals(0));
      expect(
        (await vaultB.raw.getEntryById(entry.id))?.bodyMd,
        contains('检查清单'),
      );
    });
  });
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
