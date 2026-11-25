import 'package:material_ui/material_ui.dart';

/// Semantic reading and shell surface modes defined in `docs/ui.md` §2.1.
enum BlinkSurfaceMode { day, sepia, dark }

/// Canonical brand mark and development-channel badge palette (`1024×1024`
/// brand icon specification and in-app channel pill).
abstract final class BlinkBrandColors {
  /// Flat charcoal rounded-square icon ground (`#3C4043`).
  static const Color ground = Color(0xFF3C4043);

  /// Pure white geometric `"B"` glyph (`#FFFFFF`).
  static const Color glyph = Color(0xFFFFFFFF);

  /// Development-channel pill fill (`#F3A115`).
  static const Color devPill = Color(0xFFF3A115);

  /// Development-channel pill foreground (`#202124`).
  static const Color devPillText = Color(0xFF202124);
}

/// Centralized typography stacks, font features, and text styles from
/// `docs/ui.md` §2.2.
abstract final class BlinkTypography {
  /// Primary UI sans-serif font family (`Inter`, falling back to OS CJK sans).
  static const String uiFontFamily = 'Inter';

  /// Cross-platform UI and CJK sans-serif fallback stack.
  static const List<String> uiFontFallback = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'HarmonyOS Sans SC',
    'Roboto',
    'sans-serif',
  ];

  /// Primary monospace font family for commit hashes, paths, and code blocks.
  static const String monoFontFamily = 'JetBrains Mono';

  /// Cross-platform monospace + CJK fallback stack.
  static const List<String> monoFontFallback = <String>[
    'Cascadia Mono',
    'Consolas',
    'SF Mono',
    'Menlo',
    'Noto Sans Mono CJK SC',
    'Microsoft YaHei UI',
    'monospace',
  ];

  /// OpenType `tnum` feature for aligned version numbers, timestamps, and SHAs.
  static const List<FontFeature> tabularFigures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// AppBar product wordmark (`w700` reserved exclusively for brand identity).
  static TextStyle brandWordmark(BlinkColorTokens tokens) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.3,
    color: tokens.textPrimary,
  );

  /// Primary hero/panel heading (`18px`, `w600`).
  static TextStyle heroHeading(BlinkColorTokens tokens) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: tokens.textPrimary,
  );

  /// Card/group section heading (`16px`, `w600`).
  static TextStyle sectionHeading(BlinkColorTokens tokens) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: tokens.textPrimary,
  );

  /// Interactive control label (`14px`, `w500`).
  static TextStyle controlLabel(BlinkColorTokens tokens) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.4,
    color: tokens.textPrimary,
  );

  /// Standard UI body prose (`14px`, `w400`).
  static TextStyle body(BlinkColorTokens tokens, {Color? color}) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.55,
    color: color ?? tokens.textPrimary,
  );

  /// UI metadata value (`14px`, `w500`), optionally with `tabular-nums`.
  static TextStyle metaValue(BlinkColorTokens tokens, {bool tabular = false}) =>
      TextStyle(
        fontFamily: uiFontFamily,
        fontFamilyFallback: uiFontFallback,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.4,
        fontFeatures: tabular ? tabularFigures : null,
        color: tokens.textPrimary,
      );

  /// Monospace value for git revisions and filesystem paths (`13px`).
  static TextStyle monoValue(BlinkColorTokens tokens, {bool tabular = false}) =>
      TextStyle(
        fontFamily: monoFontFamily,
        fontFamilyFallback: monoFontFallback,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.45,
        fontFeatures: tabular ? tabularFigures : null,
        color: tokens.textPrimary,
      );

  /// Compact metadata label (`12px`, `w500`).
  static TextStyle metaLabel(BlinkColorTokens tokens, {Color? color}) =>
      TextStyle(
        fontFamily: uiFontFamily,
        fontFamilyFallback: uiFontFallback,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.4,
        color: color ?? tokens.textSecondary,
      );

  /// BFM v1 editor prose style (`15px`, line-height `1.65`, `docs/ui.md` §2.2).
  static TextStyle editorBody(BlinkColorTokens tokens, {Color? color}) =>
      TextStyle(
        fontFamily: uiFontFamily,
        fontFamilyFallback: uiFontFallback,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.65,
        color: color ?? tokens.textPrimary,
      );

  /// Compact status/channel pill label (`12px`, `w600`).
  static TextStyle badge({required Color color}) => TextStyle(
    fontFamily: uiFontFamily,
    fontFamilyFallback: uiFontFallback,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: color,
  );

  /// Builds the full Material `TextTheme` bound to [tokens].
  static TextTheme textTheme(BlinkColorTokens tokens) => TextTheme(
    titleLarge: heroHeading(tokens),
    titleMedium: sectionHeading(tokens),
    titleSmall: controlLabel(tokens),
    bodyLarge: body(tokens),
    bodyMedium: body(tokens, color: tokens.textSecondary),
    bodySmall: metaLabel(tokens),
    labelLarge: controlLabel(tokens),
    labelMedium: metaLabel(tokens),
    labelSmall: metaLabel(tokens, color: tokens.textMuted),
  );
}

/// Semantic color tokens from `docs/ui.md` §2.1, synchronized with Surface 2
/// `--blink-*` CSS custom properties.
@immutable
class BlinkColorTokens extends ThemeExtension<BlinkColorTokens> {
  const BlinkColorTokens({
    required this.canvas,
    required this.sidebar,
    required this.aiDerived,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.borderHairline,
    required this.accentPrimary,
    required this.accentSubtle,
    required this.privacyPrivate,
    required this.statusOk,
    required this.statusWarn,
    required this.statusErr,
  });

  /// Main workspace, reader viewport, and input surface (`--blink-surface-canvas`).
  final Color canvas;

  /// Icon rail, context sidebar, and mobile bottom bar (`--blink-surface-sidebar`).
  final Color sidebar;

  /// AI-derived synthesis, echoes, and read-only card surface (`--blink-surface-ai-derived`).
  final Color aiDerived;

  /// Primary prose, headings, and primary action text (`--blink-text-primary`).
  final Color textPrimary;

  /// Timestamps, chapter/page info, and secondary labels (`--blink-text-secondary`).
  final Color textSecondary;

  /// Placeholders, muted identifiers, and archived items (`--blink-text-muted`).
  final Color textMuted;

  /// `1px` hairline border and section divider (`--blink-border-hairline`).
  final Color borderHairline;

  /// Single primary button, active nav indicator, and `<blink-ref>` accent (`--blink-accent-primary`).
  final Color accentPrimary;

  /// Low-saturation tint of [accentPrimary] for selected controls and prod channel pill.
  final Color accentSubtle;

  /// `#private` lock badge and local-only indicator (`--blink-privacy-private`).
  final Color privacyPrivate;

  /// Synced / healthy status (`--blink-status-ok`).
  final Color statusOk;

  /// Offline queue / degraded fallback warning (`--blink-status-warn`).
  final Color statusWarn;

  /// Sync conflict / error status (`--blink-status-err`).
  final Color statusErr;

  /// Soft translucent highlight fill for BFM `==mark==` (`docs/ui.md` §2.1).
  Color get highlightMark => statusWarn.withValues(alpha: 0.24);

  /// Soft translucent fill for `#private` badges and filter pills.
  Color get privacySubtle => privacyPrivate.withValues(alpha: 0.14);

  /// Soft translucent fill for warning banners.
  Color get statusWarnSubtle => statusWarn.withValues(alpha: 0.12);

  /// Soft translucent fill for error banners.
  Color get statusErrSubtle => statusErr.withValues(alpha: 0.12);

  /// Soft translucent fill for success pills.
  Color get statusOkSubtle => statusOk.withValues(alpha: 0.12);

  /// Crisp daylight surface (`Day`).
  static const BlinkColorTokens day = BlinkColorTokens(
    canvas: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF6F7F8),
    aiDerived: Color(0xFFF4F6FA),
    textPrimary: Color(0xFF1F2328),
    textSecondary: Color(0xFF59636E),
    textMuted: Color(0xFF8C959F),
    borderHairline: Color(0xFFE6E8EB),
    accentPrimary: Color(0xFF1E60D5),
    accentSubtle: Color(0xFFE8F0FE),
    privacyPrivate: Color(0xFF0F766E),
    statusOk: Color(0xFF1F883D),
    statusWarn: Color(0xFFBF8700),
    statusErr: Color(0xFFCF222E),
  );

  /// Warm paper reader/synthesis surface (`Sepia`).
  static const BlinkColorTokens sepia = BlinkColorTokens(
    canvas: Color(0xFFFBF7EE),
    sidebar: Color(0xFFF3EDE0),
    aiDerived: Color(0xFFEFE9DC),
    textPrimary: Color(0xFF2B261F),
    textSecondary: Color(0xFF665E52),
    textMuted: Color(0xFF918778),
    borderHairline: Color(0xFFE2DACB),
    accentPrimary: Color(0xFF2457B2),
    accentSubtle: Color(0xFFE5ECF8),
    privacyPrivate: Color(0xFF0F766E),
    statusOk: Color(0xFF1F883D),
    statusWarn: Color(0xFFBF8700),
    statusErr: Color(0xFFCF222E),
  );

  /// Low-glare night surface (`Dark`).
  static const BlinkColorTokens dark = BlinkColorTokens(
    canvas: Color(0xFF141619),
    sidebar: Color(0xFF1B1E23),
    aiDerived: Color(0xFF1F242D),
    textPrimary: Color(0xFFE6EAF0),
    textSecondary: Color(0xFF9BA4B0),
    textMuted: Color(0xFF6E7781),
    borderHairline: Color(0xFF2B3038),
    accentPrimary: Color(0xFF5893F8),
    accentSubtle: Color(0xFF1C2B45),
    privacyPrivate: Color(0xFF2DD4BF),
    statusOk: Color(0xFF3FB950),
    statusWarn: Color(0xFFD29922),
    statusErr: Color(0xFFF85149),
  );

  /// Resolves the active [BlinkColorTokens] from [context], defaulting to [day].
  static BlinkColorTokens of(BuildContext context) =>
      Theme.of(context).extension<BlinkColorTokens>() ?? day;

  /// Returns tokens for [mode].
  static BlinkColorTokens forMode(BlinkSurfaceMode mode) {
    switch (mode) {
      case BlinkSurfaceMode.day:
        return day;
      case BlinkSurfaceMode.sepia:
        return sepia;
      case BlinkSurfaceMode.dark:
        return dark;
    }
  }

  /// Exports `docs/ui.md` §2.1 `--blink-*` CSS custom properties for Surface 2
  /// sandboxed HTML views.
  Map<String, String> toCssVariables() =>
      Map<String, String>.unmodifiable(<String, String>{
        '--blink-surface-canvas': formatCssHex(canvas),
        '--blink-surface-sidebar': formatCssHex(sidebar),
        '--blink-surface-ai-derived': formatCssHex(aiDerived),
        '--blink-text-primary': formatCssHex(textPrimary),
        '--blink-text-secondary': formatCssHex(textSecondary),
        '--blink-text-muted': formatCssHex(textMuted),
        '--blink-border-hairline': formatCssHex(borderHairline),
        '--blink-accent-primary': formatCssHex(accentPrimary),
        '--blink-privacy-private': formatCssHex(privacyPrivate),
        '--blink-status-ok': formatCssHex(statusOk),
        '--blink-status-warn': formatCssHex(statusWarn),
        '--blink-status-err': formatCssHex(statusErr),
      });

  /// Formats [color] as uppercase `#RRGGBB` (or `#RRGGBBAA` when translucent).
  static String formatCssHex(Color color) {
    final argb = color.toARGB32();
    final a = (argb >> 24) & 0xFF;
    final rgbHex = (argb & 0x00FFFFFF)
        .toRadixString(16)
        .padLeft(6, '0')
        .toUpperCase();
    if (a == 0xFF) {
      return '#$rgbHex';
    }
    final alphaHex = a.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#$rgbHex$alphaHex';
  }

  @override
  BlinkColorTokens copyWith({
    Color? canvas,
    Color? sidebar,
    Color? aiDerived,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? borderHairline,
    Color? accentPrimary,
    Color? accentSubtle,
    Color? privacyPrivate,
    Color? statusOk,
    Color? statusWarn,
    Color? statusErr,
  }) => BlinkColorTokens(
    canvas: canvas ?? this.canvas,
    sidebar: sidebar ?? this.sidebar,
    aiDerived: aiDerived ?? this.aiDerived,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    borderHairline: borderHairline ?? this.borderHairline,
    accentPrimary: accentPrimary ?? this.accentPrimary,
    accentSubtle: accentSubtle ?? this.accentSubtle,
    privacyPrivate: privacyPrivate ?? this.privacyPrivate,
    statusOk: statusOk ?? this.statusOk,
    statusWarn: statusWarn ?? this.statusWarn,
    statusErr: statusErr ?? this.statusErr,
  );

  @override
  BlinkColorTokens lerp(ThemeExtension<BlinkColorTokens>? other, double t) {
    if (other is! BlinkColorTokens) {
      return this;
    }
    return BlinkColorTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      aiDerived: Color.lerp(aiDerived, other.aiDerived, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      borderHairline: Color.lerp(borderHairline, other.borderHairline, t)!,
      accentPrimary: Color.lerp(accentPrimary, other.accentPrimary, t)!,
      accentSubtle: Color.lerp(accentSubtle, other.accentSubtle, t)!,
      privacyPrivate: Color.lerp(privacyPrivate, other.privacyPrivate, t)!,
      statusOk: Color.lerp(statusOk, other.statusOk, t)!,
      statusWarn: Color.lerp(statusWarn, other.statusWarn, t)!,
      statusErr: Color.lerp(statusErr, other.statusErr, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlinkColorTokens &&
          canvas == other.canvas &&
          sidebar == other.sidebar &&
          aiDerived == other.aiDerived &&
          textPrimary == other.textPrimary &&
          textSecondary == other.textSecondary &&
          textMuted == other.textMuted &&
          borderHairline == other.borderHairline &&
          accentPrimary == other.accentPrimary &&
          accentSubtle == other.accentSubtle &&
          privacyPrivate == other.privacyPrivate &&
          statusOk == other.statusOk &&
          statusWarn == other.statusWarn &&
          statusErr == other.statusErr;

  @override
  int get hashCode => Object.hash(
    canvas,
    sidebar,
    aiDerived,
    textPrimary,
    textSecondary,
    textMuted,
    borderHairline,
    accentPrimary,
    accentSubtle,
    privacyPrivate,
    statusOk,
    statusWarn,
    statusErr,
  );
}

/// Centralized `ThemeData` factory for BLINK's Day, Sepia, and Dark surfaces.
///
/// Both `blink` and `blink-dev` share the exact same [BlinkColorTokens] and
/// primary brand blue (`#1E60D5` Day / `#5893F8` Dark); channel identity is
/// communicated exclusively through the product title and channel pill.
abstract final class BlinkTheme {
  static const Color _onLightPrimary = Color(0xFFFFFFFF);
  static const Color _onDarkPrimary = Color(0xFF0A192F);

  /// Daylight theme (`#FFFFFF` flat canvas, `#1E60D5` accent).
  static ThemeData day() =>
      _build(tokens: BlinkColorTokens.day, brightness: Brightness.light);

  /// Warm paper reader theme (`#FBF7EE` canvas, `#2457B2` accent).
  static ThemeData sepia() =>
      _build(tokens: BlinkColorTokens.sepia, brightness: Brightness.light);

  /// Night theme (`#141619` flat canvas, `#5893F8` accent), paired with Win32
  /// `DWMWA_USE_IMMERSIVE_DARK_MODE`.
  static ThemeData dark() =>
      _build(tokens: BlinkColorTokens.dark, brightness: Brightness.dark);

  static ThemeData _build({
    required BlinkColorTokens tokens,
    required Brightness brightness,
  }) {
    final isDark = brightness == Brightness.dark;
    final onPrimary = isDark ? _onDarkPrimary : _onLightPrimary;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: tokens.accentPrimary,
      onPrimary: onPrimary,
      primaryContainer: tokens.accentSubtle,
      onPrimaryContainer: tokens.accentPrimary,
      secondary: tokens.textSecondary,
      onSecondary: tokens.canvas,
      secondaryContainer: tokens.accentSubtle,
      onSecondaryContainer: tokens.accentPrimary,
      surface: tokens.canvas,
      onSurface: tokens.textPrimary,
      onSurfaceVariant: tokens.textSecondary,
      surfaceContainerLowest: tokens.canvas,
      surfaceContainerLow: tokens.sidebar,
      surfaceContainer: tokens.sidebar,
      surfaceContainerHigh: tokens.aiDerived,
      error: tokens.statusErr,
      onError: onPrimary,
      outline: tokens.borderHairline,
      outlineVariant: tokens.borderHairline,
      shadow: Colors.transparent,
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: BlinkTypography.uiFontFamily,
      fontFamilyFallback: BlinkTypography.uiFontFallback,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: tokens.canvas,
      canvasColor: tokens.canvas,
      dividerColor: tokens.borderHairline,
      shadowColor: Colors.transparent,
      textTheme: BlinkTypography.textTheme(tokens),
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.canvas,
        foregroundColor: tokens.textPrimary,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        shape: Border(
          bottom: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      cardTheme: CardThemeData(
        color: tokens.canvas,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: tokens.borderHairline, width: 1),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: tokens.borderHairline,
        thickness: 1,
        space: 1,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll<TextStyle>(
            BlinkTypography.controlLabel(tokens),
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) {
              return tokens.accentSubtle;
            }
            return tokens.canvas;
          }),
          foregroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
            if (states.contains(WidgetState.selected)) {
              return tokens.accentPrimary;
            }
            return tokens.textPrimary;
          }),
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: tokens.borderHairline, width: 1),
          ),
          elevation: const WidgetStatePropertyAll<double>(0),
        ),
      ),
      extensions: <ThemeExtension<dynamic>>[tokens],
    );
  }
}
