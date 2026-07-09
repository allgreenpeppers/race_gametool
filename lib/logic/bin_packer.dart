import 'dart:math' as math;

/// One packed rectangle. [index] refers back to the input list order,
/// so callers can map results to their source sprites.
class PackedRect {
  const PackedRect({
    required this.index,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int index;
  final int x;
  final int y;
  final int width;
  final int height;
}

/// Result of packing: the tight sheet size actually used plus placements.
class BinPackResult {
  const BinPackResult({
    required this.sheetWidth,
    required this.sheetHeight,
    required this.rects,
  });

  final int sheetWidth;
  final int sheetHeight;
  final List<PackedRect> rects;
}

class _FreeRect {
  _FreeRect(this.x, this.y, this.w, this.h);
  int x, y, w, h;

  bool contains(_FreeRect other) =>
      other.x >= x &&
      other.y >= y &&
      other.x + other.w <= x + w &&
      other.y + other.h <= y + h;
}

/// MaxRects bin packer using the Best Short Side Fit heuristic.
/// No rotation: track sprites are direction-sensitive.
class MaxRectsPacker {
  MaxRectsPacker(this.binWidth, this.binHeight)
      : _free = [_FreeRect(0, 0, binWidth, binHeight)];

  final int binWidth;
  final int binHeight;
  final List<_FreeRect> _free;

  /// Places a w x h rectangle, or returns null if it does not fit.
  ({int x, int y})? insert(int w, int h) {
    _FreeRect? best;
    var bestShort = 1 << 30;
    var bestLong = 1 << 30;

    for (final rect in _free) {
      if (rect.w < w || rect.h < h) continue;
      final leftoverX = rect.w - w;
      final leftoverY = rect.h - h;
      final shortSide = math.min(leftoverX, leftoverY);
      final longSide = math.max(leftoverX, leftoverY);
      if (shortSide < bestShort ||
          (shortSide == bestShort && longSide < bestLong)) {
        best = rect;
        bestShort = shortSide;
        bestLong = longSide;
      }
    }
    if (best == null) return null;

    final placed = _FreeRect(best.x, best.y, w, h);
    _splitFreeRects(placed);
    _pruneFreeRects();
    return (x: placed.x, y: placed.y);
  }

  void _splitFreeRects(_FreeRect used) {
    final next = <_FreeRect>[];
    for (final free in _free) {
      final overlaps = used.x < free.x + free.w &&
          used.x + used.w > free.x &&
          used.y < free.y + free.h &&
          used.y + used.h > free.y;
      if (!overlaps) {
        next.add(free);
        continue;
      }
      // Up to four leftover slices around the used area.
      if (used.y > free.y) {
        next.add(_FreeRect(free.x, free.y, free.w, used.y - free.y));
      }
      if (used.y + used.h < free.y + free.h) {
        next.add(_FreeRect(free.x, used.y + used.h, free.w,
            free.y + free.h - (used.y + used.h)));
      }
      if (used.x > free.x) {
        next.add(_FreeRect(free.x, free.y, used.x - free.x, free.h));
      }
      if (used.x + used.w < free.x + free.w) {
        next.add(_FreeRect(used.x + used.w, free.y,
            free.x + free.w - (used.x + used.w), free.h));
      }
    }
    _free
      ..clear()
      ..addAll(next);
  }

  void _pruneFreeRects() {
    for (var i = 0; i < _free.length; i++) {
      for (var j = i + 1; j < _free.length; j++) {
        if (_free[j].contains(_free[i])) {
          _free.removeAt(i);
          i--;
          break;
        }
        if (_free[i].contains(_free[j])) {
          _free.removeAt(j);
          j--;
        }
      }
    }
  }
}

/// Packs [sizes] (width, height) into the smallest bin that fits, growing
/// from a heuristic start size up to [maxBinSize]. [padding] pixels of
/// transparent gutter are reserved to the right and bottom of every sprite
/// to prevent texture bleeding when the game samples the sheet.
///
/// Throws [StateError] if the sprites cannot fit even at [maxBinSize].
BinPackResult packSprites(
  List<({int width, int height})> sizes, {
  int padding = 2,
  int maxBinSize = 8192,
}) {
  if (sizes.isEmpty) {
    return const BinPackResult(sheetWidth: 0, sheetHeight: 0, rects: []);
  }

  var maxW = 0;
  var maxH = 0;
  var totalArea = 0;
  for (final s in sizes) {
    maxW = math.max(maxW, s.width + padding);
    maxH = math.max(maxH, s.height + padding);
    totalArea += (s.width + padding) * (s.height + padding);
  }

  var binW = _nextPowerOfTwo(math.max(maxW, math.sqrt(totalArea).ceil()));
  var binH = _nextPowerOfTwo(maxH);
  binW = math.max(binW, 64);
  binH = math.max(binH, 64);

  // Largest area first gives MaxRects its best results.
  final order = List<int>.generate(sizes.length, (i) => i)
    ..sort((a, b) => (sizes[b].width * sizes[b].height)
        .compareTo(sizes[a].width * sizes[a].height));

  while (binW <= maxBinSize && binH <= maxBinSize) {
    final packer = MaxRectsPacker(binW, binH);
    final placed = <PackedRect>[];
    var failed = false;

    for (final index in order) {
      final size = sizes[index];
      final pos = packer.insert(size.width + padding, size.height + padding);
      if (pos == null) {
        failed = true;
        break;
      }
      placed.add(PackedRect(
        index: index,
        x: pos.x,
        y: pos.y,
        width: size.width,
        height: size.height,
      ));
    }

    if (!failed) {
      var usedW = 0;
      var usedH = 0;
      for (final r in placed) {
        usedW = math.max(usedW, r.x + r.width);
        usedH = math.max(usedH, r.y + r.height);
      }
      placed.sort((a, b) => a.index.compareTo(b.index));
      return BinPackResult(
          sheetWidth: usedW, sheetHeight: usedH, rects: placed);
    }

    // Grow the smaller dimension first to stay near-square.
    if (binH < binW) {
      binH *= 2;
    } else {
      binW *= 2;
    }
  }
  throw StateError(
      'Sprites do not fit in the maximum bin size of $maxBinSize px');
}

int _nextPowerOfTwo(int value) {
  var v = 1;
  while (v < value) {
    v *= 2;
  }
  return v;
}
