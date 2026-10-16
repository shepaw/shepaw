import 'dart:io' as io;

import '../peer/models/paired_peer.dart';
import '../peer/services/peer_pairing_service.dart';

/// 消息发送端设备信息，随用户消息 metadata 与 P2P 请求帧携带。
class ClientDeviceInfo {
  static const String deviceIdMetaKey = 'client_device_id';
  static const String deviceNameMetaKey = 'client_device_name';
  static const String deviceFormMetaKey = 'client_device_form';

  final String deviceId;
  final String deviceName;
  final String deviceForm;

  const ClientDeviceInfo({
    this.deviceId = '',
    required this.deviceName,
    required this.deviceForm,
  });

  bool get isMobile => deviceForm == DeviceForm.mobile;

  /// 获取当前客户端设备信息（同步快照，回退到系统 hostname 与平台形态）。
  static ClientDeviceInfo currentSync() {
    final pairing = PeerPairingService.instance;
    final cachedName = pairing.cachedDeviceName?.trim() ?? '';
    final String name;
    if (cachedName.isNotEmpty && cachedName != 'localhost') {
      name = cachedName;
    } else {
      final host = _safeLocalHostname();
      name = (host.isNotEmpty && host != 'localhost')
          ? host
          : _defaultPlatformName();
    }
    return ClientDeviceInfo(
      deviceId: pairing.cachedDeviceId ?? '',
      deviceName: name,
      deviceForm: DeviceForm.forPlatform(_safeOperatingSystem()),
    );
  }

  /// 获取当前客户端设备信息（异步确保 SharedPreferences 中的设备名已加载）。
  static Future<ClientDeviceInfo> current() async {
    try {
      final pairing = PeerPairingService.instance;
      final id = await pairing.getDeviceId();
      final name = await pairing.getDeviceName();
      return ClientDeviceInfo(
        deviceId: id,
        deviceName: name,
        deviceForm: DeviceForm.forPlatform(_safeOperatingSystem()),
      );
    } catch (_) {
      return currentSync();
    }
  }

  /// 将当前客户端设备信息写入 metadata 映射（若尚未设置）。
  static Map<String, dynamic> stampMetadata([
    Map<String, dynamic>? existing,
    ClientDeviceInfo? info,
  ]) {
    final resolved = info ?? currentSync();
    final out = existing != null
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    if (resolved.deviceId.isNotEmpty &&
        (out[deviceIdMetaKey] as String?)?.trim().isNotEmpty != true) {
      out[deviceIdMetaKey] = resolved.deviceId;
    }
    if (resolved.deviceName.isNotEmpty &&
        (out[deviceNameMetaKey] as String?)?.trim().isNotEmpty != true) {
      out[deviceNameMetaKey] = resolved.deviceName;
    }
    if (resolved.deviceForm.isNotEmpty &&
        (out[deviceFormMetaKey] as String?)?.trim().isNotEmpty != true) {
      out[deviceFormMetaKey] = resolved.deviceForm;
    }
    return out;
  }

  /// 从消息 metadata 解析发送端设备信息；无记录时返回 null。
  static ClientDeviceInfo? fromMetadata(Map<String, dynamic>? metadata) {
    if (metadata == null) return null;
    final rawName = (metadata[deviceNameMetaKey] as String?)?.trim() ?? '';
    final rawForm = (metadata[deviceFormMetaKey] as String?)?.trim() ?? '';
    final rawId = (metadata[deviceIdMetaKey] as String?)?.trim() ?? '';
    if (rawName.isEmpty && rawForm.isEmpty) return null;
    final inferredForm = rawForm.isNotEmpty
        ? rawForm
        : _inferFormFromName(rawName);
    return ClientDeviceInfo(
      deviceId: rawId,
      deviceName: rawName,
      deviceForm: inferredForm,
    );
  }

  Map<String, String> toWireFields() => <String, String>{
        if (deviceId.isNotEmpty) deviceIdMetaKey: deviceId,
        if (deviceName.isNotEmpty) deviceNameMetaKey: deviceName,
        if (deviceForm.isNotEmpty) deviceFormMetaKey: deviceForm,
      };

  static String _inferFormFromName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('iphone') ||
        lower.contains('ipad') ||
        lower.contains('android') ||
        lower.contains('pixel') ||
        lower.contains('galaxy') ||
        lower.contains('phone') ||
        lower.contains('mobile') ||
        lower.contains('手机')) {
      return DeviceForm.mobile;
    }
    return DeviceForm.desktop;
  }

  static String _safeLocalHostname() {
    try {
      return io.Platform.localHostname.trim();
    } catch (_) {
      return '';
    }
  }

  static String _safeOperatingSystem() {
    try {
      return io.Platform.operatingSystem;
    } catch (_) {
      return 'macos';
    }
  }

  static String _defaultPlatformName() {
    try {
      if (io.Platform.isAndroid) return 'Android';
      if (io.Platform.isIOS) return 'iPhone';
      if (io.Platform.isMacOS) return 'Mac';
      if (io.Platform.isWindows) return 'Windows';
      if (io.Platform.isLinux) return 'Linux';
    } catch (_) {}
    return 'Device';
  }
}
