import 'dart:async';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/ui/files_page.dart';
import 'package:blink_client/ui/sync_conflict_dialog.dart';
import 'package:blink_client/ui/sync_settings_section.dart';
import 'package:blink_client/ui/sync_status_capsule.dart';

/// Feishu-style Pane 2 category sidebar for Settings (`设置`).
class BlinkSettingsSidebar extends StatelessWidget {
  const BlinkSettingsSidebar({
    required this.workspace,
    this.isDrawer = false,
    this.onItemSelected,
    this.onCollapse,
    super.key,
  });

  final BlinkWorkspaceController workspace;
  final bool isDrawer;
  final VoidCallback? onItemSelected;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[workspace, workspace.sync]),
      builder: (context, _) {
        final active = workspace.selectedSettingsCategory;
        final sync = workspace.sync;
        final showSyncDot =
            sync.isConfigured ||
            sync.isHostRunning ||
            BlinkSyncStatusCapsule.shouldShowGlobalBanner(sync.uiStatus);

        Widget categoryRow({
          required Key itemKey,
          required SettingsCategory category,
          required IconData icon,
          required String label,
          Widget? trailing,
        }) {
          final selected = active == category;
          final fg = selected ? tokens.accentPrimary : tokens.textPrimary;
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: InkWell(
              key: itemKey,
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                workspace.selectSettingsCategory(category);
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
                      size: 17,
                      color: selected
                          ? tokens.accentPrimary
                          : tokens.textSecondary,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BlinkTypography.controlLabel(tokens)
                            .copyWith(color: fg),
                      ),
                    ),
                    ?trailing,
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
                      '设置',
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                  ),
                  if (!isDrawer && onCollapse != null)
                    IconButton(
                      key: const Key('settings_sidebar_collapse_button'),
                      tooltip: '收起侧边栏',
                      visualDensity: VisualDensity.compact,
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
            Divider(height: 1, color: tokens.borderHairline),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
                children: <Widget>[
                  categoryRow(
                    itemKey: const Key('settings_cat_general'),
                    category: SettingsCategory.general,
                    icon: Icons.tune_rounded,
                    label: '常规与外观',
                  ),
                  categoryRow(
                    itemKey: const Key('settings_cat_storage'),
                    category: SettingsCategory.storage,
                    icon: Icons.folder_outlined,
                    label: '存储与备份',
                  ),
                  categoryRow(
                    itemKey: const Key('settings_cat_sync'),
                    category: SettingsCategory.sync,
                    icon: Icons.sync_rounded,
                    label: '多端同步',
                    trailing: showSyncDot
                        ? Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: BlinkSyncStatusCapsule.statusDotColor(
                                sync,
                                tokens,
                              ),
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                  ),
                  categoryRow(
                    itemKey: const Key('settings_cat_about'),
                    category: SettingsCategory.about,
                    icon: Icons.info_outline_rounded,
                    label: '关于 BLINK',
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

/// Feishu-style categorized Settings view (`docs/ui.md`):
/// - Desktop / Tablet (`!isMobile`): renders ONLY the currently selected
///   [BlinkWorkspaceController.selectedSettingsCategory] inside a focused
///   max-width `720px` panel.
/// - Mobile (`isMobile`): renders a crisp 2-level list (`常规与外观`, `存储与备份`,
///   `多端同步`, `附件管理`, `关于 BLINK`) that pushes clean single-category sub-pages.
class BlinkSettingsPage extends StatefulWidget {
  const BlinkSettingsPage({
    required this.workspace,
    this.isMobile = false,
    this.isMobilePlatform,
    this.showCompactCategorySwitcher = false,
    this.onOpenDrawer,
    this.onExpandSidebar,
    this.showExpandSidebarButton = false,
    super.key,
  });

  final BlinkWorkspaceController workspace;

  /// Enables 2-level mobile drill-down navigation (`<600px`).
  final bool isMobile;

  /// Optional override for platform-specific desktop vs mobile guards
  /// (defaults to `Platform.isAndroid || Platform.isIOS`).
  final bool? isMobilePlatform;

  /// Renders compact 1-click category switcher pills in the header for
  /// `600–959px` narrow desktop/tablet viewports when the sidebar is collapsed.
  final bool showCompactCategorySwitcher;

  final VoidCallback? onOpenDrawer;
  final VoidCallback? onExpandSidebar;
  final bool showExpandSidebarButton;

  @override
  State<BlinkSettingsPage> createState() => _BlinkSettingsPageState();
}

enum _SurfaceChoice { system, day, sepia, dark }

class _BlinkSettingsPageState extends State<BlinkSettingsPage> {
  final TextEditingController _vaultPathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _vaultPathController.text = widget.workspace.effectiveVaultDir.path;
  }

  @override
  void didUpdateWidget(covariant BlinkSettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.workspace, widget.workspace)) {
      _vaultPathController.text = widget.workspace.effectiveVaultDir.path;
    }
  }

  @override
  void dispose() {
    _vaultPathController.dispose();
    super.dispose();
  }

  bool get _isMobilePlatform =>
      widget.isMobilePlatform ?? (Platform.isAndroid || Platform.isIOS);

  void _openMobileCategory(BuildContext context, SettingsCategory category) {
    widget.workspace.selectSettingsCategory(category);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _MobileSettingsDetailScaffold(
          title: _categoryTitle(category),
          child: _SettingsCategoryDetailBody(
            workspace: widget.workspace,
            category: category,
            isMobilePlatform: _isMobilePlatform,
            isCompactWidth: true,
            vaultPathController: _vaultPathController,
          ),
        ),
      ),
    );
  }

  void _openMobileFiles(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) {
          final tokens = BlinkColorTokens.of(pageContext);
          return Scaffold(
            backgroundColor: tokens.canvas,
            body: SafeArea(
              child: BlinkFilesPage(
                workspace: widget.workspace,
                isMobile: true,
                onBack: () => Navigator.of(pageContext).pop(),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final isCompactWidth = MediaQuery.sizeOf(context).width < 600;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        widget.workspace,
        widget.workspace.lifecycle,
        widget.workspace.sync,
      ]),
      builder: (context, _) {
        if (widget.isMobile) {
          return _buildMobileRoot(context, tokens);
        }

        final category = widget.workspace.selectedSettingsCategory;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
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
                      if (widget.showExpandSidebarButton &&
                          widget.onExpandSidebar != null) ...<Widget>[
                        IconButton(
                          key: const Key('settings_sidebar_expand_button'),
                          tooltip: '展开侧边栏',
                          visualDensity: VisualDensity.compact,
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
                          tooltip: '设置菜单',
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onOpenDrawer,
                          icon: Icon(
                            Icons.menu_rounded,
                            size: 19,
                            color: tokens.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          _categoryTitle(category),
                          style: BlinkTypography.heroHeading(tokens),
                        ),
                      ),
                    ],
                  ),
                  if (widget.showCompactCategorySwitcher) ...<Widget>[
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          _compactCategoryPill(
                            tokens,
                            const Key('settings_compact_cat_general'),
                            SettingsCategory.general,
                            '常规与外观',
                          ),
                          const SizedBox(width: 6),
                          _compactCategoryPill(
                            tokens,
                            const Key('settings_compact_cat_storage'),
                            SettingsCategory.storage,
                            '存储与备份',
                          ),
                          const SizedBox(width: 6),
                          _compactCategoryPill(
                            tokens,
                            const Key('settings_compact_cat_sync'),
                            SettingsCategory.sync,
                            '多端同步',
                          ),
                          const SizedBox(width: 6),
                          _compactCategoryPill(
                            tokens,
                            const Key('settings_compact_cat_about'),
                            SettingsCategory.about,
                            '关于 BLINK',
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _SettingsCategoryDetailBody(
                workspace: widget.workspace,
                category: category,
                isMobilePlatform: _isMobilePlatform,
                isCompactWidth: isCompactWidth,
                vaultPathController: _vaultPathController,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _compactCategoryPill(
    BlinkColorTokens tokens,
    Key pillKey,
    SettingsCategory category,
    String label,
  ) {
    final selected = widget.workspace.selectedSettingsCategory == category;
    return ChoiceChip(
      key: pillKey,
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
      onSelected: (_) => widget.workspace.selectSettingsCategory(category),
    );
  }

  Widget _buildMobileRoot(BuildContext context, BlinkColorTokens tokens) {
    final lifecycle = widget.workspace.lifecycle;
    final settings = lifecycle.settings;
    final sync = widget.workspace.sync;
    final themeLabel = switch (settings.surfaceMode) {
      null => '跟随系统',
      DesktopSurfacePreference.day => '日间',
      DesktopSurfacePreference.sepia => '暖纸',
      DesktopSurfacePreference.dark => '夜间',
    };
    final editorLabel = widget.workspace.defaultNoteEditorMode.label;
    final syncLabel = BlinkSyncStatusCapsule.shortStatusLabel(sync);
    final showSyncDot =
        sync.isConfigured ||
        sync.isHostRunning ||
        BlinkSyncStatusCapsule.shouldShowGlobalBanner(sync.uiStatus);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: tokens.canvas,
            border: Border(
              bottom: BorderSide(color: tokens.borderHairline, width: 1),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Text('设置', style: BlinkTypography.heroHeading(tokens)),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: <Widget>[
              Material(
                color: tokens.canvas,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: tokens.borderHairline, width: 1),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: <Widget>[
                    _MobileSettingsRow(
                      itemKey: const Key('mobile_settings_general'),
                      icon: Icons.tune_rounded,
                      title: '常规与外观',
                      subtitle: '$themeLabel · $editorLabel',
                      onTap: () => _openMobileCategory(
                        context,
                        SettingsCategory.general,
                      ),
                    ),
                    Divider(height: 1, color: tokens.borderHairline),
                    _MobileSettingsRow(
                      itemKey: const Key('mobile_settings_storage'),
                      icon: Icons.folder_outlined,
                      title: '存储与备份',
                      subtitle:
                          '${widget.workspace.totalMemoCount} 条小记 · ${widget.workspace.totalNoteCount} 篇笔记',
                      onTap: () => _openMobileCategory(
                        context,
                        SettingsCategory.storage,
                      ),
                    ),
                    Divider(height: 1, color: tokens.borderHairline),
                    _MobileSettingsRow(
                      itemKey: const Key('mobile_settings_sync'),
                      icon: Icons.sync_rounded,
                      title: '多端同步',
                      subtitle: syncLabel,
                      statusDotColor: showSyncDot
                          ? BlinkSyncStatusCapsule.statusDotColor(sync, tokens)
                          : null,
                      onTap: () =>
                          _openMobileCategory(context, SettingsCategory.sync),
                    ),
                    Divider(height: 1, color: tokens.borderHairline),
                    _MobileSettingsRow(
                      itemKey: const Key('mobile_settings_files'),
                      icon: Icons.perm_media_outlined,
                      title: '附件管理',
                      subtitle: '共 ${widget.workspace.blobs.length} 个附件',
                      onTap: () => _openMobileFiles(context),
                    ),
                    Divider(height: 1, color: tokens.borderHairline),
                    _MobileSettingsRow(
                      itemKey: const Key('mobile_settings_about'),
                      icon: Icons.info_outline_rounded,
                      title: '关于 BLINK',
                      subtitle: 'v${lifecycle.buildInfo.version}',
                      onTap: () =>
                          _openMobileCategory(context, SettingsCategory.about),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _categoryTitle(SettingsCategory category) {
    switch (category) {
      case SettingsCategory.general:
        return '常规与外观';
      case SettingsCategory.storage:
        return '存储与备份';
      case SettingsCategory.sync:
        return '多端同步';
      case SettingsCategory.about:
        return '关于 BLINK';
    }
  }
}

class _MobileSettingsRow extends StatelessWidget {
  const _MobileSettingsRow({
    required this.itemKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.statusDotColor,
  });

  final Key itemKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? statusDotColor;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return InkWell(
      key: itemKey,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: tokens.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: BlinkTypography.controlLabel(tokens)),
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      if (statusDotColor != null) ...<Widget>[
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: statusDotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BlinkTypography.metaLabel(tokens),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: tokens.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileSettingsDetailScaffold extends StatelessWidget {
  const _MobileSettingsDetailScaffold({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: tokens.canvas,
                border: Border(
                  bottom: BorderSide(color: tokens.borderHairline, width: 1),
                ),
              ),
              child: Row(
                children: <Widget>[
                  TextButton.icon(
                    key: const Key('mobile_settings_back_button'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.textPrimary,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 15,
                    ),
                    label: const Text('返回'),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _SettingsCategoryDetailBody extends StatelessWidget {
  const _SettingsCategoryDetailBody({
    required this.workspace,
    required this.category,
    required this.isMobilePlatform,
    required this.isCompactWidth,
    required this.vaultPathController,
  });

  final BlinkWorkspaceController workspace;
  final SettingsCategory category;
  final bool isMobilePlatform;
  final bool isCompactWidth;
  final TextEditingController vaultPathController;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final labelWidth = isCompactWidth ? 104.0 : 128.0;

    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        workspace,
        workspace.lifecycle,
        workspace.sync,
      ]),
      builder: (context, _) {
        return SingleChildScrollView(
          padding: EdgeInsets.all(isCompactWidth ? 14 : 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: switch (category) {
                SettingsCategory.general => _buildGeneralSection(tokens),
                SettingsCategory.storage => _buildStorageSection(
                  tokens,
                  labelWidth,
                ),
                SettingsCategory.sync => BlinkSyncSettingsSection(
                  workspace: workspace,
                  isMobilePlatform: isMobilePlatform,
                  compactPadding: isCompactWidth,
                  labelWidth: labelWidth,
                  onOpenConflicts: () {
                    showDialog<void>(
                      context: context,
                      barrierDismissible: true,
                      builder: (_) =>
                          BlinkSyncConflictDialog(sync: workspace.sync),
                    );
                  },
                ),
                SettingsCategory.about => _AboutSection(
                  buildInfo: workspace.lifecycle.buildInfo,
                  dataRootPath: workspace.lifecycle.paths.dataRoot.path,
                  labelWidth: labelWidth,
                  compactPadding: isCompactWidth,
                ),
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildGeneralSection(BlinkColorTokens tokens) {
    final lifecycle = workspace.lifecycle;
    final settings = lifecycle.settings;
    final currentSurface = switch (settings.surfaceMode) {
      null => _SurfaceChoice.system,
      DesktopSurfacePreference.day => _SurfaceChoice.day,
      DesktopSurfacePreference.sepia => _SurfaceChoice.sepia,
      DesktopSurfacePreference.dark => _SurfaceChoice.dark,
    };

    return _FlatSettingsPanel(
      key: const Key('settings_section'),
      compactPadding: isCompactWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('主题外观', style: BlinkTypography.controlLabel(tokens)),
          const SizedBox(height: 4),
          Text('选择适合当前阅读与写作光线的界面风格', style: BlinkTypography.metaLabel(tokens)),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_SurfaceChoice>(
              key: const Key('surface_mode_toggle'),
              showSelectedIcon: false,
              segments: const <ButtonSegment<_SurfaceChoice>>[
                ButtonSegment<_SurfaceChoice>(
                  value: _SurfaceChoice.system,
                  label: Text('跟随系统'),
                ),
                ButtonSegment<_SurfaceChoice>(
                  value: _SurfaceChoice.day,
                  label: Text('日间'),
                ),
                ButtonSegment<_SurfaceChoice>(
                  value: _SurfaceChoice.sepia,
                  label: Text('暖纸'),
                ),
                ButtonSegment<_SurfaceChoice>(
                  value: _SurfaceChoice.dark,
                  label: Text('夜间'),
                ),
              ],
              selected: <_SurfaceChoice>{currentSurface},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) {
                  return;
                }
                final next = switch (selection.first) {
                  _SurfaceChoice.system => null,
                  _SurfaceChoice.day => DesktopSurfacePreference.day,
                  _SurfaceChoice.sepia => DesktopSurfacePreference.sepia,
                  _SurfaceChoice.dark => DesktopSurfacePreference.dark,
                };
                workspace.setSurfaceMode(next);
              },
            ),
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: tokens.borderHairline),
          const SizedBox(height: 16),
          Text('笔记默认编辑模式', style: BlinkTypography.controlLabel(tokens)),
          const SizedBox(height: 4),
          Text(
            '打开笔记时默认使用的编辑方式，编辑过程中也可按 Ctrl+/ 随时切换',
            style: BlinkTypography.metaLabel(tokens),
          ),
          const SizedBox(height: 10),
          SegmentedButton<NoteEditorMode>(
            key: const Key('editor_default_mode_toggle'),
            showSelectedIcon: false,
            segments: const <ButtonSegment<NoteEditorMode>>[
              ButtonSegment<NoteEditorMode>(
                value: NoteEditorMode.wysiwyg,
                label: Text('所见即所得'),
              ),
              ButtonSegment<NoteEditorMode>(
                value: NoteEditorMode.source,
                label: Text('源代码'),
              ),
            ],
            selected: <NoteEditorMode>{workspace.defaultNoteEditorMode},
            onSelectionChanged: (selection) {
              if (selection.isNotEmpty) {
                workspace.setDefaultNoteEditorMode(selection.first);
              }
            },
          ),
          if (!isMobilePlatform) ...<Widget>[
            const SizedBox(height: 18),
            Divider(height: 1, color: tokens.borderHairline),
            const SizedBox(height: 16),
            Text('点击窗口关闭按钮时', style: BlinkTypography.controlLabel(tokens)),
            const SizedBox(height: 10),
            SegmentedButton<CloseButtonBehavior>(
              key: const Key('close_behavior_toggle'),
              showSelectedIcon: false,
              segments: const <ButtonSegment<CloseButtonBehavior>>[
                ButtonSegment<CloseButtonBehavior>(
                  value: CloseButtonBehavior.hideToTray,
                  label: Text('隐藏到托盘'),
                ),
                ButtonSegment<CloseButtonBehavior>(
                  value: CloseButtonBehavior.exitApp,
                  label: Text('直接退出'),
                ),
              ],
              selected: <CloseButtonBehavior>{settings.closeButtonBehavior},
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) {
                  lifecycle.updateCloseButtonBehavior(selection.first);
                }
              },
            ),
          ],
          if (lifecycle.recoveredCorruptSettings) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              '检测到损坏的配置文件，已保留原文件并恢复默认设置。',
              key: const Key('corrupt_settings_notice'),
              style: BlinkTypography.metaLabel(
                tokens,
                color: tokens.statusWarn,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStorageSection(BlinkColorTokens tokens, double labelWidth) {
    final settings = workspace.lifecycle.settings;
    final stats = workspace.stats;
    final mirrorStatus = workspace.mirrorStatus;
    final vaultChannel =
        workspace.vault?.metadata.channel ?? workspace.expectedChannel;
    final channelLabel = vaultChannel == BlinkChannel.blink
        ? '数据通道：正式版'
        : '数据通道：开发版';

    return _FlatSettingsPanel(
      key: const Key('vault_settings_section'),
      compactPadding: isCompactWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  isMobilePlatform ? '本机存储' : '数据文件夹',
                  style: BlinkTypography.sectionHeading(tokens),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: tokens.sidebar,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: tokens.borderHairline),
                ),
                child: Text(
                  channelLabel,
                  key: const Key('vault_channel_lock'),
                  style: BlinkTypography.metaLabel(tokens),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (workspace.vaultErrorMessage != null) ...<Widget>[
            Container(
              key: const Key('vault_error_banner'),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tokens.statusErrSubtle,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: tokens.statusErr),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.error_outline_rounded,
                    size: 18,
                    color: tokens.statusErr,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      workspace.vaultErrorMessage!,
                      style: BlinkTypography.body(
                        tokens,
                        color: tokens.statusErr,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _InfoRow(
            label: '数据文件夹',
            value: workspace.effectiveVaultDir.path,
            valueKey: const Key('vault_path_value'),
            valueStyle: BlinkTypography.monoValue(tokens),
            labelWidth: labelWidth,
          ),
          if (stats != null)
            _InfoRow(
              label: '数据概况',
              value:
                  '${workspace.totalMemoCount} 条小记 · '
                  '${workspace.totalNoteCount} 篇笔记 · '
                  '${stats.openTasks} 项待办 · '
                  '${stats.totalBlobs} 个附件（${formatByteSize(stats.totalBlobBytes)}）',
              valueKey: const Key('vault_stats_summary'),
              valueStyle: BlinkTypography.metaValue(tokens, tabular: true),
              labelWidth: labelWidth,
            ),
          if (!isMobilePlatform) ...<Widget>[
            _InfoRow(
              label: 'Markdown 自动导出',
              value: mirrorStatus == null
                  ? '尚未导出'
                  : mirrorStatus.lastExportedAtUtc == null
                  ? '已开启，等待导出'
                  : '上次导出：${_formatLocalDateTime(mirrorStatus.lastExportedAtUtc!)}',
              valueKey: const Key('vault_mirror_status'),
              valueStyle: BlinkTypography.metaValue(tokens, tabular: true),
              labelWidth: labelWidth,
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const Key('vault_path_input'),
                    controller: vaultPathController,
                    style: BlinkTypography.monoValue(tokens),
                    decoration: InputDecoration(
                      labelText: '更改数据文件夹路径',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const Key('vault_pick_button'),
                  onPressed: () async {
                    final ok = await workspace.pickAndSwitchVaultDirectory();
                    if (ok) {
                      vaultPathController.text =
                          workspace.effectiveVaultDir.path;
                    }
                  },
                  child: const Text('选择目录'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('vault_switch_button'),
                  onPressed: () async {
                    final ok = await workspace.switchVaultDirectory(
                      vaultPathController.text,
                    );
                    if (ok) {
                      vaultPathController.text =
                          workspace.effectiveVaultDir.path;
                    }
                  },
                  child: const Text('切换'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Divider(height: 1, color: tokens.borderHairline),
          const SizedBox(height: 14),
          Text('备份与维护', style: BlinkTypography.controlLabel(tokens)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('vault_backup_button'),
                onPressed: workspace.hasOpenVault
                    ? () => unawaited(workspace.createHotBackup())
                    : null,
                icon: const Icon(Icons.backup_outlined, size: 16),
                label: const Text('立即备份数据'),
              ),
              OutlinedButton.icon(
                key: const Key('vault_rebuild_button'),
                onPressed: workspace.hasOpenVault
                    ? () => unawaited(workspace.rebuildDerivedStores())
                    : null,
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('重建搜索索引'),
              ),
              if (!isMobilePlatform)
                OutlinedButton.icon(
                  key: const Key('vault_mirror_button'),
                  onPressed: workspace.hasOpenVault
                      ? () => unawaited(workspace.flushMirrorNow())
                      : null,
                  icon: const Icon(Icons.drive_file_move_outlined, size: 16),
                  label: const Text('立即导出 Markdown'),
                ),
              if (!isMobilePlatform && settings.customVaultPath != null)
                TextButton(
                  key: const Key('vault_reset_button'),
                  onPressed: () async {
                    final ok = await workspace.resetToDefaultVault();
                    if (ok) {
                      vaultPathController.text =
                          workspace.effectiveVaultDir.path;
                    }
                  },
                  child: const Text('恢复默认目录'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (isMobilePlatform)
            Text(
              '数据仅保存在本机私密存储空间，不参与系统自动云备份',
              key: const Key('mobile_sandbox_notice'),
              style: BlinkTypography.metaLabel(tokens, color: tokens.textMuted),
            )
          else ...<Widget>[
            Text(
              '提示：请勿将正在使用的数据文件夹直接放入第三方网盘同步；如需网盘存档，请使用上方的“立即备份数据”或“立即导出 Markdown”。',
              style: BlinkTypography.metaLabel(tokens, color: tokens.textMuted),
            ),
            if (BlinkPaths.isOneDrivePath(
              workspace.effectiveVaultDir.path,
            )) ...<Widget>[
              const SizedBox(height: 10),
              Container(
                key: const Key('vault_onedrive_hint'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: tokens.statusWarnSubtle,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tokens.statusWarn),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: tokens.statusWarn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '检测到当前数据文件夹位于 OneDrive 目录内：多设备同时开启网盘同步可能导致本地数据冲突，跨设备同步建议使用内置“多端同步”，或在上方切换至非网盘目录。',
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.statusWarn,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _formatLocalDateTime(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.buildInfo,
    required this.dataRootPath,
    required this.labelWidth,
    required this.compactPadding,
  });

  final BlinkBuildInfo buildInfo;
  final String dataRootPath;
  final double labelWidth;
  final bool compactPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return _FlatSettingsPanel(
      key: const Key('about_section'),
      compactPadding: compactPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const BlinkBrandMark(key: Key('brand_mark'), size: 28),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  buildInfo.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BlinkTypography.brandWordmark(tokens),
                ),
              ),
              const SizedBox(width: 10),
              _ChannelBadge(buildInfo: buildInfo),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: tokens.borderHairline),
          const SizedBox(height: 12),
          _InfoRow(
            label: '版本',
            value: buildInfo.version,
            valueKey: const Key('about_version'),
            valueStyle: BlinkTypography.metaValue(tokens, tabular: true),
            labelWidth: labelWidth,
          ),
          _InfoRow(
            label: '通道',
            value: buildInfo.channel,
            valueKey: const Key('about_channel'),
            valueStyle: BlinkTypography.metaValue(tokens),
            labelWidth: labelWidth,
          ),
          _InfoRow(
            label: '安装标识',
            value: buildInfo.displayIdentity,
            valueKey: const Key('about_identity'),
            valueStyle: BlinkTypography.metaValue(tokens),
            labelWidth: labelWidth,
          ),
          _InfoRow(
            label: '提交版本',
            value: buildInfo.shortGitSha,
            valueKey: const Key('about_git_sha'),
            valueStyle: BlinkTypography.monoValue(tokens, tabular: true),
            labelWidth: labelWidth,
          ),
          _InfoRow(
            label: '应用配置目录',
            value: dataRootPath,
            valueKey: const Key('about_data_root'),
            valueStyle: BlinkTypography.monoValue(tokens),
            labelWidth: labelWidth,
          ),
        ],
      ),
    );
  }
}

class _FlatSettingsPanel extends StatelessWidget {
  const _FlatSettingsPanel({
    required this.compactPadding,
    required this.child,
    super.key,
  });

  final bool compactPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Material(
      color: tokens.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(compactPadding ? 16 : 20),
        child: child,
      ),
    );
  }
}

class _ChannelBadge extends StatelessWidget {
  const _ChannelBadge({required this.buildInfo});

  final BlinkBuildInfo buildInfo;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final isProd = buildInfo.isProductionChannel;
    final bgColor = isProd ? tokens.accentSubtle : BlinkBrandColors.devPill;
    final fgColor = isProd
        ? tokens.accentPrimary
        : BlinkBrandColors.devPillText;
    final label = isProd ? '正式通道' : 'DEV 开发通道';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: BlinkTypography.badge(color: fgColor)),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.valueStyle,
    this.labelWidth = 128,
  });

  final String label;
  final String value;
  final Key valueKey;
  final TextStyle valueStyle;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(label, style: BlinkTypography.metaLabel(tokens)),
          ),
          Expanded(
            child: SelectableText(value, key: valueKey, style: valueStyle),
          ),
        ],
      ),
    );
  }
}
