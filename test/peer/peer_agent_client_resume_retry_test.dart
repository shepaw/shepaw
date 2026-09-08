import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

/// 断点续传的应答看门狗：resume_req 发出后无应答时自动重发（重连竞态会偶发
/// 吞掉恰好那一帧），收到应答即退役；只有重试耗尽（如旧 hub 完全不支持
/// resume_req）才判失败并提示「请重新发送」。
///
/// 背景：长任务（Claude Code 回合）跨多次 peer 重连时，单帧 resume_req 可能
/// 石沉大海而 hub 端任务仍活着 —— 原实现 10s 无应答即判死整个回合。
void main() {
  group('PeerAgentClientService.resume watchdog', () {
    final svc = PeerAgentClientService.instance;
    final sentFrames = <({String peerId, Map<String, dynamic> json})>[];

    List<Map<String, dynamic>> resumeReqs() => sentFrames
        .map((f) => f.json)
        .where((j) => j['type'] == 'agent_turn_resume_req')
        .toList();

    setUp(() {
      sentFrames.clear();
      svc.debugSendControlOverride = (peerId, json) async {
        sentFrames.add((peerId: peerId, json: json));
        return true;
      };
      svc.debugResumeResponseTimeoutOverride = const Duration(milliseconds: 40);
    });

    tearDown(() async {
      svc.debugSendControlOverride = null;
      svc.debugResumeResponseTimeoutOverride = null;
      // 兜底清理种子 turn，避免跨用例污染单例状态。
      await svc.cancelInflightTurnsForChannel('ch-retry');
      await svc.cancelInflightTurnsForChannel('ch-retry-2');
    });

    test('resume_req 单帧无应答 → 自动重发，重试耗尽才按原文案判失败', () async {
      final errors = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'req-1',
            peerId: 'peer-1',
            channelId: 'ch-retry',
            suspended: true,
          )
          .then((_) {}, onError: errors.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      expect(resumeReqs(), hasLength(1));

      // 对端一直不回复：看门狗每 ~40ms 重发一次，重试耗尽后失败。
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      expect(errors, hasLength(1), reason: '重试耗尽后应失败');
      expect(
        errors.single.toString(),
        contains('对端不支持断点续传或任务已丢失，请重新发送'),
      );
      // 初试 + resumeRetryCount 次重发，且均发往同一 peer / requestId。
      expect(resumeReqs().length, greaterThanOrEqualTo(3));
      expect(
        resumeReqs().every((j) =>
            j['request_id'] == 'req-1' && j['known_content_length'] == 0),
        isTrue,
      );
      expect(svc.hasInflightForChannel('ch-retry'), isFalse);
    });

    test('收到 resume_resp 后看门狗退役：不重发、不误杀', () async {
      final outcomes = <Object>[];
      svc
          .debugSeedPendingTurn(
            requestId: 'req-2',
            peerId: 'peer-1',
            channelId: 'ch-retry-2',
            suspended: true,
          )
          .then(outcomes.add, onError: outcomes.add);

      await svc.debugResumeSuspendedTurns('peer-1');
      expect(resumeReqs(), hasLength(1));

      // 对端应答（streaming 续传成功）→ resumeInFlight 复位，看门狗退役。
      svc.debugInjectControlForTest(
        'agent_turn_resume_resp',
        {
          'request_id': 'req-2',
          'status': 'streaming',
          'delta': 'hello',
        },
        peerId: 'peer-1',
      );

      // 跨多个看门狗周期：若应答未让看门狗退役，早该重发 / 失败。
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(resumeReqs(), hasLength(1), reason: '收到应答后不应再重发');
      expect(outcomes, isEmpty, reason: '续传中的 turn 不应被误杀');
      expect(svc.hasInflightForChannel('ch-retry-2'), isTrue);
    });
  });
}
