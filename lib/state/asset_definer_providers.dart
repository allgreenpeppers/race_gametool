import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../logic/asset_bundle.dart';
import '../logic/port_placement.dart';
import '../models/block_def.dart';
import '../models/geometry.dart';
import '../models/mask_draft.dart';
import '../models/port.dart';
import 'app_providers.dart';

/// Interaction tools available in the Phase 1 canvas.
enum Phase1Tool {
  select('Select'),
  move('Move'),
  drawBox('Draw Box'),
  paintMask('Paint Mask'),
  addPort('Add Port'),
  drawPhysicsArea('Draw Physics Area');

  const Phase1Tool(this.label);
  final String label;
}

/// A block move in progress, in grid cells. [index] is the mask being
/// moved; [dx]/[dy] is its offset from the original position (already
/// clamped so the block stays within the image).
class MovePreview {
  const MovePreview({required this.index, required this.dx, required this.dy});
  final int index;
  final int dx;
  final int dy;
}

/// A drag-in-progress rectangle, in grid cells. Purely visual feedback;
/// committed on release (a mask box in Draw Box mode, a port strip in
/// Add Port mode).
class DragPreview {
  const DragPreview({
    required this.gridX,
    required this.gridY,
    required this.widthCells,
    required this.heightCells,
  });

  final int gridX;
  final int gridY;
  final int widthCells;
  final int heightCells;
}

/// A loaded source image for one asset category.
class CategoryImage {
  const CategoryImage({
    required this.bytes,
    required this.image,
    required this.name,
  });

  final Uint8List bytes;
  final ui.Image image;
  final String name;
}

class AssetDefinerState {
  const AssetDefinerState({
    this.images = const {},
    this.masksByCategory = const {},
    this.decorationSources = const [],
    this.decorationMasks = const [],
    this.activeDecorationIndex = 0,
    this.activeCategory = BlockCategory.track,
    this.selectedIndex,
    this.tool = Phase1Tool.drawBox,
    this.dragPreview,
    this.paintPreview,
    this.movePreview,
    this.statusMessage,
    this.isDirty = false,
    this.currentFilePath,
    this.selectedVertexIndex,
    this.snapToGrid = true,
    this.physicsAreaHoverPos,
    this.curveMode = false,
    this.curveDraftPoints = const [],
  });

  /// One source image per single-image category (track, island, ...). The
  /// decoration category is multi-image and lives in [decorationSources]
  /// instead, so this map never holds a decoration entry.
  final Map<BlockCategory, CategoryImage> images;

  /// Masks for the single-image categories, keyed by category. Decoration
  /// masks live in [decorationMasks] (one list per decoration image).
  final Map<BlockCategory, List<MaskDraft>> masksByCategory;

  /// Decoration is authored across several images. These are the loaded
  /// decoration images, in display order.
  final List<CategoryImage> decorationSources;

  /// Masks per decoration image, parallel to [decorationSources]. Kept
  /// separate in Phase 1 (each authored on its own image); all merged into
  /// one sprite dictionary on export.
  final List<List<MaskDraft>> decorationMasks;

  /// Which decoration image is currently being edited.
  final int activeDecorationIndex;

  /// The category currently being edited (drives the visible image + masks).
  final BlockCategory activeCategory;

  final int? selectedIndex;
  final Phase1Tool tool;

  /// Rectangle preview for Draw Box and Add Port drags.
  final DragPreview? dragPreview;

  /// Absolute cells painted so far during a Paint Mask drag.
  final Set<Cell>? paintPreview;

  /// Block reposition in progress (Move tool).
  final MovePreview? movePreview;

  /// One-shot feedback line shown in the toolbar.
  final String? statusMessage;

  final bool isDirty;
  final String? currentFilePath;

  /// Currently selected vertex index for physicsTrackArea editing.
  final int? selectedVertexIndex;

  /// Whether physicsTrackArea vertices snap to the 16px grid.
  final bool snapToGrid;

  /// Temporary hover position for drawing physics area (virtual preview line).
  final ui.Offset? physicsAreaHoverPos;

  /// Whether curve mode is active for physicsTrackArea editing.
  final bool curveMode;

  /// Draft points currently placed for the arc curve (up to 2 points: center, start).
  final List<Vec2> curveDraftPoints;

  // --- Active-category views (keep the rest of the editor unchanged) --------

  bool get _isDecoration => activeCategory == BlockCategory.decoration;

  /// The active decoration index clamped to a valid slot, or null when there
  /// are no decoration images loaded.
  int? get _decorationSlot => decorationSources.isEmpty
      ? null
      : activeDecorationIndex.clamp(0, decorationSources.length - 1);

  CategoryImage? get activeImage {
    if (_isDecoration) {
      final slot = _decorationSlot;
      return slot == null ? null : decorationSources[slot];
    }
    return images[activeCategory];
  }

  Uint8List? get imageBytes => activeImage?.bytes;
  ui.Image? get image => activeImage?.image;
  String? get imageName => activeImage?.name;

  /// Masks of the active editing target (the active category, or the active
  /// decoration image), i.e. what the canvas edits.
  List<MaskDraft> get masks {
    if (_isDecoration) {
      final slot = _decorationSlot;
      return slot == null || slot >= decorationMasks.length
          ? const []
          : decorationMasks[slot];
    }
    return masksByCategory[activeCategory] ?? const [];
  }

  MaskDraft? get selectedMask =>
      selectedIndex == null ? null : masks[selectedIndex!];

  /// All masks across every category and every decoration image, for export.
  List<MaskDraft> get allMasks => [
        for (final c in BlockCategory.values)
          if (c != BlockCategory.decoration) ...?masksByCategory[c],
        for (final list in decorationMasks) ...list,
      ];

  bool get canExport =>
      BlockCategory.values.any((c) =>
          c != BlockCategory.decoration &&
          images[c] != null &&
          (masksByCategory[c]?.isNotEmpty ?? false)) ||
      decorationMasks.any((m) => m.isNotEmpty);

  AssetDefinerState copyWith({
    Map<BlockCategory, CategoryImage>? images,
    Map<BlockCategory, List<MaskDraft>>? masksByCategory,
    List<MaskDraft>? masks,
    List<CategoryImage>? decorationSources,
    List<List<MaskDraft>>? decorationMasks,
    int? activeDecorationIndex,
    BlockCategory? activeCategory,
    int? Function()? selectedIndex,
    Phase1Tool? tool,
    DragPreview? Function()? dragPreview,
    Set<Cell>? Function()? paintPreview,
    MovePreview? Function()? movePreview,
    String? Function()? statusMessage,
    bool? isDirty,
    String? Function()? currentFilePath,
    int? Function()? selectedVertexIndex,
    bool? snapToGrid,
    ui.Offset? Function()? physicsAreaHoverPos,
    bool? curveMode,
    List<Vec2>? curveDraftPoints,
  }) {
    final category = activeCategory ?? this.activeCategory;
    final decIndex = activeDecorationIndex ?? this.activeDecorationIndex;
    var nextMasksByCategory = masksByCategory ?? this.masksByCategory;
    var nextDecorationMasks = decorationMasks ?? this.decorationMasks;
    // The `masks` convenience param writes to the active editing target: the
    // active decoration image when decoration is active, else the active
    // category's list.
    if (masks != null) {
      if (category == BlockCategory.decoration) {
        if (decIndex >= 0 && decIndex < nextDecorationMasks.length) {
          nextDecorationMasks = [...nextDecorationMasks]..[decIndex] = masks;
        }
      } else {
        nextMasksByCategory = {...nextMasksByCategory, category: masks};
      }
    }
    return AssetDefinerState(
      images: images ?? this.images,
      masksByCategory: nextMasksByCategory,
      decorationSources: decorationSources ?? this.decorationSources,
      decorationMasks: nextDecorationMasks,
      activeDecorationIndex: decIndex,
      activeCategory: category,
      selectedIndex:
          selectedIndex != null ? selectedIndex() : this.selectedIndex,
      tool: tool ?? this.tool,
      dragPreview: dragPreview != null ? dragPreview() : this.dragPreview,
      paintPreview: paintPreview != null ? paintPreview() : this.paintPreview,
      movePreview: movePreview != null ? movePreview() : this.movePreview,
      statusMessage:
          statusMessage != null ? statusMessage() : this.statusMessage,
      isDirty: isDirty ?? this.isDirty,
      currentFilePath:
          currentFilePath != null ? currentFilePath() : this.currentFilePath,
      selectedVertexIndex: selectedVertexIndex != null
          ? selectedVertexIndex()
          : this.selectedVertexIndex,
      snapToGrid: snapToGrid ?? this.snapToGrid,
      physicsAreaHoverPos: physicsAreaHoverPos != null
          ? physicsAreaHoverPos()
          : this.physicsAreaHoverPos,
      curveMode: curveMode ?? this.curveMode,
      curveDraftPoints: curveDraftPoints ?? this.curveDraftPoints,
    );
  }
}

class AssetDefinerNotifier extends Notifier<AssetDefinerState> {
  int _nextBlockNumber = 1;
  ({int x, int y})? _dragAnchor;
  Cell? _lastPaintCell;

  bool _isDraggingVertex = false;

  @override
  AssetDefinerState build() => const AssetDefinerState();

  void setActiveCategory(BlockCategory category) {
    state = state.copyWith(
      activeCategory: category,
      selectedIndex: () => null,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
      tool: category == BlockCategory.islandTile ? Phase1Tool.drawBox : state.tool,
      statusMessage: () => 'Editing ${category.jsonValue}',
    );
  }

  /// Prompts for an image file and decodes it. Returns null if cancelled.
  Future<(Uint8List bytes, ui.Image image, String name)?> _pickImage() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Load image for ${state.activeCategory.jsonValue}',
      type: FileType.image,
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return null;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;
    return (bytes, image, result!.files.single.name);
  }

  /// Loads (or replaces) the image for the active editing target, keeping its
  /// existing masks. For a single-image category this updates that category's
  /// art; for decoration it replaces the active decoration image (or, when
  /// none exists yet, adds the first one). Reports masks that fall outside a
  /// smaller image.
  Future<void> loadImage() async {
    // Decoration with nothing loaded yet: the first "Load" simply adds one.
    if (state.activeCategory == BlockCategory.decoration &&
        state.decorationSources.isEmpty) {
      await addDecorationImage();
      return;
    }

    final picked = await _pickImage();
    if (picked == null) return;
    final (bytes, image, name) = picked;

    final hadImage = state.activeImage != null;
    final cols = (image.width / GridConstants.cellSize).ceil();
    final rows = (image.height / GridConstants.cellSize).ceil();
    final outOfBounds = state.masks
        .where((m) =>
            m.gridX + m.widthCells > cols || m.gridY + m.heightCells > rows)
        .map((m) => m.id)
        .toList();

    final statusMessage = !hadImage
        ? 'Loaded $name (${image.width} x ${image.height} px)'
        : outOfBounds.isEmpty
            ? 'Replaced image with $name, kept ${state.masks.length} blocks'
            : 'Replaced image; ${outOfBounds.length} block(s) now out of '
                'bounds: ${outOfBounds.join(', ')}';

    final newImage = CategoryImage(bytes: bytes, image: image, name: name);
    if (state.activeCategory == BlockCategory.decoration) {
      final slot = state.activeDecorationIndex;
      final newSources = [...state.decorationSources]..[slot] = newImage;
      state = state.copyWith(
        decorationSources: newSources,
        tool: Phase1Tool.drawBox,
        dragPreview: () => null,
        paintPreview: () => null,
        movePreview: () => null,
        selectedVertexIndex: () => null,
        physicsAreaHoverPos: () => null,
        curveMode: false,
        curveDraftPoints: const [],
        isDirty: true,
        statusMessage: () => statusMessage,
      );
    } else {
      state = state.copyWith(
        images: {...state.images, state.activeCategory: newImage},
        tool: Phase1Tool.drawBox,
        dragPreview: () => null,
        paintPreview: () => null,
        movePreview: () => null,
        selectedVertexIndex: () => null,
        physicsAreaHoverPos: () => null,
        curveMode: false,
        curveDraftPoints: const [],
        isDirty: true,
        statusMessage: () => statusMessage,
      );
    }
  }

  /// Adds a new decoration image and makes it the active one. Decoration is
  /// authored across multiple images that all merge on export.
  Future<void> addDecorationImage() async {
    final picked = await _pickImage();
    if (picked == null) return;
    final (bytes, image, name) = picked;

    final newSources = [
      ...state.decorationSources,
      CategoryImage(bytes: bytes, image: image, name: name),
    ];
    final newMasks = [...state.decorationMasks, <MaskDraft>[]];
    state = state.copyWith(
      decorationSources: newSources,
      decorationMasks: newMasks,
      activeCategory: BlockCategory.decoration,
      activeDecorationIndex: newSources.length - 1,
      selectedIndex: () => null,
      tool: Phase1Tool.drawBox,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
      isDirty: true,
      statusMessage: () => 'Added decoration image $name',
    );
  }

  void setActiveDecorationIndex(int index) {
    if (index < 0 || index >= state.decorationSources.length) return;
    state = state.copyWith(
      activeCategory: BlockCategory.decoration,
      activeDecorationIndex: index,
      selectedIndex: () => null,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
      statusMessage: () => 'Editing ${state.decorationSources[index].name}',
    );
  }

  void removeDecorationImage(int index) {
    if (index < 0 || index >= state.decorationSources.length) return;
    final newSources = [...state.decorationSources]..removeAt(index);
    final newMasks = [...state.decorationMasks];
    if (index < newMasks.length) newMasks.removeAt(index);
    var newActive = state.activeDecorationIndex;
    if (newActive >= newSources.length) newActive = newSources.length - 1;
    if (newActive < 0) newActive = 0;
    state = state.copyWith(
      decorationSources: newSources,
      decorationMasks: newMasks,
      activeDecorationIndex: newActive,
      selectedIndex: () => null,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
      isDirty: true,
      statusMessage: () => 'Removed decoration image',
    );
  }

  void setTool(Phase1Tool tool) {
    state = state.copyWith(
      tool: tool,
      dragPreview: () => null,
      paintPreview: () => null,
      movePreview: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
    );
    _dragAnchor = null;
    _isDraggingVertex = false;
  }

  /// Grid dimensions of the current image in whole cells.
  (int cols, int rows) get _gridSize {
    final image = state.image;
    if (image == null) return (0, 0);
    return (
      (image.width / GridConstants.cellSize).ceil(),
      (image.height / GridConstants.cellSize).ceil(),
    );
  }

  // --- Drag handling (Draw Box, Paint Mask, Add Port) -----------------------

  void dragStart(int cellX, int cellY) {
    if (state.image == null) return;
    switch (state.tool) {
      case Phase1Tool.drawBox || Phase1Tool.addPort:
        _dragAnchor = (x: cellX, y: cellY);
        state = state.copyWith(
          dragPreview: () => DragPreview(
              gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
        );
      case Phase1Tool.paintMask:
        _lastPaintCell = (cellX, cellY);
        state = state.copyWith(paintPreview: () => {(cellX, cellY)});
      case Phase1Tool.move:
        _startMove(cellX, cellY);
      case Phase1Tool.select:
        break;
      case Phase1Tool.drawPhysicsArea:
        break;
    }
  }

  void dragUpdate(int cellX, int cellY) {
    switch (state.tool) {
      case Phase1Tool.drawBox:
        _updateRectPreview(cellX, cellY, clampToStrip: false);
      case Phase1Tool.addPort:
        _updateRectPreview(cellX, cellY, clampToStrip: true);
      case Phase1Tool.move:
        _updateMove(cellX, cellY);
      case Phase1Tool.paintMask:
        final cells = state.paintPreview;
        if (cells == null) return;
        // Interpolate from the previous sample so fast drags leave a
        // continuous stroke instead of scattered cells.
        final from = _lastPaintCell ?? (cellX, cellY);
        _lastPaintCell = (cellX, cellY);
        state = state.copyWith(
            paintPreview: () =>
                {...cells, ..._lineCells(from, (cellX, cellY))});
      case Phase1Tool.select:
        break;
      case Phase1Tool.drawPhysicsArea:
        break;
    }
  }

  void _updateRectPreview(int cellX, int cellY, {required bool clampToStrip}) {
    final anchor = _dragAnchor;
    if (anchor == null) return;
    var x = cellX;
    var y = cellY;

    if (state.tool == Phase1Tool.drawBox &&
        state.activeCategory == BlockCategory.islandTile) {
      x = anchor.x;
      y = anchor.y;
    }

    if (clampToStrip) {
      // Port marquees are one row or one column: collapse the minor axis.
      if ((cellX - anchor.x).abs() >= (cellY - anchor.y).abs()) {
        y = anchor.y;
      } else {
        x = anchor.x;
      }
    }
    final x0 = x < anchor.x ? x : anchor.x;
    final y0 = y < anchor.y ? y : anchor.y;
    final x1 = x > anchor.x ? x : anchor.x;
    final y1 = y > anchor.y ? y : anchor.y;
    state = state.copyWith(
      dragPreview: () => DragPreview(
        gridX: x0,
        gridY: y0,
        widthCells: x1 - x0 + 1,
        heightCells: y1 - y0 + 1,
      ),
    );
  }

  /// Bresenham line between two cells, inclusive of both ends.
  static Iterable<Cell> _lineCells(Cell from, Cell to) sync* {
    var (x, y) = from;
    final (x1, y1) = to;
    final dx = (x1 - x).abs();
    final dy = -(y1 - y).abs();
    final sx = x < x1 ? 1 : -1;
    final sy = y < y1 ? 1 : -1;
    var err = dx + dy;
    while (true) {
      yield (x, y);
      if (x == x1 && y == y1) return;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  void dragEnd() {
    _dragAnchor = null;
    _lastPaintCell = null;
    switch (state.tool) {
      case Phase1Tool.drawBox:
        _commitBox();
      case Phase1Tool.paintMask:
        _commitPaintedMask();
      case Phase1Tool.addPort:
        _commitPortStrip();
      case Phase1Tool.move:
        _commitMove();
      case Phase1Tool.select:
        break;
      case Phase1Tool.drawPhysicsArea:
        break;
    }
  }

  void tapCell(int cellX, int cellY) {
    switch (state.tool) {
      case Phase1Tool.select || Phase1Tool.move:
        _selectAt(cellX, cellY);
      case Phase1Tool.addPort:
        // A click is a 1x1 marquee.
        state = state.copyWith(
          dragPreview: () => DragPreview(
              gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
        );
        _commitPortStrip();
      case Phase1Tool.drawBox:
        if (state.activeCategory == BlockCategory.islandTile) {
          state = state.copyWith(
            dragPreview: () => DragPreview(
                gridX: cellX, gridY: cellY, widthCells: 1, heightCells: 1),
          );
          _commitBox();
        }
        break;
      case Phase1Tool.paintMask:
        break;
      case Phase1Tool.drawPhysicsArea:
        break;
    }
  }

  void _commitBox() {
    final preview = state.dragPreview;
    if (preview == null) return;
    final mask = MaskDraft(
      id: 'block_${_nextBlockNumber++}',
      gridX: preview.gridX,
      gridY: preview.gridY,
      widthCells: preview.widthCells,
      heightCells: preview.heightCells,
      category: state.activeCategory,
    );
    state = state.copyWith(
      masks: [...state.masks, mask],
      selectedIndex: () => state.masks.length,
      dragPreview: () => null,
      isDirty: true,
      statusMessage: () =>
          'Added ${mask.id} (${mask.widthCells} x ${mask.heightCells} cells)',
    );
  }

  // --- Move (reposition an existing block) ----------------------------------

  void _startMove(int cellX, int cellY) {
    for (var i = state.masks.length - 1; i >= 0; i--) {
      if (state.masks[i].containsCell(cellX, cellY)) {
        _dragAnchor = (x: cellX, y: cellY);
        state = state.copyWith(
          selectedIndex: () => i,
          movePreview: () => MovePreview(index: i, dx: 0, dy: 0),
        );
        return;
      }
    }
    // Drag started on empty space: nothing to move.
    _dragAnchor = null;
  }

  void _updateMove(int cellX, int cellY) {
    final anchor = _dragAnchor;
    final move = state.movePreview;
    if (anchor == null || move == null) return;
    final mask = state.masks[move.index];
    final (cols, rows) = _gridSize;
    // Clamp so the whole bounding box stays inside the image.
    final dx = (cellX - anchor.x)
        .clamp(-mask.gridX, cols - mask.widthCells - mask.gridX);
    final dy = (cellY - anchor.y)
        .clamp(-mask.gridY, rows - mask.heightCells - mask.gridY);
    state = state.copyWith(
        movePreview: () => MovePreview(index: move.index, dx: dx, dy: dy));
  }

  void _commitMove() {
    final move = state.movePreview;
    if (move == null) return;
    if (move.dx == 0 && move.dy == 0) {
      state = state.copyWith(movePreview: () => null);
      return;
    }
    final mask = state.masks[move.index];
    final moved = mask.copyWith(
      gridX: mask.gridX + move.dx,
      gridY: mask.gridY + move.dy,
    );
    final masks = [...state.masks];
    masks[move.index] = moved;
    state = state.copyWith(
      masks: masks,
      movePreview: () => null,
      isDirty: true,
      statusMessage: () =>
          'Moved ${moved.id} to (${moved.gridX}, ${moved.gridY})',
    );
  }

  void _commitPaintedMask() {
    final cells = state.paintPreview;
    if (cells == null || cells.isEmpty) return;
    final mask = MaskDraft.fromCells(
      id: 'block_${_nextBlockNumber++}',
      absoluteCells: cells,
      category: state.activeCategory,
    );
    state = state.copyWith(
      masks: [...state.masks, mask],
      selectedIndex: () => state.masks.length,
      paintPreview: () => null,
      isDirty: true,
      statusMessage: () => 'Added freeform ${mask.id} '
          '(${cells.length} cells in a ${mask.widthCells} x '
          '${mask.heightCells} box)',
    );
  }

  void _commitPortStrip() {
    final preview = state.dragPreview;
    if (preview == null) return;

    // Prefer the selected mask when the strip lies inside it; otherwise
    // pick the topmost mask containing the strip and select it.
    var maskIndex = state.selectedIndex;
    if (maskIndex == null ||
        !state.masks[maskIndex]
            .containsRect(preview.gridX, preview.gridY, preview.widthCells,
                preview.heightCells)) {
      maskIndex = null;
      for (var i = state.masks.length - 1; i >= 0; i--) {
        if (state.masks[i].containsRect(preview.gridX, preview.gridY,
            preview.widthCells, preview.heightCells)) {
          maskIndex = i;
          break;
        }
      }
    }
    if (maskIndex == null) {
      state = state.copyWith(
        dragPreview: () => null,
        statusMessage: () => 'Port selection must lie inside a block',
      );
      return;
    }

    final mask = state.masks[maskIndex];
    final placement = resolvePortStrip(
      mask: mask,
      gridX: preview.gridX,
      gridY: preview.gridY,
      widthCells: preview.widthCells,
      heightCells: preview.heightCells,
    );

    switch (placement) {
      case PortPlacementError(:final message):
        state = state.copyWith(
          selectedIndex: () => maskIndex,
          dragPreview: () => null,
          statusMessage: () => message,
        );
      case PortPlacementOk(:final port):
        if (mask.ports.contains(port)) {
          state = state.copyWith(
            selectedIndex: () => maskIndex,
            dragPreview: () => null,
          );
          return;
        }
        final masks = [...state.masks];
        masks[maskIndex] = mask.copyWith(ports: [...mask.ports, port]);
        state = state.copyWith(
          masks: masks,
          selectedIndex: () => maskIndex,
          dragPreview: () => null,
          isDirty: true,
          statusMessage: () => 'Added ${port.bidirectional ? "pass-through " : ""}'
              'port ${port.direction.jsonValue} (span ${port.span}) '
              'on ${mask.id}',
        );
    }
  }

  // --- Selection and editing -------------------------------------------------

  /// Direct selection from the block list, independent of the active tool.
  void selectMask(int? index) =>
      state = state.copyWith(
        selectedIndex: () => index,
        selectedVertexIndex: () => null,
        physicsAreaHoverPos: () => null,
        curveMode: false,
        curveDraftPoints: const [],
      );

  void _selectAt(int cellX, int cellY) {
    for (var i = state.masks.length - 1; i >= 0; i--) {
      if (state.masks[i].containsCell(cellX, cellY)) {
        state = state.copyWith(
          selectedIndex: () => i,
          selectedVertexIndex: () => null,
          physicsAreaHoverPos: () => null,
          curveMode: false,
          curveDraftPoints: const [],
        );
        return;
      }
    }
    state = state.copyWith(
      selectedIndex: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveMode: false,
      curveDraftPoints: const [],
    );
  }

  void renameMask(int index, String id) =>
      _updateMask(index, state.masks[index].copyWith(id: id));

  void setMaskCategory(int index, BlockCategory category) {
    // Corner marking only applies to island tiles; reset it otherwise.
    _updateMask(
      index,
      state.masks[index].copyWith(
        category: category,
        cornerType: category == BlockCategory.islandTile
            ? state.masks[index].cornerType
            : CornerType.none,
      ),
    );
  }

  void setMaskCornerType(int index, CornerType type) =>
      _updateMask(index, state.masks[index].copyWith(cornerType: type));

  void removeMask(int index) {
    final masks = [...state.masks]..removeAt(index);
    state = state.copyWith(masks: masks, selectedIndex: () => null, isDirty: true);
  }

  void updatePort(int maskIndex, int portIndex, Port port) {
    final mask = state.masks[maskIndex];
    final ports = [...mask.ports];
    ports[portIndex] = port;
    _updateMask(maskIndex, mask.copyWith(ports: ports));
  }

  void addPort(int maskIndex, Port port) {
    final mask = state.masks[maskIndex];
    _updateMask(maskIndex, mask.copyWith(ports: [...mask.ports, port]));
  }

  void removePort(int maskIndex, int portIndex) {
    final mask = state.masks[maskIndex];
    final ports = [...mask.ports]..removeAt(portIndex);
    _updateMask(maskIndex, mask.copyWith(ports: ports));
  }

  void _updateMask(int index, MaskDraft mask) {
    final masks = [...state.masks];
    masks[index] = mask;
    state = state.copyWith(masks: masks, isDirty: true);
  }

  // --- Bundle save / open ---------------------------------------------------

  /// Collects the draft images that have masks into bundle sources: one per
  /// single-image category, plus one per non-empty decoration image. Their
  /// masks all merge into a single sprite dictionary on write.
  List<BundleSource> _collectSources() {
    final sources = <BundleSource>[];
    for (final c in BlockCategory.values) {
      if (c == BlockCategory.decoration) continue;
      final catImage = state.images[c];
      final catMasks = state.masksByCategory[c];
      if (catImage != null && catMasks != null && catMasks.isNotEmpty) {
        sources.add(BundleSource(
          category: c,
          name: catImage.name,
          imageBytes: catImage.bytes,
          masks: catMasks,
        ));
      }
    }
    for (var i = 0; i < state.decorationSources.length; i++) {
      final masks = i < state.decorationMasks.length
          ? state.decorationMasks[i]
          : const <MaskDraft>[];
      if (masks.isEmpty) continue;
      final img = state.decorationSources[i];
      sources.add(BundleSource(
        category: BlockCategory.decoration,
        name: img.name,
        imageBytes: img.bytes,
        masks: masks,
      ));
    }
    return sources;
  }

  void newConfig() {
    _nextBlockNumber = 1;
    _dragAnchor = null;
    _lastPaintCell = null;
    state = const AssetDefinerState();
    // Also clear the shared library so the level editor doesn't have stale assets
    ref.read(assetLibraryProvider.notifier).clear();
  }

  Future<void> save() async {
    if (state.currentFilePath != null) {
      await saveToPath(state.currentFilePath!);
    } else {
      await saveAs();
    }
  }

  Future<void> saveAs() async {
    if (!state.canExport) return;

    final duplicateIds = _findDuplicateIds();
    if (duplicateIds.isNotEmpty) {
      state = state.copyWith(
          statusMessage: () =>
              'Save blocked: duplicate block IDs ${duplicateIds.join(', ')}');
      return;
    }

    final Uint8List bundleBytes;
    try {
      bundleBytes = writeAssetBundle(
        sources: _collectSources(),
        imageName: state.imageName ?? 'draft.png',
      );
    } on Object catch (e) {
      state = state.copyWith(statusMessage: () => 'Save failed: $e');
      return;
    }

    final suggestedName = _bundleFileNameFor(state.imageName);
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save asset bundle',
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      bytes: bundleBytes,
    );
    if (path == null) {
      state = state.copyWith(statusMessage: () => 'Save cancelled');
      return;
    }

    // Populate the shared library from the same bundle we just wrote.
    try {
      final data = readAssetBundle(bundleBytes);
      await ref.read(assetLibraryProvider.notifier).loadAssets(
            blocks: data.blocks,
            sheetBytes: data.sheetBytes,
            sourceName: suggestedName,
          );
    } on Object {
      // Non-fatal: the file is saved regardless of the in-memory hand-off.
    }

    state = state.copyWith(
      isDirty: false,
      currentFilePath: () => path,
      statusMessage: () =>
          'Saved ${state.allMasks.length} blocks to $path (available in Phase 2)',
    );
  }

  Future<void> saveToPath(String path) async {
    if (!state.canExport) return;

    final duplicateIds = _findDuplicateIds();
    if (duplicateIds.isNotEmpty) {
      state = state.copyWith(
          statusMessage: () =>
              'Save blocked: duplicate block IDs ${duplicateIds.join(', ')}');
      return;
    }

    final Uint8List bundleBytes;
    try {
      bundleBytes = writeAssetBundle(
        sources: _collectSources(),
        imageName: state.imageName ?? 'draft.png',
      );
    } on Object catch (e) {
      state = state.copyWith(statusMessage: () => 'Save failed: $e');
      return;
    }

    try {
      final file = File(path);
      await file.writeAsBytes(bundleBytes);
    } catch (e) {
      state = state.copyWith(statusMessage: () => 'Save to disk failed: $e');
      return;
    }

    // Populate the shared library from the same bundle we just wrote.
    try {
      final data = readAssetBundle(bundleBytes);
      await ref.read(assetLibraryProvider.notifier).loadAssets(
            blocks: data.blocks,
            sheetBytes: data.sheetBytes,
            sourceName: path.split('/').last,
          );
    } on Object {
      // Non-fatal: the file is saved regardless of the in-memory hand-off.
    }

    state = state.copyWith(
      isDirty: false,
      currentFilePath: () => path,
      statusMessage: () =>
          'Saved ${state.allMasks.length} blocks to $path (available in Phase 2)',
    );
  }

  /// Opens a .rgpack back into the Phase 1 editor for further editing.
  Future<void> openBundle() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open asset bundle',
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    final path = result?.files.single.path;
    if (bytes == null) return;
    await _loadBundleBytes(bytes, sourceName: result!.files.single.name, filePath: path);
  }

  /// Opens a .rgpack given a filesystem path, used when the OS launches or
  /// activates the app with an associated file (Finder double-click,
  /// "Open With"). Under the app sandbox this read is permitted because
  /// Launch Services grants access to the user-opened file.
  Future<void> openBundleFromPath(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      state = state.copyWith(statusMessage: () => 'File not found: $path');
      return;
    }
    final bytes = await file.readAsBytes();
    await _loadBundleBytes(bytes, sourceName: path.split('/').last, filePath: path);
  }

  Future<ui.Image> _decode(Uint8List bytes) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  Future<void> _loadBundleBytes(
    Uint8List bytes, {
    required String sourceName,
    String? filePath,
  }) async {
    final AssetBundleData data;
    try {
      data = readAssetBundle(bytes);
    } on Object catch (e) {
      state = state.copyWith(statusMessage: () => 'Open failed: $e');
      return;
    }

    final fallbackImage = await _decode(data.rawImageBytes);

    // Group the single-image categories' masks (decoration is handled
    // separately below since it can span several images).
    final groupedMasks = <BlockCategory, List<MaskDraft>>{};
    for (final mask in data.masks) {
      if (mask.category == BlockCategory.decoration) continue;
      groupedMasks.putIfAbsent(mask.category, () => []).add(mask);
    }

    final images = <BlockCategory, CategoryImage>{};
    if (data.categoryRawImages.isNotEmpty) {
      for (final entry in data.categoryRawImages.entries) {
        if (entry.key == BlockCategory.decoration) continue;
        images[entry.key] = CategoryImage(
          bytes: entry.value,
          image: await _decode(entry.value),
          name: data.imageName,
        );
      }
    } else {
      // Legacy single-image bundle: share the raw source across the
      // non-decoration categories that have masks.
      for (final cat in groupedMasks.keys) {
        images[cat] = CategoryImage(
          bytes: data.rawImageBytes,
          image: fallbackImage,
          name: data.imageName,
        );
      }
    }

    // Restore each decoration image and its masks separately.
    final decorationSources = <CategoryImage>[];
    final decorationMasks = <List<MaskDraft>>[];
    if (data.decorationSources.isNotEmpty) {
      for (final src in data.decorationSources) {
        decorationSources.add(CategoryImage(
          bytes: src.imageBytes,
          image: await _decode(src.imageBytes),
          name: src.name,
        ));
        decorationMasks.add(src.masks);
      }
    } else {
      // v1/v2 back-compat: all decoration masks share a single image.
      final decoMasks = [
        for (final m in data.masks)
          if (m.category == BlockCategory.decoration) m,
      ];
      if (decoMasks.isNotEmpty) {
        final decoBytes = data.categoryRawImages[BlockCategory.decoration] ??
            data.rawImageBytes;
        decorationSources.add(CategoryImage(
          bytes: decoBytes,
          image: identical(decoBytes, data.rawImageBytes)
              ? fallbackImage
              : await _decode(decoBytes),
          name: data.imageName,
        ));
        decorationMasks.add(decoMasks);
      }
    }

    final initialCategory = groupedMasks.keys.isNotEmpty
        ? groupedMasks.keys.first
        : (decorationSources.isNotEmpty
            ? BlockCategory.decoration
            : BlockCategory.track);

    state = AssetDefinerState(
      images: images,
      masksByCategory: groupedMasks,
      decorationSources: decorationSources,
      decorationMasks: decorationMasks,
      activeCategory: initialCategory,
      tool: Phase1Tool.select,
      statusMessage: 'Opened $sourceName (${data.masks.length} blocks)',
      isDirty: false,
      currentFilePath: filePath,
    );
    // Keep the highest existing block_N counter so new boxes do not collide.
    _nextBlockNumber = _highestBlockNumber(data.masks) + 1;

    // Also make it available to Phase 2 immediately.
    await ref.read(assetLibraryProvider.notifier).loadAssets(
          blocks: data.blocks,
          sheetBytes: data.sheetBytes,
          sourceName: sourceName,
        );
  }

  static String _bundleFileNameFor(String? imageName) {
    if (imageName == null || imageName.isEmpty) return 'assets.rgpack';
    final dot = imageName.lastIndexOf('.');
    final stem = dot > 0 ? imageName.substring(0, dot) : imageName;
    return '$stem.rgpack';
  }

  static int _highestBlockNumber(List<MaskDraft> masks) {
    var highest = 0;
    final pattern = RegExp(r'^block_(\d+)$');
    for (final mask in masks) {
      final match = pattern.firstMatch(mask.id);
      if (match != null) {
        highest = math.max(highest, int.parse(match.group(1)!));
      }
    }
    return highest;
  }

  List<String> _findDuplicateIds() {
    final seen = <String>{};
    final duplicates = <String>{};
    // Every source's masks merge into one dictionary, so ids must be unique
    // across all categories and every decoration image, not just the active
    // editing target.
    for (final mask in state.allMasks) {
      if (!seen.add(mask.id)) duplicates.add(mask.id);
    }
    return duplicates.toList();
  }

  void selectVertex(int? index) {
    state = state.copyWith(selectedVertexIndex: () => index);
  }

  void setSnapToGrid(bool value) {
    state = state.copyWith(snapToGrid: value);
  }

  void toggleCurveMode() {
    state = state.copyWith(
      curveMode: !state.curveMode,
      curveDraftPoints: const [],
    );
  }

  void updatePhysicsAreaHover(ui.Offset? localPos) {
    state = state.copyWith(physicsAreaHoverPos: () => localPos);
  }

  double _snapCoord(double val) {
    if (!state.snapToGrid) return val.roundToDouble();
    final halfCell = GridConstants.cellSize / 2.0;
    final near = (val / halfCell).round() * halfCell;
    if ((val - near).abs() < 4.0) {
      return near;
    }
    return val.roundToDouble();
  }

  void trackAreaDragStart(ui.Offset localPos) {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    final originX = mask.gridX * GridConstants.cellSize;
    final originY = mask.gridY * GridConstants.cellSize;
    final lx = localPos.dx - originX;
    final ly = localPos.dy - originY;

    final vertices = mask.physicsTrackArea;
    int? clickedIdx;
    const hitRadius = 8.0;
    for (var i = 0; i < vertices.length; i++) {
      final v = vertices[i];
      final dist = math.sqrt((v.x - lx) * (v.x - lx) + (v.y - ly) * (v.y - ly));
      if (dist <= hitRadius) {
        clickedIdx = i;
        break;
      }
    }

    if (clickedIdx != null) {
      _isDraggingVertex = true;
      state = state.copyWith(
        selectedVertexIndex: () => clickedIdx,
      );
    } else {
      _isDraggingVertex = false;
    }
  }

  void trackAreaDragUpdate(ui.Offset localPos) {
    final maskIndex = state.selectedIndex;
    final vertexIndex = state.selectedVertexIndex;
    if (maskIndex == null || vertexIndex == null || !_isDraggingVertex) return;

    final mask = state.masks[maskIndex];
    final originX = mask.gridX * GridConstants.cellSize;
    final originY = mask.gridY * GridConstants.cellSize;
    final lx = (localPos.dx - originX).clamp(0.0, mask.widthCells * GridConstants.cellSize);
    final ly = (localPos.dy - originY).clamp(0.0, mask.heightCells * GridConstants.cellSize);

    final snappedX = _snapCoord(lx);
    final snappedY = _snapCoord(ly);

    final newVertices = [...mask.physicsTrackArea];
    if (vertexIndex >= 0 && vertexIndex < newVertices.length) {
      newVertices[vertexIndex] = Vec2(snappedX, snappedY);
      final updated = mask.copyWith(physicsTrackArea: newVertices);
      _updateMask(maskIndex, updated);
    }
  }

  void trackAreaDragEnd() {
    _isDraggingVertex = false;
  }

  List<Vec2> _generateArc(Vec2 center, Vec2 start, Vec2 end, int widthCells, int heightCells) {
    final double r = math.sqrt((start.x - center.x) * (start.x - center.x) +
        (start.y - center.y) * (start.y - center.y));
    if (r == 0) return [start];

    final double thetaA = math.atan2(start.y - center.y, start.x - center.x);
    final double thetaB = math.atan2(end.y - center.y, end.x - center.x);

    const int steps = 12;
    final double w = widthCells * GridConstants.cellSize;
    final double h = heightCells * GridConstants.cellSize;

    // Path 1: Counter-clockwise (increasing angle)
    double angleB1 = thetaB;
    if (angleB1 < thetaA) angleB1 += 2.0 * math.pi;
    final points1 = <Vec2>[];
    for (var i = 0; i <= steps; i++) {
      final t = thetaA + (angleB1 - thetaA) * (i / steps);
      points1.add(Vec2(
        (center.x + r * math.cos(t)).roundToDouble(),
        (center.y + r * math.sin(t)).roundToDouble(),
      ));
    }

    // Path 2: Clockwise (decreasing angle)
    double angleB2 = thetaB;
    if (angleB2 > thetaA) angleB2 -= 2.0 * math.pi;
    final points2 = <Vec2>[];
    for (var i = 0; i <= steps; i++) {
      final t = thetaA + (angleB2 - thetaA) * (i / steps);
      points2.add(Vec2(
        (center.x + r * math.cos(t)).roundToDouble(),
        (center.y + r * math.sin(t)).roundToDouble(),
      ));
    }

    int countInside(List<Vec2> pts) {
      var count = 0;
      for (final p in pts) {
        if (p.x >= 0.0 && p.x <= w && p.y >= 0.0 && p.y <= h) {
          count++;
        }
      }
      return count;
    }

    if (countInside(points1) >= countInside(points2)) {
      return points1;
    } else {
      return points2;
    }
  }

  void trackAreaTap(ui.Offset localPos) {
    // Direct selection on canvas is ONLY allowed when no block is selected yet.
    if (state.selectedIndex == null) {
      final cellX = (localPos.dx / GridConstants.cellSize).floor();
      final cellY = (localPos.dy / GridConstants.cellSize).floor();
      int? hitIndex;
      for (var i = state.masks.length - 1; i >= 0; i--) {
        if (state.masks[i].containsCell(cellX, cellY)) {
          hitIndex = i;
          break;
        }
      }
      if (hitIndex != null) {
        selectMask(hitIndex);
        return;
      }
    }

    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    final originX = mask.gridX * GridConstants.cellSize;
    final originY = mask.gridY * GridConstants.cellSize;
    final lx = localPos.dx - originX;
    final ly = localPos.dy - originY;

    // Check if clicked outside bounding box
    if (lx < -8.0 ||
        lx > mask.widthCells * GridConstants.cellSize + 8.0 ||
        ly < -8.0 ||
        ly > mask.heightCells * GridConstants.cellSize + 8.0) {
      return;
    }

    final vertices = mask.physicsTrackArea;
    int? clickedIdx;
    const hitRadius = 8.0;
    for (var i = 0; i < vertices.length; i++) {
      final v = vertices[i];
      final dist = math.sqrt((v.x - lx) * (v.x - lx) + (v.y - ly) * (v.y - ly));
      if (dist <= hitRadius) {
        clickedIdx = i;
        break;
      }
    }

    if (clickedIdx != null) {
      if (clickedIdx == 0 && vertices.length >= 3) {
        closePhysicsArea();
      } else {
        state = state.copyWith(selectedVertexIndex: () => clickedIdx);
      }
    } else {
      final snappedX = _snapCoord(lx.clamp(0.0, mask.widthCells * GridConstants.cellSize));
      final snappedY = _snapCoord(ly.clamp(0.0, mask.heightCells * GridConstants.cellSize));
      final clickPt = Vec2(snappedX, snappedY);

      if (state.curveMode) {
        final nextDraft = [...state.curveDraftPoints];
        if (nextDraft.isEmpty) {
          nextDraft.add(clickPt);
          state = state.copyWith(curveDraftPoints: nextDraft);
        } else if (nextDraft.length == 1) {
          nextDraft.add(clickPt);
          state = state.copyWith(curveDraftPoints: nextDraft);
        } else {
          final center = nextDraft[0];
          final start = nextDraft[1];
          final end = clickPt;

          final arcPoints = _generateArc(center, start, end, mask.widthCells, mask.heightCells);

          final newVertices = [...mask.physicsTrackArea];
          final currentSelect = state.selectedVertexIndex;
          if (currentSelect != null && currentSelect >= 0 && currentSelect < newVertices.length) {
            newVertices.insertAll(currentSelect + 1, arcPoints);
            state = state.copyWith(
              selectedVertexIndex: () => currentSelect + arcPoints.length,
            );
          } else {
            newVertices.addAll(arcPoints);
            state = state.copyWith(
              selectedVertexIndex: () => newVertices.length - 1,
            );
          }

          final updated = mask.copyWith(physicsTrackArea: newVertices);
          _updateMask(maskIndex, updated);
          state = state.copyWith(curveDraftPoints: const []);
        }
      } else {
        final newVertices = [...mask.physicsTrackArea];
        final currentSelect = state.selectedVertexIndex;
        if (currentSelect != null && currentSelect >= 0 && currentSelect < newVertices.length) {
          newVertices.insert(currentSelect + 1, clickPt);
          state = state.copyWith(
            selectedVertexIndex: () => currentSelect + 1,
          );
        } else {
          newVertices.add(clickPt);
          state = state.copyWith(
            selectedVertexIndex: () => newVertices.length - 1,
          );
        }

        final updated = mask.copyWith(physicsTrackArea: newVertices);
        _updateMask(maskIndex, updated);
      }
    }
  }

  void undoPhysicsAreaVertex() {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    if (mask.physicsTrackArea.isEmpty) return;

    final newVertices = [...mask.physicsTrackArea]..removeLast();
    int? nextSelect;
    if (newVertices.isNotEmpty) {
      nextSelect = newVertices.length - 1;
    }
    state = state.copyWith(
      selectedVertexIndex: () => nextSelect,
      curveDraftPoints: const [],
    );
    _updateMask(maskIndex, mask.copyWith(physicsTrackArea: newVertices));
  }

  void clearPhysicsArea() {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    state = state.copyWith(
      selectedVertexIndex: () => null,
      curveDraftPoints: const [],
    );
    _updateMask(maskIndex, mask.copyWith(physicsTrackArea: const []));
  }

  void closePhysicsArea() {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    final vertices = mask.physicsTrackArea;
    if (vertices.isNotEmpty && (vertices.length < 3 || !isSimplePolygon(vertices))) {
      state = state.copyWith(
        statusMessage: () => 'Invalid area! Polygon has self-intersections or too few vertices.',
      );
      return;
    }
    state = state.copyWith(
      selectedIndex: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveDraftPoints: const [],
    );
  }

  void cancelPhysicsArea() {
    final maskIndex = state.selectedIndex;
    if (maskIndex != null) {
      final mask = state.masks[maskIndex];
      _updateMask(maskIndex, mask.copyWith(physicsTrackArea: const []));
    }
    state = state.copyWith(
      selectedIndex: () => null,
      selectedVertexIndex: () => null,
      physicsAreaHoverPos: () => null,
      curveDraftPoints: const [],
    );
  }

  void resetPhysicsAreaToBoundingBox() {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    final w = mask.widthCells * GridConstants.cellSize;
    final h = mask.heightCells * GridConstants.cellSize;

    final newVertices = [
      const Vec2(0, 0),
      Vec2(w, 0),
      Vec2(w, h),
      Vec2(0, h),
    ];

    state = state.copyWith(
      selectedVertexIndex: () => null,
      curveDraftPoints: const [],
    );
    _updateMask(maskIndex, mask.copyWith(physicsTrackArea: newVertices));
  }

  void removePhysicsAreaVertex(int vertexIndex) {
    final maskIndex = state.selectedIndex;
    if (maskIndex == null) return;
    final mask = state.masks[maskIndex];
    if (vertexIndex < 0 || vertexIndex >= mask.physicsTrackArea.length) return;
    final newVertices = [...mask.physicsTrackArea]..removeAt(vertexIndex);
    state = state.copyWith(
      selectedVertexIndex: () => null,
      curveDraftPoints: const [],
    );
    _updateMask(maskIndex, mask.copyWith(physicsTrackArea: newVertices));
  }
}

final assetDefinerProvider =
    NotifierProvider<AssetDefinerNotifier, AssetDefinerState>(
        AssetDefinerNotifier.new);

bool isSimplePolygon(List<Vec2> vertices) {
  if (vertices.isEmpty) return true;
  if (vertices.length < 3) return false;

  final n = vertices.length;
  for (var i = 0; i < n; i++) {
    final p1 = vertices[i];
    final q1 = vertices[(i + 1) % n];

    for (var j = i + 1; j < n; j++) {
      final p2 = vertices[j];
      final q2 = vertices[(j + 1) % n];

      if (_segmentsIntersect(p1, q1, p2, q2)) {
        return false;
      }
    }
  }
  return true;
}

bool _segmentsIntersect(Vec2 p1, Vec2 q1, Vec2 p2, Vec2 q2) {
  final bool sharesVertex = (p1 == p2 || p1 == q2 || q1 == p2 || q1 == q2);

  int o1 = _orientation(p1, q1, p2);
  int o2 = _orientation(p1, q1, q2);
  int o3 = _orientation(p2, q2, p1);
  int o4 = _orientation(p2, q2, q1);

  if (o1 != o2 && o3 != o4) {
    if (sharesVertex) {
      return false;
    }
    return true;
  }

  if (sharesVertex) {
    if (q1 == p2) {
      if (o3 == 0 && _onSegmentExclusive(p2, p1, q2)) return true;
      if (o2 == 0 && _onSegmentExclusive(p1, q2, q1)) return true;
    } else if (p1 == p2) {
      if (o4 == 0 && _onSegmentExclusive(p2, q1, q2)) return true;
      if (o2 == 0 && _onSegmentExclusive(p1, q2, q1)) return true;
    } else if (q1 == q2) {
      if (o3 == 0 && _onSegmentExclusive(p2, p1, q2)) return true;
      if (o1 == 0 && _onSegmentExclusive(p1, p2, q1)) return true;
    } else if (p1 == q2) {
      if (o4 == 0 && _onSegmentExclusive(p2, q1, q2)) return true;
      if (o1 == 0 && _onSegmentExclusive(p1, p2, q1)) return true;
    }
    return false;
  }

  if (o1 == 0 && _onSegment(p1, p2, q1)) return true;
  if (o2 == 0 && _onSegment(p1, q2, q1)) return true;
  if (o3 == 0 && _onSegment(p2, p1, q2)) return true;
  if (o4 == 0 && _onSegment(p2, q1, q2)) return true;

  return false;
}

int _orientation(Vec2 p, Vec2 q, Vec2 r) {
  final val = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
  if (val == 0) return 0;
  return (val > 0) ? 1 : 2;
}

bool _onSegment(Vec2 p, Vec2 r, Vec2 q) {
  if (r.x <= math.max(p.x, q.x) && r.x >= math.min(p.x, q.x) &&
      r.y <= math.max(p.y, q.y) && r.y >= math.min(p.y, q.y)) {
    return true;
  }
  return false;
}

bool _onSegmentExclusive(Vec2 p, Vec2 r, Vec2 q) {
  if (r == p || r == q) return false;
  return r.x <= math.max(p.x, q.x) && r.x >= math.min(p.x, q.x) &&
      r.y <= math.max(p.y, q.y) && r.y >= math.min(p.y, q.y);
}
