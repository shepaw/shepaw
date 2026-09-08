# ShePaw CLI Architecture Guide

## Overview

ShePaw CLI is a hierarchical, modular command-line interface system built on an abstract base class architecture. It enables She (the AI assistant) to query and modify local data through LLM function calling. The `shepaw <namespace> <subcommand>` tool tree includes a `models` namespace so She can also **configure AI models for the user** — inspect provider presets and current definitions, add/update/remove model definitions (with securely stored API keys), and assign a model as an agent's main chat model (e.g. when DeepSeek releases a new model).

## Directory Structure

```
lib/clis/
├── cli_base.dart              # Abstract base classes & IPawChatSender interface
└── shepaw/
    ├── shepaw_cli.dart        # Main entry point (CLI registry & execution router)
    ├── cli_l10n.dart          # i18n localization facade [TODO]
    │
    ├── profile/               # Profile namespace (5 files)
    │   ├── profile_namespace.dart
    │   ├── fields_command.dart
    │   ├── query_command.dart
    │   ├── write_command.dart
    │   └── delete_command.dart
    │
    ├── memory/                # Memory namespace (4 files)
    │   ├── memory_namespace.dart
    │   ├── query_command.dart
    │   ├── write_command.dart
    │   └── append_command.dart
    │
    ├── agents/                # Agents namespace (6 files)
    │   ├── agents_namespace.dart
    │   ├── list_command.dart
    │   ├── get_command.dart
    │   ├── channels_command.dart
    │   ├── messages_command.dart
    │   └── chat_command.dart
    │
    ├── models/                # Model configuration namespace (model definitions,
    │   │                      #  provider presets, per-agent main model)
    │   ├── models_namespace.dart
    │   ├── list_command.dart
    │   ├── show_command.dart
    │   ├── providers_command.dart
    │   ├── add_command.dart
    │   ├── update_command.dart
    │   ├── remove_command.dart
    │   ├── agent_main_command.dart
    │   └── models_cli_helpers.dart
    │
    ├── messages/              # Messages namespace (2 files)
    │   ├── messages_namespace.dart
    │   └── query_command.dart
    │
    ├── channels_namespace.dart   # Single-file namespaces (no subcommands)
    ├── skills_namespace.dart
    ├── tools_namespace.dart
    ├── datetime_namespace.dart
    └── help_namespace.dart
```

## Core Concepts

### 1. Commands (`CliCommand`)

A command is the smallest executable unit. Each represents one atomic operation.

**Abstract interface:**
```dart
abstract class CliCommand {
  String get name;           // e.g., 'query', 'write', 'delete'
  String get description;    // Human-readable description
  Future<Map<String, dynamic>> execute(Map<String, String> flags);
  String getMessage(String key, {Map<String, String>? args});  // i18n support
}
```

**Example:** `lib/clis/shepaw/profile/query_command.dart`
```dart
class QueryCommand extends CliCommand {
  final _profileDb = SheProfileDatabaseService();

  @override
  String get name => 'query';

  @override
  String get description => 'Query profile, optional --fields name,age,...';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final profile = await _profileDb.getAllUserProfile();
    // ... implementation
    return {'profile': profile, 'count': profile.length};
  }
}
```

### 2. Namespaces (`CliNamespace`)

A namespace groups related commands and handles routing between them.

**Abstract interface:**
```dart
abstract class CliNamespace {
  String get namespace;     // e.g., 'profile', 'agents'
  String get description;
  Map<String, CliCommand> get commands;  // Subcommand registry
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags);
  Map<String, dynamic> getHelp();
}
```

**Example:** `lib/clis/shepaw/profile/profile_namespace.dart`
```dart
class ProfileNamespace extends CliNamespace {
  static final instance = ProfileNamespace._();
  ProfileNamespace._();

  @override
  String get namespace => 'profile';

  @override
  Map<String, CliCommand> get commands => {
    'fields': FieldsCommand(),
    'query': QueryCommand(),
    'write': WriteCommand(),
    'delete': DeleteCommand(),
  };

  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    return super.execute(subcommand, flags);  // Default routing
  }

  @override
  Map<String, dynamic> getHelp() => {
    'subcommands': {
      'fields': 'List all predefined fields',
      'query': 'Query profile, optional --fields name,age,...',
      // ...
    },
    'examples': [
      'shepaw profile query',
      'shepaw profile write --field name --value John',
    ],
  };
}
```

### 3. ShePaw Main Entry Point (`ShepawCLI`)

The singleton coordinator that registers all namespaces and routes incoming commands.

```dart
class ShepawCLI {
  static final ShepawCLI instance = ShepawCLI._();

  late final Map<String, CliNamespace> _namespaces = {
    'profile': ProfileNamespace.instance,
    'memory': MemoryNamespace.instance,
    'agents': AgentsNamespace.instance,
    // ... etc
  };

  // LLM tool definitions for OpenAI & Claude
  Map<String, dynamic> openAITool() { ... }
  Map<String, dynamic> claudeTool() { ... }
  bool isPawTool(String name) => name == 'shepaw';

  // Main execution
  Future<String> execute(Map<String, dynamic> args) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);
    
    final ns = _namespaces[namespace];
    if (ns == null) return jsonEncode({'error': 'Unknown namespace'});
    
    final result = await ns.execute(subcommand, flags);
    return jsonEncode(result);
  }
}
```

## How to Add a New Command

### Step 1: Create the Command File

Create a new file under the appropriate namespace directory:

**File:** `lib/clis/shepaw/profile/rename_command.dart`

```dart
import '../../cli_base.dart';
import '../../../services/she_profile_database_service.dart';

class RenameCommand extends CliCommand {
  final _profileDb = SheProfileDatabaseService();

  @override
  String get name => 'rename';

  @override
  String get description => 'Rename a profile field';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final oldName = flags['old_name'];
    final newName = flags['new_name'];

    if (oldName == null || oldName.isEmpty) {
      return {'error': 'Missing --old_name parameter'};
    }
    if (newName == null || newName.isEmpty) {
      return {'error': 'Missing --new_name parameter'};
    }

    // Implementation: call database service
    final oldValue = await _profileDb.getUserProfile(oldName);
    if (oldValue == null) {
      return {'error': 'Field not found: $oldName'};
    }

    await _profileDb.setSheMemory(newName, oldValue);
    await _profileDb.deleteUserProfile(oldName);

    return {'ok': true, 'old_name': oldName, 'new_name': newName};
  }
}
```

### Step 2: Register the Command in the Namespace

Update the namespace's `commands` map:

**File:** `lib/clis/shepaw/profile/profile_namespace.dart`

```dart
import 'rename_command.dart';  // Add import

class ProfileNamespace extends CliNamespace {
  // ... existing code ...

  @override
  Map<String, CliCommand> get commands => {
    'fields': FieldsCommand(),
    'query': QueryCommand(),
    'write': WriteCommand(),
    'delete': DeleteCommand(),
    'rename': RenameCommand(),  // Add new command
  };

  @override
  Map<String, dynamic> getHelp() => {
    'subcommands': {
      'fields': 'List all predefined fields',
      'query': 'Query profile, optional --fields name,age,...',
      'write': 'Write field, --field <key> --value <val>',
      'delete': 'Delete field, --field <key>',
      'rename': 'Rename field, --old_name <key> --new_name <key>',  // Add help
    },
    'examples': [
      // ... existing examples ...
      'shepaw profile rename --old_name age --new_name years_old',
    ],
  };
}
```

### Step 3: Test

The command is immediately available via LLM function calling:

```
shepaw profile rename --old_name age --new_name years_old
```

## How to Add a New Namespace

If you need to add a completely new top-level namespace (e.g., `shepaw settings <subcommand>`):

### Step 1: Create the Directory & Files

```
lib/clis/shepaw/settings/
├── settings_namespace.dart
├── get_command.dart
└── set_command.dart
```

### Step 2: Implement Namespace & Commands

Follow the same pattern as existing namespaces (extend `CliNamespace`, register commands).

### Step 3: Register in ShepawCLI

**File:** `lib/clis/shepaw/shepaw_cli.dart`

```dart
import 'settings/settings_namespace.dart';

class ShepawCLI {
  late final Map<String, CliNamespace> _namespaces = {
    'profile': ProfileNamespace.instance,
    'memory': MemoryNamespace.instance,
    'agents': AgentsNamespace.instance,
    'channels': ChannelsNamespace.instance,
    'messages': MessagesNamespace.instance,
    'skills': SkillsNamespace.instance,
    'tools': ToolsNamespace.instance,
    'datetime': DatetimeNamespace.instance,
    'help': HelpNamespace.instance,
    'settings': SettingsNamespace.instance,  // Add here
  };

  Map<String, dynamic> _parameterSchema() => {
    'namespace': {
      'enum': _namespaces.keys.toList(),  // Auto-includes 'settings'
      // ...
    },
    // ...
  };
}
```

## Important Design Patterns

### 1. Singleton Namespaces

Each namespace is a singleton. Use lazy initialization:

```dart
class ProfileNamespace extends CliNamespace {
  static final instance = ProfileNamespace._();
  ProfileNamespace._();  // Private constructor
  // ...
}
```

### 2. Error Handling

Always return structured error responses:

```dart
return {
  'error': 'Error description',
  'code': 'ERROR_CODE',
  'suggestion': 'How to fix it',
};
```

### 3. Pagination for Large Results

Support `--limit` and `--offset` for queries:

```dart
final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
final offset = int.tryParse(flags['offset'] ?? '0') ?? 0;
// ... use in database query ...
return {'items': items, 'count': items.length, 'limit': limit, 'offset': offset};
```

### 4. Empty Commands Map for Direct Execution

Some namespaces don't need subcommands (e.g., `datetime`, `channels`):

```dart
class DatetimeNamespace extends CliNamespace {
  @override
  Map<String, CliCommand> get commands => {};  // Empty

  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    // Override to bypass subcommand routing, execute directly
    return _directExecute();
  }

  Future<Map<String, dynamic>> _directExecute() async {
    // Implementation...
  }
}
```

## Integration Points

### For LLM Integration (automatic)
- `ShepawCLI.instance.openAITool()` — Generate tool definition for OpenAI API
- `ShepawCLI.instance.claudeTool()` — Generate tool definition for Claude API
- `ShepawCLI.instance.execute(args)` — Execute command from LLM tool call

### For She Agent Initialization
- `ChatService._internal()` injects `IPawChatSender` via `ShepawCLI.instance.chatSender = this`
- Enables `shepaw agents chat` to send messages back to other agents

## Best Practices

1. **Use dependency injection for services**: Pass database services to command constructors or as fields
2. **Validate flags early**: Check required parameters at the start of `execute()`
3. **Return consistent JSON structure**: Always include 'ok' or 'error' key at top level
4. **Document with examples**: Help text should include realistic command usage
5. **Keep commands focused**: One command = one atomic operation
6. **Use lazy initialization**: Create command instances in namespace's `commands` getter, not at class level

## Model Configuration (`shepaw models`)

The `models` namespace lets She help the user configure AI models from chat. It is
registered as a top-level namespace in `ShepawCLI._namespaces` (and surfaced in
`CliNamespaceRegistry` for command-permission UIs).

### Commands

| Command | Purpose |
|---------|---------|
| `shepaw models list` | List configured model definitions (sanitized — never API keys) + which agents use each one |
| `shepaw models show --id <id>` | Full detail of one definition (sanitized) |
| `shepaw models providers` | Built-in LLM provider presets (api base / protocol type / key policy) + configuration facts |
| `shepaw models add --provider <label> --name <model>` | Create a definition (auto provider presets, auto key reuse by api base, duplicate-guarded) |
| `shepaw models update --id <id> ...` | Update fields incl. securely-stored API key (`--api_key`, `--clear_api_key`) |
| `shepaw models remove --id <id> [--yes]` | Delete (refused while agents still reference it, unless `--yes`) |
| `shepaw models agent-main --agent <id\|name> --model <id\|model>` | Set/switch/unset an agent's main chat model (`metadata['main_model_id']`, same field as the agent editor) |

### What She needs to know (knowledge content)

Runtime guidance lives in `ModelsNamespace.getHelpAsync()` (`what_she_needs_to_know`,
`rules`, `workflow_deepseek_example`) plus the `shepaw` tool description and She's
meta-cognition block in `she_service.dart`. Key facts encoded there:

1. **State first**: `models list` / `models providers` before assuming anything; a model only
   matters once referenced by an agent (`main_model_id` / `scenario_models`).
2. **Sources of truth for "newest model"**: there is no built-in remote model directory —
   verify a brand-new release's exact model id against the provider's official docs via
   `tools web.search`, then `models add` — never guess a model id.
3. **Secrets**: API keys are stored via `SecureKeyManager` and never echoed; a key cached for the
   same `api_base` is reused when adding (mirrors the UI key-cache behaviour).
4. **Activation**: `add` alone does not switch anyone — assign with `agent-main` (takes effect
   from the agent's next message; explicit scenario models still take priority per modality).
5. **Safety**: removing an in-use definition is refused without `--yes`; confirm changes with the
   user before altering/removing what is in use.

See `docs/model_config_cli.md` for the end-to-end scenario walkthrough.

## Future: Multi-Language Support (i18n)

TBD: CLI strings will be localized via `lib/clis/cli_l10n.dart` + `.arb` files.

Replace hardcoded strings with `CliL10n.t('key')` calls when available.
