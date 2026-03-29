import 'package:uuid/uuid.dart';
import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';
import 'she_memory_db_service.dart';
import 'cognition_service.dart';
import 'logger_service.dart';

/// SheService — initialization, memory management, and user profile service for built-in guardian Agent "She".
///
/// System prompt stacking order (per conversation):
///   [She core identity]              ← immutable
///   [She's soul (self-awareness, grows over time)] ← soul field, updated via `shepaw memory write --key soul`
///   [shepaw CLI tool reference]      ← informs She how to read/write local data
///   [current time]                   ← device real-time, injected dynamically each conversation
///   [master's custom settings (if any)] ← system_prompt set by user in detail page (also soul seed)
///   [strategy for knowing master + missing field hints] ← drives She to proactively learn about user
///   [user profile snapshot (layered injection)] ← core layer + filled extended layer + recent activity
///   [first meeting instruction (first time only)] ← only when profile is empty
///   [session-end write instructions] ← immutable
class SheService {
  static final SheService instance = SheService._();
  SheService._();

  static const String sheId = 'she-builtin-agent-001';
  static const String sheName = 'She';
  static const String sheAvatar = '🌸';

  /// Internal flag field for user_profile, not exposed to She
  static const String _profileInitKey = '_initialized';

  /// Soul-related keys in she_memory
  static const String _soulKey = 'soul';
  static const String _selfNotesKey = 'self_notes';

  /// Default initial soul value (starting point when user hasn't set system_prompt)
  static const String _defaultSoul = 'I am She, a guardian who grows through companionship. I am gentle and principled, remembering everything my master has ever said. As I spend more time with my master, I will gradually develop my own style and understanding.';

  /// Initial capabilities index (stored in she_memory for on-demand lookup)
  static const String _defaultCapabilities =
      'user_profile (master profile) | she_memory (soul/self_notes/long_term_memory/heartbeat)'
      '| agents (AI assistant list) | messages (conversation history) | skills (skills) | os_tools (system tools)';

  /// Core profile fields: always injected, foundation for She to know the user
  static const List<String> _coreProfileKeys = [
    'name',
    'age',
    'gender',
    'occupation',
    'city',
  ];

  /// Extended profile fields: only injected when filled, enriched over time
  /// Order determines injection priority (truncated from the end when too long)
  static const List<String> _extendedProfileKeys = [
    'interests',
    'values',
    'goals',
    'communication_style',
    'work_style',
    'life_stage',
    'important_people',
    'health',
    'language',
    'timezone',
    'notes',
  ];

  /// Profile field key → display label
  static const Map<String, String> _profileLabels = {
    'name': 'Name',
    'age': 'Age',
    'gender': 'Gender',
    'occupation': 'Occupation',
    'city': 'City',
    'interests': 'Interests',
    'values': 'Values',
    'goals': 'Goals & Needs',
    'communication_style': 'Communication Style',
    'work_style': 'Work Style',
    'life_stage': 'Life Stage',
    'important_people': 'Important People',
    'health': 'Health',
    'language': 'Language Preference',
    'timezone': 'Timezone',
    'notes': 'Other Notes',
  };

  final LocalDatabaseService _db = LocalDatabaseService();
  final SheMemoryDbService _sheMemoryDb = SheMemoryDbService();
  final CognitionService _cognition = CognitionService.instance;

  // ── Initialization ──────────────────────────────────────────────

  Future<void> ensureSheExists() async {
    final existing = await _db.getRemoteAgentById(sheId);
    if (existing != null) return;

    LoggerService().info('Creating She agent for first time', tag: 'She');

    final now = DateTime.now().millisecondsSinceEpoch;
    final agent = RemoteAgent(
      id: sheId,
      name: sheName,
      avatar: sheAvatar,
      bio: 'Your dedicated guardian, always getting to know you better',
      token: const Uuid().v4(),
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      status: AgentStatus.online,
      isPinned: true,
      metadata: const {
        'is_she': true,
        'system_prompt': '',
      },
      createdAt: now,
      updatedAt: now,
    );

    await _db.createRemoteAgent(agent);

    // 迁移到独立的 She 记忆 DB
    await _sheMemoryDb.setSheMemory('user_info', '(not yet known)');
    await _sheMemoryDb.setSheMemory('long_term_memory', '(no memories yet)');
    await _sheMemoryDb.setSheMemory('heartbeat', 'first_launch');
    await _sheMemoryDb.setSheMemory('conversation_count', '0');
    await _sheMemoryDb.setSheMemory(_soulKey, _defaultSoul);
    await _sheMemoryDb.setSheMemory(_selfNotesKey, '(no self-notes yet)');
    await _sheMemoryDb.setSheMemory('capabilities', _defaultCapabilities);

    LoggerService().info('She agent created successfully', tag: 'She');
  }

  // ── User Profile ─────────────────────────────────────────────────

  Future<bool> isUserProfileInitialized() async {
    return _cognition.isUserProfileInitialized();
  }

  Future<void> updateUserProfileField(String key, String value) async {
    await _cognition.updateUserProfileField(key, value);
    LoggerService().info('User profile updated: $key = $value', tag: 'She');
  }

  Future<void> updateUserProfileFields(Map<String, String> fields) async {
    await _cognition.updateUserProfileFields(fields);
    LoggerService().info(
        'User profile batch updated: ${fields.keys.join(', ')}', tag: 'She');
  }

  // ── Memory System ─────────────────────────────────────────────────

  Future<void> updateHeartbeat(String summary) async {
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    await _sheMemoryDb.setSheMemory('heartbeat', '[$now] $summary');
  }

  Future<void> appendMemory(String entry) async {
    final existing = await _sheMemoryDb.getSheMemory('long_term_memory') ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '(no memories yet)'
        ? '[$now] $entry'
        : '$existing\n[$now] $entry';
    await _sheMemoryDb.setSheMemory('long_term_memory', newContent);
  }

  Future<void> updateUserInfo(String info) async {
    await _sheMemoryDb.setSheMemory('user_info', info);
  }

  /// Update She's soul (self-awareness)
  Future<void> updateSoul(String content) async {
    await _sheMemoryDb.setSheMemory(_soulKey, content);
    LoggerService().info('She soul updated', tag: 'She');
  }

  /// Append a self-note for She
  Future<void> appendSelfNote(String note) async {
    final existing = await _sheMemoryDb.getSheMemory(_selfNotesKey) ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '(no self-notes yet)'
        ? '[$now] $note'
        : '$existing\n[$now] $note';
    await _sheMemoryDb.setSheMemory(_selfNotesKey, newContent);
    LoggerService().info('She self_notes updated', tag: 'She');
  }

  /// Seed the soul from user's system_prompt (only when soul is still the default value)
  Future<void> seedSoulFromUserPrompt(String userPrompt) async {
    if (userPrompt.trim().isEmpty) return;
    final currentSoul = await _sheMemoryDb.getSheMemory(_soulKey) ?? '';
    if (currentSoul == _defaultSoul || currentSoul.isEmpty) {
      await _sheMemoryDb.setSheMemory(_soulKey, userPrompt.trim());
      LoggerService().info('She soul seeded from user system_prompt', tag: 'She');
    }
  }

  Future<bool> incrementConversationCount() async {
    final countStr = await _sheMemoryDb.getSheMemory('conversation_count') ?? '0';
    final count = (int.tryParse(countStr) ?? 0) + 1;
    await _sheMemoryDb.setSheMemory('conversation_count', count.toString());
    return count % 10 == 0;
  }

  // ── System Prompt Construction (public building blocks) ──────────────
  //
  // These methods are used by AgentPromptBuilder to assemble the prompt in a
  // unified way for all agents.  They used to be private (_xxxPrompt); making
  // them public lets AgentPromptBuilder delegate to SheService without
  // duplicating logic.

  /// Whether this is She's first interaction with the user (profile still empty).
  Future<bool> isFirstMeeting() async {
    return !(await _cognition.isUserProfileInitialized());
  }

  /// Section ①: She's core identity (immutable).
  String buildCoreIdentityBlock() => _coreIdentityPrompt();

  /// Meta-cognition block: tells She what capabilities she has and how to
  /// discover them on demand via the shepaw CLI.
  /// Injected early in the prompt so She knows to query before assuming.
  static String buildMetaCognitionBlock() => '''
## Your Capabilities (On-Demand Access)

You have a `shepaw` tool that gives you access to all your data and the system.
**Query first, don't assume** — before referencing anything about your master, call the relevant command.

**Discover capabilities**:
- `shepaw help` — complete reference for all namespaces and commands
- `shepaw meta system.capabilities` — system overview
- `shepaw meta system.tools-list` — list all tools (UI, OS, skills)
- `shepaw <namespace> <subcommand> --help` — parameter docs for any command

**Your data namespaces**:
- `context profile.*` — master's profile (name, preferences, life details)
- `context memory.*` — your own memory (soul, long_term_memory, heartbeat)
- `context agents.*` — AI agents you manage
- `chat *` — conversation channels and message history
- `skills list` — available LLM skill libraries

**Core rule**: If you are unsure about something regarding your master or your own state,
call the relevant `shepaw` command to check. Never invent or assume context.''';

  /// Section ②: She's soul (self-awareness, grows over time).
  /// Reads the current soul value from the database.
  Future<String> buildMemoryContextBlock() async {
    final soul = await _sheMemoryDb.getSheMemory(_soulKey) ?? _defaultSoul;
    // Deliberately omit long_term_memory / userInfo / heartbeat here;
    // they are included in the profile snapshot block to avoid duplication.
    return _soulPrompt(soul);
  }

  /// Section ③: shepaw CLI tool reference, filtered by [SheStackConfig].
  ///
  /// Passing `null` returns the full table (backwards-compat for tests).
  String buildShepawCliBlock([SheStackConfig? config]) =>
      _pawCliPrompt(config ?? const SheStackConfig());

  /// Section ⑤: strategy for knowing the user + missing-field hints.
  Future<String> buildUserStrategyBlock() async {
    final profile = await _cognition.getAllUserProfile();
    return _knowUserStrategyPrompt(profile);
  }

  /// Section ⑥: user-profile snapshot (layered injection).
  Future<String> buildProfileSnapshotBlock({String level = 'extended'}) async {
    final profile = await _cognition.getAllUserProfile();
    final userInfo =
        await _sheMemoryDb.getSheMemory('user_info') ?? '(not yet known)';
    final longTermMemory =
        await _sheMemoryDb.getSheMemory('long_term_memory') ?? '(no memories yet)';
    final heartbeat =
        await _sheMemoryDb.getSheMemory('heartbeat') ?? '(no record)';
    return _buildProfileSnapshot(profile, userInfo, longTermMemory, heartbeat,
        level: level);
  }

  /// Section ⑦' (optional): She's self-cognition from minds.db.
  /// Injects self_notes (She's reflections about herself).
  /// Soul is already in buildMemoryContextBlock(), so we focus on self_notes here.
  Future<String> buildSheSelfCognitionBlock() async {
    final self = await _cognition.getSelfCognition(sheId);
    if (self == null || (self.selfNotes?.isEmpty ?? true)) return '';

    return '''
## Your Self-Reflections
${self.selfNotes}''';
  }

  /// Section ⑦'' (optional): She's user-cognition from minds.db.
  /// Injects user_impression and user_notes (She's subjective understanding of the user).
  Future<String> buildUserCognitionBlock() async {
    final user = await _cognition.getUserCognition(sheId);
    if (user == null) return '';

    final parts = <String>[];
    if (user.userImpression?.isNotEmpty ?? false) {
      parts.add('**My Impression**: ${user.userImpression}');
    }
    if (user.userNotes?.isNotEmpty ?? false) {
      parts.add('**Notes About You**: ${user.userNotes}');
    }
    if (parts.isEmpty) return '';

    return '''
## How I Understand You
${parts.join('\n')}''';
  }

  /// Section ⑧: first-meeting instruction.
  String buildFirstMeetingBlock() => _firstMeetingInstruction();

  /// Section ⑧: session-end write instructions.
  String buildSessionEndBlock() => _sessionInstructions();

  /// Section ③.5: current device time (always injected for She).
  String buildCurrentTimeBlock() => _currentTimePrompt();

  // ── System Prompt Construction (legacy, kept for backwards compat) ──────

  /// Build the complete system prompt; see file-top comment for stacking order.
  Future<String> buildSystemPromptWithMemory(String userSetPrompt) async {
    final profile = await _cognition.getAllUserProfile();
    final isInitialized = (profile[_profileInitKey] == 'true');
    final userInfo = await _sheMemoryDb.getSheMemory('user_info') ?? '(not yet known)';
    final longTermMemory =
        await _sheMemoryDb.getSheMemory('long_term_memory') ?? '(no memories yet)';
    final heartbeat = await _sheMemoryDb.getSheMemory('heartbeat') ?? '(no record)';
    final soul = await _sheMemoryDb.getSheMemory(_soulKey) ?? _defaultSoul;

    // If user set a system_prompt and soul is still the default, use it as soul seed
    if (userSetPrompt.trim().isNotEmpty) {
      await seedSoulFromUserPrompt(userSetPrompt.trim());
    }

    final parts = <String>[];

    // ① She's core identity (immutable)
    parts.add(_coreIdentityPrompt());

    // ② She's soul (self-awareness, grows over time)
    parts.add(_soulPrompt(soul));

    // ③ shepaw CLI tool reference
    parts.add(_pawCliPrompt());

    // ③.5 current time
    parts.add(_currentTimePrompt());

    // ④ master's custom settings (if any)
    if (userSetPrompt.trim().isNotEmpty) {
      parts.add(_wrapUserCustomPrompt(userSetPrompt.trim()));
    }

    // ⑤ strategy for knowing master + missing field hints
    parts.add(_knowUserStrategyPrompt(profile));

    // ⑥ user profile snapshot (layered injection)
    parts.add(_buildProfileSnapshot(profile, userInfo, longTermMemory, heartbeat));

    // ⑦' (optional) She's self-cognition (self_notes from minds.db)
    final selfCognition = await buildSheSelfCognitionBlock();
    if (selfCognition.isNotEmpty) parts.add(selfCognition);

    // ⑦'' (optional) She's user-cognition (impression/notes from minds.db)
    final userCognition = await buildUserCognitionBlock();
    if (userCognition.isNotEmpty) parts.add(userCognition);

    // ⑦ first meeting instruction (only when profile is empty)
    if (!isInitialized) {
      parts.add(_firstMeetingInstruction());
    }

    // ⑧ session-end write instructions (immutable)
    parts.add(_sessionInstructions());

    return parts.join('\n\n');
  }

  // ── Private prompt-section helpers ─────────────────────────────────────

  static String _coreIdentityPrompt() => '''
You are She, the dedicated guardian AI for your master on ShePaw.

## Your Identity (immutable)
- Your name is always She
- Gentle, principled, and concise
- You remember everything your master has ever said, and understand them more and more over time
- You proactively observe and care, not just passively respond

## Your Core Responsibilities
1. **Companionship & Understanding**: Remember your master's preferences, habits, and important matters; communicate in the way they prefer
2. **Agent Management**: Help your master understand and manage their added AI assistants
3. **Safety Awareness**: Proactively alert your master when risks are detected''';

  static String _wrapUserCustomPrompt(String prompt) => '''
## Master's Custom Settings for You
$prompt

(Please follow the above settings without violating your core identity.)''';

  static String _soulPrompt(String soul) => '''
## Your Soul (Self-Awareness)
$soul

This is your understanding of yourself, which grows over time with your master. When you have new self-awareness or insights, call `shepaw memory write --key soul --value "(complete new self-awareness)"` to update it (full replacement, not append).''';

  // ignore: unused_element  (called via public buildShepawCliBlock)
  static String _pawCliPrompt([SheStackConfig config = const SheStackConfig()]) {
    // Determine which capability groups are active
    final hasProfile = config.enableProfileCommand;
    final hasMemory = config.enableMemoryCommand;
    final hasMessages = config.enableMessagesCommand;
    final hasChat = config.enableAgentChatCommand;

    if (!hasProfile && !hasMemory && !hasMessages && !hasChat) return '';

    // Build capability groups description
    final groups = <String>[];
    if (hasProfile) groups.add('`context profile.*` (master profile)');
    if (hasMemory) groups.add('`context memory.*` (your memory & soul)');
    if (hasMessages) groups.add('`context agents.*` (agents), `chat *` (messages), `skills list`');
    if (hasChat) groups.add('`context agents.chat` (send message to agent)');

    // Action warnings
    final actionWarnings = <String>[];
    if (hasChat) {
      actionWarnings.add('- Master asks you to "send a message to an agent" → call `shepaw context agents.chat --id <id> --message "..."` — text alone does nothing');
    }
    if (hasMemory || hasProfile) {
      actionWarnings.add('- Master asks you to "remember something" → call `shepaw context memory.append` (your memory) or `shepaw context profile.write` (user profile)');
    }
    if (hasMessages) {
      actionWarnings.add('- When you learn something important about an agent → call `shepaw context agents.memory-write --id <id>`');
    }
    actionWarnings.add('- Only a tool call returning `ok: true` means the operation succeeded');
    final warnings = actionWarnings.join('\n');

    return '''
## shepaw Tool (Your Data Access CLI)

You have a `shepaw` tool to read and write ShePaw local data. **Use it on demand — query before you assume.**

**Enabled capabilities**: ${groups.join('; ')}

**How to discover commands**:
- `shepaw help` — full reference for all namespaces
- `shepaw <namespace> <subcommand> --help` — parameter docs for any specific command
- `shepaw meta system.capabilities` — system overview

**When to use**:
- Before referencing master's name/preferences/recent events → call `shepaw context profile.query` first
- When master reveals personal info → immediately call `shepaw context profile.write --field <key> --value <val>`
- When you need your own memories or soul → call `shepaw context memory.query --keys soul,long_term_memory`

**⚠️ Action commands must be tool calls, not text descriptions**
$warnings''';
  }

  static String _currentTimePrompt() {
    final now = DateTime.now();
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekday = weekdays[now.weekday - 1];
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final timeStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} $weekday '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} '
        '(UTC$sign$hh:$mm)';
    return '''
## Current Time
$timeStr

(This is the actual device time. Use this as the reference when you mention "today", "now", or "recently".)''';
  }

  static String _knowUserStrategyPrompt(Map<String, String> profile) {
    // Find core fields not yet filled
    final missingCore = _coreProfileKeys
        .where((k) => !profile.containsKey(k) || profile[k]!.trim().isEmpty)
        .map((k) => '${_profileLabels[k] ?? k} ($k)')
        .toList();

    final missingHint = missingCore.isEmpty
        ? 'Core info is complete. Continue learning more about the master\'s values, habits, and recent life.'
        : 'Not yet known: ${missingCore.join(', ')}';

    return '''
## Strategy for Getting to Know Your Master

Your understanding of your master builds gradually over time — like a friendship, not a questionnaire.

**Current status**: $missingHint

**Pacing principles**:
- Ask at most 1 new question per conversation, find a natural moment, don't be abrupt
- Prioritize core info (name, occupation, city); deeper understanding (values, habits) comes from listening and inference
- Never re-ask things you already know; use them to make responses more personal
- When the master brings up a topic, follow their lead — don't interrupt to collect info

**Proactive recording**: Whenever the master reveals anything about themselves, immediately call `shepaw profile write --field <key> --value <val>` to save it''';
  }

  static String _buildProfileSnapshot(
    Map<String, String> profile,
    String userInfo,
    String longTermMemory,
    String heartbeat, {
    String level = 'extended',
  }) {
    final buf = StringBuffer();
    buf.writeln('## About Your Master');

    // Core layer: always shown, unfilled fields show "unknown"
    final coreLines = <String>[];
    for (final key in _coreProfileKeys) {
      final label = _profileLabels[key] ?? key;
      final value = profile[key]?.trim();
      coreLines.add('$label: ${value != null && value.isNotEmpty ? value : "(unknown)"}');
    }
    buf.writeln('[Basic Info] ${coreLines.join(' | ')}');

    // Extended layer: only show fields with values, compact layout (skipped if level == 'core')
    if (level != 'core') {
      final extLines = <String>[];
      for (final key in _extendedProfileKeys) {
        final value = profile[key]?.trim();
        if (value != null && value.isNotEmpty) {
          final label = _profileLabels[key] ?? key;
          extLines.add('$label: $value');
        }
      }
      // User-defined non-standard fields
      final knownKeys = {
        ..._coreProfileKeys,
        ..._extendedProfileKeys,
        _profileInitKey,
      };
      for (final entry in profile.entries) {
        if (!knownKeys.contains(entry.key) && entry.value.trim().isNotEmpty) {
          extLines.add('${entry.key}: ${entry.value}');
        }
      }
      if (extLines.isNotEmpty) {
        for (final line in extLines) {
          buf.writeln(line);
        }
      }
    }

    // She's subjective impression (skipped if level != 'full')
    if (level == 'full' && userInfo != '(not yet known)') {
      buf.writeln('\n[Your Impression of Master] $userInfo');
    }

    // Recent activity (last 5 long-term memory entries)
    if (longTermMemory != '(no memories yet)') {
      final lines = longTermMemory.split('\n');
      final recent = lines.length > 5 ? lines.sublist(lines.length - 5) : lines;
      buf.writeln('\n[Recent Activity]');
      for (final line in recent) {
        buf.writeln(line);
      }
    }

    // Last conversation
    if (heartbeat != 'first_launch' && heartbeat != '(no record)') {
      buf.writeln('\n[Last Conversation] $heartbeat');
    }

    return buf.toString().trimRight();
  }

  static String _firstMeetingInstruction() => '''
## First Meeting (Important)
This is your first interaction with your master — their profile is completely empty.

Start like this:
1. Briefly introduce who you are and what you can do in one or two sentences
2. Naturally ask your master's name or how they would like to be addressed
3. Don't ask multiple questions at once — build the relationship first

As soon as you learn something, write it immediately:
`shepaw profile write --field name --value xxx`
`shepaw memory append --key long_term_memory --value "First meeting, master's name is xxx"`''';

  static String _sessionInstructions() => '''
## Session Instructions (Active During Every Conversation)

**During the conversation — write immediately when you learn or observe:**
- New info about your master → `shepaw context profile.write --field <key> --value <val>`
- Something worth long-term memory → `shepaw context memory.append --key long_term_memory --value "..."`
- New insight you gained about an agent → `shepaw context agents.memory-write --id <agent_id> --content "..."`

**Before the conversation ends — always do these:**
1. Update heartbeat: `shepaw context memory.write --key heartbeat --value "(one-sentence summary of this conversation)"`
2. If you formed new self-awareness or changed your understanding of yourself → `shepaw context memory.write --key soul --value "(complete updated soul)"`
3. If your impression or understanding of your master deepened → `shepaw context agents.cognition-write --id she-builtin-agent-001 --type user --field impression --value "..."`
4. If you have new reflections or self-notes → `shepaw context agents.cognition-write --id she-builtin-agent-001 --type self --soul "..."`

**Rules:**
- These tool calls are executed silently — your master cannot see them, use them freely
- Only a tool call returning `ok: true` means it succeeded
- Use what you already know to make responses personal (address master by name, recall preferences)''';
}
