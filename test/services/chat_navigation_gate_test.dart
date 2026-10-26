import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/chat_navigation_service.dart';

void main() {
  String? route({
    bool isDesktop = false,
    required bool loggedIn,
    bool onLoginGate = false,
    String? phoneHostId,
  }) {
    return deepLinkLoginRoute(
      isDesktop: isDesktop,
      loggedIn: loggedIn,
      onLoginGate: onLoginGate,
      phoneHostId: phoneHostId,
    );
  }

  test('有效登录态且不在门页时不拦截深链', () {
    expect(route(loggedIn: true, phoneHostId: 'peer-1'), isNull);
    expect(route(isDesktop: true, loggedIn: true), isNull);
  });

  test('token 还有效但人停在登录页时不放行', () {
    expect(
      route(loggedIn: true, onLoginGate: true, phoneHostId: 'peer-1'),
      '/phone-login',
    );
    expect(
      route(isDesktop: true, loggedIn: true, onLoginGate: true),
      '/pouch',
    );
  });

  test('手机未登录回主机登录页；没配过主机先去配对', () {
    expect(route(loggedIn: false, phoneHostId: 'peer-1'), '/phone-login');
    expect(route(loggedIn: false, phoneHostId: '  '), '/remote-connect');
    expect(route(loggedIn: false, phoneHostId: null), '/remote-connect');
  });

  test('桌面未登录回储物袋登录页', () {
    expect(route(isDesktop: true, loggedIn: false), '/pouch');
  });
}
