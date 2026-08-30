import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/acp_agent_connection.dart';

/// `agent.resume.rebuild` 的 params 构造：空白提示词不透传（保持工作区扫描
/// 旧行为），非空提示词以 `{'prompt': ...}` 透传给网关。
void main() {
  group('ACPAgentConnection.resumeRebuildParams', () {
    test('null / 空白 → null（不带 params）', () {
      expect(ACPAgentConnection.resumeRebuildParams(null), isNull);
      expect(ACPAgentConnection.resumeRebuildParams(''), isNull);
      expect(ACPAgentConnection.resumeRebuildParams('   \n'), isNull);
    });

    test('非空 → 修剪后透传 prompt', () {
      expect(
        ACPAgentConnection.resumeRebuildParams('  更突出项目经验 \n'),
        {'prompt': '更突出项目经验'},
      );
    });
  });
}
