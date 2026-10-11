import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/phone_auth_screen.dart';
import 'package:shepaw/onboarding/phone_pouch_memory.dart';
import 'package:shepaw/services/cli_pouch.dart';
import 'package:shepaw/storage/pouch_catalog.dart';

void main() {
  const study = PouchDescriptor(id: 'a', name: '书房', rootPath: '');
  const studyAgain = PouchDescriptor(id: 'b', name: '书房', rootPath: '');
  const work = PouchDescriptor(id: 'c', name: '公司', rootPath: '');

  test('刚配上的主机有一只袋子就用它，多只时认上次的', () {
    expect(choosePhonePouch(const [study])?.id, 'a');
    expect(
      choosePhonePouch(const [study, work], savedId: 'c')?.name,
      '公司',
    );
    expect(choosePhonePouch(const [study, work])?.id, 'a');
    expect(choosePhonePouch(const []), isNull);
  });

  test('名称只对上一只就用它，同名时认上次的储物袋 ID', () {
    final unique = pickPhonePouch(
      typedName: '书房',
      pouches: const [study, work],
    );
    expect(unique.kind, PouchPick.found);
    expect(unique.account?.id, 'a');

    final saved = pickPhonePouch(
      typedName: '书房',
      pouches: const [study, studyAgain],
      savedId: 'b',
    );
    expect(saved.account?.id, 'b');

    final ambiguous = pickPhonePouch(
      typedName: '书房',
      pouches: const [study, studyAgain],
      savedId: 'missing',
    );
    expect(ambiguous.kind, PouchPick.ambiguous);
  });

  test('连不上主机时用记住的袋子，主机回答了就用它的名单', () {
    expect(
      phonePouchesToShow(live: null, remembered: const [study, work]).map((p) => p.id),
      ['a', 'c'],
    );
    expect(
      phonePouchesToShow(live: const [work], remembered: const [study]).single.id,
      'c',
    );
    expect(
      phonePouchesToShow(live: const [], remembered: const [study]),
      isEmpty,
    );
  });

  test('一台主机只记一只袋子，上次进入的替换原来的', () {
    final replaced = rememberPhonePouch(const [study], id: 'c', name: '公司');
    expect(replaced.map((pouch) => pouch.id), ['c']);
    final renamed = rememberPhonePouch(const [study], id: 'a', name: '新书房');
    expect(renamed.single.id, 'a');
    expect(renamed.single.name, '新书房');
    expect(
      rememberPhonePouch(const [study], id: ' ', name: '公司'),
      [study],
    );
  });

  test('记住的袋子能从文本还原，旧数据里有多只时只留最后一只', () {
    final raw = PhonePouchMemory.encode(const [study, work]);
    final decoded = PhonePouchMemory.decode(raw);
    expect(decoded.map((pouch) => pouch.name), ['公司']);
    expect(PhonePouchMemory.decode('not-json'), isEmpty);
    expect(PhonePouchMemory.decode('[{"id":"","name":"书房"}]'), isEmpty);
  });
}
