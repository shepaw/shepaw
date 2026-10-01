import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'pouch_session.dart';

/// 设备锁解开之后去哪。手机和电脑同一条：登录态还在就进主页，否则去登录袋子。
enum AppStart { home, pouchLogin }

AppStart afterDeviceUnlock(PouchSession? session, {required int nowMs}) {
  if (session != null && session.isLoggedIn(nowMs)) return AppStart.home;
  return AppStart.pouchLogin;
}

/// 与 `shepaw-protocol` 的 `login_seal_required` 同一份名单。
bool loginSealRequired(String kind) {
  if (kind.startsWith('agent_')) return true;
  const names = <String>{
    'pouch',
    'pouch_dm_turn',
    'pouch_chat_read',
    'pouch_group_turn',
    'pouch_interaction_resp',
    'pouch_turn_event',
    'pouch_file_begin',
    'pouch_file_chunk',
    'pouch_file_end',
    'pouch_file_ack',
    'pouch_peer_list_req',
    'pouch_peer_list_resp',
    'memory',
    'she',
    'session_create_req',
    'session_create_resp',
    'cli_execute_req',
    'cli_execute_resp',
  };
  return names.contains(kind);
}

/// 当前登录态对应的通道密钥。业务帧经它密封后再进 Noise。
class PouchChannel {
  PouchChannel(this.session);

  static PouchChannel? active;

  final PouchSession session;
  final _aes = AesGcm.with256bits();

  static void install(PouchSession session) {
    if (!session.isLoggedIn(DateTime.now().millisecondsSinceEpoch)) {
      active = null;
      return;
    }
    active = PouchChannel(session);
  }

  static void clear() {
    active = null;
  }

  static Future<Map<String, dynamic>> sealIfNeeded(
    Map<String, dynamic> json,
  ) async {
    final channel = active;
    final type = json['type'];
    if (channel == null || type is! String || !loginSealRequired(type)) {
      return json;
    }
    return channel.seal(json);
  }

  static Future<Map<String, dynamic>> openIfSealed(
    Map<String, dynamic> json,
  ) async {
    if (json['type'] != 'pouch_sealed') return json;
    final channel = active;
    if (channel == null) {
      throw StateError('收到密封帧，但本机没有登录态');
    }
    return channel.open(json);
  }

  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> json, {
    Uint8List? nonce,
  }) async {
    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(json)),
      secretKey: await _key(),
      nonce: nonce ?? _aes.newNonce(),
      aad: utf8.encode(session.pouchId),
    );
    return <String, dynamic>{
      'type': 'pouch_sealed',
      'sid': session.sessionId,
      'pouch_id': session.pouchId,
      'n': _b64(box.nonce),
      'c': _b64(<int>[...box.cipherText, ...box.mac.bytes]),
    };
  }

  Future<Map<String, dynamic>> open(Map<String, dynamic> frame) async {
    if (frame['sid'] != session.sessionId || frame['pouch_id'] != session.pouchId) {
      throw StateError('密封帧不属于这次登录');
    }
    final combined = _b64d(frame['c'] as String);
    if (combined.length < 16) throw StateError('密封帧太短');
    final tag = combined.sublist(combined.length - 16);
    final body = combined.sublist(0, combined.length - 16);
    final plain = await _aes.decrypt(
      SecretBox(
        body,
        nonce: _b64d(frame['n'] as String),
        mac: Mac(tag),
      ),
      secretKey: await _key(),
      aad: utf8.encode(session.pouchId),
    );
    final decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map) throw StateError('密封帧不是对象');
    return decoded.cast<String, dynamic>();
  }

  Future<SecretKey> _key() async {
    final digest = crypto.sha256.convert(utf8.encode(session.token)).bytes;
    return SecretKey(digest);
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _b64d(String input) {
    var padded = input;
    final mod = padded.length % 4;
    if (mod == 2) padded += '==';
    if (mod == 3) padded += '=';
    return base64Url.decode(padded);
  }
}
