import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/location_service.dart';

class LocationSettingsScreen extends StatefulWidget {
  const LocationSettingsScreen({Key? key}) : super(key: key);

  @override
  State<LocationSettingsScreen> createState() => _LocationSettingsScreenState();
}

class _LocationSettingsScreenState extends State<LocationSettingsScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final status = await LocationService.instance.status();
    if (!mounted) return;
    setState(() {
      _status = status;
      _loading = false;
    });
  }

  bool get _serviceEnabled => _status?['service_enabled'] == true;
  bool get _available => _status?['available'] == true;
  String get _permission => _status?['permission'] as String? ?? 'denied';
  bool get _deniedForever => _permission == 'deniedForever';

  String _statusLabel(AppLocalizations l10n) {
    if (_status == null || _status!['success'] != true) {
      return l10n.settings_locationUnavailable;
    }
    if (!_serviceEnabled) return l10n.settings_locationServiceOff;
    if (_available) return l10n.settings_locationGranted;
    if (_deniedForever) return l10n.settings_locationDeniedForever;
    return l10n.settings_locationDenied;
  }

  Future<void> _onPrimaryTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    try {
      if (!_serviceEnabled) {
        await LocationService.instance.openLocationSettings();
        return;
      }
      if (_deniedForever || _available) {
        await LocationService.instance.openAppSettings();
        return;
      }
      final result = await LocationService.instance.requestAccess();
      if (!mounted) return;
      setState(() => _status = result);
      if (result['success'] != true) {
        final code = result['code'] as String?;
        if (code == 'service_disabled') {
          await LocationService.instance.openLocationSettings();
        } else if (code == 'permission_denied_forever') {
          await LocationService.instance.openAppSettings();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.settings_locationError)),
          );
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settings_locationError)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _actionLabel(AppLocalizations l10n) {
    if (!_serviceEnabled) return l10n.settings_locationOpenLocationSettings;
    if (_deniedForever || _available) return l10n.settings_locationOpenSettings;
    return l10n.settings_locationGrant;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_location),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              l10n.settings_locationHint,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: Icon(
              _available ? Icons.location_on : Icons.location_off_outlined,
              color: _available ? scheme.primary : scheme.onSurfaceVariant,
            ),
            title: Text(l10n.settings_locationStatus),
            subtitle: _loading
                ? Text(l10n.common_loading)
                : Text(_statusLabel(l10n)),
          ),
          const Divider(height: 1),
          ListTile(
            leading: _busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location),
            title: Text(_actionLabel(l10n)),
            subtitle: Text(
              _available
                  ? l10n.settings_locationOpenSettingsSub
                  : l10n.settings_locationGrantSub,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _onPrimaryTap,
          ),
        ],
      ),
    );
  }
}
