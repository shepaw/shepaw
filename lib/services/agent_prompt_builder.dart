import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
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
///  ④  She memory context      ← soul  [She-only, optional]
///  ③.5 Current time           ← injected by SheService inside legacy path
///  ⑤  Custom prompt           ← DM override or user-set system_prompt
///  ⑥  User-strategy block     ← [She-only, optional]
///  ⑦  Profile snapshot        ← [She-only, optional]
///  ⑧  First-meeting block     ← [She-only, conditional]
///  ⑨  Session-end block       ← [She-only, optional]
/// ```
///
/// She-specific sections are delegated entirely to [SheService] so that the
/// soul / memory / profile logic stays in one place.
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
    final toolParts = _buildToolsBlocks(config.tools, config.she);
    parts.addAll(toolParts);

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
      final snapshot = await SheService.instance.buildProfileSnapshotBlock();
      if (snapshot.isNotEmpty) parts.add(snapshot);
    }

    // ⑧ She-only: first-meeting instruction (conditional)
    if (agent.isShe && config.she.includeFirstMeeting) {
      final isFirst = await SheService.instance.isFirstMeeting();
      if (isFirst) parts.add(SheService.instance.buildFirstMeetingBlock());
    }

    // ⑨ She-only: session-end write instructions
    if (agent.isShe && config.she.includeSessionEnd) {
      parts.add(SheService.instance.buildSessionEndBlock());
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

  /// Build all tool-documentation sections according to [ToolsStackConfig]
  /// and [SheStackConfig] (for the shepaw CLI).
  List<String> _buildToolsBlocks(
    ToolsStackConfig tools,
    SheStackConfig she,
  ) {
    final result = <String>[];

    if (tools.includeUI) {
      final suffix = UIComponentRegistry.instance.systemPromptSuffix;
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeOsTools && agent.enabledOsTools.isNotEmpty) {
      final suffix =
          OsToolRegistry.instance.systemPromptSuffix(agent.enabledOsTools);
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeSkills && agent.enabledSkills.isNotEmpty) {
      final suffix =
          SkillRegistry.instance.systemPromptSuffix(agent.enabledSkills);
      if (suffix.isNotEmpty) result.add(suffix);
    }

    if (tools.includeToolModels && agent.enabledToolModels.isNotEmpty) {
      final suffix = ModelRegistry.instance.systemPromptSuffix(
        agent.enabledToolModels,
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
}
