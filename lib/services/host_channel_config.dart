import 'dart:convert';
import 'dart:io';

import 'cli_host.dart';

final _channelUuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// 从 `http://host/proxy/<id>` 或 `.../c/<别名>` 里拆出主机地址。
/// 后面的 `/peer/ws` 之类忽略。不是这种地址时返回 null。
class ChannelAddressParts {
  const ChannelAddressParts({
    required this.serverUrl,
    this.channelId,
    this.endpoint,
    required this.closed,
  });

  final String serverUrl;
  final String? channelId;
  final String? endpoint;

  /// 路径在编号后面还有内容，说明这一段已经写完。
  final bool closed;

  /// 完整 UUID，或后面还有路径。输入到一半时先不拆，避免截断编号。
  bool get ready =>
      closed || (channelId != null && _channelUuid.hasMatch(channelId!));
}

ChannelAddressParts? splitChannelAddress(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = switch (uri.scheme) {
    'http' || 'https' || 'ws' || 'wss' => uri.scheme,
    _ => null,
  };
  if (scheme == null) return null;
  final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (segments.length < 2 || (segments[0] != 'proxy' && segments[0] != 'c')) {
    return null;
  }
  final value = segments[1];
  if (value.isEmpty) return null;
  final httpScheme = switch (scheme) {
    'ws' => 'http',
    'wss' => 'https',
    _ => scheme,
  };
  final port = uri.hasPort ? ':${uri.port}' : '';
  return ChannelAddressParts(
    serverUrl: '$httpScheme://${uri.host}$port',
    channelId: segments[0] == 'proxy' ? value : null,
    endpoint: segments[0] == 'c' ? value : null,
    closed: segments.length > 2,
  );
}

/// 主机 `channel.json` 里的外网 Channel。由本机 `shepaw channel` 读写。
class HostChannelConfig {
  const HostChannelConfig({
    required this.enabled,
    required this.serverUrl,
    required this.channelId,
    required this.secret,
    required this.endpoint,
    required this.publicUrl,
  });

  final bool enabled;
  final String serverUrl;
  final String channelId;
  final String secret;
  final String endpoint;
  final String publicUrl;

  static const empty = HostChannelConfig(
    enabled: false,
    serverUrl: '',
    channelId: '',
    secret: '',
    endpoint: '',
    publicUrl: '',
  );

  factory HostChannelConfig.fromJson(Map<String, dynamic> json) {
    return HostChannelConfig(
      enabled: json['enabled'] == true,
      serverUrl: json['server_url'] as String? ?? '',
      channelId: json['channel_id'] as String? ?? '',
      secret: json['secret'] as String? ?? '',
      endpoint: json['endpoint'] as String? ?? '',
      publicUrl: json['public_url'] as String? ?? '',
    );
  }
}

class HostChannelStore {
  /// 本机没有 `shepaw` 时返回 null。
  static Future<HostChannelConfig?> load() async {
    final binary = await CliHost.resolveBinary();
    if (binary == null) return null;
    final result = await Process.run(binary, const ['channel']);
    if (result.exitCode != 0) {
      throw StateError(_stderr(result));
    }
    final decoded = jsonDecode(result.stdout.toString());
    if (decoded is! Map) return HostChannelConfig.empty;
    return HostChannelConfig.fromJson(decoded.cast<String, dynamic>());
  }

  static Future<HostChannelConfig> save({
    required bool enabled,
    required String serverUrl,
    required String channelId,
    required String secret,
    required String endpoint,
  }) async {
    final binary = await CliHost.resolveBinary();
    if (binary == null) {
      throw StateError('no-cli');
    }
    final args = <String>[
      'channel',
      'set',
      '--server',
      serverUrl.trim(),
      '--id',
      channelId.trim(),
      if (endpoint.trim().isNotEmpty) ...['--endpoint', endpoint.trim()],
      if (!enabled) '--off',
    ];
    final env = Map<String, String>.from(Platform.environment);
    env['SHEPAW_CHANNEL_SECRET'] = secret;
    final result = await Process.run(binary, args, environment: env);
    if (result.exitCode != 0) {
      throw StateError(_stderr(result));
    }
    return await load() ?? HostChannelConfig.empty;
  }

  static String _stderr(ProcessResult result) {
    final err = result.stderr.toString().trim();
    if (err.isNotEmpty) return err;
    final out = result.stdout.toString().trim();
    return out.isEmpty ? 'exit ${result.exitCode}' : out;
  }
}
