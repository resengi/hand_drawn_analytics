# Hand Drawn Analytics

A bridge between [`analytics_toolkit`](https://pub.dev/packages/analytics_toolkit), a rendering-agnostic query engine, and [`hand_drawn_toolkit`](https://pub.dev/packages/hand_drawn_toolkit), sketchy, hand-drawn chart and table widgets.

You bring a typed analytics query and a hand-drawn chart configured the way you
want it to look. The bridge runs the query, maps the result into the chart's
data class, and renders it. It **defaults only the values you left unset and
never reinterprets your query**.

[![pub package](https://img.shields.io/pub/v/hand_drawn_analytics.svg)](https://pub.dev/packages/hand_drawn_analytics)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Publisher](https://img.shields.io/pub/publisher/hand_drawn_analytics.svg)](https://pub.dev/publishers/resengi.io)

## Example

| Dashboard | Charts | Tables | Streaks |
|:---:|:---:|:---:|:---:|
| ![Spec-driven dashboard cards](https://raw.githubusercontent.com/resengi/hand_drawn_analytics/main/assets/example_dashboard.png) | ![Query-backed interactive charts](https://raw.githubusercontent.com/resengi/hand_drawn_analytics/main/assets/example_charts.png) | ![Resizable analytics table](https://raw.githubusercontent.com/resengi/hand_drawn_analytics/main/assets/example_tables.png) | ![Streak leaderboard](https://raw.githubusercontent.com/resengi/hand_drawn_analytics/main/assets/example_streaks.png) |

## Features

- **Query-backed widgets**: bar, line, scatter, and table widgets that
  validate, fetch, and execute a typed `analytics_toolkit` query end to end,
  plus a big-number leaf and a streak leaderboard
- **Styling templates**: every widget styles itself from a normal
  `hand_drawn_toolkit` widget you build with `data: null`; the bridge never
  re-declares a toolkit styling knob
- **One-scope configuration**: `AnalyticsScope` supplies a shared query
  runner, palette, formatters, color resolver, and display-type aliases to an
  entire subtree, with a runner that stays instance-stable across rebuilds so
  widgets refetch only when the data source actually changes
- **Precise refetch semantics**: widgets and cards re-run a query exactly when
  a fetch-defining input changes: the payload, the date-range mode, the runner
  instance, and only the date inputs the active mode consults
- **Display-type dispatch**: `HandDrawnAnalyticsWidget` routes an
  already-computed result to a widget by a free-form `displayType` string,
  with consumer aliases and an optional builder registry for fully custom
  rendering of mapped data
- **Spec-driven dashboard cards**: `HandDrawnAnalyticsCard` decodes a
  persisted `AnalyticsWidgetSpec`, runs it, dispatches by display type, and
  frames the result in `CardChrome`, reloading in response to typed
  `AnalyticsChange` events
- **Paired-query rendering**: scatter plots consume a paired result directly;
  every other display renders a paired result by reducing it to one series
  with a `SeriesCombination` (rates, differences, products, sums)
- **Pure mapper layer**: every result-to-chart-data conversion is an
  exported pure function (`seriesToBar`, `pairedToScatter`, `resultToTable`,
  …) you can call yourself
- **Graceful failure**: expected problems become typed `BridgeError`s
  rendered as the toolkit's own empty states, never thrown
- **Semantic coloring**: a resolver → tag-pin → positional-palette resolution
  order, so colors can follow meaning rather than position
- **Locale-aware formatting**: one `BridgeFormatters` policy object for table
  cells, big numbers, axis ticks, unit labels, and bucket-key labels, reactive
  to runtime locale switches

## Installation

Add the package to your `pubspec.yaml` alongside the two packages it bridges:

```yaml
dependencies:
  hand_drawn_analytics: ^0.1.0
  analytics_toolkit: ^0.2.0    # used directly to build queries
  hand_drawn_toolkit: ^0.5.0   # used directly to build chart styling templates
```

Then run:

```bash
flutter pub get
```

## Quick Start

```dart
import 'package:analytics_toolkit/analytics_toolkit.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:hand_drawn_toolkit/hand_drawn_toolkit.dart';

// Configure the data plumbing once, at the top of a page:
AnalyticsScope(
  sources: mySources,
  cache: SourceSnapshotCache(fetcher: myFetcher),
  child: Dashboard(),
)

// Anywhere below the scope, a chart is a query plus a styling template:
HandDrawnAnalyticsBarChart(
  query: SingleQuerySpec(
    query: AnalyticsQuerySpec(
      source: 'workouts',
      measures: const [
        FieldMeasure(
          fieldRef: FieldRef(sourceId: 'workouts', fieldId: 'reps'),
          aggregation: SumAgg(),
        ),
      ],
      groupBys: const [
        FieldGroupBy(fieldRef: FieldRef(sourceId: 'workouts', fieldId: 'day')),
      ],
    ),
  ),
  chart: const HandDrawnBarChart(
    data: null,            // ← the bridge fills this
    axisColor: Colors.brown,
    irregularity: 2.5,     // ← your styling, preserved verbatim
  ),
  dateRangeMode: const FixedOverride(
    range: PresetRange(preset: DateRangePreset.last30Days),
  ),
)
```

## The Core Idea: Styling Templates

Every bridge widget takes a `chart:` argument — a normal `hand_drawn_toolkit`
widget you build with `data: null`. That instance is a *styling template*: it
carries every native styling field (colors, stroke, irregularity, padding,
label configs, legend configs, …) exactly as you set them. The bridge fills in
its `data` from the query result and otherwise leaves it untouched.

Because styling lives on the template, the bridge never re-declares a toolkit
styling knob. Anything `hand_drawn_toolkit` can express, you express directly
on `chart:` — including rotated tick labels, legend layout, plot-area
clipping, and per-segment fills.

### Constructor Groups

Each chart widget's constructor is organized into three groups:

1. **Analytics inputs** — the `query`, the `chart` template, the runner (or an
   enclosing `AnalyticsScope`), and the date-range inputs.
2. **Data-object overrides** — nullable fields (`minY`, `maxY`, `legend`,
   `title`, axis formatters, …). A non-null value replaces what the bridge
   would compute; `null` means "let the bridge default it."
3. **Bridge knobs** — behavior the toolkit data class doesn't express, such as
   `integerValued` axis snapping, `fillAlpha`, `onTap`, and hit-test
   tolerances.

## Providing a Runner

A `WidgetQueryRunner` is the one place that knows the execution choreography:
list sources → validate → project the date range → fetch records → execute.
Its three seams are injectable:

```dart
final runner = WidgetQueryRunner(
  listSources: () => mySources,
  fetchRecords: (sourceId, {dateBound}) => myFetch(sourceId, dateBound),
  // executeQuery accepts a sync or async function. It defaults to the
  // in-process AnalyticsExecutor; an async function can move execution off
  // the main isolate.
);

final single = await runner.runSingle(query, dateRangeMode: mode);
final paired = await runner.runPaired(pairedQuery, dateRangeMode: mode);
```

`runSingle`/`runPaired` accept `pageRange`, `earliestDataDate`, `today`, and
`asOf`, resolve the date range once per run, and hand the resolved
`(start, end)` bound to `fetchRecords` so a cache can key on
`(sourceId, dateBound)` instead of materializing out-of-range records. A
fetcher that ignores the bound still works — the executor's in-memory filter
applies it. A null `asOf` — the reference date `StreakMeasure` evaluates
against — resolves to the same per-run wall-clock read that resolves relative
date ranges, so range resolution and streak evaluation always share one
instant (in a paired run, across both halves); pass it explicitly to pin
streak evaluation to a known date.

`ExecuteQueryRequest` — the bundle handed to the `executeQuery` seam — holds
only data (the projected query, records, sources, resolved range, and `asOf`),
so it can cross an isolate boundary unchanged. The seam returns `FutureOr`,
so `compute`-style execution plugs in directly: hand the request to a
top-level function that calls `AnalyticsExecutor.execute` with its fields and
return the future — the runner awaits sync and async executors alike.

Every failure mode surfaces as a typed `Err`: validation and projection
failures and execution errors arrive as `BridgeAnalyticsError` wrapping the
upstream `AnalyticsError`, and any *thrown* failure (a fetcher hitting a dead
connection, a listSources bug) is caught and converted rather than escaping
the future — see [Errors and Graceful Failure](#errors-and-graceful-failure).

### AnalyticsScope

You can pass a runner to each widget, or — more commonly — configure
everything once:

```dart
AnalyticsScope(
  sources: mySources,
  cache: SourceSnapshotCache(fetcher: myFetcher),
  palette: const BridgePalette(),          // optional
  formatters: const BridgeFormatters(),    // optional
  colorResolver: myResolver,               // optional
  displayAliases: {'leaderboard': 'streakLeaderboard'},  // optional
  child: Dashboard(),
)
```

The scope derives a `WidgetQueryRunner` from `sources` and `cache` and
publishes it — together with the other fields — as an `AnalyticsScopeData`
inherited widget. Read it with `AnalyticsScope.of(context)` /
`AnalyticsScope.maybeOf(context)`. Any individual widget can override any
field locally.

**The runner is instance-stable.** The scope keeps one runner across rebuilds
and derives a new one only when `sources` or `cache` is *replaced* (compared
by identity). Widgets compare the runner by identity to decide when to
refetch, so a scope that rebuilds because a palette or formatter changed never
causes a refetch, while swapping in a new source catalog or cache refetches
everything below. Treat `sources` and `cache` as immutable while in scope:
pass a different instance to change them — in-place mutation changes neither
the runner nor what dependents see.

#### AnalyticsScope Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sources` | `List<SourceDef>` | required | Source catalog queries validate and execute against. Replace, don't mutate |
| `cache` | `SourceSnapshotCache` | required | Per-page record cache; its `getOrFetch` becomes the runner's fetch seam |
| `palette` | `BridgePalette` | `BridgePalette()` | Default palette for series/segment coloring |
| `formatters` | `BridgeFormatters` | `BridgeFormatters()` | Default display-formatting policy |
| `colorResolver` | `SemanticColorResolver?` | `null` | Semantic color hook consulted ahead of the palette |
| `displayAliases` | `Map<String, String>` | `{}` | Display-type aliases (alias → canonical kind name) |
| `child` | `Widget` | required | The subtree this scope configures |

## Date Ranges

Every query-running widget takes a `dateRangeMode` plus the inputs the mode
may consult:

- **`NoDateRange()`** — the measure takes no range (required for
  `StreakMeasure`). No date input is consulted.
- **`UsePageRange()`** — follow the page-level range; `pageRange` is required
  and is the only date input consulted.
- **`FixedOverride(range: PresetRange(...))`** — the widget carries its own
  relative preset, resolved against `today` (or the wall clock when `today` is
  null) and `earliestDataDate` (for `allTime`).
- **`FixedOverride(range: CustomRange(...))`** — explicit endpoints; the range
  is self-contained and no date input is consulted.

Widgets re-run the query exactly when a *fetch-defining* input changes: the
query payload, the date-range mode itself, the runner instance, `asOf`, and
the date inputs the active mode consults per the list above. A `pageRange`
change under a fixed override, for example, never refetches.

A relative preset resolves at fetch time and re-resolves when the widget next
refetches — it does not refresh spontaneously when the wall-clock day rolls
over. Pass an explicit `today` for deterministic resolution (tests,
screenshots, "as of" views).

## Widgets

| Widget | Query shape | Result shapes | Notes |
|---|---|---|---|
| `HandDrawnAnalyticsBarChart` | single | series / multi-series / multi-measure | `BarMode.single \| grouped \| stacked` |
| `HandDrawnAnalyticsLineChart` | single | series / multi-series / multi-measure | `TemporalSpacing.uniform \| epochMs` |
| `HandDrawnAnalyticsScatterPlot` | paired | paired series | aligns x and y by bucket key |
| `HandDrawnAnalyticsTable` | single | any | the universal fallback — every result is a table |
| `HandDrawnAnalyticsBigNumber` | — | scalar | a leaf; takes an already-run result |
| `HandDrawnAnalyticsStreakLeaderboard` | single (`StreakMeasure`) | streak table | fixed leaderboard columns |

All query-running widgets share the same loading/error presentation: while the
query runs, the bare template renders (the toolkit shows its loading state for
null data); an error renders the template's empty state with the error's
human-readable message.

### Bar Chart

```dart
HandDrawnAnalyticsBarChart(
  query: mySingleQuery,
  chart: const HandDrawnBarChart(data: null, axisColor: Colors.brown),
  mode: BarMode.stacked,
  dateRangeMode: const UsePageRange(),
  pageRange: page.range,
)
```

A single-series result renders one bar per bucket. Multi-series and
multi-measure results render grouped or stacked by `mode`; `BarMode.single`
has no meaning for those shapes and renders as grouped. In a single-series
chart every bar shares the series color (the palette's first entry, unless a
resolver or tag pin overrides per bucket) — color encodes series identity, as
in the multi-series charts, while the x-axis labels distinguish categories.

#### HandDrawnAnalyticsBarChart Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | `SingleQuerySpec` | required | The typed analytics query |
| `chart` | `HandDrawnBarChart` | required | Styling template built with `data: null` |
| `mode` | `BarMode` | `BarMode.single` | Bar layout for multi-dimension results |
| `runner` | `WidgetQueryRunner?` | scope | Explicit runner; falls back to the enclosing scope |
| `palette` / `formatters` / `colorResolver` | — | scope | Local overrides of the scope defaults |
| `dateRangeMode` | `DateRangeMode` | `NoDateRange()` | How the date range is applied |
| `pageRange` / `earliestDataDate` / `today` | — | `null` | Date inputs consulted per mode |
| `minY` / `maxY` / `axisDisplay` / `legend` / `yValueFormatter` / `title` / `yAxisLabel` / `xAxisLabel` | — | `null` | Data-object overrides; null lets the bridge compute |
| `integerValued` | `bool?` | inferred | Forces integer (`true`) or non-integer (`false`) Y ticks; null infers from the query's measures and the result's output type |
| `fillAlpha` | `double?` | `null` | Fill opacity applied to mapped segments |
| `onTap` / `onTapMiss` | callbacks | `null` | Typed bar hit / in-chart miss; when both are null no gesture layer is added |

### Line Chart

```dart
HandDrawnAnalyticsLineChart(
  query: myTemporalQuery,
  chart: const HandDrawnLineChart(data: null),
  temporalSpacing: TemporalSpacing.epochMs,
  dateRangeMode: const FixedOverride(
    range: PresetRange(preset: DateRangePreset.last90Days),
  ),
)
```

A single-series result becomes one line; a multi-series or multi-measure
result becomes one line each (mixed-unit measures are rejected). The value
axis defaults to a zero-crossing display when the data spans zero.
`temporalSpacing` chooses between evenly-spaced categorical positions
(`uniform`, the default) and real epoch-millisecond positions (`epochMs`) for
when the gaps between buckets carry meaning.

#### HandDrawnAnalyticsLineChart Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | `SingleQuerySpec` | required | The typed analytics query |
| `chart` | `HandDrawnLineChart` | required | Styling template built with `data: null` |
| `runner` / `palette` / `formatters` / `colorResolver` | — | scope | Local overrides of the scope defaults |
| `dateRangeMode` / `pageRange` / `earliestDataDate` / `today` | — | — | Date-range inputs, as on the bar chart |
| `minX` / `maxX` / `minY` / `maxY` / `axisDisplay` / `legend` / `yValueFormatter` / `xValueFormatter` / `title` / `yAxisLabel` / `xAxisLabel` | — | `null` | Data-object overrides |
| `temporalSpacing` | `TemporalSpacing` | `uniform` | Categorical vs. real-time X positioning |
| `integerValued` | `bool?` | inferred | Y-tick integer snapping, as on the bar chart |
| `onTap` / `onTapMiss` | callbacks | `null` | Typed line hit / in-chart miss |
| `pointTolerance` | `double` | `12.0` | Point hit-test tolerance (mirrors the toolkit default) |
| `lineTolerance` | `double` | `16.0` | Segment hit-test tolerance (mirrors the toolkit default) |

### Scatter Plot

```dart
HandDrawnAnalyticsScatterPlot(
  query: PairedQuerySpec(xQuery: distanceQuery, yQuery: durationQuery),
  chart: const HandDrawnScatterPlot(data: null, dotColor: Colors.indigo),
  dateRangeMode: const UsePageRange(),
  pageRange: page.range,
)
```

A scatter plot runs a *paired* query and aligns the two series by bucket key:
each key present in both series with plottable values on both sides becomes
one point. Axis labels default to the two measures' labels. The scatter widget
colors its points from the template's native `dotColor`, so it exposes no
palette or color-resolver arguments of its own.

Keys present on only one side, and aligned keys whose value is unplottable on
either side, are dropped. The pure mapper reports how many (see
[Mappers](#the-mapper-layer)); the widget renders the surviving points, or the
template's empty state when nothing aligned.

#### HandDrawnAnalyticsScatterPlot Properties

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `query` | `PairedQuerySpec` | required | The x and y halves of the paired query |
| `chart` | `HandDrawnScatterPlot` | required | Styling template built with `data: null` |
| `runner` / `formatters` | — | scope | Local overrides of the scope defaults |
| `dateRangeMode` / `pageRange` / `earliestDataDate` / `today` | — | — | Date-range inputs, applied to both halves |
| `minX` / `maxX` / `minY` / `maxY` / `axisDisplay` / `yValueFormatter` / `xValueFormatter` / `title` / `xAxisLabel` / `yAxisLabel` | — | `null` | Data-object overrides |
| `onTap` / `onTapMiss` | callbacks | `null` | Typed point hit / in-chart miss |
| `tolerance` | `double` | `16.0` | Hit-test tolerance (mirrors the toolkit default) |

### Table

```dart
HandDrawnAnalyticsTable(
  query: myQuery,
  chart: const HandDrawnTable(columns: [], rows: []),
  resizable: true,
  initialColumnWidths: restoredWidths,
  onColumnWidthsChanged: persistWidths,
)
```

The universal fallback: **every** result shape is renderable as a table.
Scalars become a 1×1 table, chart-shaped results project through their table
views, and a `TableResult` is consumed directly. Measure columns are
right-aligned, group-key columns left-aligned, and every value is stringified
through the formatters.

When upstream row capping (`topN` / `limit`) dropped rows, a footer row notes
the hidden count (`"+N more"` by default; customize with
`truncatedFooterBuilder` or suppress with `showTruncationFooter: false`).

Set `resizable: true` to let the consumer drag column boundaries. Widths are
consumer-owned: pass restored widths via `initialColumnWidths` and persist the
list reported through `onColumnWidthsChanged`. When `resizable` is false (the
default) the table uses the template's own column sizing and adds no drag
layer.

#### Rendering an already-mapped table: HandDrawnTableView

The table widget delegates its rendering to `HandDrawnTableView`, which is
exported on its own: hand it a `TableMapping` (from `resultToTable` /
`streakToTable`, or received in a builder) plus a `HandDrawnTable` template
and it renders the mapping — truncation footer, optional resizing, and all.
Returning a `HandDrawnTableView` from an `AnalyticsWidgetBuilders.table`
builder is how a spec-driven dashboard opts into resizable columns.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `mapping` | `TableMapping` | required | The bridge-mapped table data |
| `chart` | `HandDrawnTable` | required | Styling template; its `columns`/`rows` are replaced by the mapping |
| `showTruncationFooter` | `bool` | `true` | Append a footer row noting truncated rows |
| `truncatedFooterBuilder` | `String Function(int)?` | `"+N more"` | Footer label builder |
| `resizable` | `bool` | `false` | Drag-to-resize column boundaries |
| `initialColumnWidths` | `List<double>?` | `null` | Restored widths, one per data column |
| `onColumnWidthsChanged` | `void Function(List<double>)?` | `null` | Persistence hook, called after a drag settles and on reset |

### Big Number

```dart
HandDrawnAnalyticsBigNumber(
  result: alreadyRunScalarResult,
  title: 'Total reps',
  valueStyle: const TextStyle(fontSize: 40),
)
```

A prominent single-value display backed by a scalar result. There is no
upstream big-number widget to template, so this is a leaf that composes a
`HandDrawnContainer` with the value and an optional label, exposing styling
directly (`valueStyle`, `labelStyle`, `titleStyle`, `color`,
`backgroundColor`, `padding`). Pass the already-run `result` — for example
from a card or controller; a null result renders `loadingPlaceholder`. A
non-scalar result renders the shape error's message, naming the table display
as the fitting alternative.

### Streak Leaderboard

```dart
HandDrawnAnalyticsStreakLeaderboard(
  query: myStreakQuery,
  chart: const HandDrawnTable(columns: [], rows: []),
)
```

A `StreakMeasure` query yields a fixed-column table (`entityId`,
`entityLabel`, `currentStreak`, `longestStreak`), sorted by current streak
descending with `topN` applied. This widget maps those columns to a readable
leaderboard: the raw entity id is hidden by default (`showEntityId: false`),
the label takes the wide column, and the two streak counts are narrow. Header
labels are overridable (`entityLabelHeader`, `currentStreakHeader`,
`longestStreakHeader`, `entityIdHeader`). A `topN`-capped result surfaces the
same `"+N more"` footer as the table.

Streak measures do not support a date range, so this widget exposes no
date-range inputs. `asOf` — the reference date streaks are computed against —
resolves to the wall clock at fetch time when null; pass an explicit value to
pin "current streak" to a known instant (golden tests, "view as of" features).

## Display-Type Dispatch

`HandDrawnAnalyticsWidget` renders an **already-computed** `BridgeResult` by a
free-form `displayType` string — useful when a controller has already run the
query, and the routing layer the spec-driven card uses internally.

```dart
HandDrawnAnalyticsWidget(
  result: bridgeResult,
  displayType: 'stackedBar',
  barTemplate: const HandDrawnBarChart(data: null),
)
```

The display vocabulary is the `HandDrawnVisualizationKind` enum: `bar`,
`groupedBar`, `stackedBar`, `line`, `multiLine`, `scatter`, `table`,
`bigNumber`, `streakLeaderboard`. A `displayType` resolves by exact canonical
name first, then through the scope's `displayAliases` map (alias → canonical
name). An unrecognized string — and a result whose shape the chosen kind can't
draw — renders an error box rather than throwing.

Per-kind templates (`barTemplate`, `lineTemplate`, `scatterTemplate`,
`tableTemplate`) are optional; a kind with no supplied template uses a default
instance.

### Paired results under non-scatter displays

`scatter` is the one display that consumes a paired result directly. Every
other kind renders one series, so a paired result is first reduced to a single
series via the `combination` you supply — a `SeriesCombination` aligned by
bucket key (`RatioCombination` for rates, `DifferenceCombination` for nets,
`SumCombination`, `ProductCombination`) — and then rendered through exactly
the same single-series path. `combinePolicy` (an `UnmatchedBucketPolicy`,
default `drop`) governs keys present on only one side. The combination is
orthogonal to the chart kind, which is why "rate as a line" or "net as bars"
needs no dedicated widget: it's a paired query, a combination, and a display
type. A paired result with no combination under a non-scatter kind renders an
error box naming the problem.

### Builder registry

`AnalyticsWidgetBuilders` lets a consumer replace the default rendering per
*mapped data class* while keeping the bridge's query/mapping/error pipeline:

```dart
HandDrawnAnalyticsWidget(
  result: result,
  displayType: spec.displayType,
  builders: AnalyticsWidgetBuilders(
    table: (mapping) => HandDrawnTableView(
      mapping: mapping,
      chart: myTableTemplate,
      resizable: true,
    ),
    scatter: (mapping) => MyScatterWithDropBadge(mapping),
  ),
)
```

| Slot | Receives | Covers kinds |
|------|----------|--------------|
| `bar` | `BarChartData` | `bar`, `groupedBar`, `stackedBar` |
| `line` | `LineChartData` | `line`, `multiLine` (including reduced paired results) |
| `scatter` | `ScatterMapping` (data + `droppedCount`) | `scatter` |
| `table` | `TableMapping` (columns, rows, `truncatedCount`) | `table`, `streakLeaderboard` |

Builders only ever receive **successfully mapped** data — error and
shape-mismatch outcomes always use the default presentation, so a builder
never reimplements failure handling. An unset slot (or a null registry) falls
back to the per-kind template. The `table` builder receives the raw
`truncatedCount` rather than a pre-built footer row: delegating to
`HandDrawnTableView` gets footer handling for free, while a fully custom
table owns its own footer.

## Cards

### HandDrawnAnalyticsCard

The spec-driven path: hand it a persisted `AnalyticsWidgetSpec` and it decodes
the three JSON payloads (query, display, date-range mode), runs the query
through the resolved runner, dispatches by the decoded display type, and
frames the result in `CardChrome`.

```dart
HandDrawnAnalyticsCard(
  spec: specFromStorage,
  pageRange: page.range,
  reloadTrigger: analyticsChanges,   // ValueListenable<AnalyticsChange?>
  onEdit: () => openEditor(spec.id),
)
```

Spec handling follows the spec's own identity model: `AnalyticsWidgetSpec.==`
is id-based, so the card compares the *content* fields (the three JSON blobs
plus the schema version) to decide when a new spec object means new data. A
content change re-decodes and refetches; a chrome-only change (the title)
re-renders without touching the query. An undecodable spec renders a fixed
message inside the chrome — decode internals never reach the UI.

**Reload semantics.** `reloadTrigger` is a `Listenable`; when it is a
`ValueListenable<AnalyticsChange?>`, the card inspects the typed change and
consults `shouldReload` (default: `defaultShouldReload`). Date-range changes
are prop-driven rather than trigger-driven — the card receives its range
through `pageRange` and the spec's own date-range mode and refetches when
those change — so `dateRange` trigger events are skipped regardless of the
predicate. The default predicate reloads on `sourceData` only when the changed
sources intersect the sources this card reads (a null change scope means "all
sources"), and ignores `widgetSet` / `widgetOrder` / `restore`. Any other
`Listenable` reloads on every signal.

During a reload the card keeps showing its last result so it holds its size
instead of collapsing while the query re-runs; a monotonic guard drops stale
results when reloads overlap. The card keeps its state alive when scrolled
offscreen (e.g. inside a dashboard list).

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `spec` | `AnalyticsWidgetSpec` | required | The persisted widget spec (id, title, three JSON payloads) |
| `runner` / `palette` / `formatters` / `colorResolver` | — | scope | Local overrides of the scope defaults |
| `reloadTrigger` | `Listenable?` | `null` | Typed change feed; see reload semantics above |
| `shouldReload` | `AnalyticsCardReloadPredicate` | `defaultShouldReload` | `(change, mySourceIds) → bool` |
| `pageRange` / `earliestDataDate` / `today` / `asOf` | — | `null` | Date inputs, consulted per the spec's decoded mode; a null `asOf` resolves to the wall clock at fetch time |
| `onEdit` | `VoidCallback?` | `null` | Shows the chrome's edit affordance |
| `barTemplate` / `lineTemplate` / `scatterTemplate` / `tableTemplate` | — | defaults | Per-kind styling templates |
| `builders` | `AnalyticsWidgetBuilders?` | `null` | Consumer builders, forwarded to the dispatcher |
| `barMode` | `BarMode` | `BarMode.single` | Bar layout when the spec's display type resolves to the generic `bar` |
| `combination` | `SeriesCombination?` | `null` | Folds a paired result into one series for non-scatter display types |
| `combinePolicy` | `UnmatchedBucketPolicy` | `drop` | Key-alignment policy for `combination` |

### AnalyticsScalarCard

The common "one KPI per card" case, without a persisted spec: a single scalar
query rendered as a big number inside `CardChrome`.

```dart
AnalyticsScalarCard(
  query: totalRepsQuery,
  title: 'Total reps',
  dateRangeMode: const FixedOverride(
    range: PresetRange(preset: DateRangePreset.thisMonth),
  ),
)
```

It shares the card refetch machinery (and the scope fallback for the runner
and formatters) and exposes `title`, `onEdit`, `valueStyle`, and `color` for
presentation.

### CardChrome

The shared framing both cards use — a `HandDrawnContainer` with an optional
title row and an optional edit affordance — exported so custom cards can match
the dashboard treatment:

```dart
CardChrome(
  title: 'Anything',
  onEdit: openEditor,
  child: MyCustomContent(),
)
```

Pure chrome: it owns no data and runs no query.

## Coloring

`BridgePalette` resolves a series/segment color in this order, highest
priority first:

1. a `SemanticColorResolver` you supply (if it returns non-null) — a
   `(semanticTag, bucketKey) → Color?` hook for meaning-based coloring,
2. a `tagPins` entry matched on the result's `semanticTag`,
3. the indexed `colors` entry, wrapping modulo the palette length.

```dart
BridgePalette(
  colors: const [Color(0xFF4C6E81), Color(0xFFB5654A)],
  tagPins: const {'mood': Color(0xFF7E6E94)},
)
```

The palette is the bridge's *default* coloring policy: it never overrides a
color you set on a template — the bridge only fills the colors the mappers
must produce (bar segments, line series). The default palette is eight muted,
desaturated colors that read well against the hand-drawn aesthetic.

Palettes have value equality (`colors` ordered, `tagPins` by entries), so a
rebuilt-but-equivalent palette never reads as a configuration change to a
scope. An empty `colors` list is a misconfiguration only the positional step
can hit: it asserts in development and degrades to a single fixed color in
release, so a chart still renders.

## Formatting

`BridgeFormatters` is the single source of truth for turning typed analytics
values into display strings and chart numbers. Everything the bridge shows
flows through one instance, so a display policy changes in one place. The
defaults are locale-aware via `intl` and follow runtime locale switches.
Formatters are pure with respect to the widget tree — they never touch a
`BuildContext` — so they are safe to call from the pure mappers.

| Method | Renders | Default policy |
|--------|---------|----------------|
| `tableCell(TypedValue?)` | a table cell | locale decimal formats; `Yes`/`No` booleans; `yMMMd` dates; humanized durations; em dash for null/missing |
| `scalarValue(TypedValue?)` | a big number | shares the table-cell policy; split out so a subclass can format big numbers (e.g. compact `1.2k`) independently |
| `chartNumeric(TypedValue?)` | a chart-axis `double` | ints/doubles directly; durations in minutes; `null` for unplottable values |
| `chartUnitLabel(FieldType)` | the axis unit suffix | `"min"` for durations; `null` otherwise — kept in sync with `chartNumeric` |
| `bucketKey(BucketKey, {includeYear})` | an axis/category label | temporal keys formatted by grain; the year appears only when asked |
| `spansMultipleYears(keys)` | — | the helper that decides `includeYear`, so labels disambiguate only when a series crosses a year boundary |
| `humanizeDuration(Duration)` | a compact duration | `45s`, `12m`, `3h 05m`, `2d 4h`; negatives keep a leading sign |

Subclass and override individual methods to customize — for full localization,
compact notation, different duration units, and so on.

## Errors and Graceful Failure

The bridge never throws for an expected problem. Every failure becomes a typed
`BridgeError` — a sealed family with a `humanMessage` — rendered as the
toolkit's own empty state.

| Error | Meaning | Extras |
|-------|---------|--------|
| `BridgeShapeMismatch` | the result shape doesn't fit the chosen display | `expected` / `actual` shapes and, where one exists, a `suggestion` for a display that *would* fit |
| `BridgeAnalyticsError` | wraps an upstream `AnalyticsError` (validation or execution failure) | the underlying `error`; switch on its `kind` to supply your own copy |
| `BridgeMissingScope` | required configuration (e.g. the runner) was neither passed nor available from a scope | `missingField` |
| `BridgeIncompatibleValues` | values that can't share an axis (e.g. mixed-unit measures) | an `IncompatibleValuesReason` |

Unexpected *thrown* failures — a fetcher throwing on a dead connection, a
spec that fails to decode — are caught and converted through one owner,
`BridgeAnalyticsError.unexpected()`. Its `humanMessage` is fixed and generic
(`"Analytics failed unexpectedly."`) because it renders directly into
user-facing empty states, and the throwables it wraps can carry connection
strings, file paths, or decode internals that must not leak there. The
original throwable rides on `debugDetail` for diagnostics; consumers wanting
their own copy switch on the error `kind`.

Two more pieces of exported vocabulary round this out: `BridgeResult` (a
`SingleResult` for single queries; a `PairedResult` holding the two series
downstream consumers align by bucket key) and `AsyncValue<T>`
(`loading`/`data`/`error` with a `when` visitor), the three-state result type
the bridge's rendering pipeline speaks.

## The Mapper Layer

Every result-to-chart-data conversion is an exported pure function — no
widgets, no context — so you can run the bridge's exact mapping logic
yourself (in a builder, a controller, or a test):

| Mapper | Input → Output | Notes |
|--------|----------------|-------|
| `seriesToBar` | `SeriesResult` → `BarChartData` | one bar per bucket; all bars share the series color; zero-floored nice Y range |
| `multiSeriesToBar` / `multiMeasureToBar` | multi-series / multi-measure → `BarChartData` | grouped or stacked by `BarMode`; `single` renders as grouped; multi-measure rejects mixed units |
| `seriesToLine` / `multiSeriesToLine` / `multiMeasureToLine` | series shapes → `LineChartData` | shared range/axis/label/legend logic; zero-crossing axis default; `TemporalSpacing` |
| `pairedToScatter` | two `SeriesResult`s → `ScatterMapping` | aligns by bucket key; counts dropped keys/values |
| `resultToTable` | **any** `AnalyticsResult` → `TableMapping` | the totality guarantee — every result is at least a table |
| `streakToTable` | streak `TableResult` → `TableMapping?` | leaderboard layout; null when not streak-shaped (caller falls back to `resultToTable`) |
| `scalarToBigNumber` | `ScalarResult` → display record | value string + label; `Err` with a table suggestion for non-scalars |

Mappers return `Result<…, BridgeError>` and are total over their declared
input shape: empty input maps to empty, *renderable* data — an error is
reserved for genuine misfit (wrong shape, unchartable value type, mixed
units). Two mappings carry diagnostics alongside the data:
`ScatterMapping.droppedCount` distinguishes "data existed but nothing aligned"
from "nothing there at all", and `TableMapping.truncatedCount` carries the
upstream row-cap count the table view turns into its footer.

`mapper_support` exports the shared vocabulary the mappers are built from —
`SeriesView` (the normalized per-series view), `TemporalSpacing`, `NiceRange`,
and `assembleLineChartData` — for consumers building their own line-shaped
outputs that should inherit the bridge's range and labeling behavior.

## How It Works

1. **Resolution** — a widget resolves its configuration: explicit arguments
   win; otherwise the nearest `AnalyticsScope` supplies the runner, palette,
   formatters, and resolver; a missing runner is a typed `BridgeMissingScope`
   rendered in the template's empty state.

2. **Orchestration** — `WidgetQueryRunner` owns the choreography: list sources
   → validate → project the date range onto the query → fetch records →
   execute. The date range is resolved once per run and the same bound feeds
   projection, the fetch seam (and thus the cache key), and execution, so all
   three observe one consistent window. The run's single wall-clock read also
   backs `asOf` when the caller leaves it null, so streak evaluation and range
   resolution agree on what "now" is.

3. **Controller lifecycle** — each query-running widget owns an internal
   controller capturing the exact inputs it ran with. On any rebuild, the
   current inputs are compared against that record: the runner by identity,
   everything else by value, and date inputs only where the active mode
   consults them. A difference disposes and rebuilds (one fetch); equality is
   a no-op. Reload signals refresh the live controller in place. A
   monotonically increasing request id drops out-of-order results.

4. **Runner stability** — the scope owns its derived runner and replaces it
   only when `sources` or `cache` is replaced, capturing both references at
   creation so a runner's behavior stays fixed to the data source it was
   created from. Identity and meaning move in lockstep, which is what makes
   the identity comparison in step 3 sound.

5. **Mapping** — the result flows through the pure mapper for the chosen
   display, which computes only what you left unset: nice axis ranges
   (zero-floored for non-negative bars, padded for scatter), zero-crossing
   axis defaults, palette colors, legends, categorical labels with
   year-disambiguation, and unit-suffixed axis formatters.

6. **Template fill** — the mapped data lands in your template via `copyWith`;
   every styling field you set is preserved verbatim, and non-null data-object
   overrides replace the computed values field by field.

7. **Interaction** — `onTap` reconstructs the toolkit painter from the filled
   template, computes its layout for the rendered size, and hit-tests in
   logical coordinates, returning the toolkit's typed hit results. With no
   tap callbacks, no gesture layer or per-frame layout work is added.

8. **Formatter memoization** — `NumberFormat`/`DateFormat` instances are
   cached per `(current locale, format recipe)`, so a large table or dense
   axis doesn't re-parse format patterns per cell or tick, while a runtime
   locale switch transparently builds fresh instances.

## Best Practices

**Configure one `AnalyticsScope` per page** and let widgets inherit the
runner, palette, and formatters. Override locally only where a widget truly
differs — the scope keeps the runner stable across rebuilds, so per-widget
runners are extra wiring with no benefit unless a widget reads a different
data source.

**Replace, don't mutate, the scope's `sources` and `cache`.** The scope
detects change by identity. Swapping in a new list or cache instance refetches
everything below — exactly once per widget — while in-place mutation changes
nothing.

**Let the cross-rule pick your `dateRangeMode`.** Measures that support a
date range require `UsePageRange` or `FixedOverride`; `StreakMeasure` requires
`NoDateRange`. `FixedOverride(range: PresetRange(preset:
DateRangePreset.allTime))` is the self-contained choice when a widget should
ignore the page's range entirely.

**Pass explicit `today` and `asOf` values when determinism matters.**
Relative presets resolve against the wall clock when `today` is null, streak
evaluation resolves against it when `asOf` is null, and both re-resolve on the
next refetch; tests, screenshots, and "as of" views should pin the reference
dates.

**Express paired math as a query + a combination + a display type.** A
completion rate is a paired query with `RatioCombination` rendered as `line`;
a net is `DifferenceCombination` as `bar`. The reduction is aligned by bucket
key and orthogonal to the chart kind.

**Use semantic coloring for meaningful categories.** When "done" should
always be green regardless of position, supply a `SemanticColorResolver` or
pin the result's `semanticTag` in `tagPins` — positional palette colors are
the fallback, not the only option.

**Reach for builders, not forks, to customize rendering.** An
`AnalyticsWidgetBuilders` slot receives fully mapped, validated data and only
on success — you keep the bridge's query pipeline, totality fallbacks, and
error presentation while owning the final widget. Delegate table builders to
`HandDrawnTableView` unless you want to own the truncation footer yourself.

**Surface data loss where it matters.** Scatter alignment reports
`droppedCount` and tables report `truncatedCount`; a dashboard that should be
honest about partial views can render badges from these instead of silently
showing fewer points or rows.

**Keep formatters in one place.** Subclass `BridgeFormatters` for locale or
notation changes and install it on the scope; per-widget formatter overrides
are for genuine exceptions, not the default path.

**Hand `HandDrawnAnalyticsCard` a trigger, not a timer.** Fire typed
`AnalyticsChange`s when data mutates and let the predicate scope reloads to
the sources a card actually reads. Date-range changes need no trigger at all —
deliver them through `pageRange` (or the spec's mode) and the card refetches
exactly once.

## Status

Pre-1.0 (`0.1.0`). The public API may still change before `1.0.0`; while the
package is pre-1.0, breaking changes ship as minor version bumps, per pub's
[pre-1.0 versioning semantics](https://dart.dev/tools/pub/versioning#semantic-versions).
The package targets published `analytics_toolkit` and `hand_drawn_toolkit`
releases; the supported version ranges are the constraints declared in
`pubspec.yaml`.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.