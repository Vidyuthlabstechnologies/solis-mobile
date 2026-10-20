import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/solis_theme.dart';

/// The SOLIS mark ("Split Sun") on its SOLIS Orchid tile.
///
/// One sun disc cut along the horizon: the upper half stays where it rose,
/// the lower half slides left. It reads as a sunrise and its reflection, and
/// as the letter S. For the product it says that what was said (above the
/// line) and what was written down (below the line) are the same disc,
/// shifted, nothing added.
///
/// Geometry matches tool/make_brand_assets.py and assets/brand/solis_mark.svg;
/// change them together. The tile color is the same in light and dark themes.
class SolisBrandMark extends StatelessWidget {
  final double size;

  const SolisBrandMark({super.key, this.size = 48});

  /// Corner radius of the tile as a fraction of its side.
  static const double tileRadius = 0.23;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        label: 'SOLIS',
        image: true,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: SolisTheme.brand,
            borderRadius: BorderRadius.circular(size * tileRadius),
          ),
          child: const CustomPaint(painter: SplitSunPainter(color: Colors.white)),
        ),
      ),
    );
  }
}

/// Paints the split-sun glyph in a square canvas, in one color.
/// Usable on its own (for example on a brand-colored surface).
class SplitSunPainter extends CustomPainter {
  final Color color;

  const SplitSunPainter({required this.color});

  // Fractions of the tile side.
  static const double sunRadius = 0.23;
  static const double shift = 0.08;
  static const double gap = 0.025;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final origin = Offset((size.width - s) / 2, (size.height - s) / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final r = s * sunRadius;

    // Upper half: risen, shifted right.
    final dome = origin + Offset(s * (0.5 + shift), s * (0.5 - gap));
    canvas.drawArc(Rect.fromCircle(center: dome, radius: r), math.pi, math.pi, true, paint);

    // Lower half: written down, shifted left.
    final bowl = origin + Offset(s * (0.5 - shift), s * (0.5 + gap));
    canvas.drawArc(Rect.fromCircle(center: bowl, radius: r), 0, math.pi, true, paint);
  }

  @override
  bool shouldRepaint(covariant SplitSunPainter oldDelegate) => oldDelegate.color != color;
}
