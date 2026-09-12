import '../../models/acp_protocol.dart';

/// Built-in Shepaw slash commands for opening a new session with a handoff.
///
/// These live on the `/` palette and `agent.commands.list` — not the every-turn
/// tool table. Selecting one inserts `/name`; sending it expands into a
/// model-facing instruction ([expandForModel]) so the agent compresses
/// context and runs `shepaw chat session create` / group variant.
class ShepawSessionSlashCommands {
  ShepawSessionSlashCommands._();

  static const expandOpen = '[session-new]';
  static const expandClose = '[/session-new]';

  static const sessionNew = SlashCommandInfo(
    name: 'session-new',
    description:
        'Ask the agent to compress this chat and open a new 1:1 session '
        '(does not auto-switch). It should run: shepaw chat session create '
        '--reason <code> --summary "..."',
    argumentHint: '--reason context_too_long --summary "key points"',
    scope: CommandScope.builtin,
    source: CommandSource.sdk,
  );

  static const groupSessionNew = SlashCommandInfo(
    name: 'group-session-new',
    description:
        'Ask the admin agent to compress this group chat and open a new '
        'session (does not auto-switch). It should run: shepaw chat group '
        'session create --reason <code> --handoff-json \'{...}\'',
    argumentHint:
        '--reason topic_shift --handoff-json '
        '\'{"task":{"user_goal":"...","acceptance_criteria":["..."],'
        '"status":"in_progress"}}\'',
    scope: CommandScope.builtin,
    source: CommandSource.sdk,
  );

  static List<SlashCommandInfo> forConversation({required bool isGroup}) =>
      isGroup ? const [groupSessionNew] : const [sessionNew];

  /// Keep the command that matches this conversation; drop the other.
  static List<SlashCommandInfo> merge(
    List<SlashCommandInfo> existing, {
    required bool isGroup,
  }) {
    final extras = forConversation(isGroup: isGroup);
    final otherNames = <String>{
      for (final c in forConversation(isGroup: !isGroup)) _bareName(c.name),
    };
    final kept = [
      for (final c in existing)
        if (!otherNames.contains(_bareName(c.name))) c,
    ];
    final names = <String>{
      for (final c in kept) _bareName(c.name),
    };
    final missing = [
      for (final c in extras)
        if (!names.contains(_bareName(c.name))) c,
    ];
    if (missing.isEmpty && kept.length == existing.length) return existing;
    return [...kept, ...missing];
  }

  static String _bareName(String name) =>
      name.startsWith('/') ? name.substring(1) : name;

  static bool isExpanded(String text) =>
      text.contains(expandOpen) && text.contains(expandClose);

  /// Slash name if [raw] starts with `/session-new` or `/group-session-new`.
  static String? parseInvokedName(String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('/')) return null;
    final space = trimmed.indexOf(RegExp(r'\s'));
    final name =
        space == -1 ? trimmed.substring(1) : trimmed.substring(1, space);
    final bare = _bareName(name);
    if (bare == sessionNew.name || bare == groupSessionNew.name) return bare;
    return null;
  }

  /// Expand a user-visible `/session-new` into the model-facing instruction.
  ///
  /// The chat bubble stays as the raw slash line; only the LLM / engine
  /// prompt should use this.
  static String expandForModel(String raw) {
    if (isExpanded(raw)) return raw;
    final name = parseInvokedName(raw);
    if (name == null) return raw;
    final isGroup = name == groupSessionNew.name;
    return '$raw\n\n$expandOpen\n${_modelInstruction(isGroup: isGroup)}\n$expandClose';
  }

  static String _modelInstruction({required bool isGroup}) {
    if (isGroup) {
      return '''The user invoked /group-session-new. Understand the current conversation intent, compress durable context into a handoff, then run:

shepaw chat group session create --reason <topic_shift|post_delivery|noise_reduction|context_too_long|agent_memory_reset|parallel_track|user_requested> --handoff-json '{"task":{"user_goal":"...","acceptance_criteria":["..."],"status":"in_progress"}}'

Honor any flags the user already typed after the command. After the command succeeds, a switch card appears for the user to confirm. Do not assume they switched; continue here until they open the new session.''';
    }
    return '''The user invoked /session-new. Understand the current conversation intent, compress durable context into a handoff summary, then run:

shepaw chat session create --reason <topic_shift|post_delivery|noise_reduction|context_too_long|agent_memory_reset|parallel_track|user_requested> --summary "<compressed key points>"

Honor any flags the user already typed after the command. After the command succeeds, a switch card appears for the user to confirm. Do not assume they switched; continue here until they open the new session.''';
  }
}
