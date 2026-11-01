import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/paired_peer.dart';
import '../../peer/models/pairing_payload.dart';
import '../../peer/pouch_pair.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../services/logger_service.dart';
import '../storage/pouch_login_client.dart';
import '../storage/pouch_session.dart';
import 'widgets/gate_widgets.dart';

/// 加入的结果。
enum JoinOutcome {
  /// 带邀请，已经免密进去了。
  entered,

  /// 主机已经设过密码，去输密码（L6 之后，带邀请就直接进主页）。
  unlock,

  /// 主机还没设过密码，等电脑上设完。
  waitHost,

  /// 连不上主机。
  offline,
}

/// 扫码 / 粘贴之后的过渡态。
///
/// 配对、连接、问主机这一步共用一份预算（15 秒）。以前每次探测都重新等 15 秒，
/// 再乘上重试次数，用户最坏要盯着空白页一分钟。
class JoiningView extends StatefulWidget {
  const JoiningView({
    super.key,
    required this.info,
    required this.onDone,
    required this.onCancel,
    this.budget = const Duration(seconds: 15),
    JoiningSteps? steps,
  }) : _steps = steps;

  final PeerPairingInfo info;

  /// 拿到结果。失败时也会回调（[JoinOutcome.offline]），那时 peer 可能是 null。
  final void Function(PairedPeer? peer, JoinOutcome outcome) onDone;

  final VoidCallback onCancel;
  final Duration budget;
  final JoiningSteps? _steps;

  @override
  State<JoiningView> createState() => _JoiningViewState();
}

/// 真正干活的那层。抽出来是为了测试里换掉。
abstract class JoiningSteps {
  const JoiningSteps();

  Future<PairedPeer> pair(PeerPairingInfo info);
  Future<void> connect(PairedPeer peer, {required bool redial});
  Future<bool> passwordSet(String hostPeerId);

  /// 带邀请免密登录。袋子 id 由主机按邀请记录给出。
  Future<PouchLoginGrant> redeemInvite({
    required String hostPeerId,
    required String inviteId,
  });
}

class DefaultJoiningSteps implements JoiningSteps {
  const DefaultJoiningSteps();

  @override
  Future<PairedPeer> pair(PeerPairingInfo info) =>
      PouchPairing.request(info);

  @override
  Future<void> connect(
    PairedPeer peer, {
    required bool redial,
  }) async {
    if (redial) {
      await PeerConnectionManager.instance.disconnectPeer(peer.id);
    }
    await PeerConnectionManager.instance.connectToPeer(
      peer,
      ignoreTieBreak: true,
    );
  }

  @override
  Future<bool> passwordSet(String hostPeerId) =>
      requestPouchPasswordStatus(hostPeerId: hostPeerId);

  @override
  Future<PouchLoginGrant> redeemInvite({
    required String hostPeerId,
    required String inviteId,
  }) =>
      requestPouchInviteLogin(
        hostPeerId: hostPeerId,
        inviteId: inviteId,
      );
}

class _JoiningViewState extends State<JoiningView> {
  late final JoiningSteps _steps;
  bool _cancelled = false;
  PairedPeer? _paired;
  String _hostName = '';
  String? _detail;

  @override
  void initState() {
    super.initState();
    _steps = widget._steps ?? const DefaultJoiningSteps();
    _hostName = widget.info.name ?? '';
    unawaited(_run());
  }

  Future<void> _run() async {
    final deadline = DateTime.now().add(widget.budget);
    try {
      final peer = await _steps.pair(widget.info).timeout(_left(deadline));
      if (!mounted || _cancelled) return;
      _paired = peer;
      if (peer.deviceName.isNotEmpty) {
        setState(() => _hostName = peer.deviceName);
      }
      // 息屏回来第一次常常是半开连接，超时就断开重来一次（共用同一份预算）。
      try {
        await _steps.connect(peer, redial: false).timeout(_left(deadline));
      } catch (_) {
        if (!mounted || _cancelled) return;
        if (_left(deadline) <= Duration.zero) rethrow;
        await _steps.connect(peer, redial: true).timeout(_left(deadline));
      }
      if (!mounted || _cancelled) return;
      // 链接里带邀请：这台设备刚用这个码证明过自己，不用再输密码。
      final inviteId = widget.info.inviteId?.trim() ?? '';
      if (inviteId.isNotEmpty) {
        try {
          await _steps
              .redeemInvite(hostPeerId: peer.id, inviteId: inviteId)
              .timeout(_left(deadline));
          if (!mounted || _cancelled) return;
          widget.onDone(peer, JoinOutcome.entered);
          return;
        } catch (error) {
          LoggerService()
              .warning('invite redemption failed: $error', tag: 'Joining');
          // 兑不了就退回输密码，别把人卡在外面。
        }
      }
      final set = await _steps.passwordSet(peer.id).timeout(_left(deadline));
      if (!mounted || _cancelled) return;
      widget.onDone(peer, set ? JoinOutcome.unlock : JoinOutcome.waitHost);
    } catch (error) {
      LoggerService().error('join failed', tag: 'Joining', error: error);
      if (!mounted || _cancelled) return;
      setState(() {
        _detail = error.toString();
      });
      widget.onDone(_paired, JoinOutcome.offline);
    }
  }

  Duration _left(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    return left > Duration.zero ? left : const Duration(milliseconds: 1);
  }

  void _cancel() {
    _cancelled = true;
    widget.onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SizedBox(height: 64),
                Center(child: _PulseLink(hostName: _hostName)),
                const SizedBox(height: 24),
                Text(
                  l10n.connect_connecting(_hostName.isEmpty
                      ? l10n.welcome_phoneTitle
                      : _hostName),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 32),
                Center(child: const CircularProgressIndicator()),
                const SizedBox(height: 32),
                TextButton(
                  onPressed: _cancel,
                  child: Text(l10n.common_cancel),
                ),
                if (_detail != null)
                  GateStatusCard(
                    title: l10n.gate_errorUnreachable,
                    detail: _detail,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseLink extends StatefulWidget {
  const _PulseLink({required this.hostName});

  final String hostName;

  @override
  State<_PulseLink> createState() => _PulseLinkState();
}

class _PulseLinkState extends State<_PulseLink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Opacity(
        opacity: 0.5 + _pulse.value * 0.5,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.computer_outlined, size: 32),
            const SizedBox(width: 12),
            const Icon(Icons.sync_alt, size: 20),
            const SizedBox(width: 12),
            const Icon(Icons.phone_android_outlined, size: 32),
          ],
        ),
      ),
    );
  }
}
