import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';

class EventsTypesCommand extends CliCommand {
  @override
  String get name => 'types';

  @override
  String get description => 'List registered event types';

  @override
  String get usage => 'shepaw events types [--namespace test]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final ns = flags['namespace']?.trim();
    final registry = EventBus.instance.registry;
    final types = ns != null && ns.isNotEmpty
        ? registry.byNamespace(ns)
        : registry.all.toList()..sort((a, b) => a.id.compareTo(b.id));

    return {
      'count': types.length,
      'types': types.map((t) => t.toJson()).toList(),
    };
  }
}
