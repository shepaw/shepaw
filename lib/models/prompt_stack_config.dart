/// Configuration data classes that control which sections are included
/// in a system prompt for any Agent (She or others).
///
/// All configs are JSON-serializable and persisted inside
/// `RemoteAgent.metadata['prompt_stack_config']`.
///
/// She-specific sections are grouped under [SheStackConfig] and are
/// silently ignored when the agent is not She.

// ── Tools layer ───────────────────────────────────────────────────────────────

/// Controls which tool-documentation sections are appended to the system prompt.
class ToolsStackConfig {
  /// UI component tools (action_confirmation, single_select, …).
  /// Recommended: always enabled.
  final bool includeUI;

  /// OS-level tools (file operations, terminal, …).
  final bool includeOsTools;

  /// User-defined skill tools.
  final bool includeSkills;

  /// Tool-model tools (routed to specialised models).
  final bool includeToolModels;

  /// shepaw CLI tool — **She-exclusive**.
  /// Ignored for non-She agents even when set to true.
  final bool includeShepawCli;

  const ToolsStackConfig({
    this.includeUI = true,
    this.includeOsTools = true,
    this.includeSkills = true,
    this.includeToolModels = true,
    this.includeShepawCli = true,
  });

  /// At least one tool category is enabled.
  bool get any =>
      includeUI ||
      includeOsTools ||
      includeSkills ||
      includeToolModels ||
      includeShepawCli;

  static const ToolsStackConfig all = ToolsStackConfig();
  static const ToolsStackConfig noTools = ToolsStackConfig(
    includeUI: false,
    includeOsTools: false,
    includeSkills: false,
    includeToolModels: false,
    includeShepawCli: false,
  );

  factory ToolsStackConfig.fromJson(Map<String, dynamic> json) =>
      ToolsStackConfig(
        includeUI: json['include_ui'] as bool? ?? true,
        includeOsTools: json['include_os_tools'] as bool? ?? true,
        includeSkills: json['include_skills'] as bool? ?? true,
        includeToolModels: json['include_tool_models'] as bool? ?? true,
        includeShepawCli: json['include_shepaw_cli'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'include_ui': includeUI,
        'include_os_tools': includeOsTools,
        'include_skills': includeSkills,
        'include_tool_models': includeToolModels,
        'include_shepaw_cli': includeShepawCli,
      };

  ToolsStackConfig copyWith({
    bool? includeUI,
    bool? includeOsTools,
    bool? includeSkills,
    bool? includeToolModels,
    bool? includeShepawCli,
  }) =>
      ToolsStackConfig(
        includeUI: includeUI ?? this.includeUI,
        includeOsTools: includeOsTools ?? this.includeOsTools,
        includeSkills: includeSkills ?? this.includeSkills,
        includeToolModels: includeToolModels ?? this.includeToolModels,
        includeShepawCli: includeShepawCli ?? this.includeShepawCli,
      );
}

// ── She-exclusive layer ───────────────────────────────────────────────────────

/// Controls She-exclusive prompt sections and which shepaw sub-commands
/// are documented in the CLI block.
///
/// Only evaluated when the agent is She (`RemoteAgent.isShe == true`).
class SheStackConfig {
  // ── Context injection ──────────────────────────────────────────────

  /// Inject soul + user_info + heartbeat memory into the prompt.
  final bool includeSheMemory;

  /// Inject the "proactive user-understanding strategy" section.
  final bool includeUserStrategy;

  /// Inject the layered user-profile snapshot (basic info, extended, impression,
  /// recent activity, last conversation).
  final bool includeProfileSnapshot;

  /// Inject the "first meeting" instruction (only fires when profile is empty).
  final bool includeFirstMeeting;

  /// Append the session-end write instructions.
  final bool includeSessionEnd;

  // ── shepaw CLI command toggles ─────────────────────────────────────
  // Disabling a command removes its row from the CLI reference table so
  // She won't try to call it.

  /// `shepaw profile query / write`
  final bool enableProfileCommand;

  /// `shepaw memory query / write / append`
  final bool enableMemoryCommand;

  /// `shepaw agents chat`
  final bool enableAgentChatCommand;

  /// `shepaw agents list / channels / messages` and `shepaw messages query`
  final bool enableMessagesCommand;

  const SheStackConfig({
    this.includeSheMemory = true,
    this.includeUserStrategy = true,
    this.includeProfileSnapshot = true,
    this.includeFirstMeeting = true,
    this.includeSessionEnd = true,
    this.enableProfileCommand = true,
    this.enableMemoryCommand = true,
    this.enableAgentChatCommand = true,
    this.enableMessagesCommand = true,
  });

  /// All She features disabled — essentially treats She like a plain agent.
  static const SheStackConfig disabled = SheStackConfig(
    includeSheMemory: false,
    includeUserStrategy: false,
    includeProfileSnapshot: false,
    includeFirstMeeting: false,
    includeSessionEnd: false,
    enableProfileCommand: false,
    enableMemoryCommand: false,
    enableAgentChatCommand: false,
    enableMessagesCommand: false,
  );

  factory SheStackConfig.fromJson(Map<String, dynamic> json) => SheStackConfig(
        includeSheMemory: json['include_she_memory'] as bool? ?? true,
        includeUserStrategy: json['include_user_strategy'] as bool? ?? true,
        includeProfileSnapshot:
            json['include_profile_snapshot'] as bool? ?? true,
        includeFirstMeeting: json['include_first_meeting'] as bool? ?? true,
        includeSessionEnd: json['include_session_end'] as bool? ?? true,
        enableProfileCommand: json['enable_profile_command'] as bool? ?? true,
        enableMemoryCommand: json['enable_memory_command'] as bool? ?? true,
        enableAgentChatCommand:
            json['enable_agent_chat_command'] as bool? ?? true,
        enableMessagesCommand:
            json['enable_messages_command'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'include_she_memory': includeSheMemory,
        'include_user_strategy': includeUserStrategy,
        'include_profile_snapshot': includeProfileSnapshot,
        'include_first_meeting': includeFirstMeeting,
        'include_session_end': includeSessionEnd,
        'enable_profile_command': enableProfileCommand,
        'enable_memory_command': enableMemoryCommand,
        'enable_agent_chat_command': enableAgentChatCommand,
        'enable_messages_command': enableMessagesCommand,
      };

  SheStackConfig copyWith({
    bool? includeSheMemory,
    bool? includeUserStrategy,
    bool? includeProfileSnapshot,
    bool? includeFirstMeeting,
    bool? includeSessionEnd,
    bool? enableProfileCommand,
    bool? enableMemoryCommand,
    bool? enableAgentChatCommand,
    bool? enableMessagesCommand,
  }) =>
      SheStackConfig(
        includeSheMemory: includeSheMemory ?? this.includeSheMemory,
        includeUserStrategy: includeUserStrategy ?? this.includeUserStrategy,
        includeProfileSnapshot:
            includeProfileSnapshot ?? this.includeProfileSnapshot,
        includeFirstMeeting: includeFirstMeeting ?? this.includeFirstMeeting,
        includeSessionEnd: includeSessionEnd ?? this.includeSessionEnd,
        enableProfileCommand:
            enableProfileCommand ?? this.enableProfileCommand,
        enableMemoryCommand: enableMemoryCommand ?? this.enableMemoryCommand,
        enableAgentChatCommand:
            enableAgentChatCommand ?? this.enableAgentChatCommand,
        enableMessagesCommand:
            enableMessagesCommand ?? this.enableMessagesCommand,
      );
}

// ── Top-level config ──────────────────────────────────────────────────────────

/// Complete prompt-stack configuration for a single Agent.
///
/// Persisted as `RemoteAgent.metadata['prompt_stack_config']`.
///
/// Default factory constructors:
/// - [PromptStackConfig.forShe] — all sections enabled
/// - [PromptStackConfig.forOtherAgent] — She sections disabled
class PromptStackConfig {
  /// Prepend a short identity block (agent name) so the model can recognise
  /// when quoted messages refer to itself.
  final bool includeIdentity;

  /// Include the agent's description block.
  /// She → core-identity prompt; others → `metadata['system_prompt']`.
  final bool includeDescription;

  /// Append the DM-channel / user-supplied custom prompt.
  final bool includeCustomPrompt;

  /// Tool documentation sections.
  final ToolsStackConfig tools;

  /// She-exclusive sections. Ignored when `isShe == false`.
  final SheStackConfig she;

  const PromptStackConfig({
    this.includeIdentity = true,
    this.includeDescription = true,
    this.includeCustomPrompt = true,
    this.tools = const ToolsStackConfig(),
    this.she = const SheStackConfig(),
  });

  /// Full configuration for She — all sections active.
  static const PromptStackConfig forShe = PromptStackConfig();

  /// Standard configuration for non-She agents — She sections silently off.
  static const PromptStackConfig forOtherAgent = PromptStackConfig(
    she: SheStackConfig.disabled,
  );

  factory PromptStackConfig.fromJson(Map<String, dynamic> json) =>
      PromptStackConfig(
        includeIdentity: json['include_identity'] as bool? ?? true,
        includeDescription: json['include_description'] as bool? ?? true,
        includeCustomPrompt: json['include_custom_prompt'] as bool? ?? true,
        tools: json['tools'] is Map<String, dynamic>
            ? ToolsStackConfig.fromJson(
                json['tools'] as Map<String, dynamic>)
            : const ToolsStackConfig(),
        she: json['she'] is Map<String, dynamic>
            ? SheStackConfig.fromJson(json['she'] as Map<String, dynamic>)
            : const SheStackConfig(),
      );

  Map<String, dynamic> toJson() => {
        'include_identity': includeIdentity,
        'include_description': includeDescription,
        'include_custom_prompt': includeCustomPrompt,
        'tools': tools.toJson(),
        'she': she.toJson(),
      };

  PromptStackConfig copyWith({
    bool? includeIdentity,
    bool? includeDescription,
    bool? includeCustomPrompt,
    ToolsStackConfig? tools,
    SheStackConfig? she,
  }) =>
      PromptStackConfig(
        includeIdentity: includeIdentity ?? this.includeIdentity,
        includeDescription: includeDescription ?? this.includeDescription,
        includeCustomPrompt: includeCustomPrompt ?? this.includeCustomPrompt,
        tools: tools ?? this.tools,
        she: she ?? this.she,
      );
}
