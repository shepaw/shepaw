import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/resume_utils.dart';

void main() {
  group('ResumeUtils.resumeToOneLine', () {
    test('returns null for null / empty / whitespace-only bio', () {
      expect(ResumeUtils.resumeToOneLine(null), isNull);
      expect(ResumeUtils.resumeToOneLine(''), isNull);
      expect(ResumeUtils.resumeToOneLine('   \n  '), isNull);
    });

    test('collapses newlines and runs of whitespace into single spaces', () {
      const bio = '负责本群测试与构建\n'
          '  能独立跑测试、修复失败用例；\n'
          '\t改动后保持构建通过。';
      final out = ResumeUtils.resumeToOneLine(bio);
      expect(out, '负责本群测试与构建 能独立跑测试、修复失败用例； 改动后保持构建通过。');
    });

    test('keeps short resume unchanged', () {
      const bio = '负责跑测试并修复失败用例';
      expect(ResumeUtils.resumeToOneLine(bio), bio);
    });

    test('truncates long resume at maxChars with ellipsis', () {
      final bio = List.filled(200, '字').join();
      final out = ResumeUtils.resumeToOneLine(bio, maxChars: 80);
      expect(out, hasLength(81)); // 80 chars + '…'
      expect(out!.endsWith('…'), isTrue);
      expect(out.substring(0, 80), bio.substring(0, 80));
    });

    test('trims leading/trailing whitespace before folding', () {
      const bio = '  \n 负责本群文件管理  \n';
      expect(ResumeUtils.resumeToOneLine(bio), '负责本群文件管理');
    });

    test('maxChars boundary: exactly maxChars chars kept without ellipsis', () {
      final bio = List.filled(80, 'a').join();
      expect(ResumeUtils.resumeToOneLine(bio, maxChars: 80), bio);
    });
  });
}
