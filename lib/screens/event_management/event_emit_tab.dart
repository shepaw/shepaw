import 'dart:convert';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/l10n_helpers.dart';
import '../../services/event/event_bus.dart';
import 'event_cli.dart';
import 'widgets/event_hints.dart';

/// 结构化发送事件表单 → `events emit`。
///
/// emit 的 type 前缀是硬约束：`emitAgent` 要求 `type.startsWith('agent.$agentId.')`，
/// `checkEmitPermission` 另拒 `system.*`。这里做客户端预校验给出即时反馈，
/// 真正的错误仍以 CLI 返回的 `{'error': …}` 为准。
class EventEmitTab extends StatefulWidget {
  final String agentId;

  const EventEmitTab({super.key, required this.agentId});

  @override
  State<EventEmitTab> createState() => _EventEmitTabState();
}

class _EventEmitTabState extends State<EventEmitTab>
    // TabBarView 会销毁离屏 tab：不保活的话，切到「最近事件」看一眼再切回来
    // 就丢了刚写好的 type / payload。
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();
  final _type = TextEditingController();
  final _payload = TextEditingController();
  final _correlation = TextEditingController();
  final _channel = TextEditingController();

  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _type.text = 'agent.${widget.agentId}.custom.';
    _payload.text = const JsonEncoder.withIndent('  ').convert(
      <String, dynamic>{'summary': '手动发送的测试事件'},
    );
  }

  @override
  void didUpdateWidget(EventEmitTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId) {
      _type.text = 'agent.${widget.agentId}.custom.';
    }
  }

  @override
  void dispose() {
    _type.dispose();
    _payload.dispose();
    _correlation.dispose();
    _channel.dispose();
    super.dispose();
  }

  /// 已注册的 `agent.<当前 agent>.*` 类型，供下拉快速填入。
  List<EventTypeDefinition> get _registeredTypes {
    final prefix = 'agent.${widget.agentId}.';
    return EventBus.instance.registry.all
        .where((t) => t.id.startsWith(prefix))
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context);
    if (_formKey.currentState?.validate() != true) return;

    final type = _type.text.trim();
    final prefix = 'agent.${widget.agentId}.';
    if (!type.startsWith(prefix)) {
      _toast(
        l10n.eventMgmt_emitFailed(
          l10n.eventMgmt_emitTypePrefix(widget.agentId),
        ),
        error: true,
      );
      return;
    }
    // 未注册的 `agent.<id>.*` 由 `emitAgent` 自动注册，这里不拦。
    final correlation = _correlation.text.trim();
    final channel = _channel.text.trim();

    setState(() => _sending = true);
    final result = await runEventsCli(
      subcommand: 'emit',
      agentId: widget.agentId,
      flags: {
        'type': type,
        'payload': _payload.text.trim(),
        if (correlation.isNotEmpty) 'correlation': correlation,
        if (channel.isNotEmpty) 'channel_id': channel,
      },
    );
    if (!mounted) return;
    setState(() => _sending = false);

    final error = result['error'];
    if (error != null) {
      _toast(l10n.eventMgmt_emitFailed('$error'), error: true);
      return;
    }
    if (result['deduplicated'] == true) {
      _toast(l10n.eventMgmt_emitDeduplicated('${result['id']}'));
      return;
    }
    final seq = result['seq'];
    _toast(seq is int ? l10n.eventMgmt_emitSuccess(seq) : l10n.common_confirm);
  }

  void _toast(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor:
            error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String? _validatePayload(String? raw) {
    final l10n = AppLocalizations.of(context);
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        return l10n.eventMgmt_emitInvalidJson(
          l10n.eventMgmt_emitPayloadMustBeObject,
        );
      }
    } catch (e) {
      return l10n.eventMgmt_emitInvalidJson('$e');
    }
    return null;
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l10n = AppLocalizations.of(context);
    final registered = _registeredTypes;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (registered.isNotEmpty) ...[
            DropdownButtonFormField<String>(
              key: const Key('event_emit_registered_type'),
              initialValue: registered.any((t) => t.id == _type.text)
                  ? _type.text
                  : null,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.eventMgmt_emitRegistered,
                border: const OutlineInputBorder(),
                isDense: true,
                prefixIcon: const Icon(Icons.list_alt, size: 18),
              ),
              items: registered
                  .map(
                    (t) => DropdownMenuItem(
                      value: t.id,
                      child: Text(
                        localizeEventTypeLabel(l10n, t.id),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) setState(() => _type.text = v);
              },
            ),
            const SizedBox(height: 12),
          ],
          TextFormField(
            key: const Key('event_emit_type'),
            controller: _type,
            decoration: InputDecoration(
              labelText: l10n.eventMgmt_emitType,
              hintText: l10n.eventMgmt_emitTypeHint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            validator: (v) {
              final text = (v ?? '').trim();
              if (text.isEmpty) return l10n.eventMgmt_emitTypeRequired;
              if (!text.startsWith('agent.${widget.agentId}.')) {
                return l10n.eventMgmt_emitTypePrefix(widget.agentId);
              }
              return null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const Key('event_emit_payload'),
            controller: _payload,
            maxLines: 6,
            minLines: 3,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(
              labelText: l10n.eventMgmt_emitPayload,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            validator: _validatePayload,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _correlation,
            decoration: InputDecoration(
              labelText: l10n.eventMgmt_emitCorrelation,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _channel,
            decoration: InputDecoration(
              labelText: l10n.eventMgmt_emitChannel,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('event_emit_send'),
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send, size: 16),
            label: Text(l10n.eventMgmt_emitSend),
          ),
          const SizedBox(height: 16),
          EventMemoryOnlyBanner(text: l10n.eventMgmt_memoryOnly),
        ],
      ),
    );
  }
}
