import 'dart:async';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';

import 'package:blink_client/application/sync_controller.dart';
import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/secret_store.dart';

/// Fixed 4-entry primary navigation destinations (`docs/ui.md` §1).
enum BlinkNavDestination { stream, files, tasks, settings }

/// Entry stream sidebar filter modes.
enum StreamFilterKind { all, privateOnly, tag, trash }

/// Coordinates active [VaultManager], navigation, entry/blob/trash operations,
/// theme surface preference, sync orchestration, and shutdown flushing (`INV-02`).
class BlinkWorkspaceController extends ChangeNotifier {
  BlinkWorkspaceController({
    required this.lifecycle,
    BlinkFilePicker? filePicker,
    VaultManager? initialVault,
    BlinkSyncController? syncController,
    BlinkSecretStore? secretStore,
    LanDiscovery? lanDiscovery,
    BlinkNavDestination initialDestination = BlinkNavDestination.stream,
    this.enableMirrorExporter = true,
  }) : filePicker = filePicker ?? createDefaultBlinkFilePicker(),
       _vault = initialVault,
       _destination = initialDestination,
       _ownsSyncController = syncController == null {
    _syncController =
        syncController ??
        BlinkSyncController(
          paths: lifecycle.paths,
          expectedChannel: lifecycle.buildInfo.isProductionChannel
              ? BlinkChannel.blink
              : BlinkChannel.blinkDev,
          secretStore: secretStore,
          lanDiscovery: lanDiscovery,
          isQuiet: lifecycle.isQuiet,
          onVaultDataChanged: () => unawaited(refreshAll()),
        );
  }

  final DesktopLifecycleController lifecycle;
  final BlinkFilePicker filePicker;
  final bool enableMirrorExporter;
  late final BlinkSyncController _syncController;
  final bool _ownsSyncController;

  BlinkSyncController get sync => _syncController;

  VaultManager? _vault;
  BlinkNavDestination _destination;
  StreamFilterKind _streamFilter = StreamFilterKind.all;
  String? _selectedTag;
  String? _selectedEntryId;
  bool _splitPreviewEnabled = false;
  bool _searchModalOpen = false;
  bool _isLoading = false;
  bool _isDisposed = false;
  bool _ownsVault = false;

  VaultStats? _stats;
  MirrorStatus? _mirrorStatus;
  List<RawEntry> _entries = const <RawEntry>[];
  Map<String, int> _tagCounts = const <String, int>{};
  List<MediaBlob> _blobs = const <MediaBlob>[];
  Map<String, List<RawEntry>> _blobReferrers = const <String, List<RawEntry>>{};

  BlinkErrorCode? _vaultErrorCode;
  String? _vaultErrorMessage;
  String? _bannerMessage;
  bool _bannerIsError = false;

  Future<void> Function()? _onFlushDraftBeforeShutdown;
  StreamSubscription<VaultStats>? _statsSub;
  StreamSubscription<MirrorStatus>? _mirrorSub;
  StreamSubscription<List<RawEntry>>? _entriesSub;

  VaultManager? get vault => _vault;
  bool get hasOpenVault => _vault != null && _vault!.isOpen;
  BlinkNavDestination get destination => _destination;
  StreamFilterKind get streamFilter => _streamFilter;
  String? get selectedTag => _selectedTag;
  String? get selectedEntryId => _selectedEntryId;
  bool get splitPreviewEnabled => _splitPreviewEnabled;
  bool get searchModalOpen => _searchModalOpen;
  bool get isLoading => _isLoading;

  VaultStats? get stats => _stats;
  MirrorStatus? get mirrorStatus => _mirrorStatus;
  List<RawEntry> get entries => _entries;
  Map<String, int> get tagCounts => _tagCounts;
  List<MediaBlob> get blobs => _blobs;
  Map<String, List<RawEntry>> get blobReferrers => _blobReferrers;

  BlinkErrorCode? get vaultErrorCode => _vaultErrorCode;
  String? get vaultErrorMessage => _vaultErrorMessage;
  String? get bannerMessage => _bannerMessage;
  bool get bannerIsError => _bannerIsError;

  BlinkChannel get expectedChannel => lifecycle.buildInfo.isProductionChannel
      ? BlinkChannel.blink
      : BlinkChannel.blinkDev;

  DesktopSurfacePreference? get surfaceMode => lifecycle.settings.surfaceMode;

  Directory get effectiveVaultDir => lifecycle.paths.resolveEffectiveVaultDir(
    customVaultPath: lifecycle.settings.customVaultPath,
  );

  /// Registers the active editor's draft flush hook so shutdown always persists
  /// pending unsaved text before `MirrorExporter.flushNow()` and WAL checkpoint.
  void registerDraftFlushHook(Future<void> Function()? hook) {
    _onFlushDraftBeforeShutdown = hook;
  }

  /// Opens the configured vault (if one was not pre-injected), subscribes to
  /// reactive streams, and hooks clean shutdown flush into [lifecycle].
  Future<void> initialize() async {
    lifecycle.setSyncShutdownHook(_syncController.stopForShutdown);
    lifecycle.setShutdownFlushHook(flushAndCloseForShutdown);
    await _syncController.initialize();
    if (_vault != null) {
      _ownsVault = false;
      await _attachVault(_vault!);
      return;
    }

    _isLoading = true;
    _safeNotify();
    try {
      final targetDir = effectiveVaultDir;
      if (lifecycle.paths.isForbiddenTargetPath(targetDir.path)) {
        _vaultErrorCode = BlinkErrorCode.channelMismatch;
        _vaultErrorMessage =
            '通道隔离保护（channel_mismatch）：所配置的便携库目录与受保护通道目录重叠，已拒绝打开。';
        return;
      }
      final opened = await VaultManager.open(
        VaultConfig(
          vaultDir: targetDir,
          expectedChannel: expectedChannel,
          enableMirrorExporter: enableMirrorExporter,
        ),
      );
      _ownsVault = true;
      _vaultErrorCode = null;
      _vaultErrorMessage = null;
      await _attachVault(opened);
    } on BlinkException catch (error) {
      _vaultErrorCode = error.code;
      _vaultErrorMessage = _formatVaultError(error);
    } catch (error) {
      _vaultErrorCode = BlinkErrorCode.ioError;
      _vaultErrorMessage = '无法打开便携库：$error';
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<void> _attachVault(VaultManager vault) async {
    await _cancelSubscriptions();
    _vault = vault;
    _mirrorStatus = vault.mirror.currentStatus;
    _statsSub = vault.watchStats().listen((nextStats) {
      _stats = nextStats;
      _safeNotify();
    }, onError: (_) {});
    _mirrorSub = vault.mirror.watchStatus().listen((nextStatus) {
      _mirrorStatus = nextStatus;
      _safeNotify();
    }, onError: (_) {});
    _resubscribeEntries();
    await refreshAll();
    await _syncController.attachVault(vault);
  }

  void _resubscribeEntries() {
    _entriesSub?.cancel();
    _entriesSub = null;
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    _entriesSub = activeVault.raw.watchEntries(_buildEntryQuery()).listen((
      list,
    ) {
      _entries = list;
      _safeNotify();
      unawaited(_refreshMetadataLists());
    }, onError: (_) {});
  }

  EntryQuery _buildEntryQuery() {
    switch (_streamFilter) {
      case StreamFilterKind.all:
        return const EntryQuery(limit: 200);
      case StreamFilterKind.privateOnly:
        return const EntryQuery(
          privacyFilter: PrivacyLevel.private,
          limit: 200,
        );
      case StreamFilterKind.tag:
        return EntryQuery(tag: _selectedTag, limit: 200);
      case StreamFilterKind.trash:
        return const EntryQuery(onlyDeleted: true, limit: 200);
    }
  }

  Future<void> refreshAll() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        activeVault.getStats(),
        activeVault.raw.listEntries(_buildEntryQuery()),
        activeVault.raw.listTagCounts(),
        activeVault.blobs.listBlobs(limit: 500),
        activeVault.raw.listEntries(
          const EntryQuery(includeDeleted: true, limit: 500),
        ),
      ]);
      _stats = results[0] as VaultStats;
      _entries = results[1] as List<RawEntry>;
      _tagCounts = results[2] as Map<String, int>;
      _blobs = results[3] as List<MediaBlob>;
      _blobReferrers = _indexBlobReferrers(results[4] as List<RawEntry>);
      _mirrorStatus = activeVault.mirror.currentStatus;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> _refreshMetadataLists() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    try {
      final tagCounts = await activeVault.raw.listTagCounts();
      final blobs = await activeVault.blobs.listBlobs(limit: 500);
      final allEntries = await activeVault.raw.listEntries(
        const EntryQuery(includeDeleted: true, limit: 500),
      );
      _tagCounts = tagCounts;
      _blobs = blobs;
      _blobReferrers = _indexBlobReferrers(allEntries);
      _safeNotify();
    } catch (_) {}
  }

  Map<String, List<RawEntry>> _indexBlobReferrers(List<RawEntry> allEntries) {
    final map = <String, List<RawEntry>>{};
    for (final entry in allEntries) {
      if (entry.audioBlobSha256 != null && entry.audioBlobSha256!.isNotEmpty) {
        map.putIfAbsent(entry.audioBlobSha256!, () => <RawEntry>[]).add(entry);
      }
      for (final sha in entry.imageBlobSha256s) {
        map.putIfAbsent(sha, () => <RawEntry>[]).add(entry);
      }
    }
    return map;
  }

  void setDestination(BlinkNavDestination next) {
    if (_destination == next) {
      return;
    }
    _destination = next;
    _safeNotify();
  }

  void setStreamFilter(StreamFilterKind filter, {String? tag}) {
    _streamFilter = filter;
    _selectedTag = filter == StreamFilterKind.tag ? tag : null;
    if (filter == StreamFilterKind.trash) {
      _selectedEntryId = null;
    }
    _resubscribeEntries();
    _safeNotify();
    unawaited(refreshAll());
  }

  void selectEntry(String? entryId) {
    if (_selectedEntryId == entryId) {
      return;
    }
    _selectedEntryId = entryId;
    _safeNotify();
  }

  Future<void> openEntryById(String entryId) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    final found = await activeVault.raw.getEntryById(
      entryId,
      includeDeleted: true,
    );
    if (found == null) {
      showBanner('找不到对应条目，可能已被永久清除。', isError: true);
      return;
    }
    _destination = BlinkNavDestination.stream;
    if (found.isDeleted) {
      _streamFilter = StreamFilterKind.trash;
      _selectedTag = null;
    } else if (_streamFilter == StreamFilterKind.trash ||
        (_streamFilter == StreamFilterKind.privateOnly && !found.isPrivate) ||
        _streamFilter == StreamFilterKind.tag) {
      _streamFilter = StreamFilterKind.all;
      _selectedTag = null;
    }
    _selectedEntryId = found.id;
    _searchModalOpen = false;
    _resubscribeEntries();
    _safeNotify();
    await refreshAll();
  }

  void toggleSplitPreview() {
    _splitPreviewEnabled = !_splitPreviewEnabled;
    _safeNotify();
  }

  void setSplitPreviewEnabled(bool enabled) {
    if (_splitPreviewEnabled == enabled) {
      return;
    }
    _splitPreviewEnabled = enabled;
    _safeNotify();
  }

  void setSearchModalOpen(bool open) {
    if (_searchModalOpen == open) {
      return;
    }
    _searchModalOpen = open;
    _safeNotify();
  }

  void setSurfaceMode(DesktopSurfacePreference? mode) {
    lifecycle.updateSurfaceMode(mode);
    _safeNotify();
  }

  void clearBanner() {
    if (_bannerMessage == null) {
      return;
    }
    _bannerMessage = null;
    _bannerIsError = false;
    _safeNotify();
  }

  void showBanner(String message, {bool isError = false}) {
    _bannerMessage = message;
    _bannerIsError = isError;
    _safeNotify();
  }

  void clearVaultError() {
    if (_vaultErrorCode == null && _vaultErrorMessage == null) {
      return;
    }
    _vaultErrorCode = null;
    _vaultErrorMessage = null;
    _safeNotify();
  }

  Future<RawEntry?> createEntry({
    required String bodyMd,
    EntryKind entryKind = EntryKind.blink,
    bool privacyLocked = false,
    List<String> imageBlobSha256s = const <String>[],
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('便携库未就绪，无法保存条目。', isError: true);
      return null;
    }
    try {
      final created = await activeVault.raw.createEntry(
        bodyMd: bodyMd,
        entryKind: entryKind,
        privacyLocked: privacyLocked,
        imageBlobSha256s: imageBlobSha256s,
      );
      await refreshAll();
      return created;
    } on BlinkException catch (error) {
      showBanner(
        '保存条目失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
      return null;
    }
  }

  Future<RawEntry?> updateEntry({
    required String id,
    required String bodyMd,
    EntryKind? entryKind,
    bool? privacyLocked,
    List<String>? imageBlobSha256s,
    bool allowPrivacyDowngrade = false,
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('便携库未就绪，无法更新条目。', isError: true);
      return null;
    }
    try {
      final updated = await activeVault.raw.updateEntry(
        id: id,
        bodyMd: bodyMd,
        entryKind: entryKind,
        privacyLocked: privacyLocked,
        imageBlobSha256s: imageBlobSha256s,
        allowPrivacyDowngrade: allowPrivacyDowngrade,
      );
      await refreshAll();
      return updated;
    } on BlinkException catch (error) {
      showBanner(
        '更新条目失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
      return null;
    }
  }

  Future<void> softDeleteEntry(String id) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    await activeVault.raw.softDeleteEntry(id);
    if (_selectedEntryId == id) {
      _selectedEntryId = null;
    }
    showBanner('条目已移入 30 天回收站，可随时还原。');
    await refreshAll();
  }

  Future<void> restoreEntry(String id) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    await activeVault.raw.restoreEntry(id);
    showBanner('已从回收站还原条目。');
    await refreshAll();
  }

  Future<int> purgeEntryPermanently(String id) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return 0;
    }
    final purged = await activeVault.raw.purgeEntryPermanently(id);
    if (_selectedEntryId == id) {
      _selectedEntryId = null;
    }
    showBanner('已彻底清除条目并回收无引用附件。');
    await refreshAll();
    return purged;
  }

  Future<int> purgeExpiredTrash() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return 0;
    }
    final count = await activeVault.raw.purgeExpiredTrash();
    showBanner(count > 0 ? '已清理 $count 条超过 30 天的回收站条目。' : '当前没有超过 30 天的过期条目。');
    await refreshAll();
    return count;
  }

  Future<MediaBlob?> importFileFromPicker({
    bool attachToSelectedEntry = false,
  }) async {
    final picked = await filePicker.pickFileToOpen(title: '选择要导入的附件文件');
    if (picked == null || picked.trim().isEmpty) {
      return null;
    }
    return importFile(
      File(picked),
      attachToSelectedEntry: attachToSelectedEntry,
    );
  }

  Future<MediaBlob?> importFile(
    File sourceFile, {
    bool attachToSelectedEntry = false,
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('便携库未就绪，无法导入附件。', isError: true);
      return null;
    }
    if (!await sourceFile.exists()) {
      showBanner('所选文件不存在，无法导入。', isError: true);
      return null;
    }
    try {
      final mime = inferMimeTypeFromPath(sourceFile.path);
      final blob = await activeVault.blobs.putFile(sourceFile, mimeType: mime);
      if (attachToSelectedEntry && _selectedEntryId != null) {
        await attachBlobToEntry(_selectedEntryId!, blob.sha256);
      }
      showBanner('附件已按 SHA-256 去重入库（${blob.sha256.substring(0, 12)}…）。');
      await refreshAll();
      return blob;
    } on BlinkException catch (error) {
      showBanner(
        '导入附件失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
      return null;
    } catch (error) {
      showBanner('导入附件失败：$error', isError: true);
      return null;
    }
  }

  Future<bool> attachBlobToEntry(String entryId, String sha256) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return false;
    }
    final entry = await activeVault.raw.getEntryById(entryId);
    if (entry == null) {
      return false;
    }
    if (entry.imageBlobSha256s.contains(sha256)) {
      showBanner('该附件已关联到当前条目。');
      return true;
    }
    final nextList = <String>[...entry.imageBlobSha256s, sha256];
    await activeVault.raw.updateEntry(
      id: entry.id,
      bodyMd: entry.bodyMd,
      imageBlobSha256s: nextList,
    );
    showBanner('附件已关联到所选条目。');
    await refreshAll();
    return true;
  }

  Future<File?> exportBlobToPicker(MediaBlob blob) async {
    final ext = extensionForMimeType(blob.mimeType);
    final suggested = 'blink-${blob.sha256.substring(0, 12)}$ext';
    final destPath = await filePicker.pickFileToSave(
      title: '导出附件副本',
      suggestedFileName: suggested,
    );
    if (destPath == null || destPath.trim().isEmpty) {
      return null;
    }
    if (destPath.startsWith('content://') &&
        filePicker is AndroidBlinkFilePicker) {
      final activeVault = _vault;
      if (activeVault == null || !activeVault.isOpen) {
        return null;
      }
      final bytes = await activeVault.blobs.readBytes(blob.sha256);
      if (bytes == null) {
        showBanner('附件原件缺失，无法导出。', isError: true);
        return null;
      }
      final ok = await (filePicker as AndroidBlinkFilePicker).writeBytesToUri(
        destPath,
        bytes,
      );
      if (!ok) {
        showBanner('导出附件失败：无法写入所选文档位置。', isError: true);
        return null;
      }
      showBanner('已导出附件副本。');
      return File(destPath);
    }
    return exportBlobToFile(blob, File(destPath));
  }

  Future<File?> exportBlobToFile(MediaBlob blob, File destination) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return null;
    }
    File? tmp;
    try {
      final bytes = await activeVault.blobs.readBytes(blob.sha256);
      if (bytes == null) {
        showBanner('附件原件缺失，无法导出。', isError: true);
        return null;
      }
      await destination.parent.create(recursive: true);
      final uniqueTag = DateTime.now().microsecondsSinceEpoch;
      tmp = File('${destination.path}.blink-tmp-$uniqueTag');
      final raf = await tmp.open(mode: FileMode.writeOnly);
      try {
        await raf.writeFrom(bytes);
        await raf.flush();
      } finally {
        await raf.close();
      }
      await _atomicRenameWithRetry(tmp, destination);
      tmp = null;
      showBanner('已导出附件副本。');
      return destination;
    } catch (error) {
      if (tmp != null) {
        try {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        } catch (_) {}
      }
      showBanner('导出附件失败：$error', isError: true);
      return null;
    }
  }

  static Future<void> _atomicRenameWithRetry(File tmp, File target) async {
    const delays = <int>[10, 25, 50, 100, 200, 400];
    Object? lastError;
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      try {
        await tmp.rename(target.path);
        return;
      } on FileSystemException catch (error) {
        lastError = error;
        if (attempt == delays.length) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: delays[attempt]));
      }
    }
    if (lastError != null) {
      throw lastError;
    }
  }

  static String _normalizePathForCompare(String rawPath) {
    var resolved = Directory(rawPath).absolute.path;
    while (resolved.length > 3 &&
        (resolved.endsWith('/') || resolved.endsWith(r'\'))) {
      resolved = resolved.substring(0, resolved.length - 1);
    }
    return Platform.isWindows ? resolved.toLowerCase() : resolved;
  }

  Future<int> gcUnreferencedBlobs() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return 0;
    }
    final removed = await activeVault.blobs.gcUnreferencedBlobs();
    showBanner(removed > 0 ? '已安全回收 $removed 个无引用附件。' : '当前没有可回收的无引用附件。');
    await refreshAll();
    return removed;
  }

  /// Switches the active `<BLINK_VAULT_DIR>` folder. On `channel_mismatch` or
  /// `protocol_mismatch`, preserves the existing open vault and surfaces an
  /// honest diagnostic banner (`INV-06`, `INV-11`).
  Future<bool> switchVaultDirectory(String newPath) async {
    final trimmed = newPath.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (lifecycle.paths.hasVaultDirOverride) {
      showBanner('当前进程通过 BLINK_VAULT_DIR 环境变量锁定库目录，暂不支持在设置内切换。', isError: true);
      return false;
    }
    if (lifecycle.paths.isForbiddenTargetPath(trimmed)) {
      _vaultErrorCode = BlinkErrorCode.channelMismatch;
      _vaultErrorMessage = '通道隔离保护（channel_mismatch）：目标目录与受保护通道目录重叠，已拒绝切换。';
      showBanner(_vaultErrorMessage!, isError: true);
      return false;
    }

    final currentVault = _vault;
    if (currentVault != null &&
        currentVault.isOpen &&
        _normalizePathForCompare(currentVault.config.vaultDir.path) ==
            _normalizePathForCompare(trimmed)) {
      _vaultErrorCode = null;
      _vaultErrorMessage = null;
      showBanner('当前已打开该便携库目录。');
      return true;
    }

    _isLoading = true;
    _safeNotify();
    try {
      final candidate = await VaultManager.open(
        VaultConfig(
          vaultDir: Directory(trimmed),
          expectedChannel: expectedChannel,
          enableMirrorExporter: enableMirrorExporter,
        ),
      );
      final previous = _vault;
      final previousOwned = _ownsVault;
      if (previous != null && previous.isOpen) {
        try {
          await _onFlushDraftBeforeShutdown?.call();
        } catch (_) {}
        try {
          await previous.mirror.flushNow();
        } catch (_) {}
      }
      _vaultErrorCode = null;
      _vaultErrorMessage = null;
      _ownsVault = true;
      _selectedEntryId = null;
      _streamFilter = StreamFilterKind.all;
      _selectedTag = null;
      await _attachVault(candidate);
      if (previous != null && previousOwned && previous.isOpen) {
        await previous.checkpointAndClose();
      }
      lifecycle.updateCustomVaultPath(trimmed);
      showBanner('已切换单文件夹便携库。');
      return true;
    } on BlinkException catch (error) {
      _vaultErrorCode = error.code;
      _vaultErrorMessage = _formatVaultError(error);
      showBanner(_vaultErrorMessage!, isError: true);
      return false;
    } catch (error) {
      _vaultErrorCode = BlinkErrorCode.ioError;
      _vaultErrorMessage = '切换便携库失败：$error';
      showBanner(_vaultErrorMessage!, isError: true);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<bool> pickAndSwitchVaultDirectory() async {
    final dirPath = await filePicker.pickDirectory(title: '选择 BLINK 单文件夹便携库目录');
    if (dirPath == null || dirPath.trim().isEmpty) {
      return false;
    }
    return switchVaultDirectory(dirPath);
  }

  Future<bool> resetToDefaultVault() async {
    final defaultPath = lifecycle.paths.vaultDir.path;
    final ok = await switchVaultDirectory(defaultPath);
    if (ok) {
      lifecycle.updateCustomVaultPath(null);
      _safeNotify();
    }
    return ok;
  }

  Future<VaultBackupResult?> createHotBackup() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return null;
    }
    try {
      final result = await activeVault.createHotBackup();
      showBanner('已完成 VACUUM INTO 热快照备份（${formatByteSize(result.byteSize)}）。');
      return result;
    } on BlinkException catch (error) {
      showBanner(
        '热备份失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
      return null;
    }
  }

  Future<bool> rebuildDerivedStores({bool clearAiTables = false}) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return false;
    }
    try {
      await activeVault.rebuildDerivedStores(clearAiTables: clearAiTables);
      showBanner('已重建 index/fts.db、链接索引与开放镜像，原文层分毫未动。');
      await refreshAll();
      return true;
    } on BlinkException catch (error) {
      showBanner(
        '重建索引失败（${error.code.wireCode}）：${error.message}',
        isError: true,
      );
      return false;
    }
  }

  Future<bool> flushMirrorNow() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return false;
    }
    try {
      await activeVault.mirror.flushNow();
      await activeVault.mirror.rebuildAll();
      _mirrorStatus = activeVault.mirror.currentStatus;
      showBanner('已立即完成只读 .md 开放镜像导出。');
      await refreshAll();
      return true;
    } catch (error) {
      showBanner('镜像导出失败：$error', isError: true);
      return false;
    }
  }

  /// Shutdown flush hook wired into [DesktopLifecycleController]:
  /// stops embedded sync host/SSE cleanly, flushes active editor draft,
  /// flushes debounced mirror exporter, and checkpoints/closes SQLite WAL
  /// cleanly (`INV-07`).
  Future<void> flushAndCloseForShutdown() async {
    Object? firstError;
    try {
      await _syncController.stopForShutdown();
    } catch (error) {
      firstError ??= error;
    }
    if (_onFlushDraftBeforeShutdown != null) {
      try {
        await _onFlushDraftBeforeShutdown!();
      } catch (error) {
        firstError ??= error;
      }
    }
    final activeVault = _vault;
    if (activeVault != null && activeVault.isOpen) {
      try {
        await activeVault.mirror.flushNow();
      } catch (error) {
        firstError ??= error;
      }
      try {
        await activeVault.checkpointAndClose();
      } catch (error) {
        firstError ??= error;
      }
    }
    if (firstError != null) {
      throw firstError;
    }
  }

  String _formatVaultError(BlinkException error) {
    switch (error.code) {
      case BlinkErrorCode.channelMismatch:
        return '通道锁冲突（channel_mismatch）：目标目录属于其他通道，当前通道为 '
            '${expectedChannel.wireValue}，已拒绝跨通道打开。';
      case BlinkErrorCode.protocolMismatch:
        return '版本不兼容（protocol_mismatch）：目标便携库由更新版本的 BLINK 创建，请先升级客户端。';
      default:
        return '便携库打开失败（${error.code.wireCode}）：${error.message}';
    }
  }

  Future<void> _cancelSubscriptions() async {
    await _statsSub?.cancel();
    await _mirrorSub?.cancel();
    await _entriesSub?.cancel();
    _statsSub = null;
    _mirrorSub = null;
    _entriesSub = null;
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_cancelSubscriptions());
    if (_ownsSyncController) {
      _syncController.dispose();
    }
    if (_ownsVault && _vault != null && _vault!.isOpen) {
      unawaited(_vault!.checkpointAndClose());
    }
    super.dispose();
  }
}

/// Infers a canonical MIME type from a local file path extension.
String inferMimeTypeFromPath(String filePath) {
  final lower = filePath.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.pdf')) return 'application/pdf';
  if (lower.endsWith('.epub')) return 'application/epub+zip';
  if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
    return 'text/markdown';
  }
  if (lower.endsWith('.txt')) return 'text/plain';
  if (lower.endsWith('.json')) return 'application/json';
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.m4a')) return 'audio/mp4';
  if (lower.endsWith('.ogg') || lower.endsWith('.opus')) return 'audio/ogg';
  if (lower.endsWith('.wav')) return 'audio/wav';
  return 'application/octet-stream';
}

/// Returns a suggested file extension for a MIME type when exporting blobs.
String extensionForMimeType(String mimeType) {
  switch (mimeType.toLowerCase()) {
    case 'image/png':
      return '.png';
    case 'image/jpeg':
      return '.jpg';
    case 'image/webp':
      return '.webp';
    case 'image/gif':
      return '.gif';
    case 'application/pdf':
      return '.pdf';
    case 'application/epub+zip':
      return '.epub';
    case 'text/markdown':
      return '.md';
    case 'text/plain':
      return '.txt';
    case 'application/json':
      return '.json';
    case 'audio/mpeg':
      return '.mp3';
    case 'audio/mp4':
      return '.m4a';
    case 'audio/ogg':
      return '.opus';
    case 'audio/wav':
      return '.wav';
    default:
      return '.bin';
  }
}

/// Formats a byte count into a compact human-readable string.
String formatByteSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
