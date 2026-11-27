import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';

/// Quiet, accessible top-level sync status capsule (`INV-11`, `docs/ui.md` §4.5).
///
/// Always communicates sync state with icon + text + semantics (never color
/// alone) and derives 100% of colors from [BlinkColorTokens].
class BlinkSyncStatusCapsule extends StatelessWidget {
  const BlinkSyncStatusCapsule({
    required this.sync,
    required this.onOpenConflicts,
    required this.onOpenSyncSettings,
    this.compact = false,
    super.key,
  });

  final BlinkSyncController sync;
  final VoidCallback onOpenConflicts;
  final VoidCallback onOpenSyncSettings;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final spec = _describeStatus(sync, tokens);

        return Semantics(
          container: true,
          label: '同步状态：${spec.semanticsLabel}',
          child: Container(
            key: const Key('sync_status_capsule'),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 14,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: spec.background,
              border: Border(
                bottom: BorderSide(color: tokens.borderHairline, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                if (sync.uiStatus == BlinkSyncUiStatus.syncing)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: spec.foreground,
                    ),
                  )
                else
                  Icon(spec.icon, size: 16, color: spec.foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spec.label,
                    key: const Key('sync_status_capsule_label'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: spec.foreground,
                    ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
                  ),
                ),
                if (sync.openConflictCount > 0) ...<Widget>[
                  const SizedBox(width: 6),
                  TextButton.icon(
                    key: const Key('sync_capsule_conflicts_button'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.statusErr,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onOpenConflicts,
                    icon: const Icon(Icons.compare_arrows_rounded, size: 15),
                    label: Text(
                      '处理冲突 (${sync.openConflictCount})',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.statusErr,
                      ),
                    ),
                  ),
                ],
                if (sync.isConfigured) ...<Widget>[
                  const SizedBox(width: 4),
                  TextButton.icon(
                    key: const Key('sync_capsule_sync_now_button'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.accentPrimary,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: sync.isSyncing
                        ? null
                        : () => unawaited(sync.syncNow(manual: true)),
                    icon: const Icon(Icons.sync_rounded, size: 15),
                    label: Text(
                      compact ? '同步' : '立即同步',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: sync.isSyncing
                            ? tokens.textMuted
                            : tokens.accentPrimary,
                      ),
                    ),
                  ),
                ] else ...<Widget>[
                  const SizedBox(width: 4),
                  TextButton(
                    key: const Key('sync_capsule_settings_button'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.textSecondary,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onOpenSyncSettings,
                    child: Text(
                      '同步设置',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Compact sync status dot rendered above Settings on the desktop icon rail
/// (`docs/ui.md` §1).
class BlinkSyncRailDot extends StatelessWidget {
  const BlinkSyncRailDot({required this.sync, required this.onTap, super.key});

  final BlinkSyncController sync;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final spec = _describeStatus(sync, tokens);
        return Tooltip(
          message: spec.label,
          child: Semantics(
            button: true,
            label: '同步状态：${spec.semanticsLabel}',
            child: InkWell(
              key: const Key('rail_sync_status_dot'),
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: SizedBox(
                width: 36,
                height: 32,
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: spec.dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: tokens.borderHairline,
                        width: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SyncStatusPresentation {
  const _SyncStatusPresentation({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.foreground,
    required this.background,
    required this.dotColor,
  });

  final IconData icon;
  final String label;
  final String semanticsLabel;
  final Color foreground;
  final Color background;
  final Color dotColor;
}

_SyncStatusPresentation _describeStatus(
  BlinkSyncController sync,
  BlinkColorTokens tokens,
) {
  final pending = sync.pendingOutboxCount;
  final conflicts = sync.openConflictCount;

  switch (sync.uiStatus) {
    case BlinkSyncUiStatus.unconfigured:
      if (sync.isHostRunning) {
        final port = sync.activeServerPort ?? sync.config.desktopServerPort;
        return _SyncStatusPresentation(
          icon: Icons.dns_outlined,
          label: '桌面直连同步服务运行中（端口 $port）',
          semanticsLabel: '桌面直连同步服务运行中，监听端口 $port',
          foreground: tokens.statusOk,
          background: tokens.statusOkSubtle,
          dotColor: tokens.statusOk,
        );
      }
      return _SyncStatusPresentation(
        icon: Icons.cloud_off_outlined,
        label: pending > 0 ? '仅本机离线 · $pending 项保存在本机' : '仅本机离线 · 未配置同步',
        semanticsLabel: '仅本机离线，未配置同步',
        foreground: tokens.textSecondary,
        background: tokens.sidebar,
        dotColor: tokens.textMuted,
      );
    case BlinkSyncUiStatus.idleSynced:
      return _SyncStatusPresentation(
        icon: Icons.cloud_done_outlined,
        label: sync.lastSkippedPrivateCount > 0
            ? '已同步 · 已跳过 ${sync.lastSkippedPrivateCount} 条 #private 中继'
            : '已同步',
        semanticsLabel: '已同步，无待传变更',
        foreground: tokens.statusOk,
        background: tokens.statusOkSubtle,
        dotColor: tokens.statusOk,
      );
    case BlinkSyncUiStatus.offlinePending:
      return _SyncStatusPresentation(
        icon: Icons.cloud_upload_outlined,
        label: '当前离线 · $pending 项待同步',
        semanticsLabel: '当前离线，本地安全排队 $pending 项待同步',
        foreground: tokens.statusWarn,
        background: tokens.statusWarnSubtle,
        dotColor: tokens.statusWarn,
      );
    case BlinkSyncUiStatus.peerAsleep:
      return _SyncStatusPresentation(
        icon: Icons.bedtime_outlined,
        label: pending > 0 ? '对端休眠 · $pending 项已排队待同步' : '同步对端当前休眠',
        semanticsLabel: '同步对端当前离线或休眠，$pending 项本地变更已安全排队',
        foreground: tokens.statusWarn,
        background: tokens.statusWarnSubtle,
        dotColor: tokens.statusWarn,
      );
    case BlinkSyncUiStatus.syncing:
      final via = sync.activeChannelLabel ?? '同步通道';
      return _SyncStatusPresentation(
        icon: Icons.sync_rounded,
        label: pending > 0 ? '正在经 $via 同步（待传 $pending 项）…' : '正在经 $via 同步…',
        semanticsLabel: '正在经 $via 同步',
        foreground: tokens.accentPrimary,
        background: tokens.accentSubtle,
        dotColor: tokens.accentPrimary,
      );
    case BlinkSyncUiStatus.conflictPending:
      return _SyncStatusPresentation(
        icon: Icons.compare_arrows_rounded,
        label: '$conflicts 条同步冲突待处理（双本全文已保留）',
        semanticsLabel: '存在 $conflicts 条同步冲突待裁定，双本原文已完整保留',
        foreground: tokens.statusErr,
        background: tokens.statusErrSubtle,
        dotColor: tokens.statusErr,
      );
    case BlinkSyncUiStatus.deviceRevoked:
      return _SyncStatusPresentation(
        icon: Icons.gpp_bad_outlined,
        label: '设备令牌已被吊销 · 请重新配对',
        semanticsLabel: '设备同步权限已被吊销，请前往同步设置重新配对',
        foreground: tokens.statusErr,
        background: tokens.statusErrSubtle,
        dotColor: tokens.statusErr,
      );
    case BlinkSyncUiStatus.channelMismatch:
      return _SyncStatusPresentation(
        icon: Icons.block_outlined,
        label: '通道或协议不匹配 · 已停止同步',
        semanticsLabel: '同步节点通道或协议版本不匹配，已拦截',
        foreground: tokens.statusErr,
        background: tokens.statusErrSubtle,
        dotColor: tokens.statusErr,
      );
    case BlinkSyncUiStatus.privacyBlocked:
      return _SyncStatusPresentation(
        icon: Icons.lock_outline_rounded,
        label: '#private 已禁止经云中继同步 · 仅待局域网/Tailscale 直连',
        semanticsLabel: '私密条目已按策略拦截云端中继，仅保留本地等待直连同步',
        foreground: tokens.privacyPrivate,
        background: tokens.privacySubtle,
        dotColor: tokens.privacyPrivate,
      );
    case BlinkSyncUiStatus.error:
      return _SyncStatusPresentation(
        icon: Icons.error_outline_rounded,
        label: sync.lastErrorMessage ?? '同步遇到错误 · 本地变更已安全保存',
        semanticsLabel: sync.lastErrorMessage ?? '同步出错，本地变更已安全保存',
        foreground: tokens.statusErr,
        background: tokens.statusErrSubtle,
        dotColor: tokens.statusErr,
      );
  }
}
