import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/route_gate.dart';
import '../storage/pouch_login_keeper.dart';

/// 主机要求重新登录时，登录页之外的页面顶部一直挂着的一条提示。
///
/// 主机重启会作废登录会话，自动恢复又走不通（凭据失效且本进程没有密码）时，
/// 业务帧会被主机全部丢掉：界面上看起来只是「没有回复」。这条提示把原因说
/// 出来，并给一个去登录的入口。门页上不显示（登录页自己会讲）。
class PouchReloginBanner extends StatelessWidget {
  const PouchReloginBanner({
    super.key,
    required this.child,
    this.required,
    this.onSignIn,
  });

  final Widget child;

  /// 是否要登录。缺省跟 [PouchLoginKeeper.passwordRequired] 走。
  final ValueListenable<bool>? required;

  /// 点提示条 / 「去登录」时做什么。缺省跳登录页。
  final VoidCallback? onSignIn;

  @override
  Widget build(BuildContext context) {
    final listenable = required ?? PouchLoginKeeper.instance.passwordRequired;
    return ValueListenableBuilder<bool>(
      valueListenable: RouteGateObserver.onGate,
      child: child,
      builder: (context, onGate, child) {
        if (onGate) return child!;
        return ValueListenableBuilder<bool>(
          valueListenable: listenable,
          child: child,
          builder: (context, needed, child) {
            if (!needed) return child!;
            return _BannerBar(
              onSignIn: onSignIn ?? PouchLoginKeeper.instance.requestSignIn,
              child: child!,
            );
          },
        );
      },
    );
  }
}

class _BannerBar extends StatelessWidget {
  const _BannerBar({required this.onSignIn, required this.child});

  final VoidCallback onSignIn;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = colorScheme.onTertiaryContainer;

    return Column(
      children: [
        Material(
          color: colorScheme.tertiaryContainer,
          elevation: 1,
          child: SafeArea(
            bottom: false,
            child: InkWell(
              onTap: onSignIn,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, size: 20, color: foreground),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.pouch_reloginTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                          ),
                          Text(
                            l10n.pouch_reloginBody,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: foreground.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onSignIn,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: foreground,
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      child: Text(l10n.pouch_reloginAction),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}
