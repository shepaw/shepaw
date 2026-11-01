import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/app_localizations.dart';
import '../../services/cli_host.dart';
import '../../services/logger_service.dart';

/// 首次设置完成。顺手把手机也带上。
///
/// 这里的二维码是**主机**的配对码（`shepaw pair --json`），不是 App 对等端的码 ——
/// 手机扫了它就能连主机。L6 之后换成加入码，扫完直接进，不用输密码。
class SetupDoneScreen extends StatefulWidget {
  const SetupDoneScreen({super.key});

  @override
  State<SetupDoneScreen> createState() => _SetupDoneScreenState();
}

class _SetupDoneScreenState extends State<SetupDoneScreen> {
  String? _link;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _mint();
  }

  Future<void> _mint() async {
    try {
      final cli = await CliHost.detect();
      if (cli == null) {
        if (mounted) {
          setState(() {
            _error = 'hostOffline';
            _loading = false;
          });
        }
        return;
      }
      final link = await CliHost.mintShareLink(cli);
      if (!mounted) return;
      setState(() {
        _link = link;
        _loading = false;
      });
    } catch (error) {
      LoggerService()
          .warning('mint share link failed: $error', tag: 'SetupDone');
      if (mounted) {
        setState(() {
          // 原始错误只进日志：门页上统一显示「没能…」。
          _error = 'failed';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: scheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        l10n.done_title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Text(
                    l10n.done_phonePrompt,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  _qrCard(context),
                  const SizedBox(height: 16),
                  Text(l10n.done_phoneSteps),
                  const SizedBox(height: 32),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(context).pushReplacementNamed('/home'),
                    child: Text(l10n.done_enter),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushReplacementNamed('/home'),
                    child: Text(l10n.done_later),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _qrCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final link = _link;
    if (_loading) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (link == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _error == 'hostOffline' ? l10n.hostOffline_local : l10n.gate_errorGeneric,
          ),
        ),
      );
    }
    return _PlaceholderQr(link: link);
  }
}

/// TODO(L6)：换成 `JoinCodeCard`（带倒计时、加入成功提示、移除）。
/// 现在先摆主机的配对码，手机扫了之后仍要输一次主机密码。
class _PlaceholderQr extends StatelessWidget {
  const _PlaceholderQr({required this.link});

  final String link;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            QrImageView(
              data: link,
              version: QrVersions.auto,
              size: 180,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.connect_clipboardDetected)),
                );
              },
              icon: const Icon(Icons.copy, size: 18),
              label: Text(l10n.hostInstall_copyCommand),
            ),
          ],
        ),
      ),
    );
  }
}
