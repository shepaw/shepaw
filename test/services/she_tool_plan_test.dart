import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_tool_plan.dart';

void main() {
  test('App 和 Hub 对同一句话规划同一串工具', () {
    final catalog = jsonDecode(
      File('test/fixtures/she_tool_sequences.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final cases = catalog['cases'] as List<dynamic>;
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final item = raw as Map<String, dynamic>;
      final planned = planSheToolSequence(
        item['user'] as String? ?? '',
        mode: item['mode'] as String? ?? 'dm',
      );
      final expected = ((item['tools'] as List?) ?? const [])
          .map((tool) => tool.toString())
          .toList();
      expect(planned, expected, reason: item['name'] as String?);
    }
  });
}
