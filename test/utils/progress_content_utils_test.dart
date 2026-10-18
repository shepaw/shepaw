import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/progress_content_utils.dart';

void main() {
  group('capProgressContent', () {
    test('短内容原样返回', () {
      expect(capProgressContent('thinking...'), 'thinking...');
    });

    test('超长内容保留头尾并插入省略标记', () {
      final head = 'A' * kProgressContentHeadChars;
      final middle = 'M' * 100000;
      final tail = 'Z' * 1000;
      final capped = capProgressContent('$head$middle$tail');

      expect(capped.length, lessThanOrEqualTo(kMaxProgressContentChars + 80));
      expect(capped, startsWith(head));
      expect(capped, endsWith(tail));
      expect(capped, contains('中间省略'));
    });
  });

  group('appendProgressContent', () {
    test('未到高水位时直接拼接', () {
      expect(appendProgressContent('abc', 'def'), 'abcdef');
    });

    test('超过高水位后裁剪一次', () {
      final big = 'x' * (kProgressContentTrimThresholdChars - 1);
      final capped = appendProgressContent(big, 'y' * 100);
      expect(capped.length, lessThanOrEqualTo(kMaxProgressContentChars + 80));
      expect(capped, contains('中间省略'));
    });

    test('裁剪后继续追加，未到高水位不再裁剪', () {
      final capped = capProgressContent('x' * 200000);
      final next = appendProgressContent(capped, 'tail');
      expect(next, endsWith('tail'));
      expect(next.length, capped.length + 4);
    });
  });
}
