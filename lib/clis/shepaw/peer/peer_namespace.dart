import '../../cli_base.dart';
import 'accept_command.dart';
import 'list_command.dart';
import 'offer_command.dart';
import 'pair_command.dart';
import 'reject_command.dart';
import 'status_command.dart';

/// [TOOLING 层] peer 命名空间 - 设备配对与已配对设备查询
///
/// Initiator（主动连对方）：
/// - `pair`   粘贴对方 shepaw://peer?... 链接发起配对
///
/// Responder（展示二维码等人连）：
/// - `offer`  开启配对等候，返回本机 shepaw://peer 链接
/// - `status` 查看会话状态 / 待确认入站请求
/// - `accept` 确认入站配对请求
/// - `reject` 拒绝入站配对请求
///
/// 通用：
/// - `list`   列出已配对设备及连接状态
class PeerNamespace extends CliNamespace {
  static final instance = PeerNamespace._();
  PeerNamespace._();

  @override
  String get namespace => 'peer';

  @override
  String get description =>
      'Device pairing — offer/accept/reject sessions or pair via shepaw://peer link';

  @override
  String get icon => '📲';

  @override
  Map<String, CliCommand> get commands => {
        'pair': PeerPairCommand(),
        'offer': PeerOfferCommand(),
        'status': PeerStatusCommand(),
        'accept': PeerAcceptCommand(),
        'reject': PeerRejectCommand(),
        'list': PeerListCommand(),
      };
}
