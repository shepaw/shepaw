import '../../services/logger_service.dart';
import 'account_identity_service.dart';
import 'user_identity_service.dart';

/// 灵宠认主（已废弃：账号创建时自动绑定固定灵宠，无需单独认主步骤）。
///
/// 保留此类仅供旧测试与向后兼容引用。
@Deprecated('Ownership bond removed; account creation binds pet automatically')
class OwnershipService {
  OwnershipService._();
  static final OwnershipService instance = OwnershipService._();

  static const _bondPrefix = 'shepaw:ownership:v1';

  static String bondPayload({
    required String userId,
    required String petId,
    required int timestampMs,
  }) =>
      '$_bondPrefix:$userId:$petId:$timestampMs';

  Future<bool> isBonded() => UserIdentityService.instance.exists();

  Future<void> performBond({String? biometricReason}) async {
    await AccountIdentityService.instance.ensureInitialized();
    LoggerService().info('performBond is deprecated (no-op)', tag: 'Ownership');
  }
}
