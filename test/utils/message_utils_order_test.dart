import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/utils/message_utils.dart';

Message _msg(String id, int ts, {String? replyTo}) {
  return Message(
    id: id,
    from: MessageFrom(id: 'agent', type: 'agent', name: 'agent'),
    type: MessageType.text,
    content: id,
    timestampMs: ts,
    replyTo: replyTo,
  );
}

List<String> _ids(List<Message> messages) =>
    messages.map((m) => m.id).toList(growable: false);

void main() {
  group('MessageUtils.orderForDisplay', () {
    test('顺序已正确时返回同一实例', () {
      final messages = [_msg('a', 100), _msg('b', 200)];
      expect(identical(MessageUtils.orderForDisplay(messages), messages), isTrue);
    });

    test('时间戳过期的回复被移到被回复消息之后', () {
      // 用户 09:17 引用提问，agent 回复沿用了上一回合的旧时间戳。
      final messages = [
        _msg('reply', 100, replyTo: 'ask'),
        _msg('other', 150),
        _msg('ask', 200),
      ];
      expect(_ids(MessageUtils.orderForDisplay(messages)), [
        'other',
        'ask',
        'reply',
      ]);
    });

    test('窗口内容一致时 sameDisplayWindow 为真', () {
      final current = [_msg('a', 100), _msg('b', 200)];
      final incoming = [_msg('a', 100), _msg('b', 200)];
      expect(MessageUtils.sameDisplayWindow(current, incoming), isTrue);
      incoming[1] = _msg('b', 201);
      expect(MessageUtils.sameDisplayWindow(current, incoming), isFalse);
    });

    test('展示顺序缓存复用原列表，并看到被替换的流式对象', () {
      final memo = DisplayOrderMemo();
      final messages = [_msg('a', 100), _msg('b', 200)];
      expect(
        identical(memo.apply(messages, streamingIds: {'b'}), messages),
        isTrue,
      );

      final replacement = _msg('b', 200);
      messages[1] = replacement;
      final again = memo.apply(messages, streamingIds: {'b'});
      expect(identical(again, messages), isTrue);
      expect(identical(again.last, replacement), isTrue);
    });

    test('展示顺序缓存在结构不变时仍按上次的排列取当前对象', () {
      final memo = DisplayOrderMemo();
      final messages = [
        _msg('reply', 100, replyTo: 'ask'),
        _msg('ask', 200),
      ];
      expect(_ids(memo.apply(messages)), ['ask', 'reply']);

      final replacement = _msg('reply', 100, replyTo: 'ask');
      messages[0] = replacement;
      final again = memo.apply(messages);
      expect(_ids(again), ['ask', 'reply']);
      expect(identical(again.last, replacement), isTrue);
    });

    test('在途流式气泡排到最末', () {
      final messages = [
        _msg('streaming', 100),
        _msg('older', 200),
        _msg('newest', 300),
      ];
      expect(
        _ids(MessageUtils.orderForDisplay(messages, streamingIds: {'streaming'})),
        ['older', 'newest', 'streaming'],
      );
    });

    test('流式气泡已在末尾时不做重排', () {
      final messages = [_msg('older', 200), _msg('streaming', 300)];
      expect(
        identical(
          MessageUtils.orderForDisplay(messages, streamingIds: {'streaming'}),
          messages,
        ),
        isTrue,
      );
    });

    test('replyTo 成环时不会栈溢出', () {
      final messages = [
        _msg('a', 200, replyTo: 'b'),
        _msg('b', 100, replyTo: 'a'),
      ];
      // 成环时递归在首个自引用处止住，各条退回自身时间戳（b 更早仍在前）。
      expect(_ids(MessageUtils.orderForDisplay(messages)), ['b', 'a']);
    });

    test('引用链按层级递推', () {
      final messages = [
        _msg('c', 10, replyTo: 'b'),
        _msg('b', 20, replyTo: 'a'),
        _msg('a', 300),
      ];
      expect(_ids(MessageUtils.orderForDisplay(messages)), ['a', 'b', 'c']);
    });
  });
}
