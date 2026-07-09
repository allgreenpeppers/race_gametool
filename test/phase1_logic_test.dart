import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/logic/bin_packer.dart';
import 'package:race_gametool/logic/sprite_exporter.dart';
import 'package:race_gametool/models/mask_draft.dart';
import 'package:race_gametool/models/port.dart';

bool _overlaps(PackedRect a, PackedRect b, int padding) =>
    a.x < b.x + b.width + padding &&
    a.x + a.width + padding > b.x &&
    a.y < b.y + b.height + padding &&
    a.y + a.height + padding > b.y;

void main() {
  group('packSprites', () {
    test('places all rects without overlap and within bounds', () {
      final random = Random(42);
      final sizes = [
        for (var i = 0; i < 40; i++)
          (
            width: 16 + random.nextInt(12) * 16,
            height: 16 + random.nextInt(12) * 16,
          ),
      ];
      const padding = 2;
      final result = packSprites(sizes, padding: padding);

      expect(result.rects.length, sizes.length);
      for (final rect in result.rects) {
        expect(rect.width, sizes[rect.index].width);
        expect(rect.height, sizes[rect.index].height);
        expect(rect.x + rect.width, lessThanOrEqualTo(result.sheetWidth));
        expect(rect.y + rect.height, lessThanOrEqualTo(result.sheetHeight));
      }
      for (var i = 0; i < result.rects.length; i++) {
        for (var j = i + 1; j < result.rects.length; j++) {
          expect(_overlaps(result.rects[i], result.rects[j], padding), isFalse,
              reason: 'rects $i and $j overlap');
        }
      }
    });

    test('results are returned in input order', () {
      final result = packSprites([
        (width: 16, height: 16),
        (width: 160, height: 80),
        (width: 32, height: 48),
      ]);
      expect([for (final r in result.rects) r.index], [0, 1, 2]);
    });

    test('empty input yields empty sheet', () {
      final result = packSprites([]);
      expect(result.sheetWidth, 0);
      expect(result.rects, isEmpty);
    });

    test('throws when sprites cannot fit the maximum bin', () {
      expect(
        () => packSprites([(width: 300, height: 300)], maxBinSize: 256),
        throwsStateError,
      );
    });
  });

  group('buildSpriteExport', () {
    test('crops pieces into a packed transparent sheet with correct dict',
        () {
      // Draft image: 10 x 10 cells (160 x 160 px). Two colored pieces.
      final draft = img.Image(width: 160, height: 160, numChannels: 4);
      img.fillRect(draft,
          x1: 0, y1: 0, x2: 79, y2: 31, color: img.ColorRgba8(255, 0, 0, 255));
      img.fillRect(draft,
          x1: 96,
          y1: 48,
          x2: 143,
          y2: 143,
          color: img.ColorRgba8(0, 0, 255, 255));
      final rawBytes = Uint8List.fromList(img.encodePng(draft));

      final masks = [
        const MaskDraft(
          id: 'straight_h',
          gridX: 0,
          gridY: 0,
          widthCells: 5,
          heightCells: 2,
          ports: [
            Port(localGridX: 0, localGridY: 0, direction: PortDirection.left),
            Port(localGridX: 4, localGridY: 0, direction: PortDirection.right),
          ],
        ),
        const MaskDraft(
          id: 'corner_bl',
          gridX: 6,
          gridY: 3,
          widthCells: 3,
          heightCells: 6,
        ),
      ];

      final result = buildSpriteExport(rawImageBytes: rawBytes, masks: masks);

      // Dictionary structure.
      final root = jsonDecode(result.jsonText) as Map<String, dynamic>;
      expect(root['cellSize'], 16);
      expect(root['spriteSheet'], 'SpriteSheet.png');
      expect((root['blocks'] as List).length, 2);

      final straight =
          result.blocks.firstWhere((b) => b.id == 'straight_h');
      expect(straight.spriteSheetRect.w, 80);
      expect(straight.spriteSheetRect.h, 32);
      expect(straight.ports.length, 2);
      expect(straight.ports.first.direction, PortDirection.left);

      final corner = result.blocks.firstWhere((b) => b.id == 'corner_bl');
      expect(corner.spriteSheetRect.w, 48);
      expect(corner.spriteSheetRect.h, 96);

      // Pixel content survives the crop and pack.
      final sheet = img.decodePng(result.pngBytes)!;
      final sPixel = sheet.getPixel(
          straight.spriteSheetRect.x + 1, straight.spriteSheetRect.y + 1);
      expect(sPixel.r, 255);
      expect(sPixel.b, 0);
      final cPixel = sheet.getPixel(
          corner.spriteSheetRect.x + 1, corner.spriteSheetRect.y + 1);
      expect(cPixel.b, 255);
      expect(cPixel.r, 0);

      // parseSpriteDict round trip.
      final parsed = parseSpriteDict(result.jsonText);
      expect(parsed.spriteSheet, 'SpriteSheet.png');
      expect(parsed.blocks.length, 2);
      expect(parsed.blocks.map((b) => b.id),
          containsAll(['straight_h', 'corner_bl']));
    });

    test('rejects an empty mask list', () {
      expect(
        () => buildSpriteExport(
            rawImageBytes: Uint8List(0), masks: const []),
        throwsArgumentError,
      );
    });
  });
}
