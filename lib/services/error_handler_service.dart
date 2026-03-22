import 'package:flutter/material.dart';
import 'logger_service.dart';

/// 顶部 Toast 通知 Widget
class _TopToastWidget extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String message;
  final VoidCallback onDismiss;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _TopToastWidget({
    super.key,
    required this.icon,
    required this.color,
    required this.message,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _fadeAnim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> dismiss() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnim,
      child: FadeTransition(
        opacity: _fadeAnim,
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(widget.icon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.message,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                if (widget.actionLabel != null)
                  GestureDetector(
                    onTap: () {
                      widget.onAction?.call();
                      dismiss();
                    },
                    child: Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        widget.actionLabel!,
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: dismiss,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
              ],
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
    final topPadding = MediaQuery.of(context).padding.top;

    // Fresh key every time — guarantees uniqueness in the tree.
    final key = GlobalKey<_TopToastWidgetState>();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: topPadding + 12,
        left: 0,
        right: 0,
        child: _TopToastWidget(
          key: key,
          icon: icon,
          color: color,
          message: message,
          actionLabel: actionLabel,
          onAction: onAction,
          onDismiss: () {
            entry.remove();
            if (_current == entry) _current = null;
          },
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
