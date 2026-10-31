import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/onboarding/gate_errors.dart';
import 'package:shepaw/storage/pouch_login_client.dart';

void main() {
  group('按 code 归类（新主机）', () {
    test('密码不对', () {
      expect(
        mapGateError(
          const PouchPasswordRequired('密码不对', code: 'wrong_password'),
        ).kind,
        GateErrorKind.wrongPassword,
      );
    });

    test('锁定时带上还要等多久', () {
      final error = mapGateError(
        const PouchPasswordRequired(
          '试错太多次，请稍后再试',
          code: 'locked',
          retryAfter: Duration(seconds: 30),
        ),
      );
      expect(error.kind, GateErrorKind.locked);
      expect(error.locked, isTrue);
      expect(error.retryAfter, const Duration(seconds: 30));
    });

    test('凭据被拒不当错误显示，转成原因条', () {
      expect(
        mapGateError(
          const PouchCredentialRejected('设备凭据已失效'),
        ).kind,
        GateErrorKind.credentialRejected,
      );
    });

    test('加入码失效', () {
      expect(
        mapGateError(
          const PouchPasswordRequired('加入码已失效', code: 'invite_invalid'),
        ).kind,
        GateErrorKind.inviteInvalid,
      );
    });

    test('主机上没有这只袋子', () {
      expect(
        mapGateError(
          const PouchPasswordRequired('x', code: 'pouch_missing'),
        ).kind,
        GateErrorKind.pouchMissing,
      );
    });

    test('密码文件坏了', () {
      expect(
        mapGateError(
          const PouchPasswordRequired('x', code: 'password_file_broken'),
        ).kind,
        GateErrorKind.passwordFileBroken,
      );
    });
  });

  group('没有 code 时按 reason 兜底（老主机）', () {
    test('密码不对', () {
      expect(
        mapGateError(const PouchPasswordRequired('密码不对')).kind,
        GateErrorKind.wrongPassword,
      );
    });

    test('没有这只袋子', () {
      expect(
        mapGateError(const PouchPasswordRequired('没有这只袋子')).kind,
        GateErrorKind.pouchMissing,
      );
    });

    test('口令文件丢失', () {
      expect(
        mapGateError(
          const PouchPasswordRequired(
            '主机口令文件丢失，请在主机电脑上重设',
          ),
        ).kind,
        GateErrorKind.passwordFileBroken,
      );
    });

    test('密码文件损坏', () {
      expect(
        mapGateError(const PouchPasswordRequired('密码文件损坏')).kind,
        GateErrorKind.passwordFileBroken,
      );
    });

    test('主机回 locked 之外的限流也认 retry_after', () {
      final error = mapGateError(
        const PouchPasswordRequired(
          '密码不对',
          retryAfter: Duration(seconds: 5),
        ),
      );
      expect(error.kind, GateErrorKind.locked);
    });
  });

  group('连接类和兜底', () {
    test('超时算连不上', () {
      expect(
        mapGateError(TimeoutException('主机没有回应')).kind,
        GateErrorKind.unreachable,
      );
    });

    test('旧版本', () {
      expect(
        mapGateError(StateError('主机还是旧版本')).kind,
        GateErrorKind.hostOutdated,
      );
    });

    test('已经初始化过了', () {
      expect(
        mapGateError(StateError('这台主机已经初始化过了')).kind,
        GateErrorKind.alreadyInitialized,
      );
    });

    test('认不出的错误走兜底，但原始错误还在 detail 里', () {
      final error = mapGateError(StateError('什么鬼'));
      expect(error.kind, GateErrorKind.unknown);
      expect(error.detail, contains('什么鬼'));
    });

    test('不锁定时 retryAfter 为空', () {
      expect(
        mapGateError(const PouchPasswordRequired('密码不对')).locked,
        isFalse,
      );
    });
  });
}
