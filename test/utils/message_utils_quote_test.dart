import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/utils/message_utils.dart';

Message _msg(String id) => Message(
      id: id,
      from: MessageFrom(id: 'agent', type: 'agent', name: 'agent'),
      type: MessageType.text,
      content: id,
      timestampMs: 100,
    );

void main() {
  group('MessageUtils.quotedMessageFor', () {
    test('精确命中时返回那一行', () {
      final map = {'u1': _msg('u1')};
      expect(MessageUtils.quotedMessageFor(map, 'u1')?.id, 'u1');
    });

    test('库里是 peerhist_ 形态、引用记的是裸 id', () {
      // 本机乐观行被主机回放行重键之后，助手回复行上的裸 id 引用还留着。
      final map = {'peerhist_u1': _msg('peerhist_u1')};
      expect(MessageUtils.quotedMessageFor(map, 'u1')?.id, 'peerhist_u1');
    });

    test('库里是裸 id、引用记的是 peerhist_ 形态', () {
      final map = {'u1': _msg('u1')};
      expect(MessageUtils.quotedMessageFor(map, 'peerhist_u1')?.id, 'u1');
    });

    test('两边都没有时返回 null（气泡出「原消息不可用」）', () {
      final map = {'peerhist_u1': _msg('peerhist_u1')};
      expect(MessageUtils.quotedMessageFor(map, 'gone'), isNull);
    });

    test('空引用不算引用', () {
      expect(MessageUtils.quotedMessageFor({'u1': _msg('u1')}, null), isNull);
      expect(MessageUtils.quotedMessageFor({'u1': _msg('u1')}, '  '), isNull);
    });
  });
}
