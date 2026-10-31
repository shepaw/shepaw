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
    required this.showDelete,
  });

  /// [section] 为 null 表示拿不到通讯录那一行，只能按 peer 自己判断。
  ///
  /// [isMaster] 这台设备是不是储物袋的 master（可以是主机，也可以是另指的
  /// NAS / 主节点）。
  factory PeerDetailSections.of({
    required bool isHost,
    required ContactSection? section,
    required bool unlistedNode,
    required bool hasAgents,
    required bool isMaster,
  }) {
    final canHostAgents = isHost || section == ContactSection.worker;
    return PeerDetailSections(
      showAgents: canHostAgents || hasAgents,
      showEngine: canHostAgents && !unlistedNode,
      // 储物袋只在主机 Hub 的磁盘上（docs/pouch_host_refactor_decision.md
      // §1、§5），NAS / 主节点被指定为 master 时也有一份，其余设备没有。
      // 给手机、PC 客户端看这一节点进去是空的。
      showStorage: (isHost || isMaster) && !unlistedNode,
      showDelete: !unlistedNode,
    );
  }

  final bool showAgents;
  final bool showEngine;

  /// 信任级别也归在这一节里：它唯一的实际作用是出站共享的默认值，本身就是
  /// 一个共享设置，不另开「安全」一节。
  final bool showStorage;
  final bool showDelete;
}
