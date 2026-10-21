import 'package:flutter/material.dart';
import 'logger_service.dart';

/// 顶部 Toast 通知 Widget
///
/// 视觉上是一张中性的悬浮卡片：语义色只用在图标底片、细描边和
/// 底部倒计时线上，不再整条铺满高饱和色块，深浅色模式都不用改调用方。
class _TopToastWidget extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String message;
  final Duration duration;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _TopToastWidget({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    required this.duration,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _progress;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.35),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _scaleAnim = Tween<double>(begin: 0.97, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward();

    // 底部细线吃掉 duration 走完，暗示「它会自己消失」。
    _progress = AnimationController(vsync: this, duration: widget.duration)
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _progress.dispose();
    super.dispose();
  }

  bool _dismissing = false;

  Future<void> dismiss() async {
    // 自动收起与用户点关闭可能同时触发，避免 remove 被执行两次。
    if (_dismissing) return;
    _dismissing = true;
    _progress.stop();
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    // 深色底上把语义色提亮一档，避免深蓝/墨绿贴在深色卡片上看不清。
    final accent =
        isDark ? Color.lerp(widget.color, Colors.white, 0.3)! : widget.color;
    final surface = isDark ? scheme.surfaceContainerHigh : scheme.surface;
    final textColor = scheme.onSurface;
    final secondaryColor = scheme.onSurfaceVariant;

    return SlideTransition(
      position: _slideAnim,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: ScaleTransition(
          scale: _scaleAnim,
          alignment: Alignment.topCenter,
          child: Semantics(
            container: true,
            liveRegion: true,
            child: Material(
              color: Colors.transparent,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                constraints: const BoxConstraints(maxWidth: 480),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: accent.withValues(alpha: isDark ? 0.32 : 0.22),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.45 : 0.12),
                      blurRadius: 20,
                      spreadRadius: -4,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: accent.withValues(
                                  alpha: isDark ? 0.22 : 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(widget.icon, color: accent, size: 18),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              widget.message,
                              style: TextStyle(
                                color: textColor,
                                fontSize: 14,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (widget.actionLabel != null) ...[
                            const SizedBox(width: 4),
                            InkWell(
                              borderRadius: BorderRadius.circular(8),
                              onTap: () {
                                widget.onAction?.call();
                                dismiss();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                child: Text(
                                  widget.actionLabel!,
                                  style: TextStyle(
                                    color: accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                          IconButton(
                            onPressed: dismiss,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: secondaryColor,
                            tooltip: MaterialLocalizations.of(context)
                                .closeButtonTooltip,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                          ),
                        ],
                      ),
                    ),
                    // 倒计时线：走完即自动收起，比纯色条更耐看也更有信息量。
                    AnimatedBuilder(
                      animation: _progress,
                      builder: (_, __) => Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 1 - _progress.value,
                          child: Container(
                            height: 2,
                            color: accent.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部 Toast 管理器
class _TopToastManager {
  static final _TopToastManager _instance = _TopToastManager._();
  factory _TopToastManager() => _instance;
  _TopToastManager._();

  OverlayEntry? _current;

  void show(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String message,
    required Duration duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    // Remove the previous entry immediately (before inserting the new one)
    // so the old widget is fully unmounted before the new one mounts.
    _dismissNow();

    final overlay = Overlay.of(context);
    // 调用方多半在 Scaffold body 里，那里的 padding.top 已被 AppBar 吃掉，
    // 用它会把 toast 定在屏幕最上沿，状态栏挡住上半截。这里取视图真实顶距。
    final view = View.of(context);
    final topPadding = view.viewPadding.top / view.devicePixelRatio;
    // 再让出 AppBar 的高度：toast 原先贴在状态栏下沿，正好盖住标题栏和
    // 左上角返回键，用户想退出时点不到。放到标题栏下方、内容区顶部。
    final top = topPadding + kToolbarHeight + 8;

    // Fresh key every time — guarantees uniqueness in the tree.
    final key = GlobalKey<_TopToastWidgetState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: top,
        left: 0,
        right: 0,
        child: Align(
          alignment: Alignment.topCenter,
          child: _TopToastWidget(
            key: key,
            icon: icon,
            color: color,
            message: message,
            duration: duration,
            actionLabel: actionLabel,
            onAction: onAction,
            onDismiss: () {
              entry.remove();
              if (_current == entry) _current = null;
            },
          ),
        ),
      ),
    );

    _current = entry;
    overlay.insert(entry);

    Future.delayed(duration, () {
      key.currentState?.dismiss();
    });
  }

  /// Remove the current entry from the overlay immediately (no animation wait).
  void _dismissNow() {
    try {
      _current?.remove();
    } catch (_) {}
    _current = null;
  }
}

/// 全局错误处理服务
///
/// P0: 统一的错误处理和用户提示
class ErrorHandlerService {
  final LoggerService _logger;
  final _toast = _TopToastManager();

  ErrorHandlerService(this._logger);

  /// 处理错误并显示用户友好的提示
  void handleError(
    BuildContext context,
    dynamic error, {
    String? title,
    String? message,
    VoidCallback? onRetry,
  }) {
    // 记录错误日志
    _logger.error('Error occurred', error: error);

    // 生成用户友好的错误消息
    final userMessage = _getUserFriendlyMessage(error);

    // 显示错误对话框
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.red),
            const SizedBox(width: 8),
            Text(title ?? '操作失败'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message ?? userMessage),
            if (error is Error || error is Exception) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              ExpansionTile(
                title: const Text('技术详情', style: TextStyle(fontSize: 14)),
                children: [
                  SelectableText(
                    error.toString(),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          if (onRetry != null)
            TextButton.icon(
              onPressed: () {
                Navigator.pop(context);
                onRetry();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 显示成功提示
  void showSuccess(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    _toast.show(
      context,
      icon: Icons.check_circle,
      color: Colors.green,
      message: message,
      duration: duration,
    );
  }

  /// 显示警告提示
  void showWarning(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 3),
  }) {
    _toast.show(
      context,
      icon: Icons.warning_amber,
      color: Colors.orange,
      message: message,
      duration: duration,
    );
  }

  /// 显示信息提示
  void showInfo(
    BuildContext context,
    String message, {
    Duration duration = const Duration(seconds: 2),
  }) {
    _toast.show(
      context,
      icon: Icons.info_outline,
      color: Colors.blue,
      message: message,
      duration: duration,
    );
  }

  /// 显示加载对话框
  void showLoading(BuildContext context, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(message),
            ],
          ),
        ),
      ),
    );
  }

  /// 确认对话框
  Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmText = '确定',
    String cancelText = '取消',
    bool isDangerous = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(cancelText),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isDangerous ? Colors.red : null,
            ),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 将错误转换为用户友好的消息
  String _getUserFriendlyMessage(dynamic error) {
    final errorStr = error.toString().toLowerCase();

    // 网络错误
    if (errorStr.contains('socket') ||
        errorStr.contains('network') ||
        errorStr.contains('connection')) {
      return '网络连接失败，请检查您的网络设置';
    }

    // 超时错误
    if (errorStr.contains('timeout')) {
      return '请求超时，请稍后重试';
    }

    // 认证错误
    if (errorStr.contains('unauthorized') ||
        errorStr.contains('authentication') ||
        errorStr.contains('token')) {
      return '认证失败，请检查您的凭证是否正确';
    }

    // 权限错误
    if (errorStr.contains('permission') || errorStr.contains('forbidden')) {
      return '您没有权限执行此操作';
    }

    // 404 错误
    if (errorStr.contains('not found') || errorStr.contains('404')) {
      return '请求的资源不存在';
    }

    // 服务器错误
    if (errorStr.contains('500') || errorStr.contains('server error')) {
      return '服务器错误，请稍后重试';
    }

    // 数据库错误
    if (errorStr.contains('database') || errorStr.contains('sql')) {
      return '数据存储错误，请重启应用';
    }

    // 默认错误
    return '操作失败，请稍后重试';
  }
}

/// 顶部 Toast 便捷函数（不依赖 ErrorHandlerService 实例）
final _globalToast = _TopToastManager();

void showTopToast(
  BuildContext context,
  String message, {
  IconData icon = Icons.info_outline,
  Color color = Colors.blueGrey,
  Duration duration = const Duration(seconds: 3),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  _globalToast.show(
    context,
    icon: icon,
    color: color,
    message: message,
    duration: duration,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// 立即隐藏当前顶部 Toast（若有），不等待动画。
/// 供长时间持续提示（如"正在重连…"）在后台任务结束后主动收起。
void hideTopToast() {
  _globalToast._dismissNow();
}
