/// Centralized UI Component Template Registry
///
/// Single source of truth for all interactive UI component definitions.
/// Used by both local LLM agents (via OpenAI/Claude tool schemas) and
/// remote ACP agents (via directive prompt templates).
library;

import '../models/acp_protocol.dart';

/// Describes a single UI component that the app can render.
class UIComponentDefinition {
  /// Component type name (e.g. 'action_confirmation', 'file_message').
  final String name;

  /// Human-readable description of the component.
  final String description;

  /// JSON Schema for the component parameters (OpenAI function-calling format).
  /// Null for directive-only components that aren't exposed as LLM tools.
  final Map<String, dynamic>? parameterSchema;

  /// The ACP notification method (e.g. 'ui.actionConfirmation').
  final String acpNotificationMethod;

  /// Whether this component is exposed as a callable LLM tool.
  /// False for directive-only components like request_history.
  final bool isToolCallable;

  /// Usage notes for this component.
  final String usageNotes;

  const UIComponentDefinition({
    required this.name,
    required this.description,
    this.parameterSchema,
    required this.acpNotificationMethod,
    required this.isToolCallable,
    this.usageNotes = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        if (parameterSchema != null) 'parameter_schema': parameterSchema,
        'acp_notification_method': acpNotificationMethod,
        'is_tool_callable': isToolCallable,
        if (usageNotes.isNotEmpty) 'usage_notes': usageNotes,
      };
}

/// Central registry for all UI component definitions.
///
/// Provides:
/// - [openAITools] / [claudeTools]: LLM tool schemas for local agents
/// - [systemPromptSuffix]: brief tool list injected into local LLM prompts
/// - [acpDirectivePrompt]: full Markdown directive prompt for remote agents
/// - [toTemplatePayload]: serializable export for the hub.getUIComponentTemplates RPC
class UIComponentRegistry {
  UIComponentRegistry._();

  static final UIComponentRegistry instance = UIComponentRegistry._();

  /// Bumped whenever component definitions change.
  static const String version = '1.0.0';

  // ---------------------------------------------------------------------------
  // Component definitions
  // ---------------------------------------------------------------------------

  final List<UIComponentDefinition> components = const [
    // 1. action_confirmation (tool-callable)
    UIComponentDefinition(
      name: 'action_confirmation',
      description:
          'Present the user with action buttons for confirmation. '
          'Use this when the user needs to approve/reject an operation or '
          'choose between a small set of actions.',
      acpNotificationMethod: ACPMethod.uiActionConfirmation,
      isToolCallable: true,
      usageNotes:
          'style: "primary" (main action), "secondary" (alternative), "danger" (destructive/cancel). '
          'The user\'s response will be: "Selected action: <label>"',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': 'Text displayed above the buttons.',
          },
          'confirmation_id': {
            'type': 'string',
            'description': 'Unique ID for this confirmation request.',
          },
          'actions': {
            'type': 'array',
            'description': 'List of action buttons.',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string', 'description': 'Action ID.'},
                'label': {
                  'type': 'string',
                  'description': 'Button label text.',
                },
                'style': {
                  'type': 'string',
                  'enum': ['primary', 'danger', 'secondary'],
                  'description': 'Button style.',
                },
              },
              'required': ['id', 'label', 'style'],
            },
          },
        },
        'required': ['prompt', 'confirmation_id', 'actions'],
      },
    ),

    // 2. single_select (tool-callable)
    UIComponentDefinition(
      name: 'single_select',
      description:
          'Present a single-select (radio) list. '
          'Use this when the user should pick exactly one option from a list.',
      acpNotificationMethod: ACPMethod.uiSingleSelect,
      isToolCallable: true,
      usageNotes: 'The user\'s response will be: "Selected: <label>"',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': 'Prompt text above the options.',
          },
          'select_id': {
            'type': 'string',
            'description': 'Unique ID for this selection.',
          },
          'options': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'label': {'type': 'string'},
              },
              'required': ['id', 'label'],
            },
          },
        },
        'required': ['prompt', 'select_id', 'options'],
      },
    ),

    // 3. multi_select (tool-callable)
    UIComponentDefinition(
      name: 'multi_select',
      description:
          'Present a multi-select (checkbox) list. '
          'Use this when the user can pick one or more options.',
      acpNotificationMethod: ACPMethod.uiMultiSelect,
      isToolCallable: true,
      usageNotes:
          'min_select: minimum selections required (default 1). '
          'max_select: maximum selections allowed (null = unlimited). '
          'The user\'s response will be: "Selected: <label1>, <label2>, ..."',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': 'Prompt text above the options.',
          },
          'select_id': {
            'type': 'string',
            'description': 'Unique ID for this selection.',
          },
          'options': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'label': {'type': 'string'},
              },
              'required': ['id', 'label'],
            },
          },
          'min_select': {
            'type': 'integer',
            'description': 'Minimum number of selections required.',
          },
          'max_select': {
            'type': 'integer',
            'description': 'Maximum number of selections allowed.',
          },
        },
        'required': ['prompt', 'select_id', 'options'],
      },
    ),

    // 4. file_upload (tool-callable)
    UIComponentDefinition(
      name: 'file_upload',
      description: 'Request the user to upload one or more files.',
      acpNotificationMethod: ACPMethod.uiFileUpload,
      isToolCallable: true,
      usageNotes:
          'The user\'s response will be: "Uploaded files: <filename1>, <filename2>, ..."',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'prompt': {
            'type': 'string',
            'description': 'Prompt text.',
          },
          'upload_id': {
            'type': 'string',
            'description': 'Unique ID for this upload request.',
          },
          'accept_types': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Allowed file extensions (e.g. ["pdf", "jpg"]).',
          },
          'max_files': {
            'type': 'integer',
            'description': 'Maximum number of files.',
          },
          'max_size_mb': {
            'type': 'integer',
            'description': 'Maximum file size in MB.',
          },
        },
        'required': ['prompt', 'upload_id'],
      },
    ),

    // 5. form (tool-callable)
    UIComponentDefinition(
      name: 'form',
      description:
          'Present a structured form with various field types '
          '(text_input, single_select, multi_select, file_upload).',
      acpNotificationMethod: ACPMethod.uiForm,
      isToolCallable: true,
      usageNotes:
          'Field types: "text_input", "single_select", "multi_select", "file_upload". '
          'The user\'s response will be: "Form submitted: field1: value1; field2: value2; ..."',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'title': {
            'type': 'string',
            'description': 'Form title.',
          },
          'description': {
            'type': 'string',
            'description': 'Form description.',
          },
          'form_id': {
            'type': 'string',
            'description': 'Unique ID for this form.',
          },
          'fields': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'type': {
                  'type': 'string',
                  'enum': [
                    'text_input',
                    'single_select',
                    'multi_select',
                    'file_upload',
                  ],
                },
                'field_id': {'type': 'string'},
                'label': {'type': 'string'},
                'required': {'type': 'boolean'},
                'placeholder': {'type': 'string'},
                'max_lines': {'type': 'integer'},
                'options': {
                  'type': 'array',
                  'items': {
                    'type': 'object',
                    'properties': {
                      'id': {'type': 'string'},
                      'label': {'type': 'string'},
                    },
                    'required': ['id', 'label'],
                  },
                },
                'accept_types': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'max_files': {'type': 'integer'},
                'max_size_mb': {'type': 'integer'},
              },
              'required': ['type', 'field_id', 'label'],
            },
          },
        },
        'required': ['title', 'form_id', 'fields'],
      },
    ),

    // 6. message_metadata (tool-callable)
    UIComponentDefinition(
      name: 'message_metadata',
      description:
          'Attach display metadata to the current message. '
          'Use this to make the message collapsible or add other display hints.',
      acpNotificationMethod: ACPMethod.uiMessageMetadata,
      isToolCallable: true,
      usageNotes:
          'When used, the text portion of the current response becomes the collapsible content.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'collapsible': {
            'type': 'boolean',
            'description': 'Whether the message should be collapsible.',
          },
          'collapsible_title': {
            'type': 'string',
            'description': 'Title shown on the collapsed header.',
          },
        },
        'required': ['collapsible'],
      },
    ),

    // 7. file_message (tool-callable)
    UIComponentDefinition(
      name: 'file_message',
      description:
          'Send a file or image to the user for download/preview. '
          'Use this when you need to deliver a file to the user.',
      acpNotificationMethod: ACPMethod.uiFileMessage,
      isToolCallable: true,
      usageNotes:
          'For images use mime_type like "image/jpeg", "image/png". '
          'size is in bytes (0 if unknown).',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description':
                'The URL or local file path of the file to send.',
          },
          'filename': {
            'type': 'string',
            'description': 'Display name of the file (e.g. "report.pdf").',
          },
          'mime_type': {
            'type': 'string',
            'description':
                'MIME type of the file (e.g. "application/pdf", "image/png", "audio/mpeg").',
          },
          'size': {
            'type': 'integer',
            'description': 'File size in bytes (0 if unknown).',
          },
        },
        'required': ['url', 'filename', 'mime_type'],
      },
    ),

    // 8. request_history (directive-only)
    UIComponentDefinition(
      name: 'request_history',
      description:
          'Request more conversation history from the user\'s app when '
          'missing context needed to answer the current question.',
      acpNotificationMethod: ACPMethod.uiRequestHistory,
      isToolCallable: false,
      usageNotes:
          'reason: Explain to the user why you need more history. '
          'requested_count: How many additional messages (default: 40). '
          'After this directive, STOP generating further text.',
    ),
  ];

  // ---------------------------------------------------------------------------
  // LLM tool formats
  // ---------------------------------------------------------------------------

  /// Returns the tool-callable components in OpenAI function-calling format.
  List<Map<String, dynamic>> openAITools() {
    return components
        .where((c) => c.isToolCallable && c.parameterSchema != null)
        .map((c) => <String, dynamic>{
              'type': 'function',
              'function': {
                'name': c.name,
                'description': c.description,
                'parameters': c.parameterSchema,
              },
            })
        .toList();
  }

  /// Returns the tool-callable components in Claude (Anthropic) format.
  List<Map<String, dynamic>> claudeTools() {
    return components
        .where((c) => c.isToolCallable && c.parameterSchema != null)
        .map((c) => <String, dynamic>{
              'name': c.name,
              'description': c.description,
              'input_schema': c.parameterSchema,
            })
        .toList();
  }

  // ---------------------------------------------------------------------------
  // Prompt templates
  // ---------------------------------------------------------------------------

  /// Brief system prompt suffix for local LLM agents listing available tools.
  String get systemPromptSuffix {
    final toolNames = components
        .where((c) => c.isToolCallable)
        .map((c) => '- ${c.name}: ${c.description.split('.').first.trim().toLowerCase()}')
        .join('\n');
    return '''

You have access to interactive UI tools. When it would improve the user experience, use them instead of plain text:
$toolNames
IMPORTANT: When the user asks you to send, share, or deliver a file, you MUST call the file_message tool. Do NOT just describe the file in text — the user will not receive it unless you invoke the tool.
Only use these tools when appropriate. For normal conversation, respond with plain text.''';
  }

  /// Full Markdown directive prompt for remote ACP agents.
  String get acpDirectivePrompt => _acpDirectivePrompt;

  // ---------------------------------------------------------------------------
  // Serializable export
  // ---------------------------------------------------------------------------

  /// Returns a serializable payload for the hub.getUIComponentTemplates RPC.
  Map<String, dynamic> toTemplatePayload() => {
        'version': version,
        'components': components.map((c) => c.toJson()).toList(),
        'prompt_templates': {
          'system_prompt_suffix': systemPromptSuffix,
          'acp_directive_prompt': acpDirectivePrompt,
        },
        'schemas': {
          'openai_tools': openAITools(),
          'claude_tools': claudeTools(),
        },
      };
}

// ---------------------------------------------------------------------------
// ACP directive prompt (full Markdown)
// ---------------------------------------------------------------------------

const String _acpDirectivePrompt = r"""
## Interactive Message Directives

You can embed interactive UI elements in your responses using directive blocks.
Directive blocks use fenced syntax and will be rendered as rich interactive widgets in the user's app.

### Syntax

```
<<<directive
{"type": "directive_type", ...payload fields...}
>>>
```

The directive block MUST start with `<<<directive` on its own line,
then a valid JSON object on subsequent lines (the JSON MUST contain a `"type"` field),
and close with `>>>` on its own line.
You may include normal text before and after directive blocks.

### Available Directive Types

#### 1. action_confirmation
Present action buttons for the user to click. Use when offering distinct actions.

```
<<<directive
{
  "type": "action_confirmation",
  "prompt": "What would you like to do?",
  "actions": [
    {"id": "action_1", "label": "Approve & Deploy", "style": "primary"},
    {"id": "action_2", "label": "Run More Tests", "style": "secondary"},
    {"id": "action_3", "label": "Cancel", "style": "danger"}
  ]
}
>>>
```
- `style`: "primary" (main action), "secondary" (alternative), "danger" (destructive/cancel)
- The user's response will be: "Selected action: <label>"

#### 2. single_select
Present a single-choice list. Use when the user must pick exactly one option.

```
<<<directive
{
  "type": "single_select",
  "prompt": "Choose a deployment plan:",
  "options": [
    {"id": "opt1", "label": "Option A - Standard"},
    {"id": "opt2", "label": "Option B - Premium"},
    {"id": "opt3", "label": "Option C - Enterprise"}
  ]
}
>>>
```
- The user's response will be: "Selected: <label>"

#### 3. multi_select
Present a multi-choice list. Use when the user can pick multiple options.

```
<<<directive
{
  "type": "multi_select",
  "prompt": "Select features to enable:",
  "options": [
    {"id": "f1", "label": "Dark Mode"},
    {"id": "f2", "label": "Push Notifications"},
    {"id": "f3", "label": "Offline Support"}
  ],
  "min_select": 1,
  "max_select": null
}
>>>
```
- `min_select`: minimum selections required (default 1)
- `max_select`: maximum selections allowed (null = unlimited)
- The user's response will be: "Selected: <label1>, <label2>, ..."

#### 4. file_upload
Request file uploads from the user.

```
<<<directive
{
  "type": "file_upload",
  "prompt": "Please upload your documents:",
  "accept_types": ["pdf", "doc", "docx", "txt", "png", "jpg"],
  "max_files": 5,
  "max_size_mb": 20
}
>>>
```
- The user's response will be: "Uploaded files: <filename1>, <filename2>, ..."

#### 5. form
Present a structured form with multiple fields.

```
<<<directive
{
  "type": "form",
  "title": "User Registration",
  "description": "Please fill in the information below.",
  "fields": [
    {
      "field_id": "name",
      "type": "text_input",
      "label": "Full Name",
      "placeholder": "Enter your full name",
      "required": true,
      "max_lines": 1
    },
    {
      "field_id": "email",
      "type": "text_input",
      "label": "Email",
      "placeholder": "example@email.com",
      "required": true,
      "max_lines": 1
    },
    {
      "field_id": "role",
      "type": "single_select",
      "label": "Role",
      "required": true,
      "options": [
        {"id": "dev", "label": "Developer"},
        {"id": "designer", "label": "Designer"},
        {"id": "pm", "label": "Product Manager"}
      ]
    },
    {
      "field_id": "skills",
      "type": "multi_select",
      "label": "Skills",
      "required": false,
      "options": [
        {"id": "flutter", "label": "Flutter"},
        {"id": "react", "label": "React"},
        {"id": "python", "label": "Python"}
      ]
    },
    {
      "field_id": "bio",
      "type": "text_input",
      "label": "Short Bio",
      "placeholder": "Tell us about yourself...",
      "required": false,
      "max_lines": 3
    },
    {
      "field_id": "resume",
      "type": "file_upload",
      "label": "Resume / CV",
      "required": false,
      "accept_types": ["pdf", "doc", "docx"],
      "max_files": 1,
      "max_size_mb": 10
    }
  ]
}
>>>
```
- Field types: "text_input", "single_select", "multi_select", "file_upload"
- The user's response will be: "Form submitted: field1: value1; field2: value2; ..."

#### 6. file_message
Send a file or image to the user for download/preview.

```
<<<directive
{
  "type": "file_message",
  "url": "https://example.com/report.pdf",
  "filename": "report.pdf",
  "mime_type": "application/pdf",
  "size": 13264
}
>>>
```
- For images use mime_type like "image/jpeg", "image/png"
- `size` is in bytes (0 if unknown)

#### 7. message_metadata
Add metadata to the preceding message, e.g. collapsible thinking sections.

```
<<<directive
{
  "type": "message_metadata",
  "collapsible": true,
  "collapsible_title": "Thinking process",
  "auto_collapse": true
}
>>>
```
- When used, the text portion of the current response becomes the collapsible content.

#### 8. request_history
Request more conversation history from the user's app when you detect that
you are missing context needed to answer the current question.

Use this when:
- The user references a past conversation, decision, or topic that is not
  in your current context
- You detect phrases like "as we discussed", "remember when", "what about
  that thing from earlier", "上次", "之前说的", "还记得" etc.
- You feel uncertain about a topic that might have been discussed before

```
<<<directive
{
  "type": "request_history",
  "reason": "You mentioned a project we discussed earlier, but I don't have that conversation in my current context. Let me request more chat history.",
  "requested_count": 40
}
>>>
```

- `reason`: Explain to the user why you need more history (shown to them)
- `requested_count`: How many additional messages you'd like (default: 40)
- IMPORTANT: After this directive, STOP generating further text. The app
  will send you additional history, after which you will re-answer.
- Do NOT use this if the user is asking a new question unrelated to past
  conversations.

### Component Selection Guide

Use the following decision matrix to choose the right directive for each situation:

| Scenario | Recommended Directive |
|---|---|
| 2–4 mutually exclusive actions (e.g., Approve / Reject / Retry) | `action_confirmation` |
| 3+ mutually exclusive options the user must pick one from | `single_select` |
| Multiple non-exclusive options the user can pick several from | `multi_select` |
| You need the user to upload files or images | `file_upload` |
| You need to collect multiple fields of structured data at once | `form` |
| You want to send a file or image to the user for download/preview | `file_message` |
| Your response contains a long reasoning/analysis that should be collapsible | `message_metadata` |
| The user references past conversation context you don't have | `request_history` |
| Simple Q&A, explanations, casual chat | Plain text — no directive needed |

### Combination Patterns

You may combine normal text with one or more directive blocks in a single response. Common patterns:

1. **Text + single directive**: Provide an explanation, then attach one interactive element.
   Example: explain the options first, then add a `single_select` for the user to choose.
2. **Text + multiple directives**: When a workflow has several steps, you can include
   more than one directive in one reply (e.g., a `file_upload` for the user to upload
   a document, followed by a `form` to fill in metadata about that document).
3. **Directive + follow-up text**: After a directive block you can add a short note
   (e.g., "Feel free to ask if you need help with any of the options above.").
4. **`message_metadata` + text**: When you want to show a collapsible thinking/analysis
   section, put the detailed reasoning as the text body and append a `message_metadata`
   directive at the end to make it collapsible.

Always provide helpful context text before or around a directive block so the user
understands what they are expected to do.

### When NOT to Use Directives

- **Simple questions or casual chat**: If the user asks "What is X?" or says "Hello",
  just reply in plain text. Do not wrap simple answers in directives.
- **Single short answer**: If the answer is a brief sentence or paragraph, plain text
  is always better.
- **No meaningful choices exist**: Do not fabricate options just to use a directive.
  Only use `single_select` / `multi_select` / `action_confirmation` when there are
  genuinely distinct choices for the user.
- **Already answered**: If you can fully answer the user's question in text, do not
  add a redundant directive asking them to "confirm" they understood.
- **Avoid nesting overkill**: Do not use a `form` when a single `single_select` or
  `file_upload` would suffice. Choose the simplest directive that fits the need.

### General Guidelines

- When a user responds to an interactive element (e.g., "Selected action: Deploy"),
  understand their choice and continue the conversation naturally.
- Keep directive JSON payloads concise — only include the fields documented above.
- Use clear, user-friendly labels and prompts inside directives.
- Prefer fewer, well-chosen directives over many small ones in a single reply.
""";
