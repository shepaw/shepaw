import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/phone_auth_screen.dart';
import 'package:shepaw/services/cli_pouch.dart';
import 'package:shepaw/storage/pouch_catalog.dart';

void main() {
  const study = PouchDescriptor(id: 'a', name: '书房', rootPath: '');
  const studyAgain = PouchDescriptor(id: 'b', name: '书房', rootPath: '');
  const work = PouchDescriptor(id: 'c', name: '公司', rootPath: '');

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
}
