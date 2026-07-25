import 'dart:io' as io;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:package_info_plus/package_info_plus.dart';

/// 配对握手时交换的设备信息（docs/sync_protocol_spec.md §2.1）。
class PeerDeviceInfo {
  const PeerDeviceInfo({
    required this.platform,
    required this.appVersion,
    required this.hubCapable,
    required this.deviceName,
    this.syncProtocolVersion,
  });

  /// macos | windows | linux | ios | android
  final String platform;
  final String appVersion;

  /// 桌面平台为 true；移动端恒 false。
  final bool hubCapable;
  final String deviceName;

  /// 对端支持的同步协议版本；null = 旧版 App（不支持同步）。
  final int? syncProtocolVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'platform': platform,
        'app_version': appVersion,
        'hub_capable': hubCapable,
        'device_name': deviceName,
        if (syncProtocolVersion != null) 'sync_v': syncProtocolVersion,
      };

  /// null 容忍解析：旧版 App 不携带这些字段时返回 null。
  static PeerDeviceInfo? tryFromJson(Map<String, dynamic> json) {
    final platform = json['platform'];
    if (platform is! String) return null;
    return PeerDeviceInfo(
      platform: platform,
      appVersion: json['app_version'] as String? ?? '',
      hubCapable: json['hub_capable'] as bool? ?? false,
      deviceName: json['device_name'] as String? ?? '',
      syncProtocolVersion: json['sync_v'] as int?,
    );
  }
}

/// 本机设备信息采集。
class LocalDeviceInfo {
  LocalDeviceInfo._();

  static String? _cachedAppVersion;

  static Future<String> _appVersion() async {
    if (_cachedAppVersion != null) return _cachedAppVersion!;
    try {
      final info = await PackageInfo.fromPlatform();
      _cachedAppVersion = info.version;
    } catch (_) {
      _cachedAppVersion = '';
    }
    return _cachedAppVersion!;
  }

  /// 当前平台是否具备 hub 能力（桌面端）。
  static bool get hubCapable =>
      !kIsWeb && (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux);

  static Future<PeerDeviceInfo> collect({
    required String deviceName,
    int? syncProtocolVersion,
  }) async {
    return PeerDeviceInfo(
      platform: kIsWeb ? 'web' : io.Platform.operatingSystem,
      appVersion: await _appVersion(),
      hubCapable: hubCapable,
      deviceName: deviceName,
      syncProtocolVersion: syncProtocolVersion,
    );
  }
}
