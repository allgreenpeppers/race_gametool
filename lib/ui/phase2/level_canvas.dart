import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../models/block_def.dart';
import '../../models/map_scene.dart';
import '../../models/function_layer.dart';
import '../../logic/function_layer_generator.dart';
import '../../state/app_providers.dart';
import '../../state/level_editor_providers.dart';
import '../widgets/block_thumbnail.dart';
import '../widgets/port_marker.dart';

/// The Phase 2 grid canvas: an InteractiveViewer holding a fixed grid onto
/// which palette blocks are stamped. Renders placed sprites from the packed
/// sheet, their ports, the selection highlight, and a stamp ghost preview.
class LevelCanvas extends ConsumerStatefulWidget {
  const LevelCanvas({super.key, required this.tabId});

  /// Which workspace tab (and thus which `levelEditorProvider` instance) this
  /// canvas edits.
  final int tabId;

  /// Canvas size in grid cells. Large enough to lay out a full track;
  /// InteractiveViewer pans and zooms within it.
  static const int cols = GridConstants.levelGridCols;
  static const int rows = GridConstants.levelGridRows;

  @override
  ConsumerState<LevelCanvas> createState() => _LevelCanvasState();
}

class _LevelCanvasState extends ConsumerState<LevelCanvas> {
  static const _cell = GridConstants.cellSize;

  final TransformationController _transform = TransformationController();
  bool _centered = false;

  @override
  void initState() {
    super.initState();
    // Start the view centred on the large canvas so a track can grow in
    // every direction before reaching an edge.
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnce());
  }

  void _centerOnce() {
    if (_centered || !mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    const canvasW = LevelCanvas.cols * _cell;
    const canvasH = LevelCanvas.rows * _cell;
    _transform.value = Matrix4.translationValues(
      box.size.width / 2 - canvasW / 2,
      box.size.height / 2 - canvasH / 2,
      0,
    );
    _centered = true;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  (int, int) _toCell(Offset local) => (
        (local.dx / _cell).floor().clamp(0, LevelCanvas.cols - 1),
        (local.dy / _cell).floor().clamp(0, LevelCanvas.rows - 1),
      );

  /// Connect mode: tapping a free port opens a menu of blocks that can
  /// snap onto it (matching opposite direction and span). Choosing one
  /// places it snapped to the port.
  Future<void> _handleConnectTap(
    BuildContext context,
    LevelEditorNotifier notifier,
    int cellX,
    int cellY,
    Offset globalPosition,
  ) async {
    final hit = notifier.connectPortAt(cellX, cellY);
    if (hit == null) {
      notifier.setStatus('Tap a port (the + markers) to connect a block');
      return;
    }
    final candidates = notifier.connectCandidates(hit);
    if (candidates.isEmpty) {
      notifier.setStatus('No compatible block fits this port');
      return;
    }
    final library = ref.read(assetLibraryProvider);
    // A single compatible block needs no menu: auto-select it.
    final chosen = candidates.length == 1
        ? candidates.single
        : await showMenu<ConnectCandidate>(
            context: context,
            position: RelativeRect.fromLTRB(
              globalPosition.dx,
              globalPosition.dy,
              globalPosition.dx + 1,
              globalPosition.dy + 1,
            ),
            items: [
              for (final c in candidates)
                PopupMenuItem<ConnectCandidate>(
                  value: c,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 32,
                        height: 32,
                        child: library.sheetImage == null
                            ? const Icon(Icons.widgets_outlined, size: 20)
                            : BlockThumbnail(
                                image: library.sheetImage!,
                                rect: c.def.spriteSheetRect,
                              ),
                      ),
                      const SizedBox(width: 10),
                      Text(c.def.id),
                    ],
                  ),
                ),
            ],
          );
    if (chosen != null) {
      notifier.chooseConnection(
        hit,
        chosen,
        cols: LevelCanvas.cols,
        rows: LevelCanvas.rows,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(levelEditorProvider(widget.tabId));
    final library = ref.watch(assetLibraryProvider);
    final notifier = ref.read(levelEditorProvider(widget.tabId).notifier);
    // Stamp/erase paint on drag; Multi drags to marquee-select or move the
    // selection. Select and Connect leave drags to InteractiveViewer to pan.
    final usesDrag = state.tool == LevelTool.stamp ||
        state.tool == LevelTool.erase ||
        state.tool == LevelTool.multi;

    // The island layer is autotiled, not wired by ports: no connect "+",
    // no insert seams, no port glyphs there.
    final portsEnabled = state.activeLayer != MapLayer.island;

    // Occupancy for drawing "+" on free ports in Connect mode.
    final occupied = state.tool == LevelTool.connect && portsEnabled
        ? notifier.occupiedCells()
        : null;



    void handleTap(Offset local, Offset global) {
      Focus.of(context).requestFocus();
      final (x, y) = _toCell(local);
      switch (state.tool) {
        case LevelTool.stamp:
          if (state.activeLayer == MapLayer.island) {
            notifier.paintGrassAt(x, y, erase: false);
          } else {
            notifier.stampAt(x, y);
          }
        case LevelTool.erase:
          if (state.activeLayer == MapLayer.island) {
            notifier.paintGrassAt(x, y, erase: true);
          } else {
            notifier.eraseAt(x, y);
          }
        case LevelTool.select:
          notifier.selectAt(x, y);
        case LevelTool.multi:
          notifier.selectSingleAt(x, y);

        case LevelTool.spawn:
          notifier.setSpawnAt(x, y);
        case LevelTool.connect:
          if (!portsEnabled) {
            notifier.setStatus(
                'Island layer uses Generate Island, not port connect');
            break;
          }
          // While a straight-extension preview is active, a tap picks how
          // many tiles to place (ghost N -> place N), or cancels.
          if (state.extendPreview != null) {
            final count = notifier.extendCountAt(x, y);
            if (count != null) {
              notifier.commitExtend(count);
            } else {
              notifier.cancelExtend();
            }
          } else {
            _handleConnectTap(context, notifier, x, y, global);
          }
      }
    }

    void handleDragCell((int, int) cell) {
      final (x, y) = cell;
      notifier.setHover((x, y));
      if (state.tool == LevelTool.stamp) {
        if (state.activeLayer == MapLayer.island) {
          notifier.paintGrassAt(x, y, erase: false);
        }
      } else if (state.tool == LevelTool.erase) {
        if (state.activeLayer == MapLayer.island) {
          notifier.paintGrassAt(x, y, erase: true);
        } else {
          notifier.eraseAt(x, y);
        }
      }
    }

    // The MouseRegion sits INSIDE the InteractiveViewer so hover positions
    // are in the same scene coordinate space as taps; otherwise a panned or
    // zoomed view makes the stamp preview land on a different cell than the
    // actual placement.
    return InteractiveViewer(
      transformationController: _transform,
      constrained: false,
      minScale: 0.2,
      maxScale: 10,
      boundaryMargin: const EdgeInsets.all(400),
      child: Listener(
        onPointerMove: (event) {
          if (event.buttons == kMiddleMouseButton) {
            final matrix = _transform.value.clone();
            matrix.storage[12] += event.delta.dx;
            matrix.storage[13] += event.delta.dy;
            _transform.value = matrix;
          }
        },
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final isZoomKey = HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed;
            if (isZoomKey) {
              final double dy = event.scrollDelta.dy;
              if (dy != 0) {
                final double scaleDelta = dy > 0 ? 0.9 : 1.1;
                final matrix = _transform.value.clone();
                final double tx = matrix.storage[12];
                final double ty = matrix.storage[13];
                final double currentScale = matrix.getMaxScaleOnAxis();
                const minScale = 0.2;
                const maxScale = 10.0;
                final double newScale = (currentScale * scaleDelta).clamp(minScale, maxScale);
                final double actualFactor = newScale / currentScale;
                if (actualFactor != 1.0) {
                  final px = event.localPosition.dx;
                  final py = event.localPosition.dy;
                  matrix.storage[0] *= actualFactor;
                  matrix.storage[5] *= actualFactor;
                  matrix.storage[10] *= actualFactor;
                  matrix.storage[12] = px + (tx - px) * actualFactor;
                  matrix.storage[13] = py + (ty - py) * actualFactor;
                  _transform.value = matrix;
                }
              }
            } else {
              final matrix = _transform.value.clone();
              matrix.storage[12] -= event.scrollDelta.dx;
              matrix.storage[13] -= event.scrollDelta.dy;
              _transform.value = matrix;
            }
          }
        },
        child: MouseRegion(
          onHover: (event) => notifier.setHover(_toCell(event.localPosition)),
          onExit: (_) => notifier.setHover(null),
          child: RawGestureDetector(
            gestures: {
              if (usesDrag)
                LeftClickPanGestureRecognizer: GestureRecognizerFactoryWithHandlers<LeftClickPanGestureRecognizer>(
                  () => LeftClickPanGestureRecognizer(
                    allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
                  ),
                  (LeftClickPanGestureRecognizer instance) {
                    instance
                      ..onStart = (d) {
                        Focus.of(context).requestFocus();
                        final (x, y) = _toCell(d.localPosition);
                        if (state.tool == LevelTool.multi) {
                          notifier.multiDragStart(x, y);
                        } else if (state.tool == LevelTool.stamp &&
                            state.activeLayer == MapLayer.track) {
                          // Track only: dragging pulls a straight run of
                          // the selected block, committed on release.
                          notifier.stampDragStart(x, y);
                        } else {
                          handleDragCell((x, y));
                        }
                      }
                      ..onUpdate = (d) {
                        final (x, y) = _toCell(d.localPosition);
                        if (state.tool == LevelTool.multi) {
                          notifier.multiDragUpdate(x, y);
                        } else if (state.tool == LevelTool.stamp &&
                            state.activeLayer == MapLayer.track) {
                          notifier.stampDragUpdate(x, y);
                        } else {
                          handleDragCell((x, y));
                        }
                      }
                      ..onEnd = (_) {
                        if (state.tool == LevelTool.multi) {
                          notifier.multiDragEnd(
                              cols: LevelCanvas.cols, rows: LevelCanvas.rows);
                        } else if (state.tool == LevelTool.stamp) {
                          if (state.activeLayer == MapLayer.track) {
                            notifier.stampDragEnd();
                          } else if (state.activeLayer != MapLayer.island) {
                            final hover = state.hoverCell;
                            if (hover != null) {
                              notifier.stampAt(hover.$1, hover.$2);
                            }
                          }
                        }
                      };
                  },
                ),
              TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(
                  allowedButtonsFilter: (int buttons) => buttons == kPrimaryButton,
                ),
                (TapGestureRecognizer instance) {
                  instance.onTapUp = (d) => handleTap(d.localPosition, d.globalPosition);
                },
              ),
            },
            child: CustomPaint(
              size: const Size(
                  LevelCanvas.cols * _cell, LevelCanvas.rows * _cell),
              painter: _LevelPainter(
                blocks: library,
                placements: state.placements,
                tool: state.tool,
                hoverCell: state.hoverCell,
                stampId: state.selectedPaletteId,
                rectOf: notifier.rectOf,
                occupied: occupied,
                extendPreview: state.extendPreview,
                stampDragPreview: state.stampDragPreview,
                selection: state.highlighted,
                marquee: state.marquee,
                groupDelta: state.groupDelta,
                spawn: state.spawn,
                activeLayer: state.activeLayer,
                islandGrassMask: state.islandGrassMask,
                islandBrushRadius: state.islandBrushRadius,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LevelPainter extends CustomPainter {
  _LevelPainter({
    required this.blocks,
    required this.placements,
    required this.tool,
    required this.hoverCell,
    required this.stampId,
    required this.rectOf,
    required this.occupied,
    required this.extendPreview,
    required this.stampDragPreview,
    required this.selection,
    required this.marquee,
    required this.groupDelta,
    required this.spawn,
    required this.activeLayer,
    required this.islandGrassMask,
    required this.islandBrushRadius,
  });

  final AssetLibrary blocks;
  final List<BlockPlacement> placements;
  final LevelTool tool;
  final (int, int)? hoverCell;
  final String? stampId;
  final CellRect? Function(BlockPlacement) rectOf;
  final Set<(int, int)>? occupied;
  final ExtendPreview? extendPreview;
  final ExtendPreview? stampDragPreview;
  final Set<int> selection;
  final (int, int, int, int)? marquee;
  final (int, int)? groupDelta;
  final SpawnPoint? spawn;
  final MapLayer activeLayer;
  final Set<(int, int)>? islandGrassMask;
  final int islandBrushRadius;

  static const _cell = GridConstants.cellSize;

  MapLayer? _layerOf(BlockPlacement p) {
    final def = blocks.blockById(p.blockId);
    return def == null ? null : MapLayer.forCategory(def.category);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintGrid(canvas, size);

    // Render underlying manual grass mask under blocks
    _paintGrassMask(canvas, size);

    // Unknown blocks have no layer; keep their red placeholder visible at
    // the bottom of the stack.
    for (var i = 0; i < placements.length; i++) {
      if (_layerOf(placements[i]) == null) {
        _paintPlacement(canvas, placements[i], selected: false, dim: true);
      }
    }
    // Layers stack in enum order (island under track under decoration
    // under function). Layers below the active one really do sit under it,
    // so they render solid; only layers above are dimmed so they don't
    // hide what is being edited.
    for (final layer in MapLayer.values) {
      final dim = layer.index > activeLayer.index;
      for (var i = 0; i < placements.length; i++) {
        if (_layerOf(placements[i]) != layer) continue;
        _paintPlacement(canvas, placements[i],
            selected: layer == activeLayer && selection.contains(i),
            dim: dim);
      }
    }

    _paintAlignmentGuides(canvas, size);
    _paintStampGhost(canvas);
    // The Connect extender shows a clickable "+" per ghost; the drag-stamp
    // run is committed on release, so it renders ghosts only.
    _paintRunPreview(canvas, extendPreview, showPlus: true);
    _paintRunPreview(canvas, stampDragPreview, showPlus: false);
    _paintGroupMove(canvas);
    _paintMarquee(canvas);
    _paintSpawn(canvas);

    // Automatically paint the generated check lines and boundaries on all layers
    // so the user gets real-time feedback (drawn dimmer when not on the Function layer).
    _paintGeneratedFunctionData(canvas, opacity: activeLayer == MapLayer.function ? 1.0 : 0.3);
  }

  void _paintGeneratedFunctionData(Canvas canvas, {required double opacity}) {
    // Generate check lines and boundaries on the fly
    final (checkLines, boundaries) = FunctionLayerGenerator.generate(
      placements: placements,
      defOf: (id) => blocks.blockById(id),
      settings: const FunctionLayerSettings(), // Uses default settings for visual preview
      islandGrassMask: islandGrassMask,
    );

    // 1. Draw Check Lines
    final checkPaint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: opacity)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final arrowPaint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: opacity)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    for (final cl in checkLines) {
      canvas.drawLine(
        Offset(cl.p1.x, cl.p1.y),
        Offset(cl.p2.x, cl.p2.y),
        checkPaint,
      );

      // Draw direction arrow at the center
      final center = Offset((cl.p1.x + cl.p2.x) / 2.0, (cl.p1.y + cl.p2.y) / 2.0);
      final angle = math.atan2(cl.forwardVector.y, cl.forwardVector.x);
      final arrowLen = _cell * 0.5;
      final tip = center + Offset(math.cos(angle), math.sin(angle)) * arrowLen;
      canvas.drawLine(center, tip, arrowPaint);
      for (final side in [2.5, -2.5]) {
        final wing = tip + Offset(math.cos(angle + side), math.sin(angle + side)) * arrowLen * 0.4;
        canvas.drawLine(tip, wing, arrowPaint);
      }
    }

    // 2. Draw Track Boundaries
    for (final tb in boundaries) {
      if (tb.vertices.isEmpty) continue;

      final Color boundaryColor;
      final double strokeWidth;

      if (tb.type == 'antiCutRed') {
        boundaryColor = Colors.redAccent;
        strokeWidth = 2.5;
      } else if (tb.type == 'innerFunction') {
        boundaryColor = Colors.orangeAccent;
        strokeWidth = 1.5;
      } else {
        boundaryColor = Colors.indigoAccent;
        strokeWidth = 2.0;
      }

      final paint = Paint()
        ..color = boundaryColor.withValues(alpha: opacity)
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(tb.vertices.first.x, tb.vertices.first.y);
      for (var i = 1; i < tb.vertices.length; i++) {
        path.lineTo(tb.vertices[i].x, tb.vertices[i].y);
      }
      if (tb.isClosed) {
        path.close();
      }

      canvas.drawPath(path, paint);
    }
  }

  void _paintAlignmentGuides(Canvas canvas, Size size) {
    final hover = hoverCell;
    if (hover == null) {
      return;
    }
    if (tool != LevelTool.stamp &&
        tool != LevelTool.erase &&
        tool != LevelTool.connect) {
      return;
    }

    final paint = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.35)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final cx = (hover.$1 + 0.5) * _cell + 0.5;
    final cy = (hover.$2 + 0.5) * _cell + 0.5;

    // Vertical guide line
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
    // Horizontal guide line
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), paint);
  }

  void _paintGrassMask(Canvas canvas, Size size) {
    if (activeLayer != MapLayer.island || islandGrassMask == null) return;

    final paint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (final (x, y) in islandGrassMask!) {
      final rect = Rect.fromLTWH(x * _cell, y * _cell, _cell, _cell);
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect, borderPaint);
    }
  }

  void _paintSpawn(Canvas canvas) {
    final s = spawn;
    if (s == null) return;
    final center = Offset((s.gridX + 0.5) * _cell, (s.gridY + 0.5) * _cell);
    final r = _cell * 0.6;
    canvas.drawCircle(
        center, r, Paint()..color = Colors.purpleAccent.withValues(alpha: 0.85));
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    // Facing arrow.
    final a = s.facingAngle;
    final tip = center + Offset(math.cos(a), math.sin(a)) * r;
    final tail = center - Offset(math.cos(a), math.sin(a)) * r * 0.4;
    final arrow = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, tip, arrow);
    for (final side in [2.5, -2.5]) {
      final wing =
          tip + Offset(math.cos(a + side), math.sin(a + side)) * r * 0.5;
      canvas.drawLine(tip, wing, arrow);
    }
  }



  void _paintGroupMove(Canvas canvas) {
    final delta = groupDelta;
    if (delta == null || (delta.$1 == 0 && delta.$2 == 0)) return;
    final ox = delta.$1 * _cell;
    final oy = delta.$2 * _cell;
    for (final i in selection) {
      final r = rectOf(placements[i]);
      if (r == null) continue;
      final dst = Rect.fromLTWH(
          r.x * _cell + ox, r.y * _cell + oy, r.w * _cell, r.h * _cell);
      canvas.drawRect(
          dst, Paint()..color = Colors.cyanAccent.withValues(alpha: 0.18));
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.cyanAccent,
      );
    }
  }

  void _paintMarquee(Canvas canvas) {
    final m = marquee;
    if (m == null) return;
    final rect =
        Rect.fromLTWH(m.$1 * _cell, m.$2 * _cell, m.$3 * _cell, m.$4 * _cell);
    canvas.drawRect(
        rect, Paint()..color = Colors.lightBlueAccent.withValues(alpha: 0.12));
    canvas.drawRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.lightBlueAccent,
    );
  }

  void _paintRunPreview(Canvas canvas, ExtendPreview? preview,
      {required bool showPlus}) {
    if (preview == null) return;
    final def = blocks.blockById(preview.blockId);
    if (def == null) return;
    final image = blocks.sheetImage;
    final r = def.spriteSheetRect;
    for (var i = 0; i < preview.positions.length; i++) {
      final (px, py) = preview.positions[i];
      final dst = Rect.fromLTWH(px * _cell, py * _cell,
          def.boundingBox.width * _cell, def.boundingBox.height * _cell);
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
              r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
          dst,
          Paint()
            ..filterQuality = FilterQuality.none
            ..color = const Color(0x66FFFFFF)
            ..colorFilter = const ColorFilter.mode(
                Color(0x66FFFFFF), BlendMode.modulate),
        );
      }
      canvas.drawRect(
          dst, Paint()..color = Colors.cyanAccent.withValues(alpha: 0.12));
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.cyanAccent.withValues(alpha: 0.7),
      );
      // A "+" at each step; clicking step i places i+1 tiles.
      if (showPlus) _paintPlus(canvas, dst.center, _cell * 0.42);
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFF0E1B24));
    final minor = Paint()
      ..strokeWidth = 0.5
      ..color = Colors.white.withValues(alpha: 0.06);
    final major = Paint()
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: 0.14);
    for (var c = 0; c <= LevelCanvas.cols; c++) {
      final x = c * _cell;
      canvas.drawLine(
          Offset(x, 0), Offset(x, size.height), c % 5 == 0 ? major : minor);
    }
    for (var r = 0; r <= LevelCanvas.rows; r++) {
      final y = r * _cell;
      canvas.drawLine(
          Offset(0, y), Offset(size.width, y), r % 5 == 0 ? major : minor);
    }
  }

  void _paintPlacement(Canvas canvas, BlockPlacement p,
      {required bool selected, bool dim = false}) {
    final def = blocks.blockById(p.blockId);
    if (def == null) {
      // Unknown block: draw a red placeholder so it is visible.
      final rect = Rect.fromLTWH(p.gridX * _cell, p.gridY * _cell, _cell, _cell);
      canvas.drawRect(rect, Paint()..color = Colors.red.withValues(alpha: 0.4));
      return;
    }
    final dst = Rect.fromLTWH(
      p.gridX * _cell,
      p.gridY * _cell,
      def.boundingBox.width * _cell,
      def.boundingBox.height * _cell,
    );
    final image = blocks.sheetImage;
    if (image != null) {
      final r = def.spriteSheetRect;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
            r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
        dst,
        Paint()
          ..filterQuality = FilterQuality.none
          // Fade blocks that are not on the active layer.
          ..color = Colors.white.withValues(alpha: dim ? 0.28 : 1.0),
      );
    } else {
      canvas.drawRect(
          dst,
          Paint()
            ..color = Colors.blueGrey.withValues(alpha: dim ? 0.18 : 0.5));
    }

    // Dimmed (inactive-layer) blocks are context only: no selection ring,
    // no port glyphs.
    if (dim) return;

    if (selected) {
      canvas.drawRect(
        dst,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.yellowAccent,
      );
    }

    // Port glyphs are wiring detail for the track editor only: other
    // editing layers render clean sprites. Island tiles are autotiled,
    // not port-wired, so theirs never show even there.
    if (activeLayer == MapLayer.track &&
        def.category != BlockCategory.islandTile) {
      _paintPorts(canvas, def, p.gridX, p.gridY);
    }
  }

  void _paintPorts(
      Canvas canvas, BlockDef def, int originX, int originY) {
    final connectMode = tool == LevelTool.connect;
    final occ = occupied;
    for (var j = 0; j < def.ports.length; j++) {
      final port = def.ports[j];
      final passThrough = portIsPassThrough(def, port);
      final (extentW, extentH) = port.cellExtent;
      final center = Offset(
        (originX + port.localGridX + extentW / 2) * _cell,
        (originY + port.localGridY + extentH / 2) * _cell,
      );
      paintPort(canvas, center, _cell * 0.55, port.direction,
          bidirectional: passThrough);

      // In Connect mode, mark each free side with a "+" just outside the
      // strip. A pass-through port gets a "+" on both ends.
      if (connectMode && occ != null) {
        for (final dir in portOutwardDirections(def, port)) {
          final sideOccupied = portOutwardCells(originX, originY, port, dir)
              .any(occ.contains);
          if (sideOccupied) continue;
          final (dx, dy) = dir.gridDelta;
          final plus = Offset(
            center.dx + dx * _cell * 0.9,
            center.dy + dy * _cell * 0.9,
          );
          _paintPlus(canvas, plus, _cell * 0.42);
        }
      }
    }
  }

  void _paintPlus(Canvas canvas, Offset center, double radius) {
    canvas.drawCircle(
        center, radius, Paint()..color = Colors.green.withValues(alpha: 0.9));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white,
    );
    final arm = radius * 0.55;
    final bar = Paint()
      ..strokeWidth = radius * 0.28
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    canvas.drawLine(
        center - Offset(arm, 0), center + Offset(arm, 0), bar);
    canvas.drawLine(
        center - Offset(0, arm), center + Offset(0, arm), bar);
  }

  void _paintStampGhost(Canvas canvas) {
    if (activeLayer == MapLayer.island) {
      if (tool != LevelTool.stamp && tool != LevelTool.erase) return;
      final hover = hoverCell;
      if (hover == null) return;

      final radius = islandBrushRadius;
      final tint = tool == LevelTool.stamp ? Colors.greenAccent : Colors.redAccent;
      final rect = Rect.fromLTRB(
        (hover.$1 - radius) * _cell,
        (hover.$2 - radius) * _cell,
        (hover.$1 + radius + 1) * _cell,
        (hover.$2 + radius + 1) * _cell,
      );
      canvas.drawRect(rect, Paint()..color = tint.withValues(alpha: 0.18));
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = tint,
      );
      return;
    }
    if (tool == LevelTool.erase) {
      final hover = hoverCell;
      if (hover == null) return;
      final rect = Rect.fromLTWH(hover.$1 * _cell, hover.$2 * _cell, _cell, _cell);
      canvas.drawRect(rect, Paint()..color = Colors.redAccent.withValues(alpha: 0.18));
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.redAccent,
      );
      return;
    }

    if (tool != LevelTool.stamp) return;
    // While drag-stamping, the run preview is the ghost; the single hover
    // ghost would just double-draw over its anchor tile.
    if (stampDragPreview != null) return;
    final hover = hoverCell;
    if (hover == null) return;

    final id = stampId;
    if (id == null) return;
    final def = blocks.blockById(id);
    if (def == null) return;
    // Clamp the origin so the ghost stays fully inside the grid, exactly
    // as stampAt does, so the preview matches where the block will land.
    final maxX = LevelCanvas.cols - def.boundingBox.width;
    final maxY = LevelCanvas.rows - def.boundingBox.height;
    if (maxX < 0 || maxY < 0) return;
    final hx = hover.$1.clamp(0, maxX);
    final hy = hover.$2.clamp(0, maxY);
    final dst = Rect.fromLTWH(
      hx * _cell,
      hy * _cell,
      def.boundingBox.width * _cell,
      def.boundingBox.height * _cell,
    );

    // Red when the drop would overlap, green otherwise.
    final candidate =
        CellRect(hx, hy, def.boundingBox.width, def.boundingBox.height);
    var blocked = false;
    for (final p in placements) {
      if (_layerOf(p) != activeLayer) continue;
      final r = rectOf(p);
      if (r != null && candidate.overlaps(r)) {
        blocked = true;
        break;
      }
    }
    final tint = blocked ? Colors.redAccent : Colors.greenAccent;

    final image = blocks.sheetImage;
    if (image != null) {
      final r = def.spriteSheetRect;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(
            r.x.toDouble(), r.y.toDouble(), r.w.toDouble(), r.h.toDouble()),
        dst,
        Paint()
          ..filterQuality = FilterQuality.none
          ..color = const Color(0x88FFFFFF)
          ..colorFilter =
              const ColorFilter.mode(Color(0x88FFFFFF), BlendMode.modulate),
      );
    }
    canvas.drawRect(dst, Paint()..color = tint.withValues(alpha: 0.18));
    canvas.drawRect(
      dst,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = tint,
    );
  }

  @override
  bool shouldRepaint(_LevelPainter old) =>
      old.blocks != blocks ||
      old.placements != placements ||
      old.tool != tool ||
      old.hoverCell != hoverCell ||
      old.stampId != stampId ||
      old.occupied != occupied ||
      old.extendPreview != extendPreview ||
      old.stampDragPreview != stampDragPreview ||
      old.selection != selection ||
      old.marquee != marquee ||
      old.groupDelta != groupDelta ||
      old.spawn != spawn ||
      old.activeLayer != activeLayer ||
      old.islandGrassMask != islandGrassMask ||
      old.islandBrushRadius != islandBrushRadius;
}

class LeftClickPanGestureRecognizer extends PanGestureRecognizer {
  LeftClickPanGestureRecognizer({
    super.allowedButtonsFilter,
  });

  @override
  void addAllowedPointerPanZoom(PointerPanZoomStartEvent event) {
    // Ignore trackpad pan-zoom events so they fall through to InteractiveViewer.
  }
}
