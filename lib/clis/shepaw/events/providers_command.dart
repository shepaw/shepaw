import '../../cli_base.dart';
import '../../../services/event/event_provider_registry.dart';

class EventsProvidersCommand extends CliCommand {
  @override
  String get name => 'providers';

  @override
  String get description => 'List external event providers under ~/shepaw/event-providers/';

  @override
  String get usage => 'shepaw events providers';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final providers = await EventProviderRegistry.instance.scan();
    return {
      'root': EventProviderRegistry.instance.rootDir.path,
      'count': providers.length,
      'providers': providers.map((p) => p.toJson()).toList(),
    };
  }
}
