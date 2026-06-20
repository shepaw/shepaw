import '../../services/logger_service.dart';
import 'account_identity_service.dart';
import 'sync_client_service.dart';
import 'sync_protocol_service.dart';
import 'user_identity_service.dart';

/// 账号会话：设备登录账号后激活身份与同步服务。
class AccountSessionService {
  AccountSessionService._();
  static final AccountSessionService instance = AccountSessionService._();

  static const _tag = 'AccountSession';
  final _log = LoggerService();

  bool _syncStarted = false;

  /// 本机是否已有账号密钥。
  Future<bool> hasLocalAccount() => UserIdentityService.instance.exists();

  /// 激活当前账号（加载身份 + 启动 P2P 同步协议）。
  Future<void> activate() async {
    await AccountIdentityService.instance.ensureInitialized();
    if (!_syncStarted) {
      SyncProtocolService.instance.start();
      SyncClientService.instance.start();
      _syncStarted = true;
      _log.info('Account session activated', tag: _tag);
    }
  }

  void resetSyncState() {
    _syncStarted = false;
  }
}
