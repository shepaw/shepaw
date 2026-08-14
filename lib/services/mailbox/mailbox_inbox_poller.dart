/// Poll cloud inbox for stream chunks + final reply (typewriter + dedup).
library;

import 'dart:async';

import '../logger_service.dart';
import '../noise_identity.dart';
import 'channel_mailbox_service.dart';
import 'mailbox_seal.dart';

/// Result of a completed inbox turn.
class MailboxInboxTurnResult {
  MailboxInboxTurnResult({
    required this.content,
    required this.requestId,
    required this.sessionId,
    this.groupId,
  });

  final String content;
  final String requestId;
  final String sessionId;
  final String? groupId;
}

/// Tracks processed inbox entries and stream sequence to prevent duplicates.
class MailboxInboxDeduper {
  final Set<String> _seenEntryIds = {};
  final Map<String, int> _lastSeqByRequest = {};

  bool markEntry(String mailboxEntryId) {
    return _seenEntryIds.add(mailboxEntryId);
  }

  /// Returns true if [seq] is new and should be applied.
  bool acceptStreamSeq(String requestId, int seq) {
    final last = _lastSeqByRequest[requestId] ?? 0;
    if (seq <= last) return false;
    _lastSeqByRequest[requestId] = seq;
    return true;
  }
}

/// Poll `/inbox/replies` until final reply for [requestId] / [userMessageId].
class MailboxInboxPoller {
  MailboxInboxPoller({ChannelMailboxService? mailbox})
      : _mailbox = mailbox ?? ChannelMailboxService();

  final ChannelMailboxService _mailbox;

  static const defaultPollInterval = Duration(milliseconds: 350);
  static const defaultTimeout = Duration(minutes: 10);

  Future<MailboxInboxTurnResult> pollUntilComplete({
    required String channelBase,
    required String agentId,
    required String callerFp,
    required String userMessageId,
    required String requestId,
    required String sessionId,
    void Function(String delta)? onStreamChunk,
    Duration pollInterval = defaultPollInterval,
    Duration timeout = defaultTimeout,
    MailboxInboxDeduper? deduper,
  }) async {
    final identity = await NoiseIdentity.loadOrCreate();
    final dedup = deduper ?? MailboxInboxDeduper();
    final ackIds = <String>[];
    final buffer = StringBuffer();
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final replies = await _mailbox.fetchInboxReplies(
        channelBase: channelBase,
        callerFp: callerFp,
        limit: 100,
      );

      replies.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      for (final reply in replies) {
        if (!_matchesTurn(reply, userMessageId, requestId, agentId)) {
          continue;
        }
        if (!dedup.markEntry(reply.id)) {
          continue;
        }

        try {
          final payload = await mailboxOpenJson(
            reply.ciphertext,
            identity.privateKey,
          );
          final kind = payload['kind']?.toString() ?? reply.kind;
          final isFinal = payload['is_final'] == true || kind == 'chat';

          if (kind == 'stream' && !isFinal) {
            final seq = (payload['seq'] as num?)?.toInt() ?? 0;
            if (!dedup.acceptStreamSeq(requestId, seq)) {
              ackIds.add(reply.id);
              continue;
            }
            final delta = payload['delta']?.toString() ?? '';
            if (delta.isNotEmpty) {
              buffer.write(delta);
              onStreamChunk?.call(delta);
            }
            ackIds.add(reply.id);
            continue;
          }

          if (isFinal) {
            final content = payload['content']?.toString() ?? '';
            if (content.isNotEmpty) {
              // Final may repeat full text; prefer longer / non-empty.
              if (content.length >= buffer.length) {
                final extra = content.substring(buffer.length);
                if (extra.isNotEmpty) {
                  onStreamChunk?.call(extra);
                }
                buffer.clear();
                buffer.write(content);
              }
            }
            ackIds.add(reply.id);
            if (ackIds.isNotEmpty) {
              await _mailbox.ackInboxReplies(
                channelBase: channelBase,
                callerFp: callerFp,
                ids: ackIds,
              );
            }
            return MailboxInboxTurnResult(
              content: buffer.toString(),
              requestId: payload['request_id']?.toString() ?? requestId,
              sessionId: payload['session_id']?.toString() ??
                  reply.sessionId.ifEmpty(sessionId),
              groupId: payload['group_id']?.toString() ?? reply.groupId,
            );
          }

          // Legacy single-shot reply (no kind / is_final)
          final legacy = payload['content']?.toString() ?? '';
          if (legacy.isNotEmpty) {
            buffer.write(legacy);
            onStreamChunk?.call(legacy);
          }
          ackIds.add(reply.id);
          await _mailbox.ackInboxReplies(
            channelBase: channelBase,
            callerFp: callerFp,
            ids: ackIds,
          );
          return MailboxInboxTurnResult(
            content: buffer.toString(),
            requestId: requestId,
            sessionId: reply.sessionId.ifEmpty(sessionId),
            groupId: reply.groupId,
          );
        } catch (e) {
          LoggerService().warning(
            'MailboxInboxPoller: skip reply ${reply.id}: $e',
            tag: 'Mailbox',
          );
          // Do not ack — allow retry
        }
      }

      await Future<void>.delayed(pollInterval);
    }

    if (ackIds.isNotEmpty) {
      await _mailbox.ackInboxReplies(
        channelBase: channelBase,
        callerFp: callerFp,
        ids: ackIds,
      );
    }
    throw TimeoutException('Inbox reply timed out for request $requestId');
  }

  bool _matchesTurn(
    MailboxReply reply,
    String userMessageId,
    String requestId,
    String agentId,
  ) {
    if (reply.targetId.isNotEmpty && reply.targetId != agentId) {
      return false;
    }
    if (reply.requestId == requestId) return true;
    if (reply.replyTo == userMessageId) return true;
    return false;
  }
}

extension _StringEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
