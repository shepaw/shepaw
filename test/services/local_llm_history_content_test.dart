import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';

void main() {
  test('enrichHistoryContent strips [implicit] store tutorials', () {
    const uri = 'pouch://files/docs/a.txt';
    final hint = MessageImplicitPrompt.renderStoreReadHint({uri})!;
    final m = Message(
      id: 'm1',
      from: MessageFrom(id: 'u', type: 'user', name: 'U'),
      type: MessageType.text,
      content: 'please read\n$hint',
      timestampMs: 0,
      metadata: {'pouch_uri': uri},
    );
    final out = LocalLLMHelpers.enrichHistoryContent(m, m.content);
    expect(out, isNot(contains('[implicit]')));
    expect(out, contains('please read'));
  });
}
