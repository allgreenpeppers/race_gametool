import 'dart:math' as math;

import '../core/constants.dart';
import '../models/block_def.dart';
import '../models/geometry.dart';
import '../models/map_scene.dart';
import '../models/port.dart';
import '../models/function_layer.dart';

/// Automatically generates check lines and physical boundaries from track layouts.
class FunctionLayerGenerator {
  static const double _cell = GridConstants.cellSize; // 16.0

  /// Main entry point: automatically computes all check lines and boundaries.
  static (List<CheckLine>, List<TrackBoundary>) generate({
    required List<BlockPlacement> placements,
    required BlockDef? Function(String id) defOf,
    required FunctionLayerSettings settings,
    Set<(int, int)>? islandGrassMask,
  }) {
    final checkLines = <CheckLine>[];
    final boundaries = <TrackBoundary>[];

    // 1. Generate Check Lines per-block
    for (var i = 0; i < placements.length; i++) {
      final p = placements[i];
      final def = defOf(p.blockId);
      if (def == null || def.category != BlockCategory.track) continue;

      if (_isTurnBlock(def)) {
        final turnCheckLine = _generateTurnCheckLine(p, def);
        if (turnCheckLine != null) {
          checkLines.add(turnCheckLine);
        }
      } else if (_isStraightBlock(def)) {
        final straightCheckLines = _generateStraightCheckLines(p, def, settings);
        checkLines.addAll(straightCheckLines);
      }
    }

    // 2. Collect all track walls from placements
    final allSegments = <(Vec2, Vec2)>[];
    for (final p in placements) {
      final def = defOf(p.blockId);
      if (def == null || def.category != BlockCategory.track) continue;

      final globalOffset = Vec2(p.gridX * _cell, p.gridY * _cell);
      for (final wall in def.physicsHardWalls) {
        for (var j = 0; j < wall.length - 1; j++) {
          final a = wall[j] + globalOffset;
          final b = wall[j + 1] + globalOffset;
          allSegments.add((a, b));
        }
      }
    }

    // 3. Chain segments into loops
    final isClosedOut = <bool>[];
    final loops = _chainSegments(allSegments, isClosedOut);

    if (loops.isNotEmpty) {
      // Sort loops by absolute area descending to identify the outer loop
      final sortedIndices = List<int>.generate(loops.length, (i) => i)
        ..sort((a, b) => _signedArea(loops[b]).abs().compareTo(_signedArea(loops[a]).abs()));

      final d = settings.boundaryOffset;

      for (var idx = 0; idx < sortedIndices.length; idx++) {
        final i = sortedIndices[idx];
        final loop = loops[i];
        final closed = isClosedOut[i];
        final isOuter = idx == 0;

        if (closed) {
          if (!isOuter) {
            // Inner boundary (hole): always red antiCutRed, offset to the left (towards grass)
            final offsetLoop = _offsetPolyline(loop, d, isClosed: true);
            boundaries.add(TrackBoundary(
              vertices: offsetLoop,
              isClosed: true,
              type: 'antiCutRed',
            ));
          } else {
            // Outer boundary: check convex hull defects
            final hull = _convexHull(loop);

            // Group segments into antiCutRed (not on hull) and innerFunction (on hull)
            final concavePolylines = <List<Vec2>>[];
            final convexPolylines = <List<Vec2>>[];
            var currentConcave = <Vec2>[];
            var currentConvex = <Vec2>[];

            for (var j = 0; j < loop.length; j++) {
              final a = loop[j];
              final b = loop[(j + 1) % loop.length];
              final isConcave = !_isSegmentOnHull(a, b, hull);

              if (isConcave) {
                if (currentConvex.isNotEmpty) {
                  convexPolylines.add(currentConvex);
                  currentConvex = [];
                }
                if (currentConcave.isEmpty) {
                  currentConcave.add(a);
                }
                currentConcave.add(b);
              } else {
                if (currentConcave.isNotEmpty) {
                  concavePolylines.add(currentConcave);
                  currentConcave = [];
                }
                if (currentConvex.isEmpty) {
                  currentConvex.add(a);
                }
                currentConvex.add(b);
              }
            }
            if (currentConcave.isNotEmpty) concavePolylines.add(currentConcave);
            if (currentConvex.isNotEmpty) convexPolylines.add(currentConvex);

            // Handle wrapping
            _handleWrapping(loop, concavePolylines, (a, b) => !_isSegmentOnHull(a, b, hull));
            _handleWrapping(loop, convexPolylines, (a, b) => _isSegmentOnHull(a, b, hull));

            for (final poly in concavePolylines) {
              boundaries.add(TrackBoundary(
                vertices: _offsetPolyline(poly, d, isClosed: false),
                isClosed: false,
                type: 'antiCutRed',
              ));
            }
            for (final poly in convexPolylines) {
              boundaries.add(TrackBoundary(
                vertices: _offsetPolyline(poly, d, isClosed: false),
                isClosed: false,
                type: 'innerFunction',
              ));
            }
          }
        } else {
          // Open polyline (incomplete track during editing)
          // We split the polyline into antiCutRed (segments on turn inner walls)
          // and innerFunction (other segments).
          final antiCutPolys = <List<Vec2>>[];
          final normalPolys = <List<Vec2>>[];
          var currentAntiCut = <Vec2>[];
          var currentNormal = <Vec2>[];

          for (var j = 0; j < loop.length - 1; j++) {
            final a = loop[j];
            final b = loop[j + 1];
            final isInnerTurn = _isSegmentOnTurnInnerWall(a, b, placements, defOf);

            if (isInnerTurn) {
              if (currentNormal.isNotEmpty) {
                normalPolys.add(currentNormal);
                currentNormal = [];
              }
              if (currentAntiCut.isEmpty) {
                currentAntiCut.add(a);
              }
              currentAntiCut.add(b);
            } else {
              if (currentAntiCut.isNotEmpty) {
                antiCutPolys.add(currentAntiCut);
                currentAntiCut = [];
              }
              if (currentNormal.isEmpty) {
                currentNormal.add(a);
              }
              currentNormal.add(b);
            }
          }
          if (currentAntiCut.isNotEmpty) antiCutPolys.add(currentAntiCut);
          if (currentNormal.isNotEmpty) normalPolys.add(currentNormal);

          for (final poly in antiCutPolys) {
            boundaries.add(TrackBoundary(
              vertices: _offsetPolyline(poly, d, isClosed: false),
              isClosed: false,
              type: 'antiCutRed',
            ));
          }
          for (final poly in normalPolys) {
            boundaries.add(TrackBoundary(
              vertices: _offsetPolyline(poly, d, isClosed: false),
              isClosed: false,
              type: 'innerFunction',
            ));
          }
        }
      }
    }

    // 5. World Outer Boundary (Clings to the island boundary if available)
    final worldBoundaries = _generateWorldBoundary(placements, defOf, islandGrassMask);
    boundaries.addAll(worldBoundaries);

    return (checkLines, boundaries);
  }

  /// Determines if a block is a turn (ports are perpendicular / 90 degrees).
  static bool _isTurnBlock(BlockDef def) {
    if (def.ports.length != 2) return false;
    final dirA = def.ports[0].direction;
    final dirB = def.ports[1].direction;
    final diff = (dirA.angle - dirB.angle).abs();
    final normDiff = (diff + math.pi) % (2 * math.pi) - math.pi;
    final angleDiffDeg = (normDiff.abs() * 180 / math.pi).round();
    return angleDiffDeg == 90;
  }

  /// Determines if a block is a straight line (ports are opposite / 180 degrees).
  static bool _isStraightBlock(BlockDef def) {
    if (def.ports.length != 2) return false;
    final dirA = def.ports[0].direction;
    final dirB = def.ports[1].direction;
    final diff = (dirA.angle - dirB.angle).abs();
    final normDiff = (diff + math.pi) % (2 * math.pi) - math.pi;
    final angleDiffDeg = (normDiff.abs() * 180 / math.pi).round();
    return angleDiffDeg == 180 || angleDiffDeg == 0;
  }

  /// Generates a single check line at the apex (symmetry line) of a turn.
  static CheckLine? _generateTurnCheckLine(BlockPlacement p, BlockDef def) {
    if (def.ports.length < 2) return null;
    final portA = def.ports[0];
    final portB = def.ports[1];

    final wPx = def.boundingBox.width * _cell;
    final hPx = def.boundingBox.height * _cell;

    final dirA = portA.direction;
    final dirB = portB.direction;

    double innerX = 0;
    double innerY = 0;
    double outerX = wPx;
    double outerY = hPx;

    // Identify shared (inner) corner and opposite (outer) corner.
    if ((dirA == PortDirection.left && dirB == PortDirection.up) ||
        (dirA == PortDirection.up && dirB == PortDirection.left)) {
      innerX = 0; innerY = 0;
      outerX = wPx; outerY = hPx;
    } else if ((dirA == PortDirection.right && dirB == PortDirection.up) ||
               (dirA == PortDirection.up && dirB == PortDirection.right)) {
      innerX = wPx; innerY = 0;
      outerX = 0; outerY = hPx;
    } else if ((dirA == PortDirection.right && dirB == PortDirection.down) ||
               (dirA == PortDirection.down && dirB == PortDirection.right)) {
      innerX = wPx; innerY = hPx;
      outerX = 0; outerY = 0;
    } else if ((dirA == PortDirection.left && dirB == PortDirection.down) ||
               (dirA == PortDirection.down && dirB == PortDirection.left)) {
      innerX = 0; innerY = hPx;
      outerX = wPx; outerY = 0;
    }

    final cInner = Vec2(innerX, innerY);
    final cOuter = Vec2(outerX, outerY);

    final diagVec = cOuter - cInner;
    final diagLen = math.sqrt(diagVec.x * diagVec.x + diagVec.y * diagVec.y);
    if (diagLen == 0) return null;
    final uDiag = diagVec.scale(1.0 / diagLen);

    // Calculate radii based on port centers
    final cA = Vec2(
      (portA.localGridX + portA.cellExtent.$1 / 2.0) * _cell,
      (portA.localGridY + portA.cellExtent.$2 / 2.0) * _cell,
    );
    final centerVec = cA - cInner;
    final rCenter = math.sqrt(centerVec.x * centerVec.x + centerVec.y * centerVec.y);
    final roadWidth = portA.span * _cell;
    final rInner = rCenter - roadWidth / 2.0;
    final rOuter = rCenter + roadWidth / 2.0;

    final localP1 = cInner + uDiag.scale(rInner);
    final localP2 = cInner + uDiag.scale(rOuter);

    // Direction vector of motion at the apex (average tangent direction)
    final (adx, ady) = dirA.gridDelta;
    final vIn = Vec2(-adx.toDouble(), -ady.toDouble());
    final (bdx, bdy) = dirB.gridDelta;
    final vOut = Vec2(bdx.toDouble(), bdy.toDouble());

    final sumVec = vIn + vOut;
    final sumLen = math.sqrt(sumVec.x * sumVec.x + sumVec.y * sumVec.y);
    final uForward = sumLen > 0 ? sumVec.scale(1.0 / sumLen) : Vec2(1, 0);

    final globalOffset = Vec2(p.gridX * _cell, p.gridY * _cell);
    return CheckLine(
      p1: localP1 + globalOffset,
      p2: localP2 + globalOffset,
      forwardVector: uForward,
    );
  }

  /// Generates equidistant check lines along a straight road block.
  static List<CheckLine> _generateStraightCheckLines(
    BlockPlacement p,
    BlockDef def,
    FunctionLayerSettings settings,
  ) {
    if (def.ports.length < 2) return const [];
    final portA = def.ports[0];
    final portB = def.ports[1];

    final cA = Vec2(
      (portA.localGridX + portA.cellExtent.$1 / 2.0) * _cell,
      (portA.localGridY + portA.cellExtent.$2 / 2.0) * _cell,
    );
    final cB = Vec2(
      (portB.localGridX + portB.cellExtent.$1 / 2.0) * _cell,
      (portB.localGridY + portB.cellExtent.$2 / 2.0) * _cell,
    );

    final dirVec = cB - cA;
    final len = math.sqrt(dirVec.x * dirVec.x + dirVec.y * dirVec.y);
    if (len == 0) return const [];
    final u = dirVec.scale(1.0 / len);
    final uPerp = Vec2(-u.y, u.x);

    final roadWidth = portA.span * _cell;
    final interval = settings.straightCheckInterval;

    final list = <CheckLine>[];
    final globalOffset = Vec2(p.gridX * _cell, p.gridY * _cell);

    for (double d = interval; d < len; d += interval) {
      final pCenter = cA + u.scale(d);
      final p1 = pCenter - uPerp.scale(roadWidth / 2.0);
      final p2 = pCenter + uPerp.scale(roadWidth / 2.0);

      list.add(CheckLine(
        p1: p1 + globalOffset,
        p2: p2 + globalOffset,
        forwardVector: u,
      ));
    }

    return list;
  }

  /// Generates an outer world perimeter around the track boundary, conforming to the island shape.
  static List<TrackBoundary> _generateWorldBoundary(
    List<BlockPlacement> placements,
    BlockDef? Function(String id) defOf,
    Set<(int, int)>? islandGrassMask,
  ) {
    if (islandGrassMask != null && islandGrassMask.isNotEmpty) {
      final loops = _traceGridBoundary(islandGrassMask);
      return loops.map((loop) => TrackBoundary(
        vertices: loop,
        isClosed: true,
        type: 'outerWorld',
      )).toList();
    }

    if (placements.isEmpty) return const [];

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;

    for (final p in placements) {
      final def = defOf(p.blockId);
      if (def == null || def.category != BlockCategory.track) continue;

      final w = def.boundingBox.width * _cell;
      final h = def.boundingBox.height * _cell;
      final x = p.gridX * _cell;
      final y = p.gridY * _cell;

      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x + w > maxX) maxX = x + w;
      if (y + h > maxY) maxY = y + h;
    }

    if (minX == double.infinity) return const [];

    const voidBuffer = 128.0;
    minX -= voidBuffer;
    minY -= voidBuffer;
    maxX += voidBuffer;
    maxY += voidBuffer;

    return [
      TrackBoundary(
        vertices: [
          Vec2(minX, minY),
          Vec2(maxX, minY),
          Vec2(maxX, maxY),
          Vec2(minX, maxY),
        ],
        isClosed: true,
        type: 'outerWorld',
      )
    ];
  }

  /// Traces the grid boundary to find the precise contour of the grass tiles.
  static List<List<Vec2>> _traceGridBoundary(Set<(int, int)> grid) {
    if (grid.isEmpty) return const [];

    final edges = <((int, int), (int, int))>{};

    for (final cell in grid) {
      final x = cell.$1;
      final y = cell.$2;

      // Top edge: (x, y) -> (x+1, y)
      if (!grid.contains((x, y - 1))) {
        edges.add(((x, y), (x + 1, y)));
      }
      // Right edge: (x+1, y) -> (x+1, y+1)
      if (!grid.contains((x + 1, y))) {
        edges.add(((x + 1, y), (x + 1, y + 1)));
      }
      // Bottom edge: (x+1, y+1) -> (x, y+1)
      if (!grid.contains((x, y + 1))) {
        edges.add(((x + 1, y + 1), (x, y + 1)));
      }
      // Left edge: (x, y+1) -> (x, y)
      if (!grid.contains((x - 1, y))) {
        edges.add(((x, y + 1), (x, y)));
      }
    }

    final loops = <List<Vec2>>[];

    while (edges.isNotEmpty) {
      final startEdge = edges.first;
      edges.remove(startEdge);

      final loopCoords = <(int, int)>[startEdge.$1, startEdge.$2];
      var current = startEdge.$2;

      while (true) {
        ((int, int), (int, int))? nextEdge;
        for (final edge in edges) {
          if (edge.$1 == current) {
            nextEdge = edge;
            break;
          }
        }

        if (nextEdge != null) {
          edges.remove(nextEdge);
          current = nextEdge.$2;
          loopCoords.add(current);
        } else {
          break;
        }
      }

      if (loopCoords.length >= 3) {
        loops.add(loopCoords.map((c) => Vec2(c.$1 * 16.0, c.$2 * 16.0)).toList());
      }
    }

    return loops;
  }

  // --- Global Polygon Chaining & Offset Utilities ---

  static double _dist(Vec2 a, Vec2 b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

  static List<List<Vec2>> _chainSegments(List<(Vec2, Vec2)> segments, List<bool> isClosedOut) {
    final result = <List<Vec2>>[];
    final list = List<(Vec2, Vec2)>.from(segments);

    while (list.isNotEmpty) {
      final start = list.removeAt(0);
      final poly = <Vec2>[start.$1, start.$2];

      var extended = true;
      while (extended) {
        extended = false;

        final endPt = poly.last;
        int? nextIdx;
        for (var i = 0; i < list.length; i++) {
          final seg = list[i];
          if (_dist(seg.$1, endPt) < 1.0) {
            nextIdx = i;
            break;
          }
        }

        if (nextIdx != null) {
          final nextSeg = list.removeAt(nextIdx);
          poly.add(nextSeg.$2);
          extended = true;
        }

        final startPt = poly.first;
        int? prevIdx;
        for (var i = 0; i < list.length; i++) {
          final seg = list[i];
          if (_dist(seg.$2, startPt) < 1.0) {
            prevIdx = i;
            break;
          }
        }

        if (prevIdx != null) {
          final prevSeg = list.removeAt(prevIdx);
          poly.insert(0, prevSeg.$1);
          extended = true;
        }
      }

      if (poly.length >= 3 && _dist(poly.first, poly.last) < 1.0) {
        poly.removeLast();
        isClosedOut.add(true);
        result.add(poly);
      } else {
        isClosedOut.add(false);
        result.add(poly);
      }
    }

    return result;
  }

  static double _signedArea(List<Vec2> poly) {
    double area = 0.0;
    final n = poly.length;
    for (var i = 0; i < n; i++) {
      final p1 = poly[i];
      final p2 = poly[(i + 1) % n];
      area += p1.x * p2.y - p2.x * p1.y;
    }
    return area / 2.0;
  }

  static List<Vec2> _convexHull(List<Vec2> points) {
    if (points.length <= 3) return points;

    final sorted = List<Vec2>.from(points)
      ..sort((a, b) {
        if (a.x != b.x) return a.x.compareTo(b.x);
        return a.y.compareTo(b.y);
      });

    final lower = <Vec2>[];
    for (final p in sorted) {
      while (lower.length >= 2 &&
          _crossProduct(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }

    final upper = <Vec2>[];
    for (final p in sorted.reversed) {
      while (upper.length >= 2 &&
          _crossProduct(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }

    lower.removeLast();
    upper.removeLast();

    return [...lower, ...upper];
  }

  static double _crossProduct(Vec2 o, Vec2 a, Vec2 b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  }

  static bool _isSegmentOnHull(Vec2 a, Vec2 b, List<Vec2> hull) {
    final n = hull.length;
    for (var i = 0; i < n; i++) {
      final h1 = hull[i];
      final h2 = hull[(i + 1) % n];
      if (_isPointOnSegment(a, h1, h2) && _isPointOnSegment(b, h1, h2)) {
        return true;
      }
    }
    return false;
  }

  static bool _isPointOnSegment(Vec2 p, Vec2 s1, Vec2 s2) {
    final cross = (p.x - s1.x) * (s2.y - s1.y) - (p.y - s1.y) * (s2.x - s1.x);
    if (cross.abs() > 1e-5) return false;

    final dot = (p.x - s1.x) * (s2.x - s1.x) + (p.y - s1.y) * (s2.y - s1.y);
    if (dot < 0) return false;

    final squaredLength = (s2.x - s1.x) * (s2.x - s1.x) + (s2.y - s1.y) * (s2.y - s1.y);
    if (dot > squaredLength) return false;

    return true;
  }

  static List<Vec2> _offsetPolyline(List<Vec2> poly, double offset, {required bool isClosed}) {
    final n = poly.length;
    if (n < 2) return poly;

    final result = <Vec2>[];

    for (var i = 0; i < n; i++) {
      final curr = poly[i];

      final Vec2 u1;
      if (i > 0) {
        final prev = poly[i - 1];
        final dir = curr - prev;
        final len = math.sqrt(dir.x * dir.x + dir.y * dir.y);
        u1 = len > 0 ? dir.scale(1.0 / len) : const Vec2(1, 0);
      } else if (isClosed) {
        final prev = poly[n - 1];
        final dir = curr - prev;
        final len = math.sqrt(dir.x * dir.x + dir.y * dir.y);
        u1 = len > 0 ? dir.scale(1.0 / len) : const Vec2(1, 0);
      } else {
        final next = poly[i + 1];
        final dir = next - curr;
        final len = math.sqrt(dir.x * dir.x + dir.y * dir.y);
        final u = len > 0 ? dir.scale(1.0 / len) : const Vec2(1, 0);
        final normal = Vec2(u.y, -u.x);
        result.add(curr + normal.scale(offset));
        continue;
      }

      final Vec2 u2;
      if (i < n - 1) {
        final next = poly[i + 1];
        final dir = next - curr;
        final len = math.sqrt(dir.x * dir.x + dir.y * dir.y);
        u2 = len > 0 ? dir.scale(1.0 / len) : const Vec2(1, 0);
      } else if (isClosed) {
        final next = poly[0];
        final dir = next - curr;
        final len = math.sqrt(dir.x * dir.x + dir.y * dir.y);
        u2 = len > 0 ? dir.scale(1.0 / len) : const Vec2(1, 0);
      } else {
        final normal = Vec2(u1.y, -u1.x);
        result.add(curr + normal.scale(offset));
        continue;
      }

      final n1 = Vec2(u1.y, -u1.x);
      final n2 = Vec2(u2.y, -u2.x);
      final sum = n1 + n2;
      final len = math.sqrt(sum.x * sum.x + sum.y * sum.y);
      final normal = len > 0 ? sum.scale(1.0 / len) : n1;

      result.add(curr + normal.scale(offset));
    }

    return result;
  }

  static void _handleWrapping(List<Vec2> loop, List<List<Vec2>> polylines, bool Function(Vec2, Vec2) matches) {
    if (polylines.length >= 2) {
      final first = polylines.first;
      final last = polylines.last;

      final lastSegmentA = loop[loop.length - 1];
      final lastSegmentB = loop[0];
      final firstSegmentA = loop[0];
      final firstSegmentB = loop[1];

      if (matches(lastSegmentA, lastSegmentB) && matches(firstSegmentA, firstSegmentB)) {
        first.removeAt(0);
        final merged = [...last, ...first];
        polylines.removeLast();
        polylines[0] = merged;
      }
    }
  }

  static bool _isSegmentOnTurnInnerWall(
    Vec2 a,
    Vec2 b,
    List<BlockPlacement> placements,
    BlockDef? Function(String id) defOf,
  ) {
    for (final p in placements) {
      final def = defOf(p.blockId);
      if (def == null || def.category != BlockCategory.track || !_isTurnBlock(def)) continue;

      final globalOffset = Vec2(p.gridX * _cell, p.gridY * _cell);

      if (def.physicsHardWalls.length < 2) continue;
      final wall1 = def.physicsHardWalls[0];
      final wall2 = def.physicsHardWalls[1];

      final len1 = _wallLength(wall1);
      final len2 = _wallLength(wall2);
      final innerWall = len1 < len2 ? wall1 : wall2;

      for (var j = 0; j < innerWall.length - 1; j++) {
        final wa = innerWall[j] + globalOffset;
        final wb = innerWall[j + 1] + globalOffset;

        if ((_dist(a, wa) < 1.0 && _dist(b, wb) < 1.0) ||
            (_dist(a, wb) < 1.0 && _dist(b, wa) < 1.0)) {
          return true;
        }
      }
    }
    return false;
  }

  static double _wallLength(List<Vec2> wall) {
    double len = 0.0;
    for (var i = 0; i < wall.length - 1; i++) {
      len += _dist(wall[i], wall[i + 1]);
    }
    return len;
  }
}
