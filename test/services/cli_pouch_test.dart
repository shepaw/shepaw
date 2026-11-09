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
    // 主机把口令文件丢了 / 写坏了单独报出来，App 仍走重新初始化那条恢复出口。
    expect(parsePasswordStatus('missing\n'), isFalse);
    expect(parsePasswordStatus('corrupt\n'), isFalse);
    // 不认识的输出必须留给调用方记 null，不能当成「没设过密码」。
    expect(parsePasswordStatus('password: yes\n'), isNull);
    expect(cliFailureText('tracing noise\n袋子需要一个名字\n'), '袋子需要一个名字');
    final grant = parseLoginGrant(
      '{"id":"a","name":"书房","token":"t","sid":"s","expires_at":9}\n',
    );
    expect(grant?.id, 'a');
    expect(grant?.expiresAtMs, 9);
    expect(grant?.credential, isNull, reason: '老版本 shepaw 不带凭据');
    final withCredential = parseLoginGrant(
      '{"id":"a","name":"书房","token":"t","sid":"s","expires_at":9,'
      '"credential":"cred","credential_expires_at":99}\n',
    );
    expect(withCredential?.credential, 'cred');
    expect(withCredential?.credentialExpiresAtMs, 99);
    expect(parseLoginGrant('{"id":"a","name":"书房"}\n'), isNull);
    expect(
      defaultPouchAccount(
        const [
          CliPouchAccount(id: 'a', name: '书房'),
          CliPouchAccount(id: 'b', name: '工作'),
        ],
        recentId: 'b',
      )?.id,
      'b',
    );
    expect(
      defaultPouchAccount(
        const [CliPouchAccount(id: 'a', name: '书房')],
        recentId: 'missing',
      )?.id,
      'a',
    );
  });

  test('离线建袋子的回执不是登录态', () {
    const line = '{"offline":true,"id":"p-1","name":"我的储物袋"}\n';
    final offline = parseOfflineInit(line);
    expect(offline, isA<CliPouchAccount>());
    expect(offline?.id, 'p-1');
    expect(offline?.name, '我的储物袋');
    expect(parseLoginGrant(line), isNull, reason: '别把离线回执当 grant 用');
    expect(parseOfflineInit('set\n'), isNull);
    expect(parseOfflineInit('{"id":"a","name":"b"}\n'), isNull);
    expect(parseOfflineInit('{"offline":true,"id":""}\n'), isNull);
    expect(parseOfflineInit('{"offline":true,"id":7,"name":"b"}\n'), isNull);
    expect(
      parseOfflineInit(
        '{"id":"a","name":"b","token":"t","sid":"s","expires_at":9}\n',
      ),
      isNull,
      reason: '在线 host_init 的登录态不是离线回执',
    );
  });

  test('严格解析能区分空名单和认不出的输出', () {
    expect(parsePouchAccountListOrNull('[]\n'), isEmpty);
    expect(
      parsePouchAccountListOrNull('[{"id":"a","name":"书房"}]\n'),
      hasLength(1),
    );
    // 旧 CLI / 坏掉的输出不能当成「没有袋子」，兜底会据此去重设口令。
    expect(parsePouchAccountListOrNull('set\n'), isNull);
    expect(parsePouchAccountListOrNull('shepaw 没有完成\n'), isNull);
    expect(parsePouchAccountListOrNull('{"id":"a"}\n'), isNull);
    expect(parsePouchAccountListOrNull('[not json]\n'), isNull);
    expect(parsePouchAccountListOrNull(''), isNull);
  });
}
