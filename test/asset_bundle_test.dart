import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/logic/asset_bundle.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/models/port.dart';

Uint8List _draft() {
  final draft = img.Image(width: 160, height: 160, numChannels: 4);
  img.fillRect(
    draft,
    x1: 0,
    y1: 0,
    x2: 79,
    y2: 31,
    color: img.ColorRgba8(255, 0, 0, 255),
  );
  img.fillRect(
    draft,
    x1: 96,
    y1: 48,
    x2: 143,
    y2: 143,
    color: img.ColorRgba8(0, 0, 255, 255),
  );
  return Uint8List.fromList(img.encodePng(draft));
}

void main() {
  final masks = [
    const MaskDraft(
      id: 'straight_h',
      gridX: 0,
      gridY: 0,
      widthCells: 5,
      heightCells: 2,
      ports: [
        Port(
          localGridX: 0,
          localGridY: 0,
          direction: PortDirection.up,
          span: 5,
          bidirectional: true,
        ),
      ],
    ),
    MaskDraft.fromCells(
      id: 'corner_bl',
      absoluteCells: {(6, 3), (6, 4), (7, 4), (8, 4)},
    ),
  ];

  test('write then read round trips editor state and game assets', () {
    final bundle = writeAssetBundle(
      sources: [
        BundleSource(
          category: BlockCategory.track,
          name: 'draft.png',
          imageBytes: _draft(),
          masks: masks,
        ),
      ],
      imageName: 'draft.png',
    );

    final data = readAssetBundle(bundle);
    expect(data.imageName, 'draft.png');
    expect(data.cellSize, 16);
    expect(data.masks.length, 2);

    final straight = data.masks.firstWhere((m) => m.id == 'straight_h');
    expect(straight.ports.single.bidirectional, isTrue);
    expect(straight.ports.single.span, 5);

    final corner = data.masks.firstWhere((m) => m.id == 'corner_bl');
    expect(corner.isFreeform, isTrue);
    expect(corner.cells, contains((0, 0)));
    expect(corner.cells, isNot(contains((1, 0))));

    expect(data.blocks.length, 2);
    expect(img.decodePng(data.sheetBytes), isNotNull);
  });

  test('extractGameAssets returns the sheet and dict without editor data', () {
    final bundle = writeAssetBundle(
      sources: [
        BundleSource(
          category: BlockCategory.track,
          name: 'draft.png',
          imageBytes: _draft(),
          masks: masks,
        ),
      ],
      imageName: 'draft.png',
    );
    final assets = extractGameAssets(bundle);
    expect(img.decodePng(assets.sheetBytes), isNotNull);
    expect(assets.spriteDictJson, contains('straight_h'));
    expect(assets.spriteDictJson, contains('spriteSheet'));
  });

  test('embedded pixel projects round trip as optional source data', () {
    final project = Uint8List.fromList([1, 3, 3, 7]);
    final bundle = writeAssetBundle(
      sources: [
        BundleSource(
          category: BlockCategory.track,
          name: 'draft.png',
          imageBytes: _draft(),
          masks: masks,
          pixelProjectBytes: project,
        ),
      ],
      imageName: 'draft.png',
    );

    final data = readAssetBundle(bundle);
    expect(data.categoryPixelProjects[BlockCategory.track], project);
  });

  test('multiple decoration images round trip as separate sources but one '
      'merged dictionary', () {
    // Two distinct decoration draft images, each carrying its own block.
    Uint8List solid(int r, int g, int b) {
      final im = img.Image(width: 32, height: 32, numChannels: 4);
      img.fill(im, color: img.ColorRgba8(r, g, b, 255));
      return Uint8List.fromList(img.encodePng(im));
    }

    final decoA = solid(10, 20, 30);
    final decoB = solid(200, 100, 50);
    final projectB = Uint8List.fromList([9, 8, 7]);
    const maskA = MaskDraft(
      id: 'deco_a',
      gridX: 0,
      gridY: 0,
      widthCells: 2,
      heightCells: 2,
      category: BlockCategory.decoration,
    );
    const maskB = MaskDraft(
      id: 'deco_b',
      gridX: 0,
      gridY: 0,
      widthCells: 1,
      heightCells: 1,
      category: BlockCategory.decoration,
    );

    final bundle = writeAssetBundle(
      sources: [
        BundleSource(
          category: BlockCategory.decoration,
          name: 'deco_a.png',
          imageBytes: decoA,
          masks: const [maskA],
        ),
        BundleSource(
          category: BlockCategory.decoration,
          name: 'deco_b.png',
          imageBytes: decoB,
          masks: const [maskB],
          pixelProjectBytes: projectB,
        ),
      ],
      imageName: 'deco_a.png',
    );

    final data = readAssetBundle(bundle);

    // Two decoration sources preserved separately, each with its own image
    // bytes and its own mask.
    expect(data.decorationSources.length, 2);
    expect(data.decorationSources[0].name, 'deco_a.png');
    expect(data.decorationSources[0].imageBytes, decoA);
    expect(data.decorationSources[0].masks.single.id, 'deco_a');
    expect(data.decorationSources[1].name, 'deco_b.png');
    expect(data.decorationSources[1].imageBytes, decoB);
    expect(data.decorationSources[1].masks.single.id, 'deco_b');
    expect(data.decorationSources[1].pixelProjectBytes, projectB);

    // But both blocks merge into the single sprite dictionary.
    final ids = data.blocks.map((b) => b.id).toSet();
    expect(ids, containsAll(['deco_a', 'deco_b']));
  });

  test('reading a bundle missing entries throws FormatException', () {
    expect(
      () => readAssetBundle(Uint8List.fromList([1, 2, 3])),
      throwsA(anything),
    );
  });
}
