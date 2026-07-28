/// 升主镜像种子短时授权（评审 B1：关闭常驻 seed 后门）。
///
/// 仅在本节点处理过该 caller 的 `sync.cursors`（升主拉游标）后，
/// 在 [ttl] 内允许其以 `seed: true` 读他端私有分区。
class SeedAuthorization {
  SeedAuthorization({this.ttl = const Duration(minutes: 15)});

  final Duration ttl;
  final Map<String, DateTime> _until = {};

  void authorize(String deviceId) {
    if (deviceId.isEmpty) return;
    _until[deviceId] = DateTime.now().add(ttl);
  }

  bool isAuthorized(String deviceId) {
    final exp = _until[deviceId];
    if (exp == null) return false;
    if (DateTime.now().isAfter(exp)) {
      _until.remove(deviceId);
      return false;
    }
    return true;
  }

  void clear() => _until.clear();
}
