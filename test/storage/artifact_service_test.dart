import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/artifact_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// 产物 URI 与 artifact_service（docs/storage_space_plan.md §6.3）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  group('ArtifactUri', () {
    test('构造/解析往返', () {
      final uri = ArtifactUri(
          deviceId: '0123456789abcdef',
          taskId: 'task-41',
          filename: 'report.md');
      final text = uri.toString();
      expect(text, 'store://artifacts/0123456789abcdef/task-41/report.md');
      final parsed = ArtifactUri.tryParse(text)!;
      expect(parsed.deviceId, uri.deviceId);
      expect(parsed.taskId, uri.taskId);
      expect(parsed.filename, uri.filename);
      expect(parsed.storePath, 'task-41/report.md');
    });

    test('非法 URI 拒绝', () {
      for (final bad in [
        'http://artifacts/0123456789abcdef/t/f',
        'store://files/0123456789abcdef/t/f', // 非 artifacts
        'store://artifacts/not-a-device/t/f',
        'store://artifacts/0123456789abcdef/t', // 缺文件名
        'store://artifacts/0123456789abcdef/t/../x',
        '',
      ]) {
        expect(ArtifactUri.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('ArtifactService 写入/读取/引用', () {
    test('writeArtifact 经 store 落盘并返回单行 Markdown 引用', () async {
      final content = Uint8List.fromList(utf8.encode('# Q2 销售报告\n'));
      final ref = await ArtifactService.instance.writeArtifact(
        taskId: 'task-m5',
        filename: 'report.md',
        content: content,
        description: 'Q2 销售报告，markdown',
        producer: 'codebot',
      );

      // 引用格式：单行 Markdown 链接 + 描述（§6.3）
      expect(ref, startsWith('[report.md](store://artifacts/'));
      expect(ref, contains('/task-m5/report.md)'));
      expect(ref, contains('— Q2 销售报告，markdown'));
      expect(ref, contains('codebot 产出'));
      expect(ref.contains('\n'), isFalse);

      // 本机可读回（内容一致）
      final uri =
          ArtifactService.instance.parseReferences(ref).single.uri.toString();
      final back = await ArtifactService.instance.readArtifact(uri);
      expect(back, content);
    });

    test('parseReferences 提取多个引用', () {
      const text = '''
上游产物：
- [report.md](store://artifacts/0123456789abcdef/task-41/report.md) — Q2 报告，12KB
- [data.csv](store://artifacts/fedcba9876543210/task-42/data.csv)
普通链接 [example](https://example.com) 不算。
''';
      final refs = ArtifactService.instance.parseReferences(text);
      expect(refs.length, 2);
      expect(refs[0].uri.deviceId, '0123456789abcdef');
      expect(refs[0].description, 'Q2 报告，12KB');
      expect(refs[1].uri.taskId, 'task-42');
    });

    test('buildAvailableArtifactsSection 生成注入片段', () {
      final refs = ArtifactService.instance.parseReferences(
          '[report.md](store://artifacts/0123456789abcdef/task-41/report.md) — Q2 报告');
      final section =
          ArtifactService.instance.buildAvailableArtifactsSection(refs);
      expect(section, startsWith('## 可用产物\n'));
      expect(section, contains('- [report.md]'));
      expect(section, contains('shepaw store write'));
      expect(section, contains('勿默认写 OS 路径'));
      expect(section, contains('shepaw store read'));
      expect(
          ArtifactService.instance.buildAvailableArtifactsSection(const []),
          isEmpty);
    });

    test('mergeReferenceLines 去重累积引用行', () {
      final lines = <String>[];
      const ref =
          '[a.md](store://artifacts/0123456789abcdef/task-41/a.md) — desc';
      ArtifactService.instance.mergeReferenceLines(lines, ref);
      ArtifactService.instance.mergeReferenceLines(lines, ref);
      expect(lines.length, 1);
      expect(lines.single, ref);
    });

    test('truncateStepSummary 超长时保留 store 引用行', () {
      final longBody = 'x' * 600;
      const ref =
          '[report.md](store://artifacts/0123456789abcdef/task-41/report.md)';
      final output = '$longBody\n$ref';
      final summary =
          ArtifactService.instance.truncateStepSummary(output, maxLen: 500);
      expect(summary.length, lessThanOrEqualTo(500));
      expect(summary, contains('store://artifacts/'));
      expect(summary, contains('report.md'));
    });

    test('filename 路径穿越防护', () async {
      final ref = await ArtifactService.instance.writeArtifact(
        taskId: 'task-x',
        filename: '../../../etc/evil.txt',
        content: Uint8List.fromList([1]),
      );
      // 只保留 basename
      expect(ref, contains('/task-x/evil.txt'));
    });
  });

  group('写入覆盖：同名产物新版覆盖、引用 URI 稳定', () {
    test('同 task+filename 重写后读取为新版', () async {
      final v1 = Uint8List.fromList(utf8.encode('v1'));
      final v2 = Uint8List.fromList(utf8.encode('v2!!'));
      final ref1 = await ArtifactService.instance.writeArtifact(
          taskId: 'task-ov', filename: 'a.txt', content: v1);
      final ref2 = await ArtifactService.instance.writeArtifact(
          taskId: 'task-ov', filename: 'a.txt', content: v2);
      // URI 稳定（last-write-wins，内容更新）
      expect(ArtifactService.instance.parseReferences(ref2).single.uri
          .toString(), ArtifactService.instance.parseReferences(ref1).single.uri.toString());
      final back = await ArtifactService.instance.readArtifact(
          ArtifactService.instance.parseReferences(ref2).single.uri.toString());
      expect(back, v2);
    });
  });
}
