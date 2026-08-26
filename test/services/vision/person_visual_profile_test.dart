import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/vision/person_visual_profile.dart';

void main() {
  group('PersonVisualProfile', () {
    test('toJson/fromJson roundtrip preserves fields', () {
      const p = PersonVisualProfile(
        ageGroup: '幼儿',
        hairStyle: '短发',
        glasses: '无',
        typicalOutfit: '黄色连体衣',
        distinguishingMarks: ['鼻尖小痣'],
        commonScenes: ['客厅', '婴儿床'],
        voice: '奶声奶气',
        addressTerms: ['宝宝'],
        notes: '怕生',
      );
      final decoded = PersonVisualProfile.fromJson(p.toJson());
      expect(decoded.ageGroup, '幼儿');
      expect(decoded.hairStyle, '短发');
      expect(decoded.distinguishingMarks, ['鼻尖小痣']);
      expect(decoded.commonScenes, ['客厅', '婴儿床']);
      expect(decoded.addressTerms, ['宝宝']);
      expect(decoded.notes, '怕生');
    });

    test('encode() yields parseable JSON', () {
      const p = PersonVisualProfile(ageGroup: '青年', typicalOutfit: '白T恤');
      final decoded = parseVisualProfile(p.encode());
      expect(decoded.ageGroup, '青年');
      expect(decoded.typicalOutfit, '白T恤');
    });

    test('summarize joins non-empty fields', () {
      const p = PersonVisualProfile(
        ageGroup: '中年',
        glasses: '近视镜',
        distinguishingMarks: ['左眉疤'],
      );
      final s = p.summarize();
      expect(s, contains('年龄段 中年'));
      expect(s, contains('戴近视镜'));
      expect(s, contains('左眉疤'));
    });

    test('empty profile summarizes to empty string', () {
      expect(const PersonVisualProfile().summarize(), '');
    });
  });

  group('parseVisualProfile', () {
    test('parses bare JSON object', () {
      final p = parseVisualProfile(
          '{"ageGroup":"幼儿","hairStyle":"齐刘海","glasses":"无"}');
      expect(p.ageGroup, '幼儿');
      expect(p.hairStyle, '齐刘海');
    });

    test('strips ```json code fence', () {
      final p = parseVisualProfile('```json\n{"ageGroup":"青年"}\n```');
      expect(p.ageGroup, '青年');
    });

    test('tolerates prose before/after the JSON', () {
      final p = parseVisualProfile(
          '根据照片判断：\n{"ageGroup":"儿童","commonScenes":["公园","游乐场"]}\n以上。');
      expect(p.ageGroup, '儿童');
      expect(p.commonScenes, ['公园', '游乐场']);
    });

    test('never throws on garbage input', () {
      expect(parseVisualProfile('').ageGroup, isNull);
      expect(parseVisualProfile('完全不是 JSON').ageGroup, isNull);
      expect(parseVisualProfile('{"ageGroup": } broken').ageGroup, isNull);
    });

    test('accepts comma-separated string lists', () {
      final p = parseVisualProfile(
          '{"distinguishingMarks":"鼻尖小痣, 左耳耳钉","commonScenes":"客厅；婴儿床"}');
      expect(p.distinguishingMarks, ['鼻尖小痣', '左耳耳钉']);
      expect(p.commonScenes, ['客厅', '婴儿床']);
    });
  });
}
