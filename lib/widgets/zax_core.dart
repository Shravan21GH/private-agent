import 'dart:math' as math;
import 'package:flutter/material.dart';

/// The glowing Jarvis-style "brain" of Zax. It is drawn with code, so it needs
/// no image files, and it fades smoothly to the colour of the current mode.
///
/// Speed notes: the glow of each ring is now drawn ONCE per ring (not once per
/// little segment), and when [lite] is true (small core while chatting or
/// while the keyboard is open) the expensive extras are skipped.
class ZaxCore extends StatefulWidget {
  final Color color;
  final bool active; // true while Zax is thinking or listening
  final bool lite; // true = cheaper drawing for the small version

  const ZaxCore({
    super.key,
    required this.color,
    this.active = false,
    this.lite = false,
  });

  @override
  State<ZaxCore> createState() => _ZaxCoreState();
}

class _ZaxCoreState extends State<ZaxCore>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: widget.color),
        duration: const Duration(milliseconds: 600),
        builder: (context, animatedColor, child) {
          final color = animatedColor ?? widget.color;
          return AspectRatio(
            aspectRatio: 1,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  painter: _ZaxCorePainter(
                    t: _controller.value,
                    color: color,
                    active: widget.active,
                    lite: widget.lite,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ZaxCorePainter extends CustomPainter {
  final double t; // 0..1, repeats every 30 seconds
  final Color color;
  final bool active;
  final bool lite;

  _ZaxCorePainter({
    required this.t,
    required this.color,
    required this.active,
    required this.lite,
  });

  static const double _tau = math.pi * 2;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final pulse = 0.5 + 0.5 * math.sin(t * _tau * (active ? 20 : 6));
    final light = Color.lerp(color, Colors.white, 0.55)!;

    // Soft background glow
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withOpacity(0.30 + 0.12 * pulse),
            color.withOpacity(0.08),
            color.withOpacity(0.0),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );

    // Tilted orbit rings (like the reference picture)
    final orbit = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = color.withOpacity(0.55);
    for (int k = 0; k < 3; k++) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(k * math.pi / 3 + t * _tau * (k.isEven ? 1 : -1) * 2);
      canvas.scale(1.0, 0.38);
      canvas.drawCircle(Offset.zero, r * 0.8, orbit);
      canvas.restore();
    }

    // Broken, rotating rings
    _ring(canvas, center, r * 0.96, 1.2, 120, 0.5, t * _tau, 0.5, false);
    _ring(canvas, center, r * 0.86, 2.4, 36, 0.62, -t * _tau * 2, 0.8, true);
    _ring(canvas, center, r * 0.70, 1.0, 60, 0.4, t * _tau * 3, 0.6, false);
    _ring(canvas, center, r * 0.52, 3.0, 8, 0.55, -t * _tau * 4, 0.9, true);

    // Spokes (the thin glowing lines)
    final spoke = Paint()
      ..strokeWidth = 1.0
      ..color = color.withOpacity(0.35);
    final int spokeCount = lite ? 12 : 22;
    for (int i = 0; i < spokeCount; i++) {
      final a = i * _tau / spokeCount + t * _tau;
      final len = 0.45 + 0.35 * (0.5 + 0.5 * math.sin(i * 1.7 + t * _tau * 5));
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(
        center + dir * (r * 0.2),
        center + dir * (r * (0.2 + len)),
        spoke,
      );
    }

    // Floating particles (skipped in the small version)
    if (!lite) {
      final dot = Paint();
      for (int i = 0; i < 40; i++) {
        final k = (i % 3) + 1;
        final spin = i.isEven ? 1 : -1;
        final a = i * 2.399963 + spin * t * _tau * k;
        final rf = 0.22 + 0.72 * (((i * 37) % 100) / 100);
        final twinkle = 0.5 + 0.5 * math.sin(i * 1.3 + t * _tau * 8);
        dot.color = light.withOpacity(0.25 + 0.65 * twinkle);
        canvas.drawCircle(
          center + Offset(math.cos(a), math.sin(a)) * (r * rf),
          1.0 + (i % 4) * 0.6,
          dot,
        );
      }
    }

    // Glowing core
    final coreR = r * (0.09 + 0.012 * pulse);
    canvas.drawCircle(
      center,
      coreR * 3.2,
      Paint()
        ..shader = RadialGradient(
          colors: [
            light.withOpacity(0.9),
            color.withOpacity(0.35),
            color.withOpacity(0.0),
          ],
        ).createShader(Rect.fromCircle(center: center, radius: coreR * 3.2)),
    );
    for (int j = 0; j < 3; j++) {
      canvas.drawCircle(
        center,
        coreR * (1.0 + 0.55 * j),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = light.withOpacity(0.9 - 0.2 * j),
      );
    }
    canvas.drawCircle(
      center,
      coreR * 0.45,
      Paint()..color = Colors.white.withOpacity(0.95),
    );
  }

  void _ring(
    Canvas canvas,
    Offset center,
    double radius,
    double stroke,
    int segments,
    double fill,
    double rotation,
    double opacity,
    bool glow,
  ) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final step = _tau / segments;

    // All the little arcs of one ring go into ONE path, so the ring is
    // drawn with a single call instead of dozens.
    final path = Path();
    for (int i = 0; i < segments; i++) {
      path.addArc(rect, rotation + i * step, step * fill);
    }

    if (glow && !lite) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 2.5
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
          ..color = color.withOpacity(opacity * 0.6),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color.withOpacity(opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _ZaxCorePainter old) =>
      old.t != t ||
      old.color != color ||
      old.active != active ||
      old.lite != lite;
}
