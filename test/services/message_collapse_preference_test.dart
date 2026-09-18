import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shepaw/services/message_collapse_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults collapse history and expand latest only', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');

    expect(
      store.isCollapsed('old', defaultExpandedMessageId: 'latest'),
      isTrue,
    );
    expect(
      store.isCollapsed('latest', defaultExpandedMessageId: 'latest'),
      isFalse,
    );
    expect(
      store.isCollapsed('old', defaultExpandedMessageId: null),
      isTrue,
    );
  });

  test('toggle and persist user overrides per channel', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');

    await store.toggle('old', defaultExpandedMessageId: 'latest');
    expect(store.isCollapsed('old', defaultExpandedMessageId: 'latest'),
        isFalse);

    await store.toggle('old', defaultExpandedMessageId: 'latest');
    expect(
        store.isCollapsed('old', defaultExpandedMessageId: 'latest'), isTrue);

    await store.toggle('latest', defaultExpandedMessageId: 'latest');
    expect(
      store.isCollapsed('latest', defaultExpandedMessageId: 'latest'),
      isTrue,
    );

    final reloaded = MessageCollapsePreference();
    await reloaded.loadForChannel('ch-1');
    expect(reloaded.expandedIds, isEmpty);
    expect(reloaded.collapsedIds, containsAll(['old', 'latest']));

    await reloaded.loadForChannel('ch-2');
    expect(
      reloaded.isCollapsed('old', defaultExpandedMessageId: 'latest'),
      isTrue,
    );
  });

  test('setCollapsed records explicit expand/collapse overrides', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');

    await store.setCollapsed('m1', true);
    expect(store.isCollapsed('m1', defaultExpandedMessageId: 'm2'), isTrue);

    await store.setCollapsed('m1', false);
    expect(store.isCollapsed('m1', defaultExpandedMessageId: 'm2'), isFalse);
  });

  test('pruneTo drops missing message ids from both override sets', () async {
    final store = MessageCollapsePreference();
    await store.loadForChannel('ch-1');
    await store.setCollapsed('keep', true);
    await store.setCollapsed('gone', true);
    await store.setCollapsed('expanded', false);
    await store.pruneTo({'keep', 'expanded'});
    expect(store.isCollapsed('keep', defaultExpandedMessageId: null), isTrue);
    expect(store.isCollapsed('gone', defaultExpandedMessageId: null), isTrue);
    expect(
      store.isCollapsed('expanded', defaultExpandedMessageId: null),
      isFalse,
    );
  });
}
