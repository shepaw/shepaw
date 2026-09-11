import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/pairing_payload.dart';

/// 32 字节全零公钥（`pk` 的 base64url 无填充编码）。
const _pk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// `sha256(<32 个 0 字节>)[:8]` —— 与 [_pk] 自洽，见 `_fingerprintOf`。
/// 由 node 的 `crypto.createHash('sha256')` 独立算出，不是从 Dart 侧反推的。
const _fp = '66687aadf862bd77';

const _local = 'ws://192.168.1.5:18793/peer/ws';

Uint8List zeroKey() => Uint8List(32);

/// 与生产代码同算法，仅用于构造自洽的测试输入。
String fingerprintOf(Uint8List key) {
  final digest = crypto.sha256.convert(key).bytes;
  final sb = StringBuffer();
  for (var i = 0; i < 8; i++) {
    sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// 手写的旧格式 payload（无 `name=`）—— 刻意不走 `encode`，
/// 用来证明「不产生 name 的旧二维码」仍能被解析。
const _legacyRaw = 'shepaw://peer?local=ws%3A%2F%2F192.168.1.5%3A18793%2Fpeer%2Fws'
    '&code=ABC23456#fp=$_fp&pk=$_pk';

String encodeWith({
  String? name,
  String? channelEndpoint,
  String fingerprint = _fp,
  Uint8List? publicKey,
  String code = 'ABC23456',
}) =>
    PeerPairingInfo.encode(
      localEndpoint: _local,
      channelEndpoint: channelEndpoint,
      code: code,
      fingerprint: fingerprint,
      publicKey: publicKey ?? zeroKey(),
      name: name,
    );

/// 在 `#` 前插入一个额外 query 参数（模拟旧格式 / 未来新增参数）。
String withExtraParam(String param) => _legacyRaw.replaceFirst('#fp=', '&$param#fp=');

void main() {
  group('PeerPairingInfo.tryParse', () {
    test('旧格式（无 name=）→ name 与 displayName 均为 null', () {
      final info = PeerPairingInfo.tryParse(_legacyRaw);
      expect(info, isNotNull);
      expect(info!.name, isNull);
      expect(info.displayName, isNull);
      expect(info.code, 'ABC23456');
      expect(info.fingerprint, _fp);
      expect(info.publicKey, zeroKey());
      expect(info.localEndpoint, _local);
      expect(info.mode, PeerConnectMode.local);
    });

    test('name= 与 name=%20%20 都视为「没有名字」', () {
      for (final param in ['name=', 'name=%20%20', 'name=%09']) {
        final info = PeerPairingInfo.tryParse(withExtraParam(param));
        expect(info, isNotNull, reason: param);
        expect(info!.name, isNull, reason: param);
      }
    });

    test('多余的未知参数不影响解析（前向兼容）', () {
      final info = PeerPairingInfo.tryParse(withExtraParam('future=1&v=2'));
      expect(info, isNotNull);
      expect(info!.fingerprint, _fp);
      expect(info.name, isNull);
    });

    test('分隔符敌意名字解析正确，且指纹仍然对得上', () {
      final info = PeerPairingInfo.tryParse(encodeWith(name: 'A&B=C#D'));
      expect(info, isNotNull);
      expect(info!.name, 'A&B=C#D');
      expect(info.fingerprint, _fp);
      expect(info.publicKey, zeroKey());
    });

    test('安全回归：带 name 的 payload 改动 pk 一个字节 → 拒绝', () {
      final raw = encodeWith(name: 'Hub Alpha');
      // 改 pk 的**首位**：末位只承载 2 个被丢弃的填充位，改它解出的字节不变。
      final tampered = raw.replaceFirst('pk=A', 'pk=B');
      expect(tampered, isNot(raw));
      // 指纹校验必须仍在跑，不能被 name 分支绕过。
      expect(PeerPairingInfo.tryParse(tampered), isNull);
    });
  });

  group('PeerPairingInfo.encode', () {
    test('encode → tryParse 往返：字段全部保持', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
      final info = PeerPairingInfo.tryParse(
        encodeWith(
          name: '客厅电视',
          channelEndpoint: 'wss://channel.example.com/proxy/ch_peer/peer/ws',
          fingerprint: fingerprintOf(key),
          publicKey: key,
        ),
      );
      expect(info, isNotNull);
      expect(info!.name, '客厅电视');
      expect(info.code, 'ABC23456');
      expect(info.fingerprint, fingerprintOf(key));
      expect(info.publicKey, key);
      expect(info.localEndpoint, _local);
      expect(
        info.channelEndpoint,
        'wss://channel.example.com/proxy/ch_peer/peer/ws',
      );
      expect(info.mode, PeerConnectMode.local);
    });

    test('空格编码为 %20，不是 +', () {
      final raw = encodeWith(name: 'Hub Alpha');
      expect(raw, contains('name=Hub%20Alpha'));
      expect(raw, isNot(contains('name=Hub+Alpha')));
    });

    test('name 是最后一个 query 参数，且在 fragment 之前', () {
      final raw = encodeWith(
        name: 'Hub Alpha',
        channelEndpoint: 'wss://channel.example.com/proxy/ch_peer/peer/ws',
      );
      expect(raw.indexOf('&name='), greaterThan(raw.indexOf('&code=')));
      expect(raw.indexOf('&name='), lessThan(raw.indexOf('#')));
      // fragment 只有 fp/pk —— 它是信任锚，不能被 name 污染。
      expect(Uri.parse(raw).fragment, 'fp=$_fp&pk=$_pk');
    });

    test('null / 空 / 纯空白 name → 与旧格式逐字节相同', () {
      final legacy = encodeWith();
      expect(legacy, isNot(contains('name=')));
      expect(legacy, _legacyRaw);
      expect(encodeWith(name: ''), legacy);
      expect(encodeWith(name: '   '), legacy);
    });

    test('跨仓 golden：与 hub 的 buildPeerQrPayload 字节一致', () {
      // 同一组字面量固定在
      // agent-hub/core/test/peer-pairing.test.ts（"matches the cross-repo golden"）。
      // 这是唯一能抓住两侧参数顺序 / 转义集漂移的测试。
      expect(
        encodeWith(fingerprint: 'aabbccddeeff0011', name: '客厅 Hub (A)'),
        'shepaw://peer?local=ws%3A%2F%2F192.168.1.5%3A18793%2Fpeer%2Fws'
        '&code=ABC23456&name=%E5%AE%A2%E5%8E%85%20Hub%20(A)'
        '#fp=aabbccddeeff0011&pk=$_pk',
      );
      // `!~*'()` 在 encodeURIComponent 下保持字面；`&` `=` `#` 被转义。
      expect(
        encodeWith(fingerprint: 'aabbccddeeff0011', name: "A&B=C#D!~*'()"),
        'shepaw://peer?local=ws%3A%2F%2F192.168.1.5%3A18793%2Fpeer%2Fws'
        "&code=ABC23456&name=A%26B%3DC%23D!~*'()"
        '#fp=aabbccddeeff0011&pk=$_pk',
      );
      expect(
        encodeWith(fingerprint: 'aabbccddeeff0011'),
        'shepaw://peer?local=ws%3A%2F%2F192.168.1.5%3A18793%2Fpeer%2Fws'
        '&code=ABC23456#fp=aabbccddeeff0011&pk=$_pk',
      );
    });

    test('emoji 名字按 rune 截断到 32，不抛异常', () {
      final raw = encodeWith(name: '😀' * 40);
      final decoded = Uri.parse(raw).queryParameters['name'];
      expect(decoded, isNotNull);
      expect(decoded!.runes.length, 32);
      expect(decoded, '😀' * 32);
    });
  });

  group('PeerPairingInfo.displayName', () {
    PeerPairingInfo withName(String? name) => PeerPairingInfo(
          localEndpoint: _local,
          code: 'ABC23456',
          fingerprint: _fp,
          publicKey: zeroKey(),
          name: name,
        );

    test('剥掉双向覆盖符与 C0 控制字符', () {
      // 用 \uXXXX 转义而不是字面量：字面量会让源码本身不可读，也会被 lint 警告 ——
      // 这恰好说明为什么它们不该出现在设备名里。
      expect(withName('Ma\u202Ec').displayName, 'Mac'); // RLO：视觉上反向渲染
      expect(withName('\u202A\u202E').displayName, isNull);
      expect(withName('\u2066evil\u2069').displayName, 'evil'); // LRI…PDI
      expect(withName('a\u200Eb\u200Fc').displayName, 'abc'); // LRM / RLM
      expect(withName('客厅\n电视').displayName, '客厅电视'); // C0 控制符
      expect(withName('xy\u007F').displayName, 'xy'); // DEL
    });

    test('折叠连续空白并去掉首尾空白', () {
      expect(withName('  Hub   Alpha  ').displayName, 'Hub Alpha');
      expect(withName('\u5ba2\u5385\u3000\u3000\u7535\u89c6').displayName,
          '\u5ba2\u5385 \u7535\u89c6'); // U+3000 表意空格
      expect(withName('Hub\u00A0Alpha').displayName, 'Hub Alpha'); // NBSP
    });

    test('按 rune 截断到 32', () {
      expect(withName('\u{1F600}' * 40).displayName, '\u{1F600}' * 32);
      expect(withName('a' * 40).displayName, 'a' * 32);
    });

    test('清洗后为空 → null', () {
      expect(withName('\u202E\u202D').displayName, isNull);
      expect(withName('   ').displayName, isNull);
      expect(withName(null).displayName, isNull);
    });

    test('name 字段本身保留原始值（清洗只在 getter 里做）', () {
      final info = withName('  Ma\u202Ec  ');
      expect(info.name, '  Ma\u202Ec  ');
      expect(info.displayName, 'Mac');
    });
  });

  group('PeerPairingInfo.copyWith', () {
    test('未传的字段保持原值，传了的字段被覆盖', () {
      final key = Uint8List(32);
      final base = PeerPairingInfo(
        localEndpoint: _local,
        channelEndpoint: 'wss://channel.example.com/proxy/ch_peer/peer/ws',
        code: 'ABC23456',
        fingerprint: _fp,
        publicKey: key,
        name: 'Hub Alpha',
      );

      final same = base.copyWith();
      expect(same.localEndpoint, base.localEndpoint);
      expect(same.channelEndpoint, base.channelEndpoint);
      expect(same.code, base.code);
      expect(same.fingerprint, base.fingerprint);
      expect(same.publicKey, key);
      expect(same.name, 'Hub Alpha');

      // local_agent_hub_service 把 LAN 端点改写成 loopback 时走的正是这条路径；
      // name 必须活下来。
      final rewritten = base.copyWith(localEndpoint: 'ws://127.0.0.1:18793/peer/ws');
      expect(rewritten.localEndpoint, 'ws://127.0.0.1:18793/peer/ws');
      expect(rewritten.name, 'Hub Alpha');
      expect(rewritten.channelEndpoint, base.channelEndpoint);
      expect(rewritten.code, base.code);
      expect(rewritten.fingerprint, base.fingerprint);
      expect(rewritten.publicKey, key);
    });
  });
}
