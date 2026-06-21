import 'package:analytics_toolkit/analytics_toolkit.dart';

/// The bridge's vocabulary for failure and async state.
///
/// Three small foundation types live together here because they are read
/// together as the package's vocabulary:
///
/// * [BridgeError] — typed, recoverable failures the bridge can surface as a
///   graceful empty state instead of an exception.
/// * [AsyncValue] — the loading / data / error tri-state a controller exposes
///   while a query runs.
/// * [BridgeResult] — the successful payload of a run: either a single
///   [AnalyticsResult] or an aligned pair of [SeriesResult]s.

// ── BridgeError ─────────────────────────────────────────────────────────────

/// A typed, recoverable error produced by the bridge.
///
/// Mappers return these inside an [Err]; widgets render them as a graceful
/// empty state with [humanMessage] rather than throwing. The bridge never
/// throws for an expected failure — that is the whole point of the type.
sealed class BridgeError {
  const BridgeError();

  /// A user-facing, English-by-default explanation. Consumers that need
  /// localization can pattern-match on the concrete subtype instead.
  String get humanMessage;
}

/// The result a mapper was handed does not match the shape the chosen widget
/// can draw — e.g. a multi-series result handed to a single-series bar mapper.
///
/// Carries the [expected] and [actual] [ResultShape]s plus a short
/// [suggestion] naming a widget that *would* fit, so the empty state can guide
/// the consumer toward the right display type.
final class BridgeShapeMismatch extends BridgeError {
  const BridgeShapeMismatch({
    required this.expected,
    required this.actual,
    this.suggestion,
  });

  /// The shape the widget/mapper can render.
  final ResultShape expected;

  /// The shape that was actually produced.
  final ResultShape actual;

  /// Optional guidance naming a widget that fits [actual]. Null when no
  /// single obvious alternative exists.
  final String? suggestion;

  @override
  String get humanMessage {
    final base =
        'This data is shaped as ${_shapeName(actual)}, but this widget '
        'expects ${_shapeName(expected)}.';
    final hint = suggestion;
    return hint == null ? base : '$base Try $hint instead.';
  }

  static String _shapeName(ResultShape shape) => switch (shape) {
    ResultShape.scalar => 'a single value',
    ResultShape.series => 'a single series',
    ResultShape.multiSeries => 'a multi-series chart',
    ResultShape.multiMeasureSeries => 'a multi-measure chart',
    ResultShape.table => 'a table',
    ResultShape.pairedSeries => 'a pair of series',
  };
}

/// Wraps an upstream [AnalyticsError] (validation or execution failure) so the
/// bridge can carry it through the same [Err] channel as its own errors.
final class BridgeAnalyticsError extends BridgeError {
  const BridgeAnalyticsError(this.error, {this.debugDetail});

  /// The single owner of "unexpected throwable → safe error".
  ///
  /// [humanMessage] is fixed and generic: it renders directly into
  /// user-facing empty states, and the throwables this wraps (decode
  /// failures, fetch-layer faults) can carry connection strings, file paths,
  /// or other internals that must not leak there. Consumers wanting their own
  /// copy switch on [AnalyticsError.kind]; the throwable itself rides on
  /// [debugDetail] for diagnostics.
  factory BridgeAnalyticsError.unexpected({Object? debugDetail}) {
    return BridgeAnalyticsError(
      const AnalyticsError(
        kind: AnalyticsErrorKind.unexpected,
        humanMessage: 'Analytics failed unexpectedly.',
      ),
      debugDetail: debugDetail,
    );
  }

  /// The underlying analytics-layer error.
  final AnalyticsError error;

  /// The original throwable behind a [BridgeAnalyticsError.unexpected]
  /// error. Diagnostic only — never rendered.
  final Object? debugDetail;

  @override
  String get humanMessage => error.humanMessage;
}

/// A required piece of configuration (palette, formatters, page range, …) was
/// neither passed to the widget nor available from an enclosing
/// `AnalyticsScope`. [missingField] names what was absent.
final class BridgeMissingScope extends BridgeError {
  const BridgeMissingScope(this.missingField);

  /// The name of the missing field, e.g. `'pageRange'` or `'sources'`.
  final String missingField;

  @override
  String get humanMessage =>
      'Missing required configuration "$missingField". Provide it on the '
      'widget, or wrap the widget in an AnalyticsScope that supplies it.';
}

/// Why a result's *values* cannot be drawn on a numeric chart axis.
///
/// Distinct from [BridgeShapeMismatch], which is about the result's *shape*
/// versus the widget. This is a value-level incompatibility: the shape is fine,
/// but the values themselves can't be plotted.
enum IncompatibleValuesReason {
  /// A measure's output type has no numeric axis projection (e.g. a
  /// `dateTime`, `enum`, `string`, or `bool` measure handed to a chart).
  nonNumericType,

  /// Several series that would share one axis carry different units (e.g. a
  /// duration measure and a count measure stacked together).
  mixedUnits,

  /// Epoch-millisecond spacing was requested for a series whose keys are not
  /// all temporal, so there is no real time position to place them at.
  nonTemporalForEpochSpacing,
}

/// The result's shape fits the widget, but its values cannot be plotted on a
/// numeric axis. The specific cause is carried in [reason] — a non-numeric
/// measure type, several series with incompatible units sharing one axis, or
/// epoch spacing requested over non-temporal keys.
///
/// Each [humanMessage] suggests a display that can show the data (a table for a
/// type/unit mismatch, uniform spacing for non-temporal keys). Reserving this
/// type for value-level problems keeps [BridgeShapeMismatch] meaningful for
/// genuine shape-versus-widget mismatches.
final class BridgeIncompatibleValues extends BridgeError {
  const BridgeIncompatibleValues({
    required this.reason,
    this.fieldType,
    this.otherFieldType,
  });

  /// Which kind of value incompatibility occurred.
  final IncompatibleValuesReason reason;

  /// The offending field type. For [IncompatibleValuesReason.nonNumericType]
  /// this is the unchartable type; for [IncompatibleValuesReason.mixedUnits]
  /// it is one of the conflicting types.
  final FieldType? fieldType;

  /// For [IncompatibleValuesReason.mixedUnits], the second conflicting type.
  /// Null otherwise.
  final FieldType? otherFieldType;

  @override
  String get humanMessage => switch (reason) {
    IncompatibleValuesReason.nonNumericType =>
      'Values of type ${fieldType?.name ?? 'this'} cannot be plotted on a '
          'numeric axis. Try a table display instead.',
    IncompatibleValuesReason.mixedUnits =>
      'These measures carry different units '
          '(${fieldType?.name ?? '?'} and ${otherFieldType?.name ?? '?'}), so '
          'they cannot share one axis. Try a table to show them side by side.',
    IncompatibleValuesReason.nonTemporalForEpochSpacing =>
      'Real-time spacing requires temporal buckets; this series has '
          'non-temporal keys. Use uniform spacing or a categorical display.',
  };
}

// ── AsyncValue ──────────────────────────────────────────────────────────────

/// The tri-state of an in-flight asynchronous load: loading, data, or error.
///
/// Modeled as a sealed family so consumers get exhaustiveness when they
/// `switch`, with [when] offered as a convenience for the common
/// three-branch fold.
sealed class AsyncValue<T> {
  const AsyncValue();

  /// Folds the three states into a single value of type [R]. Every branch is
  /// required, mirroring the sealed family's exhaustiveness.
  R when<R>({
    required R Function() loading,
    required R Function(T data) data,
    required R Function(BridgeError error) error,
  }) {
    return switch (this) {
      AsyncLoading<T>() => loading(),
      AsyncData<T>(value: final v) => data(v),
      AsyncError<T>(error: final e) => error(e),
    };
  }
}

/// The load is in progress; no data or error yet.
final class AsyncLoading<T> extends AsyncValue<T> {
  const AsyncLoading();
}

/// The load completed successfully with [value].
final class AsyncData<T> extends AsyncValue<T> {
  const AsyncData(this.value);
  final T value;
}

/// The load failed with [error].
final class AsyncError<T> extends AsyncValue<T> {
  const AsyncError(this.error);
  final BridgeError error;
}

// ── BridgeResult ────────────────────────────────────────────────────────────

/// The successful payload of a query run.
///
/// A single query yields a [SingleResult] wrapping one [AnalyticsResult]; a
/// paired query yields a [PairedResult] holding the two [SeriesResult]s that
/// downstream consumers (the scatter mapper, a `SeriesCombination` reduction)
/// align by [BucketKey].
sealed class BridgeResult {
  const BridgeResult();
}

/// The result of a single (non-paired) query.
final class SingleResult extends BridgeResult {
  const SingleResult(this.result);
  final AnalyticsResult result;
}

/// The result of a paired query: an independently-computed x and y series,
/// aligned downstream by [BucketKey] equality.
final class PairedResult extends BridgeResult {
  const PairedResult({required this.x, required this.y});
  final SeriesResult x;
  final SeriesResult y;
}
