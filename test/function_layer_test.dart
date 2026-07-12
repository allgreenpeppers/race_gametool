import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/geometry.dart';
import 'package:race_gametool/models/map_scene.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/models/function_layer.dart';
import 'package:race_gametool/logic/function_layer_generator.dart';

void main() {
  group('FunctionLayerGenerator', () {
    final straightBlock = BlockDef(
      id: 'straight_1',
      boundingBox: const BoundingBox(width: 5, height: 1), // 80 x 16 px
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 16),
      category: BlockCategory.track,
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 1),
        Port(localGridX: 4, localGridY: 0, direction: PortDirection.right, span: 1),
      ],
      physicsHardWalls: const [
        [Vec2(0, 0), Vec2(80, 0)],
        [Vec2(0, 16), Vec2(80, 16)],
      ],
    );

    final turnBlock = BlockDef(
      id: 'turn_1',
      boundingBox: const BoundingBox(width: 5, height: 5), // 80 x 80 px
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
      category: BlockCategory.track,
      ports: const [
        Port(localGridX: 0, localGridY: 2, direction: PortDirection.left, span: 1),
        Port(localGridX: 2, localGridY: 0, direction: PortDirection.up, span: 1),
      ],
      physicsHardWalls: const [
        // Inner wall (shorter)
        [Vec2(0, 32), Vec2(32, 32), Vec2(32, 0)],
        // Outer wall (longer)
        [Vec2(0, 48), Vec2(48, 48), Vec2(48, 0)],
      ],
    );

    BlockDef? defOf(String id) {
      if (id == 'straight_1') return straightBlock;
      if (id == 'turn_1') return turnBlock;
      return null;
    }

    test('generates straight check lines at intervals', () {
      final placements = [
        const BlockPlacement(blockId: 'straight_1', gridX: 0, gridY: 0),
      ];
      final settings = const FunctionLayerSettings(
        straightCheckInterval: 30.0,
      );

      final (checkLines, _) = FunctionLayerGenerator.generate(
        placements: placements,
        defOf: defOf,
        settings: settings,
      );

      // Port A is at (8, 8), Port B is at (72, 8). Length is 64 px.
      // With interval 30.0, we expect check lines at d = 30.0, 60.0.
      expect(checkLines.length, 2);
      expect(checkLines[0].forwardVector.x, closeTo(1.0, 0.001));
      expect(checkLines[0].forwardVector.y, closeTo(0.0, 0.001));
      expect(checkLines[0].p1.y, closeTo(0.0, 0.001));
      expect(checkLines[0].p2.y, closeTo(16.0, 0.001));
    });

    test('generates turn apex check line and outer beveled boundary', () {
      final placements = [
        const BlockPlacement(blockId: 'turn_1', gridX: 0, gridY: 0),
      ];
      final settings = const FunctionLayerSettings(
        boundaryOffset: 4.0,
        curveExtension: 10.0,
        bevelRatio: 0.2,
      );

      final (checkLines, boundaries) = FunctionLayerGenerator.generate(
        placements: placements,
        defOf: defOf,
        settings: settings,
      );

      expect(checkLines.length, 1);
      // Entry is Port A (left edge), Exit is Port B (top edge).
      // tangent vector at 45 degrees points UP-RIGHT: (1/sqrt(2), -1/sqrt(2))
      final f = checkLines[0].forwardVector;
      expect(f.x, closeTo(0.707, 0.002));
      expect(f.y, closeTo(-0.707, 0.002));

      // Inner turn boundary is classified as antiCutRed (open polyline)
      final antiCutBoundaries = boundaries.where((b) => b.type == 'antiCutRed').toList();
      expect(antiCutBoundaries.length, 1);
      final bVertices = antiCutBoundaries[0].vertices;
      expect(bVertices.length, 3);

      // Verify the coordinate math for the inner offset (towards Top-Left)
      // V1: (0, 28)
      // V2: (29.172, 29.172)
      // V3: (28, 0)
      expect(bVertices[0], const Vec2(0, 28));
      expect(bVertices[1].x, closeTo(29.172, 0.001));
      expect(bVertices[1].y, closeTo(29.172, 0.001));
      expect(bVertices[2], const Vec2(28, 0));
    });

    test('generates outer world boundary conforming to island grass mask shape', () {
      final placements = [
        const BlockPlacement(blockId: 'straight_1', gridX: 0, gridY: 0),
      ];
      final settings = const FunctionLayerSettings();
      final grassMask = {
        (0, 0), (1, 0),
        (0, 1), (1, 1),
      }; // A 2x2 grid of cells

      final (checkLines, boundaries) = FunctionLayerGenerator.generate(
        placements: placements,
        defOf: defOf,
        settings: settings,
        islandGrassMask: grassMask,
      );

      final worldBoundaries = boundaries.where((b) => b.type == 'outerWorld').toList();
      expect(worldBoundaries.length, 1);
      final vertices = worldBoundaries[0].vertices;
      // 2x2 cells at 16px size forms a 32x32 px square.
      // Traced vertices should be 9 points (since it includes the closing vertex).
      expect(vertices.length, 9);
      expect(vertices, contains(const Vec2(0, 0)));
      expect(vertices, contains(const Vec2(32, 0)));
      expect(vertices, contains(const Vec2(32, 32)));
      expect(vertices, contains(const Vec2(0, 32)));
    });
  });
}
