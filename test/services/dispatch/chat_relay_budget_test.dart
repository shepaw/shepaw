import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/dispatch/dispatch_service.dart';

/// DispatchService.countConsecutiveChatRelays 纯函数测试：
/// chat 型转发的连续接力轮次预算统计。
void main() {
  group('DispatchService.countConsecutiveChatRelays', () {
    var seq = 0;
    Message msg({
      required String fromId,
      String fromType = 'user',
      Map<String, dynamic>? metadata,
    }) {
      seq++;
      return Message(
        id: 'm$seq',
        from: MessageFrom(id: fromId, type: fromType, name: fromId),
        type: MessageType.text,
        content: 'content $seq',
        // 时间升序，模拟 loadChannelMessages 的返回顺序（最旧→最新）
        timestampMs: 1700000000000 + seq,
        metadata: metadata,
      );
    }

    Message userMsg() => msg(fromId: 'local-user');
    Message sheMsg() => msg(fromId: 'she-builtin-agent-001', fromType: 'agent');
    Message relayMsg() => msg(
          fromId: DispatchService.senderId,
          metadata: const {'she_chat_relay': true},
        );
    Message dispatchResultMsg() => msg(
          fromId: DispatchService.senderId,
          metadata: const {'dispatch_result': true},
        );

    test('empty history → 0', () {
      expect(DispatchService.countConsecutiveChatRelays([]), 0);
    });

    test('no relay messages → 0', () {
      final msgs = [userMsg(), sheMsg(), userMsg(), sheMsg()];
      expect(DispatchService.countConsecutiveChatRelays(msgs), 0);
    });

    test('counts consecutive relays after last real user message', () {
      final msgs = [
        userMsg(),
        sheMsg(),
        relayMsg(),
        sheMsg(), // She 被唤起后的转述不打断计数
        relayMsg(),
      ];
      expect(DispatchService.countConsecutiveChatRelays(msgs), 2);
    });

    test('real user message resets the chain', () {
      final msgs = [
        relayMsg(),
        relayMsg(),
        userMsg(), // 用户插话 → 链中断
        sheMsg(),
        relayMsg(),
      ];
      expect(DispatchService.countConsecutiveChatRelays(msgs), 1);
    });

    test('dispatch task results neither count nor break the chain', () {
      final msgs = [
        userMsg(),
        relayMsg(),
        dispatchResultMsg(), // task 型注入：不计数、不打断
        sheMsg(),
        relayMsg(),
      ];
      expect(DispatchService.countConsecutiveChatRelays(msgs), 2);
    });

    test('system messages are skipped over', () {
      final msgs = [
        userMsg(),
        relayMsg(),
        msg(fromId: 'system', fromType: 'system'),
        relayMsg(),
      ];
      expect(DispatchService.countConsecutiveChatRelays(msgs), 2);
    });
  });
}
