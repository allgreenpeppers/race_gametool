import 'block_def.dart';
import 'geometry.dart';
import 'port.dart';

/// A cell coordinate pair. Records compare structurally, so these work
/// directly as Set members.
typedef Cell = (int x, int y);

/// A working draft in Phase 1: one masked track piece on the raw image,
/// plus the ports defined on its edges. Coordinates are grid cells on the
/// raw draft image (1 cell = 16 px). This is editor-internal state; on
/// export it becomes a BlockDef with a packed spriteSheetRect.
///
/// Shape: [cells] is null for a solid rectangle covering the bounding
/// box. For irregular pieces (diagonals, Y-shaped forks) it holds the
/// occupied cells in local coordinates; the bounding box is their extent
/// and unoccupied cells are cleared to transparent on export.
class MaskDraft {
  const MaskDraft({
    required this.id,
    required this.gridX,
    required this.gridY,
    required this.widthCells,
    required this.heightCells,
    this.cells,
    this.ports = const [],
    this.category = BlockCategory.track,
    this.cornerType = CornerType.none,
    this.physicsTrackArea = const [],
  });

  /// Builds a freeform mask from absolute painted cells. The bounding box
  /// is their extent. If the cells happen to fill the whole rectangle the
  /// mask is stored as solid.
  factory MaskDraft.fromCells({
    required String id,
    required Set<Cell> absoluteCells,
    List<Port> ports = const [],
    BlockCategory category = BlockCategory.track,
    CornerType cornerType = CornerType.none,
    List<Vec2> physicsTrackArea = const [],
  }) {
    assert(absoluteCells.isNotEmpty);
    var minX = absoluteCells.first.$1;
    var minY = absoluteCells.first.$2;
    var maxX = minX;
    var maxY = minY;
    for (final (x, y) in absoluteCells) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    final width = maxX - minX + 1;
    final height = maxY - minY + 1;
    final solid = absoluteCells.length == width * height;
    return MaskDraft(
      id: id,
      gridX: minX,
      gridY: minY,
      widthCells: width,
      heightCells: height,
      cells: solid
          ? null
          : {for (final (x, y) in absoluteCells) (x - minX, y - minY)},
      ports: ports,
      category: category,
      cornerType: cornerType,
      physicsTrackArea: physicsTrackArea,
    );
  }

  factory MaskDraft.fromJson(Map<String, dynamic> json) {
    final rawCells = json['cells'] as List<dynamic>?;
    return MaskDraft(
      id: json['id'] as String,
      gridX: json['gridX'] as int,
      gridY: json['gridY'] as int,
      widthCells: json['widthCells'] as int,
      heightCells: json['heightCells'] as int,
      cells: rawCells == null
          ? null
          : {
              for (final c in rawCells)
                ((c as List<dynamic>)[0] as int, c[1] as int),
            },
      ports: (json['ports'] as List<dynamic>? ?? [])
          .map((p) => Port.fromJson(p as Map<String, dynamic>))
          .toList(),
      category: BlockCategory.fromJson(json['category'] as String?),
      cornerType: CornerType.fromJson(json['cornerType'] as String?),
      physicsTrackArea: (json['physicsTrackArea'] as List<dynamic>? ?? [])
          .map((v) => Vec2.fromJson(v as List<dynamic>))
          .toList(),
    );
  }

  final String id;
  final int gridX;
  final int gridY;
  final int widthCells;
  final int heightCells;

  /// Occupied cells in local coordinates, or null for a solid rectangle.
  final Set<Cell>? cells;

  /// Ports in local cell coordinates (0,0 = box top-left cell).
  final List<Port> ports;

  /// Asset family and (for island corners) convex/concave marking.
  final BlockCategory category;
  final CornerType cornerType;

  /// Local vertices of the asphalt polygon. Inside means normal friction,
  /// outside means sand or grass friction.
  final List<Vec2> physicsTrackArea;

  bool get isFreeform => cells != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'gridX': gridX,
        'gridY': gridY,
        'widthCells': widthCells,
        'heightCells': heightCells,
        // Sorted for stable, diff-friendly output.
        'cells': cells == null
            ? null
            : (cells!.toList()
                  ..sort((a, b) =>
                      a.$2 != b.$2 ? a.$2 - b.$2 : a.$1 - b.$1))
                .map((c) => [c.$1, c.$2])
                .toList(),
        'ports': ports.map((p) => p.toJson()).toList(),
        'category': category.jsonValue,
        'cornerType': cornerType.jsonValue,
        'physicsTrackArea': physicsTrackArea.map((v) => v.toJson()).toList(),
      };

  /// Whether the absolute cell is part of this mask's actual shape.
  bool containsCell(int cellX, int cellY) {
    if (cellX < gridX ||
        cellX >= gridX + widthCells ||
        cellY < gridY ||
        cellY >= gridY + heightCells) {
      return false;
    }
    final local = cells;
    return local == null || local.contains((cellX - gridX, cellY - gridY));
  }

  /// Whether the whole absolute cell rectangle lies inside the shape.
  bool containsRect(int cellX, int cellY, int width, int height) {
    for (var y = cellY; y < cellY + height; y++) {
      for (var x = cellX; x < cellX + width; x++) {
        if (!containsCell(x, y)) return false;
      }
    }
    return true;
  }

  MaskDraft copyWith({
    String? id,
    int? gridX,
    int? gridY,
    int? widthCells,
    int? heightCells,
    Set<Cell>? Function()? cells,
    List<Port>? ports,
    BlockCategory? category,
    CornerType? cornerType,
    List<Vec2>? physicsTrackArea,
  }) =>
      MaskDraft(
        id: id ?? this.id,
        gridX: gridX ?? this.gridX,
        gridY: gridY ?? this.gridY,
        widthCells: widthCells ?? this.widthCells,
        heightCells: heightCells ?? this.heightCells,
        cells: cells != null ? cells() : this.cells,
        ports: ports ?? this.ports,
        category: category ?? this.category,
        cornerType: cornerType ?? this.cornerType,
        physicsTrackArea: physicsTrackArea ?? this.physicsTrackArea,
      );
}
