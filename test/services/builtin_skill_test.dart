import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 守护内置技能「ShePaw App Usage Guide」的格式与完整性。
///
/// 该技能是**目录包**：`SKILL.md` 为入口与索引，第 2~6 层正文在
/// `references/` 下。AppBootstrap._seedBuiltinSkills() 启动时用 AssetManifest
/// 枚举整个目录物化后以 importSkillDirectory 导入，运行期 readSkillContent
/// 会把 SKILL.md（在前）+ references/*.md（按路径排序）拼接成全文喂给 She。
/// 因此这里校验：目录结构齐全、front matter 可被 SkillRegistry 解析、拼接后
/// 分层齐全。用仓库内文件直接校验（不依赖插件）。
void main() {
  final skillDir = Directory(
    p.join('assets', 'skills', 'app-usage-guide'),
  );
  final skillFile = File(p.join(skillDir.path, 'SKILL.md'));
  final referencesDir = Directory(p.join(skillDir.path, 'references'));

  group('built-in skill: ShePaw App Usage Guide', () {
    test('目录结构：SKILL.md + references/ 5 个正文文件齐全', () {
      expect(skillDir.existsSync(), isTrue,
          reason: 'assets/skills/app-usage-guide/ 应存在');
      expect(skillFile.existsSync(), isTrue,
          reason: 'SKILL.md 应作为入口与索引存在');
      expect(referencesDir.existsSync(), isTrue,
          reason: 'references/ 目录应存在');

      final refs = referencesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => p.relative(a.path, from: referencesDir.path)
            .compareTo(p.relative(b.path, from: referencesDir.path)));
      final relNames = refs.map((f) => p.relative(f.path, from: referencesDir.path)).toList();
      expect(relNames, [
        '02-user-operations.md',
        '03-shepaw-cli.md',
        '04-ecosystem-infra.md',
        '05-troubleshooting.md',
        '06-resources.md',
      ], reason: 'references/ 应恰好包含第 2~6 层的 5 个正文文件');
    });

    test('SKILL.md front matter 含 name 与 description，且可被 SkillRegistry 解析', () {
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

    test('SKILL.md 作为入口：含使用说明、系统总览与内容导航表', () {
      final content = skillFile.readAsStringSync();

      expect(content, contains('## 0. 本技能使用说明'));
      expect(content, contains('## 1. 系统总览'));
      expect(content, contains('## 内容导航'),
          reason: 'SKILL.md 应含内容导航表，指引 She 按问题定位 references/ 文件');
      for (final ref in [
        '02-user-operations.md',
        '03-shepaw-cli.md',
        '04-ecosystem-infra.md',
        '05-troubleshooting.md',
        '06-resources.md',
      ]) {
        expect(content, contains(ref),
            reason: '内容导航表应提及 references/$ref');
      }
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

    test('拼接全文（SKILL.md + references/*.md）分层齐全且内容充分', () {
      // 与 readSkillContent 的拼接规则一致：SKILL.md 在前，其余按相对路径排序
      final refs = referencesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => p.relative(a.path, from: referencesDir.path)
            .compareTo(p.relative(b.path, from: referencesDir.path)));

      final parts = <String>[skillFile.readAsStringSync()];
      for (final ref in refs) {
        final rel = p.relative(ref.path, from: skillDir.path);
        parts.add('<!-- ===== $rel ===== -->\n${ref.readAsStringSync()}');
      }
      final joined = parts.join('\n\n');

      expect(joined.length, greaterThan(4000),
          reason: '拼接全文应有足够内容支撑 She 教用户使用系统');

      // 每个 references 文件以对应层级标题开头（02→第 2 层 … 06→第 6 层）
      final layerHeadings = [
        '## 2. 用户操作层',
        '## 3. 工具能力层',
        '## 4. 基础设施层',
        '## 5. 排障与 FAQ',
        '## 6. 参考资源索引',
      ];
      expect(refs.length, layerHeadings.length);
      for (var i = 0; i < refs.length; i++) {
        final rel = p.relative(refs[i].path, from: skillDir.path);
        expect(refs[i].readAsStringSync().trimLeft().startsWith(layerHeadings[i]),
            isTrue,
            reason: '$rel 应以 "${layerHeadings[i]}" 标题开头');
      }

      // 拼接后 0~6 层标题都在
      for (final heading in [
        '## 0. 本技能使用说明',
        '## 1. 系统总览',
        '## 2. 用户操作层',
        '## 3. 工具能力层',
        '## 4. 基础设施层',
        '## 5. 排障与 FAQ',
        '## 6. 参考资源索引',
      ]) {
        expect(joined, contains(heading),
            reason: '拼接全文缺少分层标题: $heading');
      }
    });
  });
}
