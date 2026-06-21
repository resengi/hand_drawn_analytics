import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:intl/intl.dart';

/// The single source of truth for turning typed analytics values into display
/// strings and chart-ready numbers.
///
/// Everything the bridge shows — table cells, scalar big-numbers, axis tick
/// values, unit labels — flows through one [BridgeFormatters] instance, so a
/// consumer can change display policy in one place. The defaults are sensible
/// and locale-aware (via `intl`); subclass and override individual methods to
/// customize.
///
/// Formatters are pure and side-effect free: they never touch a widget or a
/// `BuildContext`, so they are safe to call from mappers.
class BridgeFormatters {
  const BridgeFormatters();

  /// Renders a single [TypedValue] as a table cell string.
  ///
  /// `null` (a missing/undefined aggregation) renders as an em dash so empty
  /// buckets are visually distinct from a real zero.
  String tableCell(TypedValue? value) {
    if (value == null) return '—';
    return switch (value) {
      NullValue() => '—',
      StringValue(value: final v) => v,
      EnumValue(value: final v) => v,
      BoolValue(value: final v) => v ? 'Yes' : 'No',
      IntValue(value: final v) => _integerFormat.format(v),
      DoubleValue(value: final v) => _decimalFormat.format(v),
      DateTimeValue(value: final v) => _dateFormat.format(v),
      DurationValue(value: final v) => humanizeDuration(v),
      StringListValue(values: final vs) => vs.join(', '),
      EnumListValue(values: final vs) => vs.join(', '),
      IntListValue(values: final vs) =>
        vs.map(_integerFormat.format).join(', '),
    };
  }

  /// Renders a [TypedValue] for a prominent single-value display. Shares the
  /// table-cell policy by default; split out so a subclass can override
  /// big-number formatting (e.g. compact `1.2k`) without touching table cells.
  String scalarValue(TypedValue? value) => tableCell(value);

  /// Projects a [TypedValue] to the `double` a chart axis needs, or `null`
  /// when the value cannot be plotted numerically.
  ///
  /// Durations are projected to minutes — the most legible unit for the
  /// habit/fitness/time-tracking data these charts typically show.
  /// [chartUnitLabel] returns the matching axis unit so the two stay in sync.
  double? chartNumeric(TypedValue? value) {
    if (value == null) return null;
    return switch (value) {
      IntValue(value: final v) => v.toDouble(),
      DoubleValue(value: final v) => v,
      DurationValue(value: final v) =>
        v.inMicroseconds / Duration.microsecondsPerMinute,
      _ => null,
    };
  }

  /// The axis unit label implied by [chartNumeric] for [fieldType], or `null`
  /// when no unit annotation applies. Only duration carries a unit ("min").
  String? chartUnitLabel(FieldType fieldType) =>
      fieldType == FieldType.duration ? 'min' : null;

  /// Renders a [BucketKey] as an axis / category label.
  ///
  /// Temporal keys are formatted by grain. [includeYear] forces the year into
  /// temporal labels; callers pass the result of [spansMultipleYears] so a
  /// series that crosses a year boundary disambiguates its labels while a
  /// within-one-year series stays compact.
  String bucketKey(BucketKey key, {bool includeYear = false}) {
    return switch (key) {
      NullBucketKey() => '—',
      StringBucketKey(value: final v) => v,
      EnumBucketKey(value: final v) => v,
      BoolBucketKey(value: final v) => v ? 'Yes' : 'No',
      IntBucketKey(value: final v) => _integerFormat.format(v),
      DoubleBucketKey(value: final v) => _decimalFormat.format(v),
      TimeBucketKey(instant: final t, grain: final g) => _timeBucketLabel(
        t,
        g,
        includeYear: includeYear,
      ),
    };
  }

  /// Whether the temporal [keys] span more than one calendar year. Non-temporal
  /// or empty inputs return `false`. Callers use this to decide [bucketKey]'s
  /// `includeYear`.
  bool spansMultipleYears(Iterable<BucketKey> keys) {
    int? firstYear;
    for (final k in keys) {
      if (k is TimeBucketKey) {
        final y = k.instant.year;
        if (firstYear == null) {
          firstYear = y;
        } else if (y != firstYear) {
          return true;
        }
      }
    }
    return false;
  }

  /// Renders a [Duration] compactly: `45s`, `12m`, `3h 05m`, `2d 4h`.
  /// Zero renders as `0s`. Negative durations keep a leading sign.
  String humanizeDuration(Duration d) {
    if (d == Duration.zero) return '0s';
    final negative = d.isNegative;
    final abs = negative ? -d : d;
    final sign = negative ? '-' : '';

    final days = abs.inDays;
    final hours = abs.inHours % 24;
    final minutes = abs.inMinutes % 60;
    final seconds = abs.inSeconds % 60;

    if (days > 0) {
      return hours > 0 ? '$sign${days}d ${hours}h' : '$sign${days}d';
    }
    if (hours > 0) {
      return '$sign${hours}h ${_pad2(minutes)}m';
    }
    if (minutes > 0) {
      return '$sign${minutes}m';
    }
    return '$sign${seconds}s';
  }

  String _timeBucketLabel(
    DateTime instant,
    TimeGrain grain, {
    required bool includeYear,
  }) {
    // Choose a date format by the grain's unit. Finer-than-day grains carry a
    // time component; coarser grains show the year only when asked.
    final pattern = switch (grain.unit) {
      // Year grain inherently shows the year.
      TimeUnit.year => 'yyyy',
      TimeUnit.month => includeYear ? 'MMM yyyy' : 'MMM',
      TimeUnit.week || TimeUnit.day => includeYear ? 'MMM d, yyyy' : 'MMM d',
      // Sub-day grains always carry a date prefix, which already distinguishes
      // years in practice; the time component is what matters here.
      TimeUnit.hour => 'MMM d HH:00',
      TimeUnit.minute ||
      TimeUnit.second ||
      TimeUnit.millisecond ||
      TimeUnit.microsecond => 'MMM d HH:mm',
    };
    return _memoDateFormat(pattern, () => DateFormat(pattern)).format(instant);
  }

  static String _pad2(int n) => n < 10 ? '0$n' : '$n';

  NumberFormat get _integerFormat =>
      _memoNumberFormat('decimalPattern', NumberFormat.decimalPattern);
  NumberFormat get _decimalFormat => _memoNumberFormat(
    'decimalPattern.max2',
    () => NumberFormat.decimalPattern()..maximumFractionDigits = 2,
  );
  DateFormat get _dateFormat => _memoDateFormat('yMMMd', DateFormat.yMMMd);

  // ── Formatter memoization ─────────────────────────────────────────────────
  //
  // Constructing a NumberFormat/DateFormat parses its pattern each time,
  // which is measurable across a large table (one cell per call) or a dense
  // axis (one tick per call). Instances are cached per
  // `(current default locale, recipe id)`: keying on the locale keeps a
  // runtime locale switch fully reactive — the next call under the new locale
  // builds and caches fresh instances — and the cache stays bounded by the
  // locales × recipes actually used. The ids are literals owned by this
  // class; a raw time-bucket pattern is its own id (none collides with a
  // named recipe).

  static final Map<String, NumberFormat> _numberFormats = {};
  static final Map<String, DateFormat> _dateFormats = {};

  static NumberFormat _memoNumberFormat(
    String id,
    NumberFormat Function() create,
  ) => _numberFormats.putIfAbsent('${Intl.getCurrentLocale()} $id', create);

  static DateFormat _memoDateFormat(String id, DateFormat Function() create) =>
      _dateFormats.putIfAbsent('${Intl.getCurrentLocale()} $id', create);
}
