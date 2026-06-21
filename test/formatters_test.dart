import 'package:analytics_toolkit/analytics_toolkit.dart' show IntValue;
import 'package:flutter_test/flutter_test.dart';
import 'package:hand_drawn_analytics/hand_drawn_analytics.dart';
import 'package:intl/intl.dart';

void main() {
  test('number formatting follows a runtime locale switch', () {
    const formatters = BridgeFormatters();
    final saved = Intl.defaultLocale;
    addTearDown(() => Intl.defaultLocale = saved);

    Intl.defaultLocale = 'en_US';
    expect(formatters.tableCell(const IntValue(1234567)), '1,234,567');

    Intl.defaultLocale = 'de';
    expect(formatters.tableCell(const IntValue(1234567)), '1.234.567');
  });
}
