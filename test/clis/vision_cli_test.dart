import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';
import 'package:shepaw/clis/shepaw/vision/vision_namespace.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/vision/person_visual_profile.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/vision/debug_face_embedding_engine.dart';
import 'package:shepaw/services/vision/reference_album_service.dart';
import 'package:shepaw/services/vision/veda_face_store.dart';
import 'package:shepaw/services/vision/visual_profile_extractor.dart';

import '../storage/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late int run;

  Future<ReferenceAlbumService> _makeService() async {
    final vectors = await VedaFaceStore.open(dimension: 192);
    return ReferenceAlbumService(
      vectors: vectors,
      engine: const DebugFaceEmbeddingEngine(),
      profileBuilder: _StubProfileBuilder(),
    );
  }

  setUpAll(() async {
    tmpDir = await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  setUp(() async {
    run = DateTime.now().microsecondsSinceEpoch;
    await LocalDatabaseService().clearFaceAlbum();
    VisionNamespace.instance.albumServiceOverride =
        await _makeService();
  });

  tearDown(() {
    // 避免 override 泄漏到后续用例
    VisionNamespace.instance.albumServiceOverride = null;
  });

  Future<Map<String, dynamic>> runCli(
    String subcommand, {
    Map<String, String> flags = const {},
  }) async {
    final raw = await ShepawCLI.instance.execute({
      'namespace': 'vision',
      'subcommand': subcommand,
      'flags': flags,
    });
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<File> writeImage(int seed) async {
    final file = File(
        '${tmpDir.path}/face_cli_${run}_$seed.jpg');
    await file.writeAsBytes(
        Uint8List.fromList([seed, seed + 1, seed + 2, seed + 3, seed + 4]));
    return file;
  }

  group('shepaw vision CLI', () {
    test('status reports debug engine + empty album', () async {
      final result = await runCli('status');
      expect(result['ok'], isTrue);
      final engine = result['engine'] as Map<String, dynamic>;
      expect(engine['id'], 'debug');
      expect(engine['is_debug'], isTrue);
      expect(engine['available'], isTrue);
      final album = result['album'] as Map<String, dynamic>;
      expect(album['person_count'], 0);
    });

    test('album.enroll → album.list round-trip', () async {
      final img = await writeImage(1);
      final enrolled = await runCli('album.enroll', flags: {
        'person': '妈妈',
        'image': img.path,
        'relationship': '妈妈',
        'caption': '客厅基准照',
      });
      expect(enrolled['ok'], isTrue);
      expect(enrolled['person_name'], '妈妈');
      expect(enrolled['total_photos_for_person'], 1);
      expect(enrolled['engine'], 'debug');

      final listed = await runCli('album.list');
      expect(listed['person_count'], 1);
      final persons = listed['persons'] as List;
      expect((persons.first as Map)['name'], '妈妈');
      expect((persons.first as Map)['photo_count'], 1);
    });

    test('recognize identifies an enrolled person', () async {
      final img = await writeImage(2);
      await runCli('album.enroll', flags: {
        'person': '丁丹',
        'image': img.path,
      });

      final result = await runCli('recognize', flags: {
        'image': img.path,
      });
      expect(result['ok'], isTrue);
      expect(result['face_count'], 1);
      final faces = result['faces'] as List;
      final face = faces.first as Map<String, dynamic>;
      expect(face['status'], 'recognized');
      final candidates = face['candidates'] as List;
      expect(candidates, isNotEmpty);
      expect((candidates.first as Map)['person_name'], '丁丹');
    });

    test('recognize on unknown face → unknown, no candidates', () async {
      final img = await writeImage(99);
      final result = await runCli('recognize', flags: {
        'image': img.path,
      });
      expect(result['ok'], isTrue);
      final faces = result['faces'] as List;
      final face = faces.first as Map<String, dynamic>;
      expect(face['status'], 'unknown');
      expect(face['candidates'], isEmpty);
    });

    test('album.remove deletes the person', () async {
      final img = await writeImage(3);
      final name = '孴宝$run';
      await runCli('album.enroll', flags: {
        'person': name,
        'image': img.path,
      });

      final removed = await runCli('album.remove', flags: {
        'person': name,
      });
      expect(removed['ok'], isTrue);
      expect((removed['removed'] as Map)['name'], name);

      final listed = await runCli('album.list');
      expect(listed['person_count'], 0);
    });

    test('album.remove with unknown person returns error', () async {
      final result =
          await runCli('album.remove', flags: {'person': 'nobody'});
      expect(result['ok'], isFalse);
      expect(result['error'] as String, contains('not found'));
    });

    test('album.enroll missing --person returns error', () async {
      final img = await writeImage(4);
      final result = await runCli('album.enroll', flags: {
        'image': img.path,
      });
      expect(result['ok'], isFalse);
      expect(result['error'] as String, contains('--person'));
    });

    test('profile.get returns stored profile; build refreshes it', () async {
      final img = await writeImage(5);
      final name = '妈妈$run';
      await runCli('album.enroll', flags: {
        'person': name,
        'image': img.path,
      });

      final before = await runCli('profile.get', flags: {'person': name});
      expect(before['has_profile'], isFalse);

      final built = await runCli('profile.build', flags: {'person': name});
      expect(built['ok'], isTrue);
      expect((built['profile'] as Map)['ageGroup'], '儿童');

      final after = await runCli('profile.get', flags: {'person': name});
      expect(after['has_profile'], isTrue);
      expect(after['summary'] as String, contains('儿童'));
    });
  });
}

/// 测试用档案 stub：直接返回固定档案，不调用 LLM。
class _StubProfileBuilder implements VisualProfileBuilder {
  @override
  Future<PersonVisualProfile> extract({
    required String personName,
    required List<AttachmentData> photos,
  }) async {
    return PersonVisualProfile(
      ageGroup: '儿童',
      hairStyle: '齐刘海',
      notes: 'stub：$personName（${photos.length} 张参考照）',
    );
  }
}
