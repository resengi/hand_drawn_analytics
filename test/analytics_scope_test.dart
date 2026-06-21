import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';

// The scope derives one runner from its sources and cache and keeps that
// instance stable across rebuilds; only replacing sources or cache derives a
// new one. Hosts compare the runner by identity, so this stability is what
// makes "rebuilt scope, same data source" a non-event for every widget below.

FieldDef _field(String id, FieldType type) => FieldDef(
  fieldId: id,
  sourceId: 'events',
  displayName: id,
  fieldType: type,
  filterable: true,
  groupable: true,
  aggregatable: true,
  sortable: true,
);

SourceDef _source() => SourceDef(
  sourceId: 'events',
  displayName: 'Events',
  fields: [_field('when', FieldType.dateTime), _field('n', FieldType.integer)],
  primaryDateFieldId: 'when',
);

SourceSnapshotCache _cache() =>
    SourceSnapshotCache(fetcher: (sourceId, {dateBound}) async => const []);

void main() {
  testWidgets('a rebuilt scope with the same sources and cache hands out the '
      'identical runner', (tester) async {
    final sources = [_source()];
    final cache = _cache();
    final captured = <WidgetQueryRunner>[];

    Widget build(BridgePalette palette) => MaterialApp(
      home: AnalyticsScope(
        sources: sources,
        cache: cache,
        palette: palette,
        child: Builder(
          builder: (context) {
            captured.add(AnalyticsScope.of(context).runner);
            return const SizedBox();
          },
        ),
      ),
    );

    await tester.pumpWidget(build(const BridgePalette()));
    // A render-only change rebuilds the scope without touching the runner.
    await tester.pumpWidget(
      build(const BridgePalette(colors: [Color(0xFF112233)])),
    );

    expect(captured, hasLength(2));
    expect(identical(captured[0], captured[1]), isTrue);
  });

  testWidgets('replacing the sources or the cache derives a new runner', (
    tester,
  ) async {
    final sourcesA = [_source()];
    final sourcesB = [_source()];
    final cacheA = _cache();
    final cacheB = _cache();
    final captured = <WidgetQueryRunner>[];

    Widget build(List<SourceDef> sources, SourceSnapshotCache cache) =>
        MaterialApp(
          home: AnalyticsScope(
            sources: sources,
            cache: cache,
            child: Builder(
              builder: (context) {
                captured.add(AnalyticsScope.of(context).runner);
                return const SizedBox();
              },
            ),
          ),
        );

    await tester.pumpWidget(build(sourcesA, cacheA));
    await tester.pumpWidget(build(sourcesB, cacheA)); // sources replaced
    await tester.pumpWidget(build(sourcesB, cacheB)); // cache replaced

    expect(captured, hasLength(3));
    expect(identical(captured[0], captured[1]), isFalse);
    expect(identical(captured[1], captured[2]), isFalse);
  });

  testWidgets('maybeOf is null outside any scope', (tester) async {
    var looked = false;
    AnalyticsScopeData? scope;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            scope = AnalyticsScope.maybeOf(context);
            looked = true;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(looked, isTrue);
    expect(scope, isNull);
  });
}
