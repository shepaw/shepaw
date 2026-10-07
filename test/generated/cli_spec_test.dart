import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/generated/cli_spec/catalog.dart';
import 'package:shepaw/generated/cli_spec/validator.dart';

void main() {
  test('spec hash is present and fixtures match the validator', () {
    expect(specHash, hasLength(64));
    final catalog = jsonDecode(catalogJson) as Map<String, dynamic>;
    expect(catalog['spec_hash'], specHash);
    final cases = catalog['fixtures'] as List<dynamic>;
    expect(cases, isNotEmpty);
    for (final raw in cases) {
      final item = raw as Map<String, dynamic>;
      final name = item['name'] as String;
      final result = validateCommand(item['command'] as String, item['args']);
      if (item['ok'] == true) {
        expect(result.ok, isTrue, reason: name);
        expect(result.args, item['normalized'], reason: name);
      } else {
        expect(result.ok, isFalse, reason: name);
        expect(result.code, item['code'], reason: name);
      }
    }
  });
}
