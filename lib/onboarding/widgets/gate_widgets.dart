import 'dart:math' show sin, pi;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../theme/app_theme.dart';

/// 门页的骨架。
///
/// 以前每一页都是 `AppBar + ListView`，在桌面的宽窗口上铺满整屏，看着像设置页。
/// 这里统一成：浅色品牌背景、内容最大宽 440（桌面居中成卡片、手机全宽）、
/// 底部留一块给次要操作，并且负责键盘避让。
class GateScaffold extends StatelessWidget {
  const GateScaffold({
    super.key,
    this.avatar,
    this.title,
    this.subtitle,
    required this.body,
    this.footer,
  });

  /// 顶部的小图标或头像。
  final Widget? avatar;

  final String? title;
  final String? subtitle;

  /// 中间可滚动的部分。
  final List<Widget> body;

  /// 底部次要操作（忘记密码、换主机……）。键盘弹起时会被顶上去。
  final Widget? footer;

  static const double maxWidth = 440;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      backgroundColor: scheme.surface,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              AppTheme.brandGradient.colors.first.withValues(alpha: 0.14),
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxWidth),
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
                      children: [
                        if (avatar != null) ...[
                          Center(child: avatar!),
                          const SizedBox(height: 20),
                        ],
                        if (title != null)
                          Text(
                            title!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            subtitle!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 28),
                        ...body,
                      ],
                    ),
                  ),
                  if (footer != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        8,
                        24,
                        16 + MediaQuery.viewInsetsOf(context).bottom,
                      ),
                      child: footer,
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

/// 主机密码输入框。
///
/// 以前没有显示 / 隐藏，也没有大写锁定提示，用户输错了才知道规则。
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.focusNode,
    this.enabled = true,
    this.autofocus = false,
    this.errorText,
    this.minLength = 6,
    this.hint,
    this.onSubmitted,
    this.shakeKey,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool enabled;
  final bool autofocus;
  final String? errorText;

  /// 少于这个长度时给提示，但不拦住提交（提交时再报错）。
  final int minLength;
  final String? hint;
  final ValueChanged<String>? onSubmitted;

  /// 变一次抖一下。密码错时用它。
  final int? shakeKey;

  @override
  State<PasswordField> createState() => PasswordFieldState();
}

@visibleForTesting
class PasswordFieldState extends State<PasswordField>
    with SingleTickerProviderStateMixin {
  bool _obscure = true;
  bool _capsLock = false;
  late final AnimationController _shake;
  int? _lastShakeKey;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant PasswordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
    if (widget.shakeKey != null && widget.shakeKey != _lastShakeKey) {
      _lastShakeKey = widget.shakeKey;
      _shake.forward(from: 0);
    }
  }

  void _onChanged() {
    if (!mounted) return;
    final next = widget.controller.text.length < widget.minLength;
    if (next != _tooShort) setState(() => _tooShort = next);
  }

  bool _tooShort = true;

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _shake.dispose();
    super.dispose();
  }

  /// 桌面上大写锁定开着时提醒一句：密码是隐藏的，看不出来。
  void _refreshCapsLock() {
    final modes = HardwareKeyboard.instance.lockModesEnabled;
    final on = modes.contains(KeyboardLockMode.capsLock);
    if (on != _capsLock && mounted) setState(() => _capsLock = on);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    _refreshCapsLock();
    final showHint = _tooShort && widget.enabled;
    return AnimatedBuilder(
      animation: _shake,
      builder: (context, child) {
        // 300ms 里来回 3 次，见设计文档 7.6。
        final offset = 8 * sin(_shake.value * 6 * pi);
        return Transform.translate(offset: Offset(offset, 0), child: child);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: widget.focusNode,
            enabled: widget.enabled,
            autofocus: widget.autofocus,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(
              labelText: l10n.password_label,
              hintText: widget.hint,
              errorText: widget.errorText,
              suffixIcon: IconButton(
                tooltip: _obscure ? l10n.password_show : l10n.password_hide,
                icon: Icon(
                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: widget.onSubmitted,
          ),
          if (showHint || _capsLock) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (showHint)
                  Text(
                    l10n.password_minLength,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const Spacer(),
                if (_capsLock)
                  Text(
                    l10n.password_capsLock,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.primary),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 主机名 + 在线状态 + 重试。
class HostStatusPill extends StatelessWidget {
  const HostStatusPill({
    super.key,
    required this.hostName,
    required this.status,
    this.thisComputer = false,
    this.onRetry,
  });

  final String hostName;
  final HostReachability status;
  final bool thisComputer;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (color, label) = switch (status) {
      HostReachability.online => (const Color(0xFF2E9E5B), l10n.hostStatus_online),
      HostReachability.connecting =>
        (scheme.outline, l10n.hostStatus_connecting),
      HostReachability.offline => (scheme.error, l10n.hostStatus_offline),
      HostReachability.unknown => (scheme.outline, l10n.hostStatus_offline),
    };
    final suffix = thisComputer ? ' · ${l10n.unlock_hostThisComputer}' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          switch (status) {
            HostReachability.online => Icons.circle,
            HostReachability.connecting => Icons.pending_outlined,
            _ => Icons.circle_outlined,
          },
          size: 10,
          color: color,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '${l10n.unlock_hostLine(hostName)}$suffix · $label',
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (status == HostReachability.offline && onRetry != null)
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: Size.zero,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(l10n.gate_retry),
          ),
      ],
    );
  }
}

/// 主机的连通情况。
enum HostReachability { unknown, connecting, online, offline }

/// 离线 / 失败时的一张说明卡。带一个可折叠的「详情」，原始错误只在这里露出来。
class GateStatusCard extends StatelessWidget {
  const GateStatusCard({
    super.key,
    required this.title,
    this.body,
    this.detail,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.shakeKey,
  });

  final String title;
  final String? body;
  final String? detail;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final int? shakeKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!),
            ],
            if (primaryLabel != null || secondaryLabel != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (primaryLabel != null)
                    FilledButton(
                      onPressed: onPrimary,
                      child: Text(primaryLabel!),
                    ),
                  if (secondaryLabel != null)
                    OutlinedButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel!),
                    ),
                ],
              ),
            ],
            if (detail != null && detail!.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  l10n.gate_details,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SelectableText(
                      detail!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
