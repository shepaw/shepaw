import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/cli_pouch.dart';

void main() {
  const study = CliPouchAccount(id: 'id-a', name: '书房');
  const studyAgain = CliPouchAccount(id: 'id-b', name: '书房');
  const work = CliPouchAccount(id: 'id-c', name: '工作');

  test('唯一的名字就是那只袋子', () {
    final picked = pickPouchAccount(
      typedName: ' 书房 ',
      accounts: const [study, work],
      savedId: 'id-c',
    );
    expect(picked.kind, PouchPick.found);
    expect(picked.account?.id, 'id-a');
  });

  test('同名时用上次的储物袋 ID，对不上就不猜', () {
    final saved = pickPouchAccount(
      typedName: '书房',
      accounts: const [study, studyAgain],
      savedId: 'id-b',
    );
    expect(saved.account?.id, 'id-b');

    final ambiguous = pickPouchAccount(
      typedName: '书房',
      accounts: const [study, studyAgain],
      savedId: 'id-c',
    );
    expect(ambiguous.kind, PouchPick.ambiguous);
  });

  test('解析 CLI 的 JSON 和密码状态', () {
    expect(parsePouchAccount('{"id":"a","name":"书房"}\n')?.id, 'a');
    final listed = parsePouchAccountList(
      '[{"id":"a","name":"书房"},{"id":"","name":"x"}]\n',
    );
    expect(listed, hasLength(1));
    expect(listed.single.id, 'a');
    expect(listed.single.name, '书房');
    expect(parsePasswordStatus('unset\n'), isFalse);
    expect(parsePasswordStatus('set\n'), isTrue);
    expect(cliFailureText('tracing noise\n袋子需要一个名字\n'), '袋子需要一个名字');
    final grant = parseLoginGrant(
      '{"id":"a","name":"书房","token":"t","sid":"s","expires_at":9}\n',
    );
    expect(grant?.id, 'a');
    expect(grant?.expiresAtMs, 9);
    expect(parseLoginGrant('{"id":"a","name":"书房"}\n'), isNull);
  });
}
