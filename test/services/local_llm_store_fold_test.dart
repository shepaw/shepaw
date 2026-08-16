import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';

void main() {
  test('enrichHistoryContent strips [implicit] store tutorials', () {
    const uri = 'store://files/0123456789abcdef/docs/a.txt';
    final hint = MessageImplicitPrompt.renderStoreReadHint({uri})!;
    final m = Message(
      id: 'm1',
      from: MessageFrom(id: 'u', type: 'user', name: 'U'),
      type: MessageType.text,
      content: 'please read\n$hint',
      timestampMs: 0,
      metadata: {'store_uri': uri},
    );
    final out = LocalLLMHelpers.enrichHistoryContent(m, m.content);
    expect(out, isNot(contains('[implicit]')));
    expect(out, contains('please read'));
  });

  test('buildUserMessageContent folds URIs into Scope Card volatile', () {
    const uri = 'store://files/0123456789abcdef/docs/note.txt';
    final history = [
      Message(
        id: 'h1',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.text,
        content: 'earlier $uri',
        timestampMs: 0,
        metadata: {'store_uri': uri},
      ),
    ];
    final msg = LocalLLMHelpers.buildUserMessageContent(
      'follow up',
      null,
      false,
      historyMessages: history,
    );
    final content = msg['content'] as String;
    expect(content, contains('当前储物袋作用域 · 本轮'));
    expect(content, contains(uri));
    expect(content, isNot(contains('[implicit]')));
    expect(content, contains('follow up'));
  });
}
