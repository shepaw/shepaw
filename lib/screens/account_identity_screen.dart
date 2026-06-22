import 'package:flutter/material.dart';

import '../identity/models/device_role.dart';
import '../identity/models/owned_device_record.dart';
import '../identity/services/account_identity_service.dart';
import '../identity/services/sync_client_service.dart';
import '../l10n/app_localizations.dart';
import 'add_owned_device_screen.dart';
import 'import_account_screen.dart';

/// 账号与灵宠身份、设备角色、认主状态设置页。
class AccountIdentityScreen extends StatefulWidget {
  const AccountIdentityScreen({super.key});

  @override
  State<AccountIdentityScreen> createState() => _AccountIdentityScreenState();
}

class _AccountIdentityScreenState extends State<AccountIdentityScreen> {
  bool _loading = true;
  String? _userFp;
  String? _petFp;
  DeviceRole _localRole = DeviceRole.app;
  OwnedDeviceRecord? _primaryDevice;
  List<OwnedDeviceRecord> _owned = [];
  String? _error;
  bool _syncing = false;
  int _pendingEvents = 0;
  int _pendingBlobs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AccountIdentityService.instance.ensureInitialized();
      final user = await AccountIdentityService.instance.userIdentity();
      final pet = await AccountIdentityService.instance.spiritPetIdentity();
      final role = await AccountIdentityService.instance.localDeviceRole();
      final primary = await AccountIdentityService.instance.primaryDevice();
      final owned = await AccountIdentityService.instance.ownedDevices();
      final pending = await SyncClientService.instance.pendingCounts();
      if (!mounted) return;
      setState(() {
        _userFp = user.fingerprintHex;
        _petFp = pet.fingerprintHex;
        _localRole = role;
        _primaryDevice = primary;
        _owned = owned;
        _pendingEvents = pending.events;
        _pendingBlobs = pending.blobs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _onRoleChanged(DeviceRole? role) async {
    if (role == null || role == _localRole) return;
    if (role == DeviceRole.primary) {
      final l10n = AppLocalizations.of(context);
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.identity_setPrimaryTitle),
          content: Text(l10n.identity_setPrimaryBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.common_cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.common_confirm)),
          ],
        ),
      );
      if (confirm != true) return;
    }
    await AccountIdentityService.instance.setLocalDeviceRole(role);
    await _load();
  }

  Future<void> _pullSync() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _syncing = true);
    try {
      await SyncClientService.instance.syncWithPrimary();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.identity_syncPullSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.identity_syncPullFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _fullResync() async {
    final l10n = AppLocalizations.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.identity_syncResyncTitle),
        content: Text(l10n.identity_syncResyncBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.common_cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.common_confirm)),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _syncing = true);
    try {
      await SyncClientService.instance.fullResyncFromPrimary();
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.identity_syncResyncSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.identity_syncResyncFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  String _roleLabel(DeviceRole role, AppLocalizations l10n) {
    switch (role) {
      case DeviceRole.primary:
        return l10n.identity_rolePrimary;
      case DeviceRole.backup:
        return l10n.identity_roleBackup;
      case DeviceRole.app:
        return l10n.identity_roleApp;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.identity_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  _SectionTitle(l10n.identity_sectionAccount),
                  ListTile(
                    title: Text(l10n.identity_userId),
                    subtitle: Text(_userFp ?? '—', style: const TextStyle(fontFamily: 'monospace')),
                  ),
                  ListTile(
                    title: Text(l10n.identity_petId),
                    subtitle: Text(_petFp ?? '—', style: const TextStyle(fontFamily: 'monospace')),
                  ),
                  const Divider(height: 32),
                  _SectionTitle(l10n.identity_sectionDeviceRole),
                  Text(l10n.identity_deviceRoleHint, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  ...DeviceRole.values.map((role) => RadioListTile<DeviceRole>(
                        title: Text(_roleLabel(role, l10n)),
                        subtitle: Text(_roleDescription(role, l10n)),
                        value: role,
                        groupValue: _localRole,
                        onChanged: _onRoleChanged,
                      )),
                  if (_localRole == DeviceRole.app && _primaryDevice != null)
                    ListTile(
                      title: Text(l10n.identity_primaryDevice),
                      subtitle: Text(
                        '${_primaryDevice!.deviceName} (${_primaryDevice!.fingerprint})',
                      ),
                    ),
                  const Divider(height: 32),
                  _SectionTitle(l10n.identity_sectionMultiDevice),
                  ListTile(
                    leading: const Icon(Icons.qr_code),
                    title: Text(l10n.identity_addDeviceTitle),
                    subtitle: Text(l10n.identity_addDeviceSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AddOwnedDeviceScreen()),
                        ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.download),
                    title: Text(l10n.identity_importTitle),
                    subtitle: Text(l10n.identity_importSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final ok = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(builder: (_) => const ImportAccountScreen()),
                      );
                      if (ok == true) await _load();
                    },
                  ),
                  if (_localRole == DeviceRole.app || _localRole == DeviceRole.backup) ...[
                    if (_pendingEvents > 0 || _pendingBlobs > 0)
                      ListTile(
                        leading: Icon(
                          Icons.cloud_upload_outlined,
                          color: Theme.of(context).colorScheme.tertiary,
                        ),
                        title: Text(l10n.identity_syncPendingTitle),
                        subtitle: Text(
                          l10n.identity_syncPendingBody(_pendingEvents, _pendingBlobs),
                        ),
                      ),
                    ListTile(
                      leading: _syncing
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.sync),
                      title: Text(l10n.identity_syncPull),
                      subtitle: Text(l10n.identity_syncPullSub),
                      onTap: _syncing ? null : _pullSync,
                    ),
                    ListTile(
                      leading: _syncing
                          ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh),
                      title: Text(l10n.identity_syncResync),
                      subtitle: Text(l10n.identity_syncResyncSub),
                      onTap: _syncing ? null : _fullResync,
                    ),
                  ],
                  const Divider(height: 32),
                  _SectionTitle(l10n.identity_sectionOwnedDevices),
                  if (_owned.isEmpty)
                    ListTile(title: Text(l10n.identity_noOwnedDevices))
                  else
                    ..._owned.map((d) => ListTile(
                          leading: Icon(d.isLocal ? Icons.phone_iphone : Icons.devices),
                          title: Text(d.deviceName),
                          subtitle: Text(
                            '${_roleLabel(d.role, l10n)} · ${d.fingerprint}${d.isLocal ? ' · ${l10n.identity_thisDevice}' : ''}',
                          ),
                        )),
                ],
              ),
            ),
    );
  }

  String _roleDescription(DeviceRole role, AppLocalizations l10n) {
    switch (role) {
      case DeviceRole.primary:
        return l10n.identity_rolePrimaryDesc;
      case DeviceRole.backup:
        return l10n.identity_roleBackupDesc;
      case DeviceRole.app:
        return l10n.identity_roleAppDesc;
    }
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}
