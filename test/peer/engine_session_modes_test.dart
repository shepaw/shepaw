import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/engine_session_modes.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  group('engineSessionModeCatalog', () {
    test('exposes Cursor / Claude / Codex / OpenCode modes', () {
      expect(
        engineSessionModeCatalog('cursor').modes.map((m) => m.value),
        ['agent', 'plan', 'ask'],
      );
      expect(engineSessionModeCatalog('cursor').defaultModeId, 'agent');
      expect(engineSessionModeCatalog('claude-code').defaultModeId, 'acceptEdits');
      expect(
        engineSessionModeCatalog('codex').modes.map((m) => m.value),
        ['untrusted', 'on-request', 'on-failure', 'never'],
      );
      expect(
        engineSessionModeCatalog('opencode').modes.map((m) => m.value),
        ['build', 'plan'],
      );
    });

    test('leaves unknown engines empty', () {
      expect(engineSessionModeCatalog('codebuddy').modes, isEmpty);
      expect(engineSessionModeCatalog(null).modes, isEmpty);
      expect(engineSessionModeCatalog('').modes, isEmpty);
    });
  });

  group('catalogModesList', () {
    test('defaults current to the engine default', () {
      expect(catalogModesList('cursor').current, 'agent');
      expect(catalogModesList('cursor', current: 'plan').current, 'plan');
      expect(catalogModesList('codebuddy').modes, isEmpty);
    });
  });

  group('PeerAgentMode.fromJson', () {
    test('reads value / display_name', () {
      final mode = PeerAgentMode.fromJson({
        'value': 'agent',
        'display_name': 'Agent',
        'description': 'Full tools',
      });
      expect(mode?.value, 'agent');
      expect(mode?.displayName, 'Agent');
      expect(mode?.description, 'Full tools');
    });

    test('accepts id / name aliases used by Hub catalogs', () {
      final mode = PeerAgentMode.fromJson({
        'id': 'plan',
        'name': 'Plan',
      });
      expect(mode?.value, 'plan');
      expect(mode?.displayName, 'Plan');
    });

    test('parses maps that are not Map<String, dynamic>', () {
      final raw = <dynamic, dynamic>{
        'value': 'ask',
        'display_name': 'Ask',
      };
      final mode = PeerAgentMode.fromJson(Map<String, dynamic>.from(raw));
      expect(mode?.value, 'ask');
    });
  });
}
