import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  group('SheService.buildCoreIdentityBlock (addressing)', () {
    test('includes strict rules against honorific spam', () {
      final block = SheService.instance.buildCoreIdentityBlock();
      expect(block, contains('How to Address Them'));
      expect(block, contains('Do NOT'));
      expect(block, contains('主人'));
      expect(block, contains('once per reply'));
      expect(block, contains('internal role label'));
    });
  });

  group('SheService.buildSessionEndBlock (single-source memory)', () {
    test('self-reflections go to she_memory.db via memory.append', () {
      final block = SheService.instance.buildSessionEndBlock();
      expect(block, contains('memory.append --key self_notes'));
      expect(block, isNot(contains('--type self --soul')));
    });

    test('user impression still routed to cognition-write', () {
      final block = SheService.instance.buildSessionEndBlock();
      expect(block, contains('--type user --field impression'));
    });
  });

  group('SheService.truncateTail', () {
    test('returns text unchanged when within budget', () {
      expect(SheService.truncateTail('hello', 10), 'hello');
      expect(SheService.truncateTail('hello', 5), 'hello');
    });

    test('keeps the tail and prefixes an omission note when over budget', () {
      final text = 'a' * 100 + 'b' * 100;
      final out = SheService.truncateTail(text, 50);
      expect(out, startsWith('[older entries omitted]\n'));
      expect(out.length, '[older entries omitted]\n'.length + 50);
      expect(out, endsWith('b' * 50));
    });
  });
}
