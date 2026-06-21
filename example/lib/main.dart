import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:flutter/material.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

/// End-to-end demo of `hand_drawn_analytics`.
///
/// The package is a bridge: you give it an `analytics_toolkit` *query* plus a
/// `hand_drawn_toolkit` styling template, and it runs the aggregation and
/// renders the result. Nothing on screen is a hand-drawn chart literal — every
/// chart's geometry is computed from raw records. Edit the data (add an event,
/// toggle a habit day, change the window) and the affected charts recompute.
///
/// Two entry points are shown:
///
/// - The query-backed chart widgets (`HandDrawnAnalyticsBarChart` and
///   `HandDrawnAnalyticsScatterPlot` here): construct one in code with a query
///   and a styling template; it runs the query and renders. The type is known
///   statically, so their tap callbacks are typed — the bar chart reports a
///   [BarHitTestResult] on a hit and clears its readout via `onTapMiss`.
/// - [HandDrawnAnalyticsCard]: the spec-driven dashboard unit. It decodes a
///   persisted [AnalyticsWidgetSpec] (query + display-type + date-range, all
///   JSON), runs it, and routes the result through the dispatcher. The display
///   type is a runtime string, so the resizable table reaches its rendering
///   through an [AnalyticsWidgetBuilders] registry rather than a typed
///   callback.
void main() => runApp(const ExampleApp());

// ── Shared vocabulary ──────────────────────────────────────────────────────

const _categories = ['Work', 'Personal', 'Health'];
const _priorities = ['High', 'Medium', 'Low'];
const _durations = [15, 30, 45, 60, 90, 120];

/// Days of history each habit tracks.
const _habitWindowDays = 14;

typedef _NewEvent = ({
  String category,
  String priority,
  int duration,
  DateTime date,
});

// ── Events source ──────────────────────────────────────────────────────────

const _eventsSourceId = 'events';

const _categoryRef = FieldRef(sourceId: _eventsSourceId, fieldId: 'category');
const _priorityRef = FieldRef(sourceId: _eventsSourceId, fieldId: 'priority');
const _durationRef = FieldRef(sourceId: _eventsSourceId, fieldId: 'duration');
const _occurredAtRef = FieldRef(
  sourceId: _eventsSourceId,
  fieldId: 'occurredAt',
);

FieldDef _eventField(
  String id,
  String name,
  FieldType type, {
  bool groupable = false,
  bool aggregatable = false,
}) {
  return FieldDef(
    fieldId: id,
    sourceId: _eventsSourceId,
    displayName: name,
    fieldType: type,
    filterable: true,
    groupable: groupable,
    aggregatable: aggregatable,
    sortable: true,
  );
}

/// A stream of timestamped, categorised events.
final SourceDef _eventsSource = SourceDef(
  sourceId: _eventsSourceId,
  displayName: 'Events',
  primaryDateFieldId: 'occurredAt',
  fields: [
    _eventField('id', 'ID', FieldType.string),
    _eventField('category', 'Category', FieldType.enumeration, groupable: true),
    _eventField('priority', 'Priority', FieldType.enumeration, groupable: true),
    _eventField('duration', 'Duration', FieldType.integer, aggregatable: true),
    _eventField(
      'occurredAt',
      'Occurred at',
      FieldType.dateTime,
      groupable: true,
    ),
  ],
);

SourceRecord _eventRecord({
  required int id,
  required String category,
  required String priority,
  required int duration,
  required DateTime when,
}) {
  return SourceRecord(
    fields: {
      'id': StringValue('evt-$id'),
      'category': EnumValue(category),
      'priority': EnumValue(priority),
      'duration': IntValue(duration),
      'occurredAt': DateTimeValue(when),
    },
  );
}

/// 60 deterministic seed events — category, priority, and duration are
/// decorrelated so the grouped queries produce a real spread.
List<SourceRecord> _seedEvents() {
  final now = DateTime.now();
  return [
    for (var i = 0; i < 60; i++)
      _eventRecord(
        id: i,
        category: _categories[i % 3],
        priority: _priorities[(i ~/ 4) % 3],
        duration: 15 + (i % 8) * 15,
        when: now.subtract(Duration(days: 1 + (i * 44) ~/ 60, hours: i % 24)),
      ),
  ];
}

DateTime _eventDate(SourceRecord r) {
  final v = r.fields['occurredAt'];
  return v is DateTimeValue ? v.value : DateTime(0);
}

String _eventCategory(SourceRecord r) {
  final v = r.fields['category'];
  return v is EnumValue ? v.value : '?';
}

// ── Habits source (drives the streak leaderboard) ───────────────────────────

const _habitsSourceId = 'habits';

const _habitIdRef = FieldRef(sourceId: _habitsSourceId, fieldId: 'habitId');
const _habitNameRef = FieldRef(sourceId: _habitsSourceId, fieldId: 'habitName');
const _scheduledDateRef = FieldRef(
  sourceId: _habitsSourceId,
  fieldId: 'scheduledDate',
);
const _statusRef = FieldRef(sourceId: _habitsSourceId, fieldId: 'status');

FieldDef _habitField(
  String id,
  String name,
  FieldType type, {
  bool groupable = false,
}) {
  return FieldDef(
    fieldId: id,
    sourceId: _habitsSourceId,
    displayName: name,
    fieldType: type,
    filterable: true,
    groupable: groupable,
    aggregatable: false,
    sortable: true,
  );
}

/// Daily habit check-ins, each scheduled day marked done or missed.
final SourceDef _habitsSource = SourceDef(
  sourceId: _habitsSourceId,
  displayName: 'Habits',
  primaryDateFieldId: 'scheduledDate',
  fields: [
    _habitField('habitId', 'Habit ID', FieldType.string, groupable: true),
    _habitField('habitName', 'Habit', FieldType.string),
    _habitField(
      'scheduledDate',
      'Scheduled',
      FieldType.dateTime,
      groupable: true,
    ),
    _habitField('status', 'Status', FieldType.enumeration, groupable: true),
  ],
);

/// A habit and its per-day completion flags. The example edits this model; the
/// habit records handed to the runner are derived from it on every fetch.
class _HabitModel {
  _HabitModel({required this.id, required this.name, required this.done});

  final String id;
  final String name;

  /// One flag per tracked day; index 0 is the oldest day.
  final List<bool> done;
}

/// Four seed habits with distinct streak shapes.
List<_HabitModel> _seedHabits() {
  bool done(String habitId, int day) => switch (habitId) {
    'h1' => day != 10, // one miss
    'h2' => day % 3 != 2, // miss every third
    'h3' => true, // perfect run
    _ => day < 12, // missed the last two
  };
  return [
    for (final habit in const [
      (id: 'h1', name: 'Morning run'),
      (id: 'h2', name: 'Read'),
      (id: 'h3', name: 'Meditate'),
      (id: 'h4', name: 'Journal'),
    ])
      _HabitModel(
        id: habit.id,
        name: habit.name,
        done: [for (var d = 0; d < _habitWindowDays; d++) done(habit.id, d)],
      ),
  ];
}

/// Flattens the editable habit models into the check-in records the runner
/// queries.
List<SourceRecord> _habitRecords(List<_HabitModel> habits) {
  final now = DateTime.now();
  return [
    for (final habit in habits)
      for (var d = 0; d < habit.done.length; d++)
        SourceRecord(
          fields: {
            'habitId': StringValue(habit.id),
            'habitName': StringValue(habit.name),
            'scheduledDate': DateTimeValue(
              now.subtract(Duration(days: habit.done.length - d)),
            ),
            'status': EnumValue(habit.done[d] ? 'done' : 'missed'),
          },
        ),
  ];
}

// ── Spec-driven widget definitions (the card path) ──────────────────────────

/// Builds the persisted specs the card section decodes. Each carries a query,
/// a display-type string, and a date-range mode, all as JSON via the toolkit
/// codec — exactly what a saved dashboard would hold.
List<AnalyticsWidgetSpec> _buildSpecs() {
  final now = DateTime.now();

  AnalyticsWidgetSpec build(
    String id,
    String title,
    int order,
    AnalyticsQuerySpec query,
    String displayType, [
    DateRangeMode dateRangeMode = const UsePageRange(),
  ]) {
    return AnalyticsWidgetSpec(
      id: id,
      title: title,
      queryJson: WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: query),
      ),
      displayJson: WidgetPayloadCodec.encodeDisplaySpec(
        DisplaySpec(displayType: displayType),
      ),
      dateRangeModeJson: WidgetPayloadCodec.encodeDateRangeMode(dateRangeMode),
      sortOrder: order,
      createdAt: now,
      updatedAt: now,
    );
  }

  return [
    // One group-by → SeriesResult → bar chart.
    build(
      'events-by-category',
      'Events by category',
      0,
      AnalyticsQuerySpec(
        source: _eventsSourceId,
        measures: const [CountMeasure()],
        groupBys: const [FieldGroupBy(fieldRef: _categoryRef)],
      ),
      'bar',
    ),
    // A day grain → SeriesResult → line chart.
    build(
      'events-over-time',
      'Events over time',
      1,
      AnalyticsQuerySpec(
        source: _eventsSourceId,
        measures: const [CountMeasure()],
        groupBys: [
          TimeGroupBy(dateFieldRef: _occurredAtRef, grain: TimeGrain.day),
        ],
      ),
      'line',
    ),
    // A DeltaOp makes each bucket the day-over-day change, so values are
    // signed and the line axis crosses zero.
    build(
      'events-delta',
      'Day-over-day change',
      2,
      AnalyticsQuerySpec(
        source: _eventsSourceId,
        measures: const [CountMeasure()],
        groupBys: [
          TimeGroupBy(dateFieldRef: _occurredAtRef, grain: TimeGrain.day),
        ],
        derivedOperation: const DeltaOp(),
      ),
      'line',
    ),
    // Two group-bys → MultiSeriesResult → stacked bar.
    build(
      'category-by-priority',
      'Category by priority',
      3,
      AnalyticsQuerySpec(
        source: _eventsSourceId,
        measures: const [CountMeasure()],
        groupBys: const [
          FieldGroupBy(fieldRef: _categoryRef),
          FieldGroupBy(fieldRef: _priorityRef),
        ],
      ),
      'stackedBar',
    ),
    // StreakMeasure → TableResult → streak leaderboard. Reads the habits
    // source, so the event controls leave it untouched. A streak spans an
    // entity's full history, so it opts out of the page range with
    // NoDateRange (the validator rejects UsePageRange here).
    build(
      'habit-streaks',
      'Habit streaks',
      5,
      AnalyticsQuerySpec(
        source: _habitsSourceId,
        measures: const [
          StreakMeasure(
            entityIdField: _habitIdRef,
            scheduledDateField: _scheduledDateRef,
            statusField: _statusRef,
            completedStatusValue: 'done',
            entityLabelField: _habitNameRef,
          ),
        ],
      ),
      'streakLeaderboard',
      const NoDateRange(),
    ),
  ];
}

String _fmtDate(DateTime d) => '${d.month}/${d.day}';

/// Table styling shared by every table in the demo: sketchy row and column
/// dividers so the grid reads as a table (and the column boundaries are visible
/// to drag in the resizable variant).
const _tableTemplate = HandDrawnTable(
  columns: [],
  rows: [],
  rowDividers: TableDividerStyle(irregularity: 3),
  columnDividers: TableDividerStyle(irregularity: 3),
);

// ── App ─────────────────────────────────────────────────────────────────────

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'hand_drawn_analytics example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: const Color(0xFFF5F0E8)),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  /// Neutral palette and one-decimal number formatting, shared by every chart
  /// through the enclosing [AnalyticsScope].
  static const _palette = BridgePalette(
    colors: [
      Color(0xFF6B9BD2),
      Color(0xFFE08A7B),
      Color(0xFF6A9E6A),
      Color(0xFFD9B36A),
      Color(0xFF9B82B8),
      Color(0xFF6FB0A8),
    ],
  );

  /// Cards listen to this; firing it makes them reload selectively.
  final ValueNotifier<AnalyticsChange?> _reload = ValueNotifier(null);

  /// The mutable event store. The add-event form appends to it.
  final List<SourceRecord> _eventStore = [];

  /// The editable habit models; check-in records are derived on every fetch.
  final List<_HabitModel> _habits = [];

  late final WidgetQueryRunner _runner;
  late final SourceSnapshotCache _cache;
  late final List<AnalyticsWidgetSpec> _specs;

  int _nextEventId = 60; // ids 0..59 are the seed events
  int _nextHabitId = 5; // ids h1..h4 are the seed habits
  late DateTimeRange _selectedRange;

  @override
  void initState() {
    super.initState();
    _eventStore.addAll(_seedEvents());
    _habits.addAll(_seedHabits());
    _cache = SourceSnapshotCache(fetcher: _fetchRecords);
    _runner = WidgetQueryRunner(
      listSources: () => [_eventsSource, _habitsSource],
      fetchRecords: _fetchRecords,
    );
    _specs = _buildSpecs();
    final today = DateUtils.dateOnly(DateTime.now());
    _selectedRange = DateTimeRange(
      start: today.subtract(const Duration(days: 30)),
      end: today,
    );
  }

  @override
  void dispose() {
    _reload.dispose();
    super.dispose();
  }

  // ── Data provider ─────────────────────────────────────────────────────────

  Future<List<SourceRecord>> _fetchRecords(
    String sourceId, {
    (DateTime, DateTime)? dateBound,
  }) async {
    final store = switch (sourceId) {
      _eventsSourceId => List.of(_eventStore),
      _habitsSourceId => _habitRecords(_habits),
      _ => const <SourceRecord>[],
    };
    if (dateBound == null) return store;
    // Honour the half-open [start, end) bound the runner passes through.
    final (start, end) = dateBound;
    final dateField = sourceId == _habitsSourceId
        ? 'scheduledDate'
        : 'occurredAt';
    return store.where((r) {
      final value = r.fields[dateField];
      if (value is! DateTimeValue) return false;
      final t = value.value;
      return !t.isBefore(start) && t.isBefore(end);
    }).toList();
  }

  /// The page range the cards read. The end is pushed a day past the picked
  /// end date so the whole end day falls inside the half-open window.
  (DateTime, DateTime) get _pageRange =>
      (_selectedRange.start, _selectedRange.end.add(const Duration(days: 1)));

  // ── Interactions ──────────────────────────────────────────────────────────

  Future<void> _addEvent() async {
    final result = await showModalBottomSheet<_NewEvent>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddEventSheet(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _eventStore.add(
        _eventRecord(
          id: _nextEventId,
          category: result.category,
          priority: result.priority,
          duration: result.duration,
          when: result.date,
        ),
      );
      _nextEventId++;
    });
    _fireSourceData(_eventsSourceId);
  }

  Future<void> _addHabit() async {
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddHabitSheet(),
    );
    if (name == null || !mounted) return;
    setState(() {
      _habits.add(
        _HabitModel(
          id: 'h$_nextHabitId',
          name: name,
          done: List<bool>.filled(_habitWindowDays, false),
        ),
      );
      _nextHabitId++;
    });
    _fireSourceData(_habitsSourceId);
  }

  void _toggleHabitDay(String habitId, int day) {
    final habit = _habits.firstWhere((h) => h.id == habitId);
    setState(() => habit.done[day] = !habit.done[day]);
    _fireSourceData(_habitsSourceId);
  }

  /// A source-data change invalidates that source's cache snapshot, then fires
  /// the reload so the matching cards refetch.
  void _fireSourceData(String sourceId) {
    _cache.invalidate(sourceIds: {sourceId});
    _reload.value = AnalyticsChange(
      kind: AnalyticsChangeKind.sourceData,
      sourceIds: {sourceId},
    );
  }

  Future<void> _pickRange() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
      initialDateRange: _selectedRange,
    );
    if (picked == null || !mounted) return;
    setState(() => _selectedRange = picked);
    _reload.value = AnalyticsChange(kind: AnalyticsChangeKind.dateRange);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // One scope supplies the runner, palette, and formatters to every
    // descendant chart, so individual widgets need not repeat them.
    return AnalyticsScope(
      sources: [_eventsSource, _habitsSource],
      cache: _cache,
      palette: _palette,
      child: Scaffold(
        appBar: AppBar(title: const Text('hand_drawn_analytics')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeader(
              title: 'A bridge between two packages',
              intro:
                  'Every chart below runs an analytics_toolkit query over raw '
                  'records and renders it with hand_drawn_toolkit. The geometry '
                  'is computed by the package — nothing here is a hand-drawn '
                  'chart literal. Edit the data, and the charts recompute.',
            ),
            const SizedBox(height: 20),
            _controls(),
            const SizedBox(height: 8),
            _eventStatus(),
            const SizedBox(height: 24),

            // ── Spec-driven dashboard (the card path) ──
            const _SectionHeader(
              title: 'Saved dashboard (spec-driven)',
              intro:
                  'These cards decode a persisted spec — query, display type, '
                  'and date range, all JSON — and run it end to end, owning '
                  'loading, empty, and error states and reloading on the '
                  'matching change. The display type is a runtime string '
                  'resolved by the dispatcher.',
            ),
            const SizedBox(height: 12),
            for (final id in const [
              'events-by-category',
              'events-over-time',
              'events-delta',
              'category-by-priority',
            ]) ...[_card(_specById(id)), const SizedBox(height: 16)],

            const SizedBox(height: 12),
            const _SectionHeader(
              title: 'Resizable table (spec-driven)',
              intro:
                  'A table card whose columns can be dragged to resize — grab a '
                  'column boundary and drag. Widths are consumer-owned: '
                  'restored from this widget\'s state and persisted back through '
                  'a callback. Toggle the extra column to see widths reset when '
                  'the column count changes. The card reaches the resizable '
                  'rendering through the table builder slot.',
            ),
            const SizedBox(height: 12),
            _ResizableTableCard(runner: _runner, pageRange: () => _pageRange),
            const SizedBox(height: 16),
            const _SectionHeader(
              title: 'Resizable table (direct, no card)',
              intro:
                  'The same HandDrawnTableView fed a hardcoded TableMapping '
                  'directly — no card, no query, no reload. Compare resizing '
                  'here against the spec-driven table above to tell whether a '
                  'resize bug is in the table widget itself or in the card path '
                  'around it.',
            ),
            const SizedBox(height: 12),
            const _DirectResizableTable(),

            const SizedBox(height: 28),

            // ── Direct query-backed widgets ──
            const _SectionHeader(
              title: 'Query-backed widgets (direct)',
              intro:
                  'Constructed in code with a query and a styling template. '
                  'Because the type is known statically, the tap callbacks are '
                  'typed: each chart reports a hit (a BarHitTestResult or '
                  'LineHitTestResult) and clears its readout on a miss '
                  '(onTapMiss). The bar charts also expose a legend-layout '
                  'toggle, which simply swaps the template\'s legendConfig.',
            ),
            const SizedBox(height: 12),
            _InteractiveBar(pageRange: () => _pageRange),
            const SizedBox(height: 16),
            _InteractiveStackedBar(pageRange: () => _pageRange),
            const SizedBox(height: 16),
            _InteractiveLine(pageRange: () => _pageRange),
            const SizedBox(height: 16),
            _scatterCard(),
            const SizedBox(height: 28),

            // ── Raw input ──
            const _SectionHeader(
              title: 'Recent events',
              intro:
                  'The raw records the charts are computed from. A plain list, '
                  'not an analytics card — the toolkit has no raw-row result '
                  'shape.',
            ),
            const SizedBox(height: 12),
            _recentEventsPanel(),
            const SizedBox(height: 28),

            // ── Streak leaderboard + editor ──
            const _SectionHeader(
              title: 'Habit streaks',
              intro:
                  'A second source, shown through a spec-driven card. The '
                  'streak leaderboard reads it via a StreakMeasure, so the '
                  'event controls leave it untouched. Edit the habit grid and '
                  'the leaderboard recomputes.',
            ),
            const SizedBox(height: 12),
            _card(_specById('habit-streaks')),
            const SizedBox(height: 12),
            _HabitEditor(
              habits: _habits,
              onToggle: _toggleHabitDay,
              onAddHabit: _addHabit,
            ),
          ],
        ),
      ),
    );
  }

  AnalyticsWidgetSpec _specById(String id) =>
      _specs.firstWhere((s) => s.id == id);

  Widget _card(AnalyticsWidgetSpec spec, {AnalyticsWidgetBuilders? builders}) {
    return HandDrawnAnalyticsCard(
      key: ValueKey(spec.id),
      spec: spec,
      runner: _runner,
      reloadTrigger: _reload,
      pageRange: _pageRange,
      // StreakMeasure needs a reference date; harmless for other specs.
      asOf: DateTime.now(),
      tableTemplate: _tableTemplate,
      builders: builders,
    );
  }

  Widget _controls() {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _addEvent,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add event'),
        ),
        OutlinedButton.icon(
          onPressed: _pickRange,
          icon: const Icon(Icons.date_range, size: 18),
          label: const Text('Change window'),
        ),
      ],
    );
  }

  Widget _eventStatus() {
    final (start, end) = _pageRange;
    final inWindow = _eventStore
        .where(
          (r) => !_eventDate(r).isBefore(start) && _eventDate(r).isBefore(end),
        )
        .length;
    return Text(
      '$inWindow of ${_eventStore.length} events · window '
      '${_fmtDate(_selectedRange.start)} – ${_fmtDate(_selectedRange.end)}',
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: Color(0xFF4A7C6F),
      ),
    );
  }

  /// A scatter of duration vs. priority isn't meaningful, so this plots a
  /// paired query: events-by-category (x) against total-duration-by-category
  /// (y), aligned by the shared category bucket.
  Widget _scatterCard() {
    return _Panel(
      child: SizedBox(
        height: 260,
        child: HandDrawnAnalyticsScatterPlot(
          query: PairedQuerySpec(
            xQuery: AnalyticsQuerySpec(
              source: _eventsSourceId,
              measures: const [CountMeasure()],
              groupBys: const [FieldGroupBy(fieldRef: _categoryRef)],
            ),
            yQuery: AnalyticsQuerySpec(
              source: _eventsSourceId,
              measures: const [
                FieldMeasure(fieldRef: _durationRef, aggregation: SumAgg()),
              ],
              groupBys: const [FieldGroupBy(fieldRef: _categoryRef)],
            ),
          ),
          chart: const HandDrawnScatterPlot(data: null),
          dateRangeMode: const UsePageRange(),
          pageRange: _pageRange,
          title: 'Count vs. total duration, by category',
          xAxisLabel: 'Event count',
          yAxisLabel: 'Total minutes',
        ),
      ),
    );
  }

  Widget _recentEventsPanel() {
    final recent = [..._eventStore]
      ..sort((a, b) => _eventDate(b).compareTo(_eventDate(a)));
    final shown = recent.take(8).toList();
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Recent events (raw input)',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final r in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${_fmtDate(_eventDate(r))}  ·  ${_eventCategory(r)}',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF6B6B6B),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Interactive direct charts (tap-on-miss + legend toggle) ─────────────────

/// A boxed readout beneath an interactive chart. Null shows the idle hint.
class _TapReadout extends StatelessWidget {
  const _TapReadout({required this.value, required this.idleHint});

  final String? value;
  final String idleHint;

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDF8),
        border: Border.all(color: const Color(0xFFD8D0C0)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        v ?? idleHint,
        style: TextStyle(
          fontSize: 12.5,
          fontStyle: v == null ? FontStyle.italic : FontStyle.normal,
          color: v == null ? const Color(0xFF8A857B) : const Color(0xFF1A1A1A),
        ),
      ),
    );
  }
}

/// The three legend layouts the toggle cycles through, with display labels.
const _legendConfigs = [
  ('Inline', ChartLegendConfig.inlineBottom),
  ('Boxed below', ChartLegendConfig.externalBottomBoxed),
  ('Boxed right', ChartLegendConfig.externalRightBoxed),
];

/// A segmented control that cycles the legend layout for a multi-series chart.
class _LegendToggle extends StatelessWidget {
  const _LegendToggle({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text(
          'Legend: ',
          style: TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
        ),
        const SizedBox(width: 6),
        for (var i = 0; i < _legendConfigs.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(
                _legendConfigs[i].$1,
                style: const TextStyle(fontSize: 11.5),
              ),
              selected: i == index,
              onSelected: (_) => onChanged(i),
            ),
          ),
      ],
    );
  }
}

/// Events by category as a single bar chart. Typed `onTap`
/// ([BarHitTestResult]) pins a bar; `onTapMiss` clears it.
class _InteractiveBar extends StatefulWidget {
  const _InteractiveBar({required this.pageRange});

  final (DateTime, DateTime) Function() pageRange;

  @override
  State<_InteractiveBar> createState() => _InteractiveBarState();
}

class _InteractiveBarState extends State<_InteractiveBar> {
  String? _tapped;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 240,
            child: HandDrawnAnalyticsBarChart(
              query: SingleQuerySpec(
                query: AnalyticsQuerySpec(
                  source: _eventsSourceId,
                  measures: const [CountMeasure()],
                  groupBys: const [FieldGroupBy(fieldRef: _categoryRef)],
                ),
              ),
              chart: const HandDrawnBarChart(data: null),
              dateRangeMode: const UsePageRange(),
              pageRange: widget.pageRange(),
              integerValued: true,
              title: 'Events by category — tap a bar',
              onTap: (hit) {
                final seg = hit.segment;
                final n = seg.value.toInt();
                setState(
                  () =>
                      _tapped = '${seg.barLabel}: $n event${n == 1 ? '' : 's'}',
                );
              },
              onTapMiss: () => setState(() => _tapped = null),
            ),
          ),
          const SizedBox(height: 8),
          _TapReadout(
            value: _tapped,
            idleHint: 'No bar pinned — tap a bar, or tap empty space to clear.',
          ),
        ],
      ),
    );
  }
}

/// Category-by-priority as a stacked bar chart (two group-bys →
/// MultiSeriesResult → `BarMode.stacked`). A tap reports the bar plus the
/// stacked series; the legend toggle swaps the template's layout.
class _InteractiveStackedBar extends StatefulWidget {
  const _InteractiveStackedBar({required this.pageRange});

  final (DateTime, DateTime) Function() pageRange;

  @override
  State<_InteractiveStackedBar> createState() => _InteractiveStackedBarState();
}

class _InteractiveStackedBarState extends State<_InteractiveStackedBar> {
  String? _tapped;
  int _legend = 0;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LegendToggle(
            index: _legend,
            onChanged: (i) => setState(() => _legend = i),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 260,
            child: HandDrawnAnalyticsBarChart(
              query: SingleQuerySpec(
                query: AnalyticsQuerySpec(
                  source: _eventsSourceId,
                  measures: const [CountMeasure()],
                  groupBys: const [
                    FieldGroupBy(fieldRef: _categoryRef),
                    FieldGroupBy(fieldRef: _priorityRef),
                  ],
                ),
              ),
              mode: BarMode.stacked,
              chart: HandDrawnBarChart(
                data: null,
                legendConfig: _legendConfigs[_legend].$2,
              ),
              dateRangeMode: const UsePageRange(),
              pageRange: widget.pageRange(),
              integerValued: true,
              title: 'Category by priority — tap a segment',
              onTap: (hit) {
                final seg = hit.segment;
                setState(
                  () => _tapped =
                      '${seg.barLabel} · ${seg.category}: ${seg.value.toInt()}',
                );
              },
              onTapMiss: () => setState(() => _tapped = null),
            ),
          ),
          const SizedBox(height: 8),
          _TapReadout(
            value: _tapped,
            idleHint:
                'No segment pinned — tap a segment, or empty space to '
                'clear.',
          ),
        ],
      ),
    );
  }
}

/// Events over time as a line chart. Typed `onTap` ([LineHitTestResult], a
/// sealed type whose [LinePointHit] case carries the hit point) pins a point;
/// `onTapMiss` clears it.
class _InteractiveLine extends StatefulWidget {
  const _InteractiveLine({required this.pageRange});

  final (DateTime, DateTime) Function() pageRange;

  @override
  State<_InteractiveLine> createState() => _InteractiveLineState();
}

class _InteractiveLineState extends State<_InteractiveLine> {
  String? _tapped;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 240,
            child: HandDrawnAnalyticsLineChart(
              query: SingleQuerySpec(
                query: AnalyticsQuerySpec(
                  source: _eventsSourceId,
                  measures: const [CountMeasure()],
                  groupBys: [
                    TimeGroupBy(
                      dateFieldRef: _occurredAtRef,
                      grain: TimeGrain.day,
                    ),
                  ],
                ),
              ),
              chart: const HandDrawnLineChart(data: null),
              dateRangeMode: const UsePageRange(),
              pageRange: widget.pageRange(),
              integerValued: true,
              title: 'Events over time — tap a point',
              onTap: (hit) {
                // The hit is a point or a segment; report the point when we
                // landed on one, else note the segment.
                setState(
                  () => _tapped = switch (hit) {
                    LinePointHit(point: final p) => 'Day value: ${p.y.toInt()}',
                    LineSegmentHit() => 'On the line between points',
                  },
                );
              },
              onTapMiss: () => setState(() => _tapped = null),
            ),
          ),
          const SizedBox(height: 8),
          _TapReadout(
            value: _tapped,
            idleHint:
                'No point pinned — tap near the line, or empty space to '
                'clear.',
          ),
        ],
      ),
    );
  }
}

// ── Resizable table card (spec-driven, with a column-count toggle) ──────────

/// A spec-driven table whose columns can be dragged to resize, plus a toggle
/// that adds/removes a second group-by (2 vs. 3 columns). Changing the column
/// count makes [HandDrawnTableView] reset the widths to defaults and report the
/// reset, which this widget persists. Widths are stored per column shape so a
/// restored layout only applies to the shape it was saved for.
class _ResizableTableCard extends StatefulWidget {
  const _ResizableTableCard({required this.runner, required this.pageRange});

  final WidgetQueryRunner runner;
  final (DateTime, DateTime) Function() pageRange;

  @override
  State<_ResizableTableCard> createState() => _ResizableTableCardState();
}

class _ResizableTableCardState extends State<_ResizableTableCard> {
  bool _splitByPriority = false;

  /// Consumer-owned widths, keyed by column count so each shape keeps its own.
  final Map<int, List<double>> _widthsByShape = {};

  AnalyticsWidgetSpec _spec() {
    final now = DateTime.now();
    final query = AnalyticsQuerySpec(
      source: _eventsSourceId,
      measures: const [
        FieldMeasure(fieldRef: _durationRef, aggregation: SumAgg()),
      ],
      groupBys: [
        const FieldGroupBy(fieldRef: _categoryRef),
        if (_splitByPriority) const FieldGroupBy(fieldRef: _priorityRef),
      ],
    );
    return AnalyticsWidgetSpec(
      // The id encodes the shape so the card rebuilds (and re-runs) on toggle.
      id: 'duration-table-${_splitByPriority ? 'split' : 'flat'}',
      title: 'Total duration by category',
      queryJson: WidgetPayloadCodec.encodeQueryPayload(
        SingleQuerySpec(query: query),
      ),
      displayJson: WidgetPayloadCodec.encodeDisplaySpec(
        const DisplaySpec(displayType: 'table'),
      ),
      dateRangeModeJson: WidgetPayloadCodec.encodeDateRangeMode(
        const UsePageRange(),
      ),
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Widget build(BuildContext context) {
    final spec = _spec();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              'Split by priority (adds a column): ',
              style: TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
            ),
            Switch(
              value: _splitByPriority,
              onChanged: (v) => setState(() => _splitByPriority = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        HandDrawnAnalyticsCard(
          key: ValueKey(spec.id),
          spec: spec,
          runner: widget.runner,
          pageRange: widget.pageRange(),
          builders: AnalyticsWidgetBuilders(
            table: (mapping) {
              final shape = mapping.columns.length;
              return HandDrawnTableView(
                mapping: mapping,
                chart: _tableTemplate,
                resizable: true,
                initialColumnWidths: _widthsByShape[shape],
                onColumnWidthsChanged: (widths) =>
                    _widthsByShape[shape] = widths,
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Direct resizable table (no card) ───────────────────────────────────────

/// Feeds a fixed [TableMapping] straight into [HandDrawnTableView] with no
/// card, query, or reload around it. Used to isolate whether a resize problem
/// lives in the table widget or in the spec-driven card path.
class _DirectResizableTable extends StatefulWidget {
  const _DirectResizableTable();

  @override
  State<_DirectResizableTable> createState() => _DirectResizableTableState();
}

class _DirectResizableTableState extends State<_DirectResizableTable> {
  List<double>? _widths;

  static const _mapping = TableMapping(
    columns: [
      HandDrawnTableColumn(header: 'Category'),
      HandDrawnTableColumn(header: 'Minutes', alignment: Alignment.centerRight),
    ],
    rows: [
      HandDrawnTableRow(cells: ['Health', '855']),
      HandDrawnTableRow(cells: ['Personal', '900']),
      HandDrawnTableRow(cells: ['Work', '945']),
    ],
    truncatedCount: 0,
  );

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: HandDrawnTableView(
        mapping: _mapping,
        chart: _tableTemplate,
        resizable: true,
        initialColumnWidths: _widths,
        onColumnWidthsChanged: (widths) => _widths = widths,
      ),
    );
  }
}

// ── Add-event form ──────────────────────────────────────────────────────────

class _AddEventSheet extends StatefulWidget {
  const _AddEventSheet();

  @override
  State<_AddEventSheet> createState() => _AddEventSheetState();
}

class _AddEventSheetState extends State<_AddEventSheet> {
  String _category = _categories.first;
  String _priority = _priorities.first;
  int _duration = _durations.first;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    _date = DateUtils.dateOnly(DateTime.now());
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    setState(() => _date = picked);
  }

  void _submit() {
    Navigator.of(context).pop<_NewEvent>((
      category: _category,
      priority: _priority,
      duration: _duration,
      date: _date,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'New event',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Pick a past date to add history, or keep today. An event '
              'outside the active window will not move the charts until the '
              'window includes it.',
              style: TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
            ),
            const SizedBox(height: 16),
            _LabeledDropdown<String>(
              label: 'Category',
              value: _category,
              options: _categories,
              optionLabel: (c) => c,
              onChanged: (v) => setState(() => _category = v),
            ),
            const SizedBox(height: 12),
            _LabeledDropdown<String>(
              label: 'Priority',
              value: _priority,
              options: _priorities,
              optionLabel: (p) => p,
              onChanged: (v) => setState(() => _priority = v),
            ),
            const SizedBox(height: 12),
            _LabeledDropdown<int>(
              label: 'Duration',
              value: _duration,
              options: _durations,
              optionLabel: (d) => '$d min',
              onChanged: (v) => setState(() => _duration = v),
            ),
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Date',
                  style: TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
                ),
                const SizedBox(height: 2),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_fmtDate(_date)),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _submit, child: const Text('Add event')),
          ],
        ),
      ),
    );
  }
}

// ── Add-habit form ──────────────────────────────────────────────────────────

class _AddHabitSheet extends StatefulWidget {
  const _AddHabitSheet();

  @override
  State<_AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends State<_AddHabitSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    Navigator.of(context).pop<String>(name.isEmpty ? null : name);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'New habit',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'The habit starts with an empty history — tap its days in the '
              'editor to mark them done.',
              style: TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Habit name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: _submit, child: const Text('Add habit')),
          ],
        ),
      ),
    );
  }
}

// ── Habit editor ────────────────────────────────────────────────────────────

/// The editable input behind the streak leaderboard: one row per habit, one
/// tappable cell per tracked day.
class _HabitEditor extends StatelessWidget {
  const _HabitEditor({
    required this.habits,
    required this.onToggle,
    required this.onAddHabit,
  });

  final List<_HabitModel> habits;
  final void Function(String habitId, int day) onToggle;
  final VoidCallback onAddHabit;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Habit editor',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          const Text(
            'Tap a day to toggle done/missed — the leaderboard above '
            'recomputes.',
            style: TextStyle(fontSize: 11.5, color: Color(0xFF7A766E)),
          ),
          const SizedBox(height: 12),
          for (final habit in habits) ...[
            _HabitRow(habit: habit, onToggle: onToggle),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: onAddHabit,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add habit'),
          ),
        ],
      ),
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({required this.habit, required this.onToggle});

  final _HabitModel habit;
  final void Function(String habitId, int day) onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            habit.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF44423E)),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Row(
            children: [
              for (var day = 0; day < habit.done.length; day++)
                Expanded(
                  child: _DayCell(
                    done: habit.done[day],
                    onTap: () => onToggle(habit.id, day),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({required this.done, required this.onTap});

  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(
          color: done ? const Color(0xFF6A9E6A) : const Color(0xFFF0EDE6),
          border: Border.all(color: const Color(0xFFC8C2B6)),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

// ── Shared chrome ───────────────────────────────────────────────────────────

/// A boxed container used for every chart and panel, matching the demo's
/// paper-card look.
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDF8),
        border: Border.all(color: const Color(0xFFD8D0C0)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// A dropdown with a caption label above it.
class _LabeledDropdown<T> extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.optionLabel,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> options;
  final String Function(T) optionLabel;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Color(0xFF7A766E)),
        ),
        const SizedBox(height: 2),
        DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: [
            for (final option in options)
              DropdownMenuItem<T>(
                value: option,
                child: Text(optionLabel(option)),
              ),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ],
    );
  }
}

/// A section title with an explanatory paragraph beneath it.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.intro});

  final String title;
  final String intro;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2E2B26),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          intro,
          style: const TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Color(0xFF6B675F),
          ),
        ),
      ],
    );
  }
}
