import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../storage/pouch_login_client.dart';

/// 等电脑把主机密码设好。
///
/// 逻辑放在 controller 里、并且时间源可以注入，是为了能用 fake_async 测
/// 「每 3 秒查一次、进后台暂停、10 分钟后停」—— 以前这里是让用户自己点
/// 「我已经创建好了」，电脑那边设完了手机也不知道。
class WaitHostController extends ChangeNotifier {
  WaitHostController({
    required this.hostPeerId,
    required this.probe,
    this.interval = const Duration(seconds: 3),
    this.timeout = const Duration(minutes: 10),
    void Function(Object error)? onError,
  }) : _onError = onError;

  final String hostPeerId;
  final Future<bool> Function(String hostPeerId) probe;
  final Duration interval;
  final Duration timeout;
  final void Function(Object error)? _onError;

  Timer? _timer;
  bool _ready = false;
  bool _checking = false;
  bool _gaveUp = false;
  int _checks = 0;

  bool get ready => _ready;
  bool get checking => _checking;
  bool get gaveUp => _gaveUp;

  /// 只给测试看：已经查过几次。
  int get checks => _checks;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => check());
    check();
  }

  /// 进后台：别在后台一直问主机。
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  /// 回前台：立刻查一次，重新开始轮询。
  void resume() {
    if (_ready) return;
    start();
  }

  Future<void> check() async {
    if (_checking || _ready) return;
    _checking = true;
    notifyListeners();
    try {
      final set = await probe(hostPeerId);
      _checks++;
      if (set) {
        _ready = true;
        pause();
      }
    } catch (error) {
      _onError?.call(error);
    } finally {
      _checking = false;
      // 等太久了就别再问。按查过的次数算，不读系统时钟：读时钟在 fake_async
      // 里推进不了，见 wait_host_view_test。
      if (!_ready && interval * _checks >= timeout) {
        _gaveUp = true;
        pause();
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// 手机扫到一台还没设密码的主机时停在那一页。
class WaitHostView extends StatefulWidget {
  const WaitHostView({
    super.key,
    required this.hostPeerId,
    required this.onReady,
    WaitHostController? controller,
  }) : _controller = controller;

  final String hostPeerId;

  /// 主机设好了。
  final VoidCallback onReady;

  final WaitHostController? _controller;

  @override
  State<WaitHostView> createState() => _WaitHostViewState();
}

class _WaitHostViewState extends State<WaitHostView> {
  late final WaitHostController _gate;

  @override
  void initState() {
    super.initState();
    _gate = widget._controller ??
        WaitHostController(
          hostPeerId: widget.hostPeerId,
          probe: (hostPeerId) =>
              requestPouchPasswordStatus(hostPeerId: hostPeerId),
        );
    _gate.addListener(_onChanged);
    _gate.start();
  }

  void _onChanged() {
    if (!mounted) return;
    if (_gate.ready) widget.onReady();
    setState(() {});
  }

  @override
  void dispose() {
    _gate.removeListener(_onChanged);
    _gate.dispose();
    super.dispose();
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
                const SizedBox(height: 48),
                Text(
                  l10n.waitHost_title,
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  _gate.gaveUp ? l10n.waitHost_stale : l10n.waitHost_body,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Center(
                  child: _gate.checking
                      ? const CircularProgressIndicator()
                      : const Icon(Icons.hourglass_empty, size: 40),
                ),
                const SizedBox(height: 32),
                OutlinedButton(
                  onPressed: _gate.checking ? null : () => _gate.check(),
                  child: Text(l10n.waitHost_checkNow),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
