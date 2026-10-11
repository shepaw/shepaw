import 'dart:io' as io;

import '../../clis/shepaw/os/os_tool_registry.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_pairing_service.dart';
import 'device_command_runner.dart';

/// 登录主机后报上本机身份和能执行的 `os.*` 命令，惜宝才能用 `--device` 指到这台设备。
class DeviceHello {
  DeviceHello._();

  static Map<String, dynamic> frame({
    required String deviceId,
    required String name,
    required String platform,
    required Set<String> platformTools,
  }) {
    return {
      'type': 'device.hello',
      'device_id': deviceId,
      'name': name,
      'platform': platform,
      'headless': false,
      'approver': true,
      'role': NodeRole.client,
      'form': DeviceForm.forPlatform(platform),
      'capabilities': capabilities(platformTools),
    };
  }

  /// 本平台有执行器的命令 id，按字母排好。
  static List<String> capabilities(Set<String> platformTools) {
    return [
      for (final entry in deviceCommandTools.entries)
        if (platformTools.contains(entry.value)) entry.key,
    ]..sort();
  }

  static Future<void> send(String hostPeerId) async {
    final pairing = PeerPairingService.instance;
    final registry = OsToolRegistry.instance;
    await PeerConnectionManager.instance.sendControl(
      hostPeerId,
      frame(
        deviceId: await pairing.getDeviceId(),
        name: await pairing.getDeviceName(),
        platform: io.Platform.operatingSystem,
        platformTools: registry.platformToolNames,
      ),
    );
  }
}
