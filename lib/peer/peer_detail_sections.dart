import '../services/contacts_directory.dart';

/// 设备详情页按角色决定显示哪些区块。
///
/// 主机、工作节点、客户端、名单没同步回来的节点行共用一个页面模板，但能做的
/// 事完全不同：客户端上「Agent」「引擎」没有意义，未同步的节点行没有真正的
/// 配对记录，不该给删除入口。
class PeerDetailSections {
  const PeerDetailSections({
    required this.showAgents,
    required this.showEngine,
    required this.showStorage,
    required this.showSecurity,
    required this.showDelete,
  });

  /// [section] 为 null 表示拿不到通讯录那一行，只能按 peer 自己判断。
  factory PeerDetailSections.of({
    required bool isHost,
    required ContactSection? section,
    required bool unlistedNode,
    required bool hasAgents,
  }) {
    final canHostAgents = isHost || section == ContactSection.worker;
    return PeerDetailSections(
      showAgents: canHostAgents || hasAgents,
      showEngine: canHostAgents && !unlistedNode,
      // 未同步的节点行不在主机名单里，也没有可共享的空间。
      showStorage: !unlistedNode,
      showSecurity: !unlistedNode,
      showDelete: !unlistedNode,
    );
  }

  final bool showAgents;
  final bool showEngine;
  final bool showStorage;
  final bool showSecurity;
  final bool showDelete;
}
