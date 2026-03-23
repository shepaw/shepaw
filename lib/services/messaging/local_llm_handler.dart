import '../../models/message.dart';
import '../../models/attachment_data.dart';
import '../../models/llm_stream_event.dart';
import '../os_tool_registry.dart';
import '../skill_registry.dart';
import '../model_registry.dart';
import '../ui_component_registry.dart';
import '../../clis/shepaw/shepaw_cli.dart';
import '../task/task_models.dart';

/// Utility helpers for the local LLM execution path.
///
/// These static helpers are extracted from ChatService to isolate the
/// tool-building and message-formatting logic.
class LocalLLMHelpers {
  /// Build the combined tool list for a local LLM agent.
  static List<Map<String, dynamic>> buildToolList({
    required bool isClaude,
    required List<String> enabledOsTools,
    required List<String> enabledSkills,
    required List<String> enabledToolModels,
    required Map<String, dynamic> toolModelScenarios,
    bool isShe = false,
    // 是否在工具列表里注入 get_tool_result（有历史工具调用时应传 true）
    bool includeGetToolResult = false,
  }) {
    final osRegistry = OsToolRegistry.instance;
    final skillRegistry = SkillRegistry.instance;
    final toolModelRegistry = ModelRegistry.instance;
    final pawRegistry = ShepawCLI.instance;

    if (isClaude) {
      return [
        ...UIComponentRegistry.instance.claudeTools(),
        if (enabledOsTools.isNotEmpty) ...osRegistry.claudeTools(enabledTools: enabledOsTools.toSet()),
        if (enabledSkills.isNotEmpty) ...skillRegistry.claudeTools(enabledSkills: enabledSkills.toSet()),
        if (enabledToolModels.isNotEmpty) ...toolModelRegistry.claudeTools(
          enabledToolModels: enabledToolModels.toSet(),
          scenarioOverrides: Map<String, String>.from(toolModelScenarios),
        ),
        if (isShe) pawRegistry.claudeTool(),
        if (includeGetToolResult) getToolResultClaude(),
      ];
    } else {
      return [
        ...UIComponentRegistry.instance.openAITools(),
        if (enabledOsTools.isNotEmpty) ...osRegistry.openAITools(enabledTools: enabledOsTools.toSet()),
        if (enabledSkills.isNotEmpty) ...skillRegistry.openAITools(enabledSkills: enabledSkills.toSet()),
        if (enabledToolModels.isNotEmpty) ...toolModelRegistry.openAITools(
          enabledToolModels: enabledToolModels.toSet(),
          scenarioOverrides: Map<String, String>.from(toolModelScenarios),
        ),
        if (isShe) pawRegistry.openAITool(),
        if (includeGetToolResult) getToolResultOpenAI(),
      ];
    }
  }

  /// Build the combined system prompt for a local LLM agent.
  static String buildSystemPrompt({
    required String baseSystemPrompt,
    required List<String> enabledOsTools,
    required List<String> enabledSkills,
    required List<String> enabledToolModels,
    required Map<String, dynamic> toolModelScenarios,
  }) {
    final osRegistry = OsToolRegistry.instance;
    final skillRegistry = SkillRegistry.instance;
    final toolModelRegistry = ModelRegistry.instance;

    return '$baseSystemPrompt'
        '${UIComponentRegistry.instance.systemPromptSuffix}'
        '${enabledOsTools.isNotEmpty ? osRegistry.systemPromptSuffix(enabledOsTools.toSet()) : ''}'
        '${enabledSkills.isNotEmpty ? skillRegistry.systemPromptSuffix(enabledSkills.toSet()) : ''}'
        '${enabledToolModels.isNotEmpty ? toolModelRegistry.systemPromptSuffix(enabledToolModels.toSet(), scenarioOverrides: Map<String, String>.from(toolModelScenarios)) : ''}';
  }

  /// Known UI tool names.
  static const uiToolNames = {
    'action_confirmation', 'single_select', 'multi_select',
    'file_upload', 'form', 'file_message', 'message_metadata',
  };

  static bool isUiTool(String name) => uiToolNames.contains(name);

  // ---------------------------------------------------------------------------
  // get_tool_result — 用于按需拉取历史工具调用的完整结果
  // ---------------------------------------------------------------------------

  /// 工具名称常量
  static const kGetToolResult = 'get_tool_result';

  /// OpenAI 格式的 get_tool_result 工具定义
  static Map<String, dynamic> getToolResultOpenAI() => {
        'type': 'function',
        'function': {
          'name': kGetToolResult,
          'description':
              'Retrieve the full output of a previously executed tool call. '
              'Use this when the tool result in the conversation history has been '
              'summarised and you need the complete details to answer the user.',
          'parameters': {
            'type': 'object',
            'properties': {
              'tool_call_id': {
                'type': 'string',
                'description': 'The tool_call_id of the tool execution whose '
                    'full result you want to retrieve.',
              },
            },
            'required': ['tool_call_id'],
          },
        },
      };

  /// Claude (Anthropic) 格式的 get_tool_result 工具定义
  static Map<String, dynamic> getToolResultClaude() => {
        'name': kGetToolResult,
        'description':
            'Retrieve the full output of a previously executed tool call. '
            'Use this when the tool result in the conversation history has been '
            'summarised and you need the complete details to answer the user.',
        'input_schema': {
          'type': 'object',
          'properties': {
            'tool_call_id': {
              'type': 'string',
              'description': 'The tool_call_id of the tool execution whose '
                  'full result you want to retrieve.',
            },
          },
          'required': ['tool_call_id'],
        },
      };

  /// Build lightweight attachment metadata for history entries.
  static Map<String, dynamic> buildAttachmentInfo(Message m) {
    final info = <String, dynamic>{
      'message_id': m.id,
      'type': m.type.toString().split('.').last,
    };
    if (m.metadata != null) {
      if (m.metadata!['name'] != null) info['file_name'] = m.metadata!['name'];
      if (m.metadata!['size'] != null) info['file_size'] = m.metadata!['size'];
      if (m.metadata!['type'] != null) info['mime_type'] = m.metadata!['type'];
      if (m.metadata!['duration_ms'] != null) info['duration_ms'] = m.metadata!['duration_ms'];
    }
    return info;
  }

  /// Build a user message map, potentially with multimodal content for image attachments.
  static Map<String, dynamic> buildUserMessageContent(
    String text,
    List<AttachmentData>? attachments,
    bool isClaude,
  ) {
    if (attachments == null || attachments.isEmpty) {
      return {'role': 'user', 'content': text};
    }

    final imageAttachments = attachments.where((a) => a.isImage && !a.exceedsSizeLimit).toList();
    final nonImageAttachments = attachments.where((a) => !a.isImage).toList();

    String effectiveText = text;
    if (nonImageAttachments.isNotEmpty) {
      final descriptions = nonImageAttachments.map((a) => a.textDescription).join('\n');
      effectiveText = '$descriptions\n\n$effectiveText';
    }

    if (imageAttachments.isEmpty) {
      return {'role': 'user', 'content': effectiveText};
    }

    if (isClaude) {
      final contentParts = <Map<String, dynamic>>[
        for (final img in imageAttachments)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': img.mimeType,
              'data': img.base64Data,
            },
          },
        {'type': 'text', 'text': effectiveText},
      ];
      return {'role': 'user', 'content': contentParts};
    } else {
      final contentParts = <Map<String, dynamic>>[
        {'type': 'text', 'text': effectiveText},
        for (final img in imageAttachments)
          {
            'type': 'image_url',
            'image_url': {'url': 'data:${img.mimeType};base64,${img.base64Data}'},
          },
      ];
      return {'role': 'user', 'content': contentParts};
    }
  }

  /// Append a tool round to the message history for OpenAI-compatible APIs.
  static void appendToolRoundOpenAI(
    List<Map<String, dynamic>> messages,
    Map<String, dynamic> rawAssistantMsg,
    List<LLMToolCallEvent> toolCalls,
    List<Map<String, dynamic>> toolResults,
  ) {
    messages.add(rawAssistantMsg);
    for (final result in toolResults) {
      messages.add({
        'role': 'tool',
        'tool_call_id': result['tool_call_id'],
        'content': result['result'] as String,
      });
    }
  }

  /// Append a tool round to the message history for Claude (Anthropic) API.
  static void appendToolRoundClaude(
    List<Map<String, dynamic>> messages,
    Map<String, dynamic> rawAssistantMsg,
    List<LLMToolCallEvent> toolCalls,
    List<Map<String, dynamic>> toolResults,
  ) {
    messages.add(rawAssistantMsg);
    final toolResultBlocks = <Map<String, dynamic>>[];
    for (final result in toolResults) {
      toolResultBlocks.add({
        'type': 'tool_result',
        'tool_use_id': result['tool_call_id'],
        'content': result['result'] as String,
      });
    }
    messages.add({
      'role': 'user',
      'content': toolResultBlocks,
    });
  }

  /// Dispatch a UI tool call to the appropriate callback on [activeTask].
  static void dispatchUiToolCall(
    LLMToolCallEvent tc,
    ActiveTask activeTask, {
    required void Function({
      Map<String, dynamic>? ac,
      Map<String, dynamic>? ss,
      Map<String, dynamic>? ms,
      Map<String, dynamic>? fu,
      Map<String, dynamic>? fd,
      Map<String, dynamic>? mm,
      bool? fmh,
    }) onCaptured,
  }) {
    final args = tc.arguments;
    switch (tc.name) {
      case 'action_confirmation':
        onCaptured(ac: Map<String, dynamic>.from(args));
        activeTask.onActionConfirmation?.call(args);
        break;
      case 'single_select':
        onCaptured(ss: Map<String, dynamic>.from(args));
        activeTask.onSingleSelect?.call(args);
        break;
      case 'multi_select':
        onCaptured(ms: Map<String, dynamic>.from(args));
        activeTask.onMultiSelect?.call(args);
        break;
      case 'file_upload':
        onCaptured(fu: Map<String, dynamic>.from(args));
        activeTask.onFileUpload?.call(args);
        break;
      case 'form':
        onCaptured(fd: Map<String, dynamic>.from(args));
        activeTask.onForm?.call(args);
        break;
      case 'file_message':
        onCaptured(fmh: true);
        activeTask.onFileMessage?.call(args);
        break;
      case 'message_metadata':
        onCaptured(mm: Map<String, dynamic>.from(args));
        activeTask.onMessageMetadata?.call(args);
        break;
    }
  }
}
