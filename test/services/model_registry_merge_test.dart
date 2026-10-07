import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/model_registry.dart';

void main() {
  test('保存时不会丢掉磁盘上还在、内存里没有的模型', () {
    final merged = ModelRegistry.mergeDefinitionJson(
      stored: [
        {'id': 'old', 'display_name': 'kimi'},
        {'id': 'gone', 'display_name': 'removed'},
      ],
      memory: [
        {'id': 'new', 'display_name': 'flash'},
        {'id': 'old', 'display_name': 'kimi-renamed'},
      ],
      deletedIds: {'gone'},
    );
    final byId = {for (final item in merged) item['id']: item['display_name']};
    expect(byId['old'], 'kimi-renamed');
    expect(byId['new'], 'flash');
    expect(byId.containsKey('gone'), isFalse);
  });
}
