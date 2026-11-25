import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';

enum _MimeFilter { all, image, document, audio, other }

/// Files & content-addressed attachments (`blobs/`) management view (`docs/ui.md` §4.1).
class BlinkFilesPage extends StatefulWidget {
  const BlinkFilesPage({
    required this.workspace,
    required this.onAttachToNewEntry,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final ValueChanged<MediaBlob> onAttachToNewEntry;

  @override
  State<BlinkFilesPage> createState() => _BlinkFilesPageState();
}

class _BlinkFilesPageState extends State<BlinkFilesPage> {
  final TextEditingController _searchController = TextEditingController();
  _MimeFilter _mimeFilter = _MimeFilter.all;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: widget.workspace,
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
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '文件与附件仓（blobs/）',
                            style: BlinkTypography.heroHeading(tokens),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '共 ${allBlobs.length} 份内容寻址附件 · 合计 ${formatByteSize(totalBytes)} · 未引用 $unreferencedCount 份',
                            style: BlinkTypography.metaLabel(tokens).copyWith(
                              fontFeatures: BlinkTypography.tabularFigures,
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          OutlinedButton.icon(
                            key: const Key('files_gc_button'),
                            onPressed: widget.workspace.hasOpenVault
                                ? () => widget.workspace.gcUnreferencedBlobs()
                                : null,
                            icon: const Icon(
                              Icons.cleaning_services_outlined,
                              size: 16,
                            ),
                            label: const Text('回收无引用附件'),
                          ),
                          FilledButton.icon(
                            key: const Key('files_import_button'),
                            onPressed: widget.workspace.hasOpenVault
                                ? () => widget.workspace.importFileFromPicker()
                                : null,
                            icon: const Icon(
                              Icons.upload_file_rounded,
                              size: 16,
                            ),
                            label: const Text('导入文件'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('files_search_input'),
                    controller: _searchController,
                    style: BlinkTypography.body(tokens),
                    decoration: InputDecoration(
                      hintText: '按 MIME 类型、SHA-256 或关联条目正文筛选…',
                      hintStyle: BlinkTypography.body(
                        tokens,
                        color: tokens.textMuted,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: tokens.textSecondary,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: tokens.sidebar,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: tokens.borderHairline),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: tokens.borderHairline),
                      ),
                    ),
                    onChanged: (value) => setState(() => _query = value.trim()),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      _buildMimeChip(tokens, _MimeFilter.all, '全部'),
                      _buildMimeChip(tokens, _MimeFilter.image, '图片'),
                      _buildMimeChip(tokens, _MimeFilter.document, '文档'),
                      _buildMimeChip(tokens, _MimeFilter.audio, '音频'),
                      _buildMimeChip(tokens, _MimeFilter.other, '其他'),
                    ],
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
                              ? '附件仓为空。点击“导入文件”按 SHA-256 去重写入 blobs/，随后可关联到任意笔记。'
                              : '没有匹配当前筛选条件的附件。',
                          textAlign: TextAlign.center,
                          style: BlinkTypography.body(
                            tokens,
                            color: tokens.textMuted,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(20),
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
                              : () => widget.workspace.attachBlobToEntry(
                                  widget.workspace.selectedEntryId!,
                                  blob.sha256,
                                ),
                          onAttachToNewEntry: () =>
                              widget.onAttachToNewEntry(blob),
                          onExport: () =>
                              widget.workspace.exportBlobToPicker(blob),
                          onOpenReferrer: (entry) =>
                              widget.workspace.openEntryById(entry.id),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildMimeChip(
    BlinkColorTokens tokens,
    _MimeFilter filter,
    String label,
  ) {
    final selected = _mimeFilter == filter;
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
      onSelected: (_) => setState(() => _mimeFilter = filter),
    );
  }

  bool _matchesFilter(MediaBlob blob, List<RawEntry>? refs) {
    final mime = blob.mimeType.toLowerCase();
    switch (_mimeFilter) {
      case _MimeFilter.all:
        break;
      case _MimeFilter.image:
        if (!mime.startsWith('image/')) return false;
      case _MimeFilter.document:
        final isDoc =
            mime.startsWith('text/') ||
            mime.contains('pdf') ||
            mime.contains('epub') ||
            mime.contains('json');
        if (!isDoc) return false;
      case _MimeFilter.audio:
        if (!mime.startsWith('audio/')) return false;
      case _MimeFilter.other:
        final known =
            mime.startsWith('image/') ||
            mime.startsWith('audio/') ||
            mime.startsWith('text/') ||
            mime.contains('pdf') ||
            mime.contains('epub') ||
            mime.contains('json');
        if (known) return false;
    }

    if (_query.isEmpty) {
      return true;
    }
    final q = _query.toLowerCase();
    if (blob.sha256.toLowerCase().contains(q) ||
        mime.contains(q) ||
        blob.storageRelPath.toLowerCase().contains(q)) {
      return true;
    }
    for (final entry in refs ?? const <RawEntry>[]) {
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

    return Card(
      key: Key('blob_card_${blob.sha256}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  _iconForMime(blob.mimeType),
                  size: 18,
                  color: tokens.accentPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    blob.mimeType,
                    style: BlinkTypography.controlLabel(tokens),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isUnreferenced
                        ? tokens.statusWarnSubtle
                        : tokens.statusOkSubtle,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    isUnreferenced ? '未引用' : '${referrers.length} 条引用',
                    style: BlinkTypography.badge(
                      color: isUnreferenced
                          ? tokens.statusWarn
                          : tokens.statusOk,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatByteSize(blob.byteSize),
                  style: BlinkTypography.metaLabel(tokens)
                      .copyWith(fontFeatures: BlinkTypography.tabularFigures),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              'SHA-256: ${blob.sha256}',
              style: BlinkTypography.monoValue(
                tokens,
                tabular: true,
              ).copyWith(fontSize: 12, color: tokens.textSecondary),
            ),
            const SizedBox(height: 2),
            Text(
              '相对路径: ${blob.storageRelPath}',
              style: BlinkTypography.metaLabel(tokens, color: tokens.textMuted),
            ),
            if (referrers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final entry in referrers.take(5))
                    ActionChip(
                      label: Text(
                        _shortSnippet(entry.bodyMd),
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
                    label: const Text('关联到当前条目'),
                  ),
                OutlinedButton.icon(
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

  static String _shortSnippet(String body) {
    final first = body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '关联条目');
    return first.length > 22 ? '${first.substring(0, 22)}…' : first;
  }
}
