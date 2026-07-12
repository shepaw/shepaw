import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shepaw/services/message_collapse_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('toggle and persist collapsed ids per channel', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');
    expect(store.isCollapsed('m1'), isFalse);

    await store.toggle('m1');
    expect(store.isCollapsed('m1'), isTrue);

    await store.toggle('m1');
    expect(store.isCollapsed('m1'), isFalse);

    await store.setCollapsed('m2', true);
    await store.setCollapsed('m3', true);

    final reloaded = MessageCollapsePreference();
    await reloaded.loadForChannel('ch-1');
    expect(reloaded.isCollapsed('m2'), isTrue);
    expect(reloaded.isCollapsed('m3'), isTrue);

    await reloaded.loadForChannel('ch-2');
    expect(reloaded.isCollapsed('m2'), isFalse);
  });

  test('pruneTo drops missing message ids', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');
    await store.setCollapsed('keep', true);
    await store.setCollapsed('gone', true);
    await store.pruneTo({'keep'});
    expect(store.isCollapsed('keep'), isTrue);
    expect(store.isCollapsed('gone'), isFalse);
  });
}
