import 'package:flutter/foundation.dart';

/// 这次进主页是「离线进去」的：主机连不上，但本机有缓存可看。
///
/// 主机连上之后 GateController 会静默续期，成功就把它清掉。
class OfflineEntry {
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);
}
