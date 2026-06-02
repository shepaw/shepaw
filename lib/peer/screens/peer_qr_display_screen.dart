import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/channel_tunnel_service.dart';
import '../models/paired_peer.dart';
import '../services/peer_pairing_service.dart';
import 'peer_pairing_confirm_screen.dart';

/// 展示自己的配对 QR 码（Responder 侧）
class PeerQrDisplayScreen extends StatefulWidget {
  final void Function(PairedPeer peer)? onPaired;

  const PeerQrDisplayScreen({super.key, this.onPaired});

  @override
  State<PeerQrDisplayScreen> createState() => _PeerQrDisplayScreenState();
}

class _PeerQrDisplayScreenState extends State<PeerQrDisplayScreen> {
  String? _qrData;
  String? _pairingCode;
  String? _error;
  bool _loading = true;
  StreamSubscription? _requestSub;

  // ── Channel 外网配置相关 ──────────────────────────────────────────────
  bool _channelEnabled = false;
  ChannelTunnelConfig? _channelConfig;
  TunnelStatus _tunnelStatus = TunnelStatus.idle;
  bool _showConfigForm = false;
  StreamSubscription? _tunnelStatusSub;

  // 配置表单
  final _serverUrlController = TextEditingController();
  final _channelIdController = TextEditingController();
  final _secretController = TextEditingController();
  String? _configError;

  @override
  void initState() {
    super.initState();
    _initChannelState();
    _startPairing();
  }

  @override
  void dispose() {
    _requestSub?.cancel();
    _tunnelStatusSub?.cancel();
    _serverUrlController.dispose();
    _channelIdController.dispose();
    _secretController.dispose();
    // 注意：不在这里 cancelPairing()，因为 TabView 切换时会触发 dispose
    // 配对生命周期由父页面 PeerPairingScreen 管理
    super.dispose();
  }

  /// 初始化 Channel 状态
  Future<void> _initChannelState() async {
    final tunnelService = ChannelTunnelService.instance;
    final config = await tunnelService.loadConfig();
    final status = tunnelService.currentStatus;

    if (mounted) {
      setState(() {
        _channelConfig = config;
        _tunnelStatus = status;
        // 如果 tunnel 已连接，默认开启开关
        _channelEnabled = status == TunnelStatus.connected;
      });
    }

    // 监听 tunnel 状态变化
    _tunnelStatusSub = tunnelService.statusStream.listen((status) {
      if (!mounted) return;
      final wasConnected = _tunnelStatus == TunnelStatus.connected;
      setState(() => _tunnelStatus = status);

      // 当状态从非 connected 变为 connected 时，重新生成 QR
      if (!wasConnected && status == TunnelStatus.connected && _channelEnabled) {
        _startPairing();
      }
    });
  }

  /// 切换 Channel 开关
  Future<void> _toggleChannel(bool enabled) async {
    setState(() => _channelEnabled = enabled);

    final tunnelService = ChannelTunnelService.instance;

    if (enabled) {
      if (_channelConfig != null) {
        // 已有配置，直接启动
        await tunnelService.startWithConfig(_channelConfig!);
        // 连接成功后 statusStream 会触发 QR 刷新
      } else {
        // 无配置，展开表单
        setState(() => _showConfigForm = true);
      }
    } else {
      // 关闭 Channel
      setState(() => _showConfigForm = false);
      await tunnelService.stop();
      // 重新生成仅含内网地址的 QR
      _startPairing();
    }
  }

  /// 展开配置表单，预填已有配置
  void _editConfig() {
    if (_channelConfig != null) {
      _serverUrlController.text = _channelConfig!.serverUrl;
      _channelIdController.text = _channelConfig!.channelId;
      _secretController.text = _channelConfig!.secret;
    }
    setState(() {
      _showConfigForm = true;
      _configError = null;
    });
  }

  /// 提交 Channel 配置
  Future<void> _submitConfig() async {
    final serverUrl = _serverUrlController.text.trim();
    final channelId = _channelIdController.text.trim();
    final secret = _secretController.text.trim();

    if (serverUrl.isEmpty || channelId.isEmpty || secret.isEmpty) {
      setState(() => _configError = '请填写所有字段');
      return;
    }

    setState(() => _configError = null);

    final config = ChannelTunnelConfig(
      serverUrl: serverUrl,
      channelId: channelId,
      secret: secret,
      autoConnect: true,
    );

    final tunnelService = ChannelTunnelService.instance;

    // 如果旧 tunnel 正在运行，先停止
    if (tunnelService.isRunning) {
      await tunnelService.stop();
    }

    await tunnelService.saveConfig(config);

    setState(() {
      _channelConfig = config;
      _showConfigForm = false;
    });

    await tunnelService.startWithConfig(config);
    // 连接成功后 statusStream 会触发 QR 刷新
  }

  Future<void> _startPairing() async {
    // 取消旧的监听，避免重复订阅导致多次弹窗
    _requestSub?.cancel();
    _requestSub = null;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final qrData = await PeerPairingService.instance.startPairing();

      // 提取配对码（从 QR 数据中解析）
      final uri = Uri.parse(qrData);
      final code = uri.queryParameters['code'] ?? '';

      if (mounted) {
        setState(() {
          _qrData = qrData;
          _pairingCode = code;
          _loading = false;
        });
      }

      // 监听配对请求（仅一个订阅）
      _requestSub = PeerPairingService.instance.incomingPairingRequests.listen(
        (request) async {
          if (!mounted) return;
          // 弹出确认对话框
          final peer = await PeerPairingConfirmScreen.show(context, request);
          if (peer != null) {
            widget.onPaired?.call(peer);
          } else {
            // 被拒绝或取消，重新开始配对
            _startPairing();
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(
                '无法启动配对',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _startPairing,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 16),
          Text(
            '让对方扫描此二维码完成配对',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 24),

          // QR 码
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: QrImageView(
              data: _qrData!,
              version: QrVersions.auto,
              size: 240,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),

          const SizedBox(height: 24),

          // 配对码
          if (_pairingCode != null) ...[
            Text(
              '配对码',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: _pairingCode!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配对码已复制')),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _pairingCode!,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // ── Channel 外网配置卡片 ─────────────────────────────────────
          _buildChannelCard(context, colorScheme),

          const SizedBox(height: 24),

          // 状态提示
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '等待对方扫描...',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Text(
            '二维码 5 分钟内有效',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  // ── Channel 外网配置卡片 ────────────────────────────────────────────────

  Widget _buildChannelCard(BuildContext context, ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _channelEnabled && _tunnelStatus == TunnelStatus.connected
              ? Colors.green.withValues(alpha: 0.5)
              : colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行 + 开关
          Row(
            children: [
              Icon(
                Icons.language,
                size: 20,
                color: _channelEnabled ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '外网连接',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: _channelEnabled,
                onChanged: _toggleChannel,
              ),
            ],
          ),

          // 内容区域
          if (!_channelEnabled) ...[
            // 关闭状态：提示文案
            const SizedBox(height: 4),
            Text(
              '开启后可通过外网配对，不限同一局域网',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            // 开启状态：根据情况显示不同内容
            const SizedBox(height: 8),
            _buildChannelStatus(context, colorScheme),
          ],
        ],
      ),
    );
  }

  Widget _buildChannelStatus(BuildContext context, ColorScheme colorScheme) {
    // 如果需要显示配置表单
    if (_showConfigForm) {
      return _buildConfigForm(context, colorScheme);
    }

    // 根据 tunnel 状态显示
    switch (_tunnelStatus) {
      case TunnelStatus.connected:
        // 获取当前 channel 端点用于展示
        String? endpoint;
        if (_channelConfig != null) {
          endpoint = ChannelTunnelService.instance.getPublicEndpoint(_channelConfig!);
          endpoint = endpoint?.replaceFirst('/acp/ws', '/peer/ws');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: Colors.green[600]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Channel 已连接',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.green[700],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // 编辑配置按钮
                GestureDetector(
                  onTap: _editConfig,
                  child: Icon(
                    Icons.edit_outlined,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (endpoint != null) ...[
              const SizedBox(height: 4),
              Text(
                endpoint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 11,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        );

      case TunnelStatus.connecting:
        return Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.orange[600],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '正在连接 Channel...',
              style: TextStyle(fontSize: 13, color: Colors.orange[700]),
            ),
          ],
        );

      case TunnelStatus.disconnected:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_off, size: 16, color: Colors.grey[500]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '连接断开，正在重连...',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ),
                GestureDetector(
                  onTap: _editConfig,
                  child: Text(
                    '修改配置',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );

      case TunnelStatus.error:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red[600]),
                const SizedBox(width: 6),
                Text(
                  '连接失败',
                  style: TextStyle(fontSize: 13, color: Colors.red[700]),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      if (_channelConfig != null) {
                        await ChannelTunnelService.instance.startWithConfig(_channelConfig!);
                      }
                    },
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _editConfig,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('修改配置'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );

      case TunnelStatus.idle:
        // 已开启但状态为 idle，说明正在启动中
        if (_channelConfig != null) {
          return Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.orange[600],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '正在启动...',
                style: TextStyle(fontSize: 13, color: Colors.orange[700]),
              ),
            ],
          );
        }
        // 无配置，不应该到这里（应该显示表单）
        return const SizedBox.shrink();
    }
  }

  Widget _buildConfigForm(BuildContext context, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '配置 Channel 服务以启用外网连接',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverUrlController,
          decoration: const InputDecoration(
            labelText: 'Server URL',
            hintText: 'https://channel.example.com',
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _channelIdController,
          decoration: const InputDecoration(
            labelText: 'Channel ID',
            hintText: '输入 Channel ID',
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          style: const TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _secretController,
          decoration: const InputDecoration(
            labelText: 'Secret',
            hintText: '输入签名密钥',
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
          obscureText: true,
          style: const TextStyle(fontSize: 14),
        ),
        if (_configError != null) ...[
          const SizedBox(height: 8),
          Text(
            _configError!,
            style: TextStyle(fontSize: 12, color: colorScheme.error),
          ),
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _submitConfig,
            icon: const Icon(Icons.cloud_done, size: 18),
            label: const Text('连接'),
          ),
        ),
      ],
    );
  }
}
