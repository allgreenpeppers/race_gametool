import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/block_def.dart';

/// Renders one block's sprite by blitting its rect out of the packed
/// sheet, scaled to fit the widget while preserving aspect ratio.
class BlockThumbnail extends StatelessWidget {
  const BlockThumbnail({
    super.key,
    required this.image,
    required this.rect,
  });

  final ui.Image image;
  final SpriteSheetRect rect;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ThumbnailPainter(image: image, rect: rect),
      child: const SizedBox.expand(),
    );
  }
}

class _ThumbnailPainter extends CustomPainter {
  const _ThumbnailPainter({required this.image, required this.rect});

  final ui.Image image;
  final SpriteSheetRect rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect.w == 0 || rect.h == 0) return;
    final src = Rect.fromLTWH(
        rect.x.toDouble(), rect.y.toDouble(), rect.w.toDouble(), rect.h.toDouble());
    final scale =
        (size.width / rect.w).clamp(0.0, size.height / rect.h);
    final dstW = rect.w * scale;
    final dstH = rect.h * scale;
    final dst = Rect.fromLTWH(
      (size.width - dstW) / 2,
      (size.height - dstH) / 2,
      dstW,
      dstH,
    );
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_ThumbnailPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.rect.x != rect.x ||
      oldDelegate.rect.y != rect.y ||
      oldDelegate.rect.w != rect.w ||
      oldDelegate.rect.h != rect.h;
}
