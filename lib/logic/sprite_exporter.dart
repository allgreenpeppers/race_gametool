import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../core/constants.dart';
import '../models/block_def.dart';
import '../models/mask_draft.dart';
import 'bin_packer.dart';

/// Output of the Phase 1 export pipeline: the packed sheet PNG,
/// the sprite dictionary JSON text, and the parsed BlockDefs
/// (handed to Phase 2 in-memory so no reload is needed).
class SpriteExportResult {
  const SpriteExportResult({
    required this.pngBytes,
    required this.jsonText,
    required this.blocks,
  });

  final Uint8List pngBytes;
  final String jsonText;
  final List<BlockDef> blocks;
}

/// Crops every mask out of the raw draft image, bin-packs the pieces into
/// a single transparent sheet, and builds the sprite dictionary.
///
/// Physics fields (track area, walls, check lines) are exported empty for
/// now; they get authored in a later editing step and merged into the same
/// BlockDef entries.
SpriteExportResult buildSpriteExport({
  required Uint8List rawImageBytes,
  required List<MaskDraft> masks,
  String sheetFileName = 'SpriteSheet.png',
}) {
  if (masks.isEmpty) {
    throw ArgumentError('No masks defined; nothing to export');
  }
  final source = img.decodeImage(rawImageBytes);
  if (source == null) {
    throw ArgumentError('Could not decode the draft image');
  }

  const cell = GridConstants.cellSize;
  final crops = <img.Image>[];
  for (final mask in masks) {
    var crop = img.copyCrop(
      source,
      x: (mask.gridX * cell).round(),
      y: (mask.gridY * cell).round(),
      width: (mask.widthCells * cell).round(),
      height: (mask.heightCells * cell).round(),
    );
    crop = crop.convert(numChannels: 4);
    // Freeform masks: clear cells outside the painted shape so
    // neighboring pieces on the draft sheet do not leak into the crop.
    final shapeCells = mask.cells;
    if (shapeCells != null) {
      final cellPx = cell.round();
      for (var cy = 0; cy < mask.heightCells; cy++) {
        for (var cx = 0; cx < mask.widthCells; cx++) {
          if (shapeCells.contains((cx, cy))) continue;
          for (var py = 0; py < cellPx; py++) {
            for (var px = 0; px < cellPx; px++) {
              crop.setPixelRgba(cx * cellPx + px, cy * cellPx + py, 0, 0, 0, 0);
            }
          }
        }
      }
    }
    crops.add(crop);
  }

  final packed = packSprites([
    for (final c in crops) (width: c.width, height: c.height),
  ]);

  final sheet = img.Image(
    width: packed.sheetWidth,
    height: packed.sheetHeight,
    numChannels: 4,
  );
  for (final rect in packed.rects) {
    img.compositeImage(
      sheet,
      crops[rect.index],
      dstX: rect.x,
      dstY: rect.y,
      blend: img.BlendMode.direct,
    );
  }

  final blocks = <BlockDef>[];
  for (final rect in packed.rects) {
    final mask = masks[rect.index];
    blocks.add(BlockDef(
      id: mask.id,
      boundingBox:
          BoundingBox(width: mask.widthCells, height: mask.heightCells),
      spriteSheetRect: SpriteSheetRect(
        x: rect.x,
        y: rect.y,
        w: rect.width,
        h: rect.height,
      ),
      category: mask.category,
      cornerType: mask.cornerType,
      ports: mask.ports,
      physicsTrackArea: mask.physicsTrackArea,
    ));
  }

  final jsonText = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'cellSize': GridConstants.cellSize.round(),
    'spriteSheet': sheetFileName,
    'blocks': blocks.map((b) => b.toJson()).toList(),
  });

  return SpriteExportResult(
    pngBytes: Uint8List.fromList(img.encodePng(sheet)),
    jsonText: jsonText,
    blocks: blocks,
  );
}

/// One draft image plus the masks authored on it. Several sources may share
/// a [BlockCategory] (decoration can span multiple images); every source's
/// masks are cropped from its own image and merged into one sheet/dict.
class ExportSource {
  const ExportSource({required this.imageBytes, required this.masks});

  final Uint8List imageBytes;
  final List<MaskDraft> masks;
}

/// Crops [mask] out of its already-decoded [source] image, clearing any
/// cells outside a freeform shape to transparent.
img.Image _cropMask(img.Image source, MaskDraft mask) {
  const cell = GridConstants.cellSize;
  var crop = img.copyCrop(
    source,
    x: (mask.gridX * cell).round(),
    y: (mask.gridY * cell).round(),
    width: (mask.widthCells * cell).round(),
    height: (mask.heightCells * cell).round(),
  );
  crop = crop.convert(numChannels: 4);
  final shapeCells = mask.cells;
  if (shapeCells != null) {
    final cellPx = cell.round();
    for (var cy = 0; cy < mask.heightCells; cy++) {
      for (var cx = 0; cx < mask.widthCells; cx++) {
        if (shapeCells.contains((cx, cy))) continue;
        for (var py = 0; py < cellPx; py++) {
          for (var px = 0; px < cellPx; px++) {
            crop.setPixelRgba(cx * cellPx + px, cy * cellPx + py, 0, 0, 0, 0);
          }
        }
      }
    }
  }
  return crop;
}

/// Multi-source variant: each [ExportSource] contributes its own masks,
/// cropped from its own image, and all pieces are packed into a single
/// shared sheet + dictionary. This lets Track, Island, and any number of
/// Decoration images come from different draft images yet merge into one
/// asset set.
SpriteExportResult buildSpriteExportSources(
  List<ExportSource> sources, {
  String sheetFileName = 'SpriteSheet.png',
}) {
  // Flatten to a single ordered mask list, cropping each from its own source.
  final masks = <MaskDraft>[];
  final crops = <img.Image>[];
  for (final source in sources) {
    if (source.masks.isEmpty) continue;
    final decoded = img.decodeImage(source.imageBytes);
    if (decoded == null) {
      throw ArgumentError('Could not decode a source image');
    }
    for (final mask in source.masks) {
      masks.add(mask);
      crops.add(_cropMask(decoded, mask));
    }
  }
  if (masks.isEmpty) {
    throw ArgumentError('No masks defined; nothing to export');
  }

  final packed = packSprites([
    for (final c in crops) (width: c.width, height: c.height),
  ]);

  final sheet = img.Image(
    width: packed.sheetWidth,
    height: packed.sheetHeight,
    numChannels: 4,
  );
  for (final rect in packed.rects) {
    img.compositeImage(
      sheet,
      crops[rect.index],
      dstX: rect.x,
      dstY: rect.y,
      blend: img.BlendMode.direct,
    );
  }

  final blocks = <BlockDef>[];
  for (final rect in packed.rects) {
    final mask = masks[rect.index];
    blocks.add(BlockDef(
      id: mask.id,
      boundingBox:
          BoundingBox(width: mask.widthCells, height: mask.heightCells),
      spriteSheetRect: SpriteSheetRect(
        x: rect.x,
        y: rect.y,
        w: rect.width,
        h: rect.height,
      ),
      category: mask.category,
      cornerType: mask.cornerType,
      ports: mask.ports,
      physicsTrackArea: mask.physicsTrackArea,
    ));
  }

  final jsonText = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'cellSize': GridConstants.cellSize.round(),
    'spriteSheet': sheetFileName,
    'blocks': blocks.map((b) => b.toJson()).toList(),
  });

  return SpriteExportResult(
    pngBytes: Uint8List.fromList(img.encodePng(sheet)),
    jsonText: jsonText,
    blocks: blocks,
  );
}

/// Parses a sprite_dict.json produced by [buildSpriteExport].
/// Returns the block list plus the sheet file name it references.
({List<BlockDef> blocks, String spriteSheet}) parseSpriteDict(
    String jsonText) {
  final root = jsonDecode(jsonText) as Map<String, dynamic>;
  return (
    blocks: (root['blocks'] as List<dynamic>)
        .map((b) => BlockDef.fromJson(b as Map<String, dynamic>))
        .toList(),
    spriteSheet: root['spriteSheet'] as String? ?? 'SpriteSheet.png',
  );
}
