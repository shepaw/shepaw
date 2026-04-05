import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// Clipboard namespace — read and write clipboard
///
///   shepaw os clipboard.read
///   shepaw os clipboard.write --text "copied text"
class ClipboardNamespace extends CliNamespace {
  static final instance = ClipboardNamespace._();
  ClipboardNamespace._();

  @override
  String get namespace => 'clipboard';

  @override
  String get description => 'Clipboard operations (read, write)';

  @override
  String get usage => 'shepaw os clipboard.<action> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'read': _ClipboardReadCommand(),
        'write': _ClipboardWriteCommand(),
      };
}

// ── clipboard_read ───────────────────────────────────────────────────────────

class _ClipboardReadCommand extends CliCommand {
  @override
  String get name => 'read';

  @override
  String get description => 'Read the current contents of the clipboard.';

  @override
  String get usage => 'shepaw os clipboard.read';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('clipboard_read', {});
  }
}

// ── clipboard_write ──────────────────────────────────────────────────────────

class _ClipboardWriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description => 'Write text to the clipboard.';

  @override
  String get usage => 'shepaw os clipboard.write --text <text>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('clipboard_write', {
      if (flags['text'] != null) 'text': flags['text']!,
    });
  }
}
