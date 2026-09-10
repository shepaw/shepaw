import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/events/ack_command.dart';
import 'package:shepaw/clis/shepaw/events/emit_command.dart';
import 'package:shepaw/clis/shepaw/events/events_namespace.dart';
import 'package:shepaw/clis/shepaw/events/inbox_command.dart';
import 'package:shepaw/clis/shepaw/events/types_command.dart';
import 'package:shepaw/clis/shepaw/events/wait_command.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/she_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() {
    EventBus.resetForTesting();
    final bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
    EventBus.configure(bus);
  });

  group('events namespace', () {
    test('registers P0 commands', () async {
      final help = await EventsNamespace.instance.getHelpAsync();
      final commands = help['commands'] as Map<String, dynamic>;
      for (final name in [
        'wait',
        'inbox',
        'ack',
        'types',
        'subscribe',
        'unsubscribe',
        'list',
        'emit',
      ]) {
        expect(commands.containsKey(name), true, reason: 'missing $name');
      }
    });
  });

  group('events wait + emit', () {
    test('correlation A only receives A', () async {
      await ChatAgentScope.runScoped(
        agentId: SheService.sheId,
        body: () async {
          const cidA = 'cid_cli_a';
          const cidB = 'cid_cli_b';

          final waitFuture = EventsWaitCommand().execute({
            'correlation': cidA,
            'type': 'test.event.ping',
            'timeout': '5',
          });

          await Future<void>.delayed(const Duration(milliseconds: 20));

          EventBus.instance.emitSystem(
            systemDomain: 'test',
            type: 'test.event.ping',
            payload: {'summary': 'wrong'},
            correlationId: cidB,
          );

          EventBus.instance.emitSystem(
            systemDomain: 'test',
            type: 'test.event.ping',
            payload: {'summary': 'right'},
            correlationId: cidA,
          );

          final result = await waitFuture;
          expect(result['success'], true);
          final event = result['event'] as Map<String, dynamic>;
          expect(event['correlation_id'], cidA);
        },
      );
    });
  });

  group('events inbox + ack', () {
    test('ack removes unread', () async {
      await ChatAgentScope.runScoped(
        agentId: SheService.sheId,
        body: () async {
          EventBus.instance.addSubscription(
            agentId: SheService.sheId,
            patterns: [const EventPattern(typeGlob: 'test.event.ping')],
          );

          final emit = EventBus.instance.emitSystem(
            systemDomain: 'test',
            type: 'test.event.ping',
            payload: {'summary': 'inbox'},
            correlationId: 'cid_inbox',
          );

          final inbox = await EventsInboxCommand().execute({'unread': ''});
          expect(inbox['count'], 1);

          final ack = await EventsAckCommand().execute({'id': emit.id});
          expect(ack['acked_count'], 1);

          final unread = await EventsInboxCommand().execute({'unread': ''});
          expect(unread['count'], 0);
        },
      );
    });

    test('ack by correlation', () async {
      await ChatAgentScope.runScoped(
        agentId: SheService.sheId,
        body: () async {
          EventBus.instance.addSubscription(
            agentId: SheService.sheId,
            patterns: [const EventPattern(typeGlob: 'test.event.ping')],
          );

          EventBus.instance.emitSystem(
            systemDomain: 'test',
            type: 'test.event.ping',
            payload: {'summary': 'x'},
            correlationId: 'cid_ack_all',
          );

          final ack = await EventsAckCommand().execute({
            'correlation': 'cid_ack_all',
          });
          expect(ack['acked_count'], 1);
        },
      );
    });
  });

  group('events emit（agent / 外部包发布通道）', () {
    test('emit inherits correlation from ChatAgentScope zone', () async {
      await ChatAgentScope.runScoped(
        agentId: SheService.sheId,
        correlationId: 'cid_zone_emit',
        body: () async {
          final ok = await EventsEmitCommand().execute({
            'type': 'agent.${SheService.sheId}.tool.zone',
            'payload': '{"summary":"zone cid"}',
          });
          expect(ok['success'], true);
          expect(ok['correlation_id'], 'cid_zone_emit');
        },
      );
    });

    test('agent.<id>.* 可发布并被订阅者收到；其它前缀被拒', () async {
      await ChatAgentScope.runScoped(
        agentId: SheService.sheId,
        body: () async {
          EventBus.instance.addSubscription(
            agentId: 'agent_listener',
            patterns: [const EventPattern(typeGlob: 'agent.*')],
          );

          final ok = await EventsEmitCommand().execute({
            'type': 'agent.${SheService.sheId}.tool.done',
            'payload': '{"task":"daily-report"}',
          });
          expect(ok['success'], true);
          expect(EventBus.instance.inboxFor('agent_listener').length, 1);

          // 外部包 / agent 不能冒用系统域
          final denied = await EventsEmitCommand().execute({
            'type': 'peer.pairing.inbound',
            'payload': '{}',
          });
          expect(denied['error'], isNotNull);
        },
      );
    });
  });

  group('events types', () {
    test('lists registered types', () async {
      final result = await EventsTypesCommand().execute({});
      expect(result['count'], greaterThan(0));
      final types = result['types'] as List<dynamic>;
      expect(
        types.any((t) => (t as Map)['id'] == 'test.event.ping'),
        true,
      );
    });
  });
}
