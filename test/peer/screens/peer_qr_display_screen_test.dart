import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
// `qr` 是 qr_flutter 的传递依赖，这里只用来在测试里算模块数（= 二维码版本）。
// 为了一个测试断言把它提升成 pubspec 里的直接依赖不划算，故显式忽略该 lint。
// ignore: depend_on_referenced_packages
import 'package:qr/qr.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';
import 'package:shepaw/peer/screens/peer_qr_display_screen.dart';

/// `sha256(<32 个 0 字节>)[:8]`。
const _fp = '66687aadf862bd77';

String qrWith(String? name) => PeerPairingInfo.encode(
      localEndpoint: 'ws://192.168.1.5:18793/peer/ws',
      code: 'ABC23456',
      fingerprint: _fp,
      publicKey: Uint8List(32),
      name: name,
    );

/// `QrErrorCorrectLevel.M` 下的模块数（边长）。
int modulesFor(String payload) =>
    QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M).moduleCount;

void main() {
  // 设备名会拉长 payload，进而抬高二维码版本。这些测试把「密度不会退化到
  // 扫不动」这件事固定下来 —— 光靠肉眼扫一次是留不住的。
  group('qrSideFor', () {
    test('短 payload 保持基准边长（与改动前逐像素一致）', () {
      for (final bytes in [1, 143, 160, 200]) {
        expect(
          qrSideFor(payloadBytes: bytes, availableWidth: 800),
          240.0,
          reason: '$bytes bytes',
        );
      }
      // 普通名字（160 字节 / 53×53）也走这条路。
      expect(qrWith('Hub Alpha').length, lessThan(200));
    });

    test('长 payload 按可用宽度放大，上限 400', () {
      expect(qrSideFor(payloadBytes: 437, availableWidth: 800), 400.0);
      expect(qrSideFor(payloadBytes: 437, availableWidth: 500), 400.0);
      // 可用宽度扣掉 Container 内边距后不足 400 → 用实际可用宽度。
      expect(qrSideFor(payloadBytes: 437, availableWidth: 336), 304.0);
      expect(qrSideFor(payloadBytes: 437, availableWidth: 360), 328.0);
    });

    test('窄屏不放大小于基准边长，即不引入新的溢出', () {
      expect(qrSideFor(payloadBytes: 437, availableWidth: 200), 240.0);
      expect(qrSideFor(payloadBytes: 437, availableWidth: 0), 240.0);
    });

    test('边界：恰好 200 字节不放大，201 放大', () {
      expect(qrSideFor(payloadBytes: 200, availableWidth: 800), 240.0);
      expect(qrSideFor(payloadBytes: 201, availableWidth: 800), 400.0);
    });
  });

  group('二维码密度（H2 守卫）', () {
    // 屏幕显示、近距离用手机相机扫：业界经验是 ≥4 px/模块比较稳，2 px 左右开始
    // 勉强。不带名字时的基线是 240/49 ≈ 4.9 px，已知可扫。
    const comfortable = 4.0;

    test('名字确实把二维码版本推高了 —— 这才是需要放大的原因', () {
      final baseline = modulesFor(qrWith(null));
      final cjk = qrWith('客厅电视' * 8); // 32 runes
      expect(qrWith(null).length, lessThan(200));
      expect(qrWith('Hub Alpha').length, lessThan(200));
      expect(cjk.length, greaterThan(200));
      expect(modulesFor(cjk), greaterThan(baseline));
    });

    test('宽屏：最坏情况放大后达到舒适密度', () {
      for (final payload in [qrWith('客厅电视' * 8), qrWith('😀' * 32)]) {
        final side = qrSideFor(payloadBytes: payload.length, availableWidth: 800);
        final density = side / modulesFor(payload);
        expect(density, greaterThanOrEqualTo(comfortable),
            reason: 'payload=${payload.length} bytes, modules=${modulesFor(payload)}');
      }
    });

    test('窄屏：宽度是硬限，密度下降但不溢出', () {
      // 360px 手机：可用宽度 360，扣掉 Container 内边距 32 后是 328 < 400。
      final emoji = qrWith('😀' * 32);
      final side = qrSideFor(payloadBytes: emoji.length, availableWidth: 360);
      expect(side, 328.0);
      // 二维码连同 Container 内边距必须放得进这一行。
      expect(side + 32.0, lessThanOrEqualTo(360.0));
      // 这里达不到 comfortable：二维码不可能比屏幕还宽。记录当前值，
      // 将来若为了别的改动把版本推得更高，这条会先炸。
      expect(side / modulesFor(emoji), greaterThan(3.5));
    });

    test('32 runes 的名字确实被截断，不会继续拉长 payload', () {
      final at32 = qrWith('客' * 32);
      final at200 = qrWith('客' * 200);
      expect(at32, at200, reason: '两者都应截断到同样的 32 runes');
      expect(at32.length, lessThan(500));
    });
  });
}
