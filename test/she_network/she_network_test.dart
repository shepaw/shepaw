import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/she_network/digest_service.dart';
import 'package:shepaw/she_network/exchange_settings.dart';
import 'package:shepaw/she_network/presence_service.dart';
import 'package:shepaw/she_network/she_network_protocol.dart';
import 'package:shepaw/storage/store_protocol.dart'
    show BadPathException, TrustLevel, normalizeStorePath;

import '../storage/test_harness.dart';

void main() {
  group('she_network protocol', () {
    test('MemoryFrame / SheFrame 编解码', () {
      final m = MemoryFrame(
        op: MemoryOp.digestOffer,
        reqId: 'r1',
        payload: {
          'from_device': 'aaaaaaaaaaaaaaaa',
          'period': '2026-07-20/2026-07-26',
          'entries': [
            DigestEntry(kind: DigestKind.fact, text: 'hello').toJson(),
          ],
        },
      );
      final mw = m.toJson();
      expect(mw['type'], kMemoryControlType);
      expect(mw['ns'], kMemoryControlType);
      final mp = MemoryFrame.tryParse(mw)!;
      expect(mp.op, MemoryOp.digestOffer);
      expect(mp.payload['from_device'], 'aaaaaaaaaaaaaaaa');
      expect((mp.payload['entries'] as List).length, 1);

      final s = SheFrame(
        op: SheOp.presence,
        payload: ShePresence(
          deviceId: 'bbbbbbbbbbbbbbbb',
          sheName: '办公室的她',
          online: true,
          agentCategories: const ['she'],
          toolCategories: const ['web'],
          agentCount: 1,
        ).toJson(),
      );
      final sp = SheFrame.tryParse(s.toJson())!;
      expect(sp.op, SheOp.presence);
      expect(ShePresence.fromJson(sp.payload).sheName, '办公室的她');
    });

    test('friend 拒绝 memory/she', () {
      expect(memorySheAllowed(TrustLevel.owner), isTrue);
      expect(memorySheAllowed(TrustLevel.friend), isFalse);
    });

    test('关闭类别后不进入出站集合', () async {
      final settings = ExchangeSettings(
        enabled: true,
        kinds: {DigestKind.fact},
      );
      final entries =
          await DigestService.instance.buildOutgoing(settings: settings);
      for (final e in entries) {
        expect(e.kind, DigestKind.fact);
      }
    });

    test('总开关关闭 → 无出站摘要', () async {
      final entries = await DigestService.instance.buildOutgoing(
        settings: ExchangeSettings(enabled: false, kinds: {...DigestKind.all}),
      );
      expect(entries, isEmpty);
    });

    test('period 形如 YYYY-MM-DD/YYYY-MM-DD', () {
      final p = DigestService.instance.currentPeriod();
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}/\d{4}-\d{2}-\d{2}$').hasMatch(p),
          isTrue);
    });
  });

  group('PresenceService.routeByCategory', () {
    setUpAll(() async {
      await StorageTestHarness.init();
    });

    test('三设备：按类别选目标（不含离线）', () async {
      final svc = PresenceService.instance;
      svc.putPresence(ShePresence(
        deviceId: '1111111111111111',
        sheName: 'A',
        online: true,
        agentCategories: const ['she'],
        toolCategories: const ['shell'],
        agentCount: 1,
      ));
      svc.putPresence(ShePresence(
        deviceId: '2222222222222222',
        sheName: 'B',
        online: true,
        agentCategories: const ['assistant'],
        toolCategories: const ['web'],
        agentCount: 2,
      ));
      svc.putPresence(ShePresence(
        deviceId: '3333333333333333',
        sheName: 'C',
        online: false,
        agentCategories: const ['she'],
        toolCategories: const ['web'],
        agentCount: 1,
      ));

      final shell = await svc.routeByCategory('shell');
      expect(shell.map((e) => e.deviceId), contains('1111111111111111'));
      expect(shell.every((e) => e.online), isTrue);

      final web = await svc.routeByCategory('web');
      expect(web.map((e) => e.deviceId), contains('2222222222222222'));
      expect(web.map((e) => e.deviceId), isNot(contains('3333333333333333')));
    });
  });

  group('ExchangeSettings', () {
    setUpAll(() async {
      await StorageTestHarness.init();
    });

    test('settings 持久化 opt-in', () async {
      final off = ExchangeSettings(enabled: false, kinds: {DigestKind.fact});
      await off.save();
      final loaded = await ExchangeSettings.load();
      expect(loaded.enabled, isFalse);
      expect(loaded.kinds, {DigestKind.fact});

      final on = loaded.copyWith(enabled: true, kinds: {...DigestKind.all});
      await on.save();
      final again = await ExchangeSettings.load();
      expect(again.enabled, isTrue);
      expect(again.kinds.length, 3);
    });
  });

  group('共享 path fixture 与 Dart normalize 对齐', () {
    test('docs/storage_fixtures/path_attacks.json', () {
      final file = File('docs/storage_fixtures/path_attacks.json');
      expect(file.existsSync(), isTrue, reason: 'M7 共享 fixture 必须存在');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final attacks = (json['attacks'] as List).cast<String>();
      for (final path in attacks) {
        expect(() => normalizeStorePath(path), throwsA(isA<BadPathException>()),
            reason: path);
      }
      for (final row in (json['ok'] as List)) {
        final input = row[0] as String;
        final expectOut = row[1] as String;
        expect(normalizeStorePath(input), expectOut);
      }
    });
  });
}
