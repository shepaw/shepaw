import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../storage/pouch_session.dart';
import 'widgets/join_code_card.dart';

/// 首次设置完成。顺手把手机也带上。
///
/// 这里的加入码是**主机**签发的：手机扫了它，配对之后直接进入，不用输密码。
/// 以前摆的是 App 对等端的配对码，手机扫了登不上主机。
class SetupDoneScreen extends StatefulWidget {
  const SetupDoneScreen({super.key});

  @override
  State<SetupDoneScreen> createState() => _SetupDoneScreenState();
}

class _SetupDoneScreenState extends State<SetupDoneScreen> {
  String? _hostPeerId;

  @override
  void initState() {
    super.initState();
    _loadHost();
  }

  Future<void> _loadHost() async {
    final session = await PouchSessionStore.readActive();
    if (!mounted) return;
    setState(() => _hostPeerId = session?.hostPeerId ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final host = _hostPeerId;
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
                  host == null
                      ? const SizedBox(
                          height: 180,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      : JoinCodeCard(hostPeerId: host),
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
}
