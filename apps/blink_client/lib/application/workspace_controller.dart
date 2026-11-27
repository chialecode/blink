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

export 'package:blink_client/platform/desktop_settings.dart'
    show NoteEditorMode;

/// Primary navigation destinations in BLINK's Feishu-style adaptive shell.
enum BlinkNavDestination { memos, notes, tasks, files, settings }

/// Independent categories inside the Settings module.
enum SettingsCategory { general, storage, sync, about }

/// Sidebar filter modes for Quick Memos (`小记`).
enum MemoFilterKind { all, today, privateOnly, tag, trash }

/// Sidebar filter modes for Long-Form Notes (`笔记`).
enum NoteFilterKind { all, privateOnly, tag, trash }

/// Coordinates active [VaultManager], navigation, split memo/note browsing,
/// editor mode, sidebar layout state, attachment/trash operations, theme
/// surface preference, sync orchestration, and shutdown flushing (`INV-02`).
class BlinkWorkspaceController extends ChangeNotifier {
  BlinkWorkspaceController({
    required this.lifecycle,
    BlinkFilePicker? filePicker,
    VaultManager? initialVault,
    BlinkSyncController? syncController,
    BlinkSecretStore? secretStore,
    LanDiscovery? lanDiscovery,
    BlinkNavDestination initialDestination = BlinkNavDestination.memos,
    SettingsCategory initialSettingsCategory = SettingsCategory.general,
    NoteEditorMode? initialNoteEditorMode,
    this.enableMirrorExporter = true,
  }) : filePicker = filePicker ?? createDefaultBlinkFilePicker(),
       _vault = initialVault,
       _destination = initialDestination,
       _selectedSettingsCategory = initialSettingsCategory,
       _lastSyncedDefaultEditorMode = lifecycle.settings.defaultNoteEditorMode,
       _noteEditorMode =
           initialNoteEditorMode ?? lifecycle.settings.defaultNoteEditorMode,
       _ownsSyncController = syncController == null {
    lifecycle.addListener(_onLifecycleChanged);
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

  /// Entry kinds surfaced in the Quick Memo (`小记`) chat-capsule stream.
  static const List<EntryKind> memoEntryKinds = <EntryKind>[
    EntryKind.blink,
    EntryKind.voiceNote,
    EntryKind.photoNote,
  ];

  /// Entry kinds surfaced in the Long-Form Note (`笔记`) document view.
  static const List<EntryKind> noteEntryKinds = <EntryKind>[EntryKind.diary];

  static bool isNoteKind(EntryKind kind) => kind == EntryKind.diary;
  static bool isMemoKind(EntryKind kind) => !isNoteKind(kind);

  static const BfmEngine _bfm = BfmEngine();
  static const int _queryLimit = 500;
  static const int _metadataScanLimit = 5000;

  final DesktopLifecycleController lifecycle;
  final BlinkFilePicker filePicker;
  final bool enableMirrorExporter;
  late final BlinkSyncController _syncController;
  final bool _ownsSyncController;

  BlinkSyncController get sync => _syncController;

  VaultManager? _vault;
  BlinkNavDestination _destination;
  SettingsCategory _selectedSettingsCategory;
  NoteEditorMode _lastSyncedDefaultEditorMode;
  NoteEditorMode _noteEditorMode;
  bool _sidebarCollapsed = false;

  MemoFilterKind _selectedMemoFilter = MemoFilterKind.all;
  String? _selectedMemoTag;
  String? _selectedMemoId;

  NoteFilterKind _selectedNoteFilter = NoteFilterKind.all;
  String? _selectedNoteTag;
  String? _selectedNoteId;
  String? _pendingMobileNoteOpenId;

  String? _selectedEntryId;
  bool _splitPreviewEnabled = false;
  bool _searchModalOpen = false;
  bool _isLoading = false;
  bool _isDisposed = false;
  bool _ownsVault = false;
  bool _metadataRefreshInFlight = false;
  bool _metadataRefreshQueued = false;

  VaultStats? _stats;
  MirrorStatus? _mirrorStatus;
  List<RawEntry> _memoEntries = const <RawEntry>[];
  List<RawEntry> _noteEntries = const <RawEntry>[];
  Map<String, RawEntry> _entriesById = const <String, RawEntry>{};

  int _totalMemoCount = 0;
  int _todayMemoCount = 0;
  int _privateMemoCount = 0;
  int _trashMemoCount = 0;
  Map<String, int> _memoTagCounts = const <String, int>{};

  int _totalNoteCount = 0;
  int _privateNoteCount = 0;
  int _trashNoteCount = 0;
  Map<String, int> _noteTagCounts = const <String, int>{};

  Map<String, int> _tagCounts = const <String, int>{};
  List<MediaBlob> _blobs = const <MediaBlob>[];
  Map<String, List<RawEntry>> _blobReferrers = const <String, List<RawEntry>>{};

  BlinkErrorCode? _vaultErrorCode;
  String? _vaultErrorMessage;
  String? _bannerMessage;
  bool _bannerIsError = false;

  final Set<Future<void> Function()> _draftFlushHooks =
      <Future<void> Function()>{};
  Future<void> Function()? _legacyDraftFlushHook;
  StreamSubscription<VaultStats>? _statsSub;
  StreamSubscription<MirrorStatus>? _mirrorSub;
  StreamSubscription<List<RawEntry>>? _memoEntriesSub;
  StreamSubscription<List<RawEntry>>? _noteEntriesSub;

  VaultManager? get vault => _vault;
  bool get hasOpenVault => _vault != null && _vault!.isOpen;
  BlinkNavDestination get destination => _destination;
  SettingsCategory get selectedSettingsCategory => _selectedSettingsCategory;
  NoteEditorMode get noteEditorMode => _noteEditorMode;
  NoteEditorMode get defaultNoteEditorMode =>
      lifecycle.settings.defaultNoteEditorMode;
  bool get sidebarCollapsed => _sidebarCollapsed;

  MemoFilterKind get selectedMemoFilter => _selectedMemoFilter;
  String? get selectedMemoTag => _selectedMemoTag;
  String? get selectedMemoId => _selectedMemoId;
  List<RawEntry> get memoEntries => _memoEntries;
  int get totalMemoCount => _totalMemoCount;
  int get todayMemoCount => _todayMemoCount;
  int get privateMemoCount => _privateMemoCount;
  int get trashMemoCount => _trashMemoCount;
  Map<String, int> get memoTagCounts => _memoTagCounts;

  RawEntry? get selectedMemo {
    final id = _selectedMemoId;
    if (id == null) {
      return null;
    }
    for (final entry in _memoEntries) {
      if (entry.id == id) {
        return entry;
      }
    }
    final cached = _entriesById[id];
    if (cached != null && isMemoKind(cached.entryKind)) {
      return cached;
    }
    return null;
  }

  NoteFilterKind get selectedNoteFilter => _selectedNoteFilter;
  String? get selectedNoteTag => _selectedNoteTag;
  String? get selectedNoteId => _selectedNoteId;
  String? get pendingMobileNoteOpenId => _pendingMobileNoteOpenId;
  List<RawEntry> get noteEntries => _noteEntries;

  /// Consumes and clears the note ID queued for automatic full-screen editor
  /// navigation on mobile (`<600px`) after cross-module jumps (`promoteMemoToNote`,
  /// `openEntryById`, `createNote`).
  String? consumePendingMobileNoteOpenId() {
    final id = _pendingMobileNoteOpenId;
    _pendingMobileNoteOpenId = null;
    return id;
  }

  /// Clears any pending mobile auto-open request (for example when the user
  /// explicitly taps the mobile Notes bottom navigation tab).
  void clearPendingMobileNoteOpen() {
    _pendingMobileNoteOpenId = null;
  }

  int get totalNoteCount => _totalNoteCount;
  int get privateNoteCount => _privateNoteCount;
  int get trashNoteCount => _trashNoteCount;
  Map<String, int> get noteTagCounts => _noteTagCounts;

  RawEntry? get selectedNote {
    final id = _selectedNoteId;
    if (id == null) {
      return null;
    }
    for (final entry in _noteEntries) {
      if (entry.id == id) {
        return entry;
      }
    }
    final cached = _entriesById[id];
    if (cached != null && isNoteKind(cached.entryKind)) {
      return cached;
    }
    return null;
  }

  String? get selectedEntryId => _selectedEntryId;
  bool get splitPreviewEnabled => _splitPreviewEnabled;
  bool get searchModalOpen => _searchModalOpen;
  bool get isLoading => _isLoading;

  VaultStats? get stats => _stats;
  MirrorStatus? get mirrorStatus => _mirrorStatus;
  List<RawEntry> get entries =>
      _destination == BlinkNavDestination.notes ? _noteEntries : _memoEntries;
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

  void _onLifecycleChanged() {
    final nextDefault = lifecycle.settings.defaultNoteEditorMode;
    if (nextDefault != _lastSyncedDefaultEditorMode) {
      _lastSyncedDefaultEditorMode = nextDefault;
      _noteEditorMode = nextDefault;
      _safeNotify();
    }
  }

  /// Adds a draft-flush callback invoked on vault switch and shutdown
  /// (`INV-07`, `AC-02`). Callers MUST pair with [removeDraftFlushHook] in
  /// `dispose()` so disposed editors never overwrite newer raw entries
  /// (`INV-01`).
  void addDraftFlushHook(Future<void> Function() hook) {
    _draftFlushHooks.add(hook);
  }

  /// Removes a draft-flush callback previously added via [addDraftFlushHook].
  void removeDraftFlushHook(Future<void> Function() hook) {
    _draftFlushHooks.remove(hook);
    if (identical(_legacyDraftFlushHook, hook)) {
      _legacyDraftFlushHook = null;
    }
  }

  /// Registers or clears the single-slot legacy draft flush hook without
  /// clobbering hooks added via [addDraftFlushHook].
  void registerDraftFlushHook(Future<void> Function()? hook) {
    if (_legacyDraftFlushHook != null) {
      _draftFlushHooks.remove(_legacyDraftFlushHook);
    }
    _legacyDraftFlushHook = hook;
    if (hook != null) {
      _draftFlushHooks.add(hook);
    }
  }

  /// Flushes all currently registered draft-flush hooks in registration order.
  Future<void> flushPendingDrafts() async {
    final firstError = await _runDraftFlushHooks();
    if (firstError != null) {
      throw firstError;
    }
  }

  Future<Object?> _runDraftFlushHooks() async {
    Object? firstError;
    for (final hook in List<Future<void> Function()>.of(_draftFlushHooks)) {
      try {
        await hook();
      } catch (error) {
        firstError ??= error;
      }
    }
    return firstError;
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
            '通道隔离保护（channel_mismatch）：所配置的数据文件夹与受保护通道目录重叠，已拒绝打开。';
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
      _vaultErrorMessage = '无法打开数据文件夹：$error';
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
    _resubscribeMemoEntries();
    _resubscribeNoteEntries();
    await refreshAll();
    await _syncController.attachVault(vault);
  }

  void _resubscribeMemoEntries() {
    _memoEntriesSub?.cancel();
    _memoEntriesSub = null;
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    _memoEntriesSub = activeVault.raw
        .watchEntries(_buildMemoEntryQuery())
        .listen((list) {
          _memoEntries = List<RawEntry>.unmodifiable(list);
          _safeNotify();
          _scheduleMetadataRefresh();
        }, onError: (_) {});
  }

  void _resubscribeNoteEntries() {
    _noteEntriesSub?.cancel();
    _noteEntriesSub = null;
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    final isTrash = _selectedNoteFilter == NoteFilterKind.trash;
    _noteEntriesSub = activeVault.raw
        .watchEntries(_buildNoteEntryQuery())
        .listen((list) {
          _noteEntries = _sortNoteEntries(list, isTrash: isTrash);
          _safeNotify();
          _scheduleMetadataRefresh();
        }, onError: (_) {});
  }

  static DateTime _localTodayStartUtc() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).toUtc();
  }

  static DateTime _localTodayEndUtc() {
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day + 1,
    ).toUtc().subtract(const Duration(microseconds: 1));
  }

  static bool _isCreatedTodayLocal(RawEntry entry) {
    final localCreated = entry.createdAtUtc.toLocal();
    final now = DateTime.now();
    return localCreated.year == now.year &&
        localCreated.month == now.month &&
        localCreated.day == now.day;
  }

  static List<RawEntry> _sortNoteEntries(
    List<RawEntry> raw, {
    required bool isTrash,
  }) {
    if (isTrash) {
      return List<RawEntry>.unmodifiable(raw);
    }
    final sorted = List<RawEntry>.of(raw)
      ..sort((a, b) {
        final cmp = b.updatedAtUtc.compareTo(a.updatedAtUtc);
        if (cmp != 0) {
          return cmp;
        }
        return b.id.compareTo(a.id);
      });
    return List<RawEntry>.unmodifiable(sorted);
  }

  EntryQuery _buildMemoEntryQuery() {
    switch (_selectedMemoFilter) {
      case MemoFilterKind.all:
        return const EntryQuery(kinds: memoEntryKinds, limit: _queryLimit);
      case MemoFilterKind.today:
        return EntryQuery(
          kinds: memoEntryKinds,
          dateFromUtc: _localTodayStartUtc(),
          dateToUtc: _localTodayEndUtc(),
          limit: _queryLimit,
        );
      case MemoFilterKind.privateOnly:
        return const EntryQuery(
          kinds: memoEntryKinds,
          privacyFilter: PrivacyLevel.private,
          limit: _queryLimit,
        );
      case MemoFilterKind.tag:
        return EntryQuery(
          kinds: memoEntryKinds,
          tag: _selectedMemoTag,
          limit: _queryLimit,
        );
      case MemoFilterKind.trash:
        return const EntryQuery(
          kinds: memoEntryKinds,
          onlyDeleted: true,
          limit: _queryLimit,
        );
    }
  }

  EntryQuery _buildNoteEntryQuery() {
    switch (_selectedNoteFilter) {
      case NoteFilterKind.all:
        return const EntryQuery(kinds: noteEntryKinds, limit: _queryLimit);
      case NoteFilterKind.privateOnly:
        return const EntryQuery(
          kinds: noteEntryKinds,
          privacyFilter: PrivacyLevel.private,
          limit: _queryLimit,
        );
      case NoteFilterKind.tag:
        return EntryQuery(
          kinds: noteEntryKinds,
          tag: _selectedNoteTag,
          limit: _queryLimit,
        );
      case NoteFilterKind.trash:
        return const EntryQuery(
          kinds: noteEntryKinds,
          onlyDeleted: true,
          limit: _queryLimit,
        );
    }
  }

  void _scheduleMetadataRefresh() {
    if (_metadataRefreshInFlight) {
      _metadataRefreshQueued = true;
      return;
    }
    unawaited(_refreshMetadataLists());
  }

  Future<void> refreshAll() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    try {
      final isNoteTrash = _selectedNoteFilter == NoteFilterKind.trash;
      final results = await Future.wait<Object>(<Future<Object>>[
        activeVault.getStats(),
        activeVault.raw.listEntries(_buildMemoEntryQuery()),
        activeVault.raw.listEntries(_buildNoteEntryQuery()),
        activeVault.blobs.listBlobs(limit: _queryLimit),
        activeVault.raw.listEntries(
          const EntryQuery(includeDeleted: true, limit: _metadataScanLimit),
        ),
      ]);
      _stats = results[0] as VaultStats;
      _memoEntries = List<RawEntry>.unmodifiable(results[1] as List<RawEntry>);
      _noteEntries = _sortNoteEntries(
        results[2] as List<RawEntry>,
        isTrash: isNoteTrash,
      );
      _blobs = List<MediaBlob>.unmodifiable(results[3] as List<MediaBlob>);
      _applyMetadataSnapshot(results[4] as List<RawEntry>);
      _mirrorStatus = activeVault.mirror.currentStatus;
      _safeNotify();
    } catch (_) {}
  }

  Future<void> _refreshMetadataLists() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    _metadataRefreshInFlight = true;
    try {
      do {
        _metadataRefreshQueued = false;
        final currentVault = _vault;
        if (currentVault == null || !currentVault.isOpen || _isDisposed) {
          break;
        }
        final results = await Future.wait<Object>(<Future<Object>>[
          currentVault.blobs.listBlobs(limit: _queryLimit),
          currentVault.raw.listEntries(
            const EntryQuery(includeDeleted: true, limit: _metadataScanLimit),
          ),
        ]);
        _blobs = List<MediaBlob>.unmodifiable(results[0] as List<MediaBlob>);
        _applyMetadataSnapshot(results[1] as List<RawEntry>);
        _safeNotify();
      } while (_metadataRefreshQueued && !_isDisposed);
    } catch (_) {
    } finally {
      _metadataRefreshInFlight = false;
    }
  }

  void _applyMetadataSnapshot(List<RawEntry> allEntries) {
    final byId = <String, RawEntry>{};
    final memoTags = <String, int>{};
    final noteTags = <String, int>{};
    final allTags = <String, int>{};
    final referrers = <String, List<RawEntry>>{};

    var totalMemos = 0;
    var todayMemos = 0;
    var privateMemos = 0;
    var trashMemos = 0;

    var totalNotes = 0;
    var privateNotes = 0;
    var trashNotes = 0;

    for (final entry in allEntries) {
      byId[entry.id] = entry;
      if (entry.audioBlobSha256 != null && entry.audioBlobSha256!.isNotEmpty) {
        referrers
            .putIfAbsent(entry.audioBlobSha256!, () => <RawEntry>[])
            .add(entry);
      }
      for (final sha in entry.imageBlobSha256s) {
        referrers.putIfAbsent(sha, () => <RawEntry>[]).add(entry);
      }

      final isNote = isNoteKind(entry.entryKind);
      if (entry.isDeleted) {
        if (isNote) {
          trashNotes++;
        } else {
          trashMemos++;
        }
        continue;
      }

      if (isNote) {
        totalNotes++;
        if (entry.isPrivate) {
          privateNotes++;
        }
      } else {
        totalMemos++;
        if (_isCreatedTodayLocal(entry)) {
          todayMemos++;
        }
        if (entry.isPrivate) {
          privateMemos++;
        }
      }

      final parsed = _bfm.parse(entry.bodyMd);
      for (final tag in parsed.tags) {
        allTags[tag] = (allTags[tag] ?? 0) + 1;
        if (isNote) {
          noteTags[tag] = (noteTags[tag] ?? 0) + 1;
        } else {
          memoTags[tag] = (memoTags[tag] ?? 0) + 1;
        }
      }
    }

    _entriesById = byId;
    _totalMemoCount = totalMemos;
    _todayMemoCount = todayMemos;
    _privateMemoCount = privateMemos;
    _trashMemoCount = trashMemos;
    _memoTagCounts = Map<String, int>.unmodifiable(memoTags);

    _totalNoteCount = totalNotes;
    _privateNoteCount = privateNotes;
    _trashNoteCount = trashNotes;
    _noteTagCounts = Map<String, int>.unmodifiable(noteTags);

    _tagCounts = Map<String, int>.unmodifiable(allTags);
    _blobReferrers = referrers;
  }

  void setDestination(BlinkNavDestination next) {
    if (_destination == next) {
      return;
    }
    _destination = next;
    _safeNotify();
  }

  void selectSettingsCategory(SettingsCategory category) {
    if (_selectedSettingsCategory == category) {
      return;
    }
    _selectedSettingsCategory = category;
    _safeNotify();
  }

  void openSettingsCategory(SettingsCategory category) {
    final changed =
        _destination != BlinkNavDestination.settings ||
        _selectedSettingsCategory != category;
    if (!changed) {
      return;
    }
    _destination = BlinkNavDestination.settings;
    _selectedSettingsCategory = category;
    _safeNotify();
  }

  void setNoteEditorMode(NoteEditorMode mode, {bool persist = true}) {
    final modeChanged = _noteEditorMode != mode;
    final defaultChanged =
        persist && lifecycle.settings.defaultNoteEditorMode != mode;
    if (!modeChanged && !defaultChanged) {
      return;
    }
    _noteEditorMode = mode;
    if (persist) {
      _lastSyncedDefaultEditorMode = mode;
      lifecycle.updateDefaultNoteEditorMode(mode);
    }
    _safeNotify();
  }

  void toggleNoteEditorMode({bool persist = true}) {
    final next = _noteEditorMode == NoteEditorMode.wysiwyg
        ? NoteEditorMode.source
        : NoteEditorMode.wysiwyg;
    setNoteEditorMode(next, persist: persist);
  }

  void setDefaultNoteEditorMode(NoteEditorMode mode) {
    setNoteEditorMode(mode, persist: true);
  }

  void toggleSidebarCollapsed() {
    _sidebarCollapsed = !_sidebarCollapsed;
    _safeNotify();
  }

  void setSidebarCollapsed(bool collapsed) {
    if (_sidebarCollapsed == collapsed) {
      return;
    }
    _sidebarCollapsed = collapsed;
    _safeNotify();
  }

  void selectMemoFilter(MemoFilterKind filter, {String? tag}) {
    _selectedMemoFilter = filter;
    _selectedMemoTag = filter == MemoFilterKind.tag ? tag : null;
    if (filter == MemoFilterKind.trash) {
      _selectedMemoId = null;
    }
    _resubscribeMemoEntries();
    _safeNotify();
    unawaited(refreshAll());
  }

  void selectMemo(String? entryId) {
    if (_selectedMemoId == entryId && _selectedEntryId == entryId) {
      return;
    }
    _selectedMemoId = entryId;
    _selectedEntryId = entryId;
    _safeNotify();
  }

  void selectNoteFilter(NoteFilterKind filter, {String? tag}) {
    _selectedNoteFilter = filter;
    _selectedNoteTag = filter == NoteFilterKind.tag ? tag : null;
    if (filter == NoteFilterKind.trash) {
      _selectedNoteId = null;
    }
    _resubscribeNoteEntries();
    _safeNotify();
    unawaited(refreshAll());
  }

  void selectNote(String? id) {
    if (_selectedNoteId == id && _selectedEntryId == id) {
      return;
    }
    _selectedNoteId = id;
    _selectedEntryId = id;
    _safeNotify();
  }

  void selectEntry(String? entryId) {
    if (_selectedEntryId == entryId) {
      return;
    }
    _selectedEntryId = entryId;
    if (entryId == null) {
      if (_destination == BlinkNavDestination.notes) {
        _selectedNoteId = null;
      } else if (_destination == BlinkNavDestination.memos) {
        _selectedMemoId = null;
      }
    } else {
      final cached = _entriesById[entryId];
      if (cached != null) {
        if (isNoteKind(cached.entryKind)) {
          _selectedNoteId = entryId;
        } else {
          _selectedMemoId = entryId;
        }
      }
    }
    _safeNotify();
  }

  /// Looks up [entryId] (active or trashed) and automatically routes to `memos`
  /// (`blink`/`voiceNote`/`photoNote`) or `notes` (`diary` + selects note).
  Future<RawEntry?> openEntryById(String entryId) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return null;
    }
    final found = await activeVault.raw.getEntryById(
      entryId,
      includeDeleted: true,
    );
    if (found == null) {
      showBanner('找不到对应内容，可能已被彻底删除。', isError: true);
      return null;
    }

    _entriesById = <String, RawEntry>{..._entriesById, found.id: found};

    if (isNoteKind(found.entryKind)) {
      _destination = BlinkNavDestination.notes;
      if (found.isDeleted) {
        _selectedNoteFilter = NoteFilterKind.trash;
        _selectedNoteTag = null;
      } else if (_selectedNoteFilter == NoteFilterKind.trash ||
          (_selectedNoteFilter == NoteFilterKind.privateOnly &&
              !found.isPrivate) ||
          _selectedNoteFilter == NoteFilterKind.tag) {
        _selectedNoteFilter = NoteFilterKind.all;
        _selectedNoteTag = null;
      }
      _selectedNoteId = found.id;
      _pendingMobileNoteOpenId = found.id;
      _resubscribeNoteEntries();
    } else {
      _destination = BlinkNavDestination.memos;
      if (found.isDeleted) {
        _selectedMemoFilter = MemoFilterKind.trash;
        _selectedMemoTag = null;
      } else if (_selectedMemoFilter == MemoFilterKind.trash ||
          (_selectedMemoFilter == MemoFilterKind.privateOnly &&
              !found.isPrivate) ||
          _selectedMemoFilter == MemoFilterKind.tag ||
          (_selectedMemoFilter == MemoFilterKind.today &&
              !_isCreatedTodayLocal(found))) {
        _selectedMemoFilter = MemoFilterKind.all;
        _selectedMemoTag = null;
      }
      _selectedMemoId = found.id;
      _resubscribeMemoEntries();
    }

    _selectedEntryId = found.id;
    _searchModalOpen = false;
    _safeNotify();
    await refreshAll();
    return found;
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

  Future<RawEntry?> createMemo({
    required String bodyMd,
    bool isPrivate = false,
    List<String> imageBlobSha256s = const <String>[],
    String? audioBlobSha256,
    EntryKind entryKind = EntryKind.blink,
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('数据文件夹未就绪，无法保存小记。', isError: true);
      return null;
    }
    final effectiveKind = isNoteKind(entryKind) ? EntryKind.blink : entryKind;
    try {
      final created = await activeVault.raw.createEntry(
        bodyMd: bodyMd,
        entryKind: effectiveKind,
        privacyLocked: isPrivate,
        audioBlobSha256: audioBlobSha256,
        imageBlobSha256s: imageBlobSha256s,
      );
      _entriesById = <String, RawEntry>{..._entriesById, created.id: created};
      if (_selectedMemoFilter == MemoFilterKind.trash) {
        _selectedMemoFilter = MemoFilterKind.all;
        _selectedMemoTag = null;
        _resubscribeMemoEntries();
      }
      await refreshAll();
      return created;
    } on BlinkException catch (error) {
      showBanner('保存小记失败：${error.message}', isError: true);
      return null;
    }
  }

  Future<RawEntry?> updateMemo(
    String entryId, {
    required String bodyMd,
    bool? isPrivate,
    List<String>? imageBlobSha256s,
    bool allowPrivacyDowngrade = false,
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('数据文件夹未就绪，无法更新小记。', isError: true);
      return null;
    }
    try {
      final updated = await activeVault.raw.updateEntry(
        id: entryId,
        bodyMd: bodyMd,
        privacyLocked: isPrivate,
        imageBlobSha256s: imageBlobSha256s,
        allowPrivacyDowngrade: allowPrivacyDowngrade,
      );
      _entriesById = <String, RawEntry>{..._entriesById, updated.id: updated};
      await refreshAll();
      return updated;
    } on BlinkException catch (error) {
      showBanner('更新小记失败：${error.message}', isError: true);
      return null;
    }
  }

  Future<RawEntry?> createNote({
    String bodyMd = '',
    bool isPrivate = false,
    List<String> imageBlobSha256s = const <String>[],
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('数据文件夹未就绪，无法新建笔记。', isError: true);
      return null;
    }
    try {
      final created = await activeVault.raw.createEntry(
        bodyMd: bodyMd,
        entryKind: EntryKind.diary,
        privacyLocked: isPrivate,
        imageBlobSha256s: imageBlobSha256s,
      );
      _entriesById = <String, RawEntry>{..._entriesById, created.id: created};
      if (_selectedNoteFilter == NoteFilterKind.trash ||
          _selectedNoteFilter == NoteFilterKind.tag ||
          (_selectedNoteFilter == NoteFilterKind.privateOnly &&
              !created.isPrivate)) {
        _selectedNoteFilter = NoteFilterKind.all;
        _selectedNoteTag = null;
        _resubscribeNoteEntries();
      }
      _selectedNoteId = created.id;
      _selectedEntryId = created.id;
      _pendingMobileNoteOpenId = created.id;
      _safeNotify();
      await refreshAll();
      return created;
    } on BlinkException catch (error) {
      showBanner('新建笔记失败：${error.message}', isError: true);
      return null;
    }
  }

  Future<RawEntry?> updateNote(
    String entryId, {
    required String bodyMd,
    bool? isPrivate,
    List<String>? imageBlobSha256s,
    bool allowPrivacyDowngrade = false,
  }) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('数据文件夹未就绪，无法保存笔记。', isError: true);
      return null;
    }
    try {
      final updated = await activeVault.raw.updateEntry(
        id: entryId,
        bodyMd: bodyMd,
        entryKind: EntryKind.diary,
        privacyLocked: isPrivate,
        imageBlobSha256s: imageBlobSha256s,
        allowPrivacyDowngrade: allowPrivacyDowngrade,
      );
      _entriesById = <String, RawEntry>{..._entriesById, updated.id: updated};
      await refreshAll();
      return updated;
    } on BlinkException catch (error) {
      showBanner('保存笔记失败：${error.message}', isError: true);
      return null;
    }
  }

  /// Creates a new long-form note (`EntryKind.diary`) derived from [memo] with
  /// a backlink to the original memo, without modifying or deleting [memo]
  /// (`INV-01`), inheriting `#private` protection when [memo] is private
  /// (`INV-03`), then switches to [BlinkNavDestination.notes] and selects it.
  Future<RawEntry?> promoteMemoToNote(RawEntry memo) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      showBanner('数据文件夹未就绪，无法转为笔记。', isError: true);
      return null;
    }
    final trimmedMemo = memo.bodyMd.trimRight();
    final backlinkLine = '> 来源小记：[[entry:${memo.id}|查看原小记]]';
    final noteBody = trimmedMemo.isEmpty
        ? backlinkLine
        : '$trimmedMemo\n\n$backlinkLine';

    try {
      final created = await activeVault.raw.createEntry(
        bodyMd: noteBody,
        entryKind: EntryKind.diary,
        privacyLocked: memo.isPrivate,
        imageBlobSha256s: memo.imageBlobSha256s,
      );
      _entriesById = <String, RawEntry>{..._entriesById, created.id: created};
      _destination = BlinkNavDestination.notes;
      if (_selectedNoteFilter == NoteFilterKind.trash ||
          _selectedNoteFilter == NoteFilterKind.tag ||
          (_selectedNoteFilter == NoteFilterKind.privateOnly &&
              !created.isPrivate)) {
        _selectedNoteFilter = NoteFilterKind.all;
        _selectedNoteTag = null;
        _resubscribeNoteEntries();
      }
      _selectedNoteId = created.id;
      _selectedEntryId = created.id;
      _pendingMobileNoteOpenId = created.id;
      showBanner('已转为笔记，原小记保留在记录中。');
      await refreshAll();
      return created;
    } on BlinkException catch (error) {
      showBanner('转为笔记失败：${error.message}', isError: true);
      return null;
    }
  }

  Future<RawEntry?> createEntry({
    required String bodyMd,
    EntryKind entryKind = EntryKind.blink,
    bool privacyLocked = false,
    List<String> imageBlobSha256s = const <String>[],
  }) async {
    if (isNoteKind(entryKind)) {
      return createNote(
        bodyMd: bodyMd,
        isPrivate: privacyLocked,
        imageBlobSha256s: imageBlobSha256s,
      );
    }
    return createMemo(
      bodyMd: bodyMd,
      isPrivate: privacyLocked,
      imageBlobSha256s: imageBlobSha256s,
      entryKind: entryKind,
    );
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
      showBanner('数据文件夹未就绪，无法更新内容。', isError: true);
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
      _entriesById = <String, RawEntry>{..._entriesById, updated.id: updated};
      await refreshAll();
      return updated;
    } on BlinkException catch (error) {
      showBanner('更新失败：${error.message}', isError: true);
      return null;
    }
  }

  /// Toggles an inline task checkbox line inside [entry] and persists the
  /// updated Markdown so `raw_tasks` and source text stay synchronized.
  Future<RawEntry?> toggleEntryTaskLine(
    RawEntry entry, {
    required int lineIndex,
    required TaskStatus nextStatus,
  }) async {
    final nextBody = _bfm.toggleTaskLine(
      entry.bodyMd,
      lineIndex: lineIndex,
      newStatus: nextStatus,
    );
    if (nextBody == entry.bodyMd) {
      return entry;
    }
    return updateEntry(id: entry.id, bodyMd: nextBody);
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
    if (_selectedMemoId == id) {
      _selectedMemoId = null;
    }
    if (_selectedNoteId == id) {
      _selectedNoteId = null;
    }
    if (_pendingMobileNoteOpenId == id) {
      _pendingMobileNoteOpenId = null;
    }
    showBanner('已移入回收站（保留 30 天），可随时还原。');
    await refreshAll();
  }

  Future<void> restoreEntry(String id) async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return;
    }
    final restored = await activeVault.raw.restoreEntry(id);
    _entriesById = <String, RawEntry>{..._entriesById, restored.id: restored};
    showBanner('已从回收站还原。');
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
    if (_selectedMemoId == id) {
      _selectedMemoId = null;
    }
    if (_selectedNoteId == id) {
      _selectedNoteId = null;
    }
    if (_pendingMobileNoteOpenId == id) {
      _pendingMobileNoteOpenId = null;
    }
    if (_entriesById.containsKey(id)) {
      final nextMap = Map<String, RawEntry>.of(_entriesById)..remove(id);
      _entriesById = nextMap;
    }
    showBanner('已彻底删除并清理未引用附件。');
    await refreshAll();
    return purged;
  }

  Future<int> purgeExpiredTrash() async {
    final activeVault = _vault;
    if (activeVault == null || !activeVault.isOpen) {
      return 0;
    }
    final count = await activeVault.raw.purgeExpiredTrash();
    showBanner(count > 0 ? '已清理 $count 条超过 30 天的回收站内容。' : '当前没有超过 30 天的过期内容。');
    await refreshAll();
    return count;
  }

  Future<MediaBlob?> importFileFromPicker({
    bool attachToSelectedEntry = false,
  }) async {
    final picked = await filePicker.pickFileToOpen(title: '选择要导入的附件');
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
      showBanner('数据文件夹未就绪，无法导入附件。', isError: true);
      return null;
    }
    if (!await sourceFile.exists()) {
      showBanner('所选文件不存在，无法导入。', isError: true);
      return null;
    }
    try {
      final mime = inferMimeTypeFromPath(sourceFile.path);
      final blob = await activeVault.blobs.putFile(sourceFile, mimeType: mime);
      final targetEntryId = _destination == BlinkNavDestination.notes
          ? (_selectedNoteId ?? _selectedEntryId)
          : (_selectedMemoId ?? _selectedEntryId);
      if (attachToSelectedEntry && targetEntryId != null) {
        await attachBlobToEntry(targetEntryId, blob.sha256);
      }
      showBanner('附件已去重保存。');
      await refreshAll();
      return blob;
    } on BlinkException catch (error) {
      showBanner('导入附件失败：${error.message}', isError: true);
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
      showBanner('该附件已关联到当前内容。');
      return true;
    }
    final nextList = <String>[...entry.imageBlobSha256s, sha256];
    await activeVault.raw.updateEntry(
      id: entry.id,
      bodyMd: entry.bodyMd,
      imageBlobSha256s: nextList,
    );
    showBanner('附件已关联到当前内容。');
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
        showBanner('导出附件失败：无法写入所选位置。', isError: true);
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
    showBanner(removed > 0 ? '已清理 $removed 个未引用附件。' : '当前没有可清理的未引用附件。');
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
      showBanner('当前进程已通过环境变量锁定数据文件夹，暂不支持在设置内切换。', isError: true);
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
      showBanner('当前已打开该数据文件夹。');
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
        await _runDraftFlushHooks();
        try {
          await previous.mirror.flushNow();
        } catch (_) {}
      }
      _vaultErrorCode = null;
      _vaultErrorMessage = null;
      _ownsVault = true;
      _selectedEntryId = null;
      _selectedMemoId = null;
      _selectedNoteId = null;
      _pendingMobileNoteOpenId = null;
      _selectedMemoFilter = MemoFilterKind.all;
      _selectedMemoTag = null;
      _selectedNoteFilter = NoteFilterKind.all;
      _selectedNoteTag = null;
      await _attachVault(candidate);
      if (previous != null && previousOwned && previous.isOpen) {
        await previous.checkpointAndClose();
      }
      lifecycle.updateCustomVaultPath(trimmed);
      showBanner('已切换数据文件夹。');
      return true;
    } on BlinkException catch (error) {
      _vaultErrorCode = error.code;
      _vaultErrorMessage = _formatVaultError(error);
      showBanner(_vaultErrorMessage!, isError: true);
      return false;
    } catch (error) {
      _vaultErrorCode = BlinkErrorCode.ioError;
      _vaultErrorMessage = '切换数据文件夹失败：$error';
      showBanner(_vaultErrorMessage!, isError: true);
      return false;
    } finally {
      _isLoading = false;
      _safeNotify();
    }
  }

  Future<bool> pickAndSwitchVaultDirectory() async {
    final dirPath = await filePicker.pickDirectory(title: '选择 BLINK 数据文件夹');
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
      showBanner('已完成数据备份（${formatByteSize(result.byteSize)}）。');
      return result;
    } on BlinkException catch (error) {
      showBanner('数据备份失败：${error.message}', isError: true);
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
      showBanner('已重建搜索索引并刷新 Markdown 导出，原内容未作改动。');
      await refreshAll();
      return true;
    } on BlinkException catch (error) {
      showBanner('重建搜索索引失败：${error.message}', isError: true);
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
      showBanner('已完成 Markdown 自动导出。');
      await refreshAll();
      return true;
    } catch (error) {
      showBanner('Markdown 导出失败：$error', isError: true);
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
    firstError ??= await _runDraftFlushHooks();
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
        return '版本不兼容（protocol_mismatch）：目标数据文件夹由更新版本的 BLINK 创建，请先升级客户端。';
      default:
        return '打开数据文件夹失败（${error.code.wireCode}）：${error.message}';
    }
  }

  Future<void> _cancelSubscriptions() async {
    await _statsSub?.cancel();
    await _mirrorSub?.cancel();
    await _memoEntriesSub?.cancel();
    await _noteEntriesSub?.cancel();
    _statsSub = null;
    _mirrorSub = null;
    _memoEntriesSub = null;
    _noteEntriesSub = null;
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _draftFlushHooks.clear();
    _legacyDraftFlushHook = null;
    lifecycle.removeListener(_onLifecycleChanged);
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
