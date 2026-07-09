import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/port_placement.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/models/port.dart';

Port _expectOk(PortPlacement placement) {
  expect(placement, isA<PortPlacementOk>(),
      reason: placement is PortPlacementError ? placement.message : null);
  return (placement as PortPlacementOk).port;
}

String _expectError(PortPlacement placement) {
  expect(placement, isA<PortPlacementError>());
  return (placement as PortPlacementError).message;
}

void main() {
  group('resolvePortStrip on solid rectangles', () {
    // A 5 x 3 block at grid (10, 20).
    const mask = MaskDraft(
        id: 'b', gridX: 10, gridY: 20, widthCells: 5, heightCells: 3);

    test('horizontal strip on top edge faces UP', () {
      final port = _expectOk(resolvePortStrip(
          mask: mask, gridX: 10, gridY: 20, widthCells: 5, heightCells: 1));
      expect(port.direction, PortDirection.up);
      expect(port.span, 5);
      expect(port.bidirectional, isFalse);
      expect(port.localGridX, 0);
      expect(port.localGridY, 0);
    });

    test('horizontal strip on bottom edge faces DOWN', () {
      final port = _expectOk(resolvePortStrip(
          mask: mask, gridX: 11, gridY: 22, widthCells: 3, heightCells: 1));
      expect(port.direction, PortDirection.down);
      expect(port.span, 3);
    });

    test('vertical strip on left edge faces LEFT', () {
      final port = _expectOk(resolvePortStrip(
          mask: mask, gridX: 10, gridY: 20, widthCells: 1, heightCells: 3));
      expect(port.direction, PortDirection.left);
      expect(port.span, 3);
      expect(port.bidirectional, isFalse);
    });

    test('interior horizontal strip is rejected', () {
      _expectError(resolvePortStrip(
          mask: mask, gridX: 11, gridY: 21, widthCells: 3, heightCells: 1));
    });

    test('two-dimensional selection is rejected', () {
      _expectError(resolvePortStrip(
          mask: mask, gridX: 10, gridY: 20, widthCells: 2, heightCells: 2));
    });

    test('strip escaping the mask is rejected', () {
      _expectError(resolvePortStrip(
          mask: mask, gridX: 13, gridY: 20, widthCells: 4, heightCells: 1));
    });
  });

  group('resolvePortStrip pass-through detection', () {
    test('full-width strip on a one-row block is bidirectional', () {
      // 5 x 1 straight slice: the strip touches top and bottom at once.
      const thin = MaskDraft(
          id: 'straight', gridX: 0, gridY: 0, widthCells: 5, heightCells: 1);
      final port = _expectOk(resolvePortStrip(
          mask: thin, gridX: 0, gridY: 0, widthCells: 5, heightCells: 1));
      expect(port.bidirectional, isTrue);
      expect(port.direction, PortDirection.up);
      expect(port.span, 5);
    });

    test('vertical strip on a one-column block is bidirectional', () {
      const thin = MaskDraft(
          id: 'straight_v', gridX: 3, gridY: 3, widthCells: 1, heightCells: 5);
      final port = _expectOk(resolvePortStrip(
          mask: thin, gridX: 3, gridY: 4, widthCells: 1, heightCells: 3));
      expect(port.bidirectional, isTrue);
      expect(port.direction, PortDirection.left);
      expect(port.span, 3);
    });
  });

  group('resolvePortStrip on freeform shapes', () {
    // T-shaped piece: a 5-cell top bar with a 3-cell stem below its center.
    final tShape = MaskDraft.fromCells(id: 't', absoluteCells: {
      (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
      (2, 1), (2, 2), (2, 3),
    });

    test('top bar strip faces UP despite the stem below', () {
      final port = _expectOk(resolvePortStrip(
          mask: tShape, gridX: 0, gridY: 0, widthCells: 5, heightCells: 1));
      // The stem cell (2,1) blocks the downward side, so this is not
      // bidirectional even though the bar is one cell thick.
      expect(port.direction, PortDirection.up);
      expect(port.bidirectional, isFalse);
      expect(port.span, 5);
    });

    test('bar segment beside the stem is DOWN-capable', () {
      final port = _expectOk(resolvePortStrip(
          mask: tShape, gridX: 0, gridY: 0, widthCells: 2, heightCells: 1));
      // Left part of the bar: open above and below.
      expect(port.bidirectional, isTrue);
    });

    test('strip crossing an unpainted gap is rejected', () {
      _expectError(resolvePortStrip(
          mask: tShape, gridX: 0, gridY: 1, widthCells: 3, heightCells: 1));
    });

    test('stem cell strip is a LEFT-RIGHT pass-through', () {
      final port = _expectOk(resolvePortStrip(
          mask: tShape, gridX: 2, gridY: 1, widthCells: 1, heightCells: 3));
      expect(port.direction, PortDirection.left);
      expect(port.bidirectional, isTrue);
      expect(port.span, 3);
    });

    test('diagonal arm cells accept single-cell ports at their ends', () {
      // Diagonal staircase piece.
      final diag = MaskDraft.fromCells(id: 'diag', absoluteCells: {
        (0, 2), (1, 2), (1, 1), (2, 1), (2, 0), (3, 0),
      });
      final port = _expectOk(resolvePortStrip(
          mask: diag, gridX: 3, gridY: 0, widthCells: 1, heightCells: 1));
      // End of the staircase: open up, right, and below; horizontal
      // pass-through is not possible because (2,0) occupies the left.
      expect(port.span, 1);
      expect(port.direction, isNot(PortDirection.left));
    });
  });

  group('MaskDraft.fromCells', () {
    test('computes bounding box and localizes cells', () {
      final mask = MaskDraft.fromCells(
          id: 'm', absoluteCells: {(5, 7), (6, 7), (6, 8)});
      expect(mask.gridX, 5);
      expect(mask.gridY, 7);
      expect(mask.widthCells, 2);
      expect(mask.heightCells, 2);
      expect(mask.isFreeform, isTrue);
      expect(mask.containsCell(5, 7), isTrue);
      expect(mask.containsCell(5, 8), isFalse);
    });

    test('a filled rectangle collapses to a solid mask', () {
      final mask = MaskDraft.fromCells(
          id: 'm', absoluteCells: {(1, 1), (2, 1), (1, 2), (2, 2)});
      expect(mask.isFreeform, isFalse);
      expect(mask.containsCell(2, 2), isTrue);
    });
  });
}
