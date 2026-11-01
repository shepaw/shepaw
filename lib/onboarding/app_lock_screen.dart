import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/app_lock_service.dart';
import '../../services/biometric_service.dart';

/// 打开 App 时的锁屏。
///
/// 认证被取消就停在这里，不提供任何绕过方式 —— 开了应用锁又不拦，等于没开。
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, this.lock});

  final AppLockService? lock;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  late final AppLockService _lock;
  String _method = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _lock = widget.lock ?? AppLockService();
    _loadMethod();
  }

  Future<void> _loadMethod() async {
    final method = await BiometricService().methodLabel();
    if (!mounted) return;
    setState(() => _method = method);
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await _lock.unlock();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 56, color: scheme.primary),
                const SizedBox(height: 16),
                Text(
                  l10n.appLock_title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.fingerprint),
                  label: Text(l10n.appLock_unlock(_method)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
