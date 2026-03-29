import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
import 'agent_memory_db_service.dart';
import 'cognition_service.dart';
import 'she_service.dart';
import 'ui_component_registry.dart';
import 'os_tool_registry.dart';
import 'skill_registry.dart';
import 'model_registry.dart';

/// Builds the complete system prompt for any Agent — She or others — using a
/// unified, configurable layering approach.
///
/// ## Layering order (matching She's original stacking order)
///
/// ```
///  ①  Identity block          ← agent's name (all agents)
///  ②  Description block       ← She: core identity; others: system_prompt
///  ③  Tools block             ← UI / OS / Skills / ToolModels / shepaw CLI
///  ③' She meta-cognition      ← [She-only] on-demand capability discovery guide
///  ④  She memory context      ← soul  [She-only, optional]
///  ③.5 Current time           ← injected by SheService inside legacy path
///  ⑤  Custom prompt           ← DM override or user-set system_prompt
///  ⑥  User-strategy block     ← [She-only, optional, default OFF]
///  ⑦  Profile snapshot        ← [She-only, optional, default OFF]
///  ⑦' User profile (brief)    ← [non-She, optional] core fields only
///  ⑧  First-meeting block     ← [She-only, conditional]
///  ⑧' Agent memories          ← [non-She, optional] recent N memories
///  ⑧'' Non-She meta CLI       ← [non-She] meta/tools namespace guidance
///  ⑨  Session-end block       ← [She-only, optional]
///  ⑨' Non-She session-end     ← [non-She] soul/cognition/memory update guide
/// ```
///
/// She-specific sections are delegated entirely to [SheService] so that the
/// soul / memory / profile logic stays in one place.
///
/// Non-She sections are built from [CognitionService] (user profile) and
/// [AgentMemoryDbService] (per-agent memories).
class AgentPromptBuilder {
  final RemoteAgent agent;

  /// DM-channel system-prompt override.  When non-null and non-empty, this
  /// replaces the agent's default `system_prompt` metadata value.
  final String? dmSystemPromptOverride;

  AgentPromptBuilder({
    required this.agent,
    this.dmSystemPromptOverride,
  });

  /// Build the complete system prompt according to the agent's [PromptStackConfig].
  Future<String> buildSystemPrompt() async {
    final config = agent.promptStackConfig;

    // In lightweight mode we force tool descriptions to 'summary' and skip
    // heavy context blocks (memories, cognitions) that the agent can retrieve
    // on demand via `shepaw system tools-detail` or similar commands.
    final effectiveTools = config.lightweightMode
        ? config.tools.copyWith(toolDescriptionLevel: 'summary')
        : config.tools;
    final parts = <String>[];

    // ① Identity — always include the agent's name so the model can recognise
    //   when quoted messages refer to itself.
    if (config.includeIdentity) {
      final id = _buildIdentityBlock();
      if (id.isNotEmpty) parts.add(id);
    }

    // ② Description
    if (config.includeDescription) {
      final desc = await _buildDescriptionBlock();
      if (desc.isNotEmpty) parts.add(desc);
    }

    // ③ Tools documentation
    final toolParts = _buildToolsBlocks(effectiveTools, config.she);
    parts.addAll(toolParts);

    // ③' She-only: meta-cognition block (on-demand capability discovery)
    if (agent.isShe && config.she.includeMetaCognition) {
      parts.add(SheService.buildMetaCognitionBlock());
    }

    // ④ She-only: memory context (soul)
    if (agent.isShe && config.she.includeSheMemory) {
      final mem = await SheService.instance.buildMemoryContextBlock();
      if (mem.isNotEmpty) parts.add(mem);
    }

    // ③.5 She-only: current time (always injected for She)
    if (agent.isShe) {
      parts.add(SheService.instance.buildCurrentTimeBlock());
    }

    // ⑤ Custom / DM system prompt
    // For She: system_prompt is soul seed only (handled below) — never shown
    // as "Master's Custom Settings" to avoid duplicating soul content.
    // Only a DM-channel override is injected as a custom block.
    if (agent.isShe) {
      // Seed soul from system_prompt when soul is still the default value
      final userSetPrompt = agent.metadata['system_prompt'] as String? ?? '';
      if (userSetPrompt.isNotEmpty) {
        await SheService.instance.seedSoulFromUserPrompt(userSetPrompt);
      }
      // Inject DM override as custom settings block (if any)
      if (dmSystemPromptOverride != null && dmSystemPromptOverride!.isNotEmpty) {
        parts.add(_wrapCustomPrompt(dmSystemPromptOverride!));
      }
    } else if (config.includeCustomPrompt) {
      final custom = _resolveCustomPrompt();
      if (custom.isNotEmpty) {
        parts.add(_wrapCustomPrompt(custom));
      }
    }

    // ⑥ She-only: user-understanding strategy
    if (agent.isShe && config.she.includeUserStrategy) {
      final strategy = await SheService.instance.buildUserStrategyBlock();
      if (strategy.isNotEmpty) parts.add(strategy);
    }

    // ⑦ She-only: user-profile snapshot
    if (agent.isShe && config.she.includeProfileSnapshot) {
      final snapshot = await SheService.instance
          .buildProfileSnapshotBlock(level: config.she.profileSnapshotLevel);
      if (snapshot.isNotEmpty) parts.add(snapshot);
    }

    // ⑦' She-only: self-cognition (self_notes from minds.db)
    if (agent.isShe && config.she.includeSheSelfCognition) {
      final selfCog = await SheService.instance.buildSheSelfCognitionBlock();
      if (selfCog.isNotEmpty) parts.add(selfCog);
    }

    // ⑦'' She-only: user-cognition (impression/notes from minds.db)
    // Skipped in lightweight mode — She can query on demand.
    if (agent.isShe && !config.lightweightMode && config.she.includeUserCognition) {
      final userCog = await SheService.instance.buildUserCognitionBlock();
      if (userCog.isNotEmpty) parts.add(userCog);
    }

    // ⑦''' Non-She: brief user profile (core fields only)
    if (!agent.isShe && config.agent.includeUserProfile) {
      final profileBlock = await _buildAgentUserProfileBlock();
      if (profileBlock.isNotEmpty) parts.add(profileBlock);
    }

    // ⑧ She-only: first-meeting instruction (conditional)
    if (agent.isShe && config.she.includeFirstMeeting) {
      final isFirst = await SheService.instance.isFirstMeeting();
      if (isFirst) parts.add(SheService.instance.buildFirstMeetingBlock());
    }

    // ⑧' Non-She: agent's own soul (self-cognition from minds.db)
    // Skipped in lightweight mode.
    if (!config.lightweightMode && !agent.isShe && config.agent.includeAgentSelfCognition) {
      final selfCog = await _buildAgentSelfCognitionBlock();
      if (selfCog.isNotEmpty) parts.add(selfCog);
    }

    // ⑧'' Non-She: agent's user-cognition (impression/notes from minds.db)
    // Skipped in lightweight mode.
    if (!config.lightweightMode && !agent.isShe && config.agent.includeAgentUserCognition) {
      final userCog = await _buildAgentUserCognitionBlock();
      if (userCog.isNotEmpty) parts.add(userCog);
    }

    // ⑧''' Non-She: agent's own recent memories
    // Skipped in lightweight mode.
    if (!config.lightweightMode && !agent.isShe && config.agent.includeAgentMemory) {
      final memoriesBlock =
          await _buildAgentMemoriesBlock(config.agent.memoryLimit);
      if (memoriesBlock.isNotEmpty) parts.add(memoriesBlock);
    }

    // ⑧'' Non-She: meta/tools CLI guidance (self-discovery)
    // Always inject when enabled — helps agents discover their tool capabilities.
    if (!agent.isShe && effectiveTools.includeShepawMetaCli) {
      final metaBlock = _buildAgentMetaCliBlock();
      if (metaBlock.isNotEmpty) parts.add(metaBlock);
    }

    // ⑨ She-only: session-end write instructions
    if (agent.isShe && config.she.includeSessionEnd) {
      parts.add(SheService.instance.buildSessionEndBlock());
    }

    // ⑨' Non-She: session-end cognition/memory update guidance
    if (!agent.isShe) {
      parts.add(_buildAgentSessionEndBlock());
    }

    return parts.where((s) => s.trim().isNotEmpty).join('\n\n');
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// A one-line identity declaration so the model knows its own name.
  /// This is intentionally minimal — She's full core identity comes in ②.
  String _buildIdentityBlock() {
    if (agent.isShe) return ''; // She's name is in the core identity block (②)
    return 'Your name is ${agent.name}.';
  }

  /// The main description / persona block.
  Future<String> _buildDescriptionBlock() async {
    if (agent.isShe) {
      return SheService.instance.buildCoreIdentityBlock();
    }
    // For non-She agents the description IS the system_prompt.
    // The custom/DM override is handled separately in ⑤, so here we return
    // the agent's stored prompt only.
    return agent.metadata['system_prompt'] as String? ?? '';
  }

  /// Resolve the custom prompt: DM override takes priority over the agent's
  /// stored system_prompt (which is already in the description block for
  /// non-She agents — so for non-She we only inject dmSystemPromptOverride).
  ///
  /// For She, `metadata['system_prompt']` is ONLY used as a soul seed (see
  /// step ④ above); it is NOT re-injected as "Master's Custom Settings" to
  /// avoid duplicating the soul content.  Only a DM-channel override is
  /// injected as a custom block for She.
  String _resolveCustomPrompt() {
    if (dmSystemPromptOverride != null && dmSystemPromptOverride!.isNotEmpty) {
      return dmSystemPromptOverride!;
    }
    // For She: system_prompt is used as soul seed only, not shown separately.
    if (agent.isShe) return '';
    // For other agents the system_prompt was already in the description block.
    return '';
  }

  static String _wrapCustomPrompt(String prompt) => '''
## Master's Custom Settings for You
$prompt

(Please follow the above settings without violating your core identity.)''';

  // ── Non-She context blocks ─────────────────────────────────────────────────

  /// ⑦' Build the agent's self-cognition block (soul) from minds.db.
  Future<String> _buildAgentSelfCognitionBlock() async {
    final self = await CognitionService.instance.getSelfCognition(agent.id);
    if (self == null || self.soul.isEmpty) return '';

    return '''
## Your Core Purpose & Principles
${self.soul}''';
  }

  /// ⑦'' Build the agent's user-cognition block (impression/notes) from minds.db.
  Future<String> _buildAgentUserCognitionBlock() async {
    final user = await CognitionService.instance.getUserCognition(agent.id);
    if (user == null) return '';

    final parts = <String>[];
    if (user.userImpression?.isNotEmpty ?? false) {
      parts.add('**Your Impression**: ${user.userImpression}');
    }
    if (user.userNotes?.isNotEmpty ?? false) {
      parts.add('**Your Notes**: ${user.userNotes}');
    }
    if (parts.isEmpty) return '';

    return '''
## How I Understand My Master
${parts.join('\n')}''';
  }
  ///
  /// Injects only non-empty core fields (name/age/gender/occupation/city)
  /// so the agent has basic context about the user without overwhelming the
  /// prompt with She-level detail.
  Future<String> _buildAgentUserProfileBlock() async {
    const coreKeys = ['name', 'age', 'gender', 'occupation', 'city'];
    final profile = await CognitionService.instance.getAllUserProfile();

    final lines = <String>[];
    for (final key in coreKeys) {
      final val = profile[key];
      if (val != null && val.isNotEmpty) {
        lines.add('- **${_profileLabel(key)}**: $val');
      }
    }
    if (lines.isEmpty) return '';

    return '''
## About Your Master
${lines.join('\n')}''';
  }

  /// ⑧' Build the recent-memories block for non-She agents.
  ///
  /// Fetches up to [limit] memories sorted by `memory_time` descending.
  /// Returns empty string when the agent has no memories yet.
  Future<String> _buildAgentMemoriesBlock(int limit) async {
    final memories = await AgentMemoryDbService.forAgent(agent.id)
        .getAllMemories(limit: limit);
    if (memories.isEmpty) return '';

    final buffer = StringBuffer('## Your Memory\n');
    for (final m in memories) {
      final timeStr = DateTime.fromMillisecondsSinceEpoch(m.memoryTime)
          .toLocal()
          .toString()
          .substring(0, 16);
      final keywords =
          m.memoryKeywords.isNotEmpty ? ' [${m.memoryKeywords.join(', ')}]' : '';
      buffer.writeln('- [$timeStr]$keywords ${m.memoryContent}');
    }
    buffer.write('\nWhen you learn new things about the user or have new observations, use `shepaw agents memory write --id ${agent.id}` to record them.');
    return buffer.toString();
  }

  /// Human-readable label for core profile field keys.
  static String _profileLabel(String key) {
    const labels = {
      'name': 'Name',
      'age': 'Age',
      'gender': 'Gender',
      'occupation': 'Occupation',
      'city': 'City',
    };
    return labels[key] ?? key;
  }

  /// Build all tool-documentation sections according to [ToolsStackConfig]
  /// and [SheStackConfig] (for the shepaw CLI).
  List<String> _buildToolsBlocks(
    ToolsStackConfig tools,
    SheStackConfig she,
  ) {
    final result = <String>[];
    final level = tools.toolDescriptionLevel;

    if (tools.includeUI) {
      final suffix = UIComponentRegistry.instance.systemPromptSuffixLayered(level);
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeOsTools && agent.enabledOsTools.isNotEmpty) {
      final suffix = OsToolRegistry.instance
          .systemPromptSuffixLayered(agent.enabledOsTools, level);
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeSkills && agent.enabledSkills.isNotEmpty) {
      final suffix = SkillRegistry.instance
          .systemPromptSuffixLayered(agent.enabledSkills, level);
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeToolModels && agent.enabledToolModels.isNotEmpty) {
      final suffix = ModelRegistry.instance.systemPromptSuffixLayered(
        agent.enabledToolModels,
        level,
        scenarioOverrides: agent.toolModelScenarios,
      );
      if (suffix.isNotEmpty) result.add(suffix);
    }

    // shepaw CLI — She-exclusive; config switch lets users disable individual
    // sub-commands (e.g. disable memory writes, disable agent chat, …).
    if (tools.includeShepawCli && agent.isShe) {
      final cliBlock = SheService.instance.buildShepawCliBlock(she);
      if (cliBlock.isNotEmpty) result.add(cliBlock);
    }

    return result;
  }

  /// Build the meta/tools CLI guidance block for non-She agents.
  /// Teaches agents about `shepaw meta *` and `shepaw tools *` for self-discovery
  /// without exposing context or profile-write capabilities.
  String _buildAgentMetaCliBlock() => '''
## System Discovery (On-Demand)

You have access to a `shepaw` tool to discover your own capabilities and get system info.

**Available namespaces**:
- `meta datetime` — current date/time
- `meta system.info` — app information
- `meta system.capabilities` — overview of what the system supports
- `meta system.tools-list` — list all available tools (UI, OS, skills)
- `meta system.tools-detail --name <tool>` — full parameter docs for any tool
- `tools list` — list all tools by category
- `tools os.list` — list OS tools
- `tools os.detail --name <tool>` — OS tool details
- `skills list` — list available LLM skill libraries
- `skills detail --name <skill>` — skill details
- `help` — complete CLI reference

**How to use**: Call `shepaw help` to see all available commands, or use the namespace-specific commands above when you need specific information. Add `--help` to any command call for contextual help.''';

  /// Build the session-end guidance block for non-She agents.
  /// Encourages agents to persist new insights at the end of each conversation.
  String _buildAgentSessionEndBlock() => '''
## Before This Conversation Ends

If you learned something new or formed new insights during this conversation:
- New observations about the user → `shepaw context agents.memory-write --id ${agent.id} --content "..." --type observation`
- Updated understanding of your purpose or identity → `shepaw context agents.cognition-write --id ${agent.id} --type self --soul "(complete updated soul)"`
- New impression of the user → `shepaw context agents.cognition-write --id ${agent.id} --type user --field impression --value "..."`

These writes are silent — the user does not see them. Only write when you have genuinely new insights.''';
}
