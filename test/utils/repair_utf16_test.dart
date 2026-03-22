import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';

void main() {
  group('repairUtf16Garbled Tests', () {
    test('should return unchanged ASCII string', () {
      expect(repairUtf16Garbled('hello'), 'hello');
    });

    test('should return unchanged empty string', () {
      expect(repairUtf16Garbled(''), '');
    });

    test('should return unchanged single char string', () {
      expect(repairUtf16Garbled('a'), 'a');
    });

    test('should return unchanged normal Chinese text', () {
      expect(repairUtf16Garbled('你好世界'), '你好世界');
    });

    test('should repair UTF-16 garbled ASCII string', () {
      // Simulate the bug: each ASCII byte stored as (byte << 8) | 0x00
      // 'sk' -> [0x7300, 0x6B00]
      final garbled = String.fromCharCodes([0x7300, 0x6B00]);
      expect(repairUtf16Garbled(garbled), 'sk');
    });

    test('should repair longer garbled string', () {
      // 'hello' -> each char shifted left by 8 with low byte = 0
      final garbled = String.fromCharCodes(
        'hello'.codeUnits.map((u) => (u << 8)),
      );
      expect(repairUtf16Garbled(garbled), 'hello');
    });

    test('should not repair mixed content', () {
      // If not all codepoints match the garble pattern, return as-is
      final mixed = String.fromCharCodes([0x7300, 0x41]); // garbled 's' + normal 'A'
      // 0x41 is <= 127, so pattern check fails - returns as-is
      expect(repairUtf16Garbled(mixed), mixed);
    });
  });

  group('RemoteAgent metadata-derived properties Tests', () {
    late RemoteAgent baseAgent;

    setUp(() {
      final now = DateTime.now().millisecondsSinceEpoch;
      baseAgent = RemoteAgent(
        id: 'test-id',
        name: 'Test Agent',
        token: 'test-token',
        endpoint: 'https://example.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.websocket,
        createdAt: now,
        updatedAt: now,
      );
    });

    test('enabledOsTools should return empty set by default', () {
      expect(baseAgent.enabledOsTools, isEmpty);
      expect(baseAgent.hasOsTools, false);
    });

    test('enabledOsTools should parse from metadata', () {
      final agent = baseAgent.copyWith(
        metadata: {
          'enabled_os_tools': ['clipboard', 'screenshot', 'keyboard'],
        },
      );

      expect(agent.enabledOsTools, {'clipboard', 'screenshot', 'keyboard'});
      expect(agent.hasOsTools, true);
    });

    test('enabledSkills should return empty set by default', () {
      expect(baseAgent.enabledSkills, isEmpty);
      expect(baseAgent.hasSkills, false);
    });

    test('enabledSkills should parse from metadata', () {
      final agent = baseAgent.copyWith(
        metadata: {
          'enabled_skills': ['translate', 'summarize'],
        },
      );

      expect(agent.enabledSkills, {'translate', 'summarize'});
      expect(agent.hasSkills, true);
    });

    test('modelRouting should return empty config by default', () {
      expect(baseAgent.modelRouting.isEmpty, true);
      expect(baseAgent.hasModelRouting, false);
    });

    test('modelRouting should parse from metadata', () {
      final agent = baseAgent.copyWith(
        metadata: {
          'model_routing': {
            'image': {'provider': 'openai', 'model': 'gpt-4o'},
          },
        },
      );

      expect(agent.hasModelRouting, true);
      expect(agent.modelRouting.routes.length, 1);
    });

    test('toString should include key fields', () {
      final str = baseAgent.toString();
      expect(str, contains('test-id'));
      expect(str, contains('Test Agent'));
    });

    test('equality should compare key fields', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final a = RemoteAgent(
        id: 'same',
        name: 'Agent',
        token: 'tok',
        endpoint: 'http://e',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        createdAt: now,
        updatedAt: now,
      );
      final b = RemoteAgent(
        id: 'same',
        name: 'Agent',
        token: 'tok',
        endpoint: 'http://e',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        status: AgentStatus.online,
        createdAt: now + 1000, // different timestamps
        updatedAt: now + 1000,
      );

      expect(a == b, true);
      expect(a.hashCode, b.hashCode);
    });

    test('equality should detect differences', () {
      final a = baseAgent;
      final b = baseAgent.copyWith(name: 'Different');

      expect(a == b, false);
    });
  });
}
