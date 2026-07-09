import '../models/mask_draft.dart';
import '../models/port.dart';

/// Result of resolving a marquee selection into a port: either a valid
/// Port or a human-readable reason why the selection is rejected.
sealed class PortPlacement {
  const PortPlacement();
}

class PortPlacementOk extends PortPlacement {
  const PortPlacementOk(this.port);
  final Port port;
}

class PortPlacementError extends PortPlacement {
  const PortPlacementError(this.message);
  final String message;
}

/// Resolves a port marquee (absolute cell rectangle) against a mask.
///
/// Rules:
/// - The selection must be a single row or a single column.
/// - Every selected cell must belong to the mask's shape (freeform masks
///   use their painted cells, not just the bounding box).
/// - The strip must lie against the shape's edge on its travel axis:
///   a horizontal strip needs open space above or below every cell, a
///   vertical strip needs open space to the left or right. Open on both
///   sides (a one-cell-thick piece) makes the port a bidirectional
///   pass-through.
/// - A 1x1 selection may face any open side; horizontal wins ties.
PortPlacement resolvePortStrip({
  required MaskDraft mask,
  required int gridX,
  required int gridY,
  required int widthCells,
  required int heightCells,
}) {
  if (widthCells > 1 && heightCells > 1) {
    return const PortPlacementError(
        'Port selection must be a single row or a single column');
  }
  if (!mask.containsRect(gridX, gridY, widthCells, heightCells)) {
    return const PortPlacementError(
        'Port cells must all be inside the block shape');
  }

  final localX = gridX - mask.gridX;
  final localY = gridY - mask.gridY;

  bool rowOpen(int dy) {
    for (var x = gridX; x < gridX + widthCells; x++) {
      if (mask.containsCell(x, gridY + dy)) return false;
    }
    return true;
  }

  bool colOpen(int dx) {
    for (var y = gridY; y < gridY + heightCells; y++) {
      if (mask.containsCell(gridX + dx, y)) return false;
    }
    return true;
  }

  Port port(PortDirection direction, int span, bool bidirectional) => Port(
        localGridX: localX,
        localGridY: localY,
        direction: direction,
        span: span,
        bidirectional: bidirectional,
      );

  if (widthCells == 1 && heightCells == 1) {
    final left = colOpen(-1);
    final right = colOpen(1);
    final up = rowOpen(-1);
    final down = rowOpen(1);
    if (left && right) return PortPlacementOk(port(PortDirection.left, 1, true));
    if (up && down) return PortPlacementOk(port(PortDirection.up, 1, true));
    if (left) return PortPlacementOk(port(PortDirection.left, 1, false));
    if (right) return PortPlacementOk(port(PortDirection.right, 1, false));
    if (up) return PortPlacementOk(port(PortDirection.up, 1, false));
    if (down) return PortPlacementOk(port(PortDirection.down, 1, false));
    return const PortPlacementError('Port must touch the block edge');
  }

  if (heightCells == 1) {
    // Horizontal strip: travels up or down.
    final above = rowOpen(-1);
    final below = rowOpen(1);
    if (above && below) {
      return PortPlacementOk(port(PortDirection.up, widthCells, true));
    }
    if (above) return PortPlacementOk(port(PortDirection.up, widthCells, false));
    if (below) {
      return PortPlacementOk(port(PortDirection.down, widthCells, false));
    }
    return const PortPlacementError(
        'A horizontal port strip must lie against the top or bottom edge');
  }

  // Vertical strip: travels left or right.
  final left = colOpen(-1);
  final right = colOpen(1);
  if (left && right) {
    return PortPlacementOk(port(PortDirection.left, heightCells, true));
  }
  if (left) return PortPlacementOk(port(PortDirection.left, heightCells, false));
  if (right) {
    return PortPlacementOk(port(PortDirection.right, heightCells, false));
  }
  return const PortPlacementError(
      'A vertical port strip must lie against the left or right edge');
}
