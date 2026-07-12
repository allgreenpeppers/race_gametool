import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';
import 'package:race_gametool/state/level_editor_providers.dart';

Uint8List _solidPng(int r, int g, int b, {int size = 32}) {
  final im = img.Image(width: size, height: size, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(r, g, b, 255));
  return Uint8List.fromList(img.encodePng(im));
}

Future<ui.Image> _decode(Uint8List bytes) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('saving a config with two decoration images puts both decorations\' '
      'blocks in the phase 2 palette', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(assetDefinerProvider.notifier);

    final trackPng = _solidPng(1, 2, 3);
    final decoAPng = _solidPng(255, 0, 0);
    final decoBPng = _solidPng(0, 255, 0);

    // Drive the notifier to the state the UI produces after loading a track
    // image, adding two decoration images, and drawing one mask on each.
    // ignore: invalid_use_of_protected_member
    notifier.state = AssetDefinerState(
      images: {
        BlockCategory.track: CategoryImage(
            bytes: trackPng, image: await _decode(trackPng), name: 'track.png'),
      },
      masksByCategory: const {
        BlockCategory.track: [
          MaskDraft(
            id: 'block_1',
            gridX: 0,
            gridY: 0,
            widthCells: 2,
            heightCells: 1,
            category: BlockCategory.track,
          ),
        ],
      },
      decorationSources: [
        CategoryImage(
            bytes: decoAPng, image: await _decode(decoAPng), name: 'a.png'),
        CategoryImage(
            bytes: decoBPng, image: await _decode(decoBPng), name: 'b.png'),
      ],
      decorationMasks: const [
        [
          MaskDraft(
            id: 'block_2',
            gridX: 0,
            gridY: 0,
            widthCells: 1,
            heightCells: 1,
            category: BlockCategory.decoration,
          ),
        ],
        [
          MaskDraft(
            id: 'block_3',
            gridX: 1,
            gridY: 1,
            widthCells: 1,
            heightCells: 1,
            category: BlockCategory.decoration,
          ),
        ],
      ],
    );

    final tmp = await Directory.systemTemp.createTemp('rgpack_test');
    addTearDown(() => tmp.delete(recursive: true));
    await notifier.saveToPath('${tmp.path}/two_deco.rgpack');

    final saved = container.read(assetDefinerProvider);
    expect(saved.statusMessage, contains('Saved'),
        reason: 'save must succeed: ${saved.statusMessage}');

    // The phase 2 palette filters the shared library by category; both
    // decoration images' blocks must be there.
    final library = container.read(assetLibraryProvider);
    final decoIds = [
      for (final b in library.blocks)
        if (MapLayer.decoration.accepts(b.category)) b.id,
    ];
    expect(decoIds, containsAll(['block_2', 'block_3']));
    expect(library.blocks.map((b) => b.id), contains('block_1'));
  });
}
