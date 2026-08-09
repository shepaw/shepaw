/// Agent 结构化记忆在储物袋 `memory` 空间的路径约定。
///
/// 权威：`store://memory/<device>/<agentId>/entries/<id>.json`
/// `runtime/<owner>/memory.md` 仍可作人读镜像（非权威）。
library;

import 'runtime_paths.dart';
import 'store_protocol.dart';

class MemoryPaths {
  MemoryPaths._();

  static String agentRoot(String agentId) =>
      RuntimePaths.sanitizeSegment(agentId);

  static String metaJson(String agentId) =>
      '${agentRoot(agentId)}/meta.json';

  static String entriesDir(String agentId) =>
      '${agentRoot(agentId)}/entries';

  static String entryJson(String agentId, int memoryId) =>
      '${entriesDir(agentId)}/$memoryId.json';

  /// Soul 权威正文（与 entries 并列）。
  static String soulMd(String agentId) => '${agentRoot(agentId)}/soul.md';

  static String uri({
    required String deviceId,
    required String relPath,
  }) =>
      storeUriWithRef(StoreSpace.memory, deviceId, relPath);
}
