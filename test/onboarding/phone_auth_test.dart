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

  test('上次进入的袋子不在名单里就补上，已有的不重复', () {
    final added = rememberPhonePouch(const [study], id: 'c', name: '公司');
    expect(added.map((pouch) => pouch.id), ['a', 'c']);
    expect(
      rememberPhonePouch(added, id: 'a', name: '书房').length,
      2,
    );
    expect(
      rememberPhonePouch(const [study], id: ' ', name: '公司'),
      [study],
    );
  });

  test('记住的袋子名单能从文本还原', () {
    final raw = PhonePouchMemory.encode(const [study, work]);
    final decoded = PhonePouchMemory.decode(raw);
    expect(decoded.map((pouch) => pouch.name), ['书房', '公司']);
    expect(PhonePouchMemory.decode('not-json'), isEmpty);
    expect(PhonePouchMemory.decode('[{"id":"","name":"书房"}]'), isEmpty);
  });
}
