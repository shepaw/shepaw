import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/remote_agent_service.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/services/token_service.dart';
import 'package:shepaw/services/vision/visual_profile_extractor.dart';

import '../../storage/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  /// 一个未配置 apiBase 的非本地 agent：supportsModality(image)=true，
  /// 但走真实 LLM 链路时会在发出请求前抛出（apiBase 为空），
  /// 从而以无网络的方式验证「LLM 失败被吞掉 → 空档案」路径。
  RemoteAgent _stubVisualAgent() => RemoteAgent(
        id: SheService.sheId,
        name: 'She',
        token: 'test-token',
        endpoint: '',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        createdAt: 1,
        updatedAt: 1,
      );

  AttachmentData _photo() => AttachmentData(
        fileName: 'ref.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 0,
        bytes: Uint8List.fromList([1, 2, 3, 4, 5]),
        semanticType: 'image',
      );

  group('VisualProfileExtractor', () {
    test('empty photos → empty profile (no agent needed)', () async {
      final ex = VisualProfileExtractor();
      final profile = await ex.extract(personName: '妈妈', photos: const []);
      expect(profile.ageGroup, isNull);
      expect(profile.hairStyle, isNull);
    });

    test('no visual-capable agent → throws clear StateError', () async {
      final ex = VisualProfileExtractor(agents: _FakeAgentService(null));
      await expectLater(
        ex.extract(personName: '妈妈', photos: [_photo()]),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('视觉'))),
      );
    });

    test('LLM failure is swallowed → empty profile (never throws)',
        () async {
      final ex = VisualProfileExtractor(agents: _FakeAgentService(_stubVisualAgent()));
      final profile = await ex.extract(personName: '妈妈', photos: [_photo()]);
      // 真实 LLM 链路会因 apiBase 为空抛出 → extract 捕获并返回空档案
      expect(profile.ageGroup, isNull);
    });
  });
}

/// 测试用 agent 服务：固定返回一个 agent（或空），不触 DB。
class _FakeAgentService extends RemoteAgentService {
  _FakeAgentService(this._agent)
      : super(LocalDatabaseService(), TokenService(LocalDatabaseService()));

  final RemoteAgent? _agent;

  @override
  Future<RemoteAgent?> getAgentById(String agentId) async => _agent;

  @override
  Future<List<RemoteAgent>> getAllAgents() async =>
      _agent == null ? const [] : [_agent!];
}
