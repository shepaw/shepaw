import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/channel.dart';
import '../../models/message.dart';
import '../../models/remote_agent.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_uri_reader.dart';
import '../file_download_service.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../task/acp_task_contract.dart';
import 'group_member_capability_probe.dart';
import 'group_turn_result.dart';

/// Executes a single agent's response turn within a group chat.
///
/// 群编排已经搬到 Hub；本机只保留文件消息落库和一条明确的「不再编排」回执，
/// 避免旧调用方静默无输出。
class GroupAgentExecutor {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final void Function(String channelId) notifyChannelUpdate;

  GroupAgentExecutor({
    required LocalDatabaseService db,
    required Uuid uuid,
    required this.notifyChannelUpdate,
  })  : _db = db,
        _uuid = uuid;

  Future<void> saveGroupFileMessage({
    required Map<String, dynamic> fileData,
    required String agentId,
    required String agentName,
    required String channelId,
    required String userId,
    required String userName,
  }) async {
    try {
      final url = fileData['url'] as String?;
      final filename = fileData['filename'] as String?;
      final fileMimeType = fileData['mime_type'] as String?;
      int? size = (fileData['size'] as num?)?.toInt();
      final thumbnailBase64 = fileData['thumbnail_base64'] as String?;

      if (url == null || url.isEmpty) {
        LoggerService().warning(
            'Group file_message missing url from $agentName',
            tag: 'GroupAgentExecutor');
        return;
      }

      // pouch:// 引用已在本机储物袋中，无需下载；本地路径才需要立即复制。
      final isStoreUri = isPouchUri(url);

      String? copiedRelativePath;
      final isLocalPath = !isStoreUri &&
          !url.startsWith('http://') &&
          !url.startsWith('https://');
      if (isLocalPath) {
        try {
          final result = await FileDownloadService().downloadAndSave(
            url,
            fileName: filename,
            mimeType: fileMimeType,
          );
          copiedRelativePath = result.relativePath;
          size ??= result.fileSize;
        } catch (e) {
          LoggerService().warning('Could not pre-copy local file from $url: $e',
              tag: 'GroupAgentExecutor');
        }
      }

      // Agent 产物只给 pouch:// 引用时，向储物袋取真实大小用于展示。
      if (isStoreUri && (size == null || size == 0)) {
        try {
          size = await StoreUriReader.instance.sizeOf(url);
        } catch (_) {
          // 大小拿不到就保持原值，气泡会再尝试懒解析。
        }
      }

      if ((size == null || size == 0) && isLocalPath) {
        try {
          final f = File(url);
          if (await f.exists()) size = await f.length();
        } catch (_) {}
      }

      // Extract file_id from URL (e.g. http://host/files/{file_id})
      String? fileId;
      if (!isLocalPath) {
        try {
          final uri = Uri.parse(url);
          if (uri.pathSegments.length >= 2 &&
              uri.pathSegments[uri.pathSegments.length - 2] == 'files') {
            fileId = uri.pathSegments.last;
          }
        } catch (_) {}
      }

      final isImage = fileMimeType != null && fileMimeType.startsWith('image/');
      final msgType = isImage ? MessageType.image : MessageType.file;

      final metadata = <String, dynamic>{
        'source_url': url,
        'download_status':
            copiedRelativePath != null || isStoreUri ? 'completed' : 'pending',
        'name': filename ?? 'file',
        'type': fileMimeType ?? 'application/octet-stream',
        'size': size ?? 0,
      };

      if (isStoreUri) {
        metadata['pouch_uri'] = url;
      }
      if (copiedRelativePath != null) {
        metadata['path'] = copiedRelativePath;
      }
      if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
        metadata['thumbnail_base64'] = thumbnailBase64;
      }
      if (fileId != null) {
        metadata['file_id'] = fileId;
      }

      // 毫秒时间戳 id 在同毫秒两条文件消息时冲突，改用 uuid 保证唯一。
      final messageId = 'file_${_uuid.v4()}';
      await _db.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: agentId,
        senderType: 'agent',
        senderName: agentName,
        content: isImage
            ? '[Image: ${filename ?? "image"}]'
            : '[File: ${filename ?? "file"}]',
        messageType: msgType.toString().split('.').last,
        metadata: metadata,
      );
      await _db.markMessageAsRead(messageId);
      notifyChannelUpdate(channelId);

      LoggerService().info(
          'Group file_message saved: ${filename ?? "file"} from $agentName',
          tag: 'GroupAgentExecutor');
    } catch (e) {
      LoggerService().error('Group file_message save error from $agentName',
          tag: 'GroupAgentExecutor', error: e);
    }
  }

  Future<GroupTurnResult> processGroupAgent({
    required RemoteAgent agent,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    required List<Message> historyMessages,
    required List<String> mentionedAgentIds,
    required bool isFirstMessage,
    bool isAdmin = false,
    Map<String, dynamic>? messageVersion,
    List<ChannelMember> channelMembers = const [],
    RemoteAgent? adminAgent,
    String? customSystemPrompt,
    bool isLoopSummarize = false,
    bool isAbortSummarize = false,
    bool isDispatchNudge = false,
    bool isPlanMissingNudge = false,
    bool isPendingStatusNudge = false,
    bool isPendingResolution = false,
    bool isStalledFollowUp = false,
    int? loopRound,
    bool membersConsultedThisOrchestration = true,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    List<AttachmentData>? attachments,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName, Map<String, dynamic>)?
        onMessageMetadata,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
    bool isClosingSummary = false,
    bool isWorkflowStep = false,
    String? workflowId,
    String? workflowStepId,
    String? orchestrationTraceId,
    String? orchestrationId,
    int? orchestrationRound,
    String? groupFamilyId,
    List<String> historyPinSenderIds = const [],
    MemberCapabilitySnapshot? memberProbe,
    Duration? taskTimeout,
  }) async {
    onStreamChunk?.call(
      agent.id,
      agent.name,
      '群编排已经搬到 Hub，这台设备不再编排。',
    );
    onAgentDone?.call(agent.id, agent.name, true);
    return const GroupTurnResult(
      content: '群编排已经搬到 Hub，这台设备不再编排。',
      isDone: true,
    );
  }
}
