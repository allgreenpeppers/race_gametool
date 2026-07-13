import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../core/constants.dart';
import '../models/block_def.dart';
import '../models/mask_draft.dart';
import 'sprite_exporter.dart';

/// Internal file names inside a .rgpack asset bundle.
class BundleEntries {
  BundleEntries._();
  static const manifest = 'manifest.json';
  static const rawSource = 'raw_source.png';
  static const editor = 'editor.json';
  static const spriteSheet = 'SpriteSheet.png';
  static const spriteDict = 'sprite_dict.json';
}

/// One draft image written into a bundle: its category, display name, the raw
/// image bytes, and the masks authored on it. Decoration may contribute
/// several of these; every other category contributes at most one.
class BundleSource {
  const BundleSource({
    required this.category,
    required this.name,
    required this.imageBytes,
    required this.masks,
    this.pixelProjectBytes,
  });

  final BlockCategory category;
  final String name;
  final Uint8List imageBytes;
  final List<MaskDraft> masks;

  /// Optional editable `.rgpix` source for images authored in Pixel Editor.
  final Uint8List? pixelProjectBytes;
}

/// A decoration image read back out of a bundle, paired with the masks that
/// belong to it, so Phase 1 can restore each decoration image separately.
class BundleDecorationSource {
  const BundleDecorationSource({
    required this.imageBytes,
    required this.name,
    required this.masks,
    this.pixelProjectBytes,
  });

  final Uint8List imageBytes;
  final String name;
  final List<MaskDraft> masks;
  final Uint8List? pixelProjectBytes;
}

/// Everything read back out of a .rgpack. Splits cleanly into the two
/// audiences: the editor half (rawImageBytes + masks, for re-editing in
/// Phase 1) and the consumer half (sheetBytes + blocks, for Phase 2 and
/// the game).
class AssetBundleData {
  const AssetBundleData({
    required this.rawImageBytes,
    required this.imageName,
    required this.masks,
    required this.sheetBytes,
    required this.spriteDictJson,
    required this.blocks,
    required this.cellSize,
    this.categoryRawImages = const {},
    this.categoryPixelProjects = const {},
    this.decorationSources = const [],
  });

  final Uint8List rawImageBytes;
  final String imageName;
  final List<MaskDraft> masks;
  final Uint8List sheetBytes;
  final String spriteDictJson;
  final List<BlockDef> blocks;
  final int cellSize;

  /// Per-category raw source images, for the single-image categories
  /// (everything except decoration). Empty for legacy single-image bundles.
  final Map<BlockCategory, Uint8List> categoryRawImages;

  /// Optional `.rgpix` project paired with each single-image category.
  /// Empty for bundles written before embedded pixel sources were supported.
  final Map<BlockCategory, Uint8List> categoryPixelProjects;

  /// Decoration images, each with its own masks. May hold several entries;
  /// empty for v1/v2 bundles (their decoration masks arrive via
  /// [categoryRawImages] and [masks] instead).
  final List<BundleDecorationSource> decorationSources;
}

/// The game-ready pair extracted from a bundle: the packed sheet PNG and
/// the sprite dictionary JSON. Used by the build-time extractor CLI and
/// by a Flame game reading the bundle directly at runtime.
class GameAssets {
  const GameAssets({required this.sheetBytes, required this.spriteDictJson});
  final Uint8List sheetBytes;
  final String spriteDictJson;
}

/// Builds a .rgpack bundle from the editor state. The packed sprite sheet
/// and sprite dictionary are generated here from the raw images and masks,
/// so the bundle stays the single source of truth: editor data and the
/// derived game assets are always written together and can never drift.
///
/// Each [BundleSource] is one draft image; its masks are cropped from it and
/// merged with every other source's into the single shared sheet. Decoration
/// may supply several sources, each stored as its own raw image so Phase 1 can
/// keep them separate on re-open (the game still sees one merged dictionary).
Uint8List writeAssetBundle({
  required List<BundleSource> sources,
  required String imageName,
}) {
  if (sources.isEmpty) {
    throw ArgumentError('No sources to export');
  }

  final export = buildSpriteExportSources([
    for (final s in sources)
      ExportSource(imageBytes: s.imageBytes, masks: s.masks),
  ]);

  // Name each source's raw file. Single-image categories keep a stable
  // per-category name; decoration numbers each image so they stay distinct.
  // Decoration masks record their source index so the grouping round-trips.
  final rawFiles = <String>[];
  final pixelProjectFiles = <String?>[];
  final sourceMeta = <Map<String, dynamic>>[];
  final maskJson = <Map<String, dynamic>>[];
  var decoIndex = 0;
  for (final s in sources) {
    final String file;
    int? thisDeco;
    if (s.category == BlockCategory.decoration) {
      thisDeco = decoIndex;
      file = 'raw_source_decoration_$decoIndex.png';
      decoIndex++;
    } else {
      file = 'raw_source_${s.category.jsonValue.toLowerCase()}.png';
    }
    rawFiles.add(file);
    final pixelProjectFile = s.pixelProjectBytes == null
        ? null
        : file.replaceFirst(RegExp(r'\.png$'), '.rgpix');
    pixelProjectFiles.add(pixelProjectFile);
    sourceMeta.add({
      'category': s.category.jsonValue,
      'name': s.name,
      'file': file,
      'pixelProject': ?pixelProjectFile,
    });
    for (final m in s.masks) {
      final mj = m.toJson();
      if (thisDeco != null) mj['decorationSourceIndex'] = thisDeco;
      maskJson.add(mj);
    }
  }

  final editorJson = const JsonEncoder.withIndent('  ').convert({
    'version': 4,
    'cellSize': GridConstants.cellSize.round(),
    'imageName': imageName,
    'masks': maskJson,
    'sources': sourceMeta,
  });

  final manifestJson = const JsonEncoder.withIndent('  ').convert({
    'format': 'race_gametool.assets',
    'version': 4,
    'cellSize': GridConstants.cellSize.round(),
    'blockCount': export.blocks.length,
    'entries': {
      'rawSource': BundleEntries.rawSource,
      'editor': BundleEntries.editor,
      'spriteSheet': BundleEntries.spriteSheet,
      'spriteDict': BundleEntries.spriteDict,
    },
  });

  final archive = Archive()
    ..addFile(_textFile(BundleEntries.manifest, manifestJson))
    // First source doubles as the legacy raw_source.png for older readers.
    ..addFile(_bytesFile(BundleEntries.rawSource, sources.first.imageBytes))
    ..addFile(_textFile(BundleEntries.editor, editorJson))
    ..addFile(_bytesFile(BundleEntries.spriteSheet, export.pngBytes))
    ..addFile(_textFile(BundleEntries.spriteDict, export.jsonText));

  for (var i = 0; i < sources.length; i++) {
    archive.addFile(_bytesFile(rawFiles[i], sources[i].imageBytes));
    final pixelProjectFile = pixelProjectFiles[i];
    final pixelProjectBytes = sources[i].pixelProjectBytes;
    if (pixelProjectFile != null && pixelProjectBytes != null) {
      archive.addFile(_bytesFile(pixelProjectFile, pixelProjectBytes));
    }
  }

  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

/// Reads a full .rgpack for editing and importing.
AssetBundleData readAssetBundle(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);

  Uint8List requireBytes(String name) {
    final file = archive.findFile(name);
    if (file == null) {
      throw FormatException('Bundle is missing "$name"');
    }
    return file.readBytes() ?? Uint8List(0);
  }

  Uint8List? optionalBytes(String name) {
    final file = archive.findFile(name);
    return file?.readBytes();
  }

  String requireText(String name) => utf8.decode(requireBytes(name));

  final editor =
      jsonDecode(requireText(BundleEntries.editor)) as Map<String, dynamic>;
  final dictJson = requireText(BundleEntries.spriteDict);
  final parsed = parseSpriteDict(dictJson);

  final rawMasks = editor['masks'] as List<dynamic>;
  final masks = rawMasks
      .map((m) => MaskDraft.fromJson(m as Map<String, dynamic>))
      .toList();

  final categoryRawImages = <BlockCategory, Uint8List>{};
  final categoryPixelProjects = <BlockCategory, Uint8List>{};
  final decorationSources = <BundleDecorationSource>[];

  final sourcesMeta = editor['sources'] as List<dynamic>?;
  if (sourcesMeta != null) {
    // v3: each source lists its own raw file. Decoration masks carry a
    // decorationSourceIndex; group them back onto their source in order.
    final decoMasksByIndex = <int, List<MaskDraft>>{};
    for (var i = 0; i < rawMasks.length; i++) {
      final di = (rawMasks[i] as Map<String, dynamic>)['decorationSourceIndex'];
      if (di is int) {
        decoMasksByIndex.putIfAbsent(di, () => []).add(masks[i]);
      }
    }
    var decoIndex = 0;
    for (final entry in sourcesMeta) {
      final m = entry as Map<String, dynamic>;
      final cat = BlockCategory.fromJson(m['category'] as String?);
      final file = m['file'] as String;
      final name = m['name'] as String? ?? file;
      final bytes = optionalBytes(file);
      if (bytes == null) continue;
      final pixelProjectFile = m['pixelProject'] as String?;
      final pixelProjectBytes = pixelProjectFile == null
          ? null
          : optionalBytes(pixelProjectFile);
      if (cat == BlockCategory.decoration) {
        decorationSources.add(
          BundleDecorationSource(
            imageBytes: bytes,
            name: name,
            masks: decoMasksByIndex[decoIndex] ?? const [],
            pixelProjectBytes: pixelProjectBytes,
          ),
        );
        decoIndex++;
      } else {
        categoryRawImages[cat] = bytes;
        if (pixelProjectBytes != null) {
          categoryPixelProjects[cat] = pixelProjectBytes;
        }
      }
    }
  } else {
    // v1/v2: per-category raw files, at most one image per category.
    for (final cat in BlockCategory.values) {
      final catFile = 'raw_source_${cat.jsonValue.toLowerCase()}.png';
      final bytes = optionalBytes(catFile);
      if (bytes != null) {
        categoryRawImages[cat] = bytes;
      }
    }
  }

  return AssetBundleData(
    rawImageBytes: requireBytes(BundleEntries.rawSource),
    imageName: editor['imageName'] as String? ?? 'draft.png',
    masks: masks,
    sheetBytes: requireBytes(BundleEntries.spriteSheet),
    spriteDictJson: dictJson,
    blocks: parsed.blocks,
    cellSize:
        (editor['cellSize'] as num?)?.round() ?? GridConstants.cellSize.round(),
    categoryRawImages: categoryRawImages,
    categoryPixelProjects: categoryPixelProjects,
    decorationSources: decorationSources,
  );
}

/// Pulls only the game-ready assets out of a bundle, without decoding the
/// editor state. Cheap enough to call at game load time.
GameAssets extractGameAssets(Uint8List zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  final sheet = archive.findFile(BundleEntries.spriteSheet);
  final dict = archive.findFile(BundleEntries.spriteDict);
  if (sheet == null || dict == null) {
    throw const FormatException(
      'Bundle is missing the packed sheet or sprite dictionary',
    );
  }
  return GameAssets(
    sheetBytes: sheet.readBytes() ?? Uint8List(0),
    spriteDictJson: utf8.decode(dict.readBytes() ?? Uint8List(0)),
  );
}

ArchiveFile _textFile(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

ArchiveFile _bytesFile(String name, Uint8List bytes) =>
    ArchiveFile(name, bytes.length, bytes);
