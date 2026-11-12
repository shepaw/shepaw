import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/session/last_activated_session_store.dart';

/// 组合根注册不能漏：漏了之后所有写入点都会因 isRegistered 为假而静默
/// 降级，单元测试注入 store 也照样全绿。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setupServiceLocator 注册同一份 LastActivatedSessionStore 单例', () {
    setupServiceLocator();

    expect(getIt.isRegistered<LastActivatedSessionStore>(), isTrue);
    expect(
      getIt<LastActivatedSessionStore>(),
      same(getIt<LastActivatedSessionStore>()),
    );
  });
}
