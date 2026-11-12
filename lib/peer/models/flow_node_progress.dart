/// 节点一轮里的一块思考 / 工具步骤（`flow_node_progress_resp.progress[]`）。
/// 字段对齐主机 `shepaw_session::Progress`；老数据只有 title / content。
class FlowProgressBlock {
  const FlowProgressBlock({
    required this.kind,
    required this.title,
    required this.content,
    this.summary = '',
    this.status = '',
  });

  /// `thought` / `tool` / `plan`；老数据为空。
  final String kind;
  final String title;
  final String content;

  /// 工具入参里提炼出的一行说明（命令 / 路径）。
  final String summary;

  /// `running` / `completed` / `failed`；空按已完成算。
  final String status;

  bool get isThought => kind == 'thought';
  bool get failed => status == 'failed';

  static FlowProgressBlock? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String text(String key) => raw[key] is String ? raw[key] as String : '';
    final block = FlowProgressBlock(
      kind: text('kind'),
      title: text('title').trim(),
      content: text('content'),
      summary: text('summary').trim(),
      status: text('status'),
    );
    if (block.title.isEmpty && block.content.trim().isEmpty) return null;
    return block;
  }
}

/// 一个节点最近一轮的思考 / 工具步骤（`flow_node_progress_resp`）。
class FlowNodeProgress {
  const FlowNodeProgress({this.blocks = const [], this.omitted = 0});

  final List<FlowProgressBlock> blocks;

  /// 主机为控体积丢掉的前面几块。
  final int omitted;

  bool get isEmpty => blocks.isEmpty;
  int get thoughtCount => blocks.where((b) => b.isThought).length;
  int get toolCount => blocks.where((b) => !b.isThought).length;

  /// 主机明确失败（success:false）返回 null；老主机不认这条请求时调用方
  /// 拿到的是超时 null。两种都由面板显示成「没取到」+ 重试。
  static FlowNodeProgress? fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return null;
    final raw = response['progress'];
    return FlowNodeProgress(
      blocks: raw is List
          ? [
              for (final item in raw)
                if (FlowProgressBlock.fromJson(item) case final block?) block,
            ]
          : const [],
      omitted: (response['progress_omitted'] as num?)?.toInt() ?? 0,
    );
  }
}
