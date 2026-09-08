import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_host_service.dart';

/// Host 端断点续传应答（PeerAgentHostService 作为「被访问」一侧）：
/// 客户端断线重连后发 agent_turn_resume_req（断点 = receivedLength，
/// UTF-16 码元），host 从 turn 输出缓冲切片补发漏掉的后缀。
///
/// 语义对齐 agent-bridge hub：
/// - 在途 streaming → status=streaming + delta + stream_metadata；
/// - 终态 done/error → 补 delta + 结果/错误；
/// - 不认识该 turn / peer 不匹配 → status=lost；
/// - known 超界 → 收敛到缓冲长度（应答幂等，客户端另有 drop-prefix 去重）。
void main() {
  group('PeerAgentHostService.turn resume', () {
    final svc = PeerAgentHostService.instance;
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
      svc.debugClearTurnBuffers();
    });

    Map<String, dynamic>? lastResumeResp() {
      final frames = sentFrames
          .where((f) => f.json['type'] == 'agent_turn_resume_resp')
          .toList();
      return frames.isEmpty ? null : frames.last.json;
    }

    test('streaming：切片补发漏掉的后缀并回放 stream_metadata', () async {
      svc.debugSeedTurnBuffer(
        requestId: 'req-s',
        peerId: 'peer-1',
        accumulated: 'hello world',
        status: 'streaming',
        lastMetadata: const {'content_type': 'text', 'phase': 'answer'},
      );

      await svc.debugHandleTurnResumeReq('peer-1', {
        'request_id': 'req-s',
        'known_content_length': 6,
      });

      final resp = lastResumeResp();
      expect(resp, isNotNull);
      expect(resp!['status'], 'streaming');
      expect(resp['delta'], 'world'); // accumulated.substring(6)
      expect(
          resp['stream_metadata'], {'content_type': 'text', 'phase': 'answer'});
      expect(resp.containsKey('content'), isFalse);
    });

    test('done：补 delta + 终态结果（客户端 _onDone 直接收尾）', () async {
      svc.debugSeedTurnBuffer(
        requestId: 'req-d',
        peerId: 'peer-1',
        accumulated: 'abcdef',
        status: 'done',
        doneContent: 'FINAL',
        doneMetadata: const {'finish': 'ok'},
      );

      await svc.debugHandleTurnResumeReq('peer-1', {
        'request_id': 'req-d',
        'known_content_length': 3,
      });

      final resp = lastResumeResp();
      expect(resp!['status'], 'done');
      expect(resp['delta'], 'def');
      expect(resp['content'], 'FINAL');
      expect(resp['metadata'], {'finish': 'ok'});
    });

    test('error：补 delta + 错误信息', () async {
      svc.debugSeedTurnBuffer(
        requestId: 'req-e',
        peerId: 'peer-1',
        accumulated: 'partial text',
        status: 'error',
        errorMessage: 'boom',
      );

      await svc.debugHandleTurnResumeReq('peer-1', {
        'request_id': 'req-e',
        'known_content_length': 7,
      });

      final resp = lastResumeResp();
      expect(resp!['status'], 'error');
      expect(resp['delta'], 'text');
      expect(resp['message'], 'boom');
    });

    test('unknown requestId / peer 不匹配 → lost', () async {
      await svc.debugHandleTurnResumeReq('peer-1', {
        'request_id': 'never-seen',
        'known_content_length': 0,
      });
      expect(lastResumeResp()!['status'], 'lost');

      svc.debugSeedTurnBuffer(
        requestId: 'req-x',
        peerId: 'peer-1',
        accumulated: 'abc',
        status: 'streaming',
      );
      // 另一台配对设备发来同一 requestId → 不认（requestId 全局唯一）。
      await svc.debugHandleTurnResumeReq('peer-2', {
        'request_id': 'req-x',
        'known_content_length': 0,
      });
      expect(lastResumeResp()!['status'], 'lost');
    });

    test('known 超界收敛到缓冲长度（幂等：不越界、不报错）', () async {
      svc.debugSeedTurnBuffer(
        requestId: 'req-c',
        peerId: 'peer-1',
        accumulated: 'abc',
        status: 'done',
        doneContent: 'done-text',
      );

      await svc.debugHandleTurnResumeReq('peer-1', {
        'request_id': 'req-c',
        'known_content_length': 9999,
      });

      final resp = lastResumeResp();
      expect(resp!['status'], 'done');
      expect(resp['delta'], ''); // 客户端已全量收到
      expect(resp['content'], 'done-text');
    });
  });
}
