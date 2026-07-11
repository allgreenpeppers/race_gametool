import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

/// Drag-stamping on the track layer: dragging with the Stamp tool pulls a
/// straight run of the selected block (ghost while dragging, committed on
/// release, then hands off to Connect). Only true straights extend; the
/// run follows the block's port axis only.
Future<ui.Image> _blankImage() {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder);
  return recorder.endRecording().toImage(8, 8);
}

/// A horizontal straight: 5x1 with LEFT and RIGHT ports (span 1).
BlockDef _straightH(String id) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 5, height: 1),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 16),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
        Port(localGridX: 4, localGridY: 0, direction: PortDirection.right),
      ],
    );

/// A corner piece: two perpendicular ports, so not a straight.
BlockDef _corner(String id) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 3, height: 3),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 48, h: 48),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.up, span: 3),
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 3),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late LevelEditorNotifier notifier;

  LevelEditorState read() => container.read(levelEditorProvider(0));

  setUp(() async {
    container = ProviderContainer();
    final image = await _blankImage();
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: [_straightH('straight'), _corner('corner')],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider(0).notifier);
  });

  tearDown(() => container.dispose());

  test('dragging along the straight axis previews and places a run', () {
    notifier.selectPalette('straight');
    notifier.stampDragStart(0, 0);
    notifier.stampDragUpdate(12, 0);
    // 5-wide tile dragged 12 cells right: ghosts at x 0, 5, 10.
    expect(read().stampDragPreview!.positions, [(0, 0), (5, 0), (10, 0)]);
    expect(read().placements, isEmpty); // nothing placed until release

    notifier.stampDragEnd();
    final state = read();
    expect(state.placements.length, 3);
    expect(state.placements.map((p) => p.gridX), [0, 5, 10]);
    expect(state.stampDragPreview, isNull);
    // Release hands off to Connect, exactly like a single stamp click.
    expect(state.tool, LevelTool.connect);
  });

  test('dragging backwards grows the run in the negative direction', () {
    notifier.selectPalette('straight');
    notifier.stampDragStart(20, 0);
    notifier.stampDragUpdate(14, 0);
    expect(read().stampDragPreview!.positions, [(20, 0), (15, 0), (10, 0)]);
    notifier.stampDragEnd();
    expect(read().placements.length, 3);
  });

  test('a perpendicular drag does not extend the run', () {
    notifier.selectPalette('straight');
    notifier.stampDragStart(0, 0);
    notifier.stampDragUpdate(0, 30); // straight down, off the port axis
    expect(read().stampDragPreview!.positions, [(0, 0)]);
    notifier.stampDragEnd();
    expect(read().placements.length, 1);
  });

  test('a non-straight block drag-stamps a single tile', () {
    notifier.selectPalette('corner');
    notifier.stampDragStart(0, 0);
    notifier.stampDragUpdate(20, 0);
    expect(read().stampDragPreview!.positions, [(0, 0)]);
    notifier.stampDragEnd();
    expect(read().placements.length, 1);
  });

  test('the run stops at the first obstacle', () {
    notifier.selectPalette('straight');
    notifier.stampAt(10, 0, changeTool: false); // blocker at x10..14
    notifier.stampDragStart(0, 0);
    notifier.stampDragUpdate(14, 0);
    // Third tile would land on the blocker: run stops after two.
    expect(read().stampDragPreview!.positions, [(0, 0), (5, 0)]);
    notifier.stampDragEnd();
    expect(read().placements.length, 3); // blocker + the two dragged tiles
  });

  test('a drag anchored on an occupied cell places nothing', () {
    notifier.selectPalette('straight');
    notifier.stampAt(0, 0, changeTool: false);
    notifier.stampDragStart(2, 0); // inside the existing block
    notifier.stampDragUpdate(12, 0);
    expect(read().stampDragPreview!.positions, isEmpty);
    notifier.stampDragEnd();
    expect(read().placements.length, 1);
    expect(read().statusMessage, contains('overlaps'));
  });

  test('undo removes the whole dragged run at once', () {
    notifier.selectPalette('straight');
    notifier.stampDragStart(0, 0);
    notifier.stampDragUpdate(12, 0);
    notifier.stampDragEnd();
    expect(read().placements.length, 3);
    notifier.undo();
    expect(read().placements, isEmpty);
  });
}
