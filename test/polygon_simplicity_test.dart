import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/models/geometry.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';

void main() {
  group('isSimplePolygon', () {
    test('empty or under 3 vertices is always simple/valid', () {
      expect(isSimplePolygon([]), isTrue);
      expect(isSimplePolygon([const Vec2(0, 0)]), isFalse); // under 3 vertices is false unless empty
      expect(isSimplePolygon([const Vec2(0, 0), const Vec2(1, 1)]), isFalse);
    });

    test('valid convex triangle is simple', () {
      final triangle = [
        const Vec2(0, 0),
        const Vec2(2, 0),
        const Vec2(0, 2),
      ];
      expect(isSimplePolygon(triangle), isTrue);
    });

    test('valid concave L-shape is simple', () {
      final lShape = [
        const Vec2(0, 0),
        const Vec2(2, 0),
        const Vec2(2, 1),
        const Vec2(1, 1),
        const Vec2(1, 2),
        const Vec2(0, 2),
      ];
      expect(isSimplePolygon(lShape), isTrue);
    });

    test('self-intersecting bowtie polygon is NOT simple', () {
      final bowtie = [
        const Vec2(0, 0),
        const Vec2(2, 2),
        const Vec2(2, 0),
        const Vec2(0, 2),
      ];
      expect(isSimplePolygon(bowtie), isFalse);
    });

    test('polygon that folds back on itself is NOT simple', () {
      final foldback = [
        const Vec2(0, 0),
        const Vec2(2, 0),
        const Vec2(1, 0), // folds back along the same segment
        const Vec2(1, 1),
      ];
      expect(isSimplePolygon(foldback), isFalse);
    });
  });
}
