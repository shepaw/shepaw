import 'package:shared_preferences/shared_preferences.dart';

/// 手机配上过的主机。有这一条，下次打开直接走密码登录。
class PhoneHostStore {
  static const key = 'phone_host_peer_id';

  static Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(key)?.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  static Future<void> write(String peerId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, peerId);
  }
}
