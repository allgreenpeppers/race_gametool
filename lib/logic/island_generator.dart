import 'dart:collection';
import 'dart:math';

import '../models/map_scene.dart';
import '../models/port.dart';
import 'island_tiles.dart';

/// Auto island generation. A grass region is grown outward from the track
/// footprint, then every grass cell is matched to an island tile by its
/// 8-neighbour grass configuration (the same 8-direction signature the
/// tiles are marked with in Phase 1).

/// Grows [footprint] outward by [padding] cells (4-neighbour BFS = a
/// rounded diamond) within the grid bounds, then smooths once to shave off
/// single-cell spikes. Returns a rows x cols grid of 0 (water) / 1 (grass).
List<List<int>> dilateRegion(
  Set<(int, int)> footprint, {
  required int cols,
  required int rows,
  required int padding,
}) {
  final grid = List.generate(rows, (_) => List.filled(cols, 0));
  final queue = Queue<(int, int, int)>();
  for (final (x, y) in footprint) {
    if (x < 0 || y < 0 || x >= cols || y >= rows) continue;
    if (grid[y][x] == 0) {
      grid[y][x] = 1;
      queue.add((x, y, 0));
    }
  }
  const steps = [(1, 0), (-1, 0), (0, 1), (0, -1)];
  while (queue.isNotEmpty) {
    final (x, y, d) = queue.removeFirst();
    if (d >= padding) continue;
    for (final (dx, dy) in steps) {
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
      if (grid[ny][nx] == 0) {
        grid[ny][nx] = 1;
        queue.add((nx, ny, d + 1));
      }
    }
  }
  return _smooth(grid, cols, rows);
}

/// One cellular-automata pass: fill a water cell surrounded by >= 5 grass
/// neighbours, and carve a grass cell with <= 2 grass neighbours. Rounds
/// the coastline so it fits the convex/edge/corner tile set.
List<List<int>> _smooth(List<List<int>> grid, int cols, int rows) {
  int grassNeighbours(int x, int y) {
    var n = 0;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx >= 0 && ny >= 0 && nx < cols && ny < rows && grid[ny][nx] == 1) {
          n++;
        }
      }
    }
    return n;
  }

  final out = List.generate(rows, (y) => List<int>.from(grid[y]));
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      final n = grassNeighbours(x, y);
      if (grid[y][x] == 0 && n >= 5) {
        out[y][x] = 1;
      } else if (grid[y][x] == 1 && n <= 2) {
        out[y][x] = 0;
      }
    }
  }
  return out;
}

/// Fills water pockets fully enclosed by grass, so the autotiled island is
/// always solid. Any water cell that cannot reach the grid border through
/// water is landlocked inside the island and becomes grass. The coastline
/// itself is untouched, so a concave outline survives -- only true interior
/// holes (e.g. the middle of a track loop) are filled.
List<List<int>> fillEnclosedWater(List<List<int>> grid) {
  final rows = grid.length;
  final cols = rows == 0 ? 0 : grid[0].length;
  if (rows == 0 || cols == 0) return grid;
  final reachable = List.generate(rows, (_) => List.filled(cols, false));
  final queue = Queue<(int, int)>();
  void seed(int x, int y) {
    if (grid[y][x] == 0 && !reachable[y][x]) {
      reachable[y][x] = true;
      queue.add((x, y));
    }
  }

  for (var x = 0; x < cols; x++) {
    seed(x, 0);
    seed(x, rows - 1);
  }
  for (var y = 0; y < rows; y++) {
    seed(0, y);
    seed(cols - 1, y);
  }
  const steps = [(1, 0), (-1, 0), (0, 1), (0, -1)];
  while (queue.isNotEmpty) {
    final (x, y) = queue.removeFirst();
    for (final (dx, dy) in steps) {
      final nx = x + dx;
      final ny = y + dy;
      if (nx < 0 || ny < 0 || nx >= cols || ny >= rows) continue;
      seed(nx, ny);
    }
  }
  return [
    for (var y = 0; y < rows; y++)
      [
        for (var x = 0; x < cols; x++)
          grid[y][x] == 1 || !reachable[y][x] ? 1 : 0,
      ],
  ];
}

bool _grass(List<List<int>> grid, int x, int y, int cols, int rows) =>
    x >= 0 && y >= 0 && x < cols && y < rows && grid[y][x] == 1;

/// The canonical 8-direction signature of a grass cell: a cardinal is set
/// when that neighbour is grass; a diagonal is set only when the diagonal
/// neighbour AND both of its adjacent cardinals are grass (so a diagonal
/// counts only across a filled corner). This maps a smooth region onto the
/// interior / edge / convex / concave tile kinds.
DirSet cellSignature(List<List<int>> grid, int x, int y, int cols, int rows) {
  bool g(int nx, int ny) => _grass(grid, nx, ny, cols, rows);
  final up = g(x, y - 1);
  final down = g(x, y + 1);
  final left = g(x - 1, y);
  final right = g(x + 1, y);
  final sig = <PortDirection>{};
  if (up) sig.add(PortDirection.up);
  if (down) sig.add(PortDirection.down);
  if (left) sig.add(PortDirection.left);
  if (right) sig.add(PortDirection.right);
  if (up && right && g(x + 1, y - 1)) sig.add(PortDirection.diagUR);
  if (up && left && g(x - 1, y - 1)) sig.add(PortDirection.diagUL);
  if (down && right && g(x + 1, y + 1)) sig.add(PortDirection.diagDR);
  if (down && left && g(x - 1, y + 1)) sig.add(PortDirection.diagDL);
  return sig;
}

/// Signature of a grass cell computed directly from a cell set (for
/// incremental retiling), matching [cellSignature]'s canonical rules.
DirSet cellSignatureFromSet(Set<(int, int)> grass, int x, int y) {
  bool g(int nx, int ny) => grass.contains((nx, ny));
  final up = g(x, y - 1);
  final down = g(x, y + 1);
  final left = g(x - 1, y);
  final right = g(x + 1, y);
  final sig = <PortDirection>{};
  if (up) sig.add(PortDirection.up);
  if (down) sig.add(PortDirection.down);
  if (left) sig.add(PortDirection.left);
  if (right) sig.add(PortDirection.right);
  if (up && right && g(x + 1, y - 1)) sig.add(PortDirection.diagUR);
  if (up && left && g(x - 1, y - 1)) sig.add(PortDirection.diagUL);
  if (down && right && g(x + 1, y + 1)) sig.add(PortDirection.diagDR);
  if (down && left && g(x - 1, y + 1)) sig.add(PortDirection.diagDL);
  return sig;
}

class IslandAutotileResult {
  const IslandAutotileResult({
    required this.placements,
    required this.unmatched,
  });

  final List<BlockPlacement> placements;

  /// Grass cells whose configuration had no matching tile (the tile set is
  /// incomplete for this region's shape).
  final int unmatched;
}

/// Places an island tile on every grass cell, choosing (at random when a
/// signature has several tiles) from [tileIdsBySignature] keyed by
/// [sigKey]. Cells with no matching tile are counted in [unmatched].
IslandAutotileResult autotileIsland({
  required List<List<int>> grid,
  required Map<String, List<String>> tileIdsBySignature,
  Random? random,
}) {
  final rng = random ?? Random();
  final rows = grid.length;
  final cols = rows == 0 ? 0 : grid[0].length;
  final placements = <BlockPlacement>[];
  var unmatched = 0;
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < cols; x++) {
      if (grid[y][x] != 1) continue;
      final key = sigKey(cellSignature(grid, x, y, cols, rows));
      final ids = tileIdsBySignature[key];
      if (ids == null || ids.isEmpty) {
        unmatched++;
        continue;
      }
      final id = ids[rng.nextInt(ids.length)];
      placements.add(BlockPlacement(blockId: id, gridX: x, gridY: y));
    }
  }
  return IslandAutotileResult(placements: placements, unmatched: unmatched);
}
