import 'package:analytics_toolkit/analytics_toolkit.dart' show BucketKey;
import 'package:flutter/foundation.dart' show immutable, listEquals, mapEquals;
import 'package:flutter/painting.dart' show Color;

/// A consumer-supplied hook for assigning a color to a series, bucket, or
/// segment from its semantic identity rather than its position.
///
/// Returns `null` to defer to the next strategy in the resolution order (see
/// [BridgePalette.resolve]). [semanticTag] is the opaque `semanticTag` carried
/// on the analytics result (when present); [key] is the bucket key for the
/// item being colored (when applicable).
typedef SemanticColorResolver =
    Color? Function(String? semanticTag, BucketKey? key);

/// An ordered color palette plus the bridge's coloring resolution order.
///
/// Resolution order, highest priority first:
///
/// 1. a consumer [SemanticColorResolver] (if it returns non-null),
/// 2. a pin in [tagPins] matched by `semanticTag`,
/// 3. the indexed [colors] entry, wrapping modulo the palette length.
///
/// The palette is the bridge's *default* coloring policy. It never overrides a
/// color the consumer set on the template — the bridge only fills colors the
/// mappers must produce (bar segments, line/scatter series) when the consumer
/// has not pinned them semantically.
@immutable
class BridgePalette {
  const BridgePalette({this.colors = _defaultColors, this.tagPins = const {}});

  /// The ordered colors used for positional assignment.
  final List<Color> colors;

  /// Fixed color assignments keyed by `semanticTag`. Checked after a
  /// [SemanticColorResolver] but before positional [colors].
  final Map<String, Color> tagPins;

  /// Resolves a color following the documented order.
  ///
  /// [index] is the positional fallback index (e.g. series or segment
  /// ordinal); it is taken modulo the palette length so it can never go out of
  /// range. [semanticTag] and [key] feed the resolver and tag-pin steps. An
  /// empty [colors] list is a misconfiguration only the positional step can
  /// hit: it asserts in development and degrades to a single fixed color in
  /// release, so a chart still renders.
  Color resolve({
    required int index,
    String? semanticTag,
    BucketKey? key,
    SemanticColorResolver? resolver,
  }) {
    final resolved = resolver?.call(semanticTag, key);
    if (resolved != null) return resolved;

    if (semanticTag != null) {
      final pinned = tagPins[semanticTag];
      if (pinned != null) return pinned;
    }

    assert(colors.isNotEmpty, 'BridgePalette.colors must be non-empty');
    if (colors.isEmpty) return _fallbackColor;
    return colors[index % colors.length];
  }

  /// Value equality: two palettes are interchangeable when their [colors]
  /// (ordered) and [tagPins] match. A rebuilt-but-equivalent palette therefore
  /// never reads as a configuration change.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is BridgePalette &&
        other.runtimeType == runtimeType &&
        listEquals(other.colors, colors) &&
        mapEquals(other.tagPins, tagPins);
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(colors),
    Object.hashAllUnordered([
      for (final entry in tagPins.entries) Object.hash(entry.key, entry.value),
    ]),
  );

  /// The color positional resolution degrades to when [colors] is empty.
  /// Also the first default color.
  static const Color _fallbackColor = Color(0xFF4C6E81); // dusty blue

  /// A muted, desaturated default palette that reads well against the
  /// hand-drawn aesthetic (no neon primaries).
  static const List<Color> _defaultColors = [
    _fallbackColor,
    Color(0xFFB5654A), // terracotta
    Color(0xFF6E8B6E), // sage
    Color(0xFFC9A24B), // ochre
    Color(0xFF7E6E94), // muted violet
    Color(0xFF5E8E8E), // teal-grey
    Color(0xFFAD7B8E), // dusty rose
    Color(0xFF8A8055), // olive
  ];
}
