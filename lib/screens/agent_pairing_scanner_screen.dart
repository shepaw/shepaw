import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../services/pair_deeplink.dart';
import '../widgets/qr_scanner_view.dart';

/// Full-screen camera scanner for v2.1 pairing QR codes.
///
/// Thin wrapper around [QrScannerView] — the camera/permission/lifecycle
/// shell lives there and is shared with the P2P peer scanner. What's left
/// here is the business bit: a detected payload is parsed as a
/// `shepaw://pair?...` deep-link and, on success, popped straight back to
/// the caller as a `PairDeeplink`. Anything that doesn't parse keeps the
/// camera running with a toast, so the user can just try another QR.
///
/// The caller (AddRemoteAgentScreen) receives either `PairDeeplink` or null
/// via `Navigator.push<PairDeeplink?>`. null covers all three "no result"
/// paths: user cancelled, permission denied, unsupported platform.
class AgentPairingScannerScreen extends StatefulWidget {
  const AgentPairingScannerScreen({super.key});

  static const String routeName = '/add-agent/scan-qr';

  /// Helper that hides the platform/permission dance from callers.
  /// Returns the parsed PairDeeplink on success, or null if the user
  /// backed out / lacked permission / is on a desktop platform.
  static Future<PairDeeplink?> show(BuildContext context) {
    return Navigator.of(context).push<PairDeeplink?>(
      MaterialPageRoute<PairDeeplink?>(
        builder: (_) => const AgentPairingScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<AgentPairingScannerScreen> createState() =>
      _AgentPairingScannerScreenState();
}

class _AgentPairingScannerScreenState extends State<AgentPairingScannerScreen> {
  String? _lastError;

  /// Throttle toast messages — rapid re-detection of the same bad QR
  /// would otherwise spam SnackBars and block the retry.
  DateTime? _lastToastAt;

  Future<QrScannerOutcome> _handlePayload(String raw) async {
    final l10n = AppLocalizations.of(context);
    try {
      final parsed = parsePairDeeplink(raw);
      Navigator.of(context).pop(parsed);
      return QrScannerOutcome.consumed;
    } on PairDeeplinkError catch (e) {
      // Not a pairing QR (or malformed). Keep scanning; show a toast.
      _showTransientError(e.message);
      return QrScannerOutcome.retry;
    } catch (err, stack) {
      LoggerService().error(
        'Unexpected error parsing QR payload',
        tag: 'QRScanner',
        error: err,
        stackTrace: stack,
      );
      _showTransientError(l10n.agentPair_scanFailed('${err.runtimeType}'));
      return QrScannerOutcome.retry;
    }
  }

  void _showTransientError(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    setState(() => _lastError = message);
    if (_lastToastAt != null &&
        now.difference(_lastToastAt!).inMilliseconds < 1500) {
      return;
    }
    _lastToastAt = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = _lastError;
    return QrScannerView(
      title: l10n.agentPair_scanTitle,
      hint: l10n.agentPair_scanHint,
      onPayload: _handlePayload,
      unsupportedBody: Text(l10n.agentPair_unsupportedPlatform),
      overlay: error == null
          ? null
          : Positioned(
              left: 24,
              right: 24,
              bottom: 84,
              child: Text(
                error,
                style: TextStyle(color: Colors.orange.shade200, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
    );
  }
}
