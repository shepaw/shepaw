import 'dart:convert';

/// 结构化视觉档案：She 对一位家人的可检索外貌/场景描述。
///
/// 由视觉 LLM 从参考照提取，存于 `face_persons.profile_json`；
/// 识别命中时作为佐证与描述素材回传给 She。
class PersonVisualProfile {
  final String? ageGroup; // 年龄段：婴儿/幼儿/儿童/少年/青年/中年/老年
  final String? hairStyle; // 发型：短发/长发/齐刘海…
  final String? glasses; // 眼镜：无/近视镜/墨镜
  final String? typicalOutfit; // 常穿搭配
  final List<String> distinguishingMarks; // 明显标识：嘴角的痣/虎牙/耳钉…
  final List<String> commonScenes; // 常见场景：客厅/公园/婴儿床…
  final String? voice; // 嗓音特征
  final List<String> addressTerms; // 称呼：妈妈/宝宝/老婆…
  final String? notes; // 其他备注
  final String? builtAt; // ISO 时间（构建时间）

  const PersonVisualProfile({
    this.ageGroup,
    this.hairStyle,
    this.glasses,
    this.typicalOutfit,
    this.distinguishingMarks = const [],
    this.commonScenes = const [],
    this.voice,
    this.addressTerms = const [],
    this.notes,
    this.builtAt,
  });

  factory PersonVisualProfile.fromJson(Map<String, dynamic> json) =>
      PersonVisualProfile(
        ageGroup: _asString(json['ageGroup']),
        hairStyle: _asString(json['hairStyle']),
        glasses: _asString(json['glasses']),
        typicalOutfit: _asString(json['typicalOutfit']),
        distinguishingMarks: _asStringList(json['distinguishingMarks']),
        commonScenes: _asStringList(json['commonScenes']),
        voice: _asString(json['voice']),
        addressTerms: _asStringList(json['addressTerms']),
        notes: _asString(json['notes']),
        builtAt: _asString(json['builtAt']),
      );

  Map<String, dynamic> toJson() => {
        if (ageGroup != null) 'ageGroup': ageGroup,
        if (hairStyle != null) 'hairStyle': hairStyle,
        if (glasses != null) 'glasses': glasses,
        if (typicalOutfit != null) 'typicalOutfit': typicalOutfit,
        if (distinguishingMarks.isNotEmpty)
          'distinguishingMarks': distinguishingMarks,
        if (commonScenes.isNotEmpty) 'commonScenes': commonScenes,
        if (voice != null) 'voice': voice,
        if (addressTerms.isNotEmpty) 'addressTerms': addressTerms,
        if (notes != null) 'notes': notes,
        if (builtAt != null) 'builtAt': builtAt,
      };

  String encode() => jsonEncode(toJson());

  /// 一段适合 She 直接引用的中文描述（无则给空串）。
  String summarize() {
    final parts = <String>[
      if (ageGroup != null && ageGroup!.isNotEmpty) '年龄段 $ageGroup',
      if (hairStyle != null && hairStyle!.isNotEmpty) '$hairStyle 发型',
      if (glasses != null && glasses!.isNotEmpty) '戴$glasses',
      if (typicalOutfit != null && typicalOutfit!.isNotEmpty)
        '常穿 $typicalOutfit',
      if (distinguishingMarks.isNotEmpty)
        '标识：${distinguishingMarks.join('、')}',
      if (commonScenes.isNotEmpty) '常见场景：${commonScenes.join('、')}',
      if (voice != null && voice!.isNotEmpty) '嗓音：$voice',
    ];
    return parts.join('；');
  }

  static String? _asString(dynamic v) => v is String ? v : null;

  static List<String> _asStringList(dynamic v) {
    if (v is List) {
      return v.whereType<String>().toList();
    }
    if (v is String && v.trim().isNotEmpty) {
      // 兼容逗号分隔字符串
      return v.split(RegExp(r'[,，;；]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }
}

/// 从视觉 LLM 的文本输出中容错解析 [PersonVisualProfile]。
///
/// 容错规则：
/// - 剥掉 ```json ... ``` 代码围栏
/// - 丢弃首尾散文，定位第一个 `{` 到与之匹配的 `}`
/// - 字段缺失/类型不符一律降级为空值，绝不抛出
PersonVisualProfile parseVisualProfile(String text) {
  if (text.isEmpty) return const PersonVisualProfile();
  final stripped = _stripCodeFence(text);
  final start = stripped.indexOf('{');
  if (start < 0) return const PersonVisualProfile();
  final end = _findClosingBrace(stripped, start);
  if (end <= start) return const PersonVisualProfile();
  final candidate = stripped.substring(start, end + 1);
  try {
    final decoded = jsonDecode(candidate);
    if (decoded is Map) {
      return PersonVisualProfile.fromJson(
          Map<String, dynamic>.from(decoded));
    }
  } catch (_) {
    // 解析失败 → 空档案
  }
  return const PersonVisualProfile();
}

String _stripCodeFence(String text) {
  final re = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false);
  final m = re.firstMatch(text);
  return m?.group(1) ?? text;
}

int _findClosingBrace(String s, int start) {
  var depth = 0;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
