import 'package:uuid/uuid.dart';
import '../models/prompt_stack_config.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';
import 'she_profile_database_service.dart';
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
  final SheProfileDatabaseService _profileDb = SheProfileDatabaseService();

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

    await _profileDb.setSheMemory('user_info', '(not yet known)');
    await _profileDb.setSheMemory('long_term_memory', '(no memories yet)');
    await _profileDb.setSheMemory('heartbeat', 'first_launch');
    await _profileDb.setSheMemory('conversation_count', '0');
    await _profileDb.setSheMemory(_soulKey, _defaultSoul);
    await _profileDb.setSheMemory(_selfNotesKey, '(no self-notes yet)');
    await _profileDb.setSheMemory('capabilities', _defaultCapabilities);

    LoggerService().info('She agent created successfully', tag: 'She');
  }

  // ── User Profile ─────────────────────────────────────────────────

  Future<bool> isUserProfileInitialized() async {
    final flag = await _profileDb.getUserProfile(_profileInitKey);
    return flag == 'true';
  }

  Future<void> updateUserProfileField(String key, String value) async {
    await _profileDb.setUserProfile(key, value);
    if (key != _profileInitKey) {
      await _profileDb.setUserProfile(_profileInitKey, 'true');
    }
    LoggerService().info('User profile updated: $key = $value', tag: 'She');
  }

  Future<void> updateUserProfileFields(Map<String, String> fields) async {
    for (final entry in fields.entries) {
      await _profileDb.setUserProfile(entry.key, entry.value);
    }
    if (fields.isNotEmpty) {
      await _profileDb.setUserProfile(_profileInitKey, 'true');
    }
    LoggerService().info(
        'User profile batch updated: ${fields.keys.join(', ')}', tag: 'She');
  }

  // ── Memory System ─────────────────────────────────────────────────

  Future<void> updateHeartbeat(String summary) async {
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    await _profileDb.setSheMemory('heartbeat', '[$now] $summary');
  }

  Future<void> appendMemory(String entry) async {
    final existing = await _profileDb.getSheMemory('long_term_memory') ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '(no memories yet)'
        ? '[$now] $entry'
        : '$existing\n[$now] $entry';
    await _profileDb.setSheMemory('long_term_memory', newContent);
  }

  Future<void> updateUserInfo(String info) async {
    await _profileDb.setSheMemory('user_info', info);
  }

  /// Update She's soul (self-awareness)
  Future<void> updateSoul(String content) async {
    await _profileDb.setSheMemory(_soulKey, content);
    LoggerService().info('She soul updated', tag: 'She');
  }

  /// Append a self-note for She
  Future<void> appendSelfNote(String note) async {
    final existing = await _profileDb.getSheMemory(_selfNotesKey) ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '(no self-notes yet)'
        ? '[$now] $note'
        : '$existing\n[$now] $note';
    await _profileDb.setSheMemory(_selfNotesKey, newContent);
    LoggerService().info('She self_notes updated', tag: 'She');
  }

  /// Seed the soul from user's system_prompt (only when soul is still the default value)
  Future<void> seedSoulFromUserPrompt(String userPrompt) async {
    if (userPrompt.trim().isEmpty) return;
    final currentSoul = await _profileDb.getSheMemory(_soulKey) ?? '';
    if (currentSoul == _defaultSoul || currentSoul.isEmpty) {
      await _profileDb.setSheMemory(_soulKey, userPrompt.trim());
      LoggerService().info('She soul seeded from user system_prompt', tag: 'She');
    }
  }

  Future<bool> incrementConversationCount() async {
    final countStr = await _profileDb.getSheMemory('conversation_count') ?? '0';
    final count = (int.tryParse(countStr) ?? 0) + 1;
    await _profileDb.setSheMemory('conversation_count', count.toString());
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
    final flag = await _profileDb.getUserProfile(_profileInitKey);
    return flag != 'true';
  }

  /// Section ①: She's core identity (immutable).
  String buildCoreIdentityBlock() => _coreIdentityPrompt();

  /// Section ②: She's soul (self-awareness, grows over time).
  /// Reads the current soul value from the database.
  Future<String> buildMemoryContextBlock() async {
    final soul = await _profileDb.getSheMemory(_soulKey) ?? _defaultSoul;
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
    final profile = await _profileDb.getAllUserProfile();
    return _knowUserStrategyPrompt(profile);
  }

  /// Section ⑥: user-profile snapshot (layered injection).
  Future<String> buildProfileSnapshotBlock() async {
    final profile = await _profileDb.getAllUserProfile();
    final userInfo =
        await _profileDb.getSheMemory('user_info') ?? '(not yet known)';
    final longTermMemory =
        await _profileDb.getSheMemory('long_term_memory') ?? '(no memories yet)';
    final heartbeat =
        await _profileDb.getSheMemory('heartbeat') ?? '(no record)';
    return _buildProfileSnapshot(profile, userInfo, longTermMemory, heartbeat);
  }

  /// Section ⑦: first-meeting instruction.
  String buildFirstMeetingBlock() => _firstMeetingInstruction();

  /// Section ⑧: session-end write instructions.
  String buildSessionEndBlock() => _sessionInstructions();

  /// Section ③.5: current device time (always injected for She).
  String buildCurrentTimeBlock() => _currentTimePrompt();

  // ── System Prompt Construction (legacy, kept for backwards compat) ──────

  /// Build the complete system prompt; see file-top comment for stacking order.
  Future<String> buildSystemPromptWithMemory(String userSetPrompt) async {
    final profile = await _profileDb.getAllUserProfile();
    final isInitialized = (profile[_profileInitKey] == 'true');
    final userInfo = await _profileDb.getSheMemory('user_info') ?? '(not yet known)';
    final longTermMemory =
        await _profileDb.getSheMemory('long_term_memory') ?? '(no memories yet)';
    final heartbeat = await _profileDb.getSheMemory('heartbeat') ?? '(no record)';
    final soul = await _profileDb.getSheMemory(_soulKey) ?? _defaultSoul;

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
    final rows = <String>[];

    if (config.enableProfileCommand) {
      rows
        ..add('| `shepaw profile query` | Query master profile |')
        ..add('| `shepaw profile write --field name --value John` | Write a profile field |');
    }
    if (config.enableMemoryCommand) {
      rows
        ..add('| `shepaw memory query --keys soul,user_info` | Query specific memories |')
        ..add('| `shepaw memory write --key soul --value "..."` | Update self-awareness |')
        ..add('| `shepaw memory append --key long_term_memory --value "..."` | Append to long-term memory |');
    }
    if (config.enableMessagesCommand) {
      rows
        ..add('| `shepaw agents list` | List all agents |')
        ..add('| `shepaw agents channels --id <agent_id>` | View channels of an agent |')
        ..add('| `shepaw agents messages --id <agent_id> [--channel <id>] [--limit 20] [--offset 0]` | Read agent channel messages (supports pagination) |')
        ..add('| `shepaw messages query --channel <id>` | Query channel messages |')
        ..add('| `shepaw messages query --agent <agent_id> [--limit 20] [--offset 0]` | Query messages for a specific agent (supports pagination) |')
        ..add('| `shepaw skills list` | List skills |');
    }
    if (config.enableAgentChatCommand) {
      rows.add('| `shepaw agents chat --id <agent_id> --message "..."` | Send a message to an agent as She |');
    }

    if (rows.isEmpty) return '';

    final table = rows.join('\n');

    final actionWarnings = <String>[];
    if (config.enableAgentChatCommand) {
      actionWarnings.add('- Master asks you to "send a message to an agent" → you must call `shepaw agents chat --id <agent_id> --message "..."` — saying "I have sent it" in text does nothing');
    }
    if (config.enableMemoryCommand || config.enableProfileCommand) {
      actionWarnings.add('- Master asks you to "remember something" → you must call `shepaw memory append` or `shepaw profile write` to actually save it');
    }
    actionWarnings.add('- Only a tool call returning `ok: true` means the operation succeeded; otherwise treat it as not executed');
    final warnings = actionWarnings.join('\n');

    return '''
## shepaw Tool (Your Data Access CLI)

You have a `shepaw` tool to query and write to the ShePaw local database. Call it on demand; no need to keep it in context when not in use.

**Quick Reference** (call `shepaw help` for full usage):

| Command | Description |
|---------|-------------|
$table

**When to use**: Proactively call when you need to view the full master profile, query agent details, or look up message history. Once you learn something about your master, immediately write it with `shepaw profile write`.

**⚠️ Important: Action commands must be executed via tool call, not described in text**
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
    String heartbeat,
  ) {
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

    // Extended layer: only show fields with values, compact layout
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

    // She's subjective impression
    if (userInfo != '(not yet known)') {
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
## Session Instructions
- When you learn any new info about your master during the conversation → immediately call `shepaw profile write --field <key> --value <val>`
- When you have new self-awareness or insight → `shepaw memory write --key soul --value "(complete new self-awareness)"`
- Things worth remembering long-term → `shepaw memory append --key long_term_memory --value "..."`
- Before the conversation ends → `shepaw memory write --key heartbeat --value "(one-sentence summary)"`
- These tool calls are executed silently by the system; your master cannot see them — use them freely
- Use what you already know to make responses more personal (e.g., address your master by name)''';
}
