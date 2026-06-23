import '../models/device_role.dart';

/// device_rpc 调用方/执行方权限策略。
class DeviceRpcPolicy {
  DeviceRpcPolicy._();

  static const privilegedMethods = {'cli.exec'};

  /// 调用方是否允许发起 [method]（App 不可远程执行 CLI）。
  static bool callerMayInvoke(String method, DeviceRole callerRole) {
    if (!privilegedMethods.contains(method)) return true;
    return callerRole == DeviceRole.primary || callerRole == DeviceRole.backup;
  }

  /// 本机是否允许执行 [method]（App 设备不执行远程下发的 CLI）。
  static bool receiverMayExecute(String method, DeviceRole localRole) {
    if (method != 'cli.exec') return true;
    return localRole == DeviceRole.primary || localRole == DeviceRole.backup;
  }
}
