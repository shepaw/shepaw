/// 一轮回复里的一个思考块或工具步骤（`metadata.progress_steps` 的一项）。
///
/// 主机在 `progress_content` 之外并行下发这份结构化数据；旧主机不发，
/// 气泡就回退到只显示 `progress_content` 的老样子。
enum ProgressStepType { thought, tool, plan }

enum ProgressStepStatus { running, completed, failed }

class ProgressStep {
  final String id;
  final ProgressStepType type;
  final String title;

  /// ACP 的工具类别：read / edit / execute / search / fetch / other ...
  final String? toolKind;

  /// 入参里提炼出的一行说明，比如命令或文件路径。
  final String? summary;
  final ProgressStepStatus status;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// 思考正文或计划条目；工具步骤目前通常为空。
  final String? body;

  /// 主机把更早的步骤并成了一条汇总时，被并掉的步骤数。
  final int omitted;

  const ProgressStep({
    required this.id,
    required this.type,
    required this.title,
    required this.status,
    this.toolKind,
    this.summary,
    this.startedAt,
    this.endedAt,
    this.body,
    this.omitted = 0,
  });

  bool get isRunning => status == ProgressStepStatus.running;
  bool get hasBody => body != null && body!.trim().isNotEmpty;

  Duration? get duration {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final d = end.difference(start);
    return d.isNegative ? null : d;
  }

  static ProgressStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    if (id is! String || id.isEmpty || title is! String) return null;
    String? str(String key) {
      final v = raw[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    DateTime? ms(String key) {
      final v = raw[key];
      return v is num && v > 0
          ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
          : null;
    }

    return ProgressStep(
      id: id,
      type: switch (raw['type']) {
        'thought' => ProgressStepType.thought,
        'plan' => ProgressStepType.plan,
        _ => ProgressStepType.tool,
      },
      title: title,
      status: switch (raw['status']) {
        'running' => ProgressStepStatus.running,
        'failed' => ProgressStepStatus.failed,
        _ => ProgressStepStatus.completed,
      },
      toolKind: str('tool_kind'),
      summary: str('summary'),
      startedAt: ms('started_at'),
      endedAt: ms('ended_at'),
      body: str('body'),
      omitted: raw['omitted'] is num ? (raw['omitted'] as num).toInt() : 0,
    );
  }

  static final Expando<List<ProgressStep>> _parsed = Expando();

  /// 解析 `metadata.progress_steps`。不是列表、或一项都解析不出来时返回空列表。
  ///
  /// 气泡每次 build 都会调用；同一个列表对象只解析一次。发布方（拆分器、
  /// 主机同步）约定列表发出后不再原地修改，所以按对象身份缓存是安全的。
  static List<ProgressStep> parseList(Object? raw) {
    if (raw is! List) return const [];
    final cached = _parsed[raw];
    if (cached != null) return cached;
    final steps = [
      for (final item in raw)
        if (fromJson(item) case final step?) step,
    ];
    _parsed[raw] = steps;
    return steps;
  }
}
