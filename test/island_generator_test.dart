import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/logic/island_generator.dart';
import 'package:race_gametool/logic/island_tiles.dart';
import 'package:race_gametool/models/port.dart';

/// Builds the signature->ids map for a complete convex tile set, one id
/// per signature named by its kind.
Map<String, List<String>> _convexTileSet() {
  final map = <String, List<String>>{};
  void add(String id, Set<PortDirection> sig) =>
      map.putIfAbsent(sigKey(sig), () => []).add(id);
  add('interior', interiorSignature);
  for (var i = 0; i < edgeSignatures.length; i++) {
    add('edge$i', edgeSignatures[i]);
  }
  for (var i = 0; i < convexCornerSignatures.length; i++) {
    add('convex$i', convexCornerSignatures[i]);
  }
  return map;
}

void main() {
  test('dilateRegion grows the footprint and stays in bounds', () {
    final grid = dilateRegion({(10, 10)},
        cols: 30, rows: 30, padding: 3);
    // The seed and cells within a few steps are grass; far corners water.
    expect(grid[10][10], 1);
    expect(grid[10][12], 1);
    expect(grid[0][0], 0);
    for (final row in grid) {
      expect(row.length, 30);
    }
  });

  test('cellSignature classifies interior / edge / corner cells', () {
    // A solid 5x5 grass block at (1,1)..(5,5) in a 7x7 grid.
    final grid = List.generate(7, (_) => List.filled(7, 0));
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) {
        grid[y][x] = 1;
      }
    }
    expect(islandKindLabel(cellSignature(grid, 3, 3, 7, 7)), 'Interior');
    expect(islandKindLabel(cellSignature(grid, 3, 1, 7, 7)), 'Edge');
    expect(islandKindLabel(cellSignature(grid, 1, 1, 7, 7)), 'Convex corner');
  });

  test('autotile a solid block places a tile on every grass cell', () {
    final grid = List.generate(7, (_) => List.filled(7, 0));
    var grassCells = 0;
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) {
        grid[y][x] = 1;
        grassCells++;
      }
    }
    final result = autotileIsland(
      grid: grid,
      tileIdsBySignature: _convexTileSet(),
      random: Random(1),
    );
    // A convex 5x5 block needs only interior/edge/convex tiles -> all match.
    expect(result.unmatched, 0);
    expect(result.placements.length, grassCells);
    // Corner cell (1,1) got a convex corner tile.
    final corner =
        result.placements.firstWhere((p) => p.gridX == 1 && p.gridY == 1);
    expect(corner.blockId, startsWith('convex'));
  });

  test('a concave notch is unmatched without concave tiles', () {
    // L-shaped region produces an inner (concave) corner.
    final grid = List.generate(8, (_) => List.filled(8, 0));
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) {
        grid[y][x] = 1;
      }
    }
    // Carve so an inner corner appears (remove a rectangle corner).
    for (var y = 1; y <= 2; y++) {
      for (var x = 4; x <= 5; x++) {
        grid[y][x] = 0;
      }
    }
    final result = autotileIsland(
      grid: grid,
      tileIdsBySignature: _convexTileSet(),
      random: Random(1),
    );
    expect(result.unmatched, greaterThan(0));
  });

  test('fillEnclosedWater fills a hole enclosed by grass', () {
    // A grass ring at (1,1)..(5,5) around a water hole at (2,2)..(4,4),
    // the shape a track loop's footprint produces.
    final grid = List.generate(7, (_) => List.filled(7, 0));
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) {
        if (x == 1 || x == 5 || y == 1 || y == 5) grid[y][x] = 1;
      }
    }
    final solid = fillEnclosedWater(grid);
    // The hole is filled...
    for (var y = 2; y <= 4; y++) {
      for (var x = 2; x <= 4; x++) {
        expect(solid[y][x], 1, reason: 'hole cell ($x,$y) must become grass');
      }
    }
    // ...but the surrounding water stays water.
    expect(solid[0][0], 0);
    expect(solid[6][3], 0);
  });

  test('fillEnclosedWater keeps a concave notch open', () {
    // A C-shape: solid 5x5 block with a notch cut from the right edge to
    // the center. The notch reaches the border through water, so it is
    // coastline, not a hole, and must survive.
    final grid = List.generate(7, (_) => List.filled(7, 0));
    for (var y = 1; y <= 5; y++) {
      for (var x = 1; x <= 5; x++) {
        grid[y][x] = 1;
      }
    }
    grid[3][3] = 0;
    grid[3][4] = 0;
    grid[3][5] = 0;
    final solid = fillEnclosedWater(grid);
    expect(solid[3][3], 0);
    expect(solid[3][4], 0);
    expect(solid[3][5], 0);
    // The rest of the block is untouched.
    expect(solid[2][3], 1);
    expect(solid[4][3], 1);
  });

  test('autotiling a filled ring covers the former hole', () {
    final grid = List.generate(9, (_) => List.filled(9, 0));
    for (var y = 1; y <= 7; y++) {
      for (var x = 1; x <= 7; x++) {
        if (x == 1 || x == 7 || y == 1 || y == 7) grid[y][x] = 1;
      }
    }
    final result = autotileIsland(
      grid: fillEnclosedWater(grid),
      tileIdsBySignature: _convexTileSet(),
      random: Random(1),
    );
    expect(result.unmatched, 0);
    // 7x7 solid block = 49 tiles, including the center of the former hole.
    expect(result.placements.length, 49);
    expect(
        result.placements.any((p) => p.gridX == 4 && p.gridY == 4), isTrue);
  });
}
