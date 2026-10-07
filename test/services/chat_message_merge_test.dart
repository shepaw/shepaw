import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/chat_service.dart';

void main() {
  Message text(String id, String content, int at) {
    return Message(
      id: id,
      from: MessageFrom(id: 'u', type: 'user', name: '我'),
      type: MessageType.text,
      content: content,
      timestampMs: at,
    );
  }

  test('主机没有记录时保留本机聊天', () {
    final local = [text('m1', '你好', 1), text('m2', '在', 2)];
    expect(mergeHostAndLocalMessages(local, const []), local);
  });

  test('同一回合在两边各写一行时只留本机', () {
    Message line(String id, String who, String content, int at) {
      return Message(
        id: id,
        from: MessageFrom(id: who, type: who == 'u' ? 'user' : 'agent', name: who),
        type: MessageType.text,
        content: content,
        timestampMs: at,
      );
    }

    final local = [line('local-u', 'u', 'nihao', 1000), line('local-a', 'she', '你好', 3000)];
    final host = [line('host-u', 'u', 'nihao', 1000), line('host-a', 'she', '你好', 1100)];
    final merged = mergeHostAndLocalMessages(local, host);
    expect(merged.map((message) => message.id), ['local-u', 'local-a']);
  });

  test('同一条消息不重复，主机上多出来的接在后面', () {
    final local = [text('m1', '你好', 1)];
    final host = [text('m1', '你好', 1), text('m3', '新的', 3)];
    final merged = mergeHostAndLocalMessages(local, host);
    expect(merged.map((message) => message.id), ['m1', 'm3']);
  });
}
