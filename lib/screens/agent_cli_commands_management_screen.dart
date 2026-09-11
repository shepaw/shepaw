import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import '../models/remote_agent.dart';
import '../services/remote_agent_service.dart';
import '../service_locator.dart' show getIt;
import '../services/cli_namespace_registry.dart';
import 'cli_command_select_screen.dart';

/// Screen for managing CLI command permissions across all agents.
/// 
/// Displays a list of all agents and allows configuring which CLI commands
/// each agent can execute.
class AgentCliCommandsManagementScreen extends StatefulWidget {
  const AgentCliCommandsManagementScreen({super.key});

  @override
  State<AgentCliCommandsManagementScreen> createState() =>
      _AgentCliCommandsManagementScreenState();
}

class _AgentCliCommandsManagementScreenState
    extends State<AgentCliCommandsManagementScreen> {
  late Future<List<RemoteAgent>> _agentsFuture;
  late final RemoteAgentService _agentService;

  @override
  void initState() {
    super.initState();
    _agentService = getIt<RemoteAgentService>();
    _loadAgents();
  }

  void _loadAgents() {
    setState(() {
      _agentsFuture = _agentService.getAllAgents();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('CLI Commands'),
        centerTitle: true,
      ),
      body: FutureBuilder<List<RemoteAgent>>(
        future: _agentsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final agents = snapshot.data ?? [];

          if (agents.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    size: 64,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No agents configured',
                    style: TextStyle(
                      fontSize: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: agents.length,
            separatorBuilder: (_, __) => Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: colorScheme.outlineVariant,
            ),
            itemBuilder: (context, index) {
              final agent = agents[index];
              return _AgentCliCommandsTile(
                agent: agent,
                agentService: _agentService,
                onRefresh: _loadAgents,
              );
            },
          );
        },
      ),
    );
  }
}

/// Tile showing CLI command status for a single agent.
class _AgentCliCommandsTile extends StatefulWidget {
  final RemoteAgent agent;
  final RemoteAgentService agentService;
  final VoidCallback onRefresh;

  const _AgentCliCommandsTile({
    required this.agent,
    required this.agentService,
    required this.onRefresh,
  });

  @override
  State<_AgentCliCommandsTile> createState() => _AgentCliCommandsTileState();
}

class _AgentCliCommandsTileState extends State<_AgentCliCommandsTile> {
  RemoteAgentService get _agentService => widget.agentService;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final enabledCommands = widget.agent.enabledCliCommands;
    final registry = CliNamespaceRegistry.instance;

    String getStatusText() {
      if (enabledCommands == null) {
        return 'All CLI commands available. Store read / help skip review; '
            'OS non-safe tools always confirm. Per-agent “require approval” '
            'is on the agent detail page.';
      }
      if (enabledCommands.isEmpty) {
        return 'All CLI commands blocked — this agent cannot call shepaw.';
      }
      return '${enabledCommands.length} command(s) allowed';
    }

    Color getStatusColor() {
      if (enabledCommands == null) {
        return colorScheme.primary;
      }
      if (enabledCommands.isEmpty) {
        return colorScheme.error;
      }
      return colorScheme.tertiary;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            widget.agent.avatar,
            style: const TextStyle(fontSize: 24),
          ),
        ),
      ),
      title: Text(
        widget.agent.name,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            getStatusText(),
            style: TextStyle(
              fontSize: 12,
              color: getStatusColor(),
              fontWeight: FontWeight.w500,
            ),
          ),
          if (enabledCommands != null && enabledCommands.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Namespaces: ${registry.groupCommandsByNamespace(enabledCommands).keys.join(", ")}',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final result = await Navigator.push<CliCommandSelection>(
          context,
          MaterialPageRoute(
            builder: (_) => CliCommandSelectScreen(
              enabledCommands: enabledCommands,
            ),
          ),
        );

        // null = the user went back without saving; leave the agent alone.
        if (result == null || setEquals(result.commands, enabledCommands)) {
          return;
        }

        // Three-state persistence: absent key = unrestricted, `[]` = block all,
        // non-empty list = explicit allowlist. The old code wrote `[]` for
        // "empty", which the model layer read back as "unrestricted".
        final metadata = {...widget.agent.metadata};
        if (result.commands == null) {
          metadata.remove('enabled_cli_commands');
        } else {
          metadata['enabled_cli_commands'] = result.commands!.toList();
        }
        final updated = widget.agent.copyWith(metadata: metadata);

        try {
          await _agentService.updateAgent(updated);
          widget.onRefresh();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('CLI commands updated'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      },
    );
  }
}
