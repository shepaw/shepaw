/// 自有设备在账号域中的存储角色。
enum DeviceRole {
  /// 主存储：权威全量数据。
  primary('primary'),

  /// 备份：从 Primary 同步全量副本。
  backup('backup'),

  /// 应用设备：索引 + 热缓存，按需向 Primary 拉取。
  app('app');

  final String wireValue;
  const DeviceRole(this.wireValue);

  static DeviceRole fromWire(String? raw) {
    return DeviceRole.values.firstWhere(
      (r) => r.wireValue == raw,
      orElse: () => DeviceRole.app,
    );
  }
}
