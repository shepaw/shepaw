import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/app_localizations.dart';
import '../services/host_channel_config.dart';

/// 本机主机的外网 Channel。写到主机的 `channel.json`，正在运行的主机会自己连上。
class HostConfigScreen extends StatefulWidget {
  const HostConfigScreen({super.key});

  @override
  State<HostConfigScreen> createState() => _HostConfigScreenState();
}

class _HostConfigScreenState extends State<HostConfigScreen> {
  final _server = TextEditingController();
  final _id = TextEditingController();
  final _secret = TextEditingController();
  final _alias = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _enabled = false;
  bool _missingCli = false;
  String _publicUrl = '';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _server.dispose();
    _id.dispose();
    _secret.dispose();
    _alias.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final config = await HostChannelStore.load();
      if (!mounted) return;
      if (config == null) {
        setState(() {
          _missingCli = true;
          _loading = false;
        });
        return;
      }
      _apply(config);
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  void _apply(HostChannelConfig config) {
    _enabled = config.enabled;
    _server.text = config.serverUrl;
    _id.text = config.channelId;
    _secret.text = config.secret;
    _alias.text = config.endpoint;
    _publicUrl = config.publicUrl;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final saved = await HostChannelStore.save(
        enabled: _enabled,
        serverUrl: _server.text,
        channelId: _id.text,
        secret: _secret.text,
        endpoint: _alias.text,
      );
      if (!mounted) return;
      _apply(saved);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.hostConfig_saved)),
      );
    } catch (error) {
      if (!mounted) return;
      final message = '$error'.replaceFirst('Bad state: ', '');
      setState(() => _error = l10n.hostConfig_failed(message));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hostConfig_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _missingCli
              ? Center(child: Text(l10n.hostConfig_needCli))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l10n.hostConfig_enabled),
                      value: _enabled,
                      onChanged: _saving
                          ? null
                          : (value) => setState(() => _enabled = value),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _server,
                      decoration: InputDecoration(
                        labelText: l10n.hostConfig_server,
                        hintText: l10n.hostConfig_serverHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _id,
                      decoration: InputDecoration(
                        labelText: l10n.hostConfig_id,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _secret,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: l10n.hostConfig_secret,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _alias,
                      decoration: InputDecoration(
                        labelText: l10n.hostConfig_alias,
                        hintText: l10n.hostConfig_aliasHint,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    if (_publicUrl.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(l10n.hostConfig_publicUrl),
                        subtitle: Text(_publicUrl),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _publicUrl));
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      l10n.hostConfig_hint,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (_error.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: Text(l10n.common_save),
                    ),
                  ],
                ),
    );
  }
}
