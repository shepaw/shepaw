import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  test('model options round-trip and effective fast', () {
    final list = PeerModelsList.fromJson({
      'models': [
        {
          'value': 'grok-4.7',
          'display_name': 'Grok 4.7',
          'options': [
            {
              'id': 'fast',
              'display_name': 'Fast',
              'description': 'Faster',
              'values': ['false', 'true'],
              'default': 'true',
            },
          ],
        },
        {'value': 'sonnet', 'display_name': 'Sonnet'},
      ],
      'current': 'grok-4.7',
      'option_values': {'fast': 'false'},
    });

    final again = PeerModelsList.fromJson(list.toJson());
    expect(again.models.first.options.single.id, 'fast');
    expect(again.models.first.options.single.displayName, 'Fast');
    expect(again.models.first.options.single.defaultValue, 'true');
    expect(again.models.first.options.single.values, ['false', 'true']);
    expect(again.models[1].options, isEmpty);
    expect(again.optionValues['fast'], 'false');
    expect(again.effectiveOption('fast'), 'false');

    final defaults = PeerModelsList(
      models: again.models,
      current: 'grok-4.7',
    );
    expect(defaults.effectiveOption('fast'), 'true');

    final unsupported = PeerModelsList(
      models: again.models,
      current: 'sonnet',
      optionValues: const {'fast': 'false'},
    );
    expect(unsupported.effectiveOption('fast'), isNull);
  });

  test('old model payloads without options still parse', () {
    final list = PeerModelsList.fromJson({
      'models': [
        {'value': 'grok-4.7', 'display_name': 'Grok 4.7'},
      ],
      'current': 'grok-4.7',
    });
    expect(list.models.single.options, isEmpty);
    expect(list.optionValues, isEmpty);
    expect(list.effectiveOption('fast'), isNull);
    expect(list.models.single.toJson().containsKey('options'), isFalse);
  });
}
