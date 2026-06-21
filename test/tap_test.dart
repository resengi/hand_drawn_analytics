import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/src/widgets/chart_internals.dart';

// `wrapWithTap` is the single gesture seam all four chart widgets route through,
// so its hit/miss routing is exercised here in isolation: the test supplies the
// `computeHit` closure, making hit-versus-miss deterministic without depending
// on real chart layout.

/// Key on a finite, non-empty box so the gesture layer installs and the wrapped
/// content can be tapped.
const _boxKey = Key('chart-box');

Future<void> _pump(WidgetTester tester, Widget wrapped) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: _boxKey,
            width: 200,
            height: 200,
            child: wrapped,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a hit fires onTap and not onTapMiss', (tester) async {
    Object? tappedHit;
    var misses = 0;
    await _pump(
      tester,
      wrapWithTap<String>(
        child: const ColoredBox(color: Color(0xFF000000)),
        computeHit: (_, _) => 'hit',
        onTap: (hit) => tappedHit = hit,
        onTapMiss: () => misses++,
      ),
    );
    await tester.tap(find.byKey(_boxKey));
    expect(tappedHit, 'hit');
    expect(misses, 0);
  });

  testWidgets('a miss fires onTapMiss and not onTap', (tester) async {
    var taps = 0;
    var misses = 0;
    await _pump(
      tester,
      wrapWithTap<String>(
        child: const ColoredBox(color: Color(0xFF000000)),
        computeHit: (_, _) => null, // nothing under the pointer
        onTap: (_) => taps++,
        onTapMiss: () => misses++,
      ),
    );
    await tester.tap(find.byKey(_boxKey));
    expect(taps, 0);
    expect(misses, 1);
  });

  testWidgets('only onTapMiss set still installs the gesture layer', (
    tester,
  ) async {
    var misses = 0;
    await _pump(
      tester,
      wrapWithTap<String>(
        child: const ColoredBox(color: Color(0xFF000000)),
        computeHit: (_, _) => null,
        onTap: null,
        onTapMiss: () => misses++,
      ),
    );
    await tester.tap(find.byKey(_boxKey));
    expect(misses, 1);
  });

  testWidgets('only onTap set fires no spurious miss on a hit', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      wrapWithTap<String>(
        child: const ColoredBox(color: Color(0xFF000000)),
        computeHit: (_, _) => 'hit',
        onTap: (_) => taps++,
      ),
    );
    await tester.tap(find.byKey(_boxKey));
    expect(taps, 1);
  });

  testWidgets('neither callback returns the child unwrapped', (tester) async {
    await _pump(
      tester,
      wrapWithTap<String>(
        child: const ColoredBox(key: Key('child'), color: Color(0xFF000000)),
        computeHit: (_, _) => 'hit',
        onTap: null,
      ),
    );
    expect(find.byKey(const Key('child')), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
  });
}
