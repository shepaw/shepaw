import '../models/device_role.dart';
import 'account_identity_service.dart';
import 'account_join_service.dart';
import 'account_session_service.dart';

/// 展示扫码登录 QR 前的前置检查与会话准备。
class QrLoginPreflight {
  QrLoginPreflight._();

  /// 返回 null 表示可以展示 QR；否则为错误码（映射 l10n）。
  static Future<String?> validateCanDisplayQr() async {
    await AccountIdentityService.instance.ensureInitialized();
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) {
      return 'not_primary';
    }
    return null;
  }

  /// 启动加入监听与完整账号会话（含同步协议）。
  static Future<void> prepareDisplaySession() async {
    AccountJoinService.instance.start();
    await AccountSessionService.instance.activate();
  }
}
