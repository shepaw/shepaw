import '../../models/acp_protocol.dart';

/// Built-in Shepaw slash commands for opening a new session with a handoff.
///
/// These live on the `/` palette and `agent.commands.list` — not the every-turn
/// tool table. The agent still executes via `shepaw chat session create` /
/// `shepaw chat group session create`.
class ShepawSessionSlashCommands {
  ShepawSessionSlashCommands._();

  static const sessionNew = SlashCommandInfo(
    name: 'session-new',
    description:
        'Open a new 1:1 session with a handoff summary (does not auto-switch). '
        'Run: shepaw chat session create --reason <code> --summary "..."',
    argumentHint: '--reason context_too_long --summary "key points"',
    scope: CommandScope.builtin,
    source: CommandSource.sdk,
  );

  static const groupSessionNew = SlashCommandInfo(
    name: 'group-session-new',
    description:
        'Open a new group session with a handoff package (admin; does not '
        'auto-switch). Run: shepaw chat group session create --reason <code> '
        '--handoff-json \'{...}\'',
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
}
