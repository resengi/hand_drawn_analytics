import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/widgets.dart';

import '../analytics_scope.dart';
import '../colors.dart';
import '../controller/chart_host.dart';
import '../errors.dart';
import '../formatters.dart';
import '../runner.dart';

/// The bridge configuration a chart widget needs, resolved from explicit
/// widget arguments with fallback to the enclosing [AnalyticsScope].
///
/// All styling is excluded by design — this carries only the plumbing every
/// chart widget shares (palette, formatters, resolver, page range, runner).
class ResolvedChartConfig {
  const ResolvedChartConfig({
    required this.runner,
    required this.palette,
    required this.formatters,
    required this.colorResolver,
  });

  final WidgetQueryRunner runner;
  final BridgePalette palette;
  final BridgeFormatters formatters;
  final SemanticColorResolver? colorResolver;
}

/// Resolves the shared config for a chart widget.
///
/// Order per field: an explicit widget argument wins; otherwise the value from
/// the nearest [AnalyticsScope]; otherwise a typed [BridgeMissingScope] for the
/// fields that have no safe default (the runner). Palette and formatters have
/// sensible defaults, so they never raise.
Result<ResolvedChartConfig, BridgeError> resolveChartConfig(
  BuildContext context, {
  WidgetQueryRunner? runner,
  BridgePalette? palette,
  BridgeFormatters? formatters,
  SemanticColorResolver? colorResolver,
}) {
  final scope = AnalyticsScope.maybeOf(context);

  final resolvedRunner = runner ?? scope?.runner;
  if (resolvedRunner == null) {
    return const Err(BridgeMissingScope('runner'));
  }

  return Ok(
    ResolvedChartConfig(
      runner: resolvedRunner,
      palette: palette ?? scope?.palette ?? const BridgePalette(),
      formatters: formatters ?? scope?.formatters ?? const BridgeFormatters(),
      colorResolver: colorResolver ?? scope?.colorResolver,
    ),
  );
}

/// Builds a [ChartHost] with the standard three-state plumbing.
///
/// [loading], [error], and [data] are the bridge widget's renderers; this just
/// wires them and the query inputs to a host. Keeping this in one place means
/// the four chart widgets don't each repeat the host wiring.
Widget buildChartHost({
  required WidgetQueryRunner runner,
  required QueryPayload payload,
  required DateRangeMode dateRangeMode,
  required WidgetBuilder loading,
  required Widget Function(BuildContext, BridgeError) error,
  required Widget Function(BuildContext, BridgeResult) data,
  (DateTime, DateTime)? pageRange,
  DateTime? earliestDataDate,
  DateTime? today,
  DateTime? asOf,
}) {
  return ChartHost(
    runner: runner,
    payload: payload,
    dateRangeMode: dateRangeMode,
    pageRange: pageRange,
    earliestDataDate: earliestDataDate,
    today: today,
    asOf: asOf,
    loadingBuilder: loading,
    errorBuilder: error,
    dataBuilder: data,
  );
}

/// Wraps [child] so taps are hit-tested against a freshly-computed chart
/// layout.
///
/// The bridge widget owns all styling, so it supplies [computeHit] — a closure
/// that, given the rendered [Size] and the local tap [Offset], reconstructs its
/// painter (with the same styling that drew [child]) and returns the typed hit
/// (or null). This keeps `chart_internals` free of styling knobs while still
/// centralizing the `LayoutBuilder` + `GestureDetector` plumbing.
///
/// [onTapMiss] is called when a tap lands inside the chart but on no data
/// element. The two callbacks are independent: a tap resolves to exactly one
/// of them (a hit fires [onTap], a miss fires [onTapMiss]).
///
/// When both callbacks are null, [child] is returned unwrapped — no gesture
/// layer, no per-frame layout recomputation.
Widget wrapWithTap<H>({
  required Widget child,
  required H? Function(Size size, Offset localPosition) computeHit,
  required void Function(H hit)? onTap,
  void Function()? onTapMiss,
}) {
  if (onTap == null && onTapMiss == null) return child;
  return LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (details) {
          // A layout can only be computed against a finite, non-empty box.
          // Under unbounded constraints the size would be infinite, so skip
          // hit-testing entirely rather than feeding the painter an invalid
          // size — a tap that cannot be resolved is neither a hit nor a miss.
          if (!size.isFinite || size.isEmpty) return;
          final hit = computeHit(size, details.localPosition);
          if (hit != null) {
            onTap?.call(hit);
          } else {
            onTapMiss?.call();
          }
        },
        child: child,
      );
    },
  );
}
