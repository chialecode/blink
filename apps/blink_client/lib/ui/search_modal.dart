import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/search_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';

/// Live full-text search modal opened via `Ctrl+K` or the rail search button.
class BlinkSearchModal extends StatefulWidget {
  const BlinkSearchModal({
    required this.controller,
    required this.onClose,
    this.workspace,
    this.onSelectHit,
    super.key,
  }) : assert(
         workspace != null || onSelectHit != null,
         'Either workspace or onSelectHit must be provided.',
       );

  final BlinkSearchController controller;
  final BlinkWorkspaceController? workspace;
  final ValueChanged<FtsSearchHit>? onSelectHit;
  final VoidCallback onClose;

  @override
  State<BlinkSearchModal> createState() => _BlinkSearchModalState();
}

class _BlinkSearchModalState extends State<BlinkSearchModal> {
  late final TextEditingController _inputController = TextEditingController(
    text: widget.controller.query,
  );
  final FocusNode _focusNode = FocusNode();
  final Map<String, EntryKind> _entryKindCache = <String, EntryKind>{};
  final Set<String> _resolvingIds = <String>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_resolveHitKinds);
    _resolveHitKinds();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant BlinkSearchModal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_resolveHitKinds);
      widget.controller.addListener(_resolveHitKinds);
      _resolveHitKinds();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_resolveHitKinds);
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _resolveHitKinds() {
    final vault = widget.workspace?.vault ?? widget.controller.vaultProvider();
    if (vault == null || !vault.isOpen) {
      return;
    }
    final toResolve = <String>[];
    for (final hit in widget.controller.hits) {
      if (hit.docKind != 'entry') {
        continue;
      }
      if (_entryKindCache.containsKey(hit.docId) ||
          _resolvingIds.contains(hit.docId)) {
        continue;
      }
      if (_lookupKnownEntryKind(hit.docId) != null) {
        continue;
      }
      _resolvingIds.add(hit.docId);
      toResolve.add(hit.docId);
    }
    if (toResolve.isEmpty) {
      return;
    }
    unawaited(_fetchEntryKinds(vault, toResolve));
  }

  Future<void> _fetchEntryKinds(VaultManager vault, List<String> ids) async {
    var updated = false;
    for (final id in ids) {
      try {
        final entry = await vault.raw.getEntryById(id, includeDeleted: true);
        if (entry != null) {
          _entryKindCache[id] = entry.entryKind;
          updated = true;
        }
      } catch (_) {
      } finally {
        _resolvingIds.remove(id);
      }
    }
    if (updated && mounted) {
      setState(() {});
    }
  }

  EntryKind? _lookupKnownEntryKind(String entryId) {
    final cached = _entryKindCache[entryId];
    if (cached != null) {
      return cached;
    }
    final ws = widget.workspace;
    if (ws == null) {
      return null;
    }
    for (final note in ws.noteEntries) {
      if (note.id == entryId) {
        return note.entryKind;
      }
    }
    for (final memo in ws.memoEntries) {
      if (memo.id == entryId) {
        return memo.entryKind;
      }
    }
    return null;
  }

  void _handleSelectHit(FtsSearchHit hit) {
    if (widget.onSelectHit != null) {
      widget.onSelectHit!(hit);
      return;
    }
    widget.onClose();
    final ws = widget.workspace;
    if (ws == null) {
      return;
    }
    if (hit.docKind == 'entry') {
      unawaited(ws.openEntryById(hit.docId));
    } else if (hit.docKind == 'task') {
      ws.setDestination(BlinkNavDestination.tasks);
    }
  }

  ({String label, Color fg, Color bg}) _badgeForHit(
    FtsSearchHit hit,
    BlinkColorTokens tokens,
  ) {
    if (hit.docKind == 'task') {
      return (label: '待办', fg: tokens.statusWarn, bg: tokens.statusWarnSubtle);
    }
    final kind = _lookupKnownEntryKind(hit.docId);
    if (kind != null && BlinkWorkspaceController.isNoteKind(kind)) {
      return (label: '笔记', fg: tokens.accentPrimary, bg: tokens.accentSubtle);
    }
    return (label: '小记', fg: tokens.accentPrimary, bg: tokens.accentSubtle);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return Dialog(
      key: const Key('search_modal'),
      backgroundColor: tokens.canvas,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) {
            final hits = widget.controller.hits;
            final error = widget.controller.errorMessage;
            final includePrivate =
                widget.controller.scope == PrivacyScope.localWithPrivate;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: tokens.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          key: const Key('search_modal_input'),
                          controller: _inputController,
                          focusNode: _focusNode,
                          style: BlinkTypography.editorBody(tokens),
                          decoration: InputDecoration(
                            hintText: '搜索笔记、小记与待办…',
                            hintStyle: BlinkTypography.body(
                              tokens,
                              color: tokens.textMuted,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: widget.controller.setQuery,
                        ),
                      ),
                      TextButton(
                        key: const Key('search_scope_toggle'),
                        onPressed: () {
                          widget.controller.setScope(
                            includePrivate
                                ? PrivacyScope.normalOnly
                                : PrivacyScope.localWithPrivate,
                          );
                        },
                        child: Text(
                          includePrivate ? '含私密内容' : '不含私密',
                          style: BlinkTypography.metaLabel(
                            tokens,
                            color: includePrivate
                                ? tokens.privacyPrivate
                                : tokens.textSecondary,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭 (Esc)',
                        onPressed: widget.onClose,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: tokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: tokens.borderHairline),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      error,
                      style: BlinkTypography.body(
                        tokens,
                        color: tokens.statusErr,
                      ),
                    ),
                  )
                else if (widget.controller.query.trim().isEmpty)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '输入关键词即可实时搜索本地笔记、小记与待办。',
                          textAlign: TextAlign.center,
                          style: BlinkTypography.body(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    ),
                  )
                else if (widget.controller.isSearching)
                  const Expanded(
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else if (hits.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        '未找到匹配结果',
                        style: BlinkTypography.body(
                          tokens,
                          color: tokens.textMuted,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: hits.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: tokens.borderHairline),
                      itemBuilder: (context, index) {
                        final hit = hits[index];
                        final isPrivate =
                            hit.privacyLevel == PrivacyLevel.private;
                        final badge = _badgeForHit(hit, tokens);
                        return InkWell(
                          key: Key('search_hit_${hit.docId}'),
                          onTap: () => _handleSelectHit(hit),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: badge.bg,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        badge.label,
                                        style: BlinkTypography.badge(
                                          color: badge.fg,
                                        ),
                                      ),
                                    ),
                                    if (isPrivate) ...<Widget>[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: tokens.privacySubtle,
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                        ),
                                        child: Text(
                                          '🔒 私密',
                                          style: BlinkTypography.badge(
                                            color: tokens.privacyPrivate,
                                          ),
                                        ),
                                      ),
                                    ],
                                    const Spacer(),
                                    Text(
                                      _formatShortTime(hit.updatedAtUtc),
                                      style:
                                          BlinkTypography.metaLabel(
                                            tokens,
                                            color: tokens.textMuted,
                                          ).copyWith(
                                            fontFeatures:
                                                BlinkTypography.tabularFigures,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  hit.snippet,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: BlinkTypography.body(tokens),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  static String _formatShortTime(DateTime utc) {
    final local = utc.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm';
  }
}
