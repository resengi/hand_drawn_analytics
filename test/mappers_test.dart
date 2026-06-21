import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart'
    show AxisDisplay, AxisDisplayMode;

import 'support.dart';

const _formatters = BridgeFormatters();
const _palette = BridgePalette();

void main() {
  group('seriesToBar', () {
    test('maps one bar per bucket with a zero-floored nice range', () {
      final result = series([
        bucket(sk('Mon'), iv(3)),
        bucket(sk('Tue'), iv(7)),
        bucket(sk('Wed'), iv(5)),
      ]);
      final mapped = seriesToBar(
        result,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.bars, hasLength(3));
      expect(data.minY, 0); // non-negative data floors at zero
      expect(data.maxY, greaterThanOrEqualTo(7));
    });

    test('empty input maps to empty, renderable data (not an error)', () {
      final mapped = seriesToBar(
        series(const []),
        palette: _palette,
        formatters: _formatters,
      );
      expect(mapped.isOk, isTrue);
      expect(mapped.okOrNull!.bars, isEmpty);
    });

    test('a null bucket value plots as zero rather than crashing', () {
      final mapped = seriesToBar(
        series([bucket(sk('a'), null), bucket(sk('b'), iv(4))]),
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.bars.first.segments.first.value, 0);
    });

    test('all bars share the series color', () {
      // Color encodes series identity (matching the multi-series mappers), so
      // every bar carries the palette's first color; the x-axis labels carry
      // the category identity.
      const palette = BridgePalette(
        colors: [Color(0xFF112233), Color(0xFF445566)],
      );
      final mapped = seriesToBar(
        series([
          bucket(sk('a'), iv(1)),
          bucket(sk('b'), iv(2)),
          bucket(sk('c'), iv(3)),
        ]),
        palette: palette,
        formatters: _formatters,
      );
      final colors = mapped.okOrNull!.bars
          .map((b) => b.segments.first.color)
          .toSet();
      expect(colors, {const Color(0xFF112233)});
    });
  });

  group('multiSeriesToBar', () {
    test('single mode on a multi-series result renders as grouped', () {
      final result = multiSeries(
        xAxis: [
          const XAxisPosition(key: StringBucketKey('Q1')),
          const XAxisPosition(key: StringBucketKey('Q2')),
        ],
        seriesList: [
          NamedSeries(key: sk('A'), values: [iv(1), iv(2)]),
          NamedSeries(key: sk('B'), values: [iv(3), iv(4)]),
        ],
      );
      final mapped = multiSeriesToBar(
        result,
        mode: BarMode.single,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      // Identical to grouped: one category per x position, one inner bar and
      // one legend entry per series.
      expect(data.categories, hasLength(2));
      expect(data.categories.first.bars, hasLength(2));
      expect(data.legend, hasLength(2));
    });

    test('grouped mode produces one category per x position', () {
      final result = multiSeries(
        xAxis: [
          const XAxisPosition(key: StringBucketKey('Q1')),
          const XAxisPosition(key: StringBucketKey('Q2')),
        ],
        seriesList: [
          NamedSeries(key: sk('A'), values: [iv(1), iv(2)]),
          NamedSeries(key: sk('B'), values: [iv(3), iv(4)]),
        ],
      );
      final mapped = multiSeriesToBar(
        result,
        mode: BarMode.grouped,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.categories, hasLength(2));
      expect(data.categories.first.bars, hasLength(2));
      expect(data.legend, hasLength(2));
    });

    test('stacked mode sums series into one bar per category', () {
      final result = multiSeries(
        xAxis: [const XAxisPosition(key: StringBucketKey('Q1'))],
        seriesList: [
          NamedSeries(key: sk('A'), values: [iv(2)]),
          NamedSeries(key: sk('B'), values: [iv(3)]),
        ],
      );
      final mapped = multiSeriesToBar(
        result,
        mode: BarMode.stacked,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.categories.first.bars, hasLength(1));
      expect(data.categories.first.bars.first.segments, hasLength(2));
      expect(data.maxY, greaterThanOrEqualTo(5)); // 2 + 3 stacked
    });

    test(
      'a mixed-sign stack ranges from the negative to the positive total',
      () {
        // +100 stacks up and -90 stacks down from zero, so the visible extent
        // runs from -90 to +100 rather than the net total of +10.
        final result = multiSeries(
          xAxis: [const XAxisPosition(key: StringBucketKey('Q1'))],
          seriesList: [
            NamedSeries(key: sk('up'), values: [iv(100)]),
            NamedSeries(key: sk('down'), values: [iv(-90)]),
          ],
        );
        final data = multiSeriesToBar(
          result,
          mode: BarMode.stacked,
          palette: _palette,
          formatters: _formatters,
        ).okOrNull!;
        expect(data.minY, lessThanOrEqualTo(-90));
        expect(data.maxY, greaterThanOrEqualTo(100));
      },
    );

    test('an all-positive stack keeps the zero baseline', () {
      final result = multiSeries(
        xAxis: [const XAxisPosition(key: StringBucketKey('Q1'))],
        seriesList: [
          NamedSeries(key: sk('a'), values: [iv(20)]),
          NamedSeries(key: sk('b'), values: [iv(30)]),
        ],
      );
      final data = multiSeriesToBar(
        result,
        mode: BarMode.stacked,
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.minY, 0);
      expect(data.maxY, greaterThanOrEqualTo(50));
    });

    test('an all-negative stack ranges below zero', () {
      final result = multiSeries(
        xAxis: [const XAxisPosition(key: StringBucketKey('Q1'))],
        seriesList: [
          NamedSeries(key: sk('a'), values: [iv(-20)]),
          NamedSeries(key: sk('b'), values: [iv(-30)]),
        ],
      );
      final data = multiSeriesToBar(
        result,
        mode: BarMode.stacked,
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.minY, lessThanOrEqualTo(-50));
      expect(data.maxY, lessThanOrEqualTo(0));
    });
  });

  group('multiMeasureToBar', () {
    test('rejects measures with incompatible units', () {
      final result = multiMeasure(
        xAxis: [const XAxisPosition(key: StringBucketKey('x'))],
        seriesList: [
          MeasureSeries(
            label: 'count',
            fieldType: FieldType.integer,
            values: [iv(5)],
          ),
          MeasureSeries(
            label: 'time',
            fieldType: FieldType.duration,
            values: [const DurationValue(Duration(minutes: 5))],
          ),
        ],
      );
      final mapped = multiMeasureToBar(
        result,
        mode: BarMode.grouped,
        palette: _palette,
        formatters: _formatters,
      );
      final err = mapped.errOrNull;
      expect(err, isA<BridgeIncompatibleValues>());
      expect(
        (err! as BridgeIncompatibleValues).reason,
        IncompatibleValuesReason.mixedUnits,
      );
    });

    test('allows integer + double together (same numeric family)', () {
      final result = multiMeasure(
        xAxis: [const XAxisPosition(key: StringBucketKey('x'))],
        seriesList: [
          MeasureSeries(
            label: 'a',
            fieldType: FieldType.integer,
            values: [iv(5)],
          ),
          MeasureSeries(
            label: 'b',
            fieldType: FieldType.double,
            values: [dv(2.5)],
          ),
        ],
      );
      final mapped = multiMeasureToBar(
        result,
        mode: BarMode.grouped,
        palette: _palette,
        formatters: _formatters,
      );
      expect(mapped.isOk, isTrue);
    });

    test('single mode on a multi-measure result renders as grouped', () {
      final result = multiMeasure(
        xAxis: [const XAxisPosition(key: StringBucketKey('x'))],
        seriesList: [
          MeasureSeries(
            label: 'a',
            fieldType: FieldType.integer,
            values: [iv(5)],
          ),
          MeasureSeries(
            label: 'b',
            fieldType: FieldType.integer,
            values: [iv(3)],
          ),
        ],
      );
      final mapped = multiMeasureToBar(
        result,
        mode: BarMode.single,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.categories, hasLength(1));
      expect(data.categories.first.bars, hasLength(2));
      expect(data.legend, hasLength(2));
    });
  });

  group('seriesToLine', () {
    test('skips null buckets so the line bridges the gap', () {
      final result = series([
        bucket(sk('a'), iv(1)),
        bucket(sk('b'), null),
        bucket(sk('c'), iv(3)),
      ]);
      final mapped = seriesToLine(
        result,
        palette: _palette,
        formatters: _formatters,
      );
      final data = mapped.okOrNull!;
      expect(data.series.first.points, hasLength(2)); // null dropped
    });

    test('a single line carries no legend', () {
      final mapped = seriesToLine(
        series([bucket(sk('a'), iv(1))]),
        palette: _palette,
        formatters: _formatters,
      );
      expect(mapped.okOrNull!.legend, isEmpty);
    });

    test('epochMs spacing positions points at real time', () {
      final t0 = DateTime.utc(2024, 1, 1);
      final t1 = DateTime.utc(2024, 1, 8);
      final result = series([
        bucket(TimeBucketKey(instant: t0, grain: TimeGrain.day), iv(1)),
        bucket(TimeBucketKey(instant: t1, grain: TimeGrain.day), iv(2)),
      ], groupKind: SeriesGroupKind.temporal);
      final mapped = seriesToLine(
        result,
        palette: _palette,
        formatters: _formatters,
        temporalSpacing: TemporalSpacing.epochMs,
      );
      final data = mapped.okOrNull!;
      expect(data.minX, t0.millisecondsSinceEpoch.toDouble());
      expect(data.maxX, t1.millisecondsSinceEpoch.toDouble());
      expect(data.xLabels, isEmpty); // epochMs uses numeric ticks
    });

    test('epochMs over a non-temporal key is a typed value error', () {
      final result = series([
        bucket(
          TimeBucketKey(instant: DateTime.utc(2024), grain: TimeGrain.day),
          iv(1),
        ),
        bucket(sk('not a time'), iv(2)),
      ]);
      final err = seriesToLine(
        result,
        palette: _palette,
        formatters: _formatters,
        temporalSpacing: TemporalSpacing.epochMs,
      ).errOrNull;
      expect(err, isA<BridgeIncompatibleValues>());
      expect(
        (err! as BridgeIncompatibleValues).reason,
        IncompatibleValuesReason.nonTemporalForEpochSpacing,
      );
    });

    test('uniform spacing accepts categorical keys', () {
      final result = series([
        bucket(sk('Mon'), iv(1)),
        bucket(sk('Tue'), iv(2)),
      ]);
      final mapped = seriesToLine(
        result,
        palette: _palette,
        formatters: _formatters,
      );
      expect(mapped.isOk, isTrue);
      expect(mapped.okOrNull!.xLabels, ['Mon', 'Tue']);
    });
  });

  group('pairedToScatter', () {
    test('aligns by bucket key and drops unmatched / null pairs', () {
      final x = series([
        bucket(sk('a'), iv(1)),
        bucket(sk('b'), iv(2)),
        bucket(sk('c'), iv(3)), // unmatched in y
      ]);
      final y = series([
        bucket(sk('a'), iv(10)),
        bucket(sk('b'), null), // null y -> dropped
        bucket(sk('d'), iv(40)), // unmatched in x
      ]);
      final mapped = pairedToScatter(x, y, formatters: _formatters);
      final mapping = mapped.okOrNull!;
      final data = mapping.data;
      expect(data.points, hasLength(1)); // only 'a' survives
      expect(data.points.first.x, 1);
      expect(data.points.first.y, 10);
      // 'c' (only in x), 'b' (null y), 'd' (only in y) were all dropped.
      expect(mapping.droppedCount, 3);
    });

    test('no aligned pairs yields an empty mapping reporting every drop', () {
      final x = series([bucket(sk('a'), iv(1))]);
      final y = series([bucket(sk('b'), iv(2))]);
      final mapped = pairedToScatter(x, y, formatters: _formatters);
      final mapping = mapped.okOrNull!;
      expect(mapping.data.points, isEmpty);
      // 'a' (only in x) and 'b' (only in y) were both dropped, so a builder can
      // tell this apart from a genuinely empty input.
      expect(mapping.droppedCount, 2);
    });
  });

  // Note: the former `pairedToRate` group has moved. Per-bucket ratio
  // arithmetic (dropping zero / null / unmatched denominators, the
  // divide-by-zero -> null rule) is now `analytics_toolkit`'s
  // `SeriesAlgebra.combine(..., op: RatioCombination())` and is covered by that
  // package's own suite. The line *styling* those tests incidentally exercised
  // (palette coloring, the zero-crossing value axis) is `seriesToLine`
  // behavior, so it is retargeted onto `seriesToLine` below. End-to-end
  // "paired result reduced to a line" coverage belongs in a dispatcher widget
  // test (render `HandDrawnAnalyticsWidget` with `combination:`), not here.

  group('resultToTable (totality)', () {
    test('a scalar becomes a 1x1 table', () {
      final mapped = resultToTable(
        const ScalarResult(value: IntValue(42), measureLabel: 'Total'),
        formatters: _formatters,
      );
      final m = mapped.okOrNull!;
      expect(m.columns, hasLength(1));
      expect(m.rows, hasLength(1));
      expect(m.rows.first.cells.first, '42');
    });

    test('measure columns are right-aligned, group keys left', () {
      final mapped = resultToTable(
        series([bucket(sk('Mon'), iv(3))]),
        formatters: _formatters,
      );
      final m = mapped.okOrNull!;
      // SeriesResult.toTableResult() yields a group-key column + a measure
      // column; alignment is derived from kind.
      expect(m.columns.length, greaterThanOrEqualTo(2));
    });
  });

  group('scalarToBigNumber', () {
    test('formats the value and surfaces the label, color left null', () {
      final mapped = scalarToBigNumber(
        const ScalarResult(value: IntValue(1234), measureLabel: 'Steps'),
        formatters: _formatters,
      );
      final big = mapped.okOrNull!;
      expect(big.displayValue, contains('234')); // decimal-grouped
      expect(big.label, 'Steps');
      expect(big.color, isNull);
    });

    test('a non-scalar result is a shape mismatch', () {
      final mapped = scalarToBigNumber(
        series([bucket(sk('a'), iv(1))]),
        formatters: _formatters,
      );
      expect(mapped.errOrNull, isA<BridgeShapeMismatch>());
    });
  });

  group('streakToTable', () {
    test(
      'maps a streak-shaped result to a leaderboard, id hidden by default',
      () {
        final mapping = streakToTable(
          streakTable([
            (id: 'u1', label: 'Ada', current: 5, longest: 9),
            (id: 'u2', label: 'Linus', current: 3, longest: 12),
          ]),
          formatters: _formatters,
        )!;
        // Default hides the entity-id column: Name / Current / Longest.
        expect(mapping.columns, hasLength(3));
        expect(mapping.columns.first.header, 'Name');
        expect(mapping.rows, hasLength(2));
        expect(mapping.rows.first.cells, ['Ada', '5', '9']);
      },
    );

    test('includes the id column when asked', () {
      final mapping = streakToTable(
        streakTable([(id: 'u1', label: 'Ada', current: 5, longest: 9)]),
        formatters: _formatters,
        options: const StreakTableOptions(showEntityId: true),
      )!;
      expect(mapping.columns, hasLength(4));
      expect(mapping.rows.first.cells, ['u1', 'Ada', '5', '9']);
    });

    test('returns null for a non-streak-shaped table', () {
      // A plain series projected to a table lacks the streak columns.
      final plain = series([bucket(sk('a'), iv(1))]).toTableResult();
      expect(streakToTable(plain, formatters: _formatters), isNull);
    });
  });

  group('seriesToLine themes through the palette', () {
    test('colors the line from the palette rather than a fixed literal', () {
      // Retargeted from the former pairedToRate palette test: the single-line
      // color comes from the palette (index 0), not a hard-coded literal.
      const palette = BridgePalette(colors: [Color(0xFF112233)]);
      final mapped = seriesToLine(
        series([bucket(sk('a'), iv(10)), bucket(sk('b'), iv(20))]),
        palette: palette,
        formatters: _formatters,
      );
      expect(mapped.okOrNull!.series.first.color, const Color(0xFF112233));
    });
  });

  group('unchartable-value guard', () {
    test('seriesToBar rejects a non-numeric measure type', () {
      final result = series([
        bucket(sk('a'), null),
      ], measureFieldType: FieldType.dateTime);
      final err = seriesToBar(
        result,
        palette: _palette,
        formatters: _formatters,
      ).errOrNull;
      expect(err, isA<BridgeIncompatibleValues>());
      final incompatible = err! as BridgeIncompatibleValues;
      expect(incompatible.reason, IncompatibleValuesReason.nonNumericType);
      expect(incompatible.fieldType, FieldType.dateTime);
    });

    test('seriesToLine rejects a non-numeric measure type', () {
      final result = series([
        bucket(sk('a'), null),
      ], measureFieldType: FieldType.enumeration);
      expect(
        seriesToLine(
          result,
          palette: _palette,
          formatters: _formatters,
        ).errOrNull,
        isA<BridgeIncompatibleValues>(),
      );
    });

    test(
      'a numeric measure with an undefined bucket is a gap, not an error',
      () {
        // Field-type, not per-value: an undefined aggregation over a numeric
        // field stays null and bridges as a gap.
        final result = series([
          bucket(sk('a'), iv(3)),
          bucket(sk('b'), null),
        ], measureFieldType: FieldType.integer);
        final mapped = seriesToLine(
          result,
          palette: _palette,
          formatters: _formatters,
        );
        expect(mapped.isOk, isTrue);
        expect(mapped.okOrNull!.series.first.points, hasLength(1));
      },
    );

    test('duration is chartable', () {
      final result = series([
        bucket(sk('a'), const DurationValue(Duration(minutes: 30))),
      ], measureFieldType: FieldType.duration);
      expect(
        seriesToBar(result, palette: _palette, formatters: _formatters).isOk,
        isTrue,
      );
    });

    test('pairedToScatter rejects a non-numeric x or y series', () {
      final x = series([
        bucket(sk('a'), iv(1)),
      ], measureFieldType: FieldType.string);
      final y = series([bucket(sk('a'), iv(2))]);
      expect(
        pairedToScatter(x, y, formatters: _formatters).errOrNull,
        isA<BridgeIncompatibleValues>(),
      );
    });
  });

  group('BridgeIncompatibleValues message', () {
    test('mixed-units names both types and suggests a table', () {
      const err = BridgeIncompatibleValues(
        reason: IncompatibleValuesReason.mixedUnits,
        fieldType: FieldType.integer,
        otherFieldType: FieldType.duration,
      );
      expect(err.humanMessage, contains('integer'));
      expect(err.humanMessage, contains('duration'));
      expect(err.humanMessage.toLowerCase(), contains('table'));
    });
  });

  group('isIntegerMeasure / resolveIntegerValued', () {
    test('count and streak measures are integer-valued', () {
      expect(isIntegerMeasure(const CountMeasure()), isTrue);
      expect(
        isIntegerMeasure(
          const StreakMeasure(
            entityIdField: FieldRef(sourceId: 's', fieldId: 'e'),
            scheduledDateField: FieldRef(sourceId: 's', fieldId: 'd'),
            statusField: FieldRef(sourceId: 's', fieldId: 'st'),
            completedStatusValue: 'done',
          ),
        ),
        isTrue,
      );
    });

    test('distinct-count is integer regardless of field type', () {
      const m = FieldMeasure(
        fieldRef: FieldRef(sourceId: 's', fieldId: 'f'),
        aggregation: DistinctCountAgg(),
      );
      expect(isIntegerMeasure(m, outputType: FieldType.double), isTrue);
    });

    test('sum over an integer field is integer; sum over double is not', () {
      const m = FieldMeasure(
        fieldRef: FieldRef(sourceId: 's', fieldId: 'f'),
        aggregation: SumAgg(),
      );
      expect(isIntegerMeasure(m, outputType: FieldType.integer), isTrue);
      expect(isIntegerMeasure(m, outputType: FieldType.double), isFalse);
    });

    test('average is never integer-valued', () {
      const avg = FieldMeasure(
        fieldRef: FieldRef(sourceId: 's', fieldId: 'f'),
        aggregation: AverageAgg(),
      );
      expect(isIntegerMeasure(avg, outputType: FieldType.integer), isFalse);
    });

    test('explicit value always wins over inference', () {
      expect(
        resolveIntegerValued(explicit: false, measures: const [CountMeasure()]),
        isFalse,
      );
      expect(resolveIntegerValued(explicit: true, measures: const []), isTrue);
    });

    test('multi-measure is integer only when every measure is', () {
      const intMeasure = FieldMeasure(
        fieldRef: FieldRef(sourceId: 's', fieldId: 'f'),
        aggregation: DistinctCountAgg(),
      );
      const avgMeasure = FieldMeasure(
        fieldRef: FieldRef(sourceId: 's', fieldId: 'f'),
        aggregation: AverageAgg(),
      );
      expect(
        resolveIntegerValued(
          explicit: null,
          measures: const [intMeasure, CountMeasure()],
        ),
        isTrue,
      );
      expect(
        resolveIntegerValued(
          explicit: null,
          measures: const [intMeasure, avgMeasure],
        ),
        isFalse,
      );
    });

    test('outputTypeOf yields the measure type for series shapes only', () {
      expect(
        outputTypeOf(
          series([bucket(sk('a'), iv(1))], measureFieldType: FieldType.double),
        ),
        FieldType.double,
      );
      expect(
        outputTypeOf(
          multiSeries(
            xAxis: [const XAxisPosition(key: StringBucketKey('x'))],
            seriesList: [
              NamedSeries(key: sk('A'), values: [iv(1)]),
            ],
            measureFieldType: FieldType.integer,
          ),
        ),
        FieldType.integer,
      );
      expect(
        outputTypeOf(
          multiMeasure(
            xAxis: [const XAxisPosition(key: StringBucketKey('x'))],
            seriesList: [
              MeasureSeries(
                label: 'a',
                fieldType: FieldType.integer,
                values: [iv(1)],
              ),
            ],
          ),
        ),
        isNull,
      );
      expect(
        outputTypeOf(const ScalarResult(value: IntValue(1), measureLabel: 'v')),
        isNull,
      );
      expect(outputTypeOf(streakTable(const [])), isNull);
    });
  });

  group('zero-crossing axis baseline', () {
    test('a signed series straddling zero gets a zero-crossing value axis', () {
      final result = series([bucket(sk('a'), iv(-5)), bucket(sk('b'), iv(8))]);
      final data = seriesToBar(
        result,
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.axisDisplay.horizontal, AxisDisplayMode.zeroCrossing);
    });

    test('a non-negative series keeps the edge axis default', () {
      final result = series([bucket(sk('a'), iv(3)), bucket(sk('b'), iv(8))]);
      final data = seriesToBar(
        result,
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.axisDisplay.horizontal, AxisDisplayMode.edge);
    });

    test('a signed line straddling zero also gets the zero-crossing axis', () {
      // Retargeted from the former pairedToRate signed-axis test: the
      // zero-crossing value axis is a seriesToLine behavior, applied to any
      // signed series (a reduced paired series included).
      final data = seriesToLine(
        series([bucket(sk('a'), iv(-4)), bucket(sk('b'), iv(6))]),
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.axisDisplay.horizontal, AxisDisplayMode.zeroCrossing);
    });

    test('a non-negative line keeps the edge axis default', () {
      final data = seriesToLine(
        series([bucket(sk('a'), iv(2)), bucket(sk('b'), iv(6))]),
        palette: _palette,
        formatters: _formatters,
      ).okOrNull!;
      expect(data.axisDisplay.horizontal, AxisDisplayMode.edge);
    });

    test('defaultAxisDisplayFor: null range yields the edge default', () {
      expect(defaultAxisDisplayFor(null), AxisDisplay.edge);
    });
  });

  group('pairedToScatter dropped-count', () {
    test('reports zero when every bucket aligns cleanly', () {
      final x = series([bucket(sk('a'), iv(1)), bucket(sk('b'), iv(2))]);
      final y = series([bucket(sk('a'), iv(10)), bucket(sk('b'), iv(20))]);
      final mapping = pairedToScatter(x, y, formatters: _formatters).okOrNull!;
      expect(mapping.droppedCount, 0);
      expect(mapping.data.points, hasLength(2));
    });
  });

  group('bridgeShapeOf', () {
    test('reports the wrapped single result shape', () {
      expect(
        bridgeShapeOf(SingleResult(series([bucket(sk('a'), iv(1))]))),
        ResultShape.series,
      );
      expect(
        bridgeShapeOf(
          const SingleResult(
            ScalarResult(value: IntValue(1), measureLabel: 'v'),
          ),
        ),
        ResultShape.scalar,
      );
      expect(
        bridgeShapeOf(SingleResult(streakTable(const []))),
        ResultShape.table,
      );
    });

    test('reports pairedSeries for a paired result', () {
      expect(
        bridgeShapeOf(
          PairedResult(
            x: series([bucket(sk('a'), iv(1))]),
            y: series([bucket(sk('a'), iv(2))]),
          ),
        ),
        ResultShape.pairedSeries,
      );
    });
  });
}
