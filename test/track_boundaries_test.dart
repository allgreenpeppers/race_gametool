import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/logic/track_boundaries.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isStraightBlock and isCornerBlock classification', () {
    final straightBlock = BlockDef(
      id: 'straight',
      boundingBox: const BoundingBox(width: 5, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
        Port(localGridX: 4, localGridY: 0, direction: PortDirection.right, span: 5),
      ],
    );

    final cornerBlock = BlockDef(
      id: 'corner',
      boundingBox: const BoundingBox(width: 5, height: 5),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
      ports: const [
        Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
        Port(localGridX: 0, localGridY: 4, direction: PortDirection.down, span: 5),
      ],
    );

    expect(isStraightBlock(straightBlock), isTrue);
    expect(isCornerBlock(straightBlock), isFalse);

    expect(isStraightBlock(cornerBlock), isFalse);
    expect(isCornerBlock(cornerBlock), isTrue);
  });

  test('perpendicular directions are perpendicular', () {
    final (l1, r1) = perpendicularDirections(PortDirection.right);
    // right is (1,0). left perpendicular is (0, -1) (up), right perpendicular is (0, 1) (down)
    expect(l1.x, closeTo(0.0, 1e-9));
    expect(l1.y, closeTo(-1.0, 1e-9));
    expect(r1.x, closeTo(0.0, 1e-9));
    expect(r1.y, closeTo(1.0, 1e-9));

    final (l2, r2) = perpendicularDirections(PortDirection.diagUR);
    // dot product must be 0
    final diagURVec = PortDirection.diagUR.gridDelta;
    final dotL = l2.x * diagURVec.$1 + l2.y * diagURVec.$2;
    expect(dotL, closeTo(0.0, 1e-9));
  });

  testWidgets('level editor notifier integrates manual offsets and insertion', (tester) async {
    final container = ProviderContainer();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 8);
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: [
        BlockDef(
          id: 'road_straight',
          boundingBox: const BoundingBox(width: 5, height: 5),
          spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
          category: BlockCategory.track,
          ports: const [
            Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
            Port(localGridX: 4, localGridY: 0, direction: PortDirection.right, span: 5),
          ],
        ),
        BlockDef(
          id: 'road_corner',
          boundingBox: const BoundingBox(width: 5, height: 5),
          spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 80, h: 80),
          category: BlockCategory.track,
          ports: const [
            Port(localGridX: 0, localGridY: 0, direction: PortDirection.left, span: 5),
            Port(localGridX: 0, localGridY: 4, direction: PortDirection.down, span: 5),
          ],
        ),
      ],
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );

    final notifier = container.read(levelEditorProvider(0).notifier);

    // Place straight meeting a corner
    notifier.setLayer(MapLayer.track);
    notifier.selectPalette('road_straight');
    notifier.stampAt(0, 0); // straight at (0, 0)
    notifier.selectPalette('road_corner');
    notifier.stampAt(5, 0); // corner at (5, 0)

    final state = container.read(levelEditorProvider(0));
    expect(state.placements.length, 2);

    // Test control point drag start and update
    notifier.startControlPointDrag();
    notifier.updateControlPointOffset('auto_0_1_left', 10.0);

    final updatedState = container.read(levelEditorProvider(0));
    expect(updatedState.manualControlPointOffsets['auto_0_1_left'], 10.0);

    // Test undo restores previous offset
    notifier.undo();
    final undoneState = container.read(levelEditorProvider(0));
    expect(undoneState.manualControlPointOffsets['auto_0_1_left'], isNull);

    container.dispose();
  });
}
