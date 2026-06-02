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
                    color: colorScheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No agents configured',
                    style: TextStyle(
                      fontSize: 16,
                      color: colorScheme.outline,
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
      if (enabledCommands.isEmpty) {
        return 'All CLI commands available';
      } else {
        final count = enabledCommands.length;
        return '$count command(s) allowed';
      }
    }

    Color getStatusColor() {
      if (enabledCommands.isEmpty) {
        return colorScheme.primary;
      } else {
        return colorScheme.tertiary;
      }
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
          if (enabledCommands.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Namespaces: ${registry.groupCommandsByNamespace(enabledCommands).keys.join(", ")}',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.outline,
              ),
            ),
          ],
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final result = await Navigator.push<Set<String>>(
          context,
          MaterialPageRoute(
            builder: (_) => CliCommandSelectScreen(
              enabledCommands: enabledCommands,
            ),
          ),
        );

        if (result != null && result != enabledCommands) {
          // Update agent with new CLI commands
          final updated = widget.agent.copyWith(
            metadata: {
              ...widget.agent.metadata,
              if (result.isNotEmpty)
                'enabled_cli_commands': result.toList()
              else
                'enabled_cli_commands': <String>[], // Keep empty list to maintain "all allowed" state
            },
          );

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
        }
      },
    );
  }
}
