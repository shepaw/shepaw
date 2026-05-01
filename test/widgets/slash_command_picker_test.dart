import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/widgets/chat/slash_command_picker.dart';

void main() {
  group('SlashCommandPicker.filter', () {
    const commands = [
      SlashCommandInfo(name: 'plan', description: 'Plan work'),
      SlashCommandInfo(name: 'compact', description: 'Compact the conversation'),
      SlashCommandInfo(name: 'context', description: 'Show tokens'),
      SlashCommandInfo(name: 'review', description: 'Review a PR'),
    ];

    test('returns everything (capped at 20) when query is empty', () {
      final out = SlashCommandPicker.filter(commands, '');
      expect(out.length, 4);
      expect(out.map((c) => c.name).toList(), ['plan', 'compact', 'context', 'review']);
    });

    test('prefix matches rank above contains matches', () {
      final out = SlashCommandPicker.filter(commands, 'co');
      // 'compact' and 'context' both start with 'co', 'compact' also contains via description
      expect(out.first.name, 'compact');
      expect(out.take(2).map((c) => c.name).toSet(), {'compact', 'context'});
    });

    test('matches description via contains', () {
      final out = SlashCommandPicker.filter(commands, 'token');
      expect(out.length, 1);
      expect(out.first.name, 'context');
    });

    test('case-insensitive matching on name', () {
      final out = SlashCommandPicker.filter(commands, 'PL');
      expect(out.first.name, 'plan');
    });

    test('empty result for no match', () {
      final out = SlashCommandPicker.filter(commands, 'zzz');
      expect(out, isEmpty);
    });

    test('caps at 20 entries', () {
      final many = List.generate(50, (i) => SlashCommandInfo(name: 'cmd$i'));
      final out = SlashCommandPicker.filter(many, '');
      expect(out.length, 20);
    });
  });
}
