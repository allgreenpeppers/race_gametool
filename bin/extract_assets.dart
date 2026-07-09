import 'dart:io';
import 'dart:typed_data';

import 'package:race_gametool/logic/asset_bundle.dart';

/// Build-time extractor: pulls the game-ready SpriteSheet.png and
/// sprite_dict.json out of a .rgpack asset bundle.
///
/// The bundle is the single source of truth produced by the editor;
/// these two files are derived artifacts and can be regenerated at any
/// time, so the game build calls this instead of the editor ever saving
/// a separate game export.
///
/// Usage:
///   `dart run bin/extract_assets.dart <bundle.rgpack> <output_dir>`
void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
        'Usage: dart run bin/extract_assets.dart <bundle.rgpack> <output_dir>');
    exit(64); // EX_USAGE
  }

  final bundlePath = args[0];
  final outputDir = args[1];

  final bundleFile = File(bundlePath);
  if (!bundleFile.existsSync()) {
    stderr.writeln('Bundle not found: $bundlePath');
    exit(66); // EX_NOINPUT
  }

  final GameAssets assets;
  try {
    assets = extractGameAssets(
        Uint8List.fromList(bundleFile.readAsBytesSync()));
  } on FormatException catch (e) {
    stderr.writeln('Failed to read bundle: ${e.message}');
    exit(65); // EX_DATAERR
  }

  Directory(outputDir).createSync(recursive: true);
  final sheetPath = '$outputDir/SpriteSheet.png';
  final dictPath = '$outputDir/sprite_dict.json';
  File(sheetPath).writeAsBytesSync(assets.sheetBytes);
  File(dictPath).writeAsStringSync(assets.spriteDictJson);

  stdout.writeln('Extracted:');
  stdout.writeln('  $sheetPath');
  stdout.writeln('  $dictPath');
}
