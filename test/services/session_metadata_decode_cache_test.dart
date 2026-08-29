import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/session/session_history_service.dart';

void main() {
  group('MetadataDecodeCache', () {
    test('null 原文直接返回 null，不进缓存', () {
      final cache = MetadataDecodeCache();
      expect(cache.decode(null, 'm1'), isNull);
      expect(cache.length, 0);
    });

    test('合法 JSON 解码为 Map', () {
      final cache = MetadataDecodeCache();
      final r = cache.decode('{"a":1}', 'm1');
      expect(r, {'a': 1});
    });

    test('相同 (messageId, raw) 命中缓存，返回同一实例', () {
      final cache = MetadataDecodeCache();
      final first = cache.decode('{"a":1}', 'm1');
      final second = cache.decode('{"a":1}', 'm1');
      expect(identical(first, second), isTrue);
    });

    test('messageId 不同则键不同，各自解码', () {
      final cache = MetadataDecodeCache();
      final a = cache.decode('{"a":1}', 'm1');
      final b = cache.decode('{"a":1}', 'm2');
      expect(identical(a, b), isFalse);
      expect(cache.length, 2);
    });

    test('坏 JSON 返回 null 并缓存（不重复抛解析）', () {
      final cache = MetadataDecodeCache();
      expect(cache.decode('{oops', 'm1'), isNull);
      expect(cache.decode('{oops', 'm1'), isNull);
      expect(cache.length, 1);
    });

    test('解码结果解码为 List 顶层时回退为 null', () {
      final cache = MetadataDecodeCache();
      expect(cache.decode('[1,2]', 'm1'), isNull);
    });

    test('LRU 驱逐：超过上限淘汰最旧条目', () {
      final cache = MetadataDecodeCache();
      // 上限 500：塞 501 条，第一条应被淘汰。
      for (var i = 0; i < 501; i++) {
        cache.decode('{"i":$i}', 'm$i');
      }
      expect(cache.length, 500);
      expect(cache.decode('{"i":0}', 'm0'), {'i': 0}); // 已被驱逐，重新解码
    });

    test('LRU touch：命中条目不会被驱逐', () {
      final cache = MetadataDecodeCache();
      cache.decode('{"keep":true}', 'keep');
      // 反复填满并访问 keep，使其始终保持最新。
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 500; i++) {
          cache.decode('{"r":$round,"i":$i}', 'r$round-i$i');
          cache.decode('{"keep":true}', 'keep');
        }
      }
      final keep = cache.decode('{"keep":true}', 'keep');
      expect(keep, {'keep': true});
      expect(cache.length, lessThanOrEqualTo(500));
    });

    test('与 jsonDecode 语义一致（嵌套结构）', () {
      final cache = MetadataDecodeCache();
      final raw = jsonEncode({
        'workflow': {'id': 'wf1', 'steps': [1, 2, 3]},
        'flags': [true, false],
      });
      expect(cache.decode(raw, 'm1'), jsonDecode(raw));
    });
  });
}
