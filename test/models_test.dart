import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/geometry.dart';
import 'package:race_gametool/models/map_scene.dart';
import 'package:race_gametool/models/port.dart';

void main() {
  group('PortDirection', () {
    test('opposite pairs are symmetric', () {
      for (final dir in PortDirection.values) {
        expect(dir.opposite.opposite, dir);
      }
    });

    test('gridDelta of opposite directions cancel out', () {
      for (final dir in PortDirection.values) {
        final (dx, dy) = dir.gridDelta;
        final (ox, oy) = dir.opposite.gridDelta;
        expect(dx + ox, 0);
        expect(dy + oy, 0);
      }
    });

    test('json round trip', () {
      for (final dir in PortDirection.values) {
        expect(PortDirection.fromJson(dir.jsonValue), dir);
      }
    });
  });

  group('BlockDef', () {
    test('json round trip preserves all fields', () {
      const original = BlockDef(
        id: 'fork_1_to_2',
        boundingBox: BoundingBox(width: 10, height: 15),
        spriteSheetRect: SpriteSheetRect(x: 32, y: 64, w: 160, h: 240),
        category: BlockCategory.islandTile,
        cornerType: CornerType.concave,
        ports: [
          Port(localGridX: 0, localGridY: 7, direction: PortDirection.left),
          Port(localGridX: 9, localGridY: 2, direction: PortDirection.right),
          Port(localGridX: 9, localGridY: 12, direction: PortDirection.diagDR),
        ],
        autoDecals: [
          AutoDecal(localGridX: 1, localGridY: 0, type: DecalType.kerbGradient),
        ],
        physicsTrackArea: [
          Vec2(0, 112),
          Vec2(160, 32),
          Vec2(160, 208),
          Vec2(0, 128),
        ],
        physicsHardWalls: [
          [Vec2(0, 96), Vec2(150, 16)],
          [Vec2(0, 144), Vec2(150, 224)],
        ],
        checkLines: [
          LineSegment(Vec2(80, 100), Vec2(80, 140)),
        ],
      );

      final decoded = BlockDef.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(decoded.id, original.id);
      expect(decoded.boundingBox.width, 10);
      expect(decoded.boundingBox.height, 15);
      expect(decoded.spriteSheetRect.x, 32);
      expect(decoded.spriteSheetRect.h, 240);
      expect(decoded.ports, original.ports);
      expect(decoded.category, BlockCategory.islandTile);
      expect(decoded.cornerType, CornerType.concave);
      expect(decoded.autoDecals.single.type, DecalType.kerbGradient);
      expect(decoded.physicsTrackArea, original.physicsTrackArea);
      expect(decoded.physicsHardWalls.length, 2);
      expect(decoded.physicsHardWalls[1], original.physicsHardWalls[1]);
      expect(decoded.checkLines.single.p1, const Vec2(80, 100));
    });

    test('missing optional lists decode as empty', () {
      final decoded = BlockDef.fromJson({
        'id': 'straight_v',
        'boundingBox': {'width': 5, 'height': 1},
        'spriteSheetRect': {'x': 0, 'y': 0, 'w': 80, 'h': 16},
      });
      expect(decoded.ports, isEmpty);
      expect(decoded.physicsHardWalls, isEmpty);
      expect(decoded.checkLines, isEmpty);
      // Legacy dicts without the new fields default sensibly.
      expect(decoded.category, BlockCategory.track);
      expect(decoded.cornerType, CornerType.none);
    });
  });

  group('MapScene', () {
    test('json round trip preserves placements and terrain', () {
      const original = MapScene(
        mapName: 'map_01',
        spawnPoint: SpawnPoint(gridX: 12, gridY: 8, facingAngle: 1.5708),
        placements: [
          BlockPlacement(blockId: 'corner_top_left', gridX: 0, gridY: 0),
          BlockPlacement(blockId: 'straight_h', gridX: 6, gridY: 0),
        ],
        islandTerrain: [
          [0, 0, 0, 0],
          [0, 1, 1, 0],
          [0, 1, 1, 0],
          [0, 0, 0, 0],
        ],
      );

      final decoded = MapScene.fromJson(
          jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>);

      expect(decoded.mapName, 'map_01');
      expect(decoded.spawnPoint.facingAngle, closeTo(1.5708, 1e-9));
      expect(decoded.placements.length, 2);
      expect(decoded.placements[1].blockId, 'straight_h');
      expect(decoded.islandTerrain[1][2], 1);
      expect(decoded.islandTerrain[0][0], 0);
    });
  });
}
