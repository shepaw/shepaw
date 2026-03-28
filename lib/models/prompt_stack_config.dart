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

// ── Non-She Agent layer ───────────────────────────────────────────────────────

/// Controls context-injection sections that apply to **all non-She agents**.
///
/// These sections are silently ignored when the agent is She (`isShe == true`).
class AgentStackConfig {
  /// Inject a condensed user-profile block (core fields only: name, age,
  /// gender, occupation, city). Omitted when all core fields are empty.
  final bool includeUserProfile;

  /// Inject the agent's own recent memories (sorted by `memory_time` desc).
  final bool includeAgentMemory;

  /// Inject the agent's self-cognition (soul) from minds.db.
  final bool includeAgentSelfCognition;

  /// Inject the agent's user-cognition (impression/notes) from minds.db.
  final bool includeAgentUserCognition;

  /// Maximum number of recent memories to inject.
  final int memoryLimit;

  const AgentStackConfig({
    this.includeUserProfile = true,
    this.includeAgentMemory = true,
    this.includeAgentSelfCognition = true,
    this.includeAgentUserCognition = true,
    this.memoryLimit = 10,
  });

  /// All agent context sections disabled.
  static const AgentStackConfig disabled = AgentStackConfig(
    includeUserProfile: false,
    includeAgentMemory: false,
    includeAgentSelfCognition: false,
    includeAgentUserCognition: false,
  );

  factory AgentStackConfig.fromJson(Map<String, dynamic> json) =>
      AgentStackConfig(
        includeUserProfile: json['include_user_profile'] as bool? ?? true,
        includeAgentMemory: json['include_agent_memory'] as bool? ?? true,
        includeAgentSelfCognition: json['include_agent_self_cognition'] as bool? ?? true,
        includeAgentUserCognition: json['include_agent_user_cognition'] as bool? ?? true,
        memoryLimit: json['memory_limit'] as int? ?? 10,
      );

  Map<String, dynamic> toJson() => {
        'include_user_profile': includeUserProfile,
        'include_agent_memory': includeAgentMemory,
        'include_agent_self_cognition': includeAgentSelfCognition,
        'include_agent_user_cognition': includeAgentUserCognition,
        'memory_limit': memoryLimit,
      };

  AgentStackConfig copyWith({
    bool? includeUserProfile,
    bool? includeAgentMemory,
    bool? includeAgentSelfCognition,
    bool? includeAgentUserCognition,
    int? memoryLimit,
  }) =>
      AgentStackConfig(
        includeUserProfile: includeUserProfile ?? this.includeUserProfile,
        includeAgentMemory: includeAgentMemory ?? this.includeAgentMemory,
        includeAgentSelfCognition: includeAgentSelfCognition ?? this.includeAgentSelfCognition,
        includeAgentUserCognition: includeAgentUserCognition ?? this.includeAgentUserCognition,
        memoryLimit: memoryLimit ?? this.memoryLimit,
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

  /// Inject She's self-cognition (self_notes and updated soul from minds.db).
  final bool includeSheSelfCognition;

  /// Inject She's user-cognition (user_impression and user_notes from minds.db).
  final bool includeUserCognition;

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
    this.includeSheSelfCognition = true,
    this.includeUserCognition = true,
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
    includeSheSelfCognition: false,
    includeUserCognition: false,
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
        includeSheSelfCognition: json['include_she_self_cognition'] as bool? ?? true,
        includeUserCognition: json['include_user_cognition'] as bool? ?? true,
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
        'include_she_self_cognition': includeSheSelfCognition,
        'include_user_cognition': includeUserCognition,
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
    bool? includeSheSelfCognition,
    bool? includeUserCognition,
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
        includeSheSelfCognition: includeSheSelfCognition ?? this.includeSheSelfCognition,
        includeUserCognition: includeUserCognition ?? this.includeUserCognition,
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

  /// Non-She agent context sections. Ignored when `isShe == true`.
  final AgentStackConfig agent;

  const PromptStackConfig({
    this.includeIdentity = true,
    this.includeDescription = true,
    this.includeCustomPrompt = true,
    this.tools = const ToolsStackConfig(),
    this.she = const SheStackConfig(),
    this.agent = const AgentStackConfig(),
  });

  /// Full configuration for She — all sections active.
  static const PromptStackConfig forShe = PromptStackConfig(
    agent: AgentStackConfig.disabled,
  );

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
        agent: json['agent'] is Map<String, dynamic>
            ? AgentStackConfig.fromJson(json['agent'] as Map<String, dynamic>)
            : const AgentStackConfig(),
      );

  Map<String, dynamic> toJson() => {
        'include_identity': includeIdentity,
        'include_description': includeDescription,
        'include_custom_prompt': includeCustomPrompt,
        'tools': tools.toJson(),
        'she': she.toJson(),
        'agent': agent.toJson(),
      };

  PromptStackConfig copyWith({
    bool? includeIdentity,
    bool? includeDescription,
    bool? includeCustomPrompt,
    ToolsStackConfig? tools,
    SheStackConfig? she,
    AgentStackConfig? agent,
  }) =>
      PromptStackConfig(
        includeIdentity: includeIdentity ?? this.includeIdentity,
        includeDescription: includeDescription ?? this.includeDescription,
        includeCustomPrompt: includeCustomPrompt ?? this.includeCustomPrompt,
        tools: tools ?? this.tools,
        she: she ?? this.she,
        agent: agent ?? this.agent,
      );
}
