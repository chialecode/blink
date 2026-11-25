import 'dart:io';
import 'dart:typed_data';

import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_core_ac02_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('Isolated CJK FTS5 (`index/fts.db`) & INV-09 derived rebuild', () {
    test(
      'pretokenizes CJK + Latin and safely escapes FTS5 operator queries',
      () {
        expect(
          cjkFtsPretokenize('系统思考与Flutter设计'),
          equals('系 统 思 考 与 Flutter 设 计'),
        );
        expect(
          buildSafeFtsMatchQuery('系统思考 Flutter'),
          equals('"系 统 思 考" "Flutter"'),
        );
        expect(
          buildSafeFtsMatchQuery('NOT OR "a*":^()'),
          equals('"NOT" "OR" "a"'),
        );
        expect(buildSafeFtsMatchQuery('   *** :::   '), isEmpty);
      },
    );

    test('searches single char, bigram, long CJK phrase, mixed queries, and rebuilds cleanly (INV-09)', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-fts'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: true,
          mirrorDebounce: const Duration(milliseconds: 50),
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final e1 = await vault.raw.createEntry(
        bodyMd: '深入学习系统思考与本地优先 Flutter 架构 #架构/设计',
      );
      final e2 = await vault.raw.createEntry(bodyMd: '今日私密随笔：心流状态复盘 #private');

      // Long Chinese phrase match.
      final hitsPhrase = await vault.search.search('系统思考');
      expect(hitsPhrase.map((h) => h.docId), contains(e1.id));

      // Mixed CJK + English match.
      final hitsMixed = await vault.search.search('本地优先 Flutter');
      expect(hitsMixed.map((h) => h.docId), contains(e1.id));

      // Single Chinese character match.
      final hitsSingle = await vault.search.search('构');
      expect(hitsSingle.map((h) => h.docId), contains(e1.id));

      // FTS5 operator injection safety (must NOT throw SQLite syntax error).
      final injectionHits = await vault.search.search('系统* OR "NOT" (foo:bar)');
      expect(injectionHits, isA<List<FtsSearchHit>>());

      // Privacy isolation between fts_normal and fts_private.
      expect(
        await vault.search.search('心流状态', scope: PrivacyScope.normalOnly),
        isEmpty,
      );
      expect(
        (await vault.search.search(
          '心流状态',
          scope: PrivacyScope.localWithPrivate,
        )).map((h) => h.docId),
        contains(e2.id),
      );

      // INV-09: Rebuild derived stores wipes & reconstructs FTS + links + mirror without altering raw_*.
      await vault.rebuildDerivedStores(clearAiTables: true);
      expect((await vault.raw.getEntryById(e1.id))?.bodyMd, equals(e1.bodyMd));
      expect((await vault.raw.getEntryById(e2.id))?.bodyMd, equals(e2.bodyMd));
      expect(
        (await vault.search.search('系统思考')).map((h) => h.docId),
        contains(e1.id),
      );
      expect(
        (await vault.search.search(
          '心流状态',
          scope: PrivacyScope.localWithPrivate,
        )).map((h) => h.docId),
        contains(e2.id),
      );
    });
  });

  group('BlobStore content-addressing, trash retention & owned-only GC (INV-07/12)', () {
    test('deduplicates blobs, blocks path traversal, protects trashed blobs, and GCs orphans', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-blobs'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: false,
        ),
      );
      addTearDown(vault.checkpointAndClose);

      final payload = Uint8List.fromList('synthetic-image-bytes-v1'.codeUnits);
      final b1 = await vault.blobs.putBytes(payload, mimeType: 'image/png');
      final b2 = await vault.blobs.putBytes(payload, mimeType: 'image/png');
      expect(b2.sha256, equals(b1.sha256));
      expect(
        b1.storageRelPath,
        equals(
          'blobs/${b1.sha256.substring(0, 2)}/${b1.sha256.substring(2, 4)}/${b1.sha256}',
        ),
      );
      expect(await vault.blobs.readBytes(b1.sha256), equals(payload));

      // Path traversal and malformed SHA rejected cleanly.
      await expectLater(
        () => vault.blobs.resolveFile('../vault.json'),
        throwsA(
          isA<BlinkException>().having(
            (e) => e.code,
            'code',
            BlinkErrorCode.invalidArgument,
          ),
        ),
      );

      // Also test putFile streaming import.
      final srcFile = File(p.join(tempRoot.path, 'sample.txt'));
      await srcFile.writeAsString('streamed-attachment-body');
      final bFile = await vault.blobs.putFile(srcFile, mimeType: 'text/plain');
      expect(await vault.blobs.resolveFile(bFile.sha256), isNotNull);

      // Attach b1 to an entry; leave bFile unreferenced.
      final entry = await vault.raw.createEntry(
        bodyMd: '带图笔记',
        imageBlobSha256s: <String>[b1.sha256],
      );

      // Place an unowned user file inside blobs/ to verify INV-12 owned-only GC.
      final userFile = File(p.join(vaultDir.path, 'blobs', 'user-keep.txt'));
      await userFile.writeAsString('do-not-delete');

      // Soft-delete entry -> blob b1 must STILL be protected while in 30-day trash!
      await vault.raw.softDeleteEntry(entry.id);
      expect(
        (await vault.raw.listTrash()).map((e) => e.id),
        contains(entry.id),
      );

      final gc1 = await vault.blobs.gcUnreferencedBlobs();
      expect(
        gc1,
        equals(1),
      ); // bFile collected; b1 still referenced by trashed entry.
      expect(await vault.blobs.getMetadata(bFile.sha256), isNull);
      expect(await vault.blobs.getMetadata(b1.sha256), isNotNull);
      expect(await userFile.exists(), isTrue);

      // Restore then soft-delete and permanently purge -> now b1 is collected.
      final restored = await vault.raw.restoreEntry(entry.id);
      expect(restored.isDeleted, isFalse);
      await vault.raw.softDeleteEntry(entry.id);
      final purged = await vault.raw.purgeEntryPermanently(entry.id);
      expect(purged, equals(1));
      expect(await vault.blobs.getMetadata(b1.sha256), isNull);
      expect(await userFile.exists(), isTrue);
    });
  });

  group('AC-02: Debounced MirrorExporter, private isolation & .archived/', () {
    test('exports stream, tasks, private subtree, desensitizes cross-privacy links, and archives deleted files', () async {
      final vaultDir = Directory(p.join(tempRoot.path, 'vault-mirror'));
      final vault = await VaultManager.open(
        VaultConfig(
          vaultDir: vaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          enableMirrorExporter: true,
          mirrorDebounce: const Duration(milliseconds: 60),
        ),
      );
      addTearDown(vault.checkpointAndClose);

      // Place an unowned user file inside mirror/ to prove INV-12 non-interference.
      final customUserFile = File(
        p.join(vaultDir.path, 'mirror', 'custom-user-readme.md'),
      );
      await customUserFile.parent.create(recursive: true);
      await customUserFile.writeAsString('my own file');

      final priv = await vault.raw.createEntry(
        bodyMd: '私密记录正文 #private\n- [ ] 私密待办',
      );
      final normal = await vault.raw.createEntry(
        bodyMd:
            '今日思考 ==重点== 引用 [[entry:${priv.id}|私密目标]] @t[02:15]\n'
            '- [ ] 写完核心测试\n'
            '- [>] 顺延项\n'
            ':::fold 细节\n折叠正文\n:::',
      );

      // Wait for debounced export OR flush cleanly.
      await vault.mirror.flushNow();

      final now = normal.createdAtUtc.toUtc();
      final y = now.year.toString().padLeft(4, '0');
      final m = now.month.toString().padLeft(2, '0');
      final d = now.day.toString().padLeft(2, '0');

      final normalStreamFile = File(
        p.join(
          vaultDir.path,
          'mirror',
          'markdown',
          'stream',
          y,
          m,
          '$y-$m-$d.md',
        ),
      );
      final privateStreamFile = File(
        p.join(
          vaultDir.path,
          'mirror',
          'markdown',
          'private',
          'stream',
          y,
          m,
          '$y-$m-$d.md',
        ),
      );
      final openTasksFile = File(
        p.join(vaultDir.path, 'mirror', 'markdown', 'tasks', 'open-tasks.md'),
      );

      expect(await normalStreamFile.exists(), isTrue);
      expect(await privateStreamFile.exists(), isTrue);
      expect(await openTasksFile.exists(), isTrue);

      final normalMd = await normalStreamFile.readAsString();
      expect(
        normalMd,
        contains('<a id="entry-${normal.id.substring(0, 8)}"></a>'),
      );
      expect(normalMd, contains('<mark>重点</mark>'));
      expect(normalMd, contains('[私密目标 (私密条目)]'));
      expect(normalMd, isNot(contains(priv.id)));
      expect(normalMd, isNot(contains('私密记录正文')));
      expect(normalMd, contains('`02:15`'));
      expect(normalMd, contains('- [ ] [顺延] 顺延项'));
      expect(normalMd, contains('<details><summary>细节</summary>'));

      final privateMd = await privateStreamFile.readAsString();
      expect(privateMd, contains('私密记录正文'));

      final tasksMd = await openTasksFile.readAsString();
      expect(tasksMd, contains('- [ ] 写完核心测试'));
      expect(tasksMd, isNot(contains('私密待办')));

      // Soft-delete normal entry -> normal stream file moves to mirror/.archived/, user file stays intact.
      await vault.raw.softDeleteEntry(normal.id);
      await vault.mirror.flushNow();

      expect(await normalStreamFile.exists(), isFalse);
      final archivedDir = Directory(
        p.join(vaultDir.path, 'mirror', '.archived'),
      );
      expect(await archivedDir.exists(), isTrue);
      final archivedFiles = archivedDir.listSync().whereType<File>().toList();
      expect(archivedFiles, isNotEmpty);
      expect(await customUserFile.exists(), isTrue);
      expect(await customUserFile.readAsString(), equals('my own file'));

      // Verify automatic debounced export fires without explicit flushNow().
      final autoEntry = await vault.raw.createEntry(bodyMd: '防抖自动镜像测试');
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(await normalStreamFile.exists(), isTrue);
      expect(
        await normalStreamFile.readAsString(),
        contains(autoEntry.id.substring(0, 8)),
      );

      // Direct purgeEntryPermanently (without prior softDeleteEntry) must still reconcile mirror.
      await vault.raw.purgeEntryPermanently(autoEntry.id);
      await vault.mirror.flushNow();
      expect(await normalStreamFile.exists(), isFalse);

      // Deleting a `#private` entry must archive ONLY into `mirror/private/.archived/`,
      // NEVER into public `mirror/.archived/` (`INV-03`).
      final publicArchivedBefore = archivedDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toSet();
      await vault.raw.softDeleteEntry(priv.id);
      await vault.mirror.flushNow();

      expect(await privateStreamFile.exists(), isFalse);
      final publicArchivedAfter = archivedDir
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toSet();
      expect(publicArchivedAfter, equals(publicArchivedBefore));

      final privateArchivedDir = Directory(
        p.join(vaultDir.path, 'mirror', 'private', '.archived'),
      );
      expect(await privateArchivedDir.exists(), isTrue);
      final privateArchivedFiles = privateArchivedDir
          .listSync()
          .whereType<File>()
          .toList();
      expect(privateArchivedFiles, isNotEmpty);
      expect(
        privateArchivedFiles.any(
          (f) => f.readAsStringSync().contains('私密记录正文'),
        ),
        isTrue,
      );
    });
  });
}
