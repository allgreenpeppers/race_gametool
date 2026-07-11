import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

List<BlockDef> _mockBlockDefs() => [
  const BlockDef(
    id: 'track_straight',
    boundingBox: BoundingBox(width: 1, height: 1),
    spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: 16, h: 16),
    category: BlockCategory.track,
  ),
  const BlockDef(
    id: 'island_tile',
    boundingBox: BoundingBox(width: 1, height: 1),
    spriteSheetRect: SpriteSheetRect(x: 0, y: 0, w: 16, h: 16),
    category: BlockCategory.islandTile,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late AssetDefinerNotifier assetNotifier;
  late LevelEditorNotifier levelNotifier;

  setUp(() async {
    container = ProviderContainer();
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    final image = await recorder.endRecording().toImage(8, 8);
    container
        .read(assetLibraryProvider.notifier)
        .setAssets(blocks: _mockBlockDefs(), sheetBytes: Uint8List(0), sheetImage: image);
    assetNotifier = container.read(assetDefinerProvider.notifier);
    levelNotifier = container.read(levelEditorProvider(0).notifier);
  });

  tearDown(() {
    container.dispose();
  });

  group('Phase 1 (Asset Definer) State & File Operations', () {
    test('initial state is not dirty and has no current path', () {
      final state = container.read(assetDefinerProvider);
      expect(state.isDirty, isFalse);
      expect(state.currentFilePath, isNull);
    });

    test('newConfig resets Phase 1 and clears dirty/path', () {
      // Modify active category
      assetNotifier.setActiveCategory(BlockCategory.islandTile);
      // Run newConfig
      assetNotifier.newConfig();

      final state = container.read(assetDefinerProvider);
      expect(state.isDirty, isFalse);
      expect(state.currentFilePath, isNull);
      expect(state.activeCategory, BlockCategory.track);
    });
  });

  group('Phase 2 (Level Editor) Layer Clear & File Operations', () {
    test('initial state is not dirty and has no current path', () {
      final state = container.read(levelEditorProvider(0));
      expect(state.isDirty, isFalse);
      expect(state.currentFilePath, isNull);
    });

    test('clearLayer clears only placements on that layer', () {
      // Add one track block and one island block
      levelNotifier.setLayer(MapLayer.track);
      levelNotifier.setSpawnAt(0, 0); // triggers _saveToHistory

      // Let's place blocks.
      levelNotifier.selectPalette('track_straight');
      levelNotifier.stampAt(1, 1);

      levelNotifier.setLayer(MapLayer.island);
      levelNotifier.selectPalette('island_tile');
      levelNotifier.stampAt(2, 2);

      var state = container.read(levelEditorProvider(0));
      expect(state.placements.length, 2);
      expect(state.isDirty, isTrue);

      // Clear island layer
      levelNotifier.clearLayer(MapLayer.island);

      state = container.read(levelEditorProvider(0));
      expect(state.placements.length, 1);
      expect(state.placements.first.blockId, 'track_straight');
    });

    test('clearLayer(island) also clears islandGrassMask', () {
      levelNotifier.setLayer(MapLayer.island);
      levelNotifier.setIslandBrushRadius(0);
      levelNotifier.paintGrassAt(5, 5, erase: false);

      var state = container.read(levelEditorProvider(0));
      expect(state.islandGrassMask, isNotNull);

      levelNotifier.clearLayer(MapLayer.island);

      state = container.read(levelEditorProvider(0));
      expect(state.islandGrassMask, isNull);
      expect(state.placements, isEmpty);
    });
  });
}
