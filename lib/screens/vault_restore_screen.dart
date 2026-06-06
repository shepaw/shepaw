import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/vault_service.dart';
import '../theme/app_theme.dart';

/// 历史数据保险库页面
///
/// 展示所有历史 vault 文件，允许用户使用旧密码恢复数据。
class VaultRestoreScreen extends StatefulWidget {
  const VaultRestoreScreen({Key? key}) : super(key: key);

  @override
  State<VaultRestoreScreen> createState() => _VaultRestoreScreenState();
}

class _VaultRestoreScreenState extends State<VaultRestoreScreen> {
  final _vaultService = VaultService();

  List<VaultInfo> _vaults = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVaults();
  }

  Future<void> _loadVaults() async {
    setState(() => _isLoading = true);
    final vaults = await _vaultService.listVaults();
    if (mounted) {
      setState(() {
        _vaults = vaults;
        _isLoading = false;
      });
    }
  }

  /// 显示恢复确认对话框
  Future<void> _showRestoreDialog(VaultInfo vault) async {
    final l10n = AppLocalizations.of(context);
    final passwordController = TextEditingController();
    bool isPasswordVisible = false;
    bool isRestoring = false;
    String? errorMsg;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.lock_open_outlined),
              const SizedBox(width: 8),
              Text(l10n.vault_restoreTitle),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.vault_backupTime(_formatDate(vault.createdAt)),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              Text(
                l10n.vault_fileSize(vault.displaySize),
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              Text(l10n.vault_restorePasswordPrompt),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: !isPasswordVisible,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l10n.vault_oldPassword,
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      isPasswordVisible ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setDialogState(() {
                        isPasswordVisible = !isPasswordVisible;
                      });
                    },
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 8),
                Text(
                  errorMsg!,
                  style: TextStyle(color: Colors.red[700], fontSize: 13),
                ),
              ],
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange[200]!),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber, color: Colors.orange[700], size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.vault_restoreWarning,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isRestoring ? null : () => Navigator.pop(ctx),
              child: Text(l10n.common_cancel),
            ),
            ElevatedButton(
              onPressed: isRestoring
                  ? null
                  : () async {
                      final password = passwordController.text.trim();
                      if (password.isEmpty) {
                        setDialogState(() => errorMsg = l10n.vault_emptyPassword);
                        return;
                      }

                      setDialogState(() {
                        isRestoring = true;
                        errorMsg = null;
                      });

                      // 先从当前密码服务获取 salt（无法获得旧密码的 salt，
                      // 需要从 vault 自带的 salt 提取，或使用空 salt 逐一尝试）
                      // 实际上需要先尝试验证，由 VaultService 内部处理
                      // 这里通过 verifyVaultPassword 来测试
                      //
                      // 注意：旧密码的 salt 记录在 vault 文件元数据中（_buildVaultFile）
                      // 但我们当前版本没有在元数据中存 salt。
                      // 简化策略：让用户输入密码，遍历 salt='' 和实际逻辑
                      // 实际应存储 salt_hint 在 vault 元数据中
                      //
                      // TODO: 在 VaultService 中存储 salt 到 vault 元数据，
                      //       此处从 vault 解析 salt 后调用 restoreVault
                      //
                      // 当前实现：直接调用 restoreVault，并内部通过 SHA-256 验证
                      // restoreVault 会先验证校验和，再尝试解密

                      // 从 vault 元数据中获取 salt（需要 VaultService 支持）
                      final salt = await _vaultService.getVaultSalt(vault.vaultId);

                      final success = await _vaultService.restoreVault(
                        vaultId: vault.vaultId,
                        password: password,
                        salt: salt ?? '',
                      );

                      if (success) {
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } else {
                        setDialogState(() {
                          isRestoring = false;
                          errorMsg = l10n.vault_restoreFailed;
                        });
                      }
                    },
              child: isRestoring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l10n.vault_confirmRestore),
            ),
          ],
        ),
      ),
    );

    // 恢复成功后提示重启
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.vault_restoreSuccess),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  /// 显示删除确认对话框
  Future<void> _showDeleteDialog(VaultInfo vault) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.vault_deleteTitle),
        content: Text(
          l10n.vault_deleteConfirm(_formatDate(vault.createdAt)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.common_delete, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _vaultService.deleteVault(vault.vaultId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.vault_deleted)),
        );
        _loadVaults();
      }
    }
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_dataVault),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _vaults.isEmpty
              ? _buildEmptyState()
              : _buildVaultList(),
    );
  }

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.lock_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            l10n.vault_emptyTitle,
            style: TextStyle(fontSize: 18, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.vault_emptyDesc,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildVaultList() {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primaryContainer,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.primaryLight),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: AppColors.primaryDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.vault_infoBanner,
                  style: const TextStyle(color: AppColors.primaryDark, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _vaults.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final vault = _vaults[index];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                leading: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.indigo[50],
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.archive_outlined, color: Colors.indigo[600]),
                ),
                title: Text(
                  _formatDate(vault.createdAt),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  l10n.vault_size(vault.displaySize),
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _showRestoreDialog(vault),
                      child: Text(l10n.vault_restore),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _showDeleteDialog(vault),
                      tooltip: l10n.vault_deleteTooltip,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
