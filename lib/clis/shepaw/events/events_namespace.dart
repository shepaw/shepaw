import '../../cli_base.dart';
import 'ack_command.dart';
import 'emit_command.dart';
import 'inbox_command.dart';
import 'list_subscriptions_command.dart';
import 'providers_command.dart';
import 'subscribe_command.dart';
import 'types_command.dart';
import 'unsubscribe_command.dart';
import 'wait_command.dart';

/// [TOOLING 层] events 命名空间 — Agent 事件感知（P0: wait / inbox / ack / types）
class EventsNamespace extends CliNamespace {
  static final instance = EventsNamespace._();
  EventsNamespace._();

  @override
  String get namespace => 'events';

  @override
  String get description =>
      'Agent event bus — wait, inbox, ack, list types (correlation-aware)';

  @override
  String get icon => '📡';

  @override
  Map<String, CliCommand> get commands => {
        'wait': EventsWaitCommand(),
        'inbox': EventsInboxCommand(),
        'ack': EventsAckCommand(),
        'types': EventsTypesCommand(),
        'subscribe': EventsSubscribeCommand(),
        'unsubscribe': EventsUnsubscribeCommand(),
        'list': EventsListSubscriptionsCommand(),
        'emit': EventsEmitCommand(),
        'providers': EventsProvidersCommand(),
      };

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['hints'] = [
      'Machine-speed RPC: domain cmd → events wait --correlation <id> --type <type> --timeout 30',
      'Human-speed flows: use active subscriptions (P1); do not block wait for minutes',
      'Poll: events inbox [--unread] [--cursor N]',
    ];
    return base;
  }
}
