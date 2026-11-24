import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';

/// Vector brand mark rendered from BLINK's canonical `1024×1024` geometric
/// specification (`#3C4043` rounded square + `#FFFFFF` geometric `"B"`).
class BlinkBrandMark extends StatelessWidget {
  const BlinkBrandMark({this.size = 24.0, super.key});

  /// Logical width and height of the square mark (defaults to `24×24`).
  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(
          size: Size.square(size),
          painter: const BlinkBrandMarkPainter(),
        ),
      ),
    );
  }
}

/// Custom painter for the `1024×1024` master brand icon geometry:
/// - Ground: `[48, 48, 976, 976]`, `rx = 200`, fill [BlinkBrandColors.ground]
/// - Letter `"B"`: `x ∈ [292, 732]`, `y ∈ [250, 780]`, stroke `110`,
///   outer left corners `r = 28`, upper/lower bowls centered at `(572, 410)`
///   and `(572, 620)` (`R_out = 160`, `R_in = 50`), [PathFillType.evenOdd].
class BlinkBrandMarkPainter extends CustomPainter {
  const BlinkBrandMarkPainter();

  /// Canonical master coordinate space dimension (`1024×1024`).
  static const double masterDimension = 1024.0;

  static final RRect _groundRRect = buildGroundRRect();
  static final Path _letterBPath = buildLetterBPath();

  /// Builds the `1024×1024` rounded-square ground `[48, 48, 976, 976]`, `rx=200`.
  static RRect buildGroundRRect() =>
      RRect.fromLTRBR(48, 48, 976, 976, const Radius.circular(200));

  /// Builds the `1024×1024` geometric `"B"` path with [PathFillType.evenOdd].
  static Path buildLetterBPath() {
    // Waist intersection at y = 515 where upper bowl (cy = 410, R = 160) and
    // lower bowl (cy = 620, R = 160) meet: sin(waistAngle) = 105 / 160.
    final waistAngle = math.asin(105.0 / 160.0);

    final path = Path()..fillType = PathFillType.evenOdd;

    // Outer silhouette: left stem + rounded left corners (r = 28) + two R = 160
    // bowls split at cardinal angle 0 so every control point stays in [292, 732].
    const upperBowl = Rect.fromLTRB(412, 250, 732, 570);
    const lowerBowl = Rect.fromLTRB(412, 460, 732, 780);
    const bottomLeftCorner = Rect.fromLTRB(292, 724, 348, 780);
    const topLeftCorner = Rect.fromLTRB(292, 250, 348, 306);
    path
      ..moveTo(320, 250)
      ..lineTo(572, 250)
      ..arcTo(upperBowl, -math.pi / 2, math.pi / 2, false)
      ..arcTo(upperBowl, 0, waistAngle, false)
      ..arcTo(lowerBowl, -waistAngle, waistAngle, false)
      ..arcTo(lowerBowl, 0, math.pi / 2, false)
      ..lineTo(320, 780)
      ..arcTo(bottomLeftCorner, math.pi / 2, math.pi / 2, false)
      ..lineTo(292, 278)
      ..arcTo(topLeftCorner, math.pi, math.pi / 2, false)
      ..close();

    // Upper inner counter: [402, 572] × [360, 460] + right semicircle R = 50.
    const upperCounterArc = Rect.fromLTRB(522, 360, 622, 460);
    path
      ..moveTo(402, 360)
      ..lineTo(572, 360)
      ..arcTo(upperCounterArc, -math.pi / 2, math.pi / 2, false)
      ..arcTo(upperCounterArc, 0, math.pi / 2, false)
      ..lineTo(402, 460)
      ..close();

    // Lower inner counter: [402, 572] × [570, 670] + right semicircle R = 50.
    const lowerCounterArc = Rect.fromLTRB(522, 570, 622, 670);
    path
      ..moveTo(402, 570)
      ..lineTo(572, 570)
      ..arcTo(lowerCounterArc, -math.pi / 2, math.pi / 2, false)
      ..arcTo(lowerCounterArc, 0, math.pi / 2, false)
      ..lineTo(402, 670)
      ..close();

    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }

    canvas.save();
    canvas.scale(size.width / masterDimension, size.height / masterDimension);

    final groundPaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = BlinkBrandColors.ground;
    canvas.drawRRect(_groundRRect, groundPaint);

    final glyphPaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.fill
      ..color = BlinkBrandColors.glyph;
    canvas.drawPath(_letterBPath, glyphPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BlinkBrandMarkPainter oldDelegate) => false;
}
