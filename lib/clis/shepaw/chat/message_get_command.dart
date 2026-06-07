import 'dart:convert';

import '../../cli_base.dart';
import '../../../models/attachment_data.dart';
import '../../../models/llm_stream_event.dart';
import '../../../models/message.dart';
import '../../../models/model_definition.dart';
import '../../../models/remote_agent.dart';
import '../../../services/attachment_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/local_file_storage_service.dart';
import '../../../services/local_llm_agent_service.dart';
import '../../../services/messaging/local_llm_handler.dart';
import '../../../models/model_routing_config.dart';
import '../../../services/model_registry.dart';
import 'chat_agent_scope.dart';

/// 按 message_id 获取完整消息内容，支持按需读取附件与图片分析。
class MessageGetCommand extends CliCommand {
  MessageGetCommand();

  final _db = LocalDatabaseService();
  late final _attachmentService = AttachmentService(
    LocalFileStorageService(),
    _db,
  );

  @override
  String get name => 'get';

  @override
  String get description =>
      'Get full message by ID; optional --analyze for images, --include-data for base64';

  @override
  String get usage =>
      'shepaw chat message get --id <message_id> [--analyze "prompt"] [--include-data]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Message ID (from attachment_info.message_id or chat messages list)',
        'required': true,
        'type': 'string',
      },
      'analyze': {
        'description':
            'Analyze image attachment with vision model; optional custom prompt',
        'required': false,
        'type': 'string',
        'default': 'Describe the image content in detail, including any text.',
      },
      'include-data': {
        'description':
            'Include attachment bytes as base64 (images/files ≤ 20 MB)',
        'required': false,
        'type': 'boolean',
        'default': 'false',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final messageId = flags['id']?.trim();
    if (messageId == null || messageId.isEmpty) {
      return {
        'ok': false,
        'error': 'Missing required --id <message_id>.\nUsage: $usage',
      };
    }

    final message = await _loadMessage(messageId);
    if (message == null) {
      return {'ok': false, 'error': 'Message not found: $messageId'};
    }

    final result = <String, dynamic>{
      'ok': true,
      'message': _serializeMessage(message),
    };

    final hasAttachment = _hasAttachment(message);
    if (hasAttachment) {
      result['attachment'] = LocalLLMHelpers.buildAttachmentInfo(message);
    }

    final includeData = _flagIsTrue(flags['include-data']);
    final analyzePrompt = flags['analyze'];

    if (includeData) {
      if (!hasAttachment) {
        result['warning'] = 'Message has no attachment; --include-data ignored.';
      } else {
        final dataResult = await _loadAttachmentData(message);
        if (dataResult.containsKey('error')) {
          result['ok'] = false;
          result['error'] = dataResult['error'];
          return result;
        }
        result['attachment_data'] = dataResult;
      }
    }

    if (analyzePrompt != null) {
      if (message.type != MessageType.image) {
        return {
          'ok': false,
          'error':
              '--analyze only supports image messages (type=${message.type.name}).',
        };
      }

      final attachmentData = await _attachmentService.buildAttachmentData(message);
      if (attachmentData == null) {
        return {
          'ok': false,
          'error': 'Failed to read image attachment for message $messageId.',
        };
      }
      if (attachmentData.exceedsSizeLimit) {
        return {
          'ok': false,
          'error': 'Image exceeds 20 MB size limit for analysis.',
        };
      }

      final analysis = await _analyzeImage(
        prompt: analyzePrompt.isEmpty
            ? '请详细描述这张图片的内容，包括其中的文字。'
            : analyzePrompt,
        attachment: attachmentData,
      );
      if (analysis.startsWith('Error:')) {
        return {'ok': false, 'error': analysis};
      }
      result['analysis'] = analysis;
    }

    return result;
  }

  Future<Message?> _loadMessage(String messageId) async {
    final map = await _db.getMessageById(messageId);
    if (map == null) return null;

    Map<String, dynamic>? metadata;
    if (map['metadata'] != null) {
      try {
        metadata = Map<String, dynamic>.from(
          jsonDecode(map['metadata'] as String),
        );
      } catch (_) {}
    }

    MessageType type;
    switch (map['message_type'] as String? ?? 'text') {
      case 'image':
        type = MessageType.image;
        break;
      case 'file':
        type = MessageType.file;
        break;
      case 'audio':
        type = MessageType.audio;
        break;
      case 'system':
        type = MessageType.system;
        break;
      case 'permission_audit':
        type = MessageType.permissionAudit;
        break;
      default:
        type = MessageType.text;
    }

    return Message(
      id: map['id'] as String,
      from: MessageFrom(
        id: map['sender_id'] as String,
        type: map['sender_type'] as String,
        name: map['sender_name'] as String,
      ),
      channelId: map['channel_id'] as String?,
      type: type,
      content: map['content'] as String? ?? '',
      timestampMs:
          DateTime.parse(map['created_at'] as String).millisecondsSinceEpoch,
      replyTo: map['reply_to_id'] as String?,
      metadata: metadata,
    );
  }

  bool _hasAttachment(Message message) =>
      message.type == MessageType.image ||
      message.type == MessageType.file ||
      message.type == MessageType.audio;

  Map<String, dynamic> _serializeMessage(Message message) => {
        'id': message.id,
        'channel_id': message.channelId,
        'type': message.type.name,
        'content': message.content,
        'sender': message.from.name,
        'sender_id': message.from.id,
        'role': message.from.type,
        'created_at':
            DateTime.fromMillisecondsSinceEpoch(message.timestampMs)
                .toIso8601String(),
        'has_attachment': _hasAttachment(message),
      };

  Future<Map<String, dynamic>> _loadAttachmentData(Message message) async {
    final data = await _attachmentService.buildAttachmentData(message);
    if (data == null) {
      return {'error': 'Attachment file not found or unreadable.'};
    }
    if (data.exceedsSizeLimit) {
      return {'error': 'Attachment exceeds 20 MB size limit.'};
    }
    return {
      'file_name': data.fileName,
      'mime_type': data.mimeType,
      'file_size': data.sizeBytes,
      'semantic_type': data.semanticType,
      'base64': data.base64Data,
    };
  }

  Future<String> _analyzeImage({
    required String prompt,
    required AttachmentData attachment,
  }) async {
    final currentAgentId = ChatAgentScope.agentId;
    final agent = await _db.getRemoteAgentById(currentAgentId);
    if (agent == null) {
      return 'Error: agent $currentAgentId not found.';
    }

    final visionAgent = _resolveVisionAgent(agent);
    if (!visionAgent.supportsModality(ModalityType.image)) {
      return 'Error: no image understanding model configured for this agent. '
          'Enable an imageUnderstanding tool model in agent settings.';
    }

    final buffer = StringBuffer();
    try {
      final stream = LocalLLMAgentService.instance.chat(
        agent: visionAgent,
        message: prompt,
        enableUITools: false,
        includeShepawCli: false,
        systemPromptOverride: '',
        attachments: [attachment],
      );
      await for (final event in stream) {
        switch (event) {
          case LLMTextEvent(:final text):
            buffer.write(text);
          case LLMDoneEvent():
            break;
          default:
            break;
        }
      }
    } catch (e) {
      return 'Error: image analysis failed: $e';
    }

    final text = buffer.toString().trim();
    return text.isEmpty ? 'Error: vision model returned empty response.' : text;
  }

  /// Prefer an enabled imageUnderstanding tool model; fall back to the agent itself.
  RemoteAgent _resolveVisionAgent(RemoteAgent agent) {
    ModelDefinition? toolDef;
    for (final toolName in agent.enabledToolModels) {
      final def = ModelRegistry.instance.getDefinition(toolName);
      if (def != null && def.modelTypes.contains(ModelType.imageUnderstanding)) {
        toolDef = def;
        break;
      }
    }

    if (toolDef == null) return agent;

    final route = toolDef.route;
    final now = DateTime.now().millisecondsSinceEpoch;
    return RemoteAgent(
      id: agent.id,
      name: agent.name,
      token: agent.token,
      endpoint: agent.endpoint,
      protocol: agent.protocol,
      connectionType: agent.connectionType,
      metadata: {
        'llm_provider':
            (route.provider != null && route.provider!.isNotEmpty)
                ? route.provider!
                : 'openai',
        'llm_model': route.model ?? '',
        'llm_api_base': route.apiBase ?? '',
        'llm_api_key': route.apiKey ?? '',
        'main_model_id': toolDef.id,
      },
      createdAt: now,
      updatedAt: now,
    );
  }

  bool _flagIsTrue(String? value) {
    if (value == null) return false;
    final v = value.toLowerCase();
    return v == 'true' || v == '1' || v == 'yes';
  }
}
