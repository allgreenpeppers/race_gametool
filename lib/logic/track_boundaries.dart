import 'dart:math' as math;
import '../models/block_def.dart';
import '../models/geometry.dart';
import '../models/port.dart';
import '../models/map_scene.dart';
import '../models/control_point.dart';
import 'track_topology.dart';

class TrackSeamTransition {
  const TrackSeamTransition({
    required this.fromIndex,
    required this.fromPort,
    required this.toIndex,
    required this.toPort,
    required this.seam,
  });

  final int fromIndex;
  final int fromPort;
  final int toIndex;
  final int toPort;
  final Seam seam;
}

class TrackRun {
  const TrackRun({
    required this.placementIndices,
    required this.transitions,
    required this.isLoop,
  });

  final List<int> placementIndices;
  final List<TrackSeamTransition> transitions;
  final bool isLoop;
}

/// Classifies if a block is straight (exactly 2 ports facing opposite directions).
bool isStraightBlock(BlockDef def) {
  if (def.ports.length != 2) return false;
  final dir1 = def.ports[0].direction;
  final dir2 = def.ports[1].direction;
  return dir1 == dir2.opposite;
}

/// Classifies if a block is a corner (exactly 2 ports facing non-opposite directions).
bool isCornerBlock(BlockDef def) {
  if (def.ports.length != 2) return false;
  final dir1 = def.ports[0].direction;
  final dir2 = def.ports[1].direction;
  return dir1 != dir2.opposite;
}

/// Returns the left and right perpendicular unit vectors relative to a port direction.
/// Screen space (y down, x right).
(Vec2, Vec2) perpendicularDirections(PortDirection dir) {
  final angle = dir.angle;
  final leftAngle = angle - math.pi / 2;
  final rightAngle = angle + math.pi / 2;
  return (
    Vec2(math.cos(leftAngle), math.sin(leftAngle)),
    Vec2(math.cos(rightAngle), math.sin(rightAngle)),
  );
}

/// Computes the default boundary points of a port, aligning with physical hard walls when available.
(Vec2, Vec2) computePortBoundaryPoints(
  BlockPlacement placement,
  Port port,
  PortDirection dir,
  BlockDef? def,
) {
  final originX = placement.gridX;
  final originY = placement.gridY;
  final (ew, eh) = port.cellExtent;
  final sx = originX + port.localGridX;
  final sy = originY + port.localGridY;

  // Center of the port cells (in pixels, 16px per cell)
  final portCellsCenter = Vec2(
    (sx + ew / 2.0) * 16.0,
    (sy + eh / 2.0) * 16.0,
  );

  // Offset to the outer edge of the port cells along the outward direction (normalized)
  final (dx, dy) = dir.gridDelta;
  final double dirLength = math.sqrt(dx * dx + dy * dy);
  final double ndx = dx / dirLength;
  final double ndy = dy / dirLength;
  final seamCenter = portCellsCenter + Vec2(ndx * 8.0, ndy * 8.0);

  // Perpendicular directions
  final (leftVec, rightVec) = perpendicularDirections(dir);

  Vec2? leftPoint;
  Vec2? rightPoint;

  if (def != null && def.physicsHardWalls.isNotEmpty) {
    // Attempt to locate wall vertices on the port seam
    final (lVec, rVec) = (leftVec, rightVec);
    final localPortCenter = Vec2(
      (port.localGridX + ew / 2.0) * 16.0,
      (port.localGridY + eh / 2.0) * 16.0,
    );
    final localSeamCenter = localPortCenter + Vec2(ndx * 8.0, ndy * 8.0);

    Vec2? bestL;
    double bestDotL = -1.0;
    Vec2? bestR;
    double bestDotR = -1.0;

    for (final wall in def.physicsHardWalls) {
      for (final v in wall) {
        final toV = v - localSeamCenter;
        final distToSeam = (toV.x * ndx + toV.y * ndy).abs();
        if (distToSeam < 2.0) {
          final dotL = toV.x * lVec.x + toV.y * lVec.y;
          if (dotL > 0.0) {
            if (bestL == null || (dotL - (port.span * 8.0)).abs() < (bestDotL - (port.span * 8.0)).abs()) {
              bestL = v;
              bestDotL = dotL;
            }
          }
          final dotR = toV.x * rVec.x + toV.y * rVec.y;
          if (dotR > 0.0) {
            if (bestR == null || (dotR - (port.span * 8.0)).abs() < (bestDotR - (port.span * 8.0)).abs()) {
              bestR = v;
              bestDotR = dotR;
            }
          }
        }
      }
    }

    if (bestL != null) {
      leftPoint = Vec2(originX * 16.0 + bestL.x, originY * 16.0 + bestL.y);
    }
    if (bestR != null) {
      rightPoint = Vec2(originX * 16.0 + bestR.x, originY * 16.0 + bestR.y);
    }
  }

  // Fallback to default port span bounds if wall vertices are not found
  final halfWidth = (port.span * 16.0) / 2.0;
  leftPoint ??= seamCenter + leftVec.scale(halfWidth);
  rightPoint ??= seamCenter + rightVec.scale(halfWidth);

  return (leftPoint, rightPoint);
}

/// Traverses the connected track blocks to identify runs.
List<TrackRun> findTrackRuns(
  List<BlockPlacement> placements,
  BlockDef? Function(String id) defOf,
  List<Seam> seams,
) {
  final conn = <(int, int), (int, int)>{};
  for (final s in seams) {
    conn[(s.nearIndex, s.nearPortIndex)] = (s.farIndex, s.farPortIndex);
  }

  final visited = <int>{};
  final runs = <TrackRun>[];

  final trackIndices = <int>[];
  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def != null && def.category == BlockCategory.track) {
      trackIndices.add(i);
    }
  }

  for (final startIdx in trackIndices) {
    if (visited.contains(startIdx)) continue;

    final def = defOf(placements[startIdx].blockId)!;
    if (def.ports.length != 2) continue;

    // Walk forward from port 1
    final forward = <TrackSeamTransition>[];
    final forwardBlocks = [startIdx];
    int curr = startIdx;
    int outPort = 1;
    bool isLoop = false;
    final runVisited = {startIdx};

    while (true) {
      final target = conn[(curr, outPort)];
      if (target == null) break;
      final (nextIdx, inPort) = target;

      final nextDef = defOf(placements[nextIdx].blockId);
      if (nextDef == null || nextDef.ports.length != 2) break;

      final seam = seams.firstWhere(
        (s) =>
            s.nearIndex == curr &&
            s.nearPortIndex == outPort &&
            s.farIndex == nextIdx &&
            s.farPortIndex == inPort,
      );

      final transition = TrackSeamTransition(
        fromIndex: curr,
        fromPort: outPort,
        toIndex: nextIdx,
        toPort: inPort,
        seam: seam,
      );
      forward.add(transition);

      if (runVisited.contains(nextIdx)) {
        if (nextIdx == startIdx) {
          isLoop = true;
        }
        break;
      }

      runVisited.add(nextIdx);
      forwardBlocks.add(nextIdx);
      curr = nextIdx;
      outPort = (inPort == 0) ? 1 : 0;
    }

    if (isLoop) {
      visited.addAll(runVisited);
      runs.add(TrackRun(
        placementIndices: forwardBlocks,
        transitions: forward,
        isLoop: true,
      ));
      continue;
    }

    // Walk backward from startIdx port 0
    final backward = <TrackSeamTransition>[];
    final backwardBlocks = <int>[];
    curr = startIdx;
    int inPort = 0;

    while (true) {
      final target = conn[(curr, inPort)];
      if (target == null) break;
      final (prevIdx, prevOutPort) = target;

      final prevDef = defOf(placements[prevIdx].blockId);
      if (prevDef == null || prevDef.ports.length != 2) break;

      if (runVisited.contains(prevIdx)) break;

      final seam = seams.firstWhere(
        (s) =>
            s.nearIndex == prevIdx &&
            s.nearPortIndex == prevOutPort &&
            s.farIndex == curr &&
            s.farPortIndex == inPort,
      );

      final transition = TrackSeamTransition(
        fromIndex: prevIdx,
        fromPort: prevOutPort,
        toIndex: curr,
        toPort: inPort,
        seam: seam,
      );
      backward.insert(0, transition);

      runVisited.add(prevIdx);
      backwardBlocks.insert(0, prevIdx);
      curr = prevIdx;
      inPort = (prevOutPort == 0) ? 1 : 0;
    }

    visited.addAll(runVisited);
    runs.add(TrackRun(
      placementIndices: [...backwardBlocks, ...forwardBlocks],
      transitions: [...backward, ...forward],
      isLoop: false,
    ));
  }

  return runs;
}

/// Generates all control points (both auto-generated and manual) for a level.
List<ControlPoint> generateControlPoints({
  required List<BlockPlacement> placements,
  required BlockDef? Function(String id) defOf,
  required List<Seam> seams,
  required Map<String, double> manualOffsets,
  required List<ControlPoint> userInsertedPoints,
}) {
  final autoPoints = <ControlPoint>[];
  final runs = findTrackRuns(placements, defOf, seams);

  for (final run in runs) {
    for (final trans in run.transitions) {
      final idxA = trans.fromIndex;
      final idxB = trans.toIndex;
      final defA = defOf(placements[idxA].blockId)!;
      final defB = defOf(placements[idxB].blockId)!;

      final isAStraight = isStraightBlock(defA);
      final isBStraight = isStraightBlock(defB);

      // Rule: Auto-placement at straight-to-corner meets
      if ((isAStraight && !isBStraight) || (!isAStraight && isBStraight)) {
        final straightIdx = isAStraight ? idxA : idxB;
        final straightPortIdx = isAStraight ? trans.fromPort : trans.toPort;
        final straightPlacement = placements[straightIdx];
        final straightDef = defOf(straightPlacement.blockId)!;
        final port = straightDef.ports[straightPortIdx];

        // Traverse direction at the seam
        final traverseDir = trans.seam.dir;
        // Direction outward from the straight piece
        final outDir = isAStraight ? traverseDir : traverseDir.opposite;

        // Base points
        final (defaultLeft, defaultRight) = computePortBoundaryPoints(
          straightPlacement,
          port,
          outDir,
          straightDef,
        );

        // Perpendicular unit directions
        final (leftVec, rightVec) = perpendicularDirections(outDir);

        final leftId = "auto_${straightIdx}_${straightPortIdx}_left";
        final rightId = "auto_${straightIdx}_${straightPortIdx}_right";

        autoPoints.add(ControlPoint(
          id: leftId,
          baseX: defaultLeft.x,
          baseY: defaultLeft.y,
          dirX: leftVec.x,
          dirY: leftVec.y,
          offset: manualOffsets[leftId] ?? 0.0,
          isAuto: true,
          seamNearIndex: idxA,
          seamFarIndex: idxB,
        ));

        autoPoints.add(ControlPoint(
          id: rightId,
          baseX: defaultRight.x,
          baseY: defaultRight.y,
          dirX: rightVec.x,
          dirY: rightVec.y,
          offset: manualOffsets[rightId] ?? 0.0,
          isAuto: true,
          seamNearIndex: idxA,
          seamFarIndex: idxB,
        ));
      }
    }
  }

  return [...autoPoints, ...userInsertedPoints];
}

/// Builds the final continuous polyline boundaries (Left and Right) for all track runs.
Map<String, List<List<Vec2>>> buildBoundaryPolylines({
  required List<BlockPlacement> placements,
  required BlockDef? Function(String id) defOf,
  required List<Seam> seams,
  required List<ControlPoint> controlPoints,
}) {
  final runs = findTrackRuns(placements, defOf, seams);
  final leftLines = <List<Vec2>>[];
  final rightLines = <List<Vec2>>[];

  // Quick lookup maps for control points
  final cpMap = {for (final cp in controlPoints) cp.id: cp};

  for (final run in runs) {
    if (run.placementIndices.isEmpty) continue;

    final leftPoints = <Vec2>[];
    final rightPoints = <Vec2>[];

    // Helper to resolve the position of a seam boundary side
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

      // Default virtual point if no auto control point is generated at this seam
      final placement = placements[idx];
      final def = defOf(placement.blockId)!;
      final port = def.ports[portIdx];
      final (defaultLeft, defaultRight) = computePortBoundaryPoints(placement, port, outDir, def);
      return side == BoundarySide.left ? defaultLeft : defaultRight;
    }

    // Walk sequentially through placements in the run
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
      Vec2? entryLeft;
      Vec2? entryRight;
      if (entryTrans != null) {
        final portIdx = entryTrans.toIndex == idx ? entryTrans.toPort : entryTrans.fromPort;
        final outDir = entryTrans.toIndex == idx ? entryTrans.seam.dir.opposite : entryTrans.seam.dir;
        // Entry port faces opposite to traversal direction, so swap left/right sides
        entryLeft = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.right);
        entryRight = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.left);
      } else {
        // First block of an open strip: use its open port if it exists
        // Since def.ports.length == 2, the open port is the one not connected by exitTrans
        final connectedPort = exitTrans?.fromPort;
        final openPortIdx = (exitTrans == null) ? 0 : ((connectedPort == 0) ? 1 : 0);
        final port = def.ports[openPortIdx];
        final outDir = port.direction; // outward from block
        final (defaultLeft, defaultRight) = computePortBoundaryPoints(placements[idx], port, outDir, def);
        // Entry port faces opposite to traversal direction, so swap left/right sides
        entryLeft = defaultRight;
        entryRight = defaultLeft;
      }

      // 2. Exit Boundary Points
      Vec2? exitLeft;
      Vec2? exitRight;
      if (exitTrans != null) {
        final portIdx = exitTrans.fromIndex == idx ? exitTrans.fromPort : exitTrans.toPort;
        final outDir = exitTrans.fromIndex == idx ? exitTrans.seam.dir : exitTrans.seam.dir.opposite;
        // Exit port faces in traversal direction, so left/right sides do not swap
        exitLeft = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.left);
        exitRight = getSeamBoundaryPos(idx, portIdx, outDir, BoundarySide.right);
      } else {
        // Last block of an open strip: use its open port
        final connectedPort = entryTrans?.toPort;
        final openPortIdx = (entryTrans == null) ? 1 : ((connectedPort == 0) ? 1 : 0);
        final port = def.ports[openPortIdx];
        final outDir = port.direction;
        final (defaultLeft, defaultRight) = computePortBoundaryPoints(placements[idx], port, outDir, def);
        // Exit port faces in traversal direction, so left/right sides do not swap
        exitLeft = defaultLeft;
        exitRight = defaultRight;
      }

      // Add entry points (if not already added from previous exit)
      if (leftPoints.isEmpty || (leftPoints.last - entryLeft).hashCode != 0) {
        leftPoints.add(entryLeft);
        rightPoints.add(entryRight);
      }

      // 3. User Inserted Points on this block's edges (if straight)
      if (isStraightBlock(def)) {
        // Left side user-inserted points
        final leftUsers = controlPoints
            .where((cp) => !cp.isAuto && cp.placementIndex == idx && cp.side == BoundarySide.left)
            .toList()
          ..sort((a, b) => (a.edgeT ?? 0.0).compareTo(b.edgeT ?? 0.0));

        for (final cp in leftUsers) {
          // Recompute position dynamically in case the straight block moved or was updated
          final defaultPos = entryLeft + (exitLeft - entryLeft).scale(cp.edgeT ?? 0.0);
          final (leftVec, _) = perpendicularDirections(def.ports[1].direction); // direction of exit
          final cpPos = defaultPos + leftVec.scale(cp.offset);
          leftPoints.add(cpPos);
        }

        // Right side user-inserted points
        final rightUsers = controlPoints
            .where((cp) => !cp.isAuto && cp.placementIndex == idx && cp.side == BoundarySide.right)
            .toList()
          ..sort((a, b) => (a.edgeT ?? 0.0).compareTo(b.edgeT ?? 0.0));

        for (final cp in rightUsers) {
          final defaultPos = entryRight + (exitRight - entryRight).scale(cp.edgeT ?? 0.0);
          final (_, rightVec) = perpendicularDirections(def.ports[1].direction);
          final cpPos = defaultPos + rightVec.scale(cp.offset);
          rightPoints.add(cpPos);
        }
      }

      // Add exit points
      leftPoints.add(exitLeft);
      rightPoints.add(exitRight);
    }

    if (run.isLoop && leftPoints.isNotEmpty) {
      // Connect back to start
      leftPoints.add(leftPoints.first);
      rightPoints.add(rightPoints.first);
    }

    leftLines.add(leftPoints);
    rightLines.add(rightPoints);
  }

  return {
    'left': leftLines,
    'right': rightLines,
  };
}
