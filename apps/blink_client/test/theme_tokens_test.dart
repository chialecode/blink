import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';

double _relativeLuminance(Color color) {
  double linearize(double channel) {
    return channel <= 0.03928
        ? channel / 12.92
        : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * linearize(color.r) +
      0.7152 * linearize(color.g) +
      0.0722 * linearize(color.b);
}

double _contrastRatio(Color foreground, Color background) {
  final l1 = _relativeLuminance(foreground);
  final l2 = _relativeLuminance(background);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('BlinkColorTokens & CSS custom properties', () {
    test('Day, Sepia, and Dark tokens match docs/ui.md §2.1 specification', () {
      expect(BlinkColorTokens.day.toCssVariables(), <String, String>{
        '--blink-surface-canvas': '#FFFFFF',
        '--blink-surface-sidebar': '#F6F7F8',
        '--blink-surface-ai-derived': '#F4F6FA',
        '--blink-text-primary': '#1F2328',
        '--blink-text-secondary': '#59636E',
        '--blink-text-muted': '#8C959F',
        '--blink-border-hairline': '#E6E8EB',
        '--blink-accent-primary': '#1E60D5',
        '--blink-privacy-private': '#0F766E',
        '--blink-status-ok': '#1F883D',
        '--blink-status-warn': '#BF8700',
        '--blink-status-err': '#CF222E',
      });

      expect(BlinkColorTokens.sepia.toCssVariables(), <String, String>{
        '--blink-surface-canvas': '#FBF7EE',
        '--blink-surface-sidebar': '#F3EDE0',
        '--blink-surface-ai-derived': '#EFE9DC',
        '--blink-text-primary': '#2B261F',
        '--blink-text-secondary': '#665E52',
        '--blink-text-muted': '#918778',
        '--blink-border-hairline': '#E2DACB',
        '--blink-accent-primary': '#2457B2',
        '--blink-privacy-private': '#0F766E',
        '--blink-status-ok': '#1F883D',
        '--blink-status-warn': '#BF8700',
        '--blink-status-err': '#CF222E',
      });

      expect(BlinkColorTokens.dark.toCssVariables(), <String, String>{
        '--blink-surface-canvas': '#141619',
        '--blink-surface-sidebar': '#1B1E23',
        '--blink-surface-ai-derived': '#1F242D',
        '--blink-text-primary': '#E6EAF0',
        '--blink-text-secondary': '#9BA4B0',
        '--blink-text-muted': '#6E7781',
        '--blink-border-hairline': '#2B3038',
        '--blink-accent-primary': '#5893F8',
        '--blink-privacy-private': '#2DD4BF',
        '--blink-status-ok': '#3FB950',
        '--blink-status-warn': '#D29922',
        '--blink-status-err': '#F85149',
      });

      expect(
        BlinkColorTokens.forMode(BlinkSurfaceMode.day),
        same(BlinkColorTokens.day),
      );
      expect(
        BlinkColorTokens.forMode(BlinkSurfaceMode.sepia),
        same(BlinkColorTokens.sepia),
      );
      expect(
        BlinkColorTokens.forMode(BlinkSurfaceMode.dark),
        same(BlinkColorTokens.dark),
      );
    });

    test('brand mark and dev pill constants match canonical icon palette', () {
      expect(BlinkColorTokens.formatCssHex(BlinkBrandColors.ground), '#3C4043');
      expect(BlinkColorTokens.formatCssHex(BlinkBrandColors.glyph), '#FFFFFF');
      expect(
        BlinkColorTokens.formatCssHex(BlinkBrandColors.devPill),
        '#F3A115',
      );
      expect(
        BlinkColorTokens.formatCssHex(BlinkBrandColors.devPillText),
        '#202124',
      );
      expect(
        BlinkColorTokens.formatCssHex(const Color(0x47F5B400)),
        '#F5B40047',
      );
    });

    test('text and badge contrast meet WCAG AA thresholds across surfaces', () {
      for (final tokens in <BlinkColorTokens>[
        BlinkColorTokens.day,
        BlinkColorTokens.sepia,
        BlinkColorTokens.dark,
      ]) {
        expect(
          _contrastRatio(tokens.textPrimary, tokens.canvas),
          greaterThanOrEqualTo(7.0),
        );
        expect(
          _contrastRatio(tokens.textSecondary, tokens.canvas),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrastRatio(tokens.accentPrimary, tokens.accentSubtle),
          greaterThanOrEqualTo(4.5),
        );
      }

      expect(
        _contrastRatio(BlinkBrandColors.devPillText, BlinkBrandColors.devPill),
        greaterThanOrEqualTo(7.0),
      );
    });

    test('ThemeExtension copyWith and lerp preserve semantic invariants', () {
      final overridden = BlinkColorTokens.day.copyWith(
        accentPrimary: const Color(0xFF123456),
      );
      expect(overridden.accentPrimary, const Color(0xFF123456));
      expect(overridden.canvas, BlinkColorTokens.day.canvas);
      expect(overridden, isNot(equals(BlinkColorTokens.day)));

      expect(BlinkColorTokens.day.lerp(null, 0.5), BlinkColorTokens.day);
      expect(
        BlinkColorTokens.day.lerp(BlinkColorTokens.dark, 0.0),
        BlinkColorTokens.day,
      );
      expect(
        BlinkColorTokens.day.lerp(BlinkColorTokens.dark, 1.0),
        BlinkColorTokens.dark,
      );
    });
  });

  group('BlinkTheme & BlinkTypography', () {
    test(
      'configures flat canvas, 1px hairline cards, and Inter/CJK font stack',
      () {
        final dayTheme = BlinkTheme.day();
        final sepiaTheme = BlinkTheme.sepia();
        final darkTheme = BlinkTheme.dark();

        expect(dayTheme.scaffoldBackgroundColor, BlinkColorTokens.day.canvas);
        expect(
          dayTheme.colorScheme.primary,
          BlinkColorTokens.day.accentPrimary,
        );
        expect(dayTheme.cardTheme.elevation, 0);
        expect(dayTheme.appBarTheme.elevation, 0);
        expect(dayTheme.appBarTheme.scrolledUnderElevation, 0);

        final dayCardShape = dayTheme.cardTheme.shape as RoundedRectangleBorder;
        expect(dayCardShape.side.width, 1);
        expect(dayCardShape.side.color, BlinkColorTokens.day.borderHairline);

        expect(
          sepiaTheme.scaffoldBackgroundColor,
          BlinkColorTokens.sepia.canvas,
        );
        expect(
          sepiaTheme.colorScheme.primary,
          BlinkColorTokens.sepia.accentPrimary,
        );

        expect(darkTheme.brightness, Brightness.dark);
        expect(darkTheme.scaffoldBackgroundColor, BlinkColorTokens.dark.canvas);
        expect(
          darkTheme.colorScheme.primary,
          BlinkColorTokens.dark.accentPrimary,
        );

        expect(BlinkTypography.uiFontFamily, 'Inter');
        expect(BlinkTypography.uiFontFallback, const <String>[
          'Segoe UI',
          'Microsoft YaHei UI',
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
          'HarmonyOS Sans SC',
          'Roboto',
          'sans-serif',
        ]);
        expect(BlinkTypography.monoFontFamily, 'JetBrains Mono');
        expect(BlinkTypography.monoFontFallback, const <String>[
          'Cascadia Mono',
          'Consolas',
          'SF Mono',
          'Menlo',
          'Noto Sans Mono CJK SC',
          'Microsoft YaHei UI',
          'monospace',
        ]);

        // Headings use w600; w700 is reserved for the brand wordmark.
        expect(dayTheme.textTheme.titleLarge?.fontWeight, FontWeight.w600);
        expect(dayTheme.textTheme.titleMedium?.fontWeight, FontWeight.w600);
        expect(
          BlinkTypography.brandWordmark(BlinkColorTokens.day).fontWeight,
          FontWeight.w700,
        );
      },
    );

    test('widget classes contain zero hardcoded hex Color literals', () {
      final scannedFiles = <File>[
        for (final dirPath in const <String>['lib/app', 'lib/ui'])
          if (Directory(dirPath).existsSync())
            ...Directory(dirPath)
                .listSync(recursive: true)
                .whereType<File>()
                .where(
                  (file) =>
                      file.path.endsWith('.dart') &&
                      !file.path.endsWith('blink_theme.dart'),
                ),
      ];
      expect(scannedFiles, isNotEmpty);
      for (final file in scannedFiles) {
        final source = file.readAsStringSync();
        expect(
          RegExp(r'Color\s*\(\s*0x', caseSensitive: false).hasMatch(source),
          isFalse,
          reason: '${file.path} must obtain all colors from blink_theme.dart',
        );
      }
    });
  });

  group('BlinkBrandMarkPainter 1024x1024 geometry', () {
    test('matches exact ground rounded square and even-odd letter B bounds', () {
      final ground = BlinkBrandMarkPainter.buildGroundRRect();
      expect(ground.outerRect, const Rect.fromLTRB(48, 48, 976, 976));
      expect(ground.tlRadiusX, 200);
      expect(ground.brRadiusY, 200);

      final path = BlinkBrandMarkPainter.buildLetterBPath();
      expect(path.fillType, PathFillType.evenOdd);

      final bounds = path.getBounds();
      expect(bounds.left, closeTo(292, 0.01));
      expect(bounds.top, closeTo(250, 0.01));
      expect(bounds.right, closeTo(732, 0.01));
      expect(bounds.bottom, closeTo(780, 0.01));

      // Solid 110-unit strokes: stem, top/middle/bottom bars, and outer bowls.
      expect(path.contains(const Offset(347, 515)), isTrue);
      expect(path.contains(const Offset(480, 305)), isTrue);
      expect(path.contains(const Offset(480, 515)), isTrue);
      expect(path.contains(const Offset(480, 725)), isTrue);
      expect(path.contains(const Offset(677, 410)), isTrue);
      expect(path.contains(const Offset(677, 620)), isTrue);
      expect(path.contains(const Offset(650, 515)), isTrue);

      // Waist notch exterior and both open inner counters must be unfilled.
      expect(path.contains(const Offset(710, 515)), isFalse);
      expect(path.contains(const Offset(500, 410)), isFalse);
      expect(path.contains(const Offset(500, 620)), isFalse);
    });
  });
}
