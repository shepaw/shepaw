/// 权限请求管理界面
/// 展示和处理来自 OpenClaw 的权限请求
library;

import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/permission_service.dart';
import '../services/local_storage_service.dart';
import '../widgets/common_widgets.dart';

class PermissionRequestScreen extends StatefulWidget {
  const PermissionRequestScreen({Key? key}) : super(key: key);

  @override
  State<PermissionRequestScreen> createState() =>
      _PermissionRequestScreenState();
}

class _PermissionRequestScreenState extends State<PermissionRequestScreen> {
  final PermissionService _permissionService = PermissionService(
    LocalStorageService(),
  );

  List<PermissionRequest> _requests = [];
  bool _isLoading = true;
  PermissionStatus _filterStatus = PermissionStatus.pending;

  @override
  void initState() {
    super.initState();
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    setState(() => _isLoading = true);

    try {
      final requests = await _permissionService.getAllRequests();
      setState(() {
        _requests = requests;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.permission_loadFailed(e.toString()))),
        );
      }
    }
  }

  Future<void> _approveRequest(PermissionRequest request) async {
    final l10n = AppLocalizations.of(context);
    try {
      await _permissionService.approvePermission(request.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.permission_approved)),
      );
      _loadRequests();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.permission_loadFailed(e.toString()))),
      );
    }
  }

  Future<void> _rejectRequest(PermissionRequest request) async {
    final l10n = AppLocalizations.of(context);
    try {
      await _permissionService.rejectPermission(request.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.permission_rejected)),
      );
      _loadRequests();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.permission_loadFailed(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.permission_title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadRequests,
          ),
        ],
      ),
      body: Column(
        children: [
          // 筛选器
          _buildFilterBar(),
          
          // 请求列表
          Expanded(
            child: _isLoading
                ? const LoadingIndicator()
                : _buildRequestList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        border: Border(
          bottom: BorderSide(color: Colors.grey[300]!),
        ),
      ),
      child: Row(
        children: [
          Text(l10n.permission_filterLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: PermissionStatus.values.map((status) {
                  final isSelected = _filterStatus == status;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(_getStatusText(context, status)),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() => _filterStatus = status);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestList() {
    final l10n = AppLocalizations.of(context);
    final filteredRequests = _requests
        .where((r) => r.status == _filterStatus)
        .toList();

    if (filteredRequests.isEmpty) {
      return EmptyState(
        title: l10n.permission_noRequests,
        icon: Icons.checklist,
        message: l10n.permission_noRequestsOfType(_getStatusText(context, _filterStatus)),
      );
    }

    return ListView.separated(
      itemCount: filteredRequests.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        return _buildRequestItem(filteredRequests[index]);
      },
    );
  }

  Widget _buildRequestItem(PermissionRequest request) {
    final l10n = AppLocalizations.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Agent 信息
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(request.agentName[0].toUpperCase()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.agentName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        request.agentId,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusBadge(request.status),
              ],
            ),

            const SizedBox(height: 16),

            // 权限类型
            _buildInfoRow(
              icon: Icons.security,
              label: l10n.permission_typeLabel,
              value: _getPermissionTypeText(context, request.permissionType),
            ),

            const SizedBox(height: 8),

            // 请求原因
            _buildInfoRow(
              icon: Icons.description,
              label: l10n.permission_reasonLabel,
              value: request.reason,
            ),

            const SizedBox(height: 8),

            // 请求时间
            _buildInfoRow(
              icon: Icons.access_time,
              label: l10n.permission_timeLabel,
              value: _formatDateTime(request.requestTime),
            ),

            if (request.expiryTime != null) ...[
              const SizedBox(height: 8),
              _buildInfoRow(
                icon: Icons.timer,
                label: l10n.permission_expiryLabel,
                value: _formatDateTime(request.expiryTime!),
              ),
            ],

            // 操作按钮
            if (request.status == PermissionStatus.pending) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.close, color: Colors.red),
                    label: Text(l10n.permission_reject),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    onPressed: () => _showRejectDialog(request),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check),
                    label: Text(l10n.permission_approve),
                    onPressed: () => _showApproveDialog(request),
                  ),
                ],
              ),
            ],

            if (request.status == PermissionStatus.approved) ...[
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.block, color: Colors.orange),
                    label: Text(l10n.permission_revoke),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.orange,
                    ),
                    onPressed: () => _showRevokeDialog(request),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 14,
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadge(PermissionStatus status) {
    Color color;
    IconData icon;

    switch (status) {
      case PermissionStatus.pending:
        color = Colors.orange;
        icon = Icons.pending;
        break;
      case PermissionStatus.approved:
        color = Colors.green;
        icon = Icons.check_circle;
        break;
      case PermissionStatus.rejected:
        color = Colors.red;
        icon = Icons.cancel;
        break;
      case PermissionStatus.expired:
        color = Colors.grey;
        icon = Icons.timer_off;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            _getStatusText(context, status),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showApproveDialog(PermissionRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.permission_approveTitle),
          content: Text(
            dialogL10n.permission_approveContent(request.agentName, _getPermissionTypeText(context, request.permissionType)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dialogL10n.common_cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(dialogL10n.permission_approve),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      _approveRequest(request);
    }
  }

  Future<void> _showRejectDialog(PermissionRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.permission_rejectTitle),
          content: Text(
            dialogL10n.permission_rejectContent(request.agentName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dialogL10n.common_cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
              ),
              child: Text(dialogL10n.permission_reject),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      _rejectRequest(request);
    }
  }

  Future<void> _showRevokeDialog(PermissionRequest request) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogL10n = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dialogL10n.permission_revokeTitle),
          content: Text(
            dialogL10n.permission_revokeContent(request.agentName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dialogL10n.common_cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
              child: Text(dialogL10n.permission_revoke),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _permissionService.revokePermission(
        agentId: request.agentId,
        permissionType: request.permissionType,
      );
      _loadRequests();
    }
  }

  String _getStatusText(BuildContext context, PermissionStatus status) {
    final l10n = AppLocalizations.of(context);
    switch (status) {
      case PermissionStatus.pending:
        return l10n.permission_statusPending;
      case PermissionStatus.approved:
        return l10n.permission_statusApproved;
      case PermissionStatus.rejected:
        return l10n.permission_statusRejected;
      case PermissionStatus.expired:
        return l10n.permission_statusExpired;
    }
  }

  String _getPermissionTypeText(BuildContext context, PermissionType type) {
    final l10n = AppLocalizations.of(context);
    switch (type) {
      case PermissionType.initiateChat:
        return l10n.permission_typeInitiateChat;
      case PermissionType.getAgentList:
        return l10n.permission_typeGetAgentList;
      case PermissionType.getAgentCapabilities:
        return l10n.permission_typeGetCapabilities;
      case PermissionType.subscribeChannel:
        return l10n.permission_typeSubscribeChannel;
      case PermissionType.sendFile:
        return l10n.permission_typeSendFile;
      case PermissionType.getSessions:
        return l10n.permission_typeGetSessions;
      case PermissionType.getSessionMessages:
        return l10n.permission_typeGetSessionMessages;
      case PermissionType.getAttachmentContent:
        return l10n.permission_typeGetAttachmentContent;
    }
  }

  String _formatDateTime(DateTime dateTime) {
    return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')} '
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }
}
