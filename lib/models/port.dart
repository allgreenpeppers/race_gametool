import 'dart:math' as math;

/// The eight directions a port can face. Cardinal directions connect
/// straight segments; diagonal directions connect 45-degree segments.
enum PortDirection {
  up('UP'),
  down('DOWN'),
  left('LEFT'),
  right('RIGHT'),
  diagUR('DIAG_UR'),
  diagUL('DIAG_UL'),
  diagDR('DIAG_DR'),
  diagDL('DIAG_DL');

  const PortDirection(this.jsonValue);

  /// Stable string written to sprite_dict.json, decoupled from Dart naming.
  final String jsonValue;

  static PortDirection fromJson(String value) =>
      PortDirection.values.firstWhere((d) => d.jsonValue == value);

  /// The direction a mating port must face for the two to snap together.
  PortDirection get opposite => switch (this) {
        up => down,
        down => up,
        left => right,
        right => left,
        diagUR => diagDL,
        diagUL => diagDR,
        diagDR => diagUL,
        diagDL => diagUR,
      };

  /// Angle in radians for rendering the direction arrow.
  /// Screen coordinates: 0 points right, positive rotates clockwise (y down).
  double get angle => switch (this) {
        right => 0,
        diagDR => math.pi / 4,
        down => math.pi / 2,
        diagDL => 3 * math.pi / 4,
        left => math.pi,
        diagUL => -3 * math.pi / 4,
        up => -math.pi / 2,
        diagUR => -math.pi / 4,
      };

  /// Unit grid step along this direction: (dx, dy) with y pointing down.
  (int, int) get gridDelta => switch (this) {
        up => (0, -1),
        down => (0, 1),
        left => (-1, 0),
        right => (1, 0),
        diagUR => (1, -1),
        diagUL => (-1, -1),
        diagDR => (1, 1),
        diagDL => (-1, 1),
      };

  bool get isDiagonal =>
      this == diagUR || this == diagUL || this == diagDR || this == diagDL;
}

/// A connection interface on the edge of a block, expressed in grid cells
/// local to the block's bounding box origin (top-left).
///
/// A port is a strip of [span] cells along the block edge, perpendicular
/// to its travel [direction] (a 5-cell road connects through a 5-cell
/// port strip). [localGridX]/[localGridY] locate the strip's top-left
/// cell. When the block is only one cell thick along the travel axis,
/// the strip touches both opposite edges and the port is [bidirectional]
/// (a pass-through, rendered with a double arrow).
class Port {
  const Port({
    required this.localGridX,
    required this.localGridY,
    required this.direction,
    this.span = 1,
    this.bidirectional = false,
  });

  final int localGridX;
  final int localGridY;
  final PortDirection direction;
  final int span;
  final bool bidirectional;

  /// Strip footprint in cells (width, height). Strips run perpendicular
  /// to the travel direction; diagonal ports are always a single cell.
  (int, int) get cellExtent => switch (direction) {
        PortDirection.up || PortDirection.down => (span, 1),
        PortDirection.left || PortDirection.right => (1, span),
        _ => (1, 1),
      };

  /// The directions this port connects toward.
  List<PortDirection> get directions =>
      bidirectional ? [direction, direction.opposite] : [direction];

  factory Port.fromJson(Map<String, dynamic> json) => Port(
        localGridX: json['localGridX'] as int,
        localGridY: json['localGridY'] as int,
        direction: PortDirection.fromJson(json['direction'] as String),
        span: json['span'] as int? ?? 1,
        bidirectional: json['bidirectional'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'localGridX': localGridX,
        'localGridY': localGridY,
        'direction': direction.jsonValue,
        'span': span,
        'bidirectional': bidirectional,
      };

  Port copyWith({
    int? localGridX,
    int? localGridY,
    PortDirection? direction,
    int? span,
    bool? bidirectional,
  }) =>
      Port(
        localGridX: localGridX ?? this.localGridX,
        localGridY: localGridY ?? this.localGridY,
        direction: direction ?? this.direction,
        span: span ?? this.span,
        bidirectional: bidirectional ?? this.bidirectional,
      );

  @override
  bool operator ==(Object other) =>
      other is Port &&
      other.localGridX == localGridX &&
      other.localGridY == localGridY &&
      other.direction == direction &&
      other.span == span &&
      other.bidirectional == bidirectional;

  @override
  int get hashCode =>
      Object.hash(localGridX, localGridY, direction, span, bidirectional);
}
