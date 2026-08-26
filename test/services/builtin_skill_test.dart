import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 守护内置技能「ShePaw App Usage Guide」的格式与完整性。
///
/// 该技能在 AppBootstrap._seedBuiltinSkills() 启动时从 assets 复制进技能目录，
/// 因此必须始终满足 SkillRegistry 对 SKILL.md 的解析要求：front matter 含
/// name/description，且正文分层齐全。这里用仓库内文件直接校验（不依赖插件）。
void main() {
  final skillFile = File(
    p.join('assets', 'skills', 'app-usage-guide', 'SKILL.md'),
  );

  group('built-in skill: ShePaw App Usage Guide', () {
    test('SKILL.md 存在于 assets', () {
      expect(skillFile.existsSync(), isTrue,
          reason: 'assets/skills/app-usage-guide/SKILL.md 应被打包为内置技能');
    });

    test('front matter 含 name 与 description，且可被 SkillRegistry 解析', () {
      final content = skillFile.readAsStringSync();
      final lines = content.split('\n');

      expect(lines.first.trim(), '---',
          reason: 'SKILL.md 必须以 YAML front matter 开头');
      expect(content, contains('name:'));
      expect(content, contains('description:'));

      // 找到闭合的 ---，且只在前几行（front matter 应很简短）
      final closing = lines.indexWhere((l) => l.trim() == '---', 1);
      expect(closing, greaterThan(0));
      expect(closing, lessThan(10),
          reason: 'front matter 应只含 name/description 两个标量字段');
    });

    test('front matter 的 name 经 _sanitizeName 得到预期 tool name', () {
      final content = skillFile.readAsStringSync();
      final nameMatch =
          RegExp(r'^name:\s*(.+)$', multiLine: true).firstMatch(content);
      expect(nameMatch, isNotNull, reason: 'front matter 必须含 name');
      final name = nameMatch!.group(1)!.trim();

      // 与 SkillRegistry._sanitizeName 保持一致（见 lib/services/skill_registry.dart）
      final sanitized = name
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
      expect('skill_$sanitized', 'skill_shepaw_app_usage_guide');
    });

    test('正文充分且分层齐全（0~6 层标题都在）', () {
      final content = skillFile.readAsStringSync();

      expect(content.length, greaterThan(2000),
          reason: '技能正文应有足够内容支撑 She 教用户使用系统');

      for (final heading in [
        '## 0. 本技能使用说明',
        '## 1. 系统总览',
        '## 2. 用户操作层',
        '## 3. 工具能力层',
        '## 4. 基础设施层',
        '## 5. 排障与 FAQ',
        '## 6. 参考资源索引',
      ]) {
        expect(content, contains(heading),
            reason: '缺少分层标题: $heading');
      }
    });
  });
}
