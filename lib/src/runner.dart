import 'dart:async';

import 'package:analytics_toolkit/analytics_toolkit.dart';

import 'errors.dart';

/// Supplies the source catalog to validate and project against.
typedef ListSourcesFn = List<SourceDef> Function();

/// Fetches the normalized records for [sourceId], optionally bounded to a
/// resolved `[start, end)` date range. The host typically composes
/// `SourceSnapshotCache.getOrFetch` into this seam; the runner does not own a
/// cache itself.
///
/// The [dateBound] lets a date-bounded source (e.g. a database-backed source)
/// avoid materializing out-of-range records and lets the cache key correctly
/// on `(sourceId, dateBound)`. A fetcher that ignores it still works — it
/// simply returns the full set and relies on the executor's in-memory filter.
typedef FetchRecordsFn =
    Future<List<SourceRecord>> Function(
      String sourceId, {
      (DateTime, DateTime)? dateBound,
    });

/// Executes a fully-prepared request and returns the typed result,
/// synchronously or asynchronously. The default runs
/// [AnalyticsExecutor.execute] in-process; an async function lets a host move
/// execution off the main isolate (e.g. by handing the request to `compute`
/// with a top-level function that calls [AnalyticsExecutor.execute]).
typedef ExecuteQueryFn =
    FutureOr<Result<AnalyticsResult, AnalyticsError>> Function(
      ExecuteQueryRequest request,
    );

/// A plain, transport-friendly bundle of everything the executor needs.
///
/// Holds only data (no closures, no widgets), so it can cross an isolate
/// boundary unchanged if a host wires [ExecuteQueryFn] to a worker.
class ExecuteQueryRequest {
  const ExecuteQueryRequest({
    required this.query,
    required this.records,
    required this.sources,
    this.dateRange,
    this.asOf,
  });

  /// The projected query (date-range filters already appended when relevant).
  final AnalyticsQuerySpec query;

  /// The records to aggregate.
  final List<SourceRecord> records;

  /// The source catalog.
  final List<SourceDef> sources;

  /// The resolved `[start, end)` range. When non-null and the query uses
  /// `TimeGroupBy`, the executor densifies the result so every bucket in the
  /// range is represented; harmless for non-temporal queries.
  final (DateTime, DateTime)? dateRange;

  /// Reference date for `StreakMeasure`; ignored by other measures.
  /// [WidgetQueryRunner] always fills this — with the caller's value, or with
  /// the run's wall-clock read when the caller left it null.
  final DateTime? asOf;
}

/// The one place that knows the toolkit's execution choreography:
/// list sources → validate → project the date range → fetch records →
/// execute. Its seams ([listSources], [fetchRecords], [executeQuery]) are
/// injectable so the same orchestration works in tests, in-process, or across
/// an isolate.
class WidgetQueryRunner {
  WidgetQueryRunner({
    required this.listSources,
    required this.fetchRecords,
    ExecuteQueryFn? executeQuery,
  }) : executeQuery = executeQuery ?? _defaultExecute;

  /// Returns the current source catalog.
  final ListSourcesFn listSources;

  /// Fetches normalized records for a source id.
  final FetchRecordsFn fetchRecords;

  /// Runs a prepared request, synchronously or asynchronously. Defaults to
  /// the in-process [AnalyticsExecutor]; the runner awaits the result either
  /// way.
  final ExecuteQueryFn executeQuery;

  /// Runs a single query end to end.
  ///
  /// [asOf] — the reference date `StreakMeasure` evaluates against — defaults
  /// to the run's single wall-clock read (the same one that resolves relative
  /// date ranges) when null, so it never reaches the executor unset. Pass it
  /// explicitly to pin streak evaluation to a known instant.
  ///
  /// Validation and projection failures, execution errors, and any thrown
  /// failure all surface as `Err(BridgeAnalyticsError(...))`. On success the
  /// result is wrapped in a [SingleResult].
  Future<Result<BridgeResult, BridgeError>> runSingle(
    AnalyticsQuerySpec query, {
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
    DateTime? asOf,
  }) {
    return _guarded(() async {
      // One wall-clock read per run, shared by projection, bound resolution,
      // and the asOf default below, so a single run never straddles a
      // day/month/quarter boundary.
      final effectiveToday = today ?? DateTime.now();
      final sources = listSources();

      final prepared = _prepare(
        query: query,
        sources: sources,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: effectiveToday,
      );
      final AnalyticsQuerySpec projected;
      switch (prepared) {
        case Err(error: final e):
          return Err(BridgeAnalyticsError(e));
        case Ok(value: final q):
          projected = q;
      }

      final bound = _resolveBound(
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: effectiveToday,
      );
      final records = await fetchRecords(projected.source, dateBound: bound);
      final executed = await executeQuery(
        ExecuteQueryRequest(
          query: projected,
          records: records,
          sources: sources,
          dateRange: bound,
          asOf: asOf ?? effectiveToday,
        ),
      );

      return switch (executed) {
        Ok(value: final r) => Ok(SingleResult(r)),
        Err(error: final e) => Err(BridgeAnalyticsError(e)),
      };
    });
  }

  /// Runs a paired query.
  ///
  /// Both halves are validated once via [QueryValidator.validateWidgetPayload]
  /// (which also checks alignability), then fetched and executed concurrently.
  /// A null [asOf] defaults to the run's single wall-clock read, shared by
  /// both halves. Either half producing a non-[SeriesResult] is a shape
  /// mismatch surfaced as a [BridgeShapeMismatch]; success yields a
  /// [PairedResult]. Validation and projection failures, and any thrown
  /// failure, surface as a typed [Err].
  Future<Result<BridgeResult, BridgeError>> runPaired(
    PairedQuerySpec payload, {
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
    DateTime? asOf,
  }) {
    return _guarded(() async {
      // One wall-clock read per run, shared across both halves' projection,
      // the single fetch/densification bound, and the asOf default.
      final effectiveToday = today ?? DateTime.now();
      final sources = listSources();

      // Validate (and alignment-check) the pair as a unit before doing any I/O.
      final validation = QueryValidator.validateWidgetPayload(
        payload: payload,
        sources: sources,
        dateRangeMode: dateRangeMode,
      );
      if (validation case Err(error: final e)) {
        return Err(BridgeAnalyticsError(e));
      }

      // Project each half independently (validation already passed above, so we
      // only need projection here, not re-validation).
      final AnalyticsQuerySpec xQuery;
      switch (_project(
        query: payload.xQuery,
        sources: sources,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: effectiveToday,
      )) {
        case Err(error: final e):
          return Err(BridgeAnalyticsError(e));
        case Ok(value: final q):
          xQuery = q;
      }

      final AnalyticsQuerySpec yQuery;
      switch (_project(
        query: payload.yQuery,
        sources: sources,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: effectiveToday,
      )) {
        case Err(error: final e):
          return Err(BridgeAnalyticsError(e));
        case Ok(value: final q):
          yQuery = q;
      }

      // A paired query carries one date-range mode for the whole pair, so both
      // halves resolve to the same bound; fetch both concurrently, bounded to
      // it.
      final bound = _resolveBound(
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: effectiveToday,
      );
      final fetched = await Future.wait([
        fetchRecords(xQuery.source, dateBound: bound),
        fetchRecords(yQuery.source, dateBound: bound),
      ]);

      final AnalyticsResult xResult;
      switch (await executeQuery(
        ExecuteQueryRequest(
          query: xQuery,
          records: fetched[0],
          sources: sources,
          dateRange: bound,
          asOf: asOf ?? effectiveToday,
        ),
      )) {
        case Err(error: final e):
          return Err(BridgeAnalyticsError(e));
        case Ok(value: final r):
          xResult = r;
      }

      final AnalyticsResult yResult;
      switch (await executeQuery(
        ExecuteQueryRequest(
          query: yQuery,
          records: fetched[1],
          sources: sources,
          dateRange: bound,
          asOf: asOf ?? effectiveToday,
        ),
      )) {
        case Err(error: final e):
          return Err(BridgeAnalyticsError(e));
        case Ok(value: final r):
          yResult = r;
      }

      // Both halves must be plain series to be alignable into a pair.
      // Validation already enforces this, so reaching the error branches would
      // indicate a contract violation upstream rather than ordinary user input.
      if (xResult is! SeriesResult) {
        return Err(
          BridgeShapeMismatch(
            expected: ResultShape.series,
            actual: InferResultShape.ofQuery(payload.xQuery),
            suggestion: 'a single-group, single-measure query for the X half',
          ),
        );
      }
      if (yResult is! SeriesResult) {
        return Err(
          BridgeShapeMismatch(
            expected: ResultShape.series,
            actual: InferResultShape.ofQuery(payload.yQuery),
            suggestion: 'a single-group, single-measure query for the Y half',
          ),
        );
      }

      return Ok(PairedResult(x: xResult, y: yResult));
    });
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  /// Runs [run] and converts any thrown failure into a typed error.
  ///
  /// The whole orchestration body routes through here so that a throw from
  /// source listing, projection, preset resolution, fetching, or execution
  /// becomes an `Err(BridgeAnalyticsError(... unexpected ...))` rather than
  /// escaping the awaited future and stranding a widget on its loading state.
  Future<Result<BridgeResult, BridgeError>> _guarded(
    Future<Result<BridgeResult, BridgeError>> Function() run,
  ) async {
    try {
      return await run();
    } catch (e) {
      // [BridgeAnalyticsError.unexpected] keeps the message fixed and generic
      // — this wraps the fetch step, where connection strings, file paths,
      // and network internals surface — while carrying the throwable on
      // `debugDetail` for diagnostics.
      return Err(BridgeAnalyticsError.unexpected(debugDetail: e));
    }
  }

  /// Resolves [dateRangeMode] to a concrete `[start, end)` bound for the fetch
  /// seam, or null when the mode applies no range (`NoDateRange`). Mirrors the
  /// resolution the projector performs, surfaced here so the bound can be
  /// handed to the fetcher (and thus the cache key) rather than recomputed.
  ///
  /// `UsePageRange` without a [pageRange] would throw in the resolver; the run
  /// paths only reach here after projection has already validated that case, so
  /// a missing page range degrades to an unbounded fetch rather than throwing.
  (DateTime, DateTime)? _resolveBound({
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
  }) {
    if (dateRangeMode is NoDateRange) return null;
    if (dateRangeMode is UsePageRange && pageRange == null) return null;
    return DatePresetResolver.resolveMode(
      dateRangeMode,
      today: today ?? DateTime.now(),
      earliestDataDate: earliestDataDate,
      pageRange: pageRange,
    );
  }

  /// Validate then project a single query into an executable spec.
  Result<AnalyticsQuerySpec, AnalyticsError> _prepare({
    required AnalyticsQuerySpec query,
    required List<SourceDef> sources,
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
  }) {
    final validation = QueryValidator.validateWidgetPayload(
      payload: SingleQuerySpec(query: query),
      sources: sources,
      dateRangeMode: dateRangeMode,
    );
    return validation.andThen(
      (_) => _project(
        query: query,
        sources: sources,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: today,
      ),
    );
  }

  /// Project the date range onto [query]. A non-date-range mode (or a query
  /// that needs no range) returns the query unchanged. `UsePageRange` without a
  /// [pageRange] is a precondition error, surfaced typed rather than thrown.
  Result<AnalyticsQuerySpec, AnalyticsError> _project({
    required AnalyticsQuerySpec query,
    required List<SourceDef> sources,
    required DateRangeMode dateRangeMode,
    (DateTime, DateTime)? pageRange,
    DateTime? earliestDataDate,
    DateTime? today,
  }) {
    if (dateRangeMode is NoDateRange) return Ok(query);

    if (dateRangeMode is UsePageRange && pageRange == null) {
      return const Err(
        AnalyticsError(
          kind: AnalyticsErrorKind.preconditionViolation,
          humanMessage:
              'UsePageRange requires a pageRange; none was supplied to the '
              'runner.',
        ),
      );
    }

    return DateRangeProjector.project(
      query: query,
      mode: dateRangeMode,
      sources: sources,
      pageRange: pageRange ?? _sentinelRange,
      today: today ?? DateTime.now(),
      earliestDataDate: earliestDataDate,
    );
  }

  /// Only reached for `FixedOverride`, where the projector ignores `pageRange`.
  /// `UsePageRange` is guarded above, and `NoDateRange` returns early.
  static final (DateTime, DateTime) _sentinelRange = (
    DateTime.fromMillisecondsSinceEpoch(0),
    DateTime.fromMillisecondsSinceEpoch(0),
  );

  static Result<AnalyticsResult, AnalyticsError> _defaultExecute(
    ExecuteQueryRequest request,
  ) {
    return AnalyticsExecutor.execute(
      query: request.query,
      records: request.records,
      sources: request.sources,
      asOf: request.asOf,
      dateRange: request.dateRange,
    );
  }
}
