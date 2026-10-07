import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  test('App 惜宝分段和 Hub 用同一批对话 fixture', () {
    final file = File('test/fixtures/she_dialogue.json');
    final catalog = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final cases = catalog['cases'] as List<dynamic>;
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final item = raw as Map<String, dynamic>;
      final name = item['name'] as String;
      final profile = <String, String>{};
      final rawProfile = item['profile'];
      if (rawProfile is Map) {
        rawProfile.forEach((key, value) {
          profile[key.toString()] = value?.toString() ?? '';
        });
      }
      final prompt = SheService.assembleComparisonPrompt(
        mode: item['mode'] as String? ?? 'dm',
        profile: profile,
        soul: item['soul'] as String?,
        longTermMemory: item['long_term_memory'] as String?,
        skills: ((item['skills'] as List?) ?? const []).map((e) => e.toString()).toList(),
        nowLocal: item['now_local'] as String? ?? '',
        roomName: item['room_name'] as String?,
        sheIsAdmin: item['she_is_admin'] as bool? ?? true,
      );
      for (final needle in (item['must_contain'] as List? ?? const [])) {
        expect(prompt, contains(needle), reason: name);
      }
      for (final needle in (item['must_not_contain'] as List? ?? const [])) {
        expect(prompt, isNot(contains(needle)), reason: name);
      }
    }
  });
}
