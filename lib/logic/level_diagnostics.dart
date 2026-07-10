import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/block_def.dart';
import '../models/map_scene.dart';
import '../models/port.dart';
import '../state/app_providers.dart';
import '../state/level_editor_providers.dart';

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
  BlockDef? Function(String id) defOf,
) {
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
    for (var y = r.y; y < r.y + r.h; y++) {
      for (var x = r.x; x < r.x + r.w; x++) {
        owner[(x, y)] = i;
      }
    }
  }

  for (var i = 0; i < placements.length; i++) {
    final def = defOf(placements[i].blockId);
    if (def == null) continue;
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

  diagnostics.sort((a, b) => a.severity.index.compareTo(b.severity.index));
  return diagnostics;
}

/// Live diagnostics for the current level, recomputed whenever the
/// placements or the loaded library change.
final levelDiagnosticsProvider = Provider<List<LevelDiagnostic>>((ref) {
  final placements = ref.watch(levelEditorProvider).placements;
  final library = ref.watch(assetLibraryProvider);
  return validateLevel(placements, library.blockById);
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
