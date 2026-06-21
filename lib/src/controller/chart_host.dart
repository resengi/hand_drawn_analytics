import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/widgets.dart';

import '../errors.dart';
import '../runner.dart';
import 'query_controller.dart';

/// Owns an [AnalyticsQueryController]'s Flutter lifecycle and renders its
/// current [AsyncValue] through three builders.
///
/// Internal plumbing shared by every bridge widget: it creates the controller
/// in `initState`, recreates it when the inputs that define the query change,
/// disposes it, and rebuilds when the controller notifies. It carries **no**
/// styling — styling lives on the bridge widgets and flows to their templates.
///
/// Not exported from the package barrel.
class ChartHost extends StatefulWidget {
  const ChartHost({
    required this.runner,
    required this.payload,
    required this.dateRangeMode,
    required this.loadingBuilder,
    required this.errorBuilder,
    required this.dataBuilder,
    this.pageRange,
    this.earliestDataDate,
    this.today,
    this.asOf,
    super.key,
  });

  final WidgetQueryRunner runner;
  final QueryPayload payload;
  final DateRangeMode dateRangeMode;
  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;
  final DateTime? asOf;

  final WidgetBuilder loadingBuilder;
  final Widget Function(BuildContext context, BridgeError error) errorBuilder;
  final Widget Function(BuildContext context, BridgeResult result) dataBuilder;

  @override
  State<ChartHost> createState() => _ChartHostState();
}

class _ChartHostState extends State<ChartHost> {
  late AnalyticsQueryController _controller;

  @override
  void initState() {
    super.initState();
    _controller = _createController();
  }

  @override
  void didUpdateWidget(ChartHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_inputsChanged(oldWidget)) {
      _controller.dispose();
      _controller = _createController();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AnalyticsQueryController _createController() {
    return AnalyticsQueryController(
      runner: widget.runner,
      payload: widget.payload,
      dateRangeMode: widget.dateRangeMode,
      pageRange: widget.pageRange,
      earliestDataDate: widget.earliestDataDate,
      today: widget.today,
      asOf: widget.asOf,
    );
  }

  /// Whether any input that defines *what data to fetch* changed, requiring a
  /// fresh run. The builders are excluded (swapping a builder closure doesn't
  /// change the data). The runner is compared by identity: a scope-supplied
  /// runner is stable while the scope's data source is unchanged, so a
  /// different runner instance means different data. The query payload and
  /// date-range inputs use value equality, so an equivalent rebuilt query
  /// compares equal.
  bool _inputsChanged(ChartHost oldWidget) {
    return !identical(widget.runner, oldWidget.runner) ||
        widget.payload != oldWidget.payload ||
        widget.dateRangeMode != oldWidget.dateRangeMode ||
        widget.pageRange != oldWidget.pageRange ||
        widget.earliestDataDate != oldWidget.earliestDataDate ||
        widget.today != oldWidget.today ||
        widget.asOf != oldWidget.asOf;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return _controller.value.when(
          loading: () => widget.loadingBuilder(context),
          data: (result) => widget.dataBuilder(context, result),
          error: (error) => widget.errorBuilder(context, error),
        );
      },
    );
  }
}
