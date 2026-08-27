import '../clis/shepaw/os/os_tool_registry.dart';
import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
import '../storage/device_identity.dart';
import '../storage/scope_card.dart';
import 'agent_memory_store_service.dart';
import 'agent_soul_service.dart';
import 'cognition_service.dart';
import 'logger_service.dart';
import 'model_registry.dart';
import 'prompt_cache.dart';
import 'she_service.dart';
import 'skill_registry.dart';
import 'ui_component_registry.dart';

export 'prompt_cache.dart' show BuiltSystemPrompt;

/// Builds the complete system prompt for any Agent — She or others — using a
/// unified, configurable layering approach.
///
/// ## Layering order (static prefix, then dynamic suffix)
///
/// Static (cache-stable — identity, tools, meta, scope, soul, custom, session-end):
/// ```
///  ①   Identity / resume / description
///  ③   Tools docs + shepaw guidance
///  ③'  Scope Card + optional DM playbooks
///  ④   She soul
///  ⑤   Custom / ephemeral
///  ⑨   Session-end
/// ```
///
/// Dynamic (per-turn — profile, roster, time last so the prefix can cache):
/// ```
///  ⑥   User-strategy / profile / cognition / first-meeting
///  ⑥'  Agents roster / external digests (She 1:1)
///  ③.6 Current time            ← always last
/// ```
///
/// The only remaining `agent.isShe` checks are in the three spots where the
/// behavior genuinely differs regardless of config:
///   • `_buildIdentityBlock` — She's name lives in her core-identity block (②)
///   • `_buildDescriptionBlock` — She → core identity; non-She → system_prompt
///   • Step ⑤ (custom prompt) — She seeds soul; non-She injects as custom settings
///
/// Everything else is driven by [PromptStackConfig] flags.  Non-She agents use
/// [PromptStackConfig.forOtherAgent] which sets [SheStackConfig.disabled], so
/// She-exclusive config checks evaluate to false automatically. She's
/// data-access CLI copy is additionally gated by `agent.isShe`.
class AgentPromptBuilder {
  final RemoteAgent agent;

  /// DM-channel system-prompt override.  When non-null and non-empty, this
  /// replaces the agent's default `system_prompt` metadata value.
  final String? dmSystemPromptOverride;

  /// Ephemeral room/group context (e.g. [GroupPromptBuilder] output). Injected
  /// as a temporary room block for She — never used as soul seed. When set,
  /// DM-only sections (workflow playbook) are skipped.
  final String? ephemeralContext;

  /// Optional prompt-stack override (e.g. peer-inbound stripped config).
  final PromptStackConfig? configOverride;

  AgentPromptBuilder({
    required this.agent,
    this.dmSystemPromptOverride,
    this.ephemeralContext,
    this.configOverride,
  });

  /// Build the complete system prompt according to the agent's [PromptStackConfig].
  Future<String> buildSystemPrompt() async => (await build()).full;

  /// Layered system prompt: cache-stable prefix + per-turn suffix (time last).
  Future<BuiltSystemPrompt> build() async {
    final config = configOverride ?? agent.promptStackConfig;

    // In lightweight mode we force tool descriptions to 'summary' and skip
    // heavy context blocks (memories, cognitions) that the agent can retrieve
    // on demand via `shepaw system tools-detail` or similar commands.
    final effectiveTools = config.lightweightMode
        ? config.tools.copyWith(toolDescriptionLevel: 'summary')
        : config.tools;
    final staticParts = <String>[];
    final dynamicParts = <String>[];

    // Prefetch She's DB-backed prompt inputs in one parallel batch — avoids
    // the duplicate serial reads (profile ×3, soul ×2) across block builders.
    final sheData =
        agent.isShe ? await SheService.instance.prefetchPromptData() : null;

    // ① Identity — always include the agent's name so the model can recognise
    //   when quoted messages refer to itself.
    if (config.includeIdentity) {
      final id = _buildIdentityBlock();
      if (id.isNotEmpty) staticParts.add(id);
    }

    // ①.5 Resume — non-She / non-peer agents see their own resume (bio) and
    //   are told how to update it during chat via agents.resume-set.
    if (!agent.isShe && !agent.isPeerAgent && config.includeIdentity) {
      final resume = await _buildResumeBlock();
      if (resume.isNotEmpty) staticParts.add(resume);
    }

    // ② Description
    if (config.includeDescription) {
      if (agent.isShe || config.embedSoulText) {
        final desc = await _buildDescriptionBlock();
        if (desc.isNotEmpty) staticParts.add(desc);
      }
      // Non-She uri_only: Soul 不内嵌，靠 Scope Card soul_uri + store read
    }

    // ③ Tools documentation
    staticParts.addAll(_buildToolsBlocks(effectiveTools, config.she));

    // ③' Shepaw guidance — unified for She and non-She.
    // For She:     full meta-cognition block (config.she.includeMetaCognition).
    // For non-She: permission-scoped meta CLI block (effectiveTools.includeShepawMetaCli).
    // Content is produced by SheService.buildShepawGuidanceBlock() which is
    // aware of each agent's actual CLI permissions.
    final wantsShepawGuidance = agent.isShe
        ? config.she.includeMetaCognition
        : effectiveTools.includeShepawMetaCli;
    if (wantsShepawGuidance) {
      staticParts.add(await SheService.buildShepawGuidanceBlock(agent));
    }

    // Ephemeral room/group context — also gates Scope Card / DM playbooks.
    final hasEphemeral =
        ephemeralContext != null && ephemeralContext!.trim().isNotEmpty;

    // Scope Card（stable）— 群 ephemeral 由 GroupPromptBuilder 注入，此处跳过。
    if (!hasEphemeral) {
      final scope = await _buildStableScopeCard(config);
      if (scope.isNotEmpty) staticParts.add(scope);
    }

    // ③'' DM workflow / group playbooks — opt-in; skipped in ephemeral rooms.
    if (agent.isShe &&
        config.she.includeDmPlaybooks &&
        !hasEphemeral) {
      staticParts.add(SheService.buildDmWorkflowPlaybookBlock());
      staticParts.add(SheService.buildDmGroupManagementPlaybookBlock());
      staticParts.add(SheService.buildDmDispatchPlaybookBlock());
    }

    // ④ She memory context (soul) — guarded by SheStackConfig flag.
    // Non-She agents have SheStackConfig.disabled so this is always false for them.
    if (config.she.includeSheMemory) {
      final mem = await SheService.instance.buildMemoryContextBlock(data: sheData);
      if (mem.isNotEmpty) staticParts.add(mem);
    }

    // ⑤ Custom / DM / ephemeral context
    // For She: metadata system_prompt is soul seed only (never shown as custom
    // settings). DM override → Master's Custom Settings. Ephemeral room/group
    // context → Current Room Context (not soul-seeded).
    if (agent.isShe) {
      final userSetPrompt = agent.metadata['system_prompt'] as String? ?? '';
      if (userSetPrompt.isNotEmpty) {
        await SheService.instance.seedSoulFromUserPrompt(userSetPrompt);
      }
      if (hasEphemeral) {
        staticParts.add(
            SheService.wrapEphemeralContextPrompt(ephemeralContext!.trim()));
      } else if (dmSystemPromptOverride != null &&
          dmSystemPromptOverride!.isNotEmpty) {
        staticParts.add(SheService.wrapCustomPrompt(dmSystemPromptOverride!));
      }
    } else if (hasEphemeral) {
      staticParts.add(
          SheService.wrapEphemeralContextPrompt(ephemeralContext!.trim()));
    } else if (config.includeCustomPrompt) {
      final custom = _resolveCustomPrompt();
      if (custom.isNotEmpty) {
        staticParts.add(SheService.wrapCustomPrompt(custom));
      }
    }

    // ⑨ Session-end — in the static prefix so it can cache. She: guarded by
    // config.she.includeSessionEnd; ephemeral rooms use a lighter variant.
    // Non-She: guarded by config.agent.includeSessionEnd (off by default).
    if (hasEphemeral && agent.isShe) {
      staticParts.add(SheService.buildEphemeralSessionEndBlock());
    } else if (agent.isShe
        ? config.she.includeSessionEnd
        : config.agent.includeSessionEnd) {
      staticParts.add(SheService.instance.buildSessionEndBlockFor(agent.id));
    }

    // ── Dynamic suffix (profile / roster / time) ─────────────────────────

    // ⑥ User-understanding strategy — She-only via config flag.
    if (config.she.includeUserStrategy) {
      final strategy =
          await SheService.instance.buildUserStrategyBlock(data: sheData);
      if (strategy.isNotEmpty) dynamicParts.add(strategy);
    }

    // ⑦ User-profile snapshot — She-only via config flag.
    if (config.she.includeProfileSnapshot) {
      final snapshot = await SheService.instance.buildProfileSnapshotBlock(
          level: config.she.profileSnapshotLevel, data: sheData);
      if (snapshot.isNotEmpty) dynamicParts.add(snapshot);
    }

    // ⑦' She self-cognition (self_notes) — She-only via config flag.
    if (config.she.includeSheSelfCognition) {
      final selfCog =
          await SheService.instance.buildSheSelfCognitionBlock(data: sheData);
      if (selfCog.isNotEmpty) dynamicParts.add(selfCog);
    }

    // ⑦'' She user-cognition (impression/notes from minds.db).
    // Skipped in lightweight mode — She can query on demand.
    if (!config.lightweightMode && config.she.includeUserCognition) {
      final userCog =
          await SheService.instance.buildUserCognitionBlock(data: sheData);
      if (userCog.isNotEmpty) dynamicParts.add(userCog);
    }

    // ⑦''' Non-She: brief user profile (core fields only).
    if (config.agent.includeUserProfile) {
      final profileBlock = await _buildAgentUserProfileBlock();
      if (profileBlock.isNotEmpty) dynamicParts.add(profileBlock);
    }

    // ⑧ First-meeting instruction — She-only via config flag.
    if (config.she.includeFirstMeeting) {
      final isFirst = await SheService.instance.isFirstMeeting(data: sheData);
      if (isFirst) {
        dynamicParts.add(SheService.instance.buildFirstMeetingBlock());
      }
    }

    // ⑧' Non-She: agent's own soul (self-cognition from minds.db).
    if (!config.lightweightMode && config.agent.includeAgentSelfCognition) {
      final selfCog = await _buildAgentSelfCognitionBlock();
      if (selfCog.isNotEmpty) dynamicParts.add(selfCog);
    }

    // ⑧'' Non-She: agent's user-cognition (impression/notes from minds.db).
    if (!config.lightweightMode && config.agent.includeAgentUserCognition) {
      final userCog = await _buildAgentUserCognitionBlock();
      if (userCog.isNotEmpty) dynamicParts.add(userCog);
    }

    // ⑧''' Non-She: agent's own recent memories.
    if (!agent.isShe && config.embedMemoryEntries) {
      final memoriesBlock =
          await _buildAgentMemoriesBlock(config.agent.memoryLimit);
      if (memoriesBlock.isNotEmpty) dynamicParts.add(memoriesBlock);
    }

    // She 1:1 roster + paired-device digests (skip in ephemeral/group).
    if (agent.isShe && !hasEphemeral) {
      if (config.she.includeAgentsRoster) {
        final roster = await SheService.instance.buildAgentsOverviewBlock();
        if (roster.isNotEmpty) dynamicParts.add(roster);
      }
      if (config.she.includeExternalDigests) {
        final digests = await SheService.instance.buildExternalMemoriesBlock();
        if (digests.isNotEmpty) dynamicParts.add(digests);
      }
    }

    // ③.6 Current time — always last so a clock tick cannot bust the prefix cache.
    dynamicParts.add(SheService.instance.buildCurrentTimeBlock());

    final built = BuiltSystemPrompt(
      staticPrefix: _joinBlocks(staticParts),
      dynamicSuffix: _joinBlocks(dynamicParts),
    );
    if (built.full.length > 12000) {
      LoggerService().warning(
        'System prompt for agent=${agent.id} is ${built.full.length} chars '
        '(static=${built.staticPrefix.length}, dynamic=${built.dynamicSuffix.length})',
        tag: 'PromptBuilder',
      );
    }
    return built;
  }

  static String _joinBlocks(List<String> parts) =>
      parts.where((s) => s.trim().isNotEmpty).join('\n\n');

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Stable Scope Card for system prompt（不含本轮 URI）。
  Future<String> _buildStableScopeCard(PromptStackConfig config) async {
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final soulInjected = !agent.isShe &&
              config.includeDescription &&
              config.embedSoulText
          ? ScopeInjectLevel.full
          : ScopeInjectLevel.none;
      final memInjected = !agent.isShe && config.embedMemoryEntries
          ? ScopeInjectLevel.topN
          : ScopeInjectLevel.none;
      final injected = ScopeCardInjected(
        soul: soulInjected,
        memoryEntries: memInjected,
      );
      if (agent.isPeerAgent) {
        final peerId = agent.sourcePeerId?.trim();
        if (peerId != null && peerId.isNotEmpty) {
          return ScopeCard.forPeerAgent(
            agentId: agent.id,
            deviceId: deviceId,
            peerClientId: peerId,
            injected: injected,
          ).toStableMarkdown();
        }
      }
      return ScopeCard.forAgentDm(
        agentId: agent.id,
        deviceId: deviceId,
        injected: injected,
        writeMemory: !agent.isPeerAgent,
      ).toStableMarkdown();
    } catch (e) {
      LoggerService().warning(
        'Scope Card skipped: $e',
        tag: 'PromptBuilder',
      );
      return '';
    }
  }

  /// A one-line identity declaration so the model knows its own name.
  /// This is intentionally minimal — She's full core identity comes in ②.
  String _buildIdentityBlock() {
    if (agent.isShe) return ''; // She's name is in the core identity block (②)
    return 'Your name is ${agent.name}.';
  }

  /// The agent's own resume (bio) — what others see about it.
  /// Store read/write details live in the Scope Card; do not duplicate them here.
  Future<String> _buildResumeBlock() async {
    final bio = agent.bio?.trim() ?? '';
    final resumeText = bio.isNotEmpty ? bio : '（未设置 / Not set）';
    return [
      '## Your Resume',
      resumeText,
      '',
      'Others see this as your resume. If your capabilities or role change, update it with:',
      '`shepaw context agents.resume-set --id ${agent.id} --text "(your updated resume)"`',
    ].join('\n');
  }

  /// Prompt-view cap for non-She `soul.md` (same budget as She's soul block).
  static const int soulPromptMaxChars = 4000;

  /// Keep the tail of a soul so a long file cannot bloat the static prefix.
  static String clipSoulForPrompt(String soul) {
    final trimmed = soul.trim();
    if (trimmed.length <= soulPromptMaxChars) return trimmed;
    LoggerService().warning(
      'Agent soul is ${trimmed.length} chars (>$soulPromptMaxChars) — '
      'truncating tail for prompt injection',
      tag: 'PromptBuilder',
    );
    return SheService.truncateTail(trimmed, soulPromptMaxChars);
  }

  /// The main description / persona block.
  Future<String> _buildDescriptionBlock() async {
    if (agent.isShe) {
      return SheService.instance.buildCoreIdentityBlock();
    }
    try {
      final soul = await AgentSoulService.instance.getSoul(agent);
      if (soul.trim().isNotEmpty) return clipSoulForPrompt(soul);
    } catch (_) {
      // Store / peer unavailable (e.g. unit tests).
    }
    return '';
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
    // When soul.md is authoritative it is already injected in block ②.
    try {
      final fileSoul = await AgentSoulService.instance.getSoul(agent);
      if (fileSoul.trim().isNotEmpty) return '';
    } catch (_) {}

    final self = await CognitionService.instance.getSelfCognition(agent.id);
    if (self == null || self.soul.isEmpty) return '';

    return '''
## Your Core Purpose & Principles
${clipSoulForPrompt(self.soul)}

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
    final memories = await AgentMemoryStoreService.forAgent(agent.id)
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
    buffer.write(
      agent.isPeerAgent
          ? '\nPeer session: do not call memory-write; memory is host-managed.'
          : '\nWhen you learn new things about the user or have new observations, '
              'use `shepaw context agents.memory-write --id ${agent.id}` to record them.',
    );
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
      // Names only in the system prompt — full skill description already lives
      // in the tool schema; duplicating it here busts both caches when it changes.
      final suffix = SkillRegistry.instance
          .systemPromptSuffixLayered(agent.enabledSkills, 'names_only');
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

    // shepaw data-access CLI copy — She-exclusive (_pawCliPrompt).
    // Non-She agents still get the shepaw *tool* when includeShepawCli is true,
    // but their prompt docs come from buildShepawGuidanceBlock (meta CLI).
    // When meta-cognition is on it already carries the command guidance, so the
    // full data-access copy is skipped to avoid ~60% duplication (P2-2).
    if (agent.isShe && tools.includeShepawCli && !she.includeMetaCognition) {
      final cliBlock = SheService.instance.buildShepawCliBlock(she);
      if (cliBlock.isNotEmpty) result.add(cliBlock);
    }

    return result;
  }
}
