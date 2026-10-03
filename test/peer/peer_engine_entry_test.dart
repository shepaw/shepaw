import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  test('引擎回包带上头像、文档和启动命令', () {
    final engine = PeerEngineEntry.fromJson({
      'id': 'claude-code',
      'name': 'Claude Code',
      'command': 'npx',
      'available': false,
      'unavailable_reason': '主机上找不到命令 npx',
      'avatar_data': 'PHN2Zy8+',
      'avatar_ext': 'svg',
      'docs_url': 'https://agentclientprotocol.com',
      'acp_command': 'npx -y @agentclientprotocol/claude-agent-acp@latest',
    });
    expect(engine.available, isFalse);
    expect(engine.avatarData, 'PHN2Zy8+');
    expect(engine.avatarExt, 'svg');
    expect(engine.docsUrl, 'https://agentclientprotocol.com');
    expect(engine.acpCommand, contains('claude-agent-acp'));
    expect(engine.unavailableReason, contains('npx'));
  });
}
