import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/search_controller.dart';

/// Live CJK FTS5 search modal opened via `Ctrl+K` or top-bar search button.
class BlinkSearchModal extends StatefulWidget {
  const BlinkSearchModal({
    required this.controller,
    required this.onSelectHit,
    required this.onClose,
    super.key,
  });

  final BlinkSearchController controller;
  final ValueChanged<FtsSearchHit> onSelectHit;
  final VoidCallback onClose;

  @override
  State<BlinkSearchModal> createState() => _BlinkSearchModalState();
}

class _BlinkSearchModalState extends State<BlinkSearchModal> {
  late final TextEditingController _inputController = TextEditingController(
    text: widget.controller.query,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
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
                            hintText: '全局 CJK 全文搜索（单字、词组、中英混排）…',
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
                          includePrivate ? '含 #private' : '仅常规范围',
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
                          '输入关键词实时检索本地 index/fts.db（支持中文单字、双字与长词召回）。',
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
                        return InkWell(
                          key: Key('search_hit_${hit.docId}'),
                          onTap: () => widget.onSelectHit(hit),
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
                                    Text(
                                      hit.docKind == 'task' ? '待办' : '记录',
                                      style: BlinkTypography.metaLabel(
                                        tokens,
                                        color: tokens.accentPrimary,
                                      ),
                                    ),
                                    if (isPrivate) ...<Widget>[
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1,
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
                                const SizedBox(height: 4),
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
