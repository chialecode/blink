import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/tasks_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';

/// Feishu-style Pane 2 resource sidebar for the Tasks (`待办`) module.
class BlinkTasksSidebar extends StatefulWidget {
  const BlinkTasksSidebar({
    required this.controller,
    this.isDrawer = false,
    this.onItemSelected,
    this.onCollapse,
    super.key,
  });

  final BlinkTasksController controller;
  final bool isDrawer;
  final VoidCallback? onItemSelected;
  final VoidCallback? onCollapse;

  @override
  State<BlinkTasksSidebar> createState() => _BlinkTasksSidebarState();
}

class _BlinkTasksSidebarState extends State<BlinkTasksSidebar> {
  Map<TaskStatus, int> _countsByStatus = const <TaskStatus, int>{};
  int _totalCount = 0;
  bool _hasFetchedCounts = false;
  int _countEpoch = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncCounts();
  }

  @override
  void didUpdateWidget(covariant BlinkTasksSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncCounts();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    _syncCounts();
  }

  void _syncCounts() {
    if (widget.controller.statusFilter == null) {
      _applyTaskListCounts(widget.controller.tasks);
      return;
    }
    unawaited(_refreshAllStatusCounts());
  }

  void _applyTaskListCounts(List<RawTask> allTasks) {
    final counts = <TaskStatus, int>{
      TaskStatus.open: 0,
      TaskStatus.deferred: 0,
      TaskStatus.done: 0,
      TaskStatus.dropped: 0,
    };
    for (final task in allTasks) {
      counts[task.status] = (counts[task.status] ?? 0) + 1;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _countsByStatus = counts;
      _totalCount = allTasks.length;
      _hasFetchedCounts = true;
    });
  }

  Future<void> _refreshAllStatusCounts() async {
    final vault = widget.controller.vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    final epoch = ++_countEpoch;
    try {
      final all = await vault.raw.listTasks(
        TaskQuery(privacyFilter: widget.controller.privacyFilter),
      );
      if (!mounted || epoch != _countEpoch) {
        return;
      }
      _applyTaskListCounts(all);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final activeStatus = widget.controller.statusFilter;
        final privateOnly =
            widget.controller.privacyFilter == PrivacyLevel.private;

        final int totalCount;
        final int openCount;
        final int deferredCount;
        final int doneCount;
        final int droppedCount;

        if (activeStatus == null || !_hasFetchedCounts) {
          totalCount = widget.controller.tasks.length;
          openCount = widget.controller.tasksForStatus(TaskStatus.open).length;
          deferredCount = widget.controller
              .tasksForStatus(TaskStatus.deferred)
              .length;
          doneCount = widget.controller.tasksForStatus(TaskStatus.done).length;
          droppedCount = widget.controller
              .tasksForStatus(TaskStatus.dropped)
              .length;
        } else {
          totalCount = _totalCount;
          openCount = _countsByStatus[TaskStatus.open] ?? 0;
          deferredCount = _countsByStatus[TaskStatus.deferred] ?? 0;
          doneCount = _countsByStatus[TaskStatus.done] ?? 0;
          droppedCount = _countsByStatus[TaskStatus.dropped] ?? 0;
        }

        Widget statusRow({
          required Key itemKey,
          required TaskStatus? status,
          required IconData icon,
          required String label,
          required int count,
          Color? iconAccent,
        }) {
          final selected = activeStatus == status;
          final fg = selected ? tokens.accentPrimary : tokens.textPrimary;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              key: itemKey,
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                widget.controller.setStatusFilter(status);
                widget.onItemSelected?.call();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: selected ? tokens.accentSubtle : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      icon,
                      size: 16,
                      color: selected
                          ? tokens.accentPrimary
                          : (iconAccent ?? tokens.textSecondary),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.controlLabel(tokens)
                            .copyWith(color: fg),
                      ),
                    ),
                    Text(
                      '$count',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: selected
                            ? tokens.accentPrimary
                            : tokens.textMuted,
                      ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '待办',
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                  ),
                  if (!widget.isDrawer && widget.onCollapse != null)
                    IconButton(
                      key: const Key('tasks_sidebar_collapse_button'),
                      tooltip: '收起侧边栏',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onCollapse,
                      icon: Icon(
                        Icons.keyboard_double_arrow_left_rounded,
                        size: 18,
                        color: tokens.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.borderHairline),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
                children: <Widget>[
                  statusRow(
                    itemKey: const Key('tasks_filter_all'),
                    status: null,
                    icon: Icons.checklist_rounded,
                    label: '全部待办',
                    count: totalCount,
                  ),
                  statusRow(
                    itemKey: const Key('tasks_filter_open'),
                    status: TaskStatus.open,
                    icon: Icons.radio_button_unchecked_rounded,
                    label: '待完成',
                    count: openCount,
                  ),
                  statusRow(
                    itemKey: const Key('tasks_filter_deferred'),
                    status: TaskStatus.deferred,
                    icon: Icons.schedule_rounded,
                    label: '稍后处理',
                    count: deferredCount,
                    iconAccent: tokens.statusWarn,
                  ),
                  statusRow(
                    itemKey: const Key('tasks_filter_done'),
                    status: TaskStatus.done,
                    icon: Icons.check_circle_outline_rounded,
                    label: '已完成',
                    count: doneCount,
                    iconAccent: tokens.statusOk,
                  ),
                  statusRow(
                    itemKey: const Key('tasks_filter_dropped'),
                    status: TaskStatus.dropped,
                    icon: Icons.remove_circle_outline_rounded,
                    label: '已取消',
                    count: droppedCount,
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: tokens.borderHairline),
                  const SizedBox(height: 8),
                  InkWell(
                    key: const Key('tasks_filter_private_toggle'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      widget.controller.setPrivacyFilter(
                        privateOnly ? null : PrivacyLevel.private,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: privateOnly
                            ? tokens.privacySubtle
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                            color: privateOnly
                                ? tokens.privacyPrivate
                                : tokens.textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '仅看私密 (🔒)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: BlinkTypography.controlLabel(tokens)
                                  .copyWith(
                                    color: privateOnly
                                        ? tokens.privacyPrivate
                                        : tokens.textPrimary,
                                  ),
                            ),
                          ),
                          SizedBox(
                            height: 24,
                            child: Switch.adaptive(
                              value: privateOnly,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (selected) {
                                widget.controller.setPrivacyFilter(
                                  selected ? PrivacyLevel.private : null,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Tasks (`待办`) view collecting checklist items from Memos and Notes
/// with two-way checkbox synchronization (`docs/ui.md`).
class BlinkTasksPage extends StatelessWidget {
  const BlinkTasksPage({
    required this.controller,
    this.workspace,
    this.onJumpToEntry,
    this.showInlineFilters = true,
    this.isMobile = false,
    this.onOpenDrawer,
    this.onOpenSearch,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    super.key,
  });

  final BlinkTasksController controller;
  final BlinkWorkspaceController? workspace;
  final ValueChanged<String>? onJumpToEntry;
  final bool showInlineFilters;
  final bool isMobile;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onOpenSearch;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;

  void _handleJumpToEntry(String entryId) {
    if (onJumpToEntry != null) {
      onJumpToEntry!(entryId);
      return;
    }
    if (workspace != null) {
      unawaited(workspace!.openEntryById(entryId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final openTasks = controller.tasksForStatus(TaskStatus.open);
        final deferredTasks = controller.tasksForStatus(TaskStatus.deferred);
        final doneTasks = controller.tasksForStatus(TaskStatus.done);
        final droppedTasks = controller.tasksForStatus(TaskStatus.dropped);
        final hPad = isMobile ? 14.0 : 20.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: EdgeInsets.fromLTRB(hPad, isMobile ? 10 : 14, hPad, 12),
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  bottom: BorderSide(color: tokens.borderHairline, width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (showExpandSidebarButton &&
                          onExpandSidebar != null) ...<Widget>[
                        IconButton(
                          key: const Key('tasks_sidebar_expand_button'),
                          tooltip: '展开侧边栏',
                          visualDensity: VisualDensity.compact,
                          onPressed: onExpandSidebar,
                          icon: Icon(
                            Icons.view_sidebar_outlined,
                            size: 18,
                            color: tokens.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else if (onOpenDrawer != null) ...<Widget>[
                        IconButton(
                          tooltip: '筛选待办',
                          visualDensity: VisualDensity.compact,
                          onPressed: onOpenDrawer,
                          icon: Icon(
                            Icons.menu_rounded,
                            size: 19,
                            color: tokens.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _headingForStatus(controller.statusFilter),
                              style: BlinkTypography.heroHeading(tokens),
                            ),
                            if (!isMobile) ...<Widget>[
                              const SizedBox(height: 2),
                              Text(
                                '自动收集小记和笔记中的清单项，勾选双向同步',
                                style: BlinkTypography.metaLabel(tokens),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (isMobile && onOpenSearch != null)
                        IconButton(
                          tooltip: '搜索',
                          visualDensity: VisualDensity.compact,
                          onPressed: onOpenSearch,
                          icon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: tokens.textSecondary,
                          ),
                        ),
                    ],
                  ),
                  if (showInlineFilters) ...<Widget>[
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          _statusChip(
                            tokens,
                            null,
                            '全部 (${controller.tasks.length})',
                          ),
                          const SizedBox(width: 6),
                          _statusChip(tokens, TaskStatus.open, '待完成'),
                          const SizedBox(width: 6),
                          _statusChip(tokens, TaskStatus.deferred, '稍后处理'),
                          const SizedBox(width: 6),
                          _statusChip(tokens, TaskStatus.done, '已完成'),
                          const SizedBox(width: 6),
                          _statusChip(tokens, TaskStatus.dropped, '已取消'),
                          const SizedBox(width: 6),
                          FilterChip(
                            label: const Text('🔒 仅私密'),
                            selected:
                                controller.privacyFilter ==
                                PrivacyLevel.private,
                            showCheckmark: false,
                            backgroundColor: tokens.canvas,
                            selectedColor: tokens.privacySubtle,
                            side: BorderSide(
                              color:
                                  controller.privacyFilter ==
                                      PrivacyLevel.private
                                  ? tokens.privacyPrivate
                                  : tokens.borderHairline,
                            ),
                            labelStyle: BlinkTypography.metaLabel(
                              tokens,
                              color:
                                  controller.privacyFilter ==
                                      PrivacyLevel.private
                                  ? tokens.privacyPrivate
                                  : tokens.textSecondary,
                            ),
                            onSelected: (selected) {
                              controller.setPrivacyFilter(
                                selected ? PrivacyLevel.private : null,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (controller.lastError != null)
              Container(
                padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 10),
                color: tokens.statusErrSubtle,
                child: Text(
                  '待办加载异常：${controller.lastError}',
                  style: BlinkTypography.metaLabel(
                    tokens,
                    color: tokens.statusErr,
                  ),
                ),
              ),
            Expanded(
              child: controller.tasks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '暂无待办事项。在小记或笔记中写下 “- [ ] 待办事项” 即可自动收集到这里。',
                          textAlign: TextAlign.center,
                          style: BlinkTypography.body(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: EdgeInsets.all(hPad),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 780),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              if (openTasks.isNotEmpty)
                                _TaskGroupSection(
                                  title: '待完成（${openTasks.length}）',
                                  tasks: openTasks,
                                  controller: controller,
                                  onJumpToEntry: _handleJumpToEntry,
                                ),
                              if (deferredTasks.isNotEmpty)
                                _TaskGroupSection(
                                  title: '稍后处理（${deferredTasks.length}）',
                                  tasks: deferredTasks,
                                  controller: controller,
                                  onJumpToEntry: _handleJumpToEntry,
                                ),
                              if (doneTasks.isNotEmpty)
                                _TaskGroupSection(
                                  title: '已完成（${doneTasks.length}）',
                                  tasks: doneTasks,
                                  controller: controller,
                                  onJumpToEntry: _handleJumpToEntry,
                                ),
                              if (droppedTasks.isNotEmpty)
                                _TaskGroupSection(
                                  title: '已取消（${droppedTasks.length}）',
                                  tasks: droppedTasks,
                                  controller: controller,
                                  onJumpToEntry: _handleJumpToEntry,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  String _headingForStatus(TaskStatus? status) {
    switch (status) {
      case null:
        return '待办';
      case TaskStatus.open:
        return '待完成';
      case TaskStatus.deferred:
        return '稍后处理';
      case TaskStatus.done:
        return '已完成';
      case TaskStatus.dropped:
        return '已取消';
    }
  }

  Widget _statusChip(
    BlinkColorTokens tokens,
    TaskStatus? status,
    String label,
  ) {
    final selected = controller.statusFilter == status;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      backgroundColor: tokens.canvas,
      selectedColor: tokens.accentSubtle,
      side: BorderSide(
        color: selected ? tokens.accentPrimary : tokens.borderHairline,
      ),
      labelStyle: BlinkTypography.metaLabel(
        tokens,
        color: selected ? tokens.accentPrimary : tokens.textSecondary,
      ),
      onSelected: (_) => controller.setStatusFilter(status),
    );
  }
}

class _TaskGroupSection extends StatelessWidget {
  const _TaskGroupSection({
    required this.title,
    required this.tasks,
    required this.controller,
    required this.onJumpToEntry,
  });

  final String title;
  final List<RawTask> tasks;
  final BlinkTasksController controller;
  final ValueChanged<String> onJumpToEntry;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(title, style: BlinkTypography.sectionHeading(tokens)),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: <Widget>[
                for (var i = 0; i < tasks.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: tokens.borderHairline),
                  _TaskRow(
                    task: tasks[i],
                    onToggle: () => controller.toggleOpenDone(tasks[i]),
                    onChangeStatus: (next) =>
                        controller.updateStatus(tasks[i].id, next),
                    onJumpToEntry: tasks[i].originEntryId == null
                        ? null
                        : () => onJumpToEntry(tasks[i].originEntryId!),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.onToggle,
    required this.onChangeStatus,
    this.onJumpToEntry,
  });

  final RawTask task;
  final VoidCallback onToggle;
  final ValueChanged<TaskStatus> onChangeStatus;
  final VoidCallback? onJumpToEntry;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final isDone = task.status == TaskStatus.done;
    final isDropped = task.status == TaskStatus.dropped;
    final isDeferred = task.status == TaskStatus.deferred;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        children: <Widget>[
          IconButton(
            key: Key('task_toggle_${task.id}'),
            tooltip: isDone ? '标为待完成' : '标为已完成',
            onPressed: onToggle,
            icon: Icon(
              isDone
                  ? Icons.check_box_rounded
                  : isDeferred
                  ? Icons.schedule_rounded
                  : isDropped
                  ? Icons.indeterminate_check_box_outlined
                  : Icons.check_box_outline_blank_rounded,
              color: isDone
                  ? tokens.statusOk
                  : isDeferred
                  ? tokens.statusWarn
                  : isDropped
                  ? tokens.textMuted
                  : tokens.accentPrimary,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  task.title,
                  style:
                      BlinkTypography.body(
                        tokens,
                        color: (isDone || isDropped)
                            ? tokens.textMuted
                            : tokens.textPrimary,
                      ).copyWith(
                        decoration: (isDone || isDropped)
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                ),
                if (task.isPrivate)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.privacySubtle,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '🔒 私密',
                        style: BlinkTypography.badge(
                          color: tokens.privacyPrivate,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onJumpToEntry != null)
            TextButton.icon(
              key: Key('task_source_${task.id}'),
              onPressed: onJumpToEntry,
              icon: const Icon(Icons.north_east_rounded, size: 14),
              label: const Text('查看来源'),
            ),
          PopupMenuButton<TaskStatus>(
            tooltip: '切换状态',
            icon: Icon(
              Icons.more_horiz_rounded,
              size: 18,
              color: tokens.textSecondary,
            ),
            onSelected: onChangeStatus,
            itemBuilder: (context) => const <PopupMenuEntry<TaskStatus>>[
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.open,
                child: Text('待完成'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.done,
                child: Text('已完成'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.deferred,
                child: Text('稍后处理'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.dropped,
                child: Text('已取消'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
