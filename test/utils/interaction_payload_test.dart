import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/interaction_payload.dart';

void main() {
  group('interactionOptions', () {
    test('reads id/label', () {
      final options = interactionOptions([
        {'id': 'a', 'label': 'Alpha'},
        {'id': 'b', 'label': 'Beta'},
      ]);

      expect(options.map((o) => o.id), ['a', 'b']);
      expect(options.map((o) => o.label), ['Alpha', 'Beta']);
    });

    test('falls back to the hub value key', () {
      final options = interactionOptions([
        {'label': 'Alpha', 'value': 'alpha'},
        {'label': 'Beta', 'value': 'beta'},
      ]);

      expect(options.map((o) => o.id), ['alpha', 'beta']);
      expect(options.map((o) => o.label), ['Alpha', 'Beta']);
    });

    test('keeps ids unique so options never collapse into one', () {
      final options = interactionOptions([
        {'label': 'Alpha'},
        {'label': 'Alpha'},
        {'id': 'dup', 'label': 'Beta'},
        {'id': 'dup', 'label': 'Gamma'},
      ]);

      expect(options.map((o) => o.id).toSet(), hasLength(4));
      // The first occurrence keeps the id the agent knows about.
      expect(options[2].id, 'dup');
    });

    test('accepts bare strings and ignores junk entries', () {
      final options = interactionOptions(['Alpha', 42, {'label': 'Beta'}]);

      expect(options.map((o) => o.label), ['Alpha', 'Beta']);
      expect(options.every((o) => o.id.isNotEmpty), isTrue);
    });

    test('returns empty for non-list payloads', () {
      expect(interactionOptions(null), isEmpty);
      expect(interactionOptions('nope'), isEmpty);
    });
  });

  group('interactionSelectId', () {
    test('prefers select_id', () {
      expect(
        interactionSelectId({'select_id': 's1', 'confirmation_id': 'c1'}),
        's1',
      );
    });

    test('falls back to hub interaction ids', () {
      expect(interactionSelectId({'interaction_id': 'ix-1'}), 'ix-1');
      expect(interactionSelectId({'id': 'plain'}), 'plain');
      expect(interactionSelectId({'prompt': 'no id'}), '');
    });
  });
}
