/// 连接 Hub 时的探测顺序：自定义地址，然后局域网，然后 channel。
List<String> hubEndpointOrder({
  List<String> custom = const [],
  String? lan,
  String? channel,
  bool channelEnabled = true,
}) {
  final ordered = <String>[];
  for (final endpoint in custom) {
    final trimmed = endpoint.trim();
    if (trimmed.isNotEmpty && !ordered.contains(trimmed)) {
      ordered.add(trimmed);
    }
  }
  final lanEndpoint = lan?.trim() ?? '';
  if (lanEndpoint.isNotEmpty && !ordered.contains(lanEndpoint)) {
    ordered.add(lanEndpoint);
  }
  final channelEndpoint = channel?.trim() ?? '';
  if (channelEnabled &&
      channelEndpoint.isNotEmpty &&
      !ordered.contains(channelEndpoint)) {
    ordered.add(channelEndpoint);
  }
  return ordered;
}
