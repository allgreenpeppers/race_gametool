import 'geometry.dart';

enum BoundarySide {
  left,
  right,
}

/// A Track Boundary Control Point.
/// Can be auto-generated at a seam or manually inserted by the user.
class ControlPoint {
  const ControlPoint({
    required this.id,
    required this.baseX,
    required this.baseY,
    required this.dirX,
    required this.dirY,
    this.offset = 0.0,
    required this.isAuto,
    this.seamNearIndex,
    this.seamFarIndex,
    this.placementIndex,
    this.side,
    this.edgeT,
  });

  final String id;
  final double baseX; // base X coordinate in pixels
  final double baseY; // base Y coordinate in pixels
  final double dirX;  // unit perpendicular vector X
  final double dirY;  // unit perpendicular vector Y
  final double offset; // manual offset along (dirX, dirY)
  final bool isAuto;

  // Metadata for identifying/linking
  final int? seamNearIndex;
  final int? seamFarIndex;
  final int? placementIndex;
  final BoundarySide? side;
  final double? edgeT;

  Vec2 get position => Vec2(baseX + dirX * offset, baseY + dirY * offset);

  ControlPoint copyWith({
    String? id,
    double? baseX,
    double? baseY,
    double? dirX,
    double? dirY,
    double? offset,
    bool? isAuto,
    int? seamNearIndex,
    int? seamFarIndex,
    int? placementIndex,
    BoundarySide? side,
    double? edgeT,
  }) {
    return ControlPoint(
      id: id ?? this.id,
      baseX: baseX ?? this.baseX,
      baseY: baseY ?? this.baseY,
      dirX: dirX ?? this.dirX,
      dirY: dirY ?? this.dirY,
      offset: offset ?? this.offset,
      isAuto: isAuto ?? this.isAuto,
      seamNearIndex: seamNearIndex ?? this.seamNearIndex,
      seamFarIndex: seamFarIndex ?? this.seamFarIndex,
      placementIndex: placementIndex ?? this.placementIndex,
      side: side ?? this.side,
      edgeT: edgeT ?? this.edgeT,
    );
  }

  factory ControlPoint.fromJson(Map<String, dynamic> json) => ControlPoint(
        id: json['id'] as String,
        baseX: (json['baseX'] as num).toDouble(),
        baseY: (json['baseY'] as num).toDouble(),
        dirX: (json['dirX'] as num).toDouble(),
        dirY: (json['dirY'] as num).toDouble(),
        offset: (json['offset'] as num).toDouble(),
        isAuto: json['isAuto'] as bool,
        seamNearIndex: json['seamNearIndex'] as int?,
        seamFarIndex: json['seamFarIndex'] as int?,
        placementIndex: json['placementIndex'] as int?,
        side: json['side'] != null
            ? BoundarySide.values.byName(json['side'] as String)
            : null,
        edgeT: json['edgeT'] != null ? (json['edgeT'] as num).toDouble() : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseX': baseX,
        'baseY': baseY,
        'dirX': dirX,
        'dirY': dirY,
        'offset': offset,
        'isAuto': isAuto,
        if (seamNearIndex != null) 'seamNearIndex': seamNearIndex,
        if (seamFarIndex != null) 'seamFarIndex': seamFarIndex,
        if (placementIndex != null) 'placementIndex': placementIndex,
        if (side != null) 'side': side!.name,
        if (edgeT != null) 'edgeT': edgeT,
      };
}
