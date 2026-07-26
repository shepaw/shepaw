import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/import_auth_service.dart';

/// 换机导入授权（docs/storage_protocol_spec.md §5）。
void main() {
  late Directory tmp;
  late ImportAuthService auth;
  const oldDev = 'aaaaaaaaaaaaaaaa';
  const newDev = 'bbbbbbbbbbbbbbbb';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('import_auth_test');
    auth = ImportAuthService(storeRoot: tmp);
  });

  group('请求与签发', () {
    test('登记请求（同对设备去重）→ 审批签发 → 校验通过', () async {
      final r1 = await auth.createRequest(
          oldDevice: oldDev, newDevice: newDev);
      final r2 = await auth.createRequest(
          oldDevice: oldDev, newDevice: newDev);
      expect(r2.requestId, r1.requestId); // pending 去重

      final pending = await auth.pendingRequests();
      expect(pending.single.oldDevice, oldDev);

      final grant = await auth.grant(r1.requestId);
      expect(grant.oldDevice, oldDev);
      expect(grant.newDevice, newDev);
      expect(grant.spaces, containsAll(['backups', 'attachments']));

      expect(
          await auth.validate(grant.grantId,
              oldDevice: oldDev, newDevice: newDev, space: 'backups'),
          isTrue);
      // 主体不匹配 → 拒绝
      expect(
          await auth.validate(grant.grantId,
              oldDevice: oldDev, newDevice: 'cccccccccccccccc', space: 'backups'),
          isFalse);
      // 分区不匹配 → 拒绝
      expect(
          await auth.validate(grant.grantId,
              oldDevice: oldDev, newDevice: newDev, space: 'files'),
          isFalse);
      // 不存在的 grant → 拒绝
      expect(
          await auth.validate('ig-forged',
              oldDevice: oldDev, newDevice: newDev, space: 'backups'),
          isFalse);
    });

    test('拒绝请求后不能再签发；重复签发报错', () async {
      final r = await auth.createRequest(oldDevice: oldDev, newDevice: newDev);
      await auth.grant(r.requestId);
      expect(() => auth.grant(r.requestId), throwsA(anything));

      final r2 = await auth.createRequest(
          oldDevice: 'dddddddddddddddd', newDevice: newDev);
      await auth.reject(r2.requestId);
      expect(await auth.pendingRequests(), isEmpty);
      expect(() => auth.grant(r2.requestId), throwsA(anything));
    });

    test('撤销与过期', () async {
      final r = await auth.createRequest(oldDevice: oldDev, newDevice: newDev);
      final grant = await auth.grant(r.requestId);
      await auth.revoke(grant.grantId);
      expect(
          await auth.validate(grant.grantId,
              oldDevice: oldDev, newDevice: newDev, space: 'backups'),
          isFalse);

      // 负 TTL = 已过期
      final r2 = await auth.createRequest(
          oldDevice: 'eeeeeeeeeeeeeeee', newDevice: newDev);
      final g2 = await auth.grant(r2.requestId,
          ttl: const Duration(seconds: -1));
      expect(g2.expired, isTrue);
      expect(
          await auth.validate(g2.grantId,
              oldDevice: 'eeeeeeeeeeeeeeee',
              newDevice: newDev,
              space: 'backups'),
          isFalse);
    });

    test('持久化：新实例可读回', () async {
      final r = await auth.createRequest(oldDevice: oldDev, newDevice: newDev);
      final grant = await auth.grant(r.requestId);
      final auth2 = ImportAuthService(storeRoot: tmp);
      expect(
          await auth2.validate(grant.grantId,
              oldDevice: oldDev, newDevice: newDev, space: 'backups'),
          isTrue);
    });

    test('请求方：保存/列出收到的授权', () async {
      final r = await auth.createRequest(oldDevice: oldDev, newDevice: newDev);
      final grant = await auth.grant(r.requestId);
      await auth.saveReceivedGrant(grant);
      final received = await auth.receivedGrants();
      expect(received.single.grantId, grant.grantId);
    });
  });
}
