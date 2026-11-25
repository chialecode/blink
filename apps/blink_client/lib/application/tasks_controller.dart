import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';

/// Manages endogenous `- [ ]`/`- [x]`/`- [>]`/`- [-]` tasks extracted from BFM
/// entries and atomically syncs status toggles back to `raw_entries.body_md`.
class BlinkTasksController extends ChangeNotifier {
  BlinkTasksController({required this.vaultProvider});

  final VaultManager? Function() vaultProvider;

  List<RawTask> _tasks = const <RawTask>[];
  TaskStatus? _statusFilter;
  PrivacyLevel? _privacyFilter;
  bool _isDisposed = false;
  String? _lastError;
  StreamSubscription<List<RawTask>>? _tasksSub;
  VaultManager? _boundVault;

  List<RawTask> get tasks => _tasks;
  TaskStatus? get statusFilter => _statusFilter;
  PrivacyLevel? get privacyFilter => _privacyFilter;
  String? get lastError => _lastError;

  List<RawTask> tasksForStatus(TaskStatus status) =>
      _tasks.where((task) => task.status == status).toList(growable: false);

  /// Binds to the active [VaultManager] if changed and refreshes tasks.
  Future<void> bindVault(VaultManager? vault) async {
    if (identical(_boundVault, vault) && _tasksSub != null) {
      await refresh();
      return;
    }
    await _tasksSub?.cancel();
    _tasksSub = null;
    _boundVault = vault;
    if (vault == null || !vault.isOpen) {
      _tasks = const <RawTask>[];
      _safeNotify();
      return;
    }
    _resubscribe();
    await refresh();
  }

  void _resubscribe() {
    _tasksSub?.cancel();
    _tasksSub = null;
    final vault = _boundVault ?? vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    _tasksSub = vault.raw
        .watchTasks(_buildQuery())
        .listen(
          (items) {
            _tasks = items;
            _lastError = null;
            _safeNotify();
          },
          onError: (Object error) {
            _lastError = error.toString();
            _safeNotify();
          },
        );
  }

  TaskQuery _buildQuery() => TaskQuery(
    statuses: _statusFilter == null ? null : <TaskStatus>[_statusFilter!],
    privacyFilter: _privacyFilter,
  );

  void setStatusFilter(TaskStatus? status) {
    if (_statusFilter == status) {
      return;
    }
    _statusFilter = status;
    _resubscribe();
    _safeNotify();
    unawaited(refresh());
  }

  void setPrivacyFilter(PrivacyLevel? privacy) {
    if (_privacyFilter == privacy) {
      return;
    }
    _privacyFilter = privacy;
    _resubscribe();
    _safeNotify();
    unawaited(refresh());
  }

  Future<void> refresh() async {
    final vault = _boundVault ?? vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    try {
      _tasks = await vault.raw.listTasks(_buildQuery());
      _lastError = null;
      _safeNotify();
    } catch (error) {
      _lastError = error.toString();
      _safeNotify();
    }
  }

  Future<RawTask?> updateStatus(String taskId, TaskStatus status) async {
    final vault = _boundVault ?? vaultProvider();
    if (vault == null || !vault.isOpen) {
      return null;
    }
    try {
      final updated = await vault.raw.updateTaskStatus(
        taskId: taskId,
        status: status,
      );
      await refresh();
      return updated;
    } catch (error) {
      _lastError = error.toString();
      _safeNotify();
      return null;
    }
  }

  Future<RawTask?> toggleOpenDone(RawTask task) async {
    final nextStatus = task.status == TaskStatus.done
        ? TaskStatus.open
        : TaskStatus.done;
    return updateStatus(task.id, nextStatus);
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_tasksSub?.cancel());
    super.dispose();
  }
}
