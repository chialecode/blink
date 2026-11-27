import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/ui/desktop_window_chrome.dart';

/// Category filter for the Attachments (`附件`) module.
enum BlinkFileFilter { all, image, document, audio, other, unreferenced }

/// Shared filter state between [BlinkFilesSidebar] and [BlinkFilesPage].
class BlinkFilesController extends ChangeNotifier {
  BlinkFileFilter _filter = BlinkFileFilter.all;
  String _query = '';

  BlinkFileFilter get filter => _filter;
  String get query => _query;

  void setFilter(BlinkFileFilter next) {
    if (_filter == next) {
      return;
    }
    _filter = next;
    notifyListeners();
  }

  void setQuery(String next) {
    final trimmed = next.trim();
    if (_query == trimmed) {
      return;
    }
    _query = trimmed;
    notifyListeners();
  }

  /// Classifies [mimeType] into a primary display category.
  static BlinkFileFilter categoryForMime(String mimeType) {
    final lower = mimeType.toLowerCase();
    if (lower.startsWith('image/')) {
      return BlinkFileFilter.image;
    }
    if (lower.startsWith('audio/')) {
      return BlinkFileFilter.audio;
    }
    if (lower.startsWith('text/') ||
        lower.contains('pdf') ||
        lower.contains('epub') ||
        lower.contains('json') ||
        lower.contains('word') ||
        lower.contains('document')) {
      return BlinkFileFilter.document;
    }
    return BlinkFileFilter.other;
  }

  /// Human-readable Chinese category label for [mimeType].
  static String categoryLabel(String mimeType) {
    switch (categoryForMime(mimeType)) {
      case BlinkFileFilter.image:
        return '图片';
      case BlinkFileFilter.document:
        return '文档';
      case BlinkFileFilter.audio:
        return '音频';
      case BlinkFileFilter.all:
      case BlinkFileFilter.other:
      case BlinkFileFilter.unreferenced:
        return '文件';
    }
  }

  /// Human-readable file display name derived from MIME type and short ID.
  static String displayFileName(MediaBlob blob) {
    final ext = extensionForMimeType(blob.mimeType);
    final shortId = blob.sha256.length >= 8
        ? blob.sha256.substring(0, 8)
        : blob.sha256;
    final lower = blob.mimeType.toLowerCase();
    final prefix = switch (categoryForMime(blob.mimeType)) {
      BlinkFileFilter.image => '图片',
      BlinkFileFilter.audio => '音频',
      BlinkFileFilter.document =>
        lower.contains('pdf')
            ? 'PDF文档'
            : lower.contains('markdown')
            ? 'Markdown文档'
            : '文档',
      BlinkFileFilter.all ||
      BlinkFileFilter.other ||
      BlinkFileFilter.unreferenced => '附件',
    };
    return '${prefix}_$shortId$ext';
  }
}

/// Feishu-style Pane 2 resource sidebar for the Attachments (`附件`) module.
class BlinkFilesSidebar extends StatelessWidget {
  const BlinkFilesSidebar({
    required this.workspace,
    required this.controller,
    this.isDrawer = false,
    this.onItemSelected,
    this.onCollapse,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final BlinkFilesController controller;
  final bool isDrawer;
  final VoidCallback? onItemSelected;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[workspace, controller]),
      builder: (context, _) {
        final allBlobs = workspace.blobs;
        final referrers = workspace.blobReferrers;

        var imageCount = 0;
        var docCount = 0;
        var audioCount = 0;
        var otherCount = 0;
        var unreferencedCount = 0;
        var totalBytes = 0;

        for (final blob in allBlobs) {
          totalBytes += blob.byteSize;
          if ((referrers[blob.sha256] ?? const <RawEntry>[]).isEmpty) {
            unreferencedCount++;
          }
          switch (BlinkFilesController.categoryForMime(blob.mimeType)) {
            case BlinkFileFilter.image:
              imageCount++;
            case BlinkFileFilter.document:
              docCount++;
            case BlinkFileFilter.audio:
              audioCount++;
            case BlinkFileFilter.all:
            case BlinkFileFilter.other:
            case BlinkFileFilter.unreferenced:
              otherCount++;
          }
        }

        Widget filterRow({
          required Key itemKey,
          required BlinkFileFilter filter,
          required IconData icon,
          required String label,
          required int count,
          Color? accentOverride,
        }) {
          final selected = controller.filter == filter;
          final activeColor = accentOverride ?? tokens.accentPrimary;
          final fg = selected ? activeColor : tokens.textPrimary;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              key: itemKey,
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                controller.setFilter(filter);
                onItemSelected?.call();
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
                          ? activeColor
                          : (accentOverride ?? tokens.textSecondary),
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
                        color: selected ? activeColor : tokens.textMuted,
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
            BlinkWindowDragArea(
              enabled: !isDrawer,
              child: Container(
                height: kBlinkWindowChromeHeaderHeight,
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: IgnorePointer(
                        child: Text(
                          '附件',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BlinkTypography.sectionHeading(tokens),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('files_sidebar_import_button'),
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
                      onPressed: workspace.hasOpenVault
                          ? () => unawaited(workspace.importFileFromPicker())
                          : null,
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('导入'),
                    ),
                    if (!isDrawer && onCollapse != null)
                      IconButton(
                        key: const Key('files_sidebar_collapse_button'),
                        tooltip: '收起侧边栏',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        onPressed: onCollapse,
                        icon: Icon(
                          Icons.keyboard_double_arrow_left_rounded,
                          size: 18,
                          color: tokens.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, color: tokens.borderHairline),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                children: <Widget>[
                  filterRow(
                    itemKey: const Key('files_filter_all'),
                    filter: BlinkFileFilter.all,
                    icon: Icons.perm_media_outlined,
                    label: '全部附件',
                    count: allBlobs.length,
                  ),
                  filterRow(
                    itemKey: const Key('files_filter_image'),
                    filter: BlinkFileFilter.image,
                    icon: Icons.image_outlined,
                    label: '图片',
                    count: imageCount,
                  ),
                  filterRow(
                    itemKey: const Key('files_filter_document'),
                    filter: BlinkFileFilter.document,
                    icon: Icons.description_outlined,
                    label: '文档',
                    count: docCount,
                  ),
                  filterRow(
                    itemKey: const Key('files_filter_audio'),
                    filter: BlinkFileFilter.audio,
                    icon: Icons.audiotrack_outlined,
                    label: '音频',
                    count: audioCount,
                  ),
                  filterRow(
                    itemKey: const Key('files_filter_other'),
                    filter: BlinkFileFilter.other,
                    icon: Icons.insert_drive_file_outlined,
                    label: '其他',
                    count: otherCount,
                  ),
                  const SizedBox(height: 8),
                  Divider(height: 1, color: tokens.borderHairline),
                  const SizedBox(height: 8),
                  filterRow(
                    itemKey: const Key('files_filter_unreferenced'),
                    filter: BlinkFileFilter.unreferenced,
                    icon: Icons.link_off_rounded,
                    label: '未引用附件',
                    count: unreferencedCount,
                    accentOverride: unreferencedCount > 0
                        ? tokens.statusWarn
                        : null,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: tokens.borderHairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '已占用 ${formatByteSize(totalBytes)}',
                    style: BlinkTypography.metaValue(tokens, tabular: true),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '共 ${allBlobs.length} 个附件 · 未引用 $unreferencedCount 个',
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.textMuted,
                    ).copyWith(fontFeatures: BlinkTypography.tabularFigures),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('files_sidebar_gc_button'),
                    onPressed: workspace.hasOpenVault && unreferencedCount > 0
                        ? () => unawaited(workspace.gcUnreferencedBlobs())
                        : null,
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      size: 15,
                    ),
                    label: const Text('清理未引用'),
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

/// Clean Attachments (`附件`) management view (`docs/ui.md`).
class BlinkFilesPage extends StatefulWidget {
  const BlinkFilesPage({
    required this.workspace,
    this.controller,
    this.onAttachToNewEntry,
    this.showInlineFilters = true,
    this.isMobile = false,
    this.onBack,
    this.onOpenDrawer,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final BlinkFilesController? controller;
  final ValueChanged<MediaBlob>? onAttachToNewEntry;
  final bool showInlineFilters;
  final bool isMobile;
  final VoidCallback? onBack;
  final VoidCallback? onOpenDrawer;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;

  @override
  State<BlinkFilesPage> createState() => _BlinkFilesPageState();
}

class _BlinkFilesPageState extends State<BlinkFilesPage> {
  final TextEditingController _searchController = TextEditingController();
  BlinkFilesController? _ownedController;

  BlinkFilesController get _controller {
    if (widget.controller != null) {
      return widget.controller!;
    }
    return _ownedController ??= BlinkFilesController();
  }

  @override
  void initState() {
    super.initState();
    _searchController.text = _controller.query;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _ownedController?.dispose();
    super.dispose();
  }

  Future<void> _attachToNewNote(MediaBlob blob) async {
    if (widget.onAttachToNewEntry != null) {
      widget.onAttachToNewEntry!(blob);
      if (mounted) {
        widget.onBack?.call();
      }
      return;
    }
    final created = await widget.workspace.createNote(
      imageBlobSha256s: <String>[blob.sha256],
    );
    if (created != null) {
      widget.workspace.setDestination(BlinkNavDestination.notes);
      if (mounted) {
        widget.onBack?.call();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final controller = _controller;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[widget.workspace, controller]),
      builder: (context, _) {
        final allBlobs = widget.workspace.blobs;
        final referrers = widget.workspace.blobReferrers;
        final filtered = allBlobs
            .where((blob) => _matchesFilter(blob, referrers[blob.sha256]))
            .toList(growable: false);
        final unreferencedCount = allBlobs
            .where(
              (blob) => (referrers[blob.sha256] ?? const <RawEntry>[]).isEmpty,
            )
            .length;
        final totalBytes = allBlobs.fold<int>(
          0,
          (sum, blob) => sum + blob.byteSize,
        );
        final hPad = widget.isMobile ? 14.0 : 20.0;
        final trailingInset = widget.isMobile
            ? 0.0
            : BlinkWindowChromeScope.trailingInsetOf(context);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  bottom: BorderSide(color: tokens.borderHairline, width: 1),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  BlinkWindowDragArea(
                    enabled: !widget.isMobile,
                    child: Container(
                      height: kBlinkWindowChromeHeaderHeight,
                      padding: EdgeInsets.only(
                        left: hPad,
                        right: trailingInset > 0 ? 0 : hPad,
                      ),
                      child: Row(
                        children: <Widget>[
                          if (widget.onBack != null) ...<Widget>[
                            IconButton(
                              key: const Key('files_back_button'),
                              tooltip: '返回',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              onPressed: widget.onBack,
                              icon: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ] else if (widget.showExpandSidebarButton &&
                              widget.onExpandSidebar != null) ...<Widget>[
                            IconButton(
                              key: const Key('files_sidebar_expand_button'),
                              tooltip: '展开侧边栏',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              onPressed: widget.onExpandSidebar,
                              icon: Icon(
                                Icons.view_sidebar_outlined,
                                size: 18,
                                color: tokens.textSecondary,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ] else if (widget.onOpenDrawer != null) ...<Widget>[
                            IconButton(
                              tooltip: '筛选附件',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              onPressed: widget.onOpenDrawer,
                              icon: Icon(
                                Icons.menu_rounded,
                                size: 19,
                                color: tokens.textSecondary,
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: IgnorePointer(
                              child: Text(
                                _headingForFilter(controller.filter),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: BlinkTypography.heroHeading(tokens),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (!widget.isMobile) ...<Widget>[
                            OutlinedButton.icon(
                              key: const Key('files_gc_button'),
                              style: OutlinedButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                minimumSize: const Size(0, 30),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: widget.workspace.hasOpenVault
                                  ? () => unawaited(
                                      widget.workspace.gcUnreferencedBlobs(),
                                    )
                                  : null,
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                                size: 15,
                              ),
                              label: const Text('清理未引用'),
                            ),
                            const SizedBox(width: 8),
                          ],
                          FilledButton.icon(
                            key: const Key('files_import_button'),
                            style: FilledButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              minimumSize: const Size(0, 30),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: widget.workspace.hasOpenVault
                                ? () => unawaited(
                                    widget.workspace.importFileFromPicker(),
                                  )
                                : null,
                            icon: const Icon(
                              Icons.upload_file_rounded,
                              size: 15,
                            ),
                            label: Text(widget.isMobile ? '导入' : '导入附件'),
                          ),
                          if (trailingInset > 0) ...<Widget>[
                            const SizedBox(width: 10),
                            SizedBox(width: trailingInset),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, color: tokens.borderHairline),
                  Padding(
                    padding: EdgeInsets.fromLTRB(hPad, 10, hPad, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '共 ${allBlobs.length} 个附件 · ${formatByteSize(totalBytes)} · 未引用 $unreferencedCount 个',
                          style: BlinkTypography.metaLabel(tokens).copyWith(
                            fontFeatures: BlinkTypography.tabularFigures,
                          ),
                        ),
                        if (widget.isMobile &&
                            unreferencedCount > 0) ...<Widget>[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const Key('files_gc_button'),
                              onPressed: widget.workspace.hasOpenVault
                                  ? () => unawaited(
                                      widget.workspace.gcUnreferencedBlobs(),
                                    )
                                  : null,
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                                size: 15,
                              ),
                              label: Text('清理 $unreferencedCount 个未引用附件'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        TextField(
                          key: const Key('files_search_input'),
                          controller: _searchController,
                          style: BlinkTypography.body(tokens),
                          decoration: InputDecoration(
                            hintText: '搜索附件名称、类型或关联的小记与笔记…',
                            hintStyle: BlinkTypography.body(
                              tokens,
                              color: tokens.textMuted,
                            ),
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              size: 18,
                              color: tokens.textSecondary,
                            ),
                            suffixIcon: controller.query.isNotEmpty
                                ? IconButton(
                                    tooltip: '清空搜索',
                                    onPressed: () {
                                      _searchController.clear();
                                      controller.setQuery('');
                                    },
                                    icon: Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                      color: tokens.textSecondary,
                                    ),
                                  )
                                : null,
                            isDense: true,
                            filled: true,
                            fillColor: tokens.sidebar,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: tokens.borderHairline,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(
                                color: tokens.borderHairline,
                              ),
                            ),
                          ),
                          onChanged: controller.setQuery,
                        ),
                        if (widget.showInlineFilters) ...<Widget>[
                          const SizedBox(height: 10),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: <Widget>[
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.all,
                                  '全部',
                                ),
                                const SizedBox(width: 6),
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.image,
                                  '图片',
                                ),
                                const SizedBox(width: 6),
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.document,
                                  '文档',
                                ),
                                const SizedBox(width: 6),
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.audio,
                                  '音频',
                                ),
                                const SizedBox(width: 6),
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.other,
                                  '其他',
                                ),
                                const SizedBox(width: 6),
                                _buildFilterChip(
                                  tokens,
                                  controller,
                                  BlinkFileFilter.unreferenced,
                                  '未引用 ($unreferencedCount)',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          allBlobs.isEmpty
                              ? '还没有附件。点击“导入附件”添加图片、文档或音频，支持自动去重保存并关联到小记或笔记。'
                              : '没有符合当前筛选条件的附件。',
                          textAlign: TextAlign.center,
                          style: BlinkTypography.body(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.all(hPad),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final blob = filtered[index];
                        final refs =
                            referrers[blob.sha256] ?? const <RawEntry>[];
                        return _BlobCard(
                          blob: blob,
                          referrers: refs,
                          hasSelectedEntry:
                              widget.workspace.selectedEntryId != null,
                          onAttachToSelected:
                              widget.workspace.selectedEntryId == null
                              ? null
                              : () => unawaited(
                                  widget.workspace.attachBlobToEntry(
                                    widget.workspace.selectedEntryId!,
                                    blob.sha256,
                                  ),
                                ),
                          onAttachToNewEntry: () =>
                              unawaited(_attachToNewNote(blob)),
                          onExport: () => unawaited(
                            widget.workspace.exportBlobToPicker(blob),
                          ),
                          onOpenReferrer: (entry) {
                            widget.onBack?.call();
                            unawaited(widget.workspace.openEntryById(entry.id));
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  String _headingForFilter(BlinkFileFilter filter) {
    switch (filter) {
      case BlinkFileFilter.all:
        return '附件';
      case BlinkFileFilter.image:
        return '图片附件';
      case BlinkFileFilter.document:
        return '文档附件';
      case BlinkFileFilter.audio:
        return '音频附件';
      case BlinkFileFilter.other:
        return '其他附件';
      case BlinkFileFilter.unreferenced:
        return '未引用附件';
    }
  }

  Widget _buildFilterChip(
    BlinkColorTokens tokens,
    BlinkFilesController controller,
    BlinkFileFilter filter,
    String label,
  ) {
    final selected = controller.filter == filter;
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
      onSelected: (_) => controller.setFilter(filter),
    );
  }

  bool _matchesFilter(MediaBlob blob, List<RawEntry>? refs) {
    final filter = _controller.filter;
    final refList = refs ?? const <RawEntry>[];
    switch (filter) {
      case BlinkFileFilter.all:
        break;
      case BlinkFileFilter.unreferenced:
        if (refList.isNotEmpty) {
          return false;
        }
      case BlinkFileFilter.image:
      case BlinkFileFilter.document:
      case BlinkFileFilter.audio:
      case BlinkFileFilter.other:
        if (BlinkFilesController.categoryForMime(blob.mimeType) != filter) {
          return false;
        }
    }

    final query = _controller.query;
    if (query.isEmpty) {
      return true;
    }
    final q = query.toLowerCase();
    final displayName = BlinkFilesController.displayFileName(blob)
        .toLowerCase();
    final categoryLabel = BlinkFilesController.categoryLabel(blob.mimeType)
        .toLowerCase();
    if (displayName.contains(q) ||
        categoryLabel.contains(q) ||
        blob.mimeType.toLowerCase().contains(q) ||
        blob.sha256.toLowerCase().contains(q)) {
      return true;
    }
    for (final entry in refList) {
      if (entry.bodyMd.toLowerCase().contains(q)) {
        return true;
      }
    }
    return false;
  }
}

class _BlobCard extends StatelessWidget {
  const _BlobCard({
    required this.blob,
    required this.referrers,
    required this.hasSelectedEntry,
    required this.onAttachToSelected,
    required this.onAttachToNewEntry,
    required this.onExport,
    required this.onOpenReferrer,
  });

  final MediaBlob blob;
  final List<RawEntry> referrers;
  final bool hasSelectedEntry;
  final VoidCallback? onAttachToSelected;
  final VoidCallback onAttachToNewEntry;
  final VoidCallback onExport;
  final ValueChanged<RawEntry> onOpenReferrer;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final isUnreferenced = referrers.isEmpty;
    final displayName = BlinkFilesController.displayFileName(blob);
    final categoryName = BlinkFilesController.categoryLabel(blob.mimeType);
    final shortHash = blob.sha256.length >= 12
        ? blob.sha256.substring(0, 12)
        : blob.sha256;

    return Card(
      key: Key('blob_card_${blob.sha256}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: tokens.sidebar,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tokens.borderHairline),
                  ),
                  child: Icon(
                    _iconForMime(blob.mimeType),
                    size: 18,
                    color: tokens.accentPrimary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        displayName,
                        style: BlinkTypography.controlLabel(tokens),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(
                            '$categoryName · ${formatByteSize(blob.byteSize)} · ${_formatDate(blob.createdAtUtc)}',
                            style: BlinkTypography.metaLabel(tokens).copyWith(
                              fontFeatures: BlinkTypography.tabularFigures,
                            ),
                          ),
                          Tooltip(
                            message: '文件校验码（SHA-256）：${blob.sha256}',
                            child: Text(
                              '#$shortHash',
                              style:
                                  BlinkTypography.metaLabel(
                                    tokens,
                                    color: tokens.textMuted,
                                  ).copyWith(
                                    fontFeatures:
                                        BlinkTypography.tabularFigures,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: isUnreferenced
                        ? tokens.statusWarnSubtle
                        : tokens.statusOkSubtle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isUnreferenced ? '未引用' : '${referrers.length} 处引用',
                    style: BlinkTypography.badge(
                      color: isUnreferenced
                          ? tokens.statusWarn
                          : tokens.statusOk,
                    ),
                  ),
                ),
              ],
            ),
            if (referrers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final entry in referrers.take(5))
                    ActionChip(
                      avatar: Icon(
                        BlinkWorkspaceController.isNoteKind(entry.entryKind)
                            ? Icons.article_outlined
                            : Icons.chat_bubble_outline_rounded,
                        size: 14,
                        color: tokens.accentPrimary,
                      ),
                      label: Text(
                        _shortSnippet(entry),
                        overflow: TextOverflow.ellipsis,
                      ),
                      backgroundColor: tokens.accentSubtle,
                      side: BorderSide(color: tokens.borderHairline),
                      labelStyle: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.accentPrimary,
                      ),
                      onPressed: () => onOpenReferrer(entry),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                if (hasSelectedEntry)
                  OutlinedButton.icon(
                    onPressed: onAttachToSelected,
                    icon: const Icon(Icons.attach_file_rounded, size: 15),
                    label: const Text('关联到当前内容'),
                  ),
                OutlinedButton.icon(
                  key: Key('blob_attach_new_${blob.sha256}'),
                  onPressed: onAttachToNewEntry,
                  icon: const Icon(Icons.note_add_outlined, size: 15),
                  label: const Text('附入新笔记'),
                ),
                OutlinedButton.icon(
                  key: Key('blob_export_${blob.sha256}'),
                  onPressed: onExport,
                  icon: const Icon(Icons.download_outlined, size: 15),
                  label: const Text('导出副本'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.startsWith('image/')) return Icons.image_outlined;
    if (lower.startsWith('audio/')) return Icons.audiotrack_outlined;
    if (lower.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.startsWith('text/')) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _formatDate(DateTime utc) {
    final local = utc.toLocal();
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '${local.year}-$m-$d';
  }

  static String _shortSnippet(RawEntry entry) {
    final prefix = BlinkWorkspaceController.isNoteKind(entry.entryKind)
        ? '笔记'
        : '小记';
    final first = entry.bodyMd
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^[#>\-\s]+'), '').trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => prefix);
    final trimmed = first.length > 20 ? '${first.substring(0, 20)}…' : first;
    return trimmed;
  }
}
