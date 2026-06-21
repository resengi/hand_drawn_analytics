import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

import '../analytics_scope.dart';
import '../colors.dart';
import '../controller/query_controller.dart';
import '../dispatch/widget_dispatcher.dart';
import '../errors.dart';
import '../formatters.dart';
import '../mappers/to_bar_chart.dart';
import '../runner.dart';
import '../widgets/analytics_table.dart';

/// Hand-drawn framing around a dashboard widget: a [HandDrawnContainer] with
/// optional title and an optional edit affordance.
///
/// Pure chrome — it owns no data and runs no query. Cards compose their content
/// into it so every card on a dashboard shares one framing treatment.
class CardChrome extends StatelessWidget {
  const CardChrome({
    required this.child,
    this.title,
    this.titleStyle,
    this.onEdit,
    this.padding = const EdgeInsets.all(HandDrawnDefaults.containerPadding),
    this.backgroundColor,
    super.key,
  });

  final Widget child;
  final String? title;
  final TextStyle? titleStyle;

  /// When non-null, an edit affordance is shown in the header.
  final VoidCallback? onEdit;
  final EdgeInsets padding;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    return HandDrawnContainer(
      padding: padding,
      backgroundColor:
          backgroundColor ?? HandDrawnDefaults.containerBackgroundColor,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null || onEdit != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    title ?? '',
                    style: titleStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onEdit != null)
                  GestureDetector(
                    onTap: onEdit,
                    behavior: HitTestBehavior.opaque,
                    child: const Icon(Icons.edit, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          child,
        ],
      ),
    );
  }
}

/// Owns an [AnalyticsQueryController]'s lifecycle inside a card [State].
///
/// Both card types resolve a runner (explicit or from the enclosing scope),
/// (re)build the controller when a fetch-defining input changes, and dispose
/// it. This mixin holds that shared machinery — every lifecycle path funnels
/// into [syncController] — so each card only describes *what* to run.
mixin _CardControllerHost<T extends StatefulWidget> on State<T> {
  AnalyticsQueryController? _controller;

  /// The controller, or null until a runner is available and a payload exists.
  AnalyticsQueryController? get controller => _controller;

  /// The explicit runner for this card, if any. Falls back to the scope.
  WidgetQueryRunner? get explicitRunner;

  /// The payload to run, or null when the card has nothing to run yet.
  QueryPayload? get cardPayload;

  /// How the card's date range is applied. Decides which date inputs are
  /// fetch-defining in [syncController].
  DateRangeMode get cardDateRangeMode;

  /// The page-level date range, consulted under [UsePageRange].
  (DateTime, DateTime)? get cardPageRange;

  /// The earliest data date, consulted when resolving a relative preset.
  DateTime? get cardEarliestDataDate;

  /// The reference "today", consulted when resolving a relative preset.
  DateTime? get cardToday;

  /// The as-of instant for streak evaluation.
  DateTime? get cardAsOf;

  /// Builds a controller for the current payload.
  AnalyticsQueryController buildController(WidgetQueryRunner runner);

  /// Brings the controller in line with the card's current inputs. The single
  /// entry point for every lifecycle path: call it from
  /// [State.didChangeDependencies], [State.didUpdateWidget], and reload
  /// signals.
  ///
  /// Re-resolves the runner ([explicitRunner], else the enclosing scope's)
  /// and compares the fetch-defining inputs against what the live controller
  /// captured at construction — the controller's own fields are the "what I
  /// last built with" record, so there is no parallel bookkeeping to drift.
  /// One of three outcomes, at most one of which runs per call:
  ///
  /// * **Rebuild** (dispose + build, which runs the query) when the runner is
  ///   a different instance, a fetch-defining input differs, or the caller
  ///   knows the payload definition changed ([payloadChanged]).
  /// * **Refresh in place** when nothing changed but the caller asked for a
  ///   re-run ([refreshRequested]) — the data underneath moved, not the query.
  /// * **Nothing** otherwise, so render-only changes never refetch.
  void syncController({
    bool payloadChanged = false,
    bool refreshRequested = false,
  }) {
    final runner = explicitRunner ?? AnalyticsScope.maybeOf(context)?.runner;
    final payload = cardPayload;
    if (runner == null || payload == null) {
      _controller?.dispose();
      _controller = null;
      return;
    }
    final live = _controller;
    if (payloadChanged ||
        live == null ||
        !identical(runner, live.runner) ||
        _fetchInputsChanged(live)) {
      live?.dispose();
      _controller = buildController(runner);
      return; // Building runs the query; a same-call refresh would double-run.
    }
    if (refreshRequested) live.refresh();
  }

  /// Whether a fetch-defining input differs from what [live] captured.
  ///
  /// The payload, the date-range mode, and [cardAsOf] always count. The date
  /// inputs count only where the mode consults them, so an irrelevant input
  /// changing (e.g. the page range under a fixed override) never refetches:
  ///
  /// * [NoDateRange] — no date inputs are consulted.
  /// * [UsePageRange] — [cardPageRange] only.
  /// * [FixedOverride] of a [PresetRange] — [cardToday] and
  ///   [cardEarliestDataDate], which anchor the preset's resolution.
  /// * [FixedOverride] of a [CustomRange] — none; the range is self-contained.
  ///
  /// A range shape this mixin does not recognize counts every date input,
  /// trading a possible redundant fetch for never showing stale data.
  bool _fetchInputsChanged(AnalyticsQueryController live) {
    if (cardPayload != live.payload) return true;
    final mode = cardDateRangeMode;
    if (mode != live.dateRangeMode) return true;
    if (cardAsOf != live.asOf) return true;
    if (mode is NoDateRange) return false;
    if (mode is UsePageRange) return cardPageRange != live.pageRange;
    if (mode is FixedOverride) {
      final range = mode.range;
      if (range is PresetRange) {
        return cardToday != live.today ||
            cardEarliestDataDate != live.earliestDataDate;
      }
      if (range is CustomRange) return false;
    }
    return cardPageRange != live.pageRange ||
        cardToday != live.today ||
        cardEarliestDataDate != live.earliestDataDate;
  }

  void disposeController() {
    _controller?.dispose();
    _controller = null;
  }
}

/// A self-contained card that runs a single scalar [query] and shows the result
/// as a big number inside [CardChrome].
///
/// A convenience for the common "one KPI per card" case; for spec-driven
/// dashboards use [HandDrawnAnalyticsCard].
class AnalyticsScalarCard extends StatefulWidget {
  const AnalyticsScalarCard({
    required this.query,
    this.title,
    this.runner,
    this.formatters,
    this.dateRangeMode = const NoDateRange(),
    this.pageRange,
    this.earliestDataDate,
    this.today,
    this.asOf,
    this.onEdit,
    this.valueStyle,
    this.color,
    super.key,
  });

  final SingleQuerySpec query;
  final String? title;
  final WidgetQueryRunner? runner;
  final BridgeFormatters? formatters;

  /// How the date range is applied. A relative preset resolves against
  /// [today] (or the wall clock when [today] is null) at fetch time and
  /// re-resolves when the card next refetches — not spontaneously at a day
  /// boundary.
  final DateRangeMode dateRangeMode;
  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;

  /// Reference date for `StreakMeasure` evaluation. When null, the runner
  /// resolves it to the wall clock at fetch time, so leaving it null is the
  /// stable default — the card refetches only when an explicit value changes.
  final DateTime? asOf;
  final VoidCallback? onEdit;
  final TextStyle? valueStyle;
  final Color? color;

  @override
  State<AnalyticsScalarCard> createState() => _AnalyticsScalarCardState();
}

class _AnalyticsScalarCardState extends State<AnalyticsScalarCard>
    with _CardControllerHost {
  @override
  WidgetQueryRunner? get explicitRunner => widget.runner;

  @override
  QueryPayload? get cardPayload => widget.query;

  @override
  DateRangeMode get cardDateRangeMode => widget.dateRangeMode;

  @override
  (DateTime, DateTime)? get cardPageRange => widget.pageRange;

  @override
  DateTime? get cardEarliestDataDate => widget.earliestDataDate;

  @override
  DateTime? get cardToday => widget.today;

  @override
  DateTime? get cardAsOf => widget.asOf;

  @override
  AnalyticsQueryController buildController(WidgetQueryRunner runner) {
    return AnalyticsQueryController(
      runner: runner,
      payload: widget.query,
      dateRangeMode: widget.dateRangeMode,
      pageRange: widget.pageRange,
      earliestDataDate: widget.earliestDataDate,
      today: widget.today,
      asOf: widget.asOf,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncController();
  }

  @override
  void didUpdateWidget(AnalyticsScalarCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // [syncController] compares the new inputs against the live controller,
    // so render-only changes (title, styling) fall through without a refetch.
    syncController();
  }

  @override
  void dispose() {
    disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final formatters =
        widget.formatters ??
        AnalyticsScope.maybeOf(context)?.formatters ??
        const BridgeFormatters();
    final c = controller;

    return CardChrome(
      title: widget.title,
      onEdit: widget.onEdit,
      child: c == null
          ? const HandDrawnAnalyticsBigNumber(result: null)
          : AnimatedBuilder(
              animation: c,
              builder: (context, _) {
                return c.value.when(
                  loading: () =>
                      const HandDrawnAnalyticsBigNumber(result: null),
                  error: (e) => Text(e.humanMessage),
                  data: (result) => HandDrawnAnalyticsBigNumber(
                    result: result is SingleResult ? result.result : null,
                    formatters: formatters,
                    valueStyle: widget.valueStyle,
                    color: widget.color,
                  ),
                );
              },
            ),
    );
  }
}

/// A spec-driven dashboard card: decodes an [AnalyticsWidgetSpec]'s three JSON
/// payloads, runs the query, and renders the result by its display type inside
/// [CardChrome].
///
/// Reloads are driven by an optional [reloadTrigger]: when it fires an
/// [AnalyticsChange], [shouldReload] decides whether this card refetches.
/// Date-range changes are prop-driven rather than trigger-driven — the card
/// receives its range through [pageRange] and the spec's own date-range mode,
/// and refetches when those change — so `dateRange` trigger events are
/// skipped regardless of the predicate. A relative preset in the spec
/// resolves against [today] (or the wall clock) at fetch time and re-resolves
/// when the card next refetches. A monotonic guard inside the controller
/// drops stale reload results, and the card keeps its state alive when
/// scrolled offscreen.
class HandDrawnAnalyticsCard extends StatefulWidget {
  const HandDrawnAnalyticsCard({
    required this.spec,
    this.runner,
    this.palette,
    this.formatters,
    this.colorResolver,
    this.reloadTrigger,
    this.shouldReload = defaultShouldReload,
    this.pageRange,
    this.earliestDataDate,
    this.today,
    this.asOf,
    this.onEdit,
    this.barTemplate,
    this.lineTemplate,
    this.scatterTemplate,
    this.tableTemplate,
    this.builders,
    this.barMode = BarMode.single,
    this.combination,
    this.combinePolicy = UnmatchedBucketPolicy.drop,
    super.key,
  });

  final AnalyticsWidgetSpec spec;
  final WidgetQueryRunner? runner;
  final BridgePalette? palette;
  final BridgeFormatters? formatters;
  final SemanticColorResolver? colorResolver;

  /// Fires typed changes. Must be a `ValueListenable<AnalyticsChange?>` for
  /// [shouldReload] to inspect the change; any other [Listenable] reloads on
  /// every signal.
  final Listenable? reloadTrigger;

  /// Reload policy. Defaults to [defaultShouldReload].
  final AnalyticsCardReloadPredicate shouldReload;

  final (DateTime, DateTime)? pageRange;
  final DateTime? earliestDataDate;
  final DateTime? today;

  /// Reference date for `StreakMeasure` evaluation. When null, the runner
  /// resolves it to the wall clock at fetch time, so leaving it null is the
  /// stable default — the card refetches only when an explicit value changes.
  final DateTime? asOf;
  final VoidCallback? onEdit;

  final HandDrawnBarChart? barTemplate;
  final HandDrawnLineChart? lineTemplate;
  final HandDrawnScatterPlot? scatterTemplate;
  final HandDrawnTable? tableTemplate;

  /// Optional consumer builders forwarded to the dispatcher so a spec-driven
  /// card can render the consumer's own interactive widgets.
  final AnalyticsWidgetBuilders? builders;

  /// Bar layout used when the spec's display type resolves to the generic
  /// `bar` kind. Forwarded to [HandDrawnAnalyticsWidget.barMode].
  final BarMode barMode;

  /// How to fold a paired result into a single series before rendering it as
  /// the spec's display type. Required when the spec holds a paired query and
  /// its display type is not `scatter`. Forwarded to
  /// [HandDrawnAnalyticsWidget.combination].
  final SeriesCombination? combination;

  /// How unmatched buckets are treated when [combination] reduces a paired
  /// result. Forwarded to [HandDrawnAnalyticsWidget.combinePolicy].
  final UnmatchedBucketPolicy combinePolicy;

  @override
  State<HandDrawnAnalyticsCard> createState() => _HandDrawnAnalyticsCardState();
}

class _HandDrawnAnalyticsCardState extends State<HandDrawnAnalyticsCard>
    with _CardControllerHost, AutomaticKeepAliveClientMixin {
  // Decoded once per spec.
  QueryPayload? _payload;
  DateRangeMode _dateRangeMode = const NoDateRange();
  String _displayType = '';
  BridgeError? _decodeError;

  /// The most recent successful result, retained so a reload can keep the card
  /// at its current size instead of collapsing while the query re-runs.
  BridgeResult? _lastResult;

  @override
  bool get wantKeepAlive => true;

  @override
  WidgetQueryRunner? get explicitRunner => widget.runner;

  @override
  QueryPayload? get cardPayload => _payload;

  @override
  DateRangeMode get cardDateRangeMode => _dateRangeMode;

  @override
  (DateTime, DateTime)? get cardPageRange => widget.pageRange;

  @override
  DateTime? get cardEarliestDataDate => widget.earliestDataDate;

  @override
  DateTime? get cardToday => widget.today;

  @override
  DateTime? get cardAsOf => widget.asOf;

  @override
  AnalyticsQueryController buildController(WidgetQueryRunner runner) {
    return AnalyticsQueryController(
      runner: runner,
      payload: _payload!,
      dateRangeMode: _dateRangeMode,
      pageRange: widget.pageRange,
      earliestDataDate: widget.earliestDataDate,
      today: widget.today,
      asOf: widget.asOf,
    );
  }

  @override
  void initState() {
    super.initState();
    _decodeSpec();
    widget.reloadTrigger?.addListener(_onReloadSignal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncController();
  }

  @override
  void didUpdateWidget(HandDrawnAnalyticsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.reloadTrigger, oldWidget.reloadTrigger)) {
      oldWidget.reloadTrigger?.removeListener(_onReloadSignal);
      widget.reloadTrigger?.addListener(_onReloadSignal);
    }
    // Only data-spec fields force a re-decode; chrome-only fields (the title)
    // are re-read on every build. The decoded payload alone can't stand in
    // for this check — the data spec also spans the display and identity
    // fields — so the result is handed to [syncController] explicitly.
    final dataSpecChanged = widget.spec.dataSpecDiffersFrom(oldWidget.spec);
    if (dataSpecChanged) _decodeSpec();
    syncController(payloadChanged: dataSpecChanged);
  }

  void _decodeSpec() {
    // A (re)decode means the spec changed; drop any retained result so a new
    // spec's reload never briefly renders the previous spec's data.
    _lastResult = null;
    try {
      WidgetPayloadCodec.ensureCanDecode(widget.spec);
      _payload = WidgetPayloadCodec.decodeQueryPayload(widget.spec.queryJson);
      _dateRangeMode = WidgetPayloadCodec.decodeDateRangeMode(
        widget.spec.dateRangeModeJson,
      );
      _displayType = WidgetPayloadCodec.decodeDisplaySpec(
        widget.spec.displayJson,
      ).displayType;
      _decodeError = null;
    } on Object catch (e) {
      // The message stays fixed: decode internals would otherwise render
      // straight into the card. The throwable rides along for diagnostics.
      _decodeError = BridgeAnalyticsError.unexpected(debugDetail: e);
      _payload = null;
    }
  }

  void _onReloadSignal() {
    final trigger = widget.reloadTrigger;
    if (trigger is ValueListenable<AnalyticsChange?>) {
      final change = trigger.value;
      if (change == null) return;
      // Date-range changes are prop-driven: the card refetches when
      // [HandDrawnAnalyticsCard.pageRange] or the spec's date-range mode
      // changes, so a trigger reload here would re-run the same inputs. Skip
      // it before consulting the predicate.
      if (change.kind == AnalyticsChangeKind.dateRange) return;
      if (!widget.shouldReload(change, _sourceIds())) return;
    }
    syncController(refreshRequested: true);
  }

  Set<String> _sourceIds() {
    return switch (_payload) {
      SingleQuerySpec(query: final q) => {q.source},
      PairedQuerySpec(xQuery: final x, yQuery: final y) => {x.source, y.source},
      null => const {},
    };
  }

  @override
  void dispose() {
    widget.reloadTrigger?.removeListener(_onReloadSignal);
    disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin.

    final decodeError = _decodeError;
    if (decodeError != null) {
      return CardChrome(
        title: widget.spec.title,
        onEdit: widget.onEdit,
        child: Text(decodeError.humanMessage),
      );
    }

    final c = controller;
    return CardChrome(
      title: widget.spec.title,
      onEdit: widget.onEdit,
      child: c == null
          ? const SizedBox.shrink()
          : AnimatedBuilder(
              animation: c,
              builder: (context, _) {
                return c.value.when(
                  // On reload the query briefly re-enters the loading state.
                  // Keep showing the last result so the card holds its size
                  // instead of collapsing and shifting the layout; fall back to
                  // an empty box only before the first result arrives.
                  loading: () => _lastResult == null
                      ? const SizedBox.shrink()
                      : _dataWidget(_lastResult!),
                  error: (e) => Text(e.humanMessage),
                  data: (result) {
                    _lastResult = result;
                    return _dataWidget(result);
                  },
                );
              },
            ),
    );
  }

  /// Renders a resolved [BridgeResult] through the dispatcher. Shared by the
  /// data branch and the reload (loading-with-previous-result) branch.
  Widget _dataWidget(BridgeResult result) {
    return HandDrawnAnalyticsWidget(
      result: result,
      displayType: _displayType,
      palette: widget.palette,
      formatters: widget.formatters,
      colorResolver: widget.colorResolver,
      barTemplate: widget.barTemplate,
      lineTemplate: widget.lineTemplate,
      scatterTemplate: widget.scatterTemplate,
      tableTemplate: widget.tableTemplate,
      builders: widget.builders,
      barMode: widget.barMode,
      combination: widget.combination,
      combinePolicy: widget.combinePolicy,
    );
  }
}

/// Content comparison for [AnalyticsWidgetSpec], whose `==` is identity-keyed
/// (the row `id`).
///
/// The codec round-trips losslessly, so comparing the persisted JSON strings
/// is an exact deep-equality check on everything the card fetches, computes,
/// or displays — cheaper than decoding either side.
extension on AnalyticsWidgetSpec {
  /// Whether any field that defines what a card fetches, computes, or
  /// displays differs from [other]. Chrome-only fields (the title) are
  /// excluded: they are re-read on every build and need no re-decode.
  bool dataSpecDiffersFrom(AnalyticsWidgetSpec other) {
    return id != other.id ||
        schemaVersion != other.schemaVersion ||
        queryJson != other.queryJson ||
        displayJson != other.displayJson ||
        dateRangeModeJson != other.dateRangeModeJson;
  }
}
