import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/app_localizations.dart';
import '../services/logger_service.dart';
import '../utils/platform_utils.dart';

/// 业务层对一次识别的处理结论。
enum QrScannerOutcome {
  /// 码已受理，壳停止取景，后续由业务层接管（跳转、轮询、pop…）。
  consumed,

  /// 不是我要的码 / 这一轮失败。壳冷却后恢复取景继续扫。
  ///
  /// 提示文案由业务层自己给 —— 只有它知道该说什么，壳给不了通用文案。
  /// 想 toast 就 toast，想留在页内就用 [QrScannerView.overlay] 叠一条错误条。
  retry,

  /// 放弃取景并返回上一页（返回值 null）。
  abort,
}

/// 扫码页的共用外壳：相机 + 权限 + 生命周期 + 手电筒 + 取景框 + 桌面兜底。
///
/// 抽出来是因为项目里有两种「扫二维码」业务，它们**壳相同、业务不同**：
/// - [AgentPairingScannerScreen]：解析出 `shepaw://pair?...` 就立刻 pop；
/// - `PeerScanScreen`：扫到码后要跑完整的配对握手（最坏 5 分钟超时），
///   中间还要渲染「正在连接…／等待对方确认…」。
///
/// 合成一个页面会让前者长出一个永远用不到的分支；各复制一份壳则必然漂移
/// （权限、生命周期这类样板最容易一边修一边忘）。
///
/// 桌面端（macOS/Linux/Windows）不加载 `mobile_scanner` —— 该包只实现了
/// iOS/Android，导入原生绑定会抛 MissingPluginException。壳在这一层短路，
/// 业务层用 [unsupportedBody] 给出自己的替代路径文案。
class QrScannerView extends StatefulWidget {
  const QrScannerView({
    super.key,
    required this.title,
    required this.hint,
    required this.onPayload,
    this.overlay,
    this.unsupportedBody,
  });

  /// AppBar 标题。
  final String title;

  /// 取景框下方的引导文案。
  final String hint;

  /// 识别到二维码原文时调用。见 [QrScannerOutcome]。
  final Future<QrScannerOutcome> Function(String raw) onPayload;

  /// 叠在取景之上的业务 UI（进度、错误条…）。位置由业务层自己用
  /// `Positioned` / `Align` 控制 —— 壳只负责把它放进同一个 `Stack`。
  final Widget? overlay;

  /// 桌面端的替代**文案**（通常是业务层自己的 `Text`）。壳负责包上图标、
  /// 返回按钮和白色字色 —— 这里不传时退化成一句通用提示。
  final Widget? unsupportedBody;

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView>
    with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _hasPermission = false;
  bool _permissionDenied = false;

  /// 权限申请 / controller 构造还没完成 —— 此时只能显示转圈。
  bool _booting = true;

  /// 防重入 + 防重复派发。识别回调与 `onPayload` 都是异步的，
  /// 快速连拍会在第一次结果回来之前再触发一次。刻意不参与 build：
  /// 处理期间仍然渲染取景 + 业务 overlay（「正在连接…」就叠在上面）。
  bool _processing = false;

  /// 收到结论后不再接受新的识别结果。
  bool _dispatched = false;

  /// `retry` 后的冷却截止时间 —— 同一张码留在取景框里时不至于打转。
  static const _retryCooldown = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // mobile_scanner 5.x 的 `dispose` 是异步的（要拆平台通道订阅），而
    // State.dispose 是同步契约，所以只能点火即走。这里抛异常也没有 UI 可展示。
    final ctrl = _controller;
    if (ctrl != null) {
      unawaited(ctrl.dispose().catchError((_) {}));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台时停相机：部分 Android 机型在系统回收相机时会 ANR，
    // 用户切走时继续取景也纯属浪费电。
    //
    // start()/stop() 在 5.x 是异步的，且状态不对（未初始化就 stop /
    // dispose 后再 start）会抛 MobileScannerException。这里一律吞掉 ——
    // 生命周期回调不是给用户展示错误的地方，权限与初始化错误已经在
    // _bootstrap 与 errorBuilder 里处理过了。
    final ctrl = _controller;
    if (ctrl == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(ctrl.start().catchError((_) {}));
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(ctrl.stop().catchError((_) {}));
        break;
    }
  }

  Future<void> _bootstrap() async {
    if (_isDesktop) {
      // 桌面没有 mobile_scanner，直接短路，让业务层给出替代路径。
      setState(() => _booting = false);
      return;
    }

    final granted = await _ensureCameraPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _booting = false;
        _permissionDenied = true;
      });
      return;
    }

    // 权限到手再建 controller。保持默认（自动选后置、自动对焦），
    // 手电筒由 AppBar 的按钮驱动 toggleTorch()。
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      formats: const [BarcodeFormat.qrCode],
      // 只要原文，不要 Barcode 的类型元数据，也不要整帧图像。
      returnImage: false,
    );
    setState(() {
      _hasPermission = true;
      _booting = false;
    });
  }

  Future<bool> _ensureCameraPermission() async {
    try {
      final status = await Permission.camera.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        // 用户此前选了「不再询问」，request() 不会再弹框，只能引导去设置。
        return false;
      }
      final result = await Permission.camera.request();
      return result.isGranted;
    } catch (err, stack) {
      LoggerService().error(
        'Camera permission check failed',
        tag: 'QRScanner',
        error: err,
        stackTrace: stack,
      );
      return false;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_dispatched || _processing) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      unawaited(_dispatch(raw));
      return;
    }
  }

  Future<void> _dispatch(String raw) async {
    _processing = true;
    final ctrl = _controller;
    if (ctrl != null) {
      // 处理期间先停取景：配对握手最坏要等 5 分钟，没必要一直开着相机。
      unawaited(ctrl.stop().catchError((_) {}));
    }

    QrScannerOutcome outcome;
    try {
      outcome = await widget.onPayload(raw);
    } catch (err, stack) {
      // 业务层的异常不该掀翻整个扫码页 —— 记日志，当成一次失败重试。
      LoggerService().error(
        'QR payload handler threw',
        tag: 'QRScanner',
        error: err,
        stackTrace: stack,
      );
      outcome = QrScannerOutcome.retry;
    }
    if (!mounted) return;

    switch (outcome) {
      case QrScannerOutcome.consumed:
        // 相机保持停止，业务层已经接管屏幕（进度 / 成功提示）。
        _dispatched = true;
      case QrScannerOutcome.abort:
        _dispatched = true;
        Navigator.of(context).pop();
      case QrScannerOutcome.retry:
        await Future<void>.delayed(_retryCooldown);
        if (!mounted) return;
        _processing = false;
        unawaited(_controller?.start().catchError((_) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title),
        actions: [
          if (_hasPermission)
            IconButton(
              icon: ValueListenableBuilder<MobileScannerState>(
                // mobile_scanner 5.x：MobileScannerController 本身就是
                // ValueListenable<MobileScannerState>，手电筒状态是那个
                // 状态结构体上的字段。降级到 3.x 时改听
                // `_controller.torchState`（独立的 ValueNotifier）。
                valueListenable: _controller!,
                builder: (_, state, __) {
                  final torch = state.torchState;
                  return Icon(
                    torch == TorchState.on ? Icons.flash_on : Icons.flash_off,
                  );
                },
              ),
              tooltip: l10n.agentPair_torch,
              onPressed: () => _controller?.toggleTorch(),
            ),
        ],
      ),
      body: _buildBody(context, l10n),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    if (_booting) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (_permissionDenied) return _buildPermissionDenied(context, l10n);
    if (_isDesktop || _controller == null) {
      return _buildUnsupported(context, l10n);
    }
    return Stack(
      children: [
        MobileScanner(
          controller: _controller!,
          onDetect: _onDetect,
          errorBuilder: (context, error, _) =>
              _buildScannerError(context, l10n, error),
        ),
        // 纯视觉的取景框：扫描本身是全画面的，方框只是引导。
        const IgnorePointer(child: _ScannerOverlay()),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            widget.hint,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
        if (widget.overlay != null) widget.overlay!,
      ],
    );
  }

  Widget _buildPermissionDenied(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off, color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          Text(
            l10n.agentPair_cameraDeniedTitle,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.agentPair_cameraDeniedBody,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.settings),
            label: Text(l10n.common_openSettings),
            onPressed: () async => openAppSettings(),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              l10n.common_back,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUnsupported(BuildContext context, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.desktop_access_disabled,
            color: Colors.white70,
            size: 64,
          ),
          const SizedBox(height: 16),
          // 背景是黑的，业务层传进来的 Text 不带颜色会看不见 —— 统一压白色。
          DefaultTextStyle.merge(
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
            child: widget.unsupportedBody ??
                Text(
                  l10n.agentPair_unsupportedShort,
                  textAlign: TextAlign.center,
                ),
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              l10n.common_back,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScannerError(
    BuildContext context,
    AppLocalizations l10n,
    MobileScannerException error,
  ) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 64),
          const SizedBox(height: 16),
          Text(
            l10n.agentPair_cameraInitFailed(error.errorCode.name),
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              l10n.common_back,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }

  /// mobile_scanner 不发桌面版，提前短路给出干净提示。
  bool get _isDesktop => isDesktopPlatform;
}

/// 居中的方框取景提示。纯视觉 —— 相机扫的是整帧。
class _ScannerOverlay extends StatelessWidget {
  const _ScannerOverlay();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth * 0.7;
        return Center(
          child: Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        );
      },
    );
  }
}
