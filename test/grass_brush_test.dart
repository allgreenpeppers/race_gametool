import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/island_tiles.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/port.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

BlockDef _tile(String id, Set<PortDirection> sig) => BlockDef(
      id: id,
      boundingBox: const BoundingBox(width: 1, height: 1),
      spriteSheetRect: const SpriteSheetRect(x: 0, y: 0, w: 16, h: 16),
      category: BlockCategory.islandTile,
      ports: [
        for (final d in sig)
          Port(localGridX: 0, localGridY: 0, direction: d),
      ],
    );

/// A convex tile set with TWO interior tiles so random picks are observable.
List<BlockDef> _islandSet() => [
      _tile('interiorA', interiorSignature),
      _tile('interiorB', interiorSignature),
      for (var i = 0; i < edgeSignatures.length; i++)
        _tile('edge$i', edgeSignatures[i]),
      for (var i = 0; i < convexCornerSignatures.length; i++)
        _tile('convex$i', convexCornerSignatures[i]),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late LevelEditorNotifier notifier;
  LevelEditorState read() => container.read(levelEditorProvider(0));

  Map<(int, int), String> islandTiles() => {
        for (final p in read().placements)
          if (notifier.layerOf(p) == MapLayer.island)
            (p.gridX, p.gridY): p.blockId,
      };

  setUp(() async {
    container = ProviderContainer();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 8);
    container.read(assetLibraryProvider.notifier).setAssets(
      blocks: _islandSet(),
      sheetBytes: Uint8List(0),
      sheetImage: image,
    );
    notifier = container.read(levelEditorProvider(0).notifier);
    notifier.setLayer(MapLayer.island);
    notifier.setIslandBrushRadius(3);
  });

  tearDown(() => container.dispose());

  test('painting places island tiles (bug 1)', () {
    notifier.paintGrassAt(20, 20, erase: false); // 7x7 block at 17..23
    final tiles = islandTiles();
    expect(tiles.length, 49);
    expect(tiles[(20, 20)], anyOf('interiorA', 'interiorB'));
  });

  test('painting elsewhere does not re-randomise existing tiles (bug 3)', () {
    notifier.paintGrassAt(20, 20, erase: false);
    final before = islandTiles();
    final centerBefore = before[(20, 20)];

    notifier.paintGrassAt(40, 40, erase: false); // distant, disjoint region
    final after = islandTiles();

    // The first region's interior tile keeps its exact (random) id.
    expect(after[(20, 20)], centerBefore);
    // Every previously placed tile is unchanged.
    for (final entry in before.entries) {
      expect(after[entry.key], entry.value);
    }
    // The new region added tiles.
    expect(after.length, greaterThan(before.length));
  });

  test('clearAll also clears the painted grass mask (bug 2)', () {
    notifier.paintGrassAt(10, 10, erase: false);
    expect(read().islandGrassMask, isNotNull);
    expect(islandTiles(), isNotEmpty);

    notifier.clearAll();
    expect(read().islandGrassMask, isNull);
    expect(islandTiles(), isEmpty);
  });
}
