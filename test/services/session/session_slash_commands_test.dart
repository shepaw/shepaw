import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/services/session/session_slash_commands.dart';

void main() {
  test('DM merge adds session-new and drops group-session-new', () {
    final merged = ShepawSessionSlashCommands.merge(
      const [
        SlashCommandInfo(name: 'compact'),
        SlashCommandInfo(name: 'group-session-new', description: 'stale'),
      ],
      isGroup: false,
    );
    expect(merged.map((c) => c.name), ['compact', 'session-new']);
  });

  test('group merge adds group-session-new and drops session-new', () {
    final merged = ShepawSessionSlashCommands.merge(
      const [
        SlashCommandInfo(name: 'session-new', description: 'stale'),
      ],
      isGroup: true,
    );
    expect(merged.map((c) => c.name), ['group-session-new']);
  });

  test('descriptions teach the shepaw CLI, not a function tool', () {
    expect(
      ShepawSessionSlashCommands.sessionNew.description,
      contains('shepaw chat session create'),
    );
    expect(
      ShepawSessionSlashCommands.groupSessionNew.description,
      contains('shepaw chat group session create'),
    );
  });

  test('expandForModel teaches CLI and does not start with a slash', () {
    final expanded = ShepawSessionSlashCommands.expandForModel(
      '/session-new --reason user_requested',
    );
    expect(expanded.startsWith('/'), isFalse);
    expect(expanded, startsWith(ShepawSessionSlashCommands.expandOpen));
    expect(expanded, contains('shepaw chat session create'));
    expect(expanded, contains('User-supplied flags: --reason user_requested'));
    expect(expanded, contains('Do not assume they switched'));
    expect(expanded, contains('SHEPAW_BIN'));
    expect(expanded, contains('Hub shim'));
  });

  test('expandForModel teaches group CLI after /group-session-new', () {
    final expanded = ShepawSessionSlashCommands.expandForModel(
      '/group-session-new',
    );
    expect(expanded, contains('shepaw chat group session create'));
    expect(expanded, contains('--handoff-json'));
  });

  test('expandForModel leaves ordinary text and already-expanded prompts', () {
    expect(ShepawSessionSlashCommands.expandForModel('hello'), 'hello');
    expect(ShepawSessionSlashCommands.expandForModel('/compact'), '/compact');
    final once = ShepawSessionSlashCommands.expandForModel('/session-new');
    expect(ShepawSessionSlashCommands.expandForModel(once), once);
  });

  test('expandForModel strips a leftover leading slash from older expands', () {
    final leftover =
        '/session-new\n\n${ShepawSessionSlashCommands.expandOpen}\nrun cli\n${ShepawSessionSlashCommands.expandClose}';
    final out = ShepawSessionSlashCommands.expandForModel(leftover);
    expect(out.startsWith('/'), isFalse);
    expect(out, contains(ShepawSessionSlashCommands.expandOpen));
  });
}
