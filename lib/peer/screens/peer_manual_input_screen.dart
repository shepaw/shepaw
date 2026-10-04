import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/logger_service.dart';
import '../models/paired_peer.dart';
import '../models/pairing_payload.dart';
import '../pouch_pair.dart';
import '../services/peer_pairing_service.dart';
import '../widgets/peer_pairing_confirm_card.dart';

/// 「我连它」的手动输入页：只接受 `shepaw://` 配对链接。
///
/// 拆成两步：先解析并展示确认卡片，用户核对无误后再连接。
/// 卡片里的设备名是对方**自述**的、未经认证的标签；真正的凭据是指纹。
class PeerManualInputScreen extends StatefulWidget {
  const PeerManualInputScreen({
    super.key,
    this.onPaired,
    this.showGuide = false,
  });

  final void Function(PairedPeer peer)? onPaired;

  /// 打开时是否直接展开怎么在对方电脑上启动主机的指引。
  final bool showGuide;

  static Future<PairedPeer?> show(
    BuildContext context, {
    bool showGuide = false,
  }) {
    return Navigator.of(context).push<PairedPeer?>(
      MaterialPageRoute<PairedPeer?>(
        builder: (_) => PeerManualInputScreen(showGuide: showGuide),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<PeerManualInputScreen> createState() => _PeerManualInputScreenState();
}

enum _InputKind { empty, link, unknown }

class _PeerManualInputScreenState extends State<PeerManualInputScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  late bool _guideExpanded = widget.showGuide;

  bool _connecting = false;
  String? _error;
  String? _statusMessage;
  _InputKind _kind = _InputKind.empty;

  /// 已解析、等待用户确认的配对信息。非空时页面渲染确认卡片。
  PeerPairingInfo? _pendingInfo;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onInputChanged);
    _controller.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final next = _classify(_controller.text);
    if (next == _kind && _error == null) return;
    setState(() {
      _kind = next;
      _error = null;
    });
  }

  _InputKind _classify(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return _InputKind.empty;
    if (PeerPairingInfo.tryParse(trimmed) != null) return _InputKind.link;
    return _InputKind.unknown;
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    _controller.text = text.trim();
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    if (!mounted) return;
    setState(() => _error = null);
    // 贴进来就是完整配对链接时，少点一次「发起配对」。
    if (_classify(_controller.text) == _InputKind.link) {
      await _submit();
    }
  }

  /// 第一步：只接受 `shepaw://` 配对链接。成功则进入确认卡片。
  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = l10n.peerManual_emptyError);
      return;
    }

    final info = PeerPairingInfo.tryParse(raw);
    if (info != null) {
      setState(() {
        _error = null;
        _pendingInfo = info;
      });
      return;
    }

    setState(() => _error = l10n.peerManual_invalidError);
  }

  /// 第二步：用户在卡片上确认后才真正发起连接。
  Future<void> _connect(PeerPairingInfo info) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _connecting = true;
      _error = null;
      _statusMessage = l10n.peerManual_connecting;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && _connecting && _error == null) {
        setState(() => _statusMessage = l10n.peerManual_waitingConfirm);
      }
    });

    try {
      final peer = await PouchPairing.request(info);
      if (!mounted) return;
      setState(() => _statusMessage = l10n.peerManual_success);
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final onPaired = widget.onPaired;
      if (onPaired != null) {
        onPaired(peer);
      } else {
        Navigator.of(context).pop(peer);
      }
    } on PairingRejectedException {
      _showError(l10n.peerManual_rejected);
    } on PairingTimeoutException {
      _showError(l10n.peerManual_timeout);
    } catch (e) {
      LoggerService().error('manual pairing failed', tag: 'PeerManual', error: e);
      _showError(l10n.peer_pairingFailedRetry);
    }
  }

  /// 失败时**保留**确认卡片：错误渲染在卡片内，重试只需再点一次确认。
  void _showError(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _connecting = false;
      _statusMessage = null;
    });
  }

  void _cancelPending() {
    setState(() {
      _pendingInfo = null;
      _error = null;
    });
  }

  Future<void> _copyGuide() async {
    final l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: l10n.peerHub_guideBody));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.peerHub_guideCopied)),
    );
  }

  void _toggleGuide() {
    HapticFeedback.selectionClick();
    setState(() => _guideExpanded = !_guideExpanded);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.peerManual_title)),
      body: SafeArea(child: _buildBody(context, l10n)),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final Widget child;
    if (_connecting) {
      child = _buildConnecting(context, l10n);
    } else if (_pendingInfo != null) {
      child = _buildConfirmCard(context, l10n, _pendingInfo!);
    } else {
      child = _buildInputForm(context, l10n);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: KeyedSubtree(
        key: ValueKey<String>(
          _connecting
              ? 'connecting'
              : _pendingInfo != null
                  ? 'confirm'
                  : 'input',
        ),
        child: child,
      ),
    );
  }

  Widget _buildConnecting(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _statusMessage ?? l10n.common_processing,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputForm(BuildContext context, AppLocalizations l10n) {
    const busy = false;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            children: [
              _buildGuideCard(context, l10n),
              const SizedBox(height: 16),
              _buildInputCard(context, l10n, busy),
            ],
          ),
        ),
        _buildSubmitBar(context, l10n, busy),
      ],
    );
  }

  Widget _buildGuideCard(BuildContext context, AppLocalizations l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorScheme.onPrimaryContainer,
        );
    return Material(
      color: colorScheme.primaryContainer.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _toggleGuide,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: colorScheme.surface.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.terminal,
                            size: 20,
                            color: colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.peerHub_guideTitle,
                            style: titleStyle,
                          ),
                        ),
                        AnimatedRotation(
                          turns: _guideExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.only(left: 48, right: 8),
                      child: Text(
                        l10n.peerManual_guideHint,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.78),
                              height: 1.4,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _guideExpanded
                  ? Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: _buildGuideCommands(context, l10n, colorScheme),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGuideCommands(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.peerHub_guideCopy,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.peerHub_guideCopy,
                  onPressed: () {
                    // 点复制时不要再触发外层展开/收起。
                    _copyGuide();
                  },
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(
              l10n.peerHub_guideBody,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputCard(
    BuildContext context,
    AppLocalizations l10n,
    bool busy,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasError = _error != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasError ? colorScheme.error : colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.peerConnect_pasteTitle,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.peerManual_desc,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              focusNode: _inputFocus,
              enabled: !busy,
              maxLines: 4,
              minLines: 3,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: InputDecoration(
                hintText: l10n.peerManual_inputHint,
                filled: true,
                fillColor: colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: colorScheme.primary.withValues(alpha: 0.45),
                  ),
                ),
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              ),
              onSubmitted: busy ? null : (_) => _submit(),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildKindChip(context, l10n, colorScheme)),
                FilledButton.tonalIcon(
                  onPressed: busy ? null : _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: Text(l10n.peerManual_paste),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: hasError
                  ? Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _ErrorBanner(message: _error!),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKindChip(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme colorScheme,
  ) {
    final recognized = switch (_kind) {
      _InputKind.link => (
          l10n.peerManual_recognizedLink,
          Icons.link,
          colorScheme.primary,
        ),
      _InputKind.empty || _InputKind.unknown => null,
    };
    if (recognized == null) return const SizedBox.shrink();
    final (label, icon, color) = recognized;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitBar(
    BuildContext context,
    AppLocalizations l10n,
    bool busy,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Divider(height: 1, color: colorScheme.outlineVariant),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: busy
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.peerHub_probing),
                      ],
                    )
                  : Text(l10n.peerManual_submit),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmCard(
    BuildContext context,
    AppLocalizations l10n,
    PeerPairingInfo info,
  ) {
    return PeerPairingConfirmCard(
      info: info,
      error: _error,
      onConfirm: () => _connect(info),
      onCancel: _cancelPending,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 18, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.error,
                      height: 1.35,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
