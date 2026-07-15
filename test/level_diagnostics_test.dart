import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/level_diagnostics.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/geometry.dart';
import 'package:race_gametool/models/map_scene.dart';
import 'package:race_gametool/models/port.dart';

/// Horizontal straight: width w, height 1 (a length-1 pass-through when
/// w==1, otherwise a thin road with LEFT/RIGHT end ports of [span]).
BlockDef _straight(String id, {required int w, required int span}) => BlockDef(
      id: id,
      boundingBox: BoundingBox(width: w, height: 1),
      spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: w * 16, h: 16),
      ports: [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: span),
        Port(
            localGridX: w - 1,
            localGridY: 0,
            direction: PortDirection.right,
            span: span),
      ],
    );

/// A 5-tall vertical straight tile, 1 wide, span-5 pass-through.
BlockDef _vStraight5(String id) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 1, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 16, h: 80),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.up, span: 1),
        Port(
            localGridX: 0,
            localGridY: 4,
            direction: PortDirection.down,
            span: 1),
      ],
    );

void main() {
  BlockDef? Function(String) libOf(List<BlockDef> defs) =>
      (id) => defs.where((d) => d.id == id).firstOrNull;

  test('a single isolated block warns on every free port side', () {
    final lib = [_straight('s', w: 3, span: 1)];
    final diags = validateLevel(
      [const BlockPlacement(blockId: 's', gridX: 0, gridY: 0)],
      libOf(lib),
    );
    // LEFT and RIGHT ports both free -> 2 warnings, no errors.
    expect(diags.where((d) => d.severity == DiagnosticSeverity.error), isEmpty);
    expect(
        diags.where((d) => d.severity == DiagnosticSeverity.warning).length, 2);
  });

  test('two aligned same-span straights connect cleanly', () {
    final lib = [_straight('s', w: 3, span: 1)];
    final diags = validateLevel(
      const [
        BlockPlacement(blockId: 's', gridX: 0, gridY: 0), // x0..2
        BlockPlacement(blockId: 's', gridX: 3, gridY: 0), // x3..5, abuts
      ],
      libOf(lib),
    );
    // Inner ports connect; only the two outer ends remain free (warnings).
    expect(diags.where((d) => d.severity == DiagnosticSeverity.error), isEmpty);
    expect(
        diags.where((d) => d.severity == DiagnosticSeverity.warning).length, 2);
  });

  test('span mismatch (4 meeting 5) is an error', () {
    final lib = [
      _vStraight5('a'), // span-5 ... actually build explicit mismatch below
    ];
    // Two horizontal straights, same width but different port spans.
    final s4 = BlockDef(
      id: 's4',
      boundingBox: const BoundingBox(width: 3, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 48, h: 80),
      ports: const [
        Port(localGridX: 2, localGridY: 0, direction: PortDirection.right, span: 4),
      ],
    );
    final s5 = BlockDef(
      id: 's5',
      boundingBox: const BoundingBox(width: 3, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 48, h: 80),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
      ],
    );
    final diags = validateLevel(
      const [
        BlockPlacement(blockId: 's4', gridX: 0, gridY: 0), // x0..2
        BlockPlacement(blockId: 's5', gridX: 3, gridY: 0), // x3..5
      ],
      libOf([s4, s5, ...lib]),
    );
    expect(diags.any((d) => d.severity == DiagnosticSeverity.error), isTrue,
        reason: 'span 4 facing span 5 should error');
  });

  test('island tiles are excluded from port diagnostics', () {
    // An island tile with 8-direction ports would otherwise flood the panel
    // with "not connected" warnings.
    final islandTile = BlockDef(
      id: 'grass',
      boundingBox: const BoundingBox(width: 1, height: 1),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 16, h: 16),
      category: BlockCategory.islandTile,
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.up),
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.diagUR),
      ],
    );
    // A track piece sitting on the same cells (layers overlap) must not be
    // reported as connecting to the island tile.
    final track = _straight('road', w: 3, span: 1);
    final diags = validateLevel(
      const [
        BlockPlacement(blockId: 'grass', gridX: 0, gridY: 0),
        BlockPlacement(blockId: 'road', gridX: 0, gridY: 0),
      ],
      libOf([islandTile, track]),
    );
    // Only the road's two free end ports warn; the island tile is ignored,
    // and the overlapping island cell does not corrupt the road's checks.
    expect(diags.where((d) => d.severity == DiagnosticSeverity.error), isEmpty);
    expect(diags.every((d) => d.message.startsWith('road')), isTrue);
  });

  test('unknown block id is an error', () {
    final diags = validateLevel(
      const [BlockPlacement(blockId: 'ghost', gridX: 0, gridY: 0)],
      (_) => null,
    );
    expect(diags.single.severity, DiagnosticSeverity.error);
    expect(diags.single.message, contains('Unknown block'));
  });

  test('control line touching track area is reported as an error', () {
    final straightDef = BlockDef(
      id: 'road_straight',
      boundingBox: const BoundingBox(width: 5, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
      category: BlockCategory.track,
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
        Port(localGridX: 4, localGridY: 0, direction: PortDirection.right, span: 5),
      ],
      physicsTrackArea: const [
        Vec2(0, 16),
        Vec2(80, 16),
        Vec2(80, 64),
        Vec2(0, 64),
      ],
    );

    final cornerDef = BlockDef(
      id: 'road_corner',
      boundingBox: const BoundingBox(width: 5, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
      category: BlockCategory.track,
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
        Port(localGridX: 0, localGridY: 4, direction: PortDirection.down, span: 5),
      ],
      physicsTrackArea: const [
        Vec2(0, 16),
        Vec2(64, 16),
        Vec2(64, 80),
        Vec2(0, 80),
      ],
    );

    final diagsNormal = validateLevel(
      const [
        BlockPlacement(blockId: 'road_straight', gridX: 0, gridY: 0),
        BlockPlacement(blockId: 'road_corner', gridX: 5, gridY: 0),
      ],
      libOf([straightDef, cornerDef]),
    );
    expect(
      diagsNormal.where((d) => d.message.contains('touches track area')),
      isEmpty,
    );

    final diagsCollision = validateLevel(
      const [
        BlockPlacement(blockId: 'road_straight', gridX: 0, gridY: 0),
        BlockPlacement(blockId: 'road_corner', gridX: 5, gridY: 0),
      ],
      libOf([straightDef, cornerDef]),
      manualControlPointOffsets: const {
        'auto_0_1_left': -30.0,
      },
    );
    final errors = diagsCollision.where((d) => d.message.contains('touches track area'));
    expect(errors, isNotEmpty);
    expect(errors.first.severity, DiagnosticSeverity.error);
    expect(errors.first.placementIndex, 0);
  });
}
