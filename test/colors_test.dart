import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';

void main() {
  group('BridgePalette.resolve with an empty palette', () {
    test('asserts when positional resolution is reached', () {
      const palette = BridgePalette(colors: []);
      expect(() => palette.resolve(index: 0), throwsAssertionError);
    });

    test('still resolves through a covering resolver', () {
      const palette = BridgePalette(colors: []);
      const color = Color(0xFF123456);
      final resolved = palette.resolve(
        index: 3,
        resolver: (semanticTag, key) => color,
      );
      expect(resolved, color);
    });

    test('still resolves through a tag pin', () {
      const palette = BridgePalette(
        colors: [],
        tagPins: {'mood': Color(0xFF654321)},
      );
      expect(
        palette.resolve(index: 1, semanticTag: 'mood'),
        const Color(0xFF654321),
      );
    });
  });

  group('BridgePalette equality', () {
    test('palettes with equal colors and tag pins are equal', () {
      const a = BridgePalette(
        colors: [Color(0xFF112233), Color(0xFF445566)],
        tagPins: {'mood': Color(0xFF654321)},
      );
      const b = BridgePalette(
        colors: [Color(0xFF112233), Color(0xFF445566)],
        tagPins: {'mood': Color(0xFF654321)},
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('default-constructed palettes are equal', () {
      expect(const BridgePalette(), const BridgePalette());
    });

    test('differing colors are unequal', () {
      const a = BridgePalette(colors: [Color(0xFF112233)]);
      const b = BridgePalette(colors: [Color(0xFF445566)]);
      expect(a, isNot(b));
    });

    test('differing tag pins are unequal', () {
      const a = BridgePalette(tagPins: {'mood': Color(0xFF654321)});
      const b = BridgePalette(tagPins: {'mood': Color(0xFF123456)});
      expect(a, isNot(b));
    });
  });
}
