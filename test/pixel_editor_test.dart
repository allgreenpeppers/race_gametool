import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/logic/pixel_ops.dart';
import 'package:race_gametool/models/block_def.dart';
import 'package:race_gametool/models/pixel_document.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';
import 'package:race_gametool/state/pixel_editor_providers.dart';

/// Pixel editor notifier behavior: tool gestures, undo/redo, selection and
/// floating moves, symmetry, canvas ops, and the Asset Definer hand-off. All
/// assertions read the raw layer buffer, so the async image cache never
/// races the tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const red = 0xffff0000;
  const blue = 0xff0000ff;

  late ProviderContainer container;
  late PixelEditorNotifier notifier;

  const tabId = 0;
  PixelEditorState read() => container.read(pixelEditorProvider(tabId));
  Uint32List px() => read().document.layers.first.pixels;
  int at(int x, int y) => px()[y * read().document.width + x];

  setUp(() {
    container = ProviderContainer();
    notifier = container.read(pixelEditorProvider(tabId).notifier);
    notifier.newDocument(4, 4);
    notifier.setColor(red);
  });

  tearDown(() => container.dispose());

  group('pencil and eraser', () {
    test('tap paints one pixel; a drag paints the whole path', () {
      notifier.tapAt(1.2, 1.7);
      expect(at(1, 1), red);

      notifier.strokeStart(0.5, 3.5);
      notifier.strokeUpdate(3.5, 3.5);
      notifier.strokeEnd();
      for (var x = 0; x < 4; x++) {
        expect(at(x, 3), red, reason: 'stroke covers ($x,3)');
      }
    });

    test('eraser clears back to transparent', () {
      notifier.tapAt(1, 1);
      notifier.setTool(PixelTool.eraser);
      notifier.tapAt(1, 1);
      expect(at(1, 1), 0);
    });

    test('undo/redo walk the stroke history', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(1, 0);
      expect(read().canUndo, isTrue);

      notifier.undo();
      expect(at(1, 0), 0);
      expect(at(0, 0), red);

      notifier.undo();
      expect(at(0, 0), 0);
      expect(read().canUndo, isFalse);

      notifier.redo();
      notifier.redo();
      expect(at(0, 0), red);
      expect(at(1, 0), red);
    });
  });

  test(
    'mosaic brush alternates from the stroke start with a tab-local B color',
    () {
      notifier.newDocument(8, 4);
      notifier.setBrushSize(2);
      notifier.setColor(red);
      notifier.setMosaicSecondaryColor(blue);
      notifier.setTool(PixelTool.mosaic);
      notifier.strokeStart(1, 1);
      notifier.strokeUpdate(6.9, 1);
      notifier.strokeEnd();

      expect(
        [for (var x = 0; x < 8; x++) at(x, 1)],
        [0, red, red, blue, blue, red, red, 0],
      );
      expect(read().mosaicSecondaryColor, blue);
      expect(read().mosaicColorSlot, MosaicColorSlot.primary);
      notifier.setMosaicColorSlot(MosaicColorSlot.secondary);
      expect(read().mosaicColorSlot, MosaicColorSlot.secondary);
    },
  );

  test('the single layer opacity is undoable and changes the composite', () {
    notifier.tapAt(0, 0);
    notifier.setLayerOpacity(0.4);

    expect(read().document.layers, hasLength(1));
    expect(read().document.layers.single.opacity, 0.4);
    expect((read().document.composite()[0] >>> 24) & 0xff, closeTo(102, 1));
    expect(read().isDirty, isTrue);

    notifier.undo();
    expect(read().document.layers.single.opacity, 1);
    expect(read().document.composite()[0], red);
  });

  group('shape tools', () {
    test('line drag commits on release and undoes as one step', () {
      notifier.setTool(PixelTool.line);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(2.0, 0.4); // preview grows during the drag
      notifier.strokeUpdate(3.9, 0.4);
      notifier.strokeEnd();
      for (var x = 0; x < 4; x++) {
        expect(at(x, 0), red);
      }
      notifier.undo();
      expect(
        px().every((p) => p == 0),
        isTrue,
        reason: 'the intermediate preview is not a separate history step',
      );
    });

    test('rectangle drag draws the outline only', () {
      notifier.setTool(PixelTool.rect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(3.9, 3.9);
      notifier.strokeEnd();
      expect(at(0, 0), red);
      expect(at(3, 3), red);
      expect(at(1, 1), 0);
    });
  });

  group('fill tool', () {
    test('contiguous fill stays inside the connected region', () {
      // A vertical red wall at x=2 splits the canvas.
      notifier.setTool(PixelTool.line);
      notifier.strokeStart(2, 0);
      notifier.strokeUpdate(2, 3.9);
      notifier.strokeEnd();

      notifier.setColor(blue);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      expect(at(0, 0), blue);
      expect(at(3, 0), 0, reason: 'other side of the wall untouched');
    });

    test('non-contiguous fill is a color replace', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(3, 3); // two disconnected red pixels
      notifier.setTool(PixelTool.fill);
      notifier.setFillContiguous(false);
      notifier.setColor(blue);
      notifier.tapAt(0, 0);
      expect(at(0, 0), blue);
      expect(at(3, 3), blue);
      expect(at(1, 1), 0, reason: 'only the tapped color is replaced');
    });

    test('tolerance fills nearby colors after selection mode', () {
      notifier.setColor(0xff101010);
      notifier.tapAt(0, 0);
      notifier.setColor(0xff161616);
      notifier.tapAt(1, 0);

      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(0, 0);
      notifier.strokeEnd();
      expect(read().selection, isNotNull);

      notifier.setFillTolerance(6);
      notifier.setColor(blue);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);

      expect(at(0, 0), blue);
      expect(at(1, 0), blue);
    });

    test('shade variation fills a stable range around the selected color', () {
      notifier.setColor(0xff6aa84f);
      notifier.setFillShadeEnabled(true);
      notifier.setFillShadeStrength(16);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);

      final colors = px().toSet();
      expect(colors.length, greaterThan(1));
      expect(colors.every((color) => (color >>> 24) == 0xff), isTrue);
    });
  });

  test('eyedropper picks the tapped color and skips transparency', () {
    notifier.tapAt(1, 1);
    notifier.setColor(blue);
    notifier.setTool(PixelTool.eyedropper);
    notifier.tapAt(1, 1);
    expect(read().color, red);
    notifier.tapAt(3, 3);
    expect(read().color, red, reason: 'transparent tap keeps the color');
  });

  group('selection', () {
    void selectRect(double x0, double y0, double x1, double y1) {
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(x0, y0);
      notifier.strokeUpdate(x1, y1);
      notifier.strokeEnd();
    }

    test('rectangle selection auto-selects only non-transparent pixels', () {
      notifier.tapAt(1, 1);
      notifier.tapAt(2, 1);
      selectRect(0, 0, 3.9, 3.9);

      expect(read().selection!.where((value) => value != 0), hasLength(2));
      expect(read().selection![1 * 4 + 1], 1);
      expect(read().selection![1 * 4 + 2], 1);
    });

    test('switching to a drawing tool cancels selection automatically', () {
      notifier.tapAt(0, 0);
      selectRect(0, 0, 0, 0);
      notifier.setTool(PixelTool.pencil);

      expect(read().selection, isNull);
      notifier.tapAt(3, 3);
      expect(at(3, 3), red);
    });

    test('magic wand selects the tapped region; Delete clears it', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(1, 0); // connected pair
      notifier.tapAt(3, 3); // separate pixel
      notifier.setTool(PixelTool.wand);
      notifier.tapAt(0, 0);
      expect(read().selection, isNotNull);

      notifier.deleteSelectionContents();
      expect(at(0, 0), 0);
      expect(at(1, 0), 0);
      expect(at(3, 3), red, reason: 'not part of the wand region');
    });

    test('wand drag starts an object selection when no pixel is selected', () {
      notifier.tapAt(2, 2);
      notifier.setTool(PixelTool.wand);
      notifier.strokeStart(2, 2);
      notifier.strokeUpdate(2.9, 2.9);
      notifier.strokeEnd();

      expect(read().selection, isNotNull);
      expect(read().selection![2 * 4 + 2], 1);
    });

    test('lasso drag produces a mask; tap clears the selection', () {
      notifier.tapAt(1, 1);
      notifier.setTool(PixelTool.lasso);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(4, 0);
      notifier.strokeUpdate(4, 4);
      notifier.strokeUpdate(0, 4);
      notifier.strokeEnd();
      expect(read().selection, isNotNull);

      notifier.tapAt(2, 2);
      expect(read().selection, isNull);
    });

    test('Shift adds rectangle, lasso, and wand selections', () {
      notifier.tapAt(0, 0);
      notifier.tapAt(2, 0);
      notifier.tapAt(3, 3);
      notifier.tapAt(1, 2);
      selectRect(0, 0, 0, 0);
      notifier.strokeStart(3, 3, additiveSelection: true);
      notifier.strokeEnd();
      expect(read().selection![0], 1);
      expect(read().selection![15], 1);

      notifier.setTool(PixelTool.lasso);
      notifier.strokeStart(0, 2, additiveSelection: true);
      notifier.strokeUpdate(2, 2);
      notifier.strokeUpdate(2, 4);
      notifier.strokeUpdate(0, 4);
      notifier.strokeEnd();
      expect(read().selection![2 * 4 + 1], 1);

      notifier.setTool(PixelTool.wand);
      notifier.tapAt(2, 0, additiveSelection: true);
      expect(read().selection![2], 1);
      expect(
        read().selection![0],
        1,
        reason: 'the prior rectangle selection is retained',
      );
    });
  });

  group('selection move', () {
    test('dragging selected pixels moves without switching tools', () {
      notifier.tapAt(0, 0);
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(0.9, 0.9);
      notifier.strokeEnd();

      notifier.strokeStart(0.5, 0.5);
      notifier.strokeUpdate(2.5, 2.5);
      notifier.strokeEnd();
      expect(read().floating, isNotNull);
      expect(read().floating!.offsetX, 2);
      expect(at(0, 0), 0, reason: 'lifted off the layer');

      notifier.tapAt(0, 3); // outside the floating box: commit
      expect(read().floating, isNull);
      expect(at(2, 2), red);

      // One undo reverts the whole move (lift + drop).
      notifier.undo();
      expect(at(0, 0), red);
      expect(at(2, 2), 0);
    });

    test('Esc cancels an in-flight move back to the source', () {
      notifier.tapAt(1, 1);
      notifier.selectAll();
      notifier.setTool(PixelTool.move);
      notifier.strokeStart(1.5, 1.5);
      notifier.strokeUpdate(3.5, 3.5);
      notifier.strokeEnd();
      expect(read().floating, isNotNull);

      notifier.cancelFloatingOrSelection();
      expect(read().floating, isNull);
      expect(at(1, 1), red, reason: 'pixels restored where they were');
    });

    test('corner-handle scaling resamples nearest-neighbor', () {
      notifier.tapAt(0, 0);
      notifier.setTool(PixelTool.selectRect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(0.9, 0.9);
      notifier.strokeEnd();
      notifier.setTool(PixelTool.move);
      notifier.strokeStart(0.5, 0.5); // lift the 1x1 selection
      notifier.strokeEnd();

      notifier.startHandleScale(3); // bottom-right handle
      notifier.strokeStart(0.5, 0.5);
      notifier.strokeUpdate(1.5, 1.5); // stretch to 2x2
      notifier.strokeEnd();
      final f = read().floating!;
      expect((f.width, f.height), (2, 2));
      expect(
        f.pixels.toList(),
        List.filled(4, red),
        reason: 'nearest-neighbor keeps the flat color crisp',
      );
    });
  });

  test('symmetry mirrors strokes around the canvas center', () {
    notifier.setSymmetry(SymmetryMode.horizontal);
    notifier.tapAt(0, 1);
    expect(at(0, 1), red);
    expect(at(3, 1), red);

    notifier.setSymmetry(SymmetryMode.both);
    notifier.tapAt(1, 0);
    expect(at(1, 0), red);
    expect(at(2, 0), red);
    expect(at(1, 3), red);
    expect(at(2, 3), red);
  });

  group('editor preferences and dirty state', () {
    test('preferences are shared without dirtying pixel documents', () {
      expect(read().isDirty, isFalse);

      notifier.setSymmetry(SymmetryMode.horizontal);
      notifier.togglePixelGrid();
      notifier.toggleCellGrid();
      notifier.setBrushSize(4);

      expect(read().isDirty, isFalse);
      final preferences = container.read(pixelEditorPreferencesProvider);
      expect(preferences.symmetry, SymmetryMode.horizontal);
      expect(preferences.showPixelGrid, isFalse);
      expect(preferences.showCellGrid, isFalse);
      expect(preferences.brushSize, 4);

      notifier.setBrushSize(99);
      final latestPreferences = container.read(pixelEditorPreferencesProvider);
      expect(latestPreferences.brushSize, 32);

      container.read(pixelEditorProvider(1).notifier).newDocument(2, 2);
      expect(
        container.read(pixelEditorPreferencesProvider),
        same(latestPreferences),
      );
    });

    test('cancelling a floating move restores the prior dirty state', () {
      expect(read().isDirty, isFalse);
      notifier.selectAll();
      notifier.setTool(PixelTool.move);
      notifier.strokeStart(0, 0);
      notifier.strokeEnd();
      expect(read().floating, isNotNull);
      expect(read().isDirty, isTrue);

      notifier.cancelFloatingOrSelection();

      expect(read().floating, isNull);
      expect(
        read().isDirty,
        isFalse,
        reason: 'Esc restored the exact pre-move document',
      );
    });
  });

  group('canvas operations', () {
    test('rotate 90 swaps dimensions and moves content', () {
      notifier.newDocument(2, 1);
      notifier.setColor(red);
      notifier.tapAt(0, 0);
      notifier.rotate90Action(clockwise: true);
      expect(read().document.width, 1);
      expect(read().document.height, 2);
      expect(at(0, 0), red);
      expect(at(0, 1), 0);
    });

    test('flip mirrors the whole canvas', () {
      notifier.tapAt(0, 0);
      notifier.flipAction(horizontal: true);
      expect(at(0, 0), 0);
      expect(at(3, 0), red);
    });

    test('resize keeps content at the chosen anchor', () {
      notifier.newDocument(1, 1);
      notifier.setColor(red);
      notifier.tapAt(0, 0);
      notifier.resizeCanvasTo(3, 3, anchorX: 1, anchorY: 1);
      expect(read().document.width, 3);
      expect(at(2, 2), red);
      expect(at(0, 0), 0);
    });

    test('crop to selection tightens the canvas', () {
      notifier.tapAt(1, 1);
      notifier.setTool(PixelTool.wand);
      notifier.tapAt(1, 1);
      notifier.cropToSelection();
      expect(read().document.width, 1);
      expect(read().document.height, 1);
      expect(at(0, 0), red);
    });

    test('canvas ops are undoable', () {
      notifier.tapAt(0, 0);
      notifier.flipAction(horizontal: true);
      expect(at(3, 0), red);
      notifier.undo();
      expect(at(0, 0), red);
      expect(at(3, 0), 0);
    });
  });

  group('shape interaction modes', () {
    test('Shift constrains rectangle drag to a square', () {
      notifier.setTool(PixelTool.rect);
      notifier.strokeStart(0, 0);
      notifier.strokeUpdate(3, 1, constrainShape: true);
      notifier.strokeEnd();

      expect(at(3, 3), red);
      expect(at(1, 2), 0, reason: 'only the square outline is drawn');
    });

    test('planned shape adjusts an edge and commits only on confirm', () {
      notifier.setTool(PixelTool.rect);
      notifier.setShapeMode(ShapeInteractionMode.planned);
      notifier.strokeStart(1, 1);
      notifier.strokeUpdate(2, 2);
      notifier.strokeEnd();

      expect(px().every((pixel) => pixel == 0), isTrue);
      expect(read().shapePlan, isNotNull);

      notifier.startShapePlanAdjustment(2);
      notifier.strokeStart(3, 2);
      notifier.strokeUpdate(3, 2);
      notifier.strokeEnd();
      expect(read().shapePlan!.right, 3);

      notifier.confirmShapePlan();
      expect(read().shapePlan, isNull);
      expect(at(3, 1), red);
      notifier.undo();
      expect(px().every((pixel) => pixel == 0), isTrue);
    });
  });

  test('copy, cut, and paste move pixels between tabs', () async {
    notifier.tapAt(0, 0);
    notifier.setTool(PixelTool.selectRect);
    notifier.strokeStart(0, 0);
    notifier.strokeEnd();

    await notifier.copySelection();
    await notifier.cutSelection();
    expect(at(0, 0), 0);

    final other = container.read(pixelEditorProvider(1).notifier)
      ..newDocument(4, 4);
    await other.pasteSelection();
    expect(container.read(pixelEditorProvider(1)).floating, isNotNull);
    other.tapAt(0, 0);
    expect(
      container.read(pixelEditorProvider(1)).document.layers.first.pixels[5],
      red,
    );
  });

  test('newDocument resets history, selection, and dirty state', () {
    notifier.tapAt(0, 0);
    notifier.selectAll();
    notifier.newDocument(8, 8);
    expect(read().document.width, 8);
    expect(read().selection, isNull);
    expect(read().isDirty, isFalse);
    expect(read().canUndo, isFalse);
    expect(px().every((p) => p == 0), isTrue);
  });

  test('embedded sources restore rgpix exactly and legacy PNGs fall back', () {
    final fallback = img.Image(width: 2, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 1, 2, 3, 255);
    final fallbackBytes = Uint8List.fromList(img.encodePng(fallback));
    final embedded = RgpixFile(
      document: PixelDocument.blank(1, 2),
      palette: const [],
    );
    const target = AssetPixelTarget(category: BlockCategory.track);

    final error = notifier.loadAssetSource(
      imageBytes: fallbackBytes,
      name: 'track.png',
      target: target,
      pixelProjectBytes: Uint8List.fromList(utf8.encode(embedded.encode())),
    );
    expect(error, isNull);
    expect(read().document.width, 1);
    expect(read().document.height, 2);
    expect(
      read().palette,
      isEmpty,
      reason: 'an intentionally empty project palette must stay empty',
    );

    notifier.loadAssetSource(
      imageBytes: fallbackBytes,
      name: 'legacy.png',
      target: target,
    );
    expect(read().document.width, 2);
    expect(read().document.height, 1);
    expect(at(0, 0), 0xff010203);
    expect(read().imageColors, contains(0xff010203));
  });

  test('multi-layer projects open as one editable flattened layer', () {
    final source = img.Image(width: 1, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 0, 0, 0, 0);
    final project = RgpixFile(
      document: PixelDocument(
        width: 1,
        height: 1,
        layers: [
          PixelLayer(name: 'bottom', pixels: Uint32List.fromList([red])),
          PixelLayer(
            name: 'top',
            opacity: 0.5,
            pixels: Uint32List.fromList([blue]),
          ),
        ],
      ),
    );
    final expected = project.document.composite().single;

    final error = notifier.loadAssetSource(
      imageBytes: Uint8List.fromList(img.encodePng(source)),
      name: 'layered.rgpix',
      target: const AssetPixelTarget(category: BlockCategory.track),
      pixelProjectBytes: Uint8List.fromList(utf8.encode(project.encode())),
    );

    expect(error, isNull);
    expect(read().document.layers, hasLength(1));
    expect(read().document.layers.single.pixels.single, expected);
    expect(read().statusMessage, contains('single flattened layer'));
  });

  group('Asset Definer hand-off', () {
    test(
      'preserves the single layer opacity in the embedded project',
      () async {
        notifier.tapAt(0, 0);
        notifier.setLayerOpacity(0.35);

        await notifier.sendToAssetDefiner(BlockCategory.track);

        final image = container
            .read(assetDefinerProvider)
            .images[BlockCategory.track]!;
        final project = RgpixFile.decode(utf8.decode(image.pixelProjectBytes!));
        expect(project.document.layers, hasLength(1));
        expect(project.document.layers.single.opacity, 0.35);
      },
    );

    test('replaces the track source image with the drawn pixels', () async {
      notifier.newDocument(32, 16);
      notifier.setColor(red);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);

      await notifier.sendToAssetDefiner(BlockCategory.track);

      final asset = container.read(assetDefinerProvider);
      final image = asset.images[BlockCategory.track];
      expect(image, isNotNull);
      expect(image!.image.width, 32);
      expect(image.image.height, 16);
      expect(image.pixelProjectBytes, isNotNull);
      // The PNG bytes decode back to the drawn color.
      final decoded = img.decodePng(image.bytes)!;
      expect(decoded.getPixel(5, 5).r, 0xff);
      expect(decoded.getPixel(5, 5).g, 0);

      // The hand-off lands the user in Asset Definer.
      expect(container.read(workspaceProvider).mode, AppMode.assetDefiner);
    });

    test('decoration images are appended, not replaced', () async {
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      await notifier.sendToAssetDefiner(BlockCategory.decoration);
      notifier.newDocument(4, 4);
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      await notifier.sendToAssetDefiner(BlockCategory.decoration);

      final asset = container.read(assetDefinerProvider);
      expect(asset.decorationSources.length, 2);
      expect(asset.decorationMasks.length, 2);
      expect(asset.activeDecorationIndex, 1);
    });

    test('an embedded decoration edit updates its original source', () async {
      notifier.setTool(PixelTool.fill);
      notifier.tapAt(0, 0);
      await notifier.sendToAssetDefiner(BlockCategory.decoration);
      final original = container
          .read(assetDefinerProvider)
          .decorationSources
          .single;

      notifier.setColor(blue);
      notifier.tapAt(0, 0);
      await notifier.sendToAssetDefiner();

      final asset = container.read(assetDefinerProvider);
      expect(asset.decorationSources, hasLength(1));
      expect(asset.decorationSources.single.bytes, isNot(same(original.bytes)));
      expect(asset.decorationSources.single.pixelProjectBytes, isNotNull);
    });

    test(
      'an embedded decoration edit keeps masks and reports new bounds',
      () async {
        notifier.newDocument(32, 16);
        await notifier.sendToAssetDefiner(BlockCategory.decoration);

        final assetNotifier = container.read(assetDefinerProvider.notifier);
        assetNotifier.dragStart(1, 0);
        assetNotifier.dragEnd();
        expect(
          container.read(assetDefinerProvider).decorationMasks.single,
          hasLength(1),
        );

        notifier.resizeCanvasTo(16, 16);
        await notifier.sendToAssetDefiner();

        final asset = container.read(assetDefinerProvider);
        expect(asset.decorationMasks.single, hasLength(1));
        expect(asset.statusMessage, contains('now out of bounds'));
      },
    );
  });

  test('pixel tabs keep independent documents and workspace focus', () {
    final workspace = container.read(workspaceProvider.notifier);
    final first = workspace.openPixelTab();
    final second = workspace.openPixelTab();
    container.read(pixelEditorProvider(first).notifier)
      ..newDocument(2, 2)
      ..setColor(red)
      ..tapAt(0, 0);
    container.read(pixelEditorProvider(second).notifier).newDocument(3, 3);

    expect(container.read(pixelEditorProvider(first)).document.width, 2);
    expect(container.read(pixelEditorProvider(second)).document.width, 3);
    expect(container.read(workspaceProvider).activePixelTab, second);

    workspace.closePixelTab(second);
    expect(container.read(workspaceProvider).activePixelTab, first);
  });
}
