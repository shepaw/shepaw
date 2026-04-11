import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
import 'agent_memory_db_service.dart';
import 'cognition_service.dart';
import 'she_service.dart';
import 'ui_component_registry.dart';
import '../clis/shepaw/os/os_tool_registry.dart';
import 'skill_registry.dart';
import 'model_registry.dart';

/// Builds the complete system prompt for any Agent — She or others — using a
/// unified, configurable layering approach.
///
/// ## Layering order
///
/// ```
///  ①   Identity block          ← agent's name (non-She only; She's name is in ②)
///  ②   Description block       ← She: core identity; others: system_prompt
///  ③   Tools block             ← UI / OS / Skills / ToolModels
///  ③.5 She data-access CLI     ← [She-only] shepaw CLI data-access reference
///  ③'  Shepaw guidance         ← tool-discovery + web-search guidance (all agents,
///                                 content scoped to each agent's actual permissions)
///  ④   She memory context      ← soul  [She-only via config.she.includeSheMemory]
///  ③.6 Current time            ← injected for all agents
///  ⑤   Custom prompt           ← DM override or user-set system_prompt
///  ⑥   User-strategy block     ← [She-only via config.she.includeUserStrategy]
///  ⑦   Profile snapshot        ← [She-only via config.she.includeProfileSnapshot]
///  ⑦'  She self-cognition      ← [She-only via config.she.includeSheSelfCognition]
///  ⑦'' She user-cognition      ← [She-only via config.she.includeUserCognition]
///  ⑦'''Non-She user profile    ← [non-She via config.agent.includeUserProfile]
///  ⑧   First-meeting block     ← [She-only via config.she.includeFirstMeeting]
///  ⑧'  Non-She self-cognition  ← [non-She via config.agent.includeAgentSelfCognition]
///  ⑧'' Non-She user-cognition  ← [non-She via config.agent.includeAgentUserCognition]
///  ⑧'''Non-She agent memories  ← [non-She via config.agent.includeAgentMemory]
///  ⑨   Session-end block       ← all agents (She: guarded by config.she.includeSessionEnd)
/// ```
///
/// The only remaining `agent.isShe` checks are in the three spots where the
/// behavior genuinely differs regardless of config:
///   • `_buildIdentityBlock` — She's name lives in her core-identity block (②)
///   • `_buildDescriptionBlock` — She → core identity; non-She → system_prompt
///   • Step ⑤ (custom prompt) — She seeds soul; non-She injects as custom settings
///
/// Everything else is driven by [PromptStackConfig] flags.  Non-She agents use
/// [PromptStackConfig.forOtherAgent] which sets [SheStackConfig.disabled] and
/// disables `includeShepawCli`, so all She-exclusive config checks evaluate to
/// false automatically — no hardcoded `!agent.isShe` guard needed.
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

    // ③' Shepaw guidance — unified for She and non-She.
    // For She:     full meta-cognition block (config.she.includeMetaCognition).
    // For non-She: permission-scoped meta CLI block (effectiveTools.includeShepawMetaCli).
    // Content is produced by SheService.buildShepawGuidanceBlock() which is
    // aware of each agent's actual CLI permissions.
    final wantsShepawGuidance = agent.isShe
        ? config.she.includeMetaCognition
        : effectiveTools.includeShepawMetaCli;
    if (wantsShepawGuidance) {
      parts.add(SheService.buildShepawGuidanceBlock(agent));
    }

    // ④ She memory context (soul) — guarded by SheStackConfig flag.
    // Non-She agents have SheStackConfig.disabled so this is always false for them.
    if (config.she.includeSheMemory) {
      final mem = await SheService.instance.buildMemoryContextBlock();
      if (mem.isNotEmpty) parts.add(mem);
    }

    // ③.6 Current time — injected for all agents so they have accurate temporal context.
    parts.add(SheService.instance.buildCurrentTimeBlock());

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
        parts.add(SheService.wrapCustomPrompt(dmSystemPromptOverride!));
      }
    } else if (config.includeCustomPrompt) {
      final custom = _resolveCustomPrompt();
      if (custom.isNotEmpty) {
        parts.add(SheService.wrapCustomPrompt(custom));
      }
    }

    // ⑥ User-understanding strategy — She-only via config flag.
    if (config.she.includeUserStrategy) {
      final strategy = await SheService.instance.buildUserStrategyBlock();
      if (strategy.isNotEmpty) parts.add(strategy);
    }

    // ⑦ User-profile snapshot — She-only via config flag.
    if (config.she.includeProfileSnapshot) {
      final snapshot = await SheService.instance
          .buildProfileSnapshotBlock(level: config.she.profileSnapshotLevel);
      if (snapshot.isNotEmpty) parts.add(snapshot);
    }

    // ⑦' She self-cognition (self_notes from minds.db) — She-only via config flag.
    if (config.she.includeSheSelfCognition) {
      final selfCog = await SheService.instance.buildSheSelfCognitionBlock();
      if (selfCog.isNotEmpty) parts.add(selfCog);
    }

    // ⑦'' She user-cognition (impression/notes from minds.db).
    // Skipped in lightweight mode — She can query on demand.
    if (!config.lightweightMode && config.she.includeUserCognition) {
      final userCog = await SheService.instance.buildUserCognitionBlock();
      if (userCog.isNotEmpty) parts.add(userCog);
    }

    // ⑦''' Non-She: brief user profile (core fields only).
    // Non-She configs have AgentStackConfig enabled; She has AgentStackConfig.disabled.
    if (config.agent.includeUserProfile) {
      final profileBlock = await _buildAgentUserProfileBlock();
      if (profileBlock.isNotEmpty) parts.add(profileBlock);
    }

    // ⑧ First-meeting instruction — She-only via config flag.
    if (config.she.includeFirstMeeting) {
      final isFirst = await SheService.instance.isFirstMeeting();
      if (isFirst) parts.add(SheService.instance.buildFirstMeetingBlock());
    }

    // ⑧' Non-She: agent's own soul (self-cognition from minds.db).
    // Skipped in lightweight mode.
    if (!config.lightweightMode && config.agent.includeAgentSelfCognition) {
      final selfCog = await _buildAgentSelfCognitionBlock();
      if (selfCog.isNotEmpty) parts.add(selfCog);
    }

    // ⑧'' Non-She: agent's user-cognition (impression/notes from minds.db).
    // Skipped in lightweight mode.
    if (!config.lightweightMode && config.agent.includeAgentUserCognition) {
      final userCog = await _buildAgentUserCognitionBlock();
      if (userCog.isNotEmpty) parts.add(userCog);
    }

    // ⑧''' Non-She: agent's own recent memories.
    // Skipped in lightweight mode.
    if (!config.lightweightMode && config.agent.includeAgentMemory) {
      final memoriesBlock =
          await _buildAgentMemoriesBlock(config.agent.memoryLimit);
      if (memoriesBlock.isNotEmpty) parts.add(memoriesBlock);
    }

    // ⑨ Session-end — unified for all agents via SheService.buildSessionEndBlockFor().
    // She: guarded by config.she.includeSessionEnd.
    // Non-She: always injected (config.she.includeSessionEnd is false for them,
    //          but !agent.isShe ensures they still get the lighter version).
    if (config.she.includeSessionEnd || !agent.isShe) {
      parts.add(SheService.instance.buildSessionEndBlockFor(agent.id));
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

  /// Resolve the custom prompt for non-She agents: DM override takes priority.
  /// The agent's `system_prompt` is already in the description block (②),
  /// so here we only return the DM-channel override when present.
  String _resolveCustomPrompt() {
    if (dmSystemPromptOverride != null && dmSystemPromptOverride!.isNotEmpty) {
      return dmSystemPromptOverride!;
    }
    return '';
  }

  // ── Non-She context blocks ─────────────────────────────────────────────────

  /// Build the agent's self-cognition block (soul) from minds.db.
  Future<String> _buildAgentSelfCognitionBlock() async {
    final self = await CognitionService.instance.getSelfCognition(agent.id);
    if (self == null || self.soul.isEmpty) return '';

    return '''
## Your Core Purpose & Principles
${self.soul}

This grows over time. When you gain new self-awareness, call:
`shepaw context memory.write --key soul --value "(complete updated soul)"`''';
  }

  /// Build the agent's user-cognition block (impression/notes) from minds.db.
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

  /// Build the recent-memories block for non-She agents.
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
    buffer.write('\nWhen you learn new things about the user or have new observations, use `shepaw context agents.memory-write --id ${agent.id}` to record them.');
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
  /// and [SheStackConfig] (for the shepaw data-access CLI block).
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
      final isShe = agent.isShe;
      // She uses expanded mode (her CLI reference already lists tools fully).
      // Non-She agents default to cli_reference to reduce prompt size; they
      // discover the full list by calling `shepaw tools os.list` when needed.
      final useExpanded = isShe || tools.osToolsMode == 'expanded';
      final suffix = useExpanded
          ? OsToolRegistry.instance
              .systemPromptSuffixLayered(agent.enabledOsTools, tools.toolDescriptionLevel)
          : OsToolRegistry.instance
              .systemPromptCliReference(agent.enabledOsTools);
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

    // shepaw data-access CLI — She-exclusive content (_pawCliPrompt).
    // Non-She agents have this disabled via PromptStackConfig.forOtherAgent
    // (tools: ToolsStackConfig(includeShepawCli: false)) so this branch
    // only fires for She.
    if (tools.includeShepawCli) {
      final cliBlock = SheService.instance.buildShepawCliBlock(she);
      if (cliBlock.isNotEmpty) result.add(cliBlock);
    }

    return result;
  }
}
