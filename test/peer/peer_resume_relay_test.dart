import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 简历中继（agent_resume_get / set / rebuild）客户端侧协议行为：
/// 帧形状、resp 关联、拒绝 / 发送失败 / 超时路径。
void main() {
  group('PeerAgentClientService resume relay', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    setUp(() {
      sentFrames.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
    });

    tearDown(() {
      svc.debugSendControlOverride = null;
    });

    /// 最近发出的一帧请求。
    Map<String, dynamic> lastReq() => sentFrames.last.json;

    test('getResumeInfo 发送 get_req 并回填 resume + editable', () async {
      final future = svc.getResumeInfo(peerId: 'p1', remoteAgentId: 'a1');
      await untilSent(sentFrames);
      final req = lastReq();
      expect(req['type'], 'agent_resume_get_req');
      expect(req['agent_id'], 'a1');
      expect(req['request_id'], isNotEmpty);

      svc.debugInjectControlForTest('agent_resume_get_resp', {
        'agent_id': 'a1',
        'request_id': req['request_id'],
        'ok': true,
        'resume': '简历正文',
        'editable': true,
      });
      final info = await future;
      expect(info, isNotNull);
      expect(info!.isOk, isTrue);
      expect(info.resume, '简历正文');
      expect(info.editable, isTrue);
    });

    test('getResumeInfo 宿主拒绝 → error 有值；未发出 → null', () async {
      final denied = svc.getResumeInfo(peerId: 'p1', remoteAgentId: 'a1');
      await untilSent(sentFrames);
      svc.debugInjectControlForTest('agent_resume_get_resp', {
        'request_id': lastReq()['request_id'],
        'ok': false,
        'error': 'denied',
      });
      final info = await denied;
      expect(info!.isOk, isFalse);
      expect(info.error, 'denied');

      svc.debugSendControlOverride = (peerId, json) async => false;
      final unsent = await svc.getResumeInfo(peerId: 'p1', remoteAgentId: 'a2');
      expect(unsent, isNull);
    });

    test('setResume 发送 resume 字段；ok:true → true，denied → false', () async {
      final ok = svc.setResume(
        peerId: 'p1',
        remoteAgentId: 'a1',
        resume: '新简历',
      );
      await untilSent(sentFrames);
      final req = lastReq();
      expect(req['type'], 'agent_resume_set_req');
      expect(req['resume'], '新简历');
      svc.debugInjectControlForTest('agent_resume_set_resp', {
        'request_id': req['request_id'],
        'ok': true,
      });
      expect(await ok, isTrue);

      final denied = svc.setResume(
        peerId: 'p1',
        remoteAgentId: 'a1',
        resume: 'x',
      );
      await untilSent(sentFrames);
      svc.debugInjectControlForTest('agent_resume_set_resp', {
        'request_id': sentFrames.last.json['request_id'],
        'ok': false,
        'error': 'denied',
      });
      expect(await denied, isFalse);
    });

    test('rebuildResumeViaPeer 发送 prompt 并返回宿主新简历', () async {
      final future = svc.rebuildResumeViaPeer(
        peerId: 'p1',
        remoteAgentId: 'a1',
        prompt: '更突出项目经验',
      );
      await untilSent(sentFrames);
      final req = lastReq();
      expect(req['type'], 'agent_resume_rebuild_req');
      expect(req['prompt'], '更突出项目经验');
      svc.debugInjectControlForTest('agent_resume_rebuild_resp', {
        'request_id': req['request_id'],
        'ok': true,
        'resume': '重写后的简历',
      });
      expect(await future, '重写后的简历');
    });

    test('rebuildResumeViaPeer ok:false → StateError(error)', () async {
      final future = svc.rebuildResumeViaPeer(
        peerId: 'p1',
        remoteAgentId: 'a1',
        prompt: 'x',
      );
      await untilSent(sentFrames);
      svc.debugInjectControlForTest('agent_resume_rebuild_resp', {
        'request_id': sentFrames.last.json['request_id'],
        'ok': false,
        'error': 'denied',
      });
      await expectLater(future, throwsStateError);
    });
  });
}

/// 等到 override 捕获到至少一帧。
Future<void> untilSent(
  List<({String peerId, Map<String, dynamic> json})> frames,
) async {
  for (var i = 0; i < 100 && frames.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(frames, isNotEmpty, reason: 'sendControl override was never called');
}
