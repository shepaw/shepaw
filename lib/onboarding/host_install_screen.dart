import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/cli_host.dart';
import '../../services/logger_service.dart';
import 'gate_entry.dart';
import 'gate_navigator.dart';
import 'host_install_controller.dart';
import 'widgets/step_list.dart';

/// 准备本机主机：安装 → 启动 → 连接。
///
/// 失败时停在失败的那一步，「重试」从那一步继续，不从头再来。
/// 回访时这一页常常不出现：Splash 原地跑完 2 秒内就继续走了（见 GateNavigator）。
class HostInstallScreen extends StatefulWidget {
  const HostInstallScreen({super.key, this.controller, this.reason});

  /// Splash 已经在跑的那个。没有就自己 new 一个。
  final HostInstallController? controller;

  final HostInstallReason? reason;

  @override
  State<HostInstallScreen> createState() => _HostInstallScreenState();
}

class _HostInstallScreenState extends State<HostInstallScreen> {
  late final HostInstallController _gate;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _gate = widget.controller ??
        HostInstallController(
          reason: widget.reason ?? HostInstallReason.firstInstall,
          log: (message) => LoggerService().info(message, tag: 'HostInstall'),
        );
    _gate.addListener(_onChanged);
    if (widget.controller == null) {
      unawaited(_gate.start());
    } else if (!_gate.busy && !_gate.done && _gate.failedStep == null) {
      unawaited(_gate.start());
    }
    // 「进行中」要显示秒数。
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_gate.busy && mounted) setState(() {});
    });
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (_gate.done) unawaited(_afterDone());
  }

  /// 主机就绪了：回到 GateNavigator 重新判断一次（可能要去设密码，也可能直接进）。
  Future<void> _afterDone() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await GateNavigator.go(context);
  }

  @override
  void dispose() {
    _tick?.cancel();
    // 只有自己 new 的才 dispose；Splash 传过来的那个还归 Splash 管吗 ——
    // Splash 已经被 replace 掉了，所以这里一律释放。
    _gate.removeListener(_onChanged);
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 32),
                  Text(
                    l10n.hostInstall_title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 24),
                  ListenableBuilder(
                    listenable: _gate,
                    builder: (context, _) => StepList(
                      steps: _gate.steps,
                      elapsed: _gate.elapsed,
                      failedDetailBuilder: (step) => switch (step) {
                        HostInstallStep.install =>
                          l10n.hostInstall_installFailed,
                        HostInstallStep.start => l10n.hostInstall_startFailed,
                        HostInstallStep.connect =>
                          l10n.hostInstall_unresponsive,
                      },
                      failureDetail: _gate.failureDetail,
                      logTail: _gate.logTail,
                      onRetry: _gate.busy ? null : () => _gate.retry(),
                      onOpenLog: () => _openLog(l10n),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () => Navigator.of(context)
                        .pushReplacementNamed('/welcome'),
                    child: Text(l10n.hostInstall_useOther),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openLog(AppLocalizations l10n) {
    final file = CliHost.logFile();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.hostInstall_openLog),
        content: SizedBox(
          width: double.maxFinite,
          child: SelectableText(
            _gate.logTail ?? file.path,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }
}
