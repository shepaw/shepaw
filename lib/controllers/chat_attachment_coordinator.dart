import 'dart:io';

import '../models/attachment_data.dart';
import '../models/message.dart';
import '../models/pending_attachment.dart';
import '../models/store_attachment_ref.dart';
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

/// In-memory queue of attachments staged in the chat composer.
///
/// Owns capacity checks and clipboard temp-file cleanup; Flutter `setState`
/// stays in the Screen.
class PendingAttachmentQueue {
  PendingAttachmentQueue({this.maxItems = defaultMaxItems});

  static const int defaultMaxItems = 9;

  final int maxItems;
  final List<PendingAttachment> items = [];

  bool get isEmpty => items.isEmpty;
  bool get isNotEmpty => items.isNotEmpty;
  bool get isFull => items.length >= maxItems;
  int get length => items.length;

  /// Stage a file into the queue. Returns false when the queue is full.
  Future<bool> addFromFile(
    File file, {
    bool isFromClipboard = false,
  }) async {
    if (isFull) return false;
    final attachment = await PendingAttachment.fromFile(
      file,
      isFromClipboard: isFromClipboard,
    );
    items.add(attachment);
    return true;
  }

  /// Stage a store reference (no file copy). Returns false when full or missing.
  Future<bool> addFromStoreRef(StoreAttachmentRef ref) async {
    if (isFull) return false;
    final attachment = await PendingAttachment.fromStoreRef(ref);
    if (attachment == null) return false;
    items.add(attachment);
    return true;
  }

  /// Remove a staged attachment and delete clipboard temp files.
  void remove(PendingAttachment att) {
    items.remove(att);
    ChatAttachmentCoordinator.deleteClipboardTempIfNeeded(att);
  }

  void clear({bool deleteClipboardTemps = false}) {
    if (deleteClipboardTemps) {
      for (final att in List<PendingAttachment>.from(items)) {
        ChatAttachmentCoordinator.deleteClipboardTempIfNeeded(att);
      }
    }
    items.clear();
  }
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
        storeUri: att.storeRef?.storeUri,
        displayName: att.storeRef?.displayName ?? att.fileName,
        channelId: channelId,
        userId: userId,
        userName: userName,
        agentId: agentId,
      );
      if (att.isFromClipboard) {
        deleteClipboardTempIfNeeded(att);
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
