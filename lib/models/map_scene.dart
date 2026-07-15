import 'control_point.dart';

/// Where the player car starts, in grid coordinates plus a facing angle
/// in radians (0 points right, positive rotates clockwise).
class SpawnPoint {
  const SpawnPoint({
    required this.gridX,
    required this.gridY,
    required this.facingAngle,
  });

  final int gridX;
  final int gridY;
  final double facingAngle;

  factory SpawnPoint.fromJson(Map<String, dynamic> json) => SpawnPoint(
        gridX: json['gridX'] as int,
        gridY: json['gridY'] as int,
        facingAngle: (json['facingAngle'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'gridX': gridX,
        'gridY': gridY,
        'facingAngle': facingAngle,
      };
}

/// One block stamped onto the map. Stores only the ID and grid position;
/// all visual and physics data lives in the BlockDef dictionary.
class BlockPlacement {
  const BlockPlacement({
    required this.blockId,
    required this.gridX,
    required this.gridY,
  });

  final String blockId;
  final int gridX;
  final int gridY;

  factory BlockPlacement.fromJson(Map<String, dynamic> json) =>
      BlockPlacement(
        blockId: json['blockId'] as String,
        gridX: json['gridX'] as int,
        gridY: json['gridY'] as int,
      );

  Map<String, dynamic> toJson() => {
        'blockId': blockId,
        'gridX': gridX,
        'gridY': gridY,
      };

  BlockPlacement copyWith({String? blockId, int? gridX, int? gridY}) =>
      BlockPlacement(
        blockId: blockId ?? this.blockId,
        gridX: gridX ?? this.gridX,
        gridY: gridY ?? this.gridY,
      );
}

/// The exported map scene: everything the game needs to rebuild a level,
/// given the sprite dictionary.
class MapScene {
  const MapScene({
    required this.mapName,
    required this.spawnPoint,
    this.placements = const [],
    this.islandTerrain = const [],
    this.manualControlPointOffsets = const {},
    this.userInsertedPoints = const [],
  });

  final String mapName;
  final SpawnPoint spawnPoint;
  final List<BlockPlacement> placements;

  /// Row-major terrain grid: 0 = water, 1 = grass island.
  /// islandTerrain[y][x], generated via Marching Squares in the editor.
  final List<List<int>> islandTerrain;

  final Map<String, double> manualControlPointOffsets;
  final List<ControlPoint> userInsertedPoints;

  factory MapScene.fromJson(Map<String, dynamic> json) => MapScene(
        mapName: json['mapName'] as String,
        spawnPoint:
            SpawnPoint.fromJson(json['spawnPoint'] as Map<String, dynamic>),
        placements: (json['placements'] as List<dynamic>? ?? [])
            .map((p) => BlockPlacement.fromJson(p as Map<String, dynamic>))
            .toList(),
        islandTerrain: (json['islandTerrain'] as List<dynamic>? ?? [])
            .map((row) =>
                (row as List<dynamic>).map((v) => v as int).toList())
            .toList(),
        manualControlPointOffsets: Map<String, double>.from(
            (json['manualControlPointOffsets'] as Map<dynamic, dynamic>?)?.map(
                    (k, v) => MapEntry(k as String, (v as num).toDouble())) ??
                {}),
        userInsertedPoints: (json['userInsertedPoints'] as List<dynamic>? ?? [])
            .map((p) => ControlPoint.fromJson(p as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'mapName': mapName,
        'spawnPoint': spawnPoint.toJson(),
        'placements': placements.map((p) => p.toJson()).toList(),
        'islandTerrain': islandTerrain,
        'manualControlPointOffsets': manualControlPointOffsets,
        'userInsertedPoints': userInsertedPoints.map((p) => p.toJson()).toList(),
      };

  MapScene copyWith({
    String? mapName,
    SpawnPoint? spawnPoint,
    List<BlockPlacement>? placements,
    List<List<int>>? islandTerrain,
    Map<String, double>? manualControlPointOffsets,
    List<ControlPoint>? userInsertedPoints,
  }) =>
      MapScene(
        mapName: mapName ?? this.mapName,
        spawnPoint: spawnPoint ?? this.spawnPoint,
        placements: placements ?? this.placements,
        islandTerrain: islandTerrain ?? this.islandTerrain,
        manualControlPointOffsets:
            manualControlPointOffsets ?? this.manualControlPointOffsets,
        userInsertedPoints: userInsertedPoints ?? this.userInsertedPoints,
      );
}

