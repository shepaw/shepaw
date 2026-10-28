import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/interaction_card_close.dart';

void main() {
  test('按 id 收起表单，不谎称用户提交过', () {
    final next = metadataClosingInteraction(
      {
        'form': {
          'form_id': 'form-1',
          'title': '选哪个端口',
        },
      },
      interactionId: 'form-1',
      reason: 'timeout',
    );

    expect(next?['form']['closed'], 'timeout');
    expect(next?['form']['submitted_values'], isNull);
  });

  test('按 id 收起审批卡时写下 expired 哨兵', () {
    final next = metadataClosingInteraction(
      {
        'action_confirmation': {
          'confirmation_id': 'appr-1',
          'prompt': '允许吗',
        },
      },
      interactionId: 'appr-1',
      reason: 'cancelled',
    );

    final card = next?['action_confirmation'] as Map;
    expect(card['closed'], 'cancelled');
    expect(card['selected_action_id'], kExpiredActionId);
  });

  test('用户已经答过的卡不动', () {
    expect(
      metadataClosingInteraction(
        {
          'form': {
            'form_id': 'form-1',
            'submitted_values': {'port': '3000'},
          },
        },
        interactionId: 'form-1',
        reason: 'timeout',
      ),
      isNull,
    );
    expect(
      metadataClosingInteraction(
        {
          'action_confirmation': {
            'confirmation_id': 'appr-1',
            'selected_action_id': 'allow',
          },
        },
        interactionId: 'appr-1',
        reason: 'timeout',
      ),
      isNull,
    );
  });

  test('已经作废的卡不改原因', () {
    expect(
      metadataClosingInteraction(
        {
          'form': {'form_id': 'form-1', 'closed': 'timeout'},
        },
        interactionId: 'form-1',
        reason: 'turn_ended',
      ),
      isNull,
    );
  });

  test('deferred 表单在回合结束时不作废', () {
    final next = metadataClosingOpenCards(
      {
        'form': {'form_id': 'form-1', 'deferred': true},
      },
      reason: 'turn_ended',
    );

    expect(next, isNull);
  });

  test('按 id 明确收场时 deferred 表单照常关闭', () {
    final next = metadataClosingInteraction(
      {
        'form': {'form_id': 'form-1', 'deferred': true},
      },
      interactionId: 'form-1',
      reason: 'declined',
    );

    expect(next?['form']['closed'], 'declined');
    expect(next?['form']['deferred'], isTrue);
  });

  test('标 deferred 时清掉先到的 closed', () {
    final next = metadataMarkingFormDeferred(
      {
        'form': {'form_id': 'form-1', 'closed': 'turn_ended'},
      },
      interactionId: 'form-1',
    );

    expect(next?['form']['deferred'], isTrue);
    expect(next?['form']['closed'], isNull);
  });

  test('已经答过的表单不会被标成 deferred', () {
    expect(
      metadataMarkingFormDeferred(
        {
          'form': {
            'form_id': 'form-1',
            'submitted_values': {'port': '3000'},
          },
        },
        interactionId: 'form-1',
      ),
      isNull,
    );
  });

  test('答案没送到主机时，已提交的表单退回可答并预填', () {
    final next = metadataMarkingFormDeferred(
      {
        'form': {
          'form_id': 'form-1',
          'closed': 'turn_ended',
          'submitted_values': {'port': '3000', 'tags': ['a']},
          'fields': [
            {'field_id': 'port', 'type': 'text_input'},
            {'name': 'tags', 'type': 'multi_select'},
            {'field_id': 'note', 'type': 'text_input'},
          ],
        },
      },
      interactionId: 'form-1',
      reopen: true,
    );

    final form = next?['form'] as Map;
    expect(form['submitted_values'], isNull);
    expect(form['closed'], isNull);
    expect(form['deferred'], isTrue);
    final fields = form['fields'] as List;
    expect(fields[0]['default'], '3000');
    expect(fields[1]['default'], ['a']);
    expect((fields[2] as Map).containsKey('default'), isFalse);
  });

  test('没有卡片 id 时，回合结束仍收起还开着的卡', () {
    final next = metadataClosingOpenCards(
      {
        'form': {'form_id': 'form-1', 'title': '端口'},
        'action_confirmation': {
          'confirmation_id': 'appr-1',
          'selected_action_id': 'deny',
        },
      },
      reason: 'turn_ended',
    );

    expect(next?['form']['closed'], 'turn_ended');
    // 已经拒绝过的审批卡保持原样。
    expect(next?['action_confirmation']['closed'], isNull);
    expect(next?['action_confirmation']['selected_action_id'], 'deny');
  });
}
