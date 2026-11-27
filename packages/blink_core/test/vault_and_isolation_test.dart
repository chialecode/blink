import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sq;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_core_vault_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('AC-03 & INV-06/07/08: Portable Vault, Channel Lock & Hot Backup', () {
    test('enforces blink vs blink-dev channelMismatch lock', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-dev'));
      final devVault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      expect(devVault.metadata.channel, equals(BlinkChannel.blinkDev));
      expect(isValidUuidV7(devVault.metadata.vaultId), isTrue);
      await devVault.checkpointAndClose();

      await expectLater(
        () => VaultManager.open(
          VaultConfig(
            vaultDir: vaultDir,
            expectedChannel: BlinkChannel.blink,
            enableMirrorExporter: false,
          ),
        ),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.channelMismatch,
          ),
        ),
      );
    });

    test(
      'rejects future schema_version and preserves corrupt vault.json',
      () async {
        final futureDir = Directory(p.join(tempRoot.path, 'vault-future'));
        await futureDir.create(recursive: true);
        final futureJson = File(p.join(futureDir.path, 'vault.json'));
        await futureJson.writeAsString(
          jsonEncode(<String, Object?>{
            'format_version': 99,
            'schema_version': 99,
            'vault_id': generateUuidV7(),
            'channel': 'blink-dev',
            'created_at_utc': DateTime.now().toUtc().toIso8601String(),
          }),
        );

        await expectLater(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: futureDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
          throwsA(
            isA<BlinkException>().having(
              (e) => e.code,
              'code',
              BlinkErrorCode.protocolMismatch,
            ),
          ),
        );
        // Future vault.json must NOT be renamed as corrupt.
        expect(await futureJson.exists(), isTrue);

        final corruptDir = Directory(p.join(tempRoot.path, 'vault-corrupt'));
        await corruptDir.create(recursive: true);
        final corruptJson = File(p.join(corruptDir.path, 'vault.json'));
        await corruptJson.writeAsString('{broken json');

        await expectLater(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: corruptDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
          throwsA(
            isA<BlinkException>().having(
              (e) => e.code,
              'code',
              BlinkErrorCode.ioError,
            ),
          ),
        );
        final preservedFiles = corruptDir
            .listSync()
            .whereType<File>()
            .where((f) => p.basename(f.path).startsWith('vault.json.corrupt-'))
            .toList();
        expect(preservedFiles, hasLength(1));
        expect(
          await preservedFiles.first.readAsString(),
          equals('{broken json'),
        );
      },
    );

    test('VACUUM INTO hot backup, cold folder copy, WAL pragmas, and zero secrets (INV-07/08)', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-portable'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: true,
          mirrorDebounce: const Duration(milliseconds: 50),
        ),
      );

      final entry = await vault.raw.createEntry(
        bodyMd: '便携库测试 #便携/迁移\n- [ ] 核验热备份',
      );

      // Verify WAL pragmas on live database.
      final probeDb = sq.sqlite3.open(
        p.join(vaultDir.path, 'db', 'blink.db'),
        mode: sq.OpenMode.readOnly,
      );
      try {
        final mode = probeDb.select('PRAGMA journal_mode;').first.values.first;
        expect(mode.toString().toLowerCase(), equals('wal'));
      } finally {
        probeDb.close();
      }

      // Hot backup via VACUUM INTO must complete quickly and produce a valid snapshot.
      final sw = Stopwatch()..start();
      final backup = await vault.createHotBackup();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(await backup.backupFile.exists(), isTrue);
      expect(backup.byteSize, greaterThan(0));
      expect(isValidBlobSha256(backup.sha256), isTrue);

      final snapDb = sq.sqlite3.open(
        backup.backupFile.path,
        mode: sq.OpenMode.readOnly,
      );
      try {
        final count =
            snapDb.select(
                  'SELECT COUNT(*) AS c FROM raw_entries WHERE id = ?',
                  [entry.id],
                ).first['c']
                as int;
        expect(count, equals(1));
      } finally {
        snapDb.close();
      }

      await vault.checkpointAndClose();

      // Zero .blink-tmp files and zero secrets inside <BLINK_VAULT_DIR> (`INV-07`/`INV-08`).
      final allFiles = vaultDir
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      for (final file in allFiles) {
        final name = p.basename(file.path);
        expect(name.endsWith('.blink-tmp'), isFalse);
        expect(name, isNot(equals('ipc.json')));
        if (name.endsWith('.json') || name.endsWith('.md')) {
          final content = await file.readAsString();
          expect(content, isNot(contains('api_key')));
          expect(content, isNot(contains('Bearer ')));
        }
      }

      // Cold-copy entire folder to a brand-new location and reopen cleanly.
      final copiedDir = Directory(p.join(tempRoot.path, 'vault-copied'));
      await _copyDirectory(vaultDir, copiedDir);

      final reopened = await VaultManager.open(
        VaultConfig(
          vaultDir: copiedDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      try {
        final loaded = await reopened.raw.getEntryById(entry.id);
        expect(loaded, isNotNull);
        expect(loaded!.bodyMd, equals(entry.bodyMd));
        final hits = await reopened.search.search('便携库测试');
        expect(hits.map((h) => h.docId), contains(entry.id));
      } finally {
        await reopened.checkpointAndClose();
      }
    });
  });

  group('INV-01 / INV-03 / INV-04 / INV-05: RawRepository & ExternalAiRepository', () {
    test('enforces #private unidirectional latch, bidirectional tasks, drafts, and streams', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-repo'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final observedCounts = <int>[];
      final sub = vault.raw.watchEntries().listen((entries) {
        observedCounts.add(entries.length);
      });
      addTearDown(sub.cancel);

      final normalEntry = await vault.raw.createEntry(
        bodyMd: '晨间思考 #思考/方法论\n- [ ] 整理文献卡片',
      );
      expect(normalEntry.privacyLevel, equals(PrivacyLevel.normal));
      expect(normalEntry.revision, equals(1));

      // Verify reactive stream pushed update.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(observedCounts, contains(1));

      // Verify endogenous task creation & bidirectional toggle back to raw_entries.body_md.
      final tasks = await vault.raw.listTasks();
      expect(tasks, hasLength(1));
      expect(tasks.first.status, equals(TaskStatus.open));
      expect(tasks.first.originEntryId, equals(normalEntry.id));

      final toggledTask = await vault.raw.toggleTaskStatus(tasks.first.id);
      expect(toggledTask.status, equals(TaskStatus.done));
      final entryAfterToggle = await vault.raw.getEntryById(normalEntry.id);
      expect(entryAfterToggle!.bodyMd, contains('- [x] 整理文献卡片'));

      // Promote entry to #private via token in body_md -> immediately evicted from fts_normal.
      final promoted = await vault.raw.updateEntry(
        id: normalEntry.id,
        bodyMd: '私密升级词条 #private\n- [x] 整理文献卡片',
      );
      expect(promoted.privacyLevel, equals(PrivacyLevel.private));

      final normalSearchAfterPromote = await vault.search.search(
        '私密升级词条',
        scope: PrivacyScope.normalOnly,
      );
      expect(normalSearchAfterPromote, isEmpty);

      final localSearchAfterPromote = await vault.search.search(
        '私密升级词条',
        scope: PrivacyScope.localWithPrivate,
      );
      expect(
        localSearchAfterPromote.map((h) => h.docId),
        contains(promoted.id),
      );

      // Unidirectional latch: removing `#private` without explicit `allowPrivacyDowngrade` keeps it private!
      final stillPrivate = await vault.raw.updateEntry(
        id: promoted.id,
        bodyMd: '去掉标签但仍锁存私密',
        privacyLocked: false,
      );
      expect(stillPrivate.privacyLevel, equals(PrivacyLevel.private));
      expect(
        await vault.search.search('去掉标签但仍锁存私密', scope: PrivacyScope.normalOnly),
        isEmpty,
      );

      // Defensive boundary: even with allowPrivacyDowngrade=true, an active `#private` token keeps it private.
      final guardedByToken = await vault.raw.updateEntry(
        id: promoted.id,
        bodyMd: '仍含标签 #private\n- [x] 整理文献卡片',
        privacyLocked: false,
        allowPrivacyDowngrade: true,
      );
      expect(guardedByToken.privacyLevel, equals(PrivacyLevel.private));

      // Explicit user cancellation: strip `#private` + `privacyLocked: false` + `allowPrivacyDowngrade: true`
      // migrates entry & tasks cleanly from `fts_private` back to `fts_normal` (`DEC-034`).
      final strippedBody = vault.bfm.stripPrivateTokens(guardedByToken.bodyMd);
      expect(strippedBody, equals('仍含标签\n- [x] 整理文献卡片'));
      final downgraded = await vault.raw.updateEntry(
        id: promoted.id,
        bodyMd: strippedBody,
        privacyLocked: false,
        allowPrivacyDowngrade: true,
      );
      expect(downgraded.privacyLevel, equals(PrivacyLevel.normal));
      expect(downgraded.isPrivate, isFalse);

      final normalHitsAfterDowngrade = await vault.search.search(
        '仍含标签',
        scope: PrivacyScope.normalOnly,
      );
      expect(
        normalHitsAfterDowngrade.map((h) => h.docId),
        contains(promoted.id),
      );
      final localHitsAfterDowngrade = await vault.search.search(
        '仍含标签',
        scope: PrivacyScope.localWithPrivate,
      );
      expect(
        localHitsAfterDowngrade
            .where((h) => h.docId == promoted.id)
            .single
            .privacyLevel,
        equals(PrivacyLevel.normal),
      );
      final tasksAfterDowngrade = await vault.raw.listTasks();
      expect(tasksAfterDowngrade, hasLength(1));
      expect(
        tasksAfterDowngrade.first.privacyLevel,
        equals(PrivacyLevel.normal),
      );
      final normalTaskHits = await vault.search.search(
        '整理文献卡片',
        scope: PrivacyScope.normalOnly,
        docKinds: const <String>['task'],
      );
      expect(
        normalTaskHits.map((h) => h.docId),
        contains(tasksAfterDowngrade.first.id),
      );
      expect(await vault.externalAi.getEntry(promoted.id), isNotNull);

      // Crash-recovery draft survives save/load/clear without entering sync_oplog.
      final statsBeforeDraft = await vault.getStats();
      final draft = EditorDraft(
        draftKey: 'inbox',
        bodyMd: '未发送的草稿内容',
        entryKind: EntryKind.blink,
        privacyLocked: false,
        updatedAtUtc: DateTime.now().toUtc(),
      );
      await vault.raw.saveDraft(draft);
      final loadedDraft = await vault.raw.loadDraft('inbox');
      expect(loadedDraft?.bodyMd, equals('未发送的草稿内容'));
      final statsAfterDraft = await vault.getStats();
      expect(statsAfterDraft.latestSeqId, equals(statsBeforeDraft.latestSeqId));

      await vault.raw.clearDraft('inbox');
      expect(await vault.raw.loadDraft('inbox'), isNull);
    });

    test('ExternalAiRepository blocks private records, redacts cross-privacy links, and validates HTML refs', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-ext-ai'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final privEntry = await vault.raw.createEntry(
        bodyMd: '绝密个人日记 #private 机密暗语甲骨文',
      );
      final normalEntry = await vault.raw.createEntry(
        bodyMd: '公开读书笔记 引用 [[entry:${privEntry.id}|绝密标题]] 公开关键词',
      );

      final aiNormal = vault.externalAi;
      expect(aiNormal.scope, equals(PrivacyScope.normalOnly));

      // Private ID returns null and opaque `notFound` (identical to non-existent UUID).
      expect(await aiNormal.getEntry(privEntry.id), isNull);
      await expectLater(
        () => aiNormal.requireEntry(privEntry.id),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.notFound,
          ),
        ),
      );
      await expectLater(
        () => aiNormal.requireEntry(generateUuidV7()),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.notFound,
          ),
        ),
      );

      // Normal entry has cross-privacy reference redacted (`INV-03`).
      final fetchedNormal = await aiNormal.getEntry(normalEntry.id);
      expect(fetchedNormal, isNotNull);
      expect(fetchedNormal!.bodyMd, contains('[private-ref]'));
      expect(fetchedNormal.bodyMd, isNot(contains(privEntry.id)));
      expect(fetchedNormal.bodyMd, isNot(contains('绝密标题')));

      // Search in normalOnly never leaks private entries.
      expect(await aiNormal.search('机密暗语甲骨文'), isEmpty);
      expect(
        (await aiNormal.search('公开关键词')).map((h) => h.docId),
        contains(normalEntry.id),
      );

      // Live BlinkRefValidator integration with packages/blink_sanitizer.
      final validHtml =
          '<p>综述引用 <blink-ref kind="entry" id="${normalEntry.id}">公开笔记</blink-ref></p>';
      final validRes = aiNormal.sanitizeAndValidateHtml(
        validHtml,
        profile: SanitizeProfile.surface2Sandbox,
      );
      expect(validRes.isValid, isTrue);
      expect(
        validRes.html,
        contains('href="blink-ref://entry/${normalEntry.id}"'),
      );

      // Private target in normalOnly triggers E_PRIVACY_SCOPE_VIOLATION and redacts to [private-ref].
      final leakHtml =
          '<p>越界引用 <blink-ref kind="entry" id="${privEntry.id}">泄漏标题</blink-ref></p>';
      final leakRes = aiNormal.sanitizeAndValidateHtml(
        leakHtml,
        profile: SanitizeProfile.surface1Native,
      );
      expect(leakRes.isValid, isFalse);
      expect(
        leakRes.errors.map((e) => e.code),
        contains(DiagnosticCode.privacyScopeViolation),
      );
      expect(leakRes.html, contains('[private-ref]'));
      expect(leakRes.html, isNot(contains('泄漏标题')));

      // Non-existent target triggers E_BROKEN_BLINK_REF.
      final brokenId = generateUuidV7();
      final brokenRes = aiNormal.sanitizeAndValidateHtml(
        '<p><blink-ref kind="entry" id="$brokenId">不存在</blink-ref></p>',
        profile: SanitizeProfile.surface1Native,
      );
      expect(brokenRes.isValid, isFalse);
      expect(
        brokenRes.errors.map((e) => e.code),
        contains(DiagnosticCode.brokenBlinkRef),
      );

      // localWithPrivate scope can read private entries and validate private refs.
      final aiPrivate = vault.externalAiWithScope(
        PrivacyScope.localWithPrivate,
      );
      expect(
        (await aiPrivate.getEntry(privEntry.id))?.id,
        equals(privEntry.id),
      );
      final privRes = aiPrivate.sanitizeAndValidateHtml(
        leakHtml,
        profile: SanitizeProfile.surface1Native,
      );
      expect(privRes.isValid, isTrue);

      // Incremental listEntries(sinceSeq:) and derived-only upsertBfmLinks.
      final incNormal = await aiNormal.listEntries(sinceSeq: 0);
      expect(incNormal.map((e) => e.id), equals(<String>[normalEntry.id]));

      await expectLater(
        () => aiNormal.upsertBfmLinks('entry', privEntry.id, <BfmLinkRecord>[
          BfmLinkRecord(
            id: generateUuidV7(),
            srcType: 'entry',
            srcId: privEntry.id,
            targetKind: BfmLinkTargetKind.entry,
            targetId: normalEntry.id,
            privacyLevel: PrivacyLevel.normal,
          ),
        ]),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.notFound,
          ),
        ),
      );

      final derivedLink = BfmLinkRecord(
        id: generateUuidV7(),
        srcType: 'entry',
        srcId: normalEntry.id,
        targetKind: BfmLinkTargetKind.titleQuery,
        privacyLevel: PrivacyLevel.normal,
      );
      await aiNormal.upsertBfmLinks('entry', normalEntry.id, <BfmLinkRecord>[
        derivedLink,
      ]);
      expect(
        await aiNormal.isReferenceAccessible(
          kind: BfmLinkTargetKind.entry,
          id: normalEntry.id,
        ),
        isTrue,
      );
      expect(
        await aiNormal.isReferenceAccessible(
          kind: BfmLinkTargetKind.entry,
          id: privEntry.id,
        ),
        isFalse,
      );
    });

    test('filters entries by hierarchical tag, kind, backlinks, and purges expired trash', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-queries'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final target = await vault.raw.createEntry(
        bodyMd: '目标卡片 #知识/系统',
        entryKind: EntryKind.diary,
      );
      final linker = await vault.raw.createEntry(
        bodyMd: '关联 [[entry:${target.id}|目标卡片]] #知识/方法',
        entryKind: EntryKind.blink,
      );

      final byParentTag = await vault.raw.listEntries(
        const EntryQuery(tag: '#知识'),
      );
      expect(byParentTag.length, equals(2));

      final byChildTag = await vault.raw.listEntries(
        const EntryQuery(tag: '知识/系统'),
      );
      expect(byChildTag.map((e) => e.id), equals(<String>[target.id]));

      final tagCounts = await vault.raw.listTagCounts();
      expect(tagCounts['知识/系统'], equals(1));
      expect(tagCounts['知识/方法'], equals(1));

      final backlinks = await vault.raw.getBacklinks(target.id);
      expect(backlinks.map((b) => b.srcId), contains(linker.id));

      // Soft-delete linker -> backlinks exclude soft-deleted sources.
      await vault.raw.softDeleteEntry(linker.id);
      expect(await vault.raw.getBacklinks(target.id), isEmpty);

      // Verify retention vs zero-retention purgeExpiredTrash.
      expect(
        await vault.raw.purgeExpiredTrash(retention: const Duration(days: 30)),
        equals(0),
      );
      expect(
        await vault.raw.purgeExpiredTrash(retention: Duration.zero),
        equals(1),
      );
      expect(
        await vault.raw.getEntryById(linker.id, includeDeleted: true),
        isNull,
      );
    });

    test('restoreEntry does not resurrect endogenous tasks removed before soft-delete', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-restore-task'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final entry = await vault.raw.createEntry(
        bodyMd: '任务测试\n- [ ] 保留任务A\n- [ ] 已移除任务B',
      );
      expect((await vault.raw.listTasks()).length, equals(2));

      await vault.raw.updateEntry(id: entry.id, bodyMd: '任务测试\n- [ ] 保留任务A');
      final activeBeforeDelete = await vault.raw.listTasks();
      expect(activeBeforeDelete.map((t) => t.title), equals(<String>['保留任务A']));

      await vault.raw.softDeleteEntry(entry.id);
      expect(await vault.raw.listTasks(), isEmpty);

      await vault.raw.restoreEntry(entry.id);
      final restoredTasks = await vault.raw.listTasks();
      expect(restoredTasks.map((t) => t.title), equals(<String>['保留任务A']));
    });

    test('emptyTrash purges trashed entries by kind or all and collects orphan blobs', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-empty-trash'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final memoBlob = await vault.blobs.putBytes(
        utf8.encode('memo-blob-bytes'),
        mimeType: 'text/plain',
      );
      final noteBlob = await vault.blobs.putBytes(
        utf8.encode('note-blob-bytes'),
        mimeType: 'text/plain',
      );
      final activeMemo = await vault.raw.createEntry(
        bodyMd: '保留的活跃小记',
        entryKind: EntryKind.blink,
      );
      final trashedMemo = await vault.raw.createEntry(
        bodyMd: '待清空的回收站小记',
        entryKind: EntryKind.blink,
        imageBlobSha256s: <String>[memoBlob.sha256],
      );
      final trashedNote = await vault.raw.createEntry(
        bodyMd: '# 待清空的回收站笔记',
        entryKind: EntryKind.diary,
        imageBlobSha256s: <String>[noteBlob.sha256],
      );

      await vault.raw.softDeleteEntry(trashedMemo.id);
      await vault.raw.softDeleteEntry(trashedNote.id);

      // Emptying only memo kinds purges trashedMemo + its blob, keeping trashedNote & activeMemo intact.
      final purgedMemos = await vault.raw.emptyTrash(
        kinds: const <EntryKind>[
          EntryKind.blink,
          EntryKind.voiceNote,
          EntryKind.photoNote,
        ],
      );
      expect(purgedMemos, equals(1));
      expect(
        await vault.raw.getEntryById(trashedMemo.id, includeDeleted: true),
        isNull,
      );
      expect(await vault.blobs.readBytes(memoBlob.sha256), isNull);
      expect(
        await vault.raw.getEntryById(trashedNote.id, includeDeleted: true),
        isNotNull,
      );
      expect(await vault.blobs.readBytes(noteBlob.sha256), isNotNull);
      expect(await vault.raw.getEntryById(activeMemo.id), isNotNull);

      // Emptying remaining trash purges trashedNote + its blob while keeping activeMemo untouched.
      final purgedRest = await vault.raw.emptyTrash();
      expect(purgedRest, equals(1));
      expect(
        await vault.raw.getEntryById(trashedNote.id, includeDeleted: true),
        isNull,
      );
      expect(await vault.blobs.readBytes(noteBlob.sha256), isNull);
      expect(await vault.raw.getEntryById(activeMemo.id), isNotNull);
    });
  });
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: false)) {
    final targetPath = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      await entity.copy(targetPath);
    }
  }
}
