import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_def.dart';

/// The two top-level modes of the tool, selected via the NavigationRail.
enum AppMode {
  assetDefiner('Phase 1: Asset Definer'),
  levelEditor('Phase 2: Level Editor');

  const AppMode(this.label);
  final String label;
}

/// Currently active top-level mode.
class AppModeNotifier extends Notifier<AppMode> {
  @override
  AppMode build() => AppMode.assetDefiner;

  void select(AppMode mode) => state = mode;
}

final appModeProvider =
    NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

/// The loaded asset set shared across the app: the block dictionary plus
/// the packed sprite sheet needed to render the blocks. Phase 1 populates
/// it when saving a bundle; Phase 2 also populates it when importing a
/// .rgpack, so a single Phase 1 output can feed many Phase 2 levels.
class AssetLibrary {
  const AssetLibrary({
    this.blocks = const [],
    this.sheetBytes,
    this.sheetImage,
    this.sourceName,
  });

  final List<BlockDef> blocks;
  final Uint8List? sheetBytes;

  /// Decoded sprite sheet for CustomPaint rendering in the palette/canvas.
  final ui.Image? sheetImage;

  /// Name of the bundle or session this came from, for display.
  final String? sourceName;

  bool get isEmpty => blocks.isEmpty;
  bool get isNotEmpty => blocks.isNotEmpty;

  BlockDef? blockById(String id) {
    for (final b in blocks) {
      if (b.id == id) return b;
    }
    return null;
  }
}

class AssetLibraryNotifier extends Notifier<AssetLibrary> {
  @override
  AssetLibrary build() => const AssetLibrary();

  /// Sets the library from already-decoded parts (Phase 1 hand-off, where
  /// the sheet image is decoded once at save time).
  void setAssets({
    required List<BlockDef> blocks,
    required Uint8List sheetBytes,
    required ui.Image sheetImage,
    String? sourceName,
  }) {
    state = AssetLibrary(
      blocks: List.unmodifiable(blocks),
      sheetBytes: sheetBytes,
      sheetImage: sheetImage,
      sourceName: sourceName,
    );
  }

  /// Loads the library from raw parts, decoding the sheet image.
  Future<void> loadAssets({
    required List<BlockDef> blocks,
    required Uint8List sheetBytes,
    String? sourceName,
  }) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(sheetBytes, completer.complete);
    final image = await completer.future;
    setAssets(
      blocks: blocks,
      sheetBytes: sheetBytes,
      sheetImage: image,
      sourceName: sourceName,
    );
  }

  void clear() => state = const AssetLibrary();
}

final assetLibraryProvider =
    NotifierProvider<AssetLibraryNotifier, AssetLibrary>(
        AssetLibraryNotifier.new);
