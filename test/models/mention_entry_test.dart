import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/mention_entry.dart';

void main() {
  group('MentionEntry.toJson', () {
    test('omits reason when null, includes it when set', () {
      const without = MentionEntry(
        id: 'a1',
        name: '张三',
        notify: true,
      );
      expect(without.toJson(), {'id': 'a1', 'name': '张三', 'notify': true});

      const withReason = MentionEntry(
        id: 'a1',
        name: '张三',
        notify: true,
        reason: '帮我 review',
      );
      expect(withReason.toJson(), {
        'id': 'a1',
        'name': '张三',
        'notify': true,
        'reason': '帮我 review',
      });
    });
  });

  group('MentionEntry.fromJson', () {
    test('tolerates missing reason and non-bool notify', () {
      final entry = MentionEntry.fromJson({
        'id': 'a2',
        'name': 'Tom',
        'notify': 'false', // stringified bool from legacy data
      });
      expect(entry.id, 'a2');
      expect(entry.name, 'Tom');
      expect(entry.notify, isTrue); // non-bool falls back to default true
      expect(entry.reason, isNull);
    });

    test('reads reason when present', () {
      final entry = MentionEntry.fromJson({
        'id': 'a1',
        'name': '张三',
        'notify': false,
        'reason': 'cc 即可',
      });
      expect(entry.notify, isFalse);
      expect(entry.reason, 'cc 即可');
    });
  });
}
