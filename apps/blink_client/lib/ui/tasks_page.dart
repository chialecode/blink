import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/tasks_controller.dart';

/// Endogenous `- [ ]`/`- [x]`/`- [>]`/`- [-]` tasks view (`docs/ui.md` §4.3).
///
/// Toggling status updates BOTH `raw_tasks` and the originating `raw_entries.body_md`
/// atomically; clicking the source pill jumps directly to the originating entry.
class BlinkTasksPage extends StatelessWidget {
  const BlinkTasksPage({
    required this.controller,
    required this.onJumpToEntry,
    super.key,
  });

  final BlinkTasksController controller;
  final ValueChanged<String> onJumpToEntry;

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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  bottom: BorderSide(color: tokens.borderHairline, width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('内生柔性待办', style: BlinkTypography.heroHeading(tokens)),
                  const SizedBox(height: 2),
                  Text(
                    '从 BFM 笔记中的 - [ ] / - [x] / - [>] / - [-] 自动同步，状态变更双向回写原文。',
                    style: BlinkTypography.metaLabel(tokens),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      _statusChip(
                        tokens,
                        null,
                        '全部 (${controller.tasks.length})',
                      ),
                      _statusChip(tokens, TaskStatus.open, '待办'),
                      _statusChip(tokens, TaskStatus.deferred, '稍后'),
                      _statusChip(tokens, TaskStatus.done, '已完成'),
                      _statusChip(tokens, TaskStatus.dropped, '已放下'),
                      FilterChip(
                        label: const Text('仅 #private'),
                        selected:
                            controller.privacyFilter == PrivacyLevel.private,
                        showCheckmark: false,
                        backgroundColor: tokens.canvas,
                        selectedColor: tokens.privacySubtle,
                        side: BorderSide(
                          color:
                              controller.privacyFilter == PrivacyLevel.private
                              ? tokens.privacyPrivate
                              : tokens.borderHairline,
                        ),
                        labelStyle: BlinkTypography.metaLabel(
                          tokens,
                          color:
                              controller.privacyFilter == PrivacyLevel.private
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
                ],
              ),
            ),
            if (controller.lastError != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
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
                          '暂无内生待办。在采集流笔记中写下 “- [ ] 待办事项” 即可自动出现于此。',
                          textAlign: TextAlign.center,
                          style: BlinkTypography.body(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(20),
                      children: <Widget>[
                        if (openTasks.isNotEmpty)
                          _TaskGroupSection(
                            title: '待办（${openTasks.length}）',
                            tasks: openTasks,
                            controller: controller,
                            onJumpToEntry: onJumpToEntry,
                          ),
                        if (deferredTasks.isNotEmpty)
                          _TaskGroupSection(
                            title: '稍后意图（${deferredTasks.length}）',
                            tasks: deferredTasks,
                            controller: controller,
                            onJumpToEntry: onJumpToEntry,
                          ),
                        if (doneTasks.isNotEmpty)
                          _TaskGroupSection(
                            title: '已完成（${doneTasks.length}）',
                            tasks: doneTasks,
                            controller: controller,
                            onJumpToEntry: onJumpToEntry,
                          ),
                        if (droppedTasks.isNotEmpty)
                          _TaskGroupSection(
                            title: '已放下（${droppedTasks.length}）',
                            tasks: droppedTasks,
                            controller: controller,
                            onJumpToEntry: onJumpToEntry,
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: <Widget>[
          IconButton(
            key: Key('task_toggle_${task.id}'),
            tooltip: isDone ? '标为待办' : '标为已完成',
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
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '🔒 #private',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.privacyPrivate,
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
              label: const Text('源记录'),
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
                child: Text('待办 (- [ ])'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.done,
                child: Text('已完成 (- [x])'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.deferred,
                child: Text('稍后意图 (- [>])'),
              ),
              PopupMenuItem<TaskStatus>(
                value: TaskStatus.dropped,
                child: Text('放下 (- [-])'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
