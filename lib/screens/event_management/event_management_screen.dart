import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/remote_agent.dart';
import '../../service_locator.dart';
import '../../services/remote_agent_service.dart';
import 'event_emit_tab.dart';
import 'event_inbox_tab.dart';
import 'event_listen_tab.dart';
import 'event_recent_tab.dart';
import 'event_types_tab.dart';
import 'widgets/event_agent_picker.dart';
import 'widgets/event_hints.dart';

/// 事件管理页：把 CLI `events` 的收件箱 / 订阅 / 类型 / 发送能力可视化，
/// 外加一个 CLI 没有的「最近事件」实时流。
///
/// 读写分离：读直连类型化 API（`registry` / `allSubscriptions` /
/// `activeWaitLeases` / `inboxFor` / `busStore.log`），不做 JSON 往返；
/// 写走 `ShepawCLI.instance.execute`，见 [runEventsCli]。
class EventManagementScreen extends StatefulWidget {
  const EventManagementScreen({super.key});

  @override
  State<EventManagementScreen> createState() => _EventManagementScreenState();
}

class _EventManagementScreenState extends State<EventManagementScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 5, vsync: this);

  List<RemoteAgent> _agents = const [];
  bool _loadingAgents = true;
  String? _selectedAgentId;

  @override
  void initState() {
    super.initState();
    _loadAgents();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    List<RemoteAgent> agents = const [];
    try {
      // She 也在里面：`SheService` 把 She 持久化成普通 `RemoteAgent` 行
      // （`id == SheService.sheId`），不需要额外做并集。
      agents = await getIt<RemoteAgentService>().getAllAgents();
    } catch (_) {
      agents = const [];
    }
    if (!mounted) return;
    setState(() {
      _agents = agents;
      _loadingAgents = false;
      _selectedAgentId ??= agents.isEmpty ? null : agents.first.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final agentId = _selectedAgentId;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.eventMgmt_title),
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: l10n.eventMgmt_tabInbox),
            Tab(text: l10n.eventMgmt_tabListen),
            Tab(text: l10n.eventMgmt_tabTypes),
            Tab(text: l10n.eventMgmt_tabEmit),
            Tab(text: l10n.eventMgmt_tabRecent),
          ],
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loadingAgents) const LinearProgressIndicator(minHeight: 2),
          if (_agents.isNotEmpty)
            EventAgentPicker(
              agents: _agents,
              selectedAgentId: agentId,
              onChanged: (v) => setState(() => _selectedAgentId = v),
            ),
          Expanded(
            child: agentId == null
                ? EventEmptyHint(
                    text: _loadingAgents
                        ? l10n.common_loading
                        : l10n.eventMgmt_agentPick,
                    icon: Icons.smart_toy_outlined,
                  )
                : TabBarView(
                    controller: _tab,
                    children: [
                      EventInboxTab(agentId: agentId),
                      EventListenTab(agentId: agentId),
                      const EventTypesTab(),
                      EventEmitTab(agentId: agentId),
                      const EventRecentTab(),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
