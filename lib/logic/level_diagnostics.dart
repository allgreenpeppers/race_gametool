import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_def.dart';
import '../models/control_point.dart';
import '../models/geometry.dart';
import '../models/map_scene.dart';
import '../models/port.dart';
import '../state/app_providers.dart';
import '../state/level_editor_providers.dart';
import 'track_boundaries.dart';
import 'track_topology.dart';

/// Severity of a level diagnostic, mirroring an IDE problems panel.
enum DiagnosticSeverity { error, warning }

/// One problem found while validating the placed track.
class LevelDiagnostic {
  const LevelDiagnostic({
    required this.severity,
    required this.message,
    this.placementIndex,
    this.gridX,
    this.gridY,
  });

  final DiagnosticSeverity severity;
  final String message;

  /// Placement the problem belongs to (for click-to-focus), if any.
  final int? placementIndex;

  /// A representative cell for the problem, for centering the view.
  final int? gridX;
  final int? gridY;
}

/// Validates the placed track and returns problems, errors first.
///
/// Rules:
/// - ERROR: a port faces a neighbor block across the edge, but no port on
///   that neighbor faces back with a matching span (mismatched, e.g. a
///   span-4 meeting a span-5, or an edge butting a block with no port).
/// - ERROR: a port's outward cells are only partly covered by a neighbor
///   (misaligned / partial contact).
/// - WARNING: a port side is completely free (nothing connected).
///
/// A pass-through port is checked per side.
List<LevelDiagnostic> validateLevel(
  List<BlockPlacement> placements,
  BlockDef? Function(String id) defOf, {
  Map<String, double> manualControlPointOffsets = const {},
  List<ControlPoint> userInsertedPoints = const [],
}) {
  final diagnostics = <LevelDiagnostic>[];

  // Map every occupied cell to the placement index covering it. Later
  // placements win on overlap, but overlaps are prevented on placement.
  final owner = <(int, int), int>{};
  final rects = <CellRect?>[];
  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null) {
      rects.add(null);
      diagnostics.add(LevelDiagnostic(
        severity: DiagnosticSeverity.error,
        message: 'Unknown block "${placements[i].blockId}" (not in library)',
        placementIndex: i,
        gridX: placements[i].gridX,
        gridY: placements[i].gridY,
      ));
      continue;
    }
    final r = CellRect(placements[i].gridX, placements[i].gridY,
        def.boundingBox.width, def.boundingBox.height);
    rects.add(r);
    // Only track pieces participate in port-connection diagnostics; island
    // tiles (autotiled) and decorations are not port-wired, and they may
    // share cells with track since layers overlap. Keeping only track cells
    // in the owner map avoids cross-layer false positives.
    if (def.category != BlockCategory.track) continue;
    for (var y = r.y; y < r.y + r.h; y++) {
      for (var x = r.x; x < r.x + r.w; x++) {
        owner[(x, y)] = i;
      }
    }
  }

  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null) continue;
    // Port-connection checks only apply to track pieces.
    if (def.category != BlockCategory.track) continue;
    final p = placements[i];

    for (var pi = 0; pi < def.ports.length; pi++) {
      final port = def.ports[pi];
      for (final dir in portOutwardDirections(def, port)) {
        final outward = portOutwardCells(p.gridX, p.gridY, port, dir);

        // Which neighbor placements cover the outward cells, and how many
        // cells each covers.
        final coverage = <int, int>{};
        for (final cell in outward) {
          final o = owner[cell];
          if (o != null && o != i) {
            coverage[o] = (coverage[o] ?? 0) + 1;
          }
        }

        if (coverage.isEmpty) {
          diagnostics.add(LevelDiagnostic(
            severity: DiagnosticSeverity.warning,
            message:
                '${p.blockId}: ${dir.jsonValue} port (span ${port.span}) '
                'is not connected',
            placementIndex: i,
            gridX: outward.first.$1,
            gridY: outward.first.$2,
          ));
          continue;
        }

        // A clean connection: exactly one neighbor covers ALL outward
        // cells, and that neighbor has a port facing back with equal span.
        final single =
            coverage.length == 1 && coverage.values.first == outward.length;
        final neighborIndex = coverage.keys.first;
        if (!single) {
          diagnostics.add(LevelDiagnostic(
            severity: DiagnosticSeverity.error,
            message: '${p.blockId}: ${dir.jsonValue} port is misaligned '
                '(partial or split contact with a neighbor)',
            placementIndex: i,
            gridX: outward.first.$1,
            gridY: outward.first.$2,
          ));
          continue;
        }

        if (!_neighborFacesBack(
          placements: placements,
          rects: rects,
          defOf: defOf,
          neighborIndex: neighborIndex,
          sourceOutwardCells: outward,
          needed: dir.opposite,
          span: port.span,
        )) {
          diagnostics.add(LevelDiagnostic(
            severity: DiagnosticSeverity.error,
            message: '${p.blockId}: ${dir.jsonValue} port (span ${port.span}) '
                'connects to ${placements[neighborIndex].blockId} but no '
                'matching ${dir.opposite.jsonValue} port of the same span '
                'faces back',
            placementIndex: i,
            gridX: outward.first.$1,
            gridY: outward.first.$2,
          ));
        }
      }
    }
  }

  // Check if control lines (left and right boundaries) touch/intersect track drivable area
  final seams = findSeams(placements, defOf);
  final controlPoints = generateControlPoints(
    placements: placements,
    defOf: defOf,
    seams: seams,
    manualOffsets: manualControlPointOffsets,
    userInsertedPoints: userInsertedPoints,
  );
  final runs = findTrackRuns(placements, defOf, seams);
  final cpMap = {for (final cp in controlPoints) cp.id: cp};

  final trackPolygons = <(int placementIndex, List<Vec2> vertices)>[];
  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null || def.category != BlockCategory.track) continue;
    if (def.physicsTrackArea.isEmpty) continue;

    final originX = placements[i].gridX * 16.0;
    final originY = placements[i].gridY * 16.0;
    final worldVertices = def.physicsTrackArea
        .map((v) => Vec2(originX + v.x, originY + v.y))
        .toList();
    trackPolygons.add((i, worldVertices));
  }

  void checkSegments(List<(Vec2, Vec2)> segments, String lineName) {
    for (final (p1, p2) in segments) {
      final mid = Vec2((p1.x + p2.x) * 0.5, (p1.y + p2.y) * 0.5);
      for (final (placementIndex, poly) in trackPolygons) {
        if (_isPointStrictlyInside(p1, poly) ||
            _isPointStrictlyInside(p2, poly) ||
            _isPointStrictlyInside(mid, poly)) {
          final placement = placements[placementIndex];
          diagnostics.add(LevelDiagnostic(
            severity: DiagnosticSeverity.error,
            message: 'Control line ($lineName) touches track area',
            placementIndex: placementIndex,
            gridX: placement.gridX,
            gridY: placement.gridY,
          ));
          break;
        }

        var intersects = false;
        final n = poly.length;
        for (var j = 0; j < n; j++) {
          final q1 = poly[j];
          final q2 = poly[(j + 1) % n];
          if (_segmentsIntersectStrictly(p1, p2, q1, q2)) {
            intersects = true;
            break;
          }
        }

        if (intersects) {
          final placement = placements[placementIndex];
          diagnostics.add(LevelDiagnostic(
            severity: DiagnosticSeverity.error,
            message: 'Control line ($lineName) touches track area',
            placementIndex: placementIndex,
            gridX: placement.gridX,
            gridY: placement.gridY,
          ));
          break;
        }
      }
    }
  }

  for (final run in runs) {
    if (run.placementIndices.isEmpty) continue;

    Vec2 getSeamBoundaryPos(
      int idx,
      int portIdx,
      PortDirection outDir,
      BoundarySide side,
    ) {
      final autoId = "auto_${idx}_${portIdx}_${side.name}";
      final customCp = cpMap[autoId];
      if (customCp != null) {
        return customCp.position;
      }
      final placement = placements[idx];
      final def = defOf(placement.blockId)!;
      final port = def.ports[portIdx];
      final (defaultLeft, defaultRight) = computePortBoundaryPoints(placement, port, outDir, def);
      return side == BoundarySide.left ? defaultLeft : defaultRight;
    }

    for (var i = 0; i < run.placementIndices.length; i++) {
      final idx = run.placementIndices[i];
      final def = defOf(placements[idx].blockId)!;

      // Identify entry and exit transitions for this block
      TrackSeamTransition? entryTrans;
      TrackSeamTransition? exitTrans;

      if (run.isLoop) {
        entryTrans = run.transitions[(i - 1 + run.transitions.length) % run.transitions.length];
        exitTrans = run.transitions[i];
      } else {
        if (i > 0) entryTrans = run.transitions[i - 1];
        if (i < run.transitions.length) exitTrans = run.transitions[i];
      }

      // 1. Entry Boundary Points
      Vec2 entryLeft;
      Vec2 entryRight;
      if (entryTrans != null) {
        final portIdx = entryTrans.toIndex == idx ? entryTrans.toPort : entryTrans.fromPort;
        final outDir = entryTrans.toIndex == idx ? entryTrans.seam.dir.opposite : entryTrans.seam.dir;
        entryLeft = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.right);
        entryRight = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.left);
      } else {
        final connectedPort = exitTrans?.fromPort;
        final openPortIdx = (exitTrans == null) ? 0 : ((connectedPort == 0) ? 1 : 0);
        final port = def.ports[openPortIdx];
        final outDir = port.direction;
        final (defaultLeft, defaultRight) = computePortBoundaryPoints(placements[idx], port, outDir, def);
        entryLeft = defaultRight;
        entryRight = defaultLeft;
      }

      // 2. Exit Boundary Points
      Vec2 exitLeft;
      Vec2 exitRight;
      if (exitTrans != null) {
        final portIdx = exitTrans.fromIndex == idx ? exitTrans.fromPort : exitTrans.toPort;
        final outDir = exitTrans.fromIndex == idx ? exitTrans.seam.dir : exitTrans.seam.dir.opposite;
        exitLeft = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.left);
        exitRight = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.right);
      } else {
        final connectedPort = entryTrans?.toPort;
        final openPortIdx = (entryTrans == null) ? 1 : ((connectedPort == 0) ? 1 : 0);
        final port = def.ports[openPortIdx];
        final outDir = port.direction;
        final (defaultLeft, defaultRight) = computePortBoundaryPoints(placements[idx], port, outDir, def);
        exitLeft = defaultLeft;
        exitRight = defaultRight;
      }

      // ONLY validate segments on straight blocks
      if (isStraightBlock(def)) {
        final leftSegments = <(Vec2, Vec2)>[];
        final rightSegments = <(Vec2, Vec2)>[];

        // Left side user-inserted points
        final leftUsers = controlPoints
            .where((cp) => !cp.isAuto && cp.placementIndex == idx && cp.side == BoundarySide.left)
            .toList()
          ..sort((a, b) => (a.edgeT ?? 0.0).compareTo(b.edgeT ?? 0.0));

        var prevL = entryLeft;
        for (final cp in leftUsers) {
          final defaultPos = entryLeft + (exitLeft - entryLeft).scale(cp.edgeT ?? 0.0);
          final (leftVec, _) = perpendicularDirections(def.ports[1].direction);
          final cpPos = defaultPos + leftVec.scale(cp.offset);
          leftSegments.add((prevL, cpPos));
          prevL = cpPos;
        }
        leftSegments.add((prevL, exitLeft));

        // Right side user-inserted points
        final rightUsers = controlPoints
            .where((cp) => !cp.isAuto && cp.placementIndex == idx && cp.side == BoundarySide.right)
            .toList()
          ..sort((a, b) => (a.edgeT ?? 0.0).compareTo(b.edgeT ?? 0.0));

        var prevR = entryRight;
        for (final cp in rightUsers) {
          final defaultPos = entryRight + (exitRight - entryRight).scale(cp.edgeT ?? 0.0);
          final (_, rightVec) = perpendicularDirections(def.ports[1].direction);
          final cpPos = defaultPos + rightVec.scale(cp.offset);
          rightSegments.add((prevR, cpPos));
          prevR = cpPos;
        }
        rightSegments.add((prevR, exitRight));

        checkSegments(leftSegments, 'left');
        checkSegments(rightSegments, 'right');
      }
    }
  }

  diagnostics.sort((a, b) => a.severity.index.compareTo(b.severity.index));
  return diagnostics;
}

bool _isPointInsidePolygon(Vec2 p, List<Vec2> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  final n = polygon.length;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    final vi = polygon[i];
    final vj = polygon[j];
    if (((vi.y > p.y) != (vj.y > p.y)) &&
        (p.x < (vj.x - vi.x) * (p.y - vi.y) / (vj.y - vi.y) + vi.x)) {
      inside = !inside;
    }
  }
  return inside;
}

double _distancePointToSegment(Vec2 p, Vec2 a, Vec2 b) {
  final ab = b - a;
  final ap = p - a;
  final abLenSq = ab.x * ab.x + ab.y * ab.y;
  if (abLenSq == 0) return math.sqrt(ap.x * ap.x + ap.y * ap.y);
  var t = (ap.x * ab.x + ap.y * ab.y) / abLenSq;
  t = t.clamp(0.0, 1.0);
  final proj = a + ab.scale(t);
  final diff = p - proj;
  return math.sqrt(diff.x * diff.x + diff.y * diff.y);
}

bool _isPointStrictlyInside(Vec2 p, List<Vec2> polygon) {
  if (!_isPointInsidePolygon(p, polygon)) return false;
  final n = polygon.length;
  for (var i = 0; i < n; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % n];
    if (_distancePointToSegment(p, a, b) < 0.1) {
      return false;
    }
  }
  return true;
}

int _orientation(Vec2 p, Vec2 q, Vec2 r) {
  final value = (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y);
  if (value == 0) return 0;
  return value > 0 ? 1 : 2;
}

bool _segmentsIntersectStrictly(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
  if (a == c || a == d || b == c || b == d) return false;

  final o1 = _orientation(a, b, c);
  final o2 = _orientation(a, b, d);
  final o3 = _orientation(c, d, a);
  final o4 = _orientation(c, d, b);

  if (o1 != o2 && o3 != o4) {
    return true;
  }
  return false;
}

/// Live diagnostics for the current level, recomputed whenever the
/// placements or the loaded library change.
final levelDiagnosticsProvider =
    Provider.family<List<LevelDiagnostic>, int>((ref, tabId) {
  final state = ref.watch(levelEditorProvider(tabId));
  final library = ref.watch(assetLibraryProvider);
  return validateLevel(
    state.placements,
    library.blockById,
    manualControlPointOffsets: state.manualControlPointOffsets,
    userInsertedPoints: state.userInsertedPoints,
  );
});

/// Whether [neighborIndex] has a port facing [needed] with matching [span]
/// whose own strip sits exactly on the source's outward cells (i.e. the
/// two ports line up cell for cell).
bool _neighborFacesBack({
  required List<BlockPlacement> placements,
  required List<CellRect?> rects,
  required BlockDef? Function(String id) defOf,
  required int neighborIndex,
  required List<(int, int)> sourceOutwardCells,
  required PortDirection needed,
  required int span,
}) {
  final np = placements[neighborIndex];
  final ndef = defOf(np.blockId);
  if (ndef == null) return false;
  final target = sourceOutwardCells.toSet();

  for (final nPort in ndef.ports) {
    if (nPort.span != span) continue;
    if (!portOutwardDirections(ndef, nPort).contains(needed)) continue;
    // The neighbor port's own strip cells must equal the source outward
    // cells for a flush, aligned connection.
    final (ew, eh) = nPort.cellExtent;
    final strip = <(int, int)>{};
    for (var k = 0; k < ew * eh; k++) {
      strip.add((
        np.gridX + nPort.localGridX + (ew > 1 ? k : 0),
        np.gridY + nPort.localGridY + (eh > 1 ? k : 0),
      ));
    }
    if (strip.length == target.length && strip.containsAll(target)) {
      return true;
    }
  }
  return false;
}
