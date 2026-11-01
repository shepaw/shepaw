import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/pouch_invite.dart';
import '../../peer/pouch_pair.dart';
import '../../services/logger_service.dart';
import 'gate_widgets.dart';

/// 出示加入码：别的设备扫了它，配对之后直接进入，不用输密码。
///
/// 邀请方（已经登录的那台）每 2 秒问一次状态；有人兑换了就换成「✓ 已加入」，
/// 并且给一个「移除」—— 那是扫码即登录的安全阀，移除要真的把那台设备踢掉。
class JoinCodeCard extends StatefulWidget {
  const JoinCodeCard({
    super.key,
    required this.hostPeerId,
    PouchInviteClient? client,
    this.pollInterval = const Duration(seconds: 2),
  }) : _client = client;

  final String hostPeerId;
  final Duration pollInterval;
  final PouchInviteClient? _client;

  @override
  State<JoinCodeCard> createState() => JoinCodeCardState();
}

@visibleForTesting
class JoinCodeCardState extends State<JoinCodeCard> {
  PouchInvite? _invite;
  PouchInviteStatus? _status;
  String? _error;
  bool _outdated = false;
  bool _busy = false;
  bool _removing = false;
  Timer? _poll;

  PouchInviteClient get _impl =>
      widget._client ?? productionInviteClient();

  @override
  void initState() {
    super.initState();
    unawaited(_mint());
  }

  Future<void> _mint() async {
    setState(() {
      _busy = true;
      _error = null;
      _invite = null;
      _status = null;
    });
    try {
      final invite = await _impl.create(hostPeerId: widget.hostPeerId);
      if (!mounted) return;
      setState(() {
        _invite = invite;
        _busy = false;
      });
      _startPolling();
    } catch (error) {
      LoggerService().warning('invite create failed: $error', tag: 'JoinCode');
      if (!mounted) return;
      setState(() {
        // 老主机不认识这三个帧，不会回包，只会等到超时。
        _outdated = error is TimeoutException;
        _error = 'failed';
        _busy = false;
      });
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(widget.pollInterval, (_) => _check());
  }

  Future<void> _check() async {
    final invite = _invite;
    if (invite == null || !mounted) return;
    try {
      final status = await _impl.status(
        hostPeerId: widget.hostPeerId,
        inviteId: invite.id,
      );
      if (!mounted) return;
      setState(() => _status = status);
      if (status.state == PouchInviteState.redeemed ||
          status.state == PouchInviteState.expired ||
          status.state == PouchInviteState.cancelled) {
        _poll?.cancel();
        _poll = null;
      }
    } catch (error) {
      LoggerService().warning('invite status failed: $error', tag: 'JoinCode');
    }
  }

  /// 邀请还没被用掉就撤掉，别让这个码一直活着。
  Future<void> _cancelIfPending() async {
    final invite = _invite;
    final status = _status;
    if (invite == null || status == null) return;
    if (status.state != PouchInviteState.pending) return;
    try {
      await _impl.cancel(
        hostPeerId: widget.hostPeerId,
        inviteId: invite.id,
      );
    } catch (error) {
      LoggerService().warning('invite cancel failed: $error', tag: 'JoinCode');
    }
  }

  Future<void> _remove() async {
    final status = _status;
    final peerId = status?.peerId;
    if (peerId == null || _removing) return;
    setState(() => _removing = true);
    try {
      await PouchPairRelay.instance.remove(
        hostPeerId: widget.hostPeerId,
        fingerprint: status!.fingerprint ?? '',
      );
      if (!mounted) return;
      setState(() {
        _removing = false;
        _status = null;
        _invite = null;
      });
      await _mint();
    } catch (error) {
      LoggerService().warning('remove joined device failed: $error',
          tag: 'JoinCode');
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_cancelIfPending());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invite = _invite;
    final status = _status;

    if (_error != null) {
      return GateStatusCard(
        title: _outdated
            ? l10n.joinCode_unsupported
            : l10n.gate_errorGeneric,
        detail: _error,
        primaryLabel: l10n.gate_retry,
        onPrimary: _mint,
      );
    }
    if (invite == null) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (status != null && status.joined) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.joinCode_joined(
                          status.deviceName ?? l10n.appTitle),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _removing ? null : _remove,
                  child: Text(l10n.joinCode_notYou),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final stale = status != null &&
        (status.state == PouchInviteState.expired ||
            status.state == PouchInviteState.cancelled);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (invite.loopback)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  l10n.joinCode_loopback,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            QrImageView(
              data: invite.link,
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            Text(
              stale
                  ? l10n.joinCode_replaced
                  : l10n.joinCode_expiresIn(_remaining(l10n)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _mint,
                  child: Text(l10n.joinCode_refresh),
                ),
                TextButton(
                  onPressed: () => _copy(invite.link),
                  child: Text(l10n.joinCode_copyLink),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _remaining(AppLocalizations l10n) {
    final left = _invite!.expiresAt.difference(DateTime.now());
    final seconds = left.inSeconds < 0 ? 0 : left.inSeconds;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return '${minutes}:${rest.toString().padLeft(2, '0')}';
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context).connect_clipboardDetected)),
    );
  }
}
