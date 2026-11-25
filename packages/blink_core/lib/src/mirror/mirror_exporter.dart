import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../bfm/bfm_engine.dart';
import '../models/blink_models.dart';
import '../repositories/raw_repository.dart';
import '../utils/atomic_io.dart';

/// Current status snapshot of [MirrorExporter].
@immutable
final class MirrorStatus {
  const MirrorStatus({
    required this.isRunning,
    required this.lastExportedSeq,
    this.lastExportedAtUtc,
    this.lastError,
  });

  final bool isRunning;
  final int lastExportedSeq;
  final DateTime? lastExportedAtUtc;
  final String? lastError;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MirrorStatus &&
          isRunning == other.isRunning &&
          lastExportedSeq == other.lastExportedSeq &&
          ((lastExportedAtUtc == null && other.lastExportedAtUtc == null) ||
              (lastExportedAtUtc != null &&
                  other.lastExportedAtUtc != null &&
                  lastExportedAtUtc!.isAtSameMomentAs(
                    other.lastExportedAtUtc!,
                  ))) &&
          lastError == other.lastError;

  @override
  int get hashCode => Object.hash(
    isRunning,
    lastExportedSeq,
    lastExportedAtUtc?.toUtc(),
    lastError,
  );
}

/// 5-second debounced open Markdown mirror exporter (`INV-07`, `INV-12`, `FR-SYNC-004`).
abstract interface class MirrorExporter {
  Stream<MirrorStatus> watchStatus();

  MirrorStatus get currentStatus;

  /// Schedules a debounced incremental export (default 5s).
  void scheduleExport();

  /// Cancels pending debounce and flushes incremental delta immediately (awaited on shutdown).
  Future<void> flushNow();

  /// Full atomic reconciliation of `mirror/markdown/` (`stream/`, `tasks/`, `0700 private/`, `.archived/`),
  /// touching ONLY manifest-owned files (`INV-07`, `INV-12`).
  Future<void> rebuildAll();

  Future<void> dispose();
}

/// Pure `dart:io` atomic implementation of [MirrorExporter].
final class FileMirrorExporter implements MirrorExporter {
  FileMirrorExporter({
    required this._vaultDir,
    required this._enabled,
    required this._debounceDuration,
    required this._dbProvider,
    required this._isVaultOpen,
    required this._persistWatermarkSeq,
    required int initialWatermarkSeq,
    required this._bfm,
  }) : _status = MirrorStatus(
         isRunning: false,
         lastExportedSeq: initialWatermarkSeq,
       );

  static const String _manifestFileName = '.blink-mirror-manifest.json';

  final Directory _vaultDir;
  final bool _enabled;
  final Duration _debounceDuration;
  final Database Function() _dbProvider;
  final bool Function() _isVaultOpen;
  final void Function(int seqId) _persistWatermarkSeq;
  final BfmEngine _bfm;

  final StreamController<MirrorStatus> _statusController =
      StreamController<MirrorStatus>.broadcast();
  MirrorStatus _status;
  Timer? _debounceTimer;
  Future<void>? _inFlight;
  bool _rescheduleRequested = false;
  bool _disposed = false;

  @override
  MirrorStatus get currentStatus => _status;

  @override
  Stream<MirrorStatus> watchStatus() {
    late StreamController<MirrorStatus> controller;
    StreamSubscription<MirrorStatus>? sub;
    controller = StreamController<MirrorStatus>.broadcast(
      onListen: () {
        if (!controller.isClosed) {
          controller.add(_status);
        }
        sub = _statusController.stream.listen(
          (status) {
            if (!controller.isClosed) {
              controller.add(status);
            }
          },
          onError: controller.addError,
          onDone: () {
            if (!controller.isClosed) {
              controller.close();
            }
          },
        );
      },
      onCancel: () async {
        await sub?.cancel();
        sub = null;
      },
    );
    return controller.stream;
  }

  @override
  void scheduleExport() {
    if (!_enabled || _disposed || !_isVaultOpen()) {
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      _debounceTimer = null;
      unawaited(_triggerExport(forceFull: false));
    });
  }

  @override
  Future<void> flushNow() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_enabled || _disposed || !_isVaultOpen()) {
      return;
    }
    await _triggerExport(forceFull: false);
  }

  @override
  Future<void> rebuildAll() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (_disposed || !_isVaultOpen()) {
      return;
    }
    await _triggerExport(forceFull: true);
  }

  @override
  Future<void> dispose() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _disposed = true;
    final pending = _inFlight;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
  }

  Future<void> _triggerExport({required bool forceFull}) async {
    if (_inFlight != null) {
      _rescheduleRequested = true;
      await _inFlight;
      if (!_disposed && _isVaultOpen()) {
        await _runExportPass(forceFull: forceFull);
      }
      return;
    }
    await _runExportPass(forceFull: forceFull);
  }

  Future<void> _runExportPass({required bool forceFull}) async {
    if (_disposed || !_isVaultOpen()) {
      return;
    }
    final completer = Completer<void>();
    _inFlight = completer.future;

    _emitStatus(
      MirrorStatus(
        isRunning: true,
        lastExportedSeq: _status.lastExportedSeq,
        lastExportedAtUtc: _status.lastExportedAtUtc,
      ),
    );

    try {
      final exportedSeq = await _performExport(forceFull: forceFull);
      final nowUtc = DateTime.now().toUtc();
      _persistWatermarkSeq(exportedSeq);
      _emitStatus(
        MirrorStatus(
          isRunning: false,
          lastExportedSeq: exportedSeq,
          lastExportedAtUtc: nowUtc,
        ),
      );
    } catch (error) {
      _emitStatus(
        MirrorStatus(
          isRunning: false,
          lastExportedSeq: _status.lastExportedSeq,
          lastExportedAtUtc: _status.lastExportedAtUtc,
          lastError: error.toString(),
        ),
      );
      rethrow;
    } finally {
      _inFlight = null;
      completer.complete();
      if (_rescheduleRequested && !_disposed && _isVaultOpen()) {
        _rescheduleRequested = false;
      }
    }
  }

  Future<int> _performExport({required bool forceFull}) async {
    final db = _dbProvider();
    final seqRows = db.select(
      'SELECT COALESCE(MAX(seq_id), 0) AS max_seq FROM sync_oplog',
    );
    final latestSeq = (seqRows.first['max_seq'] as int?) ?? 0;

    if (!forceFull &&
        latestSeq == _status.lastExportedSeq &&
        await _manifestFile().exists()) {
      return latestSeq;
    }

    final mirrorRoot = Directory(p.join(_vaultDir.path, 'mirror'));
    await mirrorRoot.create(recursive: true);

    final activeEntries = db
        .select(
          'SELECT * FROM raw_entries WHERE deleted_at IS NULL '
          'ORDER BY created_at ASC, id ASC',
        )
        .map(rowToRawEntry)
        .toList(growable: false);

    final activeTasks = db
        .select(
          'SELECT * FROM raw_tasks WHERE deleted_at IS NULL '
          'ORDER BY created_at ASC, id ASC',
        )
        .map(rowToRawTask)
        .toList(growable: false);

    final entryRelPathById = <String, String>{};
    final privateIds = <String>{};
    for (final entry in activeEntries) {
      final datePath = _streamRelPath(entry);
      entryRelPathById[entry.id] = datePath;
      if (entry.isPrivate) {
        privateIds.add(entry.id);
      }
    }
    for (final row in db.select(
      "SELECT id FROM raw_entries WHERE privacy_level = 'private'",
    )) {
      privateIds.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM raw_sources WHERE privacy_level = 'private'",
    )) {
      privateIds.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM raw_annotations WHERE privacy_level = 'private'",
    )) {
      privateIds.add(row['id'] as String);
    }
    for (final row in db.select(
      "SELECT id FROM ai_syntheses WHERE privacy_scope = 'local_with_private'",
    )) {
      privateIds.add(row['id'] as String);
    }

    // Group active entries by target relative path under `mirror/`.
    final normalByPath = <String, List<RawEntry>>{};
    final privateByPath = <String, List<RawEntry>>{};
    for (final entry in activeEntries) {
      final relPath = _streamRelPath(entry);
      if (entry.isPrivate) {
        privateByPath.putIfAbsent(relPath, () => <RawEntry>[]).add(entry);
      } else {
        normalByPath.putIfAbsent(relPath, () => <RawEntry>[]).add(entry);
      }
    }

    final desiredFiles = <String, String>{};

    for (final pair in normalByPath.entries) {
      desiredFiles[pair.key] = _renderStreamDayMarkdown(
        relPath: pair.key,
        entries: pair.value,
        entryPrivacy: PrivacyLevel.normal,
        entryRelPathById: entryRelPathById,
        privateIds: privateIds,
      );
    }

    if (privateByPath.isNotEmpty) {
      await applyOwnerOnlyDirPermissions(
        Directory(p.join(mirrorRoot.path, 'markdown', 'private')),
      );
      for (final pair in privateByPath.entries) {
        desiredFiles[pair.key] = _renderStreamDayMarkdown(
          relPath: pair.key,
          entries: pair.value,
          entryPrivacy: PrivacyLevel.private,
          entryRelPathById: entryRelPathById,
          privateIds: privateIds,
        );
      }
    }

    final normalTasks = activeTasks
        .where((t) => !t.isPrivate)
        .toList(growable: false);
    if (normalTasks.isNotEmpty) {
      const rel = 'markdown/tasks/open-tasks.md';
      desiredFiles[rel] = _renderTasksMarkdown(
        relPath: rel,
        tasks: normalTasks,
        entryRelPathById: entryRelPathById,
        privateIds: privateIds,
        isPrivateSection: false,
      );
    }

    final privateTasks = activeTasks
        .where((t) => t.isPrivate)
        .toList(growable: false);
    if (privateTasks.isNotEmpty) {
      await applyOwnerOnlyDirPermissions(
        Directory(p.join(mirrorRoot.path, 'markdown', 'private')),
      );
      const rel = 'markdown/private/tasks/open-tasks.md';
      desiredFiles[rel] = _renderTasksMarkdown(
        relPath: rel,
        tasks: privateTasks,
        entryRelPathById: entryRelPathById,
        privateIds: privateIds,
        isPrivateSection: true,
      );
    }

    final previousOwned = await _readManifestOwnedPaths();

    // Write every desired owned file atomically (`INV-07`).
    for (final pair in desiredFiles.entries) {
      final file = _fileForMirrorRelPath(mirrorRoot, pair.key);
      await writeStringAtomically(file, pair.value);
    }

    // Archive previously owned files that are no longer active (`INV-12`),
    // NEVER touching unowned user files.
    final stamp = formatCompactUtcStamp(DateTime.now().toUtc());
    for (final oldRel in previousOwned) {
      if (desiredFiles.containsKey(oldRel)) {
        continue;
      }
      final oldFile = _fileForMirrorRelPath(mirrorRoot, oldRel);
      if (await oldFile.exists()) {
        final archivedRel = oldRel.replaceAll('/', '__');
        final archiveDest = File(
          p.join(mirrorRoot.path, '.archived', '$stamp-$archivedRel'),
        );
        await atomicRenameWithRetry(oldFile, archiveDest);
      }
    }

    // Persist updated manifest atomically.
    final sortedOwned = desiredFiles.keys.toList()..sort();
    await _writeManifestOwnedPaths(sortedOwned);

    return latestSeq;
  }

  String _renderStreamDayMarkdown({
    required String relPath,
    required List<RawEntry> entries,
    required PrivacyLevel entryPrivacy,
    required Map<String, String> entryRelPathById,
    required Set<String> privateIds,
  }) {
    final firstDate = _formatDateYmd(entries.first.createdAtUtc);
    final buf = StringBuffer('# $firstDate\n');

    for (final entry in entries) {
      final uuid8 = entry.id.length >= 8 ? entry.id.substring(0, 8) : entry.id;
      final timeHm = _formatTimeHm(entry.createdAtUtc);
      buf.writeln();
      buf.writeln('<a id="entry-$uuid8"></a>');
      buf.writeln('## $timeHm · ${entry.entryKind.wireValue}');
      buf.writeln();
      final body = _bfm.toMirrorMarkdown(
        entry.bodyMd,
        entryPrivacy: entryPrivacy,
        privateTargetIds: privateIds,
        linkResolver: (link, currentPrivacy) => _resolveMirrorLink(
          fromRelPath: relPath,
          link: link,
          currentPrivacy: currentPrivacy,
          entryRelPathById: entryRelPathById,
        ),
      );
      buf.writeln(body);
    }

    return buf.toString();
  }

  String _renderTasksMarkdown({
    required String relPath,
    required List<RawTask> tasks,
    required Map<String, String> entryRelPathById,
    required Set<String> privateIds,
    required bool isPrivateSection,
  }) {
    final title = isPrivateSection ? '# Private Tasks' : '# Open Tasks';
    final buf = StringBuffer('$title\n\n');
    for (final task in tasks) {
      final checkbox = switch (task.status) {
        TaskStatus.open => '- [ ]',
        TaskStatus.done => '- [x]',
        TaskStatus.deferred => '- [ ] [顺延]',
        TaskStatus.dropped => '- [x] ~~[放弃]~~',
      };
      var originSuffix = '';
      final originId = task.originEntryId;
      if (originId != null) {
        if (!isPrivateSection && privateIds.contains(originId)) {
          originSuffix = ' ([来源 (私密条目)])';
        } else {
          final targetRel = entryRelPathById[originId];
          if (targetRel != null) {
            final relativeHref = _posixRelative(
              fromDir: p.posix.dirname(relPath),
              toPath: targetRel,
            );
            final uuid8 = originId.length >= 8
                ? originId.substring(0, 8)
                : originId;
            originSuffix = ' ([来源]($relativeHref#entry-$uuid8))';
          }
        }
      }
      buf.writeln('$checkbox ${task.title}$originSuffix');
    }
    return buf.toString();
  }

  String _resolveMirrorLink({
    required String fromRelPath,
    required BfmParsedLink link,
    required PrivacyLevel currentPrivacy,
    required Map<String, String> entryRelPathById,
  }) {
    final fromDir = p.posix.dirname(fromRelPath);
    switch (link.targetKind) {
      case BfmLinkTargetKind.entry:
        final id = link.targetId;
        final targetRel = id != null ? entryRelPathById[id] : null;
        if (targetRel != null && id != null) {
          final relHref = _posixRelative(fromDir: fromDir, toPath: targetRel);
          final uuid8 = id.length >= 8 ? id.substring(0, 8) : id;
          return '[${link.label}]($relHref#entry-$uuid8)';
        }
        return '[${link.label}]';
      case BfmLinkTargetKind.source:
      case BfmLinkTargetKind.annotation:
        final id = link.targetId ?? 'unknown';
        final anchorSuffix = link.anchor != null ? '#${link.anchor}' : '';
        final relHref = _posixRelative(
          fromDir: fromDir,
          toPath: 'markdown/sources/$id.md',
        );
        return '[${link.label}]($relHref$anchorSuffix)';
      case BfmLinkTargetKind.ai:
        final id = link.targetId ?? 'unknown';
        final htmlHref = _posixRelative(
          fromDir: fromDir,
          toPath: 'insights/$id.html',
        );
        final mdHref = _posixRelative(
          fromDir: fromDir,
          toPath: 'insights/$id.md',
        );
        return '> ✦ AI 派生视图：[${link.label}]($htmlHref)（[纯文本摘要]($mdHref)）';
      case BfmLinkTargetKind.titleQuery:
        return '[[${link.label}]]';
    }
  }

  static String _streamRelPath(RawEntry entry) {
    final dt = entry.createdAtUtc.toUtc();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    if (entry.isPrivate) {
      return 'markdown/private/stream/$y/$m/$y-$m-$d.md';
    }
    return 'markdown/stream/$y/$m/$y-$m-$d.md';
  }

  static String _formatDateYmd(DateTime utc) {
    final dt = utc.toUtc();
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _formatTimeHm(DateTime utc) {
    final dt = utc.toUtc();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm UTC';
  }

  static String _posixRelative({
    required String fromDir,
    required String toPath,
  }) => p.posix.relative(toPath, from: fromDir);

  File _manifestFile() =>
      File(p.join(_vaultDir.path, 'mirror', _manifestFileName));

  File _fileForMirrorRelPath(Directory mirrorRoot, String relPath) {
    final segments = relPath.split('/');
    return File(p.joinAll(<String>[mirrorRoot.path, ...segments]));
  }

  Future<Set<String>> _readManifestOwnedPaths() async {
    final manifest = _manifestFile();
    if (!await manifest.exists()) {
      return <String>{};
    }
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map<String, Object?> && decoded['owned_files'] is List) {
        return (decoded['owned_files'] as List)
            .whereType<String>()
            .where((path) => !path.contains('..') && !path.startsWith('/'))
            .toSet();
      }
    } catch (_) {
      // Preserve corrupt manifest without deleting any user files.
      await preserveCorruptFile(manifest);
    }
    return <String>{};
  }

  Future<void> _writeManifestOwnedPaths(List<String> ownedFiles) async {
    final payload = const JsonEncoder.withIndent('  ')
        .convert(<String, Object?>{
          'manifest_version': 1,
          'owned_files': ownedFiles,
          'updated_at_utc': DateTime.now().toUtc().toIso8601String(),
        });
    await writeStringAtomically(_manifestFile(), '$payload\n');
  }

  void _emitStatus(MirrorStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}
