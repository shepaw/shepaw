import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/phone_auth_screen.dart';
import 'package:shepaw/storage/pouch_catalog.dart';

void main() {
  const first = PouchDescriptor(id: 'a', name: '书房', rootPath: '');
  const second = PouchDescriptor(id: 'b', name: '公司', rootPath: '');

  test('已有袋子时不新建，优先用上次登录的那只', () {
    expect(chooseExistingPouch(const []), isNull);
    expect(chooseExistingPouch(const [first, second])?.id, 'a');
    expect(
      chooseExistingPouch(const [first, second], preferredId: 'b')?.id,
      'b',
    );
    expect(
      chooseExistingPouch(const [first], preferredId: 'missing')?.id,
      'a',
    );
  });
}
