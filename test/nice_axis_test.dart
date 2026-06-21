import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';

void main() {
  group('niceYRange', () {
    test('floors non-negative data at zero', () {
      final r = niceYRange([3, 7, 5]);
      expect(r!.min, 0);
      expect(r.max, greaterThanOrEqualTo(7));
    });

    test('expands mixed-sign data on both sides of zero', () {
      final r = niceYRange([-4, 6])!;
      expect(r.min, lessThan(0));
      expect(r.max, greaterThan(0));
    });

    test('snaps to whole numbers when integerValued', () {
      final r = niceYRange([1, 2, 3], integerValued: true)!;
      expect(r.max, r.max.roundToDouble());
    });

    test('returns null when there is nothing to plot', () {
      expect(niceYRange([null, null]), isNull);
      expect(niceYRange(const <double?>[]), isNull);
    });

    test('a nice upper bound rounds up to 1/2/2.5/5 x 10^n', () {
      expect(niceUpperBound(7), 10);
      expect(niceUpperBound(11), 20);
      expect(niceUpperBound(23), 25);
      expect(niceUpperBound(0), 0);
    });
  });

  group('nicePaddedRange (scatter)', () {
    test('never floors at zero — pads both ends', () {
      final r = nicePaddedRange([10, 20, 30])!;
      expect(r.min, lessThan(10));
      expect(r.max, greaterThan(30));
    });

    test('pads around a single degenerate value', () {
      final r = nicePaddedRange([5, 5])!;
      expect(r.min, lessThan(5));
      expect(r.max, greaterThan(5));
    });
  });
}
