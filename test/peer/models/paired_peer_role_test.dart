import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent_node.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/services/device_node/device_hello.dart';

PairedPeer _peer({
  String? role,
  String? form,
  String? platform,
  PeerPairingRole? pairing,
}) =>
    PairedPeer(
      id: 'p1',
      deviceName: 'box',
      deviceId: 'd1',
      publicKey: Uint8List(32),
      fingerprint: 'abcd',
      pairedAt: 1,
      pairingRole: pairing,
      nodeRole: role,
      form: form,
      platform: platform,
    );

void main() {
  group('PairedPeer 身份', () {
    test('旧数据当作客户端，形态按平台推断', () {
      expect(_peer().effectiveRole, NodeRole.client);
      expect(_peer().effectiveForm, DeviceForm.desktop);
      expect(_peer(platform: 'android').effectiveForm, DeviceForm.mobile);
      expect(_peer(platform: 'iOS').effectiveForm, DeviceForm.mobile);
    });

    test('工作节点默认是服务器形态', () {
      final peer = _peer(role: NodeRole.worker, platform: 'linux');
      expect(peer.effectiveRole, NodeRole.worker);
      expect(peer.effectiveForm, DeviceForm.server);
    });

    test('不认识的取值退回推断', () {
      final peer = _peer(role: 'boss', form: 'tablet', platform: 'ios');
      expect(peer.effectiveRole, NodeRole.client);
      expect(peer.effectiveForm, DeviceForm.mobile);
    });

    test('主机名单里的 role/form/platform 能读回来', () {
      final json = _peer(role: NodeRole.host, form: 'server', platform: 'linux')
          .toJson();
      expect(json['role'], 'host');
      final back = PairedPeer.fromJson(json);
      expect(back.effectiveRole, NodeRole.host);
      expect(back.effectiveForm, DeviceForm.server);
      expect(back.platform, 'linux');
    });

    test('只有主机能登录储物袋，工作节点和客户端都不算', () {
      expect(_peer(role: NodeRole.host).isHost, isTrue);
      expect(
        _peer(role: NodeRole.worker, pairing: PeerPairingRole.initiator).isHost,
        isFalse,
      );
      expect(
        _peer(role: NodeRole.client, pairing: PeerPairingRole.initiator).isHost,
        isFalse,
      );
      expect(_peer(pairing: PeerPairingRole.initiator).isHost, isTrue);
      expect(_peer(pairing: PeerPairingRole.responder).isHost, isFalse);
      expect(_peer().isHost, isFalse);
    });

    test('空字符串当作没给', () {
      final json = _peer().toJson()..['role'] = ' ';
      expect(PairedPeer.fromJson(json).nodeRole, isNull);
    });
  });

  group('配对载荷', () {
    test('请求带上客户端身份', () {
      final request = PairingRequest(
        pairingCode: 'ABCD2345',
        deviceName: 'phone',
        deviceId: 'dev',
        timestamp: 1,
        role: NodeRole.client,
        form: DeviceForm.mobile,
        platform: 'android',
      );
      final back = PairingRequest.fromBytes(request.toBytes());
      expect(back.role, 'client');
      expect(back.form, 'mobile');
      expect(back.platform, 'android');
    });

    test('主机回包里的 role 能读到，旧回包没有', () {
      final response = PairingResponse.fromJson({
        'accepted': true,
        'device_name': 'hub',
        'device_id': 'fp',
        'peer_id': 'p',
        'role': 'host',
        'platform': 'macos',
      });
      expect(response.role, 'host');
      expect(response.platform, 'macos');
      final old = PairingResponse.fromJson({
        'accepted': true,
        'device_name': 'hub',
        'device_id': 'fp',
        'peer_id': 'p',
      });
      expect(old.role, isNull);
      expect(old.toJson().containsKey('role'), isFalse);
    });
  });

  group('device.hello', () {
    test('只报本平台有执行器的命令', () {
      final frame = DeviceHello.frame(
        deviceId: 'dev',
        name: 'Mac',
        platform: 'macos',
        platformTools: {'system_info', 'shell_exec', 'not_a_command'},
      );
      expect(frame['type'], 'device.hello');
      expect(frame['role'], 'client');
      expect(frame['form'], 'desktop');
      expect(frame['capabilities'], ['os.command.exec', 'os.command.sysinfo']);
    });

    test('手机报移动形态', () {
      final frame = DeviceHello.frame(
        deviceId: 'dev',
        name: 'Phone',
        platform: 'ios',
        platformTools: const {},
      );
      expect(frame['form'], 'mobile');
      expect(frame['capabilities'], isEmpty);
    });
  });

  group('AgentNodeInfo', () {
    test('工作节点 Agent 带节点信息', () {
      final node = AgentNodeInfo.fromAgentListEntry({
        'node_id': 'fc57',
        'node_name': 'gpu-box',
        'node_role': 'worker',
        'online': false,
      });
      expect(node.onWorker, isTrue);
      expect(node.online, isFalse);
      expect(node.toMetadata(), {
        'node_id': 'fc57',
        'node_name': 'gpu-box',
        'node_role': 'worker',
        'online': false,
      });
      expect(AgentNodeInfo.fromMetadata(node.toMetadata()).nodeId, 'fc57');
    });

    test('没有节点字段时是主机上的在线 Agent', () {
      final node = AgentNodeInfo.fromAgentListEntry({'id': 'a'});
      expect(node.onWorker, isFalse);
      expect(node.online, isTrue);
      expect(AgentNodeInfo.fromMetadata(null).online, isTrue);
    });
  });
}
