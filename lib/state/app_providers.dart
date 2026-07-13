import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_def.dart';

/// The two top-level modes of the tool, selected via the NavigationRail.
enum AppMode {
  assetDefiner('Asset Definer'),
  levelEditor('Level Editor'),
  pixelEditor('Pixel Editor');

  const AppMode(this.label);
  final String label;
}

/// Browser-style workspace: a pinned Phase 1 tab plus independent Pixel Editor
/// and Phase 2 document tabs. Tab ids are monotonic within each editor so a
/// closed family-provider instance is never reused for a different document.
class WorkspaceState {
  const WorkspaceState({
    this.levelTabs = const [],
    this.activeLevelTab,
    this.nextLevelId = 0,
    this.pixelTabs = const [],
    this.activePixelTab,
    this.nextPixelId = 0,
  });

  /// Ids of the open Phase 2 tabs, in display order.
  final List<int> levelTabs;

  /// The active level tab id, or null when the pinned Phase 1 tab is active.
  final int? activeLevelTab;

  /// Next level id to hand out. Never decremented.
  final int nextLevelId;

  /// Ids of the open Pixel Editor tabs, in display order.
  final List<int> pixelTabs;

  /// The active pixel tab id, or null when another editor is active.
  final int? activePixelTab;

  /// Next pixel id to hand out. Never decremented.
  final int nextPixelId;

  /// The top-level mode derived from which tab is active.
  AppMode get mode => activeLevelTab != null
      ? AppMode.levelEditor
      : activePixelTab != null
      ? AppMode.pixelEditor
      : AppMode.assetDefiner;

  WorkspaceState copyWith({
    List<int>? levelTabs,
    int? Function()? activeLevelTab,
    int? nextLevelId,
    List<int>? pixelTabs,
    int? Function()? activePixelTab,
    int? nextPixelId,
  }) => WorkspaceState(
    levelTabs: levelTabs ?? this.levelTabs,
    activeLevelTab: activeLevelTab != null
        ? activeLevelTab()
        : this.activeLevelTab,
    nextLevelId: nextLevelId ?? this.nextLevelId,
    pixelTabs: pixelTabs ?? this.pixelTabs,
    activePixelTab: activePixelTab != null
        ? activePixelTab()
        : this.activePixelTab,
    nextPixelId: nextPixelId ?? this.nextPixelId,
  );
}

class WorkspaceNotifier extends Notifier<WorkspaceState> {
  @override
  WorkspaceState build() => const WorkspaceState();

  /// Opens a new empty level tab and activates it. Returns its id so the
  /// caller can drive that tab's `levelEditorProvider(id).notifier`.
  int openLevelTab() {
    final id = state.nextLevelId;
    state = state.copyWith(
      levelTabs: [...state.levelTabs, id],
      activeLevelTab: () => id,
      activePixelTab: () => null,
      nextLevelId: id + 1,
    );
    return id;
  }

  /// Activates the pinned Phase 1 tab.
  void activatePhase1() => state = state.copyWith(
    activeLevelTab: () => null,
    activePixelTab: () => null,
  );

  /// Opens a new empty Pixel Editor tab and activates it.
  int openPixelTab() {
    final id = state.nextPixelId;
    state = state.copyWith(
      pixelTabs: [...state.pixelTabs, id],
      activePixelTab: () => id,
      activeLevelTab: () => null,
      nextPixelId: id + 1,
    );
    return id;
  }

  void activatePixelTab(int id) {
    if (state.pixelTabs.contains(id)) {
      state = state.copyWith(
        activePixelTab: () => id,
        activeLevelTab: () => null,
      );
    }
  }

  void activateLevelTab(int id) {
    if (state.levelTabs.contains(id)) {
      state = state.copyWith(
        activeLevelTab: () => id,
        activePixelTab: () => null,
      );
    }
  }

  /// Removes a pixel tab and focuses its neighbour, or Phase 1 when the last
  /// pixel document closes.
  void closePixelTab(int id) {
    final idx = state.pixelTabs.indexOf(id);
    if (idx < 0) return;
    final remaining = [...state.pixelTabs]..removeAt(idx);
    int? nextActive = state.activePixelTab;
    if (state.activePixelTab == id) {
      nextActive = remaining.isEmpty
          ? null
          : remaining[idx.clamp(0, remaining.length - 1)];
    }
    state = state.copyWith(
      pixelTabs: remaining,
      activePixelTab: () => nextActive,
    );
  }

  /// Removes a level tab. When the closed tab was active, focus moves to the
  /// neighbour that slides into its slot (or Phase 1 if none remain).
  void closeLevelTab(int id) {
    final idx = state.levelTabs.indexOf(id);
    if (idx < 0) return;
    final remaining = [...state.levelTabs]..removeAt(idx);
    int? nextActive = state.activeLevelTab;
    if (state.activeLevelTab == id) {
      nextActive = remaining.isEmpty
          ? null
          : remaining[idx.clamp(0, remaining.length - 1)];
    }
    state = state.copyWith(
      levelTabs: remaining,
      activeLevelTab: () => nextActive,
    );
  }

  /// Closes every level tab and returns to Phase 1. Used when the asset set is
  /// replaced (New Config), since the open levels reference the old assets.
  void closeAllLevelTabs() {
    state = state.copyWith(levelTabs: const [], activeLevelTab: () => null);
  }
}

final workspaceProvider = NotifierProvider<WorkspaceNotifier, WorkspaceState>(
  WorkspaceNotifier.new,
);

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
      AssetLibraryNotifier.new,
    );
