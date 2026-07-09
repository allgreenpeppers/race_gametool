import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/port.dart';

/// Visual representation of a Port: a colored circle with an arrow
/// pointing along the port's direction. Used both in Phase 1 (defining
/// ports on a bounding box) and Phase 2 (showing ports on placed blocks).
class PortMarker extends StatelessWidget {
  const PortMarker({
    super.key,
    required this.direction,
    this.size = 24,
    this.color,
    this.selected = false,
    this.bidirectional = false,
  });

  final PortDirection direction;
  final double size;
  final bool bidirectional;

  /// Explicit color override. When null, cardinal ports render blue and
  /// diagonal ports render orange so routing modes are distinguishable
  /// at a glance.
  final Color? color;

  /// Selected ports (e.g. Port A during routing) get a highlight ring.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? defaultPortColor(direction);
    return CustomPaint(
      size: Size.square(size),
      painter: _PortMarkerPainter(
        direction: direction,
        color: effectiveColor,
        selected: selected,
        bidirectional: bidirectional,
      ),
    );
  }
}

/// Default color for a port of the given direction: blue for cardinal,
/// orange for diagonal.
Color defaultPortColor(PortDirection direction) => direction.isDiagonal
    ? Colors.orange.shade700
    : Colors.blue.shade600;

/// Paints a port glyph (colored disc plus direction arrow) directly onto
/// a canvas. Shared by the PortMarker widget and the editor canvases so
/// ports look identical everywhere.
void paintPort(
  Canvas canvas,
  Offset center,
  double radius,
  PortDirection direction, {
  Color? color,
  bool selected = false,
  bool bidirectional = false,
}) {
  final effectiveColor = color ?? defaultPortColor(direction);
  final circleRadius = radius * 0.62;

  if (selected) {
    canvas.drawCircle(
      center,
      radius * 0.92,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.14
        ..color = Colors.yellowAccent,
    );
  }

  canvas.drawCircle(center, circleRadius, Paint()..color = effectiveColor);
  canvas.drawCircle(
    center,
    circleRadius,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 0.1
      ..color = Colors.white,
  );

  // Arrow: a shaft through the center plus a two-line head, rotated to
  // the port direction. Drawn in white on top of the colored disc.
  final arrowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = radius * 0.16
    ..strokeCap = StrokeCap.round
    ..color = Colors.white;

  final angle = direction.angle;
  final tipDistance = circleRadius * 0.75;
  final tailDistance = bidirectional ? tipDistance : circleRadius * 0.55;
  final tip =
      center + Offset(math.cos(angle), math.sin(angle)) * tipDistance;
  final tail =
      center - Offset(math.cos(angle), math.sin(angle)) * tailDistance;
  canvas.drawLine(tail, tip, arrowPaint);

  const headSpread = math.pi * 0.8;
  final headLength = circleRadius * 0.55;
  void drawHead(Offset at, double headAngle) {
    for (final side in [headSpread, -headSpread]) {
      final wing = at +
          Offset(math.cos(headAngle + side), math.sin(headAngle + side)) *
              headLength;
      canvas.drawLine(at, wing, arrowPaint);
    }
  }

  drawHead(tip, angle);
  if (bidirectional) {
    // Pass-through port: arrowheads on both ends of the shaft.
    drawHead(tail, angle + math.pi);
  }
}

class _PortMarkerPainter extends CustomPainter {
  const _PortMarkerPainter({
    required this.direction,
    required this.color,
    required this.selected,
    required this.bidirectional,
  });

  final PortDirection direction;
  final Color color;
  final bool selected;
  final bool bidirectional;

  @override
  void paint(Canvas canvas, Size size) {
    paintPort(
      canvas,
      size.center(Offset.zero),
      size.shortestSide / 2,
      direction,
      color: color,
      selected: selected,
      bidirectional: bidirectional,
    );
  }

  @override
  bool shouldRepaint(_PortMarkerPainter oldDelegate) =>
      oldDelegate.direction != direction ||
      oldDelegate.color != color ||
      oldDelegate.selected != selected ||
      oldDelegate.bidirectional != bidirectional;
}
