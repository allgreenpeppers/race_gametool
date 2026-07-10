import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/map_scene.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

Future<ui.Image> _blankImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(8, 8);
}

BlockDef _block(String id, int w, int h) => BlockDef(
      id: id,
      boundingBox: BoundingBox(width: w, height: h),
      spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: w * 16, h: h * 16),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('placement', _placementTests);
  group('connection', _connectionTests);
}

void _placementTests() {
  late ProviderContainer container;
  late LevelEditorNotifier notifier;

  setUp(() async {
    container = ProviderContainer();
    final image = await _blankImage();
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: [_block('straight_h', 5, 2), _block('corner', 3, 3)],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider.notifier);
  });

  tearDown(() => container.dispose());

  test('stamping requires a selected palette block', () {
    notifier.stampAt(0, 0);
    expect(container.read(levelEditorProvider).placements, isEmpty);
    expect(container.read(levelEditorProvider).statusMessage,
        contains('Select a palette block'));
  });

  test('stamp places the selected block at the grid cell', () {
    notifier.selectPalette('straight_h');
    notifier.stampAt(4, 6);
    final placements = container.read(levelEditorProvider).placements;
    expect(placements.length, 1);
    expect(placements.single.blockId, 'straight_h');
    expect(placements.single.gridX, 4);
    expect(placements.single.gridY, 6);
  });

  test('stamp origin clamps so the block stays inside the grid', () {
    // straight_h is 5x2; grid is 320x240. Hovering the far corner clamps
    // the origin so the whole block fits (315, 238).
    notifier.selectPalette('straight_h');
    final (x, y) = notifier.stampOrigin('straight_h', 319, 239);
    expect(x, 315);
    expect(y, 238);
    notifier.stampAt(319, 239);
    final p = container.read(levelEditorProvider).placements.single;
    expect(p.gridX, 315);
    expect(p.gridY, 238);
  });

  test('overlapping placements are rejected by bounding box', () {
    notifier.selectPalette('straight_h'); // 5x2 at (0,0) covers x0..4,y0..1
    notifier.stampAt(0, 0);
    // (4,1) is inside the first block's box -> rejected.
    notifier.stampAt(4, 1);
    expect(container.read(levelEditorProvider).placements.length, 1);
    expect(container.read(levelEditorProvider).statusMessage,
        contains('overlaps'));
    // (5,0) is clear -> accepted.
    notifier.stampAt(5, 0);
    expect(container.read(levelEditorProvider).placements.length, 2);
  });

  test('select and erase hit the topmost placement at a cell', () {
    notifier.selectPalette('corner'); // 3x3
    notifier.stampAt(10, 10);
    notifier.selectAt(11, 11);
    expect(container.read(levelEditorProvider).selectedPlacementIndex, 0);

    notifier.eraseAt(12, 12);
    expect(container.read(levelEditorProvider).placements, isEmpty);
  });

  test('deleteSelected removes the current selection', () {
    notifier.selectPalette('corner');
    notifier.stampAt(0, 0);
    notifier.selectAt(1, 1);
    notifier.deleteSelected();
    expect(container.read(levelEditorProvider).placements, isEmpty);
    expect(container.read(levelEditorProvider).selectedPlacementIndex, isNull);
  });

  test('spawn point and buildScene produce the export model', () {
    notifier.selectPalette('straight_h');
    notifier.stampAt(3, 3);
    notifier.setSpawnFacing(PortDirection.down);
    notifier.setSpawnAt(5, 6);

    final scene = notifier.buildScene();
    expect(scene.mapName, 'map_01');
    expect(scene.spawnPoint.gridX, 5);
    expect(scene.spawnPoint.gridY, 6);
    expect(scene.spawnPoint.facingAngle, closeTo(PortDirection.down.angle, 1e-9));
    expect(scene.placements.length, 1);
    expect(scene.placements.single.blockId, 'straight_h');

    // Round trips through JSON.
    final decoded = MapScene.fromJson(scene.toJson());
    expect(decoded.spawnPoint.gridY, 6);
    expect(decoded.placements.single.gridX, 3);
  });

  test('marquee selects intersecting blocks and group-drag moves them', () {
    notifier.selectPalette('corner'); // 3x3
    notifier.stampAt(0, 0); // covers 0..2
    notifier.stampAt(10, 10); // far away
    notifier.selectPalette('straight_h'); // 5x2
    notifier.stampAt(0, 5); // covers x0..4, y5..6

    notifier.setTool(LevelTool.multi);
    // Marquee over the top-left region catches the corner and the straight
    // but not the far block.
    notifier.multiDragStart(0, 0);
    notifier.multiDragUpdate(4, 6);
    notifier.multiDragEnd(cols: 160, rows: 120);
    final sel = container.read(levelEditorProvider).selection;
    expect(sel, containsAll([0, 2]));
    expect(sel, isNot(contains(1)));

    // Drag the selection down-right by (20, 20): start on a selected block.
    notifier.multiDragStart(1, 1);
    notifier.multiDragUpdate(21, 21);
    notifier.multiDragEnd(cols: 160, rows: 120);
    final placements = container.read(levelEditorProvider).placements;
    expect(placements[0].gridX, 20); // corner moved +20
    expect(placements[0].gridY, 20);
    expect(placements[2].gridX, 20); // straight moved +20
    expect(placements[2].gridY, 25);
    expect(placements[1].gridX, 10); // far block untouched
  });

  test('group move that would overlap a non-selected block is rejected', () {
    notifier.selectPalette('corner'); // 3x3
    notifier.stampAt(0, 0);
    notifier.stampAt(5, 0);
    notifier.setTool(LevelTool.multi);
    notifier.selectSingleAt(1, 1); // select the first
    // Try to move it +3 (onto x3..5) which overlaps the second (x5..7).
    notifier.multiDragStart(1, 1);
    notifier.multiDragUpdate(4, 1);
    notifier.multiDragEnd(cols: 160, rows: 120);
    // Rejected: first block stays put.
    expect(container.read(levelEditorProvider).placements[0].gridX, 0);
  });
}

/// A 1-cell-tall horizontal straight with a RIGHT port on its right edge
/// and a LEFT port on its left edge (span 1).
BlockDef _straightWithSidePorts(String id) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 5, height: 1),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 16),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
        Port(localGridX: 4, localGridY: 0, direction: PortDirection.right),
      ],
    );

void _connectionTests() {
  late ProviderContainer container;
  late LevelEditorNotifier notifier;

  setUp(() async {
    container = ProviderContainer();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 8);
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: [_straightWithSidePorts('straight')],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider.notifier);
    notifier.selectPalette('straight');
    notifier.stampAt(10, 10); // occupies x10..14, y10
  });

  tearDown(() => container.dispose());

  test('portAt finds the port strip cell', () {
    final ref = notifier.portAt(14, 10); // right edge port cell
    expect(ref, isNotNull);
    expect(ref!.placementIndex, 0);
  });

  test('connectPortAt matches the outward "+" cell with a side', () {
    // The + marker for the RIGHT port sits at x15 (one cell outside the
    // block); tapping it must resolve to that port on its RIGHT side.
    expect(notifier.portAt(15, 10), isNull);
    final hit = notifier.connectPortAt(15, 10);
    expect(hit, isNotNull);
    expect(hit!.ref.portIndex, 1); // the RIGHT port
    expect(hit.outward, PortDirection.right);
  });

  test('connect candidate snaps a block flush against the source port', () {
    final hit = notifier.connectPortAt(15, 10)!; // RIGHT side
    final candidates = notifier.connectCandidates(hit);
    expect(candidates, isNotEmpty);
    final c = candidates.first;
    // New block's LEFT port (localX 0) must land at x15, y10.
    expect(c.gridX, 15);
    expect(c.gridY, 10);

    notifier.placeConnected(c);
    final placements = container.read(levelEditorProvider).placements;
    expect(placements.length, 2);
    expect(placements[1].gridX, 15);
  });

  test('a one-cell-thick straight is a pass-through with two free sides', () {
    // A 1-wide, 5-tall block with a single LEFT port reads as a horizontal
    // pass-through: both LEFT and RIGHT sides are connectable.
    final def = BlockDef(
      id: 'straight_v_thin',
      boundingBox: const BoundingBox(width: 1, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 16, h: 80),
      ports: const [
        Port(
            localGridX: 0,
            localGridY: 0,
            direction: PortDirection.left,
            span: 5),
      ],
    );
    expect(portIsPassThrough(def, def.ports.first), isTrue);
    expect(portOutwardDirections(def, def.ports.first),
        containsAll([PortDirection.left, PortDirection.right]));
  });

  test('a side stops being free once a neighbor is attached', () {
    final occ0 = notifier.occupiedCells();
    expect(notifier.freeSides(0, 1, occ0), contains(PortDirection.right));
    final hit = notifier.connectPortAt(15, 10)!;
    notifier.placeConnected(notifier.connectCandidates(hit).first);
    final occ1 = notifier.occupiedCells();
    expect(
        notifier.freeSides(0, 1, occ1), isNot(contains(PortDirection.right)));
  });

  test('straight run reaches the grid edge and stops cleanly', () {
    // With a 22-wide grid, a 5-wide straight from x15 can sit at 15 and 20
    // (20+5=25 > 22 stops it after 15). Prove it stops at the boundary
    // instead of stepping off-grid.
    final hit = notifier.connectPortAt(15, 10)!;
    final candidate = notifier.connectCandidates(hit).first;
    final positions =
        notifier.straightRunPositions(hit, candidate, cols: 22, rows: 40);
    expect(positions, [(15, 10)]);
    for (final (x, _) in positions) {
      expect(x + 5, lessThanOrEqualTo(22));
    }
  });

  test('straight run extends by tile length and places N at once', () {
    // Source straight covers x10..14. Extending RIGHT with the same 5-wide
    // straight should step by 5: origins 15, 20, 25, ...
    final hit = notifier.connectPortAt(15, 10)!;
    final candidate = notifier.connectCandidates(hit).first;
    final positions =
        notifier.straightRunPositions(hit, candidate, cols: 40, rows: 40);
    expect(positions.first, (15, 10));
    expect(positions[1], (20, 10));
    expect(positions[2], (25, 10));

    notifier.chooseConnection(hit, candidate, cols: 40, rows: 40);
    expect(container.read(levelEditorProvider).extendPreview, isNotNull);

    notifier.commitExtend(3);
    final placements = container.read(levelEditorProvider).placements;
    expect(placements.length, 4); // original + 3
    expect(placements[3].gridX, 25);
    expect(container.read(levelEditorProvider).extendPreview, isNull);
  });
}
