import 'geometry.dart';

/// Configurable settings for automatic generation in the Function Layer.
class FunctionLayerSettings {
  const FunctionLayerSettings({
    this.boundaryOffset = 16.0,
    this.curveExtension = 32.0,
    this.bevelRatio = 0.3,
    this.straightCheckInterval = 500.0,
  });

  /// Parallel buffer distance from the inner road area.
  final double boundaryOffset;

  /// Depth of turn outer anti-cut protrusions (bracket shape depth).
  final double curveExtension;

  /// Ratio (0.0 to 1.0) along the protrusion corner sides to apply a bevel,
  /// turning the sharp corner into a trapezoid.
  final double bevelRatio;

  /// Distance interval for generating check lines on straight road segments.
  final double straightCheckInterval;

  factory FunctionLayerSettings.fromJson(Map<String, dynamic> json) =>
      FunctionLayerSettings(
        boundaryOffset: (json['boundaryOffset'] as num?)?.toDouble() ?? 16.0,
        curveExtension: (json['curveExtension'] as num?)?.toDouble() ?? 32.0,
        bevelRatio: (json['bevelRatio'] as num?)?.toDouble() ?? 0.3,
        straightCheckInterval:
            (json['straightCheckInterval'] as num?)?.toDouble() ?? 500.0,
      );

  Map<String, dynamic> toJson() => {
        'boundaryOffset': boundaryOffset,
        'curveExtension': curveExtension,
        'bevelRatio': bevelRatio,
        'straightCheckInterval': straightCheckInterval,
      };
}

/// A check point/line segment for lap counting and anti-cheat validation,
/// including a forward vector to determine player vehicle direction.
class CheckLine {
  const CheckLine({
    required this.p1,
    required this.p2,
    required this.forwardVector,
  });

  final Vec2 p1;
  final Vec2 p2;
  final Vec2 forwardVector;

  factory CheckLine.fromJson(Map<String, dynamic> json) => CheckLine(
        p1: Vec2.fromJson(json['p1'] as List<dynamic>),
        p2: Vec2.fromJson(json['p2'] as List<dynamic>),
        forwardVector: Vec2.fromJson(json['forwardVector'] as List<dynamic>),
      );

  Map<String, dynamic> toJson() => {
        'p1': p1.toJson(),
        'p2': p2.toJson(),
        'forwardVector': forwardVector.toJson(),
      };
}

/// A physical boundary (e.g. outer world void fence, inner track barrier, or
/// beveled anti-cut red obstacles).
class TrackBoundary {
  const TrackBoundary({
    required this.vertices,
    required this.isClosed,
    required this.type,
  });

  final List<Vec2> vertices;
  final bool isClosed;
  final String type; // 'outerWorld', 'innerFunction', 'antiCutRed'

  factory TrackBoundary.fromJson(Map<String, dynamic> json) => TrackBoundary(
        vertices: (json['vertices'] as List<dynamic>)
            .map((v) => Vec2.fromJson(v as List<dynamic>))
            .toList(),
        isClosed: json['isClosed'] as bool,
        type: json['type'] as String,
      );

  Map<String, dynamic> toJson() => {
        'vertices': vertices.map((v) => v.toJson()).toList(),
        'isClosed': isClosed,
        'type': type,
      };
}
