import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../logic/pal_file.dart';
import '../logic/pixel_ops.dart';
import '../models/block_def.dart';
import '../models/pixel_document.dart';
import 'app_providers.dart';
import 'asset_definer_providers.dart';

/// Tools of the pixel editor toolbar.
enum PixelTool {
  pencil('Pencil'),
  eraser('Eraser'),
  line('Line'),
  rect('Rectangle'),
  ellipse('Ellipse'),
  fill('Fill / Replace'),
  eyedropper('Eyedropper'),
  selectRect('Select Rectangle'),
  lasso('Lasso'),
  wand('Magic Wand'),
  move('Move / Transform');

  const PixelTool(this.label);
  final String label;
}

enum ShapeInteractionMode { drag, planned }

const _minCanvasSide = 1;
const _maxCanvasSide = 1024;

/// Session-wide Pixel Editor preferences shared by every document tab. These
/// affect editing behavior or presentation, not the saved pixel document.
class PixelEditorPreferences {
  const PixelEditorPreferences({
    this.brushSize = 1,
    this.fillTolerance = 0,
    this.fillContiguous = true,
    this.fillShadeEnabled = false,
    this.fillShadeStrength = 12,
    this.symmetry = SymmetryMode.none,
    this.showPixelGrid = true,
    this.showCellGrid = true,
    this.shapeMode = ShapeInteractionMode.drag,
  });

  final int brushSize;
  final int fillTolerance;
  final bool fillContiguous;
  final bool fillShadeEnabled;
  final int fillShadeStrength;
  final SymmetryMode symmetry;
  final bool showPixelGrid;
  final bool showCellGrid;
  final ShapeInteractionMode shapeMode;

  PixelEditorPreferences copyWith({
    int? brushSize,
    int? fillTolerance,
    bool? fillContiguous,
    bool? fillShadeEnabled,
    int? fillShadeStrength,
    SymmetryMode? symmetry,
    bool? showPixelGrid,
    bool? showCellGrid,
    ShapeInteractionMode? shapeMode,
  }) => PixelEditorPreferences(
    brushSize: brushSize ?? this.brushSize,
    fillTolerance: fillTolerance ?? this.fillTolerance,
    fillContiguous: fillContiguous ?? this.fillContiguous,
    fillShadeEnabled: fillShadeEnabled ?? this.fillShadeEnabled,
    fillShadeStrength: fillShadeStrength ?? this.fillShadeStrength,
    symmetry: symmetry ?? this.symmetry,
    showPixelGrid: showPixelGrid ?? this.showPixelGrid,
    showCellGrid: showCellGrid ?? this.showCellGrid,
    shapeMode: shapeMode ?? this.shapeMode,
  );
}

class PixelEditorPreferencesNotifier extends Notifier<PixelEditorPreferences> {
  @override
  PixelEditorPreferences build() => const PixelEditorPreferences();

  void setBrushSize(int size) =>
      state = state.copyWith(brushSize: size.clamp(1, 32));

  void setFillTolerance(int tolerance) =>
      state = state.copyWith(fillTolerance: tolerance.clamp(0, 255));

  void setFillContiguous(bool contiguous) =>
      state = state.copyWith(fillContiguous: contiguous);

  void setFillShadeEnabled(bool enabled) =>
      state = state.copyWith(fillShadeEnabled: enabled);

  void setFillShadeStrength(int strength) =>
      state = state.copyWith(fillShadeStrength: strength.clamp(1, 32));

  void setSymmetry(SymmetryMode mode) => state = state.copyWith(symmetry: mode);

  void togglePixelGrid() =>
      state = state.copyWith(showPixelGrid: !state.showPixelGrid);

  void toggleCellGrid() =>
      state = state.copyWith(showCellGrid: !state.showCellGrid);

  void setShapeMode(ShapeInteractionMode mode) =>
      state = state.copyWith(shapeMode: mode);
}

final pixelEditorPreferencesProvider =
    NotifierProvider<PixelEditorPreferencesNotifier, PixelEditorPreferences>(
      PixelEditorPreferencesNotifier.new,
    );

class PixelClipboardData {
  PixelClipboardData({
    required Uint32List pixels,
    required this.width,
    required this.height,
  }) : pixels = Uint32List.fromList(pixels);

  final Uint32List pixels;
  final int width;
  final int height;
}

class PixelClipboardNotifier extends Notifier<PixelClipboardData?> {
  @override
  PixelClipboardData? build() => null;

  void setPixels(Uint32List pixels, int width, int height) {
    state = PixelClipboardData(pixels: pixels, width: width, height: height);
  }
}

/// Keeps pixel data available between editor tabs while also mirroring it to
/// the system clipboard for interoperability outside the app.
final pixelClipboardProvider =
    NotifierProvider<PixelClipboardNotifier, PixelClipboardData?>(
      PixelClipboardNotifier.new,
    );

/// DawnBringer 32, a common general-purpose pixel-art palette; the default
/// palette for new sessions.
const defaultPixelPalette = <int>[
  0xff000000,
  0xff222034,
  0xff45283c,
  0xff663931,
  0xff8f563b,
  0xffdf7126,
  0xffd9a066,
  0xffeec39a,
  0xfffbf236,
  0xff99e550,
  0xff6abe30,
  0xff37946e,
  0xff4b692f,
  0xff524b24,
  0xff323c39,
  0xff3f3f74,
  0xff306082,
  0xff5b6ee1,
  0xff639bff,
  0xff5fcde4,
  0xffcbdbfc,
  0xffffffff,
  0xff9badb7,
  0xff847e87,
  0xff696a6a,
  0xff595652,
  0xff76428a,
  0xffac3232,
  0xffd95763,
  0xffd77bba,
  0xff8f974a,
  0xff8a6f30,
];

/// Selection pixels lifted off the layer, movable and scalable before being
/// stamped back down. [original] keeps the pixels as lifted so repeated
/// nearest-neighbor scaling always resamples from the source (no compounding
/// loss).
class FloatingSelection {
  const FloatingSelection({
    required this.pixels,
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
    required this.original,
    required this.originalWidth,
    required this.originalHeight,
  });

  final Uint32List pixels;
  final int width;
  final int height;
  final int offsetX;
  final int offsetY;
  final Uint32List original;
  final int originalWidth;
  final int originalHeight;

  FloatingSelection copyWith({
    Uint32List? pixels,
    int? width,
    int? height,
    int? offsetX,
    int? offsetY,
    Uint32List? original,
    int? originalWidth,
    int? originalHeight,
  }) => FloatingSelection(
    pixels: pixels ?? this.pixels,
    width: width ?? this.width,
    height: height ?? this.height,
    offsetX: offsetX ?? this.offsetX,
    offsetY: offsetY ?? this.offsetY,
    original: original ?? this.original,
    originalWidth: originalWidth ?? this.originalWidth,
    originalHeight: originalHeight ?? this.originalHeight,
  );
}

/// The in-progress rectangle of a Select Rectangle drag, in pixel coords.
class SelectDraft {
  const SelectDraft(this.x0, this.y0, this.x1, this.y1);
  final int x0, y0, x1, y1;
}

/// Adjustable inclusive bounds for rectangle/ellipse planned mode.
class ShapePlan {
  const ShapePlan({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;

  ShapePlan copyWith({int? left, int? top, int? right, int? bottom}) =>
      ShapePlan(
        left: left ?? this.left,
        top: top ?? this.top,
        right: right ?? this.right,
        bottom: bottom ?? this.bottom,
      );
}

/// The Asset Definer source updated by an embedded Pixel Editor tab.
class AssetPixelTarget {
  const AssetPixelTarget({required this.category, this.decorationIndex});

  final BlockCategory category;
  final int? decorationIndex;
}

class _Snapshot {
  _Snapshot(this.document, this.selection);
  final PixelDocument document;
  final Uint8List? selection;
}

class PixelEditorState {
  const PixelEditorState({
    required this.document,
    this.tool = PixelTool.pencil,
    this.color = 0xff000000,
    this.palette = defaultPixelPalette,
    this.imageColors = const [],
    this.canvasImage,
    this.floatingImage,
    this.revision = 0,
    this.selection,
    this.floating,
    this.selectDraft,
    this.lassoDraft,
    this.shapePlan,
    this.isDirty = false,
    this.filePath,
    this.displayName = 'Untitled Pixel',
    this.assetTarget,
    this.statusMessage,
    this.canUndo = false,
    this.canRedo = false,
  });

  final PixelDocument document;
  final PixelTool tool;

  /// Active drawing color, ARGB.
  final int color;

  /// The indexed palette, ARGB entries.
  final List<int> palette;

  /// Pick-only colors extracted from an imported/current image.
  final List<int> imageColors;

  /// Composited document, rebuilt after every change; what the canvas draws.
  final ui.Image? canvasImage;

  /// The floating selection's pixels as an image, drawn above [canvasImage].
  final ui.Image? floatingImage;

  /// Bumped on every visual change so the painter always repaints, even when
  /// the image object arrives asynchronously.
  final int revision;

  /// Active selection mask (document-sized, non-zero = selected), or null
  /// when nothing is selected.
  final Uint8List? selection;

  final FloatingSelection? floating;
  final SelectDraft? selectDraft;

  /// Lasso polygon vertices collected during the drag, in pixel coords.
  final List<(double, double)>? lassoDraft;
  final ShapePlan? shapePlan;

  final bool isDirty;
  final String? filePath;
  final String displayName;
  final AssetPixelTarget? assetTarget;
  final String? statusMessage;
  final bool canUndo;
  final bool canRedo;

  PixelEditorState copyWith({
    PixelDocument? document,
    PixelTool? tool,
    int? color,
    List<int>? palette,
    List<int>? imageColors,
    ui.Image? Function()? canvasImage,
    ui.Image? Function()? floatingImage,
    int? revision,
    Uint8List? Function()? selection,
    FloatingSelection? Function()? floating,
    SelectDraft? Function()? selectDraft,
    List<(double, double)>? Function()? lassoDraft,
    ShapePlan? Function()? shapePlan,
    bool? isDirty,
    String? Function()? filePath,
    String? displayName,
    AssetPixelTarget? Function()? assetTarget,
    String? Function()? statusMessage,
    bool? canUndo,
    bool? canRedo,
  }) => PixelEditorState(
    document: document ?? this.document,
    tool: tool ?? this.tool,
    color: color ?? this.color,
    palette: palette ?? this.palette,
    imageColors: imageColors ?? this.imageColors,
    canvasImage: canvasImage != null ? canvasImage() : this.canvasImage,
    floatingImage: floatingImage != null ? floatingImage() : this.floatingImage,
    revision: revision ?? this.revision,
    selection: selection != null ? selection() : this.selection,
    floating: floating != null ? floating() : this.floating,
    selectDraft: selectDraft != null ? selectDraft() : this.selectDraft,
    lassoDraft: lassoDraft != null ? lassoDraft() : this.lassoDraft,
    shapePlan: shapePlan != null ? shapePlan() : this.shapePlan,
    isDirty: isDirty ?? this.isDirty,
    filePath: filePath != null ? filePath() : this.filePath,
    displayName: displayName ?? this.displayName,
    assetTarget: assetTarget != null ? assetTarget() : this.assetTarget,
    statusMessage: statusMessage != null ? statusMessage() : this.statusMessage,
    canUndo: canUndo ?? this.canUndo,
    canRedo: canRedo ?? this.canRedo,
  );
}

class PixelEditorNotifier extends Notifier<PixelEditorState> {
  // Undo history. Snapshots are full document clones; at the tool's canvas
  // sizes (<= 1024 square) this is simple and fast. Capped so marathon
  // sessions cannot exhaust memory.
  static const _historyCap = 256;
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];

  // Stroke-in-progress bookkeeping.
  Uint32List? _strokeBase;
  (int, int)? _shapeAnchor;
  (int, int)? _lastStrokePoint;

  // Move-tool drag bookkeeping.
  (int, int)? _moveGrabOffset;
  int? _scaleCorner; // 0 TL, 1 TR, 2 BL, 3 BR
  int? _shapePlanEdge; // 0 left, 1 top, 2 right, 3 bottom
  bool _selectionAdditive = false;
  bool? _dirtyBeforeFloating;

  int _imageGeneration = 0;
  int _floatingGeneration = 0;
  Timer? _rebuildTimer;
  PixelDocument? _pendingRebuildDocument;
  ui.Image? _ownedCanvasImage;
  ui.Image? _ownedFloatingImage;
  bool _disposed = false;

  @override
  PixelEditorState build() {
    ref.onDispose(() {
      _disposed = true;
      _rebuildTimer?.cancel();
      _pendingRebuildDocument = null;
      _ownedCanvasImage?.dispose();
      _ownedFloatingImage?.dispose();
    });
    final initialState = PixelEditorState(
      document: PixelDocument.blank(128, 128),
    );
    _scheduleRebuild(initialState.document);
    return initialState;
  }

  PixelLayer get _layer => state.document.layers.first;
  int get _w => state.document.width;
  int get _h => state.document.height;
  PixelEditorPreferences get _preferences =>
      ref.read(pixelEditorPreferencesProvider);

  // --- Image cache ----------------------------------------------------------

  /// Rebuilds the composited canvas image asynchronously. A generation
  /// counter drops stale results when edits outpace decoding. Pointer updates
  /// are coalesced to one rebuild per display-frame interval so a fast stroke
  /// does not repeatedly composite and decode the same canvas state.
  void _scheduleRebuild(PixelDocument document) {
    _pendingRebuildDocument = document;
    if (_rebuildTimer != null) return;
    _rebuildTimer = Timer(const Duration(milliseconds: 16), () {
      _rebuildTimer = null;
      final pending = _pendingRebuildDocument;
      _pendingRebuildDocument = null;
      if (_disposed || pending == null) return;
      _decodeCanvasImage(pending);
    });
  }

  void _decodeCanvasImage(PixelDocument document) {
    final generation = ++_imageGeneration;
    final bytes = pixelsToRgbaBytes(document.composite());
    ui.decodeImageFromPixels(
      bytes,
      document.width,
      document.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (_disposed || generation != _imageGeneration) {
          image.dispose();
          return;
        }
        _ownedCanvasImage?.dispose();
        _ownedCanvasImage = image;
        state = state.copyWith(
          canvasImage: () => image,
          revision: state.revision + 1,
        );
      },
    );
  }

  void _scheduleFloatingRebuild(FloatingSelection? floating) {
    final generation = ++_floatingGeneration;
    if (floating == null) {
      _ownedFloatingImage?.dispose();
      _ownedFloatingImage = null;
      state = state.copyWith(
        floatingImage: () => null,
        revision: state.revision + 1,
      );
      return;
    }
    ui.decodeImageFromPixels(
      pixelsToRgbaBytes(floating.pixels),
      floating.width,
      floating.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (_disposed || generation != _floatingGeneration) {
          image.dispose();
          return;
        }
        _ownedFloatingImage?.dispose();
        _ownedFloatingImage = image;
        state = state.copyWith(
          floatingImage: () => image,
          revision: state.revision + 1,
        );
      },
    );
  }

  void _touch({bool dirty = true, String? status}) {
    state = state.copyWith(
      revision: state.revision + 1,
      isDirty: dirty ? true : null,
      statusMessage: status == null ? null : () => status,
    );
    _scheduleRebuild(state.document);
  }

  // --- History --------------------------------------------------------------

  void _pushUndo() {
    _undoStack.add(
      _Snapshot(
        state.document.clone(),
        state.selection == null ? null : Uint8List.fromList(state.selection!),
      ),
    );
    if (_undoStack.length > _historyCap) _undoStack.removeAt(0);
    _redoStack.clear();
    state = state.copyWith(canUndo: true, canRedo: false);
  }

  void undo() {
    if (_strokeBase != null || state.lassoDraft != null) return;
    if (_undoStack.isEmpty) return;
    _commitFloating(silent: true);
    // _commitFloating may itself have pushed nothing; the floating case is
    // committed as part of the state being undone.
    if (_undoStack.isEmpty) return;
    _redoStack.add(
      _Snapshot(
        state.document.clone(),
        state.selection == null ? null : Uint8List.fromList(state.selection!),
      ),
    );
    final snapshot = _undoStack.removeLast();
    state = state.copyWith(
      document: snapshot.document,
      selection: () => snapshot.selection,
      canUndo: _undoStack.isNotEmpty,
      canRedo: true,
      statusMessage: () => 'Undo',
    );
    _touch(dirty: true);
  }

  void redo() {
    if (_strokeBase != null || state.lassoDraft != null) return;
    if (_redoStack.isEmpty) return;
    _undoStack.add(
      _Snapshot(
        state.document.clone(),
        state.selection == null ? null : Uint8List.fromList(state.selection!),
      ),
    );
    final snapshot = _redoStack.removeLast();
    state = state.copyWith(
      document: snapshot.document,
      selection: () => snapshot.selection,
      canUndo: true,
      canRedo: _redoStack.isNotEmpty,
      statusMessage: () => 'Redo',
    );
    _touch(dirty: true);
  }

  // --- Settings -------------------------------------------------------------

  bool _isSelectionTool(PixelTool tool) =>
      tool == PixelTool.selectRect ||
      tool == PixelTool.lasso ||
      tool == PixelTool.wand ||
      tool == PixelTool.move;

  void setTool(PixelTool tool) {
    final keepsSelection = _isSelectionTool(tool);
    if (!keepsSelection) _commitFloating();
    state = state.copyWith(
      tool: tool,
      selection: keepsSelection ? null : () => null,
      selectDraft: () => null,
      lassoDraft: () => null,
      shapePlan: () => null,
      statusMessage: () => tool.label,
    );
    _shapePlanEdge = null;
  }

  void setColor(int argb) => state = state.copyWith(color: argb);

  void setBrushSize(int size) =>
      ref.read(pixelEditorPreferencesProvider.notifier).setBrushSize(size);

  void setFillTolerance(int tolerance) => ref
      .read(pixelEditorPreferencesProvider.notifier)
      .setFillTolerance(tolerance);

  void setFillContiguous(bool contiguous) => ref
      .read(pixelEditorPreferencesProvider.notifier)
      .setFillContiguous(contiguous);

  void setFillShadeEnabled(bool enabled) => ref
      .read(pixelEditorPreferencesProvider.notifier)
      .setFillShadeEnabled(enabled);

  void setFillShadeStrength(int strength) => ref
      .read(pixelEditorPreferencesProvider.notifier)
      .setFillShadeStrength(strength);

  void setSymmetry(SymmetryMode mode) {
    if (_preferences.symmetry == mode) return;
    ref.read(pixelEditorPreferencesProvider.notifier).setSymmetry(mode);
    state = state.copyWith(statusMessage: () => 'Symmetry: ${mode.jsonValue}');
  }

  void togglePixelGrid() =>
      ref.read(pixelEditorPreferencesProvider.notifier).togglePixelGrid();

  void toggleCellGrid() =>
      ref.read(pixelEditorPreferencesProvider.notifier).toggleCellGrid();

  void setShapeMode(ShapeInteractionMode mode) {
    ref.read(pixelEditorPreferencesProvider.notifier).setShapeMode(mode);
    if (mode == ShapeInteractionMode.drag) cancelShapePlan();
  }

  // --- Palette --------------------------------------------------------------

  void addCurrentColorToPalette() {
    if (state.palette.contains(state.color)) {
      state = state.copyWith(
        statusMessage: () => 'Color already in the palette',
      );
      return;
    }
    state = state.copyWith(
      palette: [...state.palette, state.color],
      isDirty: true,
    );
  }

  void removePaletteColor(int index) {
    if (index < 0 || index >= state.palette.length) return;
    state = state.copyWith(
      palette: [...state.palette]..removeAt(index),
      isDirty: true,
    );
  }

  Future<void> importPalette() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import palette (.pal)',
      type: FileType.custom,
      allowedExtensions: ['pal'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    try {
      final palette = decodeJascPal(utf8.decode(bytes, allowMalformed: true));
      state = state.copyWith(
        palette: palette,
        isDirty: true,
        statusMessage: () =>
            'Imported ${palette.length} colors from ${result!.files.single.name}',
      );
    } on FormatException catch (e) {
      state = state.copyWith(
        statusMessage: () => 'Palette import failed: ${e.message}',
      );
    }
  }

  Future<void> exportPalette() async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export palette (.pal)',
      fileName: 'palette.pal',
      type: FileType.custom,
      allowedExtensions: ['pal'],
      bytes: Uint8List.fromList(utf8.encode(encodeJascPal(state.palette))),
    );
    if (path != null) {
      state = state.copyWith(statusMessage: () => 'Palette saved to $path');
    }
  }

  // --- Selection ------------------------------------------------------------

  void selectAll() {
    _commitFloating();
    state = state.copyWith(
      selection: () => Uint8List(_w * _h)..fillRange(0, _w * _h, 1),
      statusMessage: () => 'All selected',
    );
  }

  void clearSelection() {
    _commitFloating();
    state = state.copyWith(selection: () => null);
  }

  /// Esc: drop a floating selection back where it was lifted from, else
  /// deselect.
  void cancelFloatingOrSelection() {
    if (state.shapePlan != null) {
      cancelShapePlan();
      return;
    }
    if (state.floating != null) {
      // The lift pushed an undo snapshot; restoring it is the cancel.
      final snapshot = _undoStack.removeLast();
      final wasDirty = _dirtyBeforeFloating ?? state.isDirty;
      _dirtyBeforeFloating = null;
      state = state.copyWith(
        document: snapshot.document,
        selection: () => snapshot.selection,
        floating: () => null,
        isDirty: wasDirty,
        canUndo: _undoStack.isNotEmpty,
        statusMessage: () => 'Move cancelled',
      );
      _scheduleFloatingRebuild(null);
      _touch(dirty: false);
      return;
    }
    if (state.selection != null) clearSelection();
  }

  Future<void> copySelection() async {
    Uint32List pixels;
    int width;
    int height;
    final floating = state.floating;
    if (floating != null) {
      pixels = Uint32List.fromList(floating.pixels);
      width = floating.width;
      height = floating.height;
    } else {
      final selection = state.selection;
      if (selection == null) {
        state = state.copyWith(statusMessage: () => 'Nothing selected');
        return;
      }
      final bounds = maskBounds(selection, _w, _h);
      if (bounds == null) return;
      final copy = Uint32List.fromList(_layer.pixels);
      pixels = liftMaskedPixels(copy, _w, _h, selection, bounds);
      width = bounds.$3 - bounds.$1 + 1;
      height = bounds.$4 - bounds.$2 + 1;
    }
    final payload = jsonEncode({
      'format': 'race_gametool.pixel_clipboard',
      'version': 1,
      'width': width,
      'height': height,
      'pixels': base64Encode(pixelsToRgbaBytes(pixels)),
    });
    ref.read(pixelClipboardProvider.notifier).setPixels(pixels, width, height);
    await Clipboard.setData(ClipboardData(text: payload));
    state = state.copyWith(statusMessage: () => 'Copied selection');
  }

  Future<void> cutSelection() async {
    if (state.selection == null && state.floating == null) return;
    await copySelection();
    deleteSelectionContents();
    state = state.copyWith(statusMessage: () => 'Cut selection');
  }

  Future<void> pasteSelection() async {
    try {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      PixelClipboardData? clipboard;
      if (text != null) {
        final payload = jsonDecode(text);
        if (payload is! Map<String, dynamic> ||
            payload['format'] != 'race_gametool.pixel_clipboard' ||
            payload['version'] != 1) {
          throw const FormatException('not pixel data');
        }
        final width = payload['width'];
        final height = payload['height'];
        final encoded = payload['pixels'];
        if (width is! int ||
            height is! int ||
            width <= 0 ||
            height <= 0 ||
            width > _maxCanvasSide ||
            height > _maxCanvasSide ||
            encoded is! String) {
          throw const FormatException('invalid pixel clipboard');
        }
        final pixels = rgbaBytesToPixels(base64Decode(encoded));
        if (pixels.length != width * height) {
          throw const FormatException('pixel clipboard size mismatch');
        }
        clipboard = PixelClipboardData(
          pixels: pixels,
          width: width,
          height: height,
        );
      } else {
        clipboard = ref.read(pixelClipboardProvider);
      }
      if (clipboard == null) return;

      _commitFloating(silent: true);
      _dirtyBeforeFloating = state.isDirty;
      _pushUndo();
      final floating = FloatingSelection(
        pixels: Uint32List.fromList(clipboard.pixels),
        width: clipboard.width,
        height: clipboard.height,
        offsetX: (_w - clipboard.width) ~/ 2,
        offsetY: (_h - clipboard.height) ~/ 2,
        original: Uint32List.fromList(clipboard.pixels),
        originalWidth: clipboard.width,
        originalHeight: clipboard.height,
      );
      state = state.copyWith(
        tool: PixelTool.selectRect,
        selection: () => null,
        floating: () => floating,
        shapePlan: () => null,
        isDirty: true,
        statusMessage: () => 'Pasted selection',
      );
      _scheduleFloatingRebuild(floating);
      _touch();
    } on Object {
      state = state.copyWith(
        statusMessage: () => 'Clipboard does not contain pixel data',
      );
    }
  }

  /// Deletes the selected pixels (or drops the floating selection).
  void deleteSelectionContents() {
    if (state.floating != null) {
      // Pixels were already lifted off the layer; dropping the float deletes
      // them. The lift's undo snapshot restores everything.
      state = state.copyWith(
        floating: () => null,
        selection: () => null,
        statusMessage: () => 'Selection deleted',
      );
      _dirtyBeforeFloating = null;
      _scheduleFloatingRebuild(null);
      _touch();
      return;
    }
    final selection = state.selection;
    if (selection == null) return;
    _pushUndo();
    final pixels = _layer.pixels;
    for (var i = 0; i < pixels.length; i++) {
      if (selection[i] != 0) pixels[i] = 0;
    }
    state = state.copyWith(selection: () => null);
    _touch(status: 'Selection deleted');
  }

  // --- Floating selection (move/transform) -----------------------------------

  void _liftSelection() {
    final selection = state.selection;
    if (selection == null) return;
    final bounds = maskBounds(selection, _w, _h);
    if (bounds == null) return;
    _dirtyBeforeFloating = state.isDirty;
    _pushUndo();
    final lifted = liftMaskedPixels(_layer.pixels, _w, _h, selection, bounds);
    final (left, top, right, bottom) = bounds;
    final fw = right - left + 1, fh = bottom - top + 1;
    final floating = FloatingSelection(
      pixels: lifted,
      width: fw,
      height: fh,
      offsetX: left,
      offsetY: top,
      original: Uint32List.fromList(lifted),
      originalWidth: fw,
      originalHeight: fh,
    );
    state = state.copyWith(floating: () => floating, selection: () => null);
    _scheduleFloatingRebuild(floating);
    _touch();
  }

  /// Stamps the floating pixels down and re-derives the selection from their
  /// footprint, so the moved region stays selected.
  void _commitFloating({bool silent = false}) {
    final floating = state.floating;
    if (floating == null) return;
    blit(
      _layer.pixels,
      _w,
      _h,
      floating.pixels,
      floating.width,
      floating.height,
      floating.offsetX,
      floating.offsetY,
    );
    final selection = Uint8List(_w * _h);
    for (var y = 0; y < floating.height; y++) {
      final ty = floating.offsetY + y;
      if (ty < 0 || ty >= _h) continue;
      for (var x = 0; x < floating.width; x++) {
        final tx = floating.offsetX + x;
        if (tx < 0 || tx >= _w) continue;
        if ((floating.pixels[y * floating.width + x] >>> 24) != 0) {
          selection[ty * _w + tx] = 1;
        }
      }
    }
    state = state.copyWith(
      floating: () => null,
      selection: () => selection,
      statusMessage: silent ? null : () => 'Selection placed',
    );
    _dirtyBeforeFloating = null;
    _shapePlanEdge = null;
    _selectionAdditive = false;
    _scheduleFloatingRebuild(null);
    _touch();
  }

  /// The canvas widget hit-tests scale handles (their size is zoom
  /// dependent) and reports the grabbed corner here before the drag.
  void startHandleScale(int corner) {
    if (state.floating == null) return;
    _scaleCorner = corner;
  }

  void _transformFloating(
    FloatingSelection Function(FloatingSelection) transform,
  ) {
    var floating = state.floating;
    if (floating == null) {
      if (state.selection == null) return;
      _liftSelection();
      floating = state.floating;
      if (floating == null) return;
    }
    final next = transform(floating);
    state = state.copyWith(floating: () => next, isDirty: true);
    _scheduleFloatingRebuild(next);
    state = state.copyWith(revision: state.revision + 1);
  }

  /// Rotates the floating selection (lifting the selection if needed), or
  /// with no selection the whole canvas.
  void rotate90Action({required bool clockwise}) {
    if (state.floating != null || state.selection != null) {
      _transformFloating((f) {
        final pixels = rotate90(
          f.pixels,
          f.width,
          f.height,
          clockwise: clockwise,
        );
        final original = rotate90(
          f.original,
          f.originalWidth,
          f.originalHeight,
          clockwise: clockwise,
        );
        return f.copyWith(
          pixels: pixels,
          width: f.height,
          height: f.width,
          original: original,
          originalWidth: f.originalHeight,
          originalHeight: f.originalWidth,
        );
      });
      return;
    }
    _pushUndo();
    final doc = state.document;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
          pixels: rotate90(
            layer.pixels,
            doc.width,
            doc.height,
            clockwise: clockwise,
          ),
        ),
    ];
    state = state.copyWith(
      document: PixelDocument(
        width: doc.height,
        height: doc.width,
        layers: layers,
      ),
    );
    _touch(status: 'Canvas rotated');
  }

  /// Flips the floating selection (lifting if needed), or the whole canvas.
  void flipAction({required bool horizontal}) {
    if (state.floating != null || state.selection != null) {
      _transformFloating((f) {
        final pixels = Uint32List.fromList(f.pixels);
        final original = Uint32List.fromList(f.original);
        if (horizontal) {
          flipHorizontal(pixels, f.width, f.height);
          flipHorizontal(original, f.originalWidth, f.originalHeight);
        } else {
          flipVertical(pixels, f.width, f.height);
          flipVertical(original, f.originalWidth, f.originalHeight);
        }
        return f.copyWith(pixels: pixels, original: original);
      });
      return;
    }
    _pushUndo();
    for (final layer in state.document.layers) {
      if (horizontal) {
        flipHorizontal(layer.pixels, _w, _h);
      } else {
        flipVertical(layer.pixels, _w, _h);
      }
    }
    _touch(status: 'Canvas flipped');
  }

  // --- Canvas size ----------------------------------------------------------

  /// Anchor components are -1 (keep start edge), 0 (center), 1 (keep end).
  void resizeCanvasTo(
    int width,
    int height, {
    int anchorX = -1,
    int anchorY = -1,
  }) {
    final w = width.clamp(_minCanvasSide, _maxCanvasSide);
    final h = height.clamp(_minCanvasSide, _maxCanvasSide);
    if (w == _w && h == _h) return;
    _commitFloating(silent: true);
    _pushUndo();
    final doc = state.document;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
          pixels: resizeCanvas(
            layer.pixels,
            doc.width,
            doc.height,
            w,
            h,
            anchorX: anchorX,
            anchorY: anchorY,
          ),
        ),
    ];
    state = state.copyWith(
      document: PixelDocument(width: w, height: h, layers: layers),
      selection: () => null,
    );
    _touch(status: 'Canvas resized to $w x $h');
  }

  void cropToSelection() {
    final selection = state.selection;
    if (selection == null) return;
    final bounds = maskBounds(selection, _w, _h);
    if (bounds == null) return;
    _commitFloating(silent: true);
    _pushUndo();
    final doc = state.document;
    final (left, top, right, bottom) = bounds;
    final layers = [
      for (final layer in doc.layers)
        layer.copyWith(
          pixels: cropCanvas(layer.pixels, doc.width, doc.height, bounds),
        ),
    ];
    state = state.copyWith(
      document: PixelDocument(
        width: right - left + 1,
        height: bottom - top + 1,
        layers: layers,
      ),
      selection: () => null,
    );
    _touch(status: 'Cropped to selection');
  }

  // --- Drawing gestures -------------------------------------------------------

  bool get _isShapeTool =>
      state.tool == PixelTool.rect || state.tool == PixelTool.ellipse;

  (int, int) _shapeEndPoint(
    (int, int) anchor,
    (int, int) end, {
    required bool constrained,
  }) {
    if (!constrained) return end;
    final dx = end.$1 - anchor.$1;
    final dy = end.$2 - anchor.$2;
    final side = math.max(dx.abs(), dy.abs());
    return (
      anchor.$1 + (dx < 0 ? -side : side),
      anchor.$2 + (dy < 0 ? -side : side),
    );
  }

  ShapePlan _shapePlanFrom(
    (int, int) anchor,
    (int, int) end, {
    required bool constrained,
  }) {
    final adjusted = _shapeEndPoint(anchor, end, constrained: constrained);
    return ShapePlan(
      left: math.min(anchor.$1, adjusted.$1).clamp(0, _w - 1),
      top: math.min(anchor.$2, adjusted.$2).clamp(0, _h - 1),
      right: math.max(anchor.$1, adjusted.$1).clamp(0, _w - 1),
      bottom: math.max(anchor.$2, adjusted.$2).clamp(0, _h - 1),
    );
  }

  Uint8List _selectionResult(Uint8List next, {required bool additive}) {
    final previous = state.selection;
    if (!additive || previous == null) return next;
    final merged = Uint8List.fromList(previous);
    for (var i = 0; i < merged.length; i++) {
      if (next[i] != 0) merged[i] = 1;
    }
    return merged;
  }

  /// A marquee is an object-selection gesture: transparent padding inside the
  /// dragged area should not become part of the selection or its outline.
  Uint8List _opaqueSelection(Uint8List region) {
    final composite = state.document.composite();
    for (var i = 0; i < region.length; i++) {
      if ((composite[i] >>> 24) == 0) region[i] = 0;
    }
    return region;
  }

  void startShapePlanAdjustment(int edge) {
    if (state.shapePlan != null) _shapePlanEdge = edge.clamp(0, 3);
  }

  void confirmShapePlan() {
    final plan = state.shapePlan;
    if (plan == null || !_isShapeTool) return;
    _pushUndo();
    _paintShape((plan.left, plan.top), (plan.right, plan.bottom));
    state = state.copyWith(shapePlan: () => null);
    _shapePlanEdge = null;
    _touch(status: 'Shape committed');
  }

  void cancelShapePlan() {
    if (state.shapePlan == null) return;
    state = state.copyWith(
      shapePlan: () => null,
      revision: state.revision + 1,
      statusMessage: () => 'Shape cancelled',
    );
    _shapePlanEdge = null;
  }

  (int, int) _clampPoint(double x, double y) =>
      (x.floor().clamp(0, _w - 1), y.floor().clamp(0, _h - 1));

  bool _insideSelection(int x, int y) {
    final selection = state.selection;
    if (selection == null) return false;
    if (x < 0 || y < 0 || x >= _w || y >= _h) return false;
    return selection[y * _w + x] != 0;
  }

  bool _insideFloating(int x, int y) {
    final f = state.floating;
    if (f == null) return false;
    return x >= f.offsetX &&
        y >= f.offsetY &&
        x < f.offsetX + f.width &&
        y < f.offsetY + f.height;
  }

  /// Selection tools also move a selection directly. A distinct move tool is
  /// kept only for old shortcuts and existing saved workspace state.
  bool _startSelectionMove(int x, int y) {
    if (_scaleCorner != null) return true;
    final floating = state.floating;
    if (floating != null && _insideFloating(x, y)) {
      _moveGrabOffset = (x - floating.offsetX, y - floating.offsetY);
      return true;
    }
    if (!_insideSelection(x, y)) return false;
    _liftSelection();
    final lifted = state.floating;
    if (lifted != null) {
      _moveGrabOffset = (x - lifted.offsetX, y - lifted.offsetY);
      return true;
    }
    return false;
  }

  bool _updateSelectionMove(int x, int y) {
    final corner = _scaleCorner;
    if (corner != null) {
      _scaleFloatingTo(corner, x, y);
      return true;
    }
    final grab = _moveGrabOffset;
    final floating = state.floating;
    if (grab == null || floating == null) return false;
    state = state.copyWith(
      floating: () =>
          floating.copyWith(offsetX: x - grab.$1, offsetY: y - grab.$2),
      isDirty: true,
      revision: state.revision + 1,
    );
    return true;
  }

  bool _finishSelectionMove() {
    if (_moveGrabOffset == null && _scaleCorner == null) return false;
    _moveGrabOffset = null;
    _scaleCorner = null;
    return true;
  }

  /// Draws one brush segment (with symmetry) from [from] to [to] on the live
  /// layer buffer.
  void _paintSegment((int, int) from, (int, int) to, int color) {
    final preferences = _preferences;
    final fromPts = symmetryPoints(
      from.$1,
      from.$2,
      _w,
      _h,
      preferences.symmetry,
    );
    final toPts = symmetryPoints(to.$1, to.$2, _w, _h, preferences.symmetry);
    for (var i = 0; i < fromPts.length; i++) {
      drawLine(
        _layer.pixels,
        _w,
        _h,
        fromPts[i].$1,
        fromPts[i].$2,
        toPts[i].$1,
        toPts[i].$2,
        color,
        brushSize: preferences.brushSize,
        mask: state.selection,
      );
    }
  }

  void _paintShape((int, int) from, (int, int) to) {
    final preferences = _preferences;
    final fromPts = symmetryPoints(
      from.$1,
      from.$2,
      _w,
      _h,
      preferences.symmetry,
    );
    final toPts = symmetryPoints(to.$1, to.$2, _w, _h, preferences.symmetry);
    for (var i = 0; i < fromPts.length; i++) {
      final (x0, y0) = fromPts[i];
      final (x1, y1) = toPts[i];
      switch (state.tool) {
        case PixelTool.line:
          drawLine(
            _layer.pixels,
            _w,
            _h,
            x0,
            y0,
            x1,
            y1,
            state.color,
            brushSize: preferences.brushSize,
            mask: state.selection,
          );
        case PixelTool.rect:
          drawRectShape(
            _layer.pixels,
            _w,
            _h,
            x0,
            y0,
            x1,
            y1,
            state.color,
            brushSize: preferences.brushSize,
            mask: state.selection,
          );
        case PixelTool.ellipse:
          drawEllipseShape(
            _layer.pixels,
            _w,
            _h,
            x0,
            y0,
            x1,
            y1,
            state.color,
            brushSize: preferences.brushSize,
            mask: state.selection,
          );
        default:
          break;
      }
    }
  }

  void strokeStart(double px, double py, {bool additiveSelection = false}) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        _lastStrokePoint = (x, y);
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment((x, y), (x, y), color);
        _touch();
      case PixelTool.line:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        _shapeAnchor = (x, y);
        _paintShape((x, y), (x, y));
        _touch();
      case PixelTool.rect:
      case PixelTool.ellipse:
        if (_preferences.shapeMode == ShapeInteractionMode.planned) {
          if (_shapePlanEdge != null) return;
          _shapeAnchor = (x, y);
          state = state.copyWith(
            shapePlan: () => ShapePlan(left: x, top: y, right: x, bottom: y),
            revision: state.revision + 1,
          );
          return;
        }
        _strokeBase = Uint32List.fromList(_layer.pixels);
        _shapeAnchor = (x, y);
        _paintShape((x, y), (x, y));
        _touch();
      case PixelTool.selectRect:
        if (_startSelectionMove(x, y)) return;
        _commitFloating(silent: true);
        _selectionAdditive = additiveSelection;
        _shapeAnchor = (x, y);
        state = state.copyWith(
          selectDraft: () => SelectDraft(x, y, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.lasso:
        if (_startSelectionMove(x, y)) return;
        _commitFloating(silent: true);
        _selectionAdditive = additiveSelection;
        state = state.copyWith(
          lassoDraft: () => [(px, py)],
          revision: state.revision + 1,
        );
      case PixelTool.wand:
        if (_startSelectionMove(x, y)) return;
        _commitFloating(silent: true);
        _selectionAdditive = additiveSelection;
        _shapeAnchor = (x, y);
        state = state.copyWith(
          selectDraft: () => SelectDraft(x, y, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.move:
        if (!_startSelectionMove(x, y)) _commitFloating();
      case PixelTool.fill:
      case PixelTool.eyedropper:
        break; // tap-only tools
    }
  }

  void strokeUpdate(double px, double py, {bool constrainShape = false}) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        if (_strokeBase == null) return;
        final last = _lastStrokePoint ?? (x, y);
        if (last == (x, y)) return;
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment(last, (x, y), color);
        _lastStrokePoint = (x, y);
        _touch();
      case PixelTool.line:
        final base = _strokeBase;
        final anchor = _shapeAnchor;
        if (base == null || anchor == null) return;
        _layer.pixels.setAll(0, base);
        _paintShape(anchor, (x, y));
        _touch();
      case PixelTool.rect:
      case PixelTool.ellipse:
        if (_preferences.shapeMode == ShapeInteractionMode.planned) {
          final plan = state.shapePlan;
          if (plan == null) return;
          final edge = _shapePlanEdge;
          if (edge != null) {
            final next = switch (edge) {
              0 => plan.copyWith(left: x.clamp(0, plan.right)),
              1 => plan.copyWith(top: y.clamp(0, plan.bottom)),
              2 => plan.copyWith(right: x.clamp(plan.left, _w - 1)),
              _ => plan.copyWith(bottom: y.clamp(plan.top, _h - 1)),
            };
            state = state.copyWith(
              shapePlan: () => next,
              revision: state.revision + 1,
            );
            return;
          }
          final anchor = _shapeAnchor;
          if (anchor == null) return;
          state = state.copyWith(
            shapePlan: () =>
                _shapePlanFrom(anchor, (x, y), constrained: constrainShape),
            revision: state.revision + 1,
          );
          return;
        }
        final base = _strokeBase;
        final anchor = _shapeAnchor;
        if (base == null || anchor == null) return;
        _layer.pixels.setAll(0, base);
        _paintShape(
          anchor,
          _shapeEndPoint(anchor, (x, y), constrained: constrainShape),
        );
        _touch();
      case PixelTool.selectRect:
        if (_updateSelectionMove(x, y)) return;
        final anchor = _shapeAnchor;
        if (anchor == null) return;
        state = state.copyWith(
          selectDraft: () => SelectDraft(anchor.$1, anchor.$2, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.lasso:
        if (_updateSelectionMove(x, y)) return;
        final draft = state.lassoDraft;
        if (draft == null) return;
        state = state.copyWith(
          lassoDraft: () => [...draft, (px, py)],
          revision: state.revision + 1,
        );
      case PixelTool.wand:
        if (_updateSelectionMove(x, y)) return;
        final anchor = _shapeAnchor;
        if (anchor == null) return;
        state = state.copyWith(
          selectDraft: () => SelectDraft(anchor.$1, anchor.$2, x, y),
          revision: state.revision + 1,
        );
      case PixelTool.move:
        _updateSelectionMove(x, y);
      case PixelTool.fill:
      case PixelTool.eyedropper:
        break;
    }
  }

  void strokeEnd() {
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
      case PixelTool.line:
        _finishDrawnStroke();
      case PixelTool.rect:
      case PixelTool.ellipse:
        if (_preferences.shapeMode == ShapeInteractionMode.planned) {
          _shapeAnchor = null;
          _shapePlanEdge = null;
          state = state.copyWith(
            statusMessage: () => 'Adjust bounds, then confirm',
          );
          return;
        }
        _finishDrawnStroke();
      case PixelTool.selectRect:
        if (_finishSelectionMove()) return;
        final draft = state.selectDraft;
        _shapeAnchor = null;
        if (draft == null) return;
        final mask = _selectionResult(
          _opaqueSelection(
            rectMask(_w, _h, draft.x0, draft.y0, draft.x1, draft.y1),
          ),
          additive: _selectionAdditive,
        );
        _selectionAdditive = false;
        state = state.copyWith(
          selection: () => mask,
          selectDraft: () => null,
          revision: state.revision + 1,
          statusMessage: () => 'Selected',
        );
      case PixelTool.lasso:
        if (_finishSelectionMove()) return;
        final draft = state.lassoDraft;
        if (draft == null) return;
        final rawMask = draft.length >= 3
            ? _opaqueSelection(polygonMask(_w, _h, draft))
            : null;
        final mask = rawMask == null
            ? null
            : _selectionResult(rawMask, additive: _selectionAdditive);
        _selectionAdditive = false;
        final hasAny = mask != null && mask.any((v) => v != 0);
        state = state.copyWith(
          selection: () => hasAny ? mask : null,
          lassoDraft: () => null,
          revision: state.revision + 1,
          statusMessage: () => hasAny ? 'Selected' : 'Empty selection',
        );
      case PixelTool.wand:
        if (_finishSelectionMove()) return;
        final draft = state.selectDraft;
        _shapeAnchor = null;
        if (draft == null) return;
        final mask = _selectionResult(
          _opaqueSelection(
            rectMask(_w, _h, draft.x0, draft.y0, draft.x1, draft.y1),
          ),
          additive: _selectionAdditive,
        );
        _selectionAdditive = false;
        final hasAny = mask.any((value) => value != 0);
        state = state.copyWith(
          selection: () => hasAny ? mask : null,
          selectDraft: () => null,
          revision: state.revision + 1,
          statusMessage: () => hasAny ? 'Selected' : 'Empty selection',
        );
      case PixelTool.move:
        _finishSelectionMove();
      case PixelTool.fill:
      case PixelTool.eyedropper:
        break;
    }
  }

  void _finishDrawnStroke() {
    final base = _strokeBase;
    if (base == null) return;
    _strokeBase = null;
    _shapeAnchor = null;
    _lastStrokePoint = null;
    final result = Uint32List.fromList(_layer.pixels);
    _layer.pixels.setAll(0, base);
    _pushUndo();
    _layer.pixels.setAll(0, result);
    _touch();
  }

  void _scaleFloatingTo(int corner, int x, int y) {
    final f = state.floating;
    if (f == null) return;
    // The corner opposite the grabbed one stays fixed.
    final fixedX = corner == 0 || corner == 2
        ? f.offsetX + f.width - 1
        : f.offsetX;
    final fixedY = corner == 0 || corner == 1
        ? f.offsetY + f.height - 1
        : f.offsetY;
    final left = x < fixedX ? x : fixedX;
    final right = x < fixedX ? fixedX : x;
    final top = y < fixedY ? y : fixedY;
    final bottom = y < fixedY ? fixedY : y;
    final w = right - left + 1;
    final h = bottom - top + 1;
    final next = f.copyWith(
      pixels: scaleNearest(f.original, f.originalWidth, f.originalHeight, w, h),
      width: w,
      height: h,
      offsetX: left,
      offsetY: top,
    );
    state = state.copyWith(
      floating: () => next,
      isDirty: true,
      revision: state.revision + 1,
    );
    _scheduleFloatingRebuild(next);
  }

  void tapAt(double px, double py, {bool additiveSelection = false}) {
    final (x, y) = _clampPoint(px, py);
    switch (state.tool) {
      case PixelTool.pencil:
      case PixelTool.eraser:
        _strokeBase = Uint32List.fromList(_layer.pixels);
        final color = state.tool == PixelTool.eraser ? 0 : state.color;
        _paintSegment((x, y), (x, y), color);
        strokeEnd();
      case PixelTool.fill:
        final preferences = _preferences;
        _pushUndo();
        for (final (sx, sy) in symmetryPoints(
          x,
          y,
          _w,
          _h,
          preferences.symmetry,
        )) {
          floodFill(
            _layer.pixels,
            _w,
            _h,
            sx,
            sy,
            state.color,
            tolerance: preferences.fillTolerance,
            contiguous: preferences.fillContiguous,
            mask: state.selection,
            shadeStrength: preferences.fillShadeEnabled
                ? preferences.fillShadeStrength
                : 0,
          );
        }
        _touch(
          status: preferences.fillShadeEnabled
              ? 'Filled with shade variation'
              : preferences.fillContiguous
              ? 'Filled'
              : 'Color replaced',
        );
      case PixelTool.eyedropper:
        final composite = state.document.composite();
        final picked = composite[y * _w + x];
        if ((picked >>> 24) == 0) {
          state = state.copyWith(
            statusMessage: () => 'Transparent pixel: color kept',
          );
        } else {
          state = state.copyWith(
            color: picked,
            statusMessage: () => 'Picked color',
          );
        }
      case PixelTool.wand:
        final preferences = _preferences;
        _commitFloating(silent: true);
        final mask = _selectionResult(
          _opaqueSelection(
            magicWandMask(
              _layer.pixels,
              _w,
              _h,
              x,
              y,
              tolerance: preferences.fillTolerance,
              contiguous: preferences.fillContiguous,
            ),
          ),
          additive: additiveSelection,
        );
        final hasAny = mask.any((v) => v != 0);
        state = state.copyWith(
          selection: () => hasAny ? mask : null,
          revision: state.revision + 1,
          statusMessage: () => hasAny ? 'Selected' : 'Nothing selected',
        );
      case PixelTool.selectRect:
      case PixelTool.lasso:
        _commitFloating(silent: true);
        if (!additiveSelection) {
          state = state.copyWith(
            selection: () => null,
            revision: state.revision + 1,
          );
        }
      case PixelTool.move:
        _scaleCorner = null;
        if (state.floating != null && !_insideFloating(x, y)) {
          _commitFloating();
        }
      case PixelTool.line:
      case PixelTool.rect:
      case PixelTool.ellipse:
        break;
    }
  }

  // --- Files ------------------------------------------------------------------

  void newDocument(int width, int height) {
    final w = width.clamp(_minCanvasSide, _maxCanvasSide);
    final h = height.clamp(_minCanvasSide, _maxCanvasSide);
    _undoStack.clear();
    _redoStack.clear();
    _strokeBase = null;
    _shapeAnchor = null;
    _lastStrokePoint = null;
    _moveGrabOffset = null;
    _scaleCorner = null;
    _dirtyBeforeFloating = null;
    _shapePlanEdge = null;
    _selectionAdditive = false;
    state = state.copyWith(
      document: PixelDocument.blank(w, h),
      imageColors: const [],
      selection: () => null,
      floating: () => null,
      selectDraft: () => null,
      lassoDraft: () => null,
      shapePlan: () => null,
      isDirty: false,
      filePath: () => null,
      displayName: 'Untitled Pixel',
      assetTarget: () => null,
      canUndo: false,
      canRedo: false,
      statusMessage: () => 'New $w x $h canvas',
    );
    _scheduleFloatingRebuild(null);
    _scheduleRebuild(state.document);
  }

  RgpixFile _currentFile() {
    // Serialize with the floating selection stamped down, without disturbing
    // the live editing state.
    final doc = state.document.clone();
    final floating = state.floating;
    if (floating != null) {
      blit(
        doc.layers.first.pixels,
        doc.width,
        doc.height,
        floating.pixels,
        floating.width,
        floating.height,
        floating.offsetX,
        floating.offsetY,
      );
    }
    return RgpixFile(document: doc, palette: state.palette);
  }

  void _loadProject(
    RgpixFile project, {
    required String displayName,
    String? filePath,
    AssetPixelTarget? assetTarget,
    String? status,
    bool isDirty = false,
  }) {
    _undoStack.clear();
    _redoStack.clear();
    _strokeBase = null;
    _shapeAnchor = null;
    _lastStrokePoint = null;
    _moveGrabOffset = null;
    _scaleCorner = null;
    _shapePlanEdge = null;
    _selectionAdditive = false;
    _dirtyBeforeFloating = null;
    state = state.copyWith(
      document: project.document,
      palette: project.palette,
      imageColors: frequentOpaqueColors(project.document.composite()),
      selection: () => null,
      floating: () => null,
      selectDraft: () => null,
      lassoDraft: () => null,
      shapePlan: () => null,
      isDirty: isDirty,
      filePath: () => filePath,
      displayName: displayName,
      assetTarget: () => assetTarget,
      canUndo: false,
      canRedo: false,
      statusMessage: () => status ?? 'Opened $displayName',
    );
    _scheduleFloatingRebuild(null);
    _scheduleRebuild(state.document);
  }

  RgpixFile? _projectFromImageBytes(Uint8List imageBytes) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null ||
        decoded.width <= 0 ||
        decoded.height <= 0 ||
        decoded.width > _maxCanvasSide ||
        decoded.height > _maxCanvasSide) {
      return null;
    }
    final pixels = Uint32List(decoded.width * decoded.height);
    for (var y = 0; y < decoded.height; y++) {
      for (var x = 0; x < decoded.width; x++) {
        final pixel = decoded.getPixel(x, y);
        pixels[y * decoded.width + x] =
            (pixel.a.toInt() << 24) |
            (pixel.r.toInt() << 16) |
            (pixel.g.toInt() << 8) |
            pixel.b.toInt();
      }
    }
    return RgpixFile(
      document: PixelDocument(
        width: decoded.width,
        height: decoded.height,
        layers: [PixelLayer(name: 'Layer 1', pixels: pixels)],
      ),
      palette: defaultPixelPalette,
    );
  }

  /// Opens an Asset Definer source in this tab. Embedded project data wins;
  /// older bundles and ordinary imported images fall back to a one-layer
  /// document decoded from their PNG bytes.
  String? loadAssetSource({
    required Uint8List imageBytes,
    required String name,
    required AssetPixelTarget target,
    Uint8List? pixelProjectBytes,
  }) {
    RgpixFile? project;
    String? warning;
    if (pixelProjectBytes != null) {
      try {
        project = RgpixFile.decode(utf8.decode(pixelProjectBytes));
      } on Object {
        warning = 'Embedded pixel project was invalid; opened the PNG instead';
      }
    }

    if (project == null) {
      project = _projectFromImageBytes(imageBytes);
      if (project == null) {
        return 'Pixel Editor could not decode $name at its original size';
      }
    }

    _loadProject(
      project,
      displayName: name,
      assetTarget: target,
      status: warning,
    );
    return null;
  }

  bool importImageBytes(Uint8List imageBytes, String name) {
    final project = _projectFromImageBytes(imageBytes);
    if (project == null) {
      state = state.copyWith(
        statusMessage: () =>
            'Import failed: image must be decodable and at most 1024 x 1024 px',
      );
      return false;
    }
    _loadProject(
      project,
      displayName: name,
      isDirty: true,
      status: 'Imported $name at 1:1 pixel size',
    );
    return true;
  }

  Future<bool> importImageFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import image at 1:1 pixel size',
      type: FileType.image,
      withData: true,
    );
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return false;
    return importImageBytes(bytes, file.name);
  }

  void refreshImageColors() {
    state = state.copyWith(
      imageColors: frequentOpaqueColors(state.document.composite()),
      statusMessage: () => 'Refreshed image colors',
    );
  }

  Future<void> save() async {
    if (state.assetTarget != null) {
      await _embedInAssetDefiner(activateAssetDefiner: false);
      return;
    }
    final path = state.filePath;
    if (path == null) {
      await saveAs();
      return;
    }
    try {
      await File(path).writeAsString(_currentFile().encode());
    } catch (e) {
      state = state.copyWith(statusMessage: () => 'Save failed: $e');
      return;
    }
    state = state.copyWith(
      isDirty: false,
      statusMessage: () => 'Saved to $path',
    );
  }

  Future<void> saveAs() async {
    final encoded = _currentFile().encode();
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save pixel project',
      fileName: state.filePath?.split('/').last ?? 'pixel-art.rgpix',
      type: FileType.custom,
      allowedExtensions: ['rgpix'],
      bytes: Uint8List.fromList(utf8.encode(encoded)),
    );
    if (path == null) {
      state = state.copyWith(statusMessage: () => 'Save cancelled');
      return;
    }
    state = state.copyWith(
      isDirty: false,
      filePath: () => path,
      displayName: path.split('/').last,
      assetTarget: () => null,
      statusMessage: () => 'Saved to $path',
    );
  }

  Future<bool> openFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open pixel project',
      type: FileType.custom,
      allowedExtensions: ['rgpix'],
      withData: true,
    );
    final file = result?.files.single;
    if (file?.bytes == null) return false;
    final RgpixFile decoded;
    try {
      decoded = RgpixFile.decode(utf8.decode(file!.bytes!));
    } on FormatException catch (e) {
      state = state.copyWith(statusMessage: () => 'Open failed: ${e.message}');
      return false;
    }
    _loadProject(decoded, displayName: file.name, filePath: file.path);
    return true;
  }

  Uint8List _encodePng() {
    final file = _currentFile();
    final rgba = pixelsToRgbaBytes(file.document.composite());
    final image = img.Image.fromBytes(
      width: file.document.width,
      height: file.document.height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  String get _pngName {
    final base = state.displayName.replaceFirst(RegExp(r'\.(rgpix|png)$'), '');
    return '$base.png';
  }

  Future<void> exportPng() async {
    final path = await FilePicker.saveFile(
      dialogTitle: 'Export PNG',
      fileName: _pngName,
      type: FileType.custom,
      allowedExtensions: ['png'],
      bytes: _encodePng(),
    );
    if (path != null) {
      state = state.copyWith(statusMessage: () => 'Exported PNG to $path');
    }
  }

  Future<bool> _embedInAssetDefiner({
    BlockCategory? category,
    required bool activateAssetDefiner,
  }) async {
    final previousTarget = state.assetTarget;
    final resolvedCategory = category ?? previousTarget?.category;
    if (resolvedCategory == null) return false;
    final projectBytes = Uint8List.fromList(
      utf8.encode(_currentFile().encode()),
    );
    final error = await ref
        .read(assetDefinerProvider.notifier)
        .importImageBytes(
          _encodePng(),
          _pngName,
          resolvedCategory,
          pixelProjectBytes: projectBytes,
          decorationIndex: previousTarget?.category == resolvedCategory
              ? previousTarget?.decorationIndex
              : null,
        );
    if (error != null) {
      state = state.copyWith(statusMessage: () => error);
      return false;
    }
    final assetState = ref.read(assetDefinerProvider);
    final target = AssetPixelTarget(
      category: resolvedCategory,
      decorationIndex: resolvedCategory == BlockCategory.decoration
          ? assetState.activeDecorationIndex
          : null,
    );
    state = state.copyWith(
      isDirty: false,
      filePath: () => null,
      displayName: _pngName,
      assetTarget: () => target,
      statusMessage: () => 'Embedded in Asset Definer',
    );
    if (activateAssetDefiner) {
      ref.read(workspaceProvider.notifier).activatePhase1();
    }
    return true;
  }

  /// Embeds the editable project and flattened PNG in Asset Definer, then
  /// switches back to it. A standalone tab needs a category; a tab opened
  /// from an asset source updates that exact source.
  Future<void> sendToAssetDefiner([BlockCategory? category]) async {
    await _embedInAssetDefiner(category: category, activateAssetDefiner: true);
  }
}

/// One independent pixel-editor instance per open Pixel tab. The family is
/// deliberately non-autoDispose so switching tabs keeps document history and
/// decoded images alive until the workspace closes that tab.
final pixelEditorProvider =
    NotifierProvider.family<PixelEditorNotifier, PixelEditorState, int>(
      (_) => PixelEditorNotifier(),
    );
