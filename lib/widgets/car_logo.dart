import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Shared minimalist car logo — drawn with CustomPainter.
/// [onRed] = true  → white car on red background (splash, headers)
/// [onRed] = false → red car on white background (entry screen)
class CarLogo extends StatelessWidget {
  final double size;
  final bool onRed;

  const CarLogo({super.key, this.size = 100, this.onRed = true});

  @override
  Widget build(BuildContext context) {
    // Canvas is 5:3 ratio — wide, low silhouette
    return SizedBox(
      width: size,
      height: size * 0.6,
      child: CustomPaint(
        painter: _CarPainter(onRed: onRed),
      ),
    );
  }
}

class _CarPainter extends CustomPainter {
  final bool onRed;
  const _CarPainter({required this.onRed});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final carColor = onRed ? Colors.white : const Color(0xFFFF0000);
    final bgColor  = onRed ? const Color(0xFFFF0000) : Colors.white;

    final fill = Paint()..color = carColor..style = PaintingStyle.fill;
    final cut  = Paint()..color = bgColor..style  = PaintingStyle.fill;

    // ── Key measurements ──────────────────────────────────
    final double groundY = h * 0.90;
    final double bodyTopY = h * 0.52;
    final double bodyL   = w * 0.03;
    final double bodyR   = w * 0.97;

    // ── 1. Body slab — low wedge with chamfered corners ───
    final body = Path();
    body.moveTo(bodyL + w * 0.05, bodyTopY);          // front top
    body.lineTo(bodyR - w * 0.04, bodyTopY);          // rear top
    body.lineTo(bodyR,            bodyTopY + h * 0.10); // rear-top chamfer
    body.lineTo(bodyR,            groundY  - h * 0.20); // rear side
    body.lineTo(bodyR - w * 0.02, groundY  - h * 0.08); // rear-bot chamfer
    body.lineTo(bodyL + w * 0.02, groundY  - h * 0.08); // underside
    body.lineTo(bodyL,            groundY  - h * 0.20); // front-bot chamfer
    body.lineTo(bodyL,            bodyTopY + h * 0.10); // front side
    body.close();
    canvas.drawPath(body, fill);

    // ── 2. Cabin — sleek fastback profile ─────────────────
    final double aBase  = w * 0.27;   // A-pillar base x
    final double cBase  = w * 0.81;   // C-pillar base x
    final double aTop   = w * 0.34;   // A-pillar top  x
    final double cTop   = w * 0.72;   // C-pillar top  x
    final double roofY  = h * 0.05;   // roof height

    final cabin = Path();
    cabin.moveTo(aBase, bodyTopY);
    // A-pillar — steeply raked
    cabin.lineTo(aTop, roofY + h * 0.02);
    // Roof — almost flat
    cabin.quadraticBezierTo(w * 0.53, roofY, cTop, roofY + h * 0.02);
    // C-pillar — fastback sweep
    cabin.lineTo(cBase, bodyTopY);
    cabin.close();
    canvas.drawPath(cabin, fill);

    // ── 3. Windshield (front glass) ───────────────────────
    final ws = Path();
    ws.moveTo(aBase + w * 0.018, bodyTopY - h * 0.005);
    ws.lineTo(aTop  + w * 0.014, roofY   + h * 0.06);
    ws.lineTo(w * 0.508,         roofY   + h * 0.025);
    ws.lineTo(w * 0.508,         bodyTopY - h * 0.005);
    ws.close();
    canvas.drawPath(ws, cut);

    // ── 4. Rear screen — fastback rake ────────────────────
    final rs = Path();
    rs.moveTo(w * 0.524,         bodyTopY - h * 0.005);
    rs.lineTo(w * 0.524,         roofY   + h * 0.025);
    rs.lineTo(cTop  - w * 0.014, roofY   + h * 0.06);
    rs.lineTo(cBase - w * 0.018, bodyTopY - h * 0.005);
    rs.close();
    canvas.drawPath(rs, cut);

    // ── 5. Side crease line ───────────────────────────────
    final crease = Paint()
      ..color = bgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = h * 0.028
      ..strokeCap = StrokeCap.butt;
    final creaseY = bodyTopY + h * 0.30;
    // Slight upward kick toward rear (character line)
    final cPath = Path();
    cPath.moveTo(bodyL + w * 0.08, creaseY + h * 0.02);
    cPath.quadraticBezierTo(
      w * 0.55, creaseY,
      bodyR - w * 0.06, creaseY - h * 0.04,
    );
    canvas.drawPath(cPath, crease);

    // ── 6. DRL / tail lamps — angular slash cuts ──────────
    // Front DRL
    final drl = Path();
    drl.moveTo(bodyL,            bodyTopY + h * 0.08);
    drl.lineTo(bodyL,            bodyTopY + h * 0.20);
    drl.lineTo(bodyL + w * 0.05, bodyTopY + h * 0.16);
    drl.lineTo(bodyL + w * 0.05, bodyTopY + h * 0.09);
    drl.close();
    canvas.drawPath(drl, cut);

    // Rear lamp
    final lamp = Path();
    lamp.moveTo(bodyR,            bodyTopY + h * 0.08);
    lamp.lineTo(bodyR,            bodyTopY + h * 0.20);
    lamp.lineTo(bodyR - w * 0.05, bodyTopY + h * 0.16);
    lamp.lineTo(bodyR - w * 0.05, bodyTopY + h * 0.09);
    lamp.close();
    canvas.drawPath(lamp, cut);

    // ── 7. Wheels — staggered, low-profile ────────────────
    final double tireR = h * 0.275;
    final double rimR  = h * 0.175;
    final double hubR  = h * 0.062;
    final double wheelY = groundY - h * 0.12;

    final spokes = Paint()
      ..color = carColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.016
      ..strokeCap = StrokeCap.butt;

    for (final cx in [w * 0.235, w * 0.765]) {
      // Tyre
      canvas.drawCircle(Offset(cx, wheelY), tireR, fill);
      // Rim void
      canvas.drawCircle(Offset(cx, wheelY), rimR, cut);
      // 5 spokes
      for (int i = 0; i < 5; i++) {
        final a = (i * 72 - 90) * math.pi / 180;
        canvas.drawLine(
          Offset(cx + hubR * 1.15 * math.cos(a), wheelY + hubR * 1.15 * math.sin(a)),
          Offset(cx + rimR * 0.87 * math.cos(a), wheelY + rimR * 0.87 * math.sin(a)),
          spokes,
        );
      }
      // Centre hub
      canvas.drawCircle(Offset(cx, wheelY), hubR, fill);
      canvas.drawCircle(Offset(cx, wheelY), hubR * 0.42, cut);
    }

    // ── 8. Wheel arch cutouts from body ───────────────────
    // Makes the body look like it sits around the wheels properly
    canvas.drawCircle(Offset(w * 0.235, wheelY), tireR + h * 0.02, cut);
    canvas.drawCircle(Offset(w * 0.765, wheelY), tireR + h * 0.02, cut);

    // Re-draw body over arch cutout edges (clean clip)
    // Front bumper lip
    final fBumper = Path();
    fBumper.moveTo(bodyL,            groundY - h * 0.20);
    fBumper.lineTo(w * 0.135,        groundY - h * 0.08);
    fBumper.lineTo(bodyL + w * 0.02, groundY - h * 0.08);
    fBumper.lineTo(bodyL,            groundY - h * 0.20);
    fBumper.close();
    canvas.drawPath(fBumper, fill);

    // Rear bumper lip
    final rBumper = Path();
    rBumper.moveTo(bodyR,            groundY - h * 0.20);
    rBumper.lineTo(w * 0.865,        groundY - h * 0.08);
    rBumper.lineTo(bodyR - w * 0.02, groundY - h * 0.08);
    rBumper.lineTo(bodyR,            groundY - h * 0.20);
    rBumper.close();
    canvas.drawPath(rBumper, fill);

    // Centre sill bar
    final sill = Path();
    sill.moveTo(w * 0.135, groundY - h * 0.08);
    sill.lineTo(w * 0.865, groundY - h * 0.08);
    sill.lineTo(w * 0.865, groundY - h * 0.01);
    sill.lineTo(w * 0.135, groundY - h * 0.01);
    sill.close();
    canvas.drawPath(sill, fill);
  }

  @override
  bool shouldRepaint(covariant _CarPainter old) => old.onRed != onRed;
}