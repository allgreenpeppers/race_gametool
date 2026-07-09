/// A JSON-friendly 2D vector used by physics polygons and check lines.
///
/// This library stays pure Dart (no dart:ui) so the models can be used by
/// the plain-Dart build-time extractor CLI as well as the Flutter app.
/// We also do not depend on vector_math: the exported JSON is consumed by
/// the Flame game which maps these onto its own Vector2 type. Serialized
/// as a compact [x, y] array to keep exported files small.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  factory Vec2.fromJson(List<dynamic> json) =>
      Vec2((json[0] as num).toDouble(), (json[1] as num).toDouble());

  List<double> toJson() => [x, y];

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 scale(double s) => Vec2(x * s, y * s);

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2($x, $y)';
}

/// A line segment between two points, used for check lines
/// (lap counting and anti-cheat gates at corner apexes).
class LineSegment {
  const LineSegment(this.p1, this.p2);

  final Vec2 p1;
  final Vec2 p2;

  factory LineSegment.fromJson(Map<String, dynamic> json) => LineSegment(
        Vec2.fromJson(json['p1'] as List<dynamic>),
        Vec2.fromJson(json['p2'] as List<dynamic>),
      );

  Map<String, dynamic> toJson() => {'p1': p1.toJson(), 'p2': p2.toJson()};
}
