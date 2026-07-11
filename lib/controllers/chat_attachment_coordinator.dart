import '../models/attachment_data.dart';
import '../models/message.dart';
import '../models/pending_attachment.dart';
import '../services/attachment_service.dart';

/// Result of persisting UI-pending attachments into the channel DB.
class PersistedAttachments {
  final List<Message> messages;
  final List<AttachmentData> data;

  const PersistedAttachments({
    required this.messages,
    required this.data,
  });

  bool get isEmpty => messages.isEmpty && data.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// Saves pending chat attachments via [AttachmentService].
///
/// UI list updates stay on the caller through [onMessageSaved].
class ChatAttachmentCoordinator {
  ChatAttachmentCoordinator(this._attachmentService);

  final AttachmentService _attachmentService;

  /// Persist each pending file and build sendable [AttachmentData] entries.
  ///
  /// Clipboard temp files are deleted after a successful save attempt.
  /// Oversized attachments are saved as messages but omitted from [data].
  Future<PersistedAttachments> persistPending({
    required List<PendingAttachment> pending,
    required String channelId,
    required String userId,
    required String userName,
    required String agentId,
    void Function(Message message)? onMessageSaved,
  }) async {
    if (pending.isEmpty) {
      return const PersistedAttachments(messages: [], data: []);
    }

    final savedMessages = <Message>[];
    final attachmentDataList = <AttachmentData>[];

    for (final att in pending) {
      final message = await _attachmentService.saveAttachment(
        file: att.file,
        channelId: channelId,
        userId: userId,
        userName: userName,
        agentId: agentId,
      );
      if (att.isFromClipboard) {
        try {
          att.file.deleteSync();
        } catch (_) {}
      }
      if (message == null) continue;

      savedMessages.add(message);
      onMessageSaved?.call(message);

      final attData = await _attachmentService.buildAttachmentData(message);
      if (attData != null && !attData.exceedsSizeLimit) {
        attachmentDataList.add(attData);
      }
    }

    return PersistedAttachments(
      messages: savedMessages,
      data: attachmentDataList,
    );
  }

  /// Best-effort delete of a clipboard temp file (exposed for tests / callers).
  static void deleteClipboardTempIfNeeded(PendingAttachment att) {
    if (!att.isFromClipboard) return;
    try {
      if (att.file.existsSync()) {
        att.file.deleteSync();
      }
    } catch (_) {}
  }
}
