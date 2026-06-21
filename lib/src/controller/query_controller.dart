import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/foundation.dart';

import '../errors.dart';
import '../runner.dart';

/// Runs a query payload through a [WidgetQueryRunner], exposes the result as an
/// [AsyncValue], and drops stale responses.
///
/// Lifecycle only: it does not project date ranges or resolve presets — that
/// is the runner's job. It routes a single vs paired payload to the matching
/// runner method, and guards against out-of-order completions with a monotonic
/// request id, so a slow earlier query can never overwrite a newer result.
class AnalyticsQueryController extends ChangeNotifier {
  AnalyticsQueryController({
    required this.runner,
    required this.payload,
    required this.dateRangeMode,
    this.pageRange,
    this.earliestDataDate,
    this.today,
    this.asOf,
  }) {
    refresh();
  }

  /// The runner that performs validation, projection, fetch, and execution.
  final WidgetQueryRunner runner;

  /// The query payload (single or paired).
  final QueryPayload payload;

  /// How the date range is applied.
  final DateRangeMode dateRangeMode;

  /// Page-level range, required when [dateRangeMode] is `UsePageRange`.
  final (DateTime, DateTime)? pageRange;

  /// Optional earliest-data hint for preset resolution.
  final DateTime? earliestDataDate;

  /// "Now" for preset resolution; defaults to wall-clock when null.
  final DateTime? today;

  /// Reference date for `StreakMeasure`.
  final DateTime? asOf;

  AsyncValue<BridgeResult> _value = const AsyncLoading();

  /// The current async state.
  AsyncValue<BridgeResult> get value => _value;

  int _requestId = 0;
  bool _disposed = false;

  /// Re-runs the query. Any in-flight request is invalidated; only the latest
  /// request's outcome is applied.
  Future<void> refresh() async {
    final requestId = ++_requestId;
    _setLoading();

    final payload = this.payload;
    final result = switch (payload) {
      SingleQuerySpec(query: final q) => await runner.runSingle(
        q,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: today,
        asOf: asOf,
      ),
      PairedQuerySpec() => await runner.runPaired(
        payload,
        dateRangeMode: dateRangeMode,
        pageRange: pageRange,
        earliestDataDate: earliestDataDate,
        today: today,
        asOf: asOf,
      ),
    };

    // Drop the response if a newer request started while we awaited, or if the
    // controller was disposed.
    if (requestId != _requestId || _disposed) return;

    _set(switch (result) {
      Ok(value: final r) => AsyncData(r),
      Err(error: final e) => AsyncError(e),
    });
  }

  /// Resets to the loading state. Notifies only when the value actually changes
  /// and the controller is live, so the synchronous call from the constructor
  /// (before any listener attaches) does no needless work.
  void _setLoading() {
    if (_value is AsyncLoading<BridgeResult>) return;
    _set(const AsyncLoading());
  }

  void _set(AsyncValue<BridgeResult> next) {
    if (_disposed) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    // Invalidate any in-flight request so its completion is ignored, and block
    // any further notifications.
    _disposed = true;
    _requestId++;
    super.dispose();
  }
}
