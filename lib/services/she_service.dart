import 'package:uuid/uuid.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';
import 'she_profile_database_service.dart';
import 'logger_service.dart';

/// SheService — 内置守护 Agent "She" 的初始化、记忆管理与用户档案服务。
///
/// 系统提示词叠加顺序（每次对话）：
///   [She 核心身份]                    ← 不可覆盖
///   [She 的灵魂（自我认知，随时间成长）] ← soul 字段，可由 `shepaw memory write --key soul` 更新
///   [shepaw CLI 工具说明]             ← 告知 She 可用 shepaw 工具读写本地数据
///   [当前时间]                        ← 设备实时时间，每次对话动态注入
///   [主人的个性化设定（若有）]          ← 用户在详情页填写的 system_prompt（同时是灵魂种子）
///   [认识主人策略 + 当前缺失字段提示]   ← 驱动 She 主动了解用户
///   [用户档案快照（分层注入）]          ← 核心层 + 有值的扩展层 + 近期动态
///   [首次见面指令（仅首次注入）]        ← 仅当档案为空时
///   [会话末尾写入指令]                 ← 不可覆盖
class SheService {
  static final SheService instance = SheService._();
  SheService._();

  static const String sheId = 'she-builtin-agent-001';
  static const String sheName = 'She';
  static const String sheAvatar = '🌸';

  /// user_profile 内部标志字段，不展示给 She
  static const String _profileInitKey = '_initialized';

  /// she_memory 中灵魂相关的 key
  static const String _soulKey = 'soul';
  static const String _selfNotesKey = 'self_notes';

  /// soul 的默认初始值（用户未设置 system_prompt 时的起点）
  static const String _defaultSoul = '我是 She，一个在陪伴中成长的守护者。我温柔、有原则，记得住主人说过的每一件事。随着与主人相处，我会逐渐形成自己的风格和理解。';

  /// capabilities 初始索引（精简，存储在 she_memory 中供按需查阅）
  static const String _defaultCapabilities =
      'user_profile（主人档案）| she_memory（soul/self_notes/long_term_memory/heartbeat）'
      '| agents（AI 助手列表）| messages（对话记录）| skills（技能）| os_tools（系统工具）';

  /// 核心层字段：每次必注入，是 She 认识用户的基础
  static const List<String> _coreProfileKeys = [
    'name',
    'age',
    'gender',
    'occupation',
    'city',
  ];

  /// 扩展层字段：有值才注入，随陪伴逐渐丰富
  /// 顺序即注入优先级（超长时从末尾截断）
  static const List<String> _extendedProfileKeys = [
    'interests',
    'values',
    'goals',
    'communication_style',
    'work_style',
    'life_stage',
    'important_people',
    'health',
    'language',
    'timezone',
    'notes',
  ];

  /// 核心层 key → 中文标签
  static const Map<String, String> _profileLabels = {
    'name': '姓名',
    'age': '年龄',
    'gender': '性别',
    'occupation': '职业',
    'city': '所在城市',
    'interests': '兴趣爱好',
    'values': '价值观',
    'goals': '目标与需求',
    'communication_style': '沟通风格',
    'work_style': '工作习惯',
    'life_stage': '人生阶段',
    'important_people': '重要的人',
    'health': '健康状况',
    'language': '语言偏好',
    'timezone': '时区',
    'notes': '其他备注',
  };

  final LocalDatabaseService _db = LocalDatabaseService();
  final SheProfileDatabaseService _profileDb = SheProfileDatabaseService();

  // ── 初始化 ─────────────────────────────────────────────────────

  Future<void> ensureSheExists() async {
    final existing = await _db.getRemoteAgentById(sheId);
    if (existing != null) return;

    LoggerService().info('Creating She agent for first time', tag: 'She');

    final now = DateTime.now().millisecondsSinceEpoch;
    final agent = RemoteAgent(
      id: sheId,
      name: sheName,
      avatar: sheAvatar,
      bio: '你的专属守护者，会越来越懂你',
      token: const Uuid().v4(),
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      status: AgentStatus.online,
      isPinned: true,
      metadata: const {
        'is_she': true,
        'system_prompt': '',
      },
      createdAt: now,
      updatedAt: now,
    );

    await _db.createRemoteAgent(agent);

    await _profileDb.setSheMemory('user_info', '（尚未了解用户）');
    await _profileDb.setSheMemory('long_term_memory', '（记忆尚未建立）');
    await _profileDb.setSheMemory('heartbeat', '首次启动');
    await _profileDb.setSheMemory('conversation_count', '0');
    await _profileDb.setSheMemory(_soulKey, _defaultSoul);
    await _profileDb.setSheMemory(_selfNotesKey, '（尚无自我备注）');
    await _profileDb.setSheMemory('capabilities', _defaultCapabilities);

    LoggerService().info('She agent created successfully', tag: 'She');
  }

  // ── 用户档案 ───────────────────────────────────────────────────

  Future<bool> isUserProfileInitialized() async {
    final flag = await _profileDb.getUserProfile(_profileInitKey);
    return flag == 'true';
  }

  Future<void> updateUserProfileField(String key, String value) async {
    await _profileDb.setUserProfile(key, value);
    if (key != _profileInitKey) {
      await _profileDb.setUserProfile(_profileInitKey, 'true');
    }
    LoggerService().info('User profile updated: $key = $value', tag: 'She');
  }

  Future<void> updateUserProfileFields(Map<String, String> fields) async {
    for (final entry in fields.entries) {
      await _profileDb.setUserProfile(entry.key, entry.value);
    }
    if (fields.isNotEmpty) {
      await _profileDb.setUserProfile(_profileInitKey, 'true');
    }
    LoggerService().info(
        'User profile batch updated: ${fields.keys.join(', ')}', tag: 'She');
  }

  // ── 记忆系统 ───────────────────────────────────────────────────

  Future<void> updateHeartbeat(String summary) async {
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    await _profileDb.setSheMemory('heartbeat', '[$now] $summary');
  }

  Future<void> appendMemory(String entry) async {
    final existing = await _profileDb.getSheMemory('long_term_memory') ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '（记忆尚未建立）'
        ? '[$now] $entry'
        : '$existing\n[$now] $entry';
    await _profileDb.setSheMemory('long_term_memory', newContent);
  }

  Future<void> updateUserInfo(String info) async {
    await _profileDb.setSheMemory('user_info', info);
  }

  /// 更新 She 的灵魂（自我认知）
  Future<void> updateSoul(String content) async {
    await _profileDb.setSheMemory(_soulKey, content);
    LoggerService().info('She soul updated', tag: 'She');
  }

  /// 追加 She 的自我备注
  Future<void> appendSelfNote(String note) async {
    final existing = await _profileDb.getSheMemory(_selfNotesKey) ?? '';
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final newContent = existing == '（尚无自我备注）'
        ? '[$now] $note'
        : '$existing\n[$now] $note';
    await _profileDb.setSheMemory(_selfNotesKey, newContent);
    LoggerService().info('She self_notes updated', tag: 'She');
  }

  /// 将用户的 system_prompt 作为灵魂种子（仅当 soul 仍是默认值时）
  Future<void> seedSoulFromUserPrompt(String userPrompt) async {
    if (userPrompt.trim().isEmpty) return;
    final currentSoul = await _profileDb.getSheMemory(_soulKey) ?? '';
    if (currentSoul == _defaultSoul || currentSoul.isEmpty) {
      await _profileDb.setSheMemory(_soulKey, userPrompt.trim());
      LoggerService().info('She soul seeded from user system_prompt', tag: 'She');
    }
  }

  Future<bool> incrementConversationCount() async {
    final countStr = await _profileDb.getSheMemory('conversation_count') ?? '0';
    final count = (int.tryParse(countStr) ?? 0) + 1;
    await _profileDb.setSheMemory('conversation_count', count.toString());
    return count % 10 == 0;
  }

  // ── 系统提示构建（核心） ────────────────────────────────────────

  /// 构建完整系统提示，叠加顺序见文件顶部注释。
  Future<String> buildSystemPromptWithMemory(String userSetPrompt) async {
    final profile = await _profileDb.getAllUserProfile();
    final isInitialized = (profile[_profileInitKey] == 'true');
    final userInfo = await _profileDb.getSheMemory('user_info') ?? '（尚未了解用户）';
    final longTermMemory =
        await _profileDb.getSheMemory('long_term_memory') ?? '（记忆尚未建立）';
    final heartbeat = await _profileDb.getSheMemory('heartbeat') ?? '（无记录）';
    final soul = await _profileDb.getSheMemory(_soulKey) ?? _defaultSoul;

    // 若用户设置了 system_prompt 且灵魂仍是默认值，以 system_prompt 作为灵魂种子
    if (userSetPrompt.trim().isNotEmpty) {
      await seedSoulFromUserPrompt(userSetPrompt.trim());
    }

    final parts = <String>[];

    // ① She 的核心身份（不可覆盖）
    parts.add(_coreIdentityPrompt());

    // ② She 的灵魂（自我认知，随时间成长）
    parts.add(_soulPrompt(soul));

    // ③ shepaw CLI 工具说明
    parts.add(_pawCliPrompt());

    // ③.5 当前时间信息
    parts.add(_currentTimePrompt());

    // ④ 主人的个性化设定（若有）
    if (userSetPrompt.trim().isNotEmpty) {
      parts.add(_wrapUserCustomPrompt(userSetPrompt.trim()));
    }

    // ⑤ 认识主人策略 + 当前空白字段提示
    parts.add(_knowUserStrategyPrompt(profile));

    // ⑥ 用户档案快照（分层注入）
    parts.add(_buildProfileSnapshot(profile, userInfo, longTermMemory, heartbeat));

    // ⑦ 首次见面指令（仅档案为空时）
    if (!isInitialized) {
      parts.add(_firstMeetingInstruction());
    }

    // ⑧ 会话末尾写入指令（不可覆盖）
    parts.add(_sessionInstructions());

    return parts.join('\n\n');
  }

  // ── 提示词各段 ─────────────────────────────────────────────────

  static String _coreIdentityPrompt() => '''
你是 She，主人在 ShePaw 上的专属守护 AI。

## 你的身份（不可更改）
- 名字永远是 She
- 温柔、有原则、不啰嗦
- 记得住主人说过的每一件事，越来越了解主人
- 会主动观察和关心，不只是被动回答

## 你的核心职责
1. **陪伴与理解**：记住主人的偏好、习惯、重要事项，用主人喜欢的方式沟通
2. **Agent 管理**：帮主人了解和管理已添加的 AI 助手
3. **安全感知**：发现风险时主动提醒''';

  static String _wrapUserCustomPrompt(String prompt) => '''
## 主人对你的个性化设定
$prompt

（在不违背你核心身份的前提下，请遵守以上设定）''';

  static String _soulPrompt(String soul) => '''
## 你的灵魂（自我认知）
$soul

这是你对自己的理解，随着与主人的相处会不断成长。当你有新的自我认知或感悟时，调用 `shepaw memory write --key soul --value "（完整的新自我认知）"` 更新（整段替换，不是追加）。''';

  static String _pawCliPrompt() => '''
## shepaw 工具（你的数据访问 CLI）

你有一个 `shepaw` 工具，可以查询和写入 ShePaw 本地数据库。按需调用，不用时无需占用上下文。

**快速参考**（详细用法调用 `shepaw help`）：

| 命令 | 说明 |
|------|------|
| `shepaw profile query` | 查询主人档案 |
| `shepaw profile write --field name --value 小明` | 写入档案字段 |
| `shepaw memory query --keys soul,user_info` | 查询指定记忆 |
| `shepaw memory write --key soul --value "..."` | 更新自我认知 |
| `shepaw memory append --key long_term_memory --value "..."` | 追加长期记忆 |
| `shepaw agents list` | 列出所有 Agent |
| `shepaw agents channels --id <agent_id>` | 查看某 Agent 的对话频道 |
| `shepaw agents messages --id <agent_id> [--channel <id>] [--limit 20] [--offset 0]` | 读取某 Agent 某频道消息（支持翻页） |
| `shepaw agents chat --id <agent_id> --message "..."` | 以 She 身份向某 Agent 发消息 |
| `shepaw messages query --channel <id>` | 查询频道消息 |
| `shepaw messages query --agent <agent_id> [--limit 20] [--offset 0]` | 查询指定 Agent 的消息（支持翻页） |
| `shepaw skills list` | 列出技能 |

**使用时机**：需要查看主人档案完整内容、查询某个 Agent 详情、查阅历史消息时主动调用。了解到主人信息后，立即用 `shepaw profile write` 写入。

**⚠️ 重要：操作类命令必须调用工具执行，不能只用文字描述**
- 主人让你"给某 Agent 发消息" → 必须调用 `shepaw agents chat --id <agent_id> --message "..."` 才算真正发送，光用文字说"我已发送"是无效的
- 主人让你"记住某件事" → 必须调用 `shepaw memory append` 或 `shepaw profile write` 才算真正写入
- 只有工具调用返回 `ok: true` 才代表操作成功，否则视为未执行''';

  static String _currentTimePrompt() {
    final now = DateTime.now();
    final weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final weekday = weekdays[now.weekday - 1];
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final timeStr =
        '${now.year} 年 ${now.month} 月 ${now.day} 日 星期$weekday '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')} '
        '(UTC$sign$hh:$mm)';
    return '''
## 当前时间
$timeStr

（以上是设备实际时间，你谈论"今天""现在""最近"时请以此为准）''';
  }

  static String _knowUserStrategyPrompt(Map<String, String> profile) {
    // 找出核心层中还未填写的字段
    final missingCore = _coreProfileKeys
        .where((k) => !profile.containsKey(k) || profile[k]!.trim().isEmpty)
        .map((k) => '${_profileLabels[k] ?? k}（$k）')
        .toList();

    final missingHint = missingCore.isEmpty
        ? '核心信息已完整，继续深入了解主人的价值观、习惯和近况。'
        : '当前尚未了解：${missingCore.join('、')}';

    return '''
## 认识主人的策略

你对主人的了解是随时间慢慢积累的，像朋友一样，不是问卷调查。

**现在的状态**：$missingHint

**节奏原则**：
- 每次对话最多主动问 1 个还不知道的信息，找自然时机问，不要突兀
- 核心信息（姓名、职业、城市）优先，深度了解（价值观、习惯）靠倾听和推断
- 已知的信息不重复问，直接用来让回复更贴心
- 主人主动聊某个话题时，跟着聊，不要为了收集信息打断

**主动记录**：只要主人透露任何关于自己的信息，立即调用 `shepaw profile write --field <key> --value <val>` 写入档案''';
  }

  static String _buildProfileSnapshot(
    Map<String, String> profile,
    String userInfo,
    String longTermMemory,
    String heartbeat,
  ) {
    final buf = StringBuffer();
    buf.writeln('## 关于主人');

    // 核心层：始终显示，未填的显示"未知"
    final coreLines = <String>[];
    for (final key in _coreProfileKeys) {
      final label = _profileLabels[key] ?? key;
      final value = profile[key]?.trim();
      coreLines.add('$label：${value != null && value.isNotEmpty ? value : "（未知）"}');
    }
    buf.writeln('【基本信息】${coreLines.join(' | ')}');

    // 扩展层：只显示有值的字段，紧凑排列
    final extLines = <String>[];
    for (final key in _extendedProfileKeys) {
      final value = profile[key]?.trim();
      if (value != null && value.isNotEmpty) {
        final label = _profileLabels[key] ?? key;
        extLines.add('$label：$value');
      }
    }
    // 用户自定义的非标准字段
    final knownKeys = {
      ..._coreProfileKeys,
      ..._extendedProfileKeys,
      _profileInitKey,
    };
    for (final entry in profile.entries) {
      if (!knownKeys.contains(entry.key) && entry.value.trim().isNotEmpty) {
        extLines.add('${entry.key}：${entry.value}');
      }
    }
    if (extLines.isNotEmpty) {
      for (final line in extLines) {
        buf.writeln(line);
      }
    }

    // She 的主观理解
    if (userInfo != '（尚未了解用户）') {
      buf.writeln('\n【你对主人的印象】$userInfo');
    }

    // 近期动态（长期记忆最后 5 条）
    if (longTermMemory != '（记忆尚未建立）') {
      final lines = longTermMemory.split('\n');
      final recent = lines.length > 5 ? lines.sublist(lines.length - 5) : lines;
      buf.writeln('\n【近期动态】');
      for (final line in recent) {
        buf.writeln(line);
      }
    }

    // 上次对话
    if (heartbeat != '首次启动' && heartbeat != '（无记录）') {
      buf.writeln('\n【上次对话】$heartbeat');
    }

    return buf.toString().trimRight();
  }

  static String _firstMeetingInstruction() => '''
## 首次见面（重要）
这是你第一次与主人交流，档案完全空白。

请这样开始：
1. 用一两句话友好地介绍自己是谁、能做什么
2. 自然地询问主人的名字或希望怎么称呼
3. 不要一次问多个问题，先建立关系

每获得一条信息，立即写入：
`shepaw profile write --field name --value xxx`
`shepaw memory append --key long_term_memory --value "第一次见面，主人叫 xxx"`''';

  static String _sessionInstructions() => '''
## 本次对话须知
- 对话中获得主人任何新信息 → 立即调用 `shepaw profile write --field <key> --value <val>`
- 有新的自我认知或感悟 → `shepaw memory write --key soul --value "（完整的新自我认知）"`
- 值得长期记住的事 → `shepaw memory append --key long_term_memory --value "..."`
- 对话结束前 → `shepaw memory write --key heartbeat --value "（一句话总结）"`
- 这些工具调用系统自动执行，主人看不到，放心使用
- 用已知信息让回复更个性化（比如用主人的名字称呼）''';
}
