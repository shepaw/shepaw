import 'package:flutter/material.dart';
import '../services/cognition_service.dart';
import '../services/logger_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/form_bottom_bar.dart';

/// 用户档案设置页面
///
/// 管理所有 Agent 共用的用户个人信息，包含：
/// - 预设字段（name / age / gender / occupation 等 16 个）
/// - 用户自定义属性（可任意添加/编辑/删除）
class UserProfileSettingsScreen extends StatefulWidget {
  const UserProfileSettingsScreen({Key? key}) : super(key: key);

  @override
  State<UserProfileSettingsScreen> createState() =>
      _UserProfileSettingsScreenState();
}

class _UserProfileSettingsScreenState extends State<UserProfileSettingsScreen> {
  final CognitionService _cognition = CognitionService.instance;

  // ── 预设字段 key 列表（顺序固定）────────────────────────────────────────────
  static const List<String> _coreFieldKeys = [
    'name',
    'age',
    'gender',
    'occupation',
    'city',
  ];

  static const List<String> _extendedFieldKeys = [
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

  // 所有预设 key，用于区分自定义属性
  static final Set<String> _reservedKeys = {
    ..._coreFieldKeys,
    ..._extendedFieldKeys,
    '_initialized',
  };

  // 每个预设字段对应一个 Controller
  final Map<String, TextEditingController> _controllers = {};

  // 用户自定义属性列表（有序，保持添加顺序）
  final List<_CustomAttr> _customAttrs = [];

  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    for (final key in [..._coreFieldKeys, ..._extendedFieldKeys]) {
      _controllers[key] = TextEditingController();
    }
    _loadProfile();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── 字段定义（运行时从 l10n 获取 label/hint）────────────────────────────────

  List<_FieldDef> _buildCoreFields(AppLocalizations l10n) => [
        _FieldDef(key: 'name', label: l10n.profile_nameField),
        _FieldDef(
          key: 'age',
          label: l10n.profile_ageField,
          inputType: TextInputType.number,
        ),
        _FieldDef(key: 'gender', label: l10n.profile_genderField),
        _FieldDef(key: 'occupation', label: l10n.profile_occupationField),
        _FieldDef(key: 'city', label: l10n.profile_cityField),
      ];

  List<_FieldDef> _buildExtendedFields(AppLocalizations l10n) => [
        _FieldDef(
          key: 'interests',
          label: l10n.profile_interestsField,
          hint: l10n.profile_interestsHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'values',
          label: l10n.profile_valuesField,
          hint: l10n.profile_valuesHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'goals',
          label: l10n.profile_goalsField,
          hint: l10n.profile_goalsHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'communication_style',
          label: l10n.profile_communicationStyleField,
          hint: l10n.profile_communicationStyleHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'work_style',
          label: l10n.profile_workStyleField,
          hint: l10n.profile_workStyleHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'life_stage',
          label: l10n.profile_lifeStageField,
          hint: l10n.profile_lifeStageHint,
        ),
        _FieldDef(
          key: 'important_people',
          label: l10n.profile_importantPeopleField,
          hint: l10n.profile_importantPeopleHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'health',
          label: l10n.profile_healthField,
          hint: l10n.profile_healthHint,
          minLines: 2,
        ),
        _FieldDef(
          key: 'language',
          label: l10n.profile_languageField,
          hint: l10n.profile_languageHint,
        ),
        _FieldDef(
          key: 'timezone',
          label: l10n.profile_timezoneField,
          hint: l10n.profile_timezoneHint,
        ),
        _FieldDef(
          key: 'notes',
          label: l10n.profile_notesField,
          hint: l10n.profile_notesHint,
          minLines: 3,
        ),
      ];

  // ── 数据加载 ──────────────────────────────────────────────────────────────

  Future<void> _loadProfile() async {
    try {
      final profile = await _cognition.getAllUserProfile();
      final customAttrs = <_CustomAttr>[];

      for (final entry in profile.entries) {
        if (_reservedKeys.contains(entry.key)) {
          _controllers[entry.key]?.text = entry.value;
        } else {
          // 非预设字段 → 自定义属性
          customAttrs.add(
            _CustomAttr(
              key: entry.key,
              valueController: TextEditingController(text: entry.value),
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _customAttrs
            ..clear()
            ..addAll(customAttrs);
          _isLoading = false;
        });
      }
    } catch (e) {
      LoggerService().error(
        'Failed to load user profile',
        tag: 'UserProfileSettings',
        error: e,
      );
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack(AppLocalizations.of(context).profile_loadFailed);
      }
    }
  }

  // ── 保存操作 ──────────────────────────────────────────────────────────────

  Future<void> _saveProfile() async {
    final l10n = AppLocalizations.of(context);
    try {
      setState(() => _isSaving = true);

      // 收集预设字段
      final toSave = <String, String>{};
      for (final key in [..._coreFieldKeys, ..._extendedFieldKeys]) {
        final v = _controllers[key]!.text.trim();
        if (v.isNotEmpty) toSave[key] = v;
      }

      // 收集自定义属性
      for (final attr in _customAttrs) {
        final key = attr.key.trim();
        final value = attr.valueController.text.trim();
        if (key.isNotEmpty && value.isNotEmpty) {
          toSave[key] = value;
        }
      }

      // 删除值为空的字段
      final allKeys = {..._reservedKeys, ..._customAttrs.map((a) => a.key)};
      for (final key in allKeys) {
        if (!toSave.containsKey(key) && key != '_initialized') {
          await _cognition.deleteUserProfileField(key);
        }
      }

      // 批量写入
      for (final entry in toSave.entries) {
        await _cognition.updateUserProfileField(entry.key, entry.value);
      }

      if (mounted) _showSnack(l10n.profile_saved);
      LoggerService().info('User profile saved', tag: 'UserProfileSettings');
    } catch (e) {
      LoggerService().error(
        'Failed to save profile',
        tag: 'UserProfileSettings',
        error: e,
      );
      if (mounted) _showSnack(l10n.profile_saveFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── 重置操作 ──────────────────────────────────────────────────────────────

  Future<void> _resetProfile() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await _showConfirm(
      title: l10n.profile_resetTitle,
      content: l10n.profile_resetContent,
      destructive: true,
    );
    if (confirmed != true) return;

    try {
      await _cognition.clearUserProfile();
      for (final c in _controllers.values) {
        c.text = '';
      }
      for (final attr in _customAttrs) {
        attr.valueController.dispose();
      }
      setState(() => _customAttrs.clear());
      if (mounted) _showSnack(l10n.profile_resetSuccess);
    } catch (e) {
      if (mounted) _showSnack(l10n.profile_resetFailed);
    }
  }

  // ── 自定义属性 ────────────────────────────────────────────────────────────

  Future<void> _addCustomAttr() async {
    final l10n = AppLocalizations.of(context);
    final keyController = TextEditingController();
    final valueController = TextEditingController();
    String? keyError;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(l10n.profile_addCustomTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyController,
                decoration: InputDecoration(
                  labelText: l10n.profile_attributeName,
                  hintText: l10n.profile_attributeNameHint,
                  errorText: keyError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) {
                  if (keyError != null) {
                    setDialogState(() => keyError = null);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: valueController,
                minLines: 2,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: l10n.profile_attributeValue,
                  hintText: l10n.profile_attributeValueHint,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.common_cancel),
            ),
            TextButton(
              onPressed: () {
                final key = keyController.text.trim();
                final err = _validateCustomKey(key, l10n);
                if (err != null) {
                  setDialogState(() => keyError = err);
                  return;
                }
                Navigator.pop(context, true);
              },
              child: Text(l10n.profile_add),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      final key = keyController.text.trim();
      final value = valueController.text.trim();
      if (key.isNotEmpty) {
        setState(() {
          _customAttrs.add(
            _CustomAttr(
              key: key,
              valueController: TextEditingController(text: value),
            ),
          );
        });
      }
    }

    keyController.dispose();
    valueController.dispose();
  }

  Future<void> _removeCustomAttr(int index) async {
    final l10n = AppLocalizations.of(context);
    final attr = _customAttrs[index];
    final confirmed = await _showConfirm(
      title: l10n.profile_removeAttrTitle,
      content: l10n.profile_removeAttrContent(attr.key),
      destructive: true,
    );
    if (confirmed != true) return;

    attr.valueController.dispose();
    setState(() => _customAttrs.removeAt(index));
  }

  String? _validateCustomKey(String key, AppLocalizations l10n) {
    if (key.isEmpty) return l10n.profile_nameEmpty;
    if (key.startsWith('_')) return l10n.profile_nameStartWithUnderscore;
    if (_reservedKeys.contains(key)) return l10n.profile_nameReserved(key);
    if (_customAttrs.any((a) => a.key == key)) {
      return l10n.profile_nameDuplicate(key);
    }
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(key)) {
      return l10n.profile_nameInvalidChars;
    }
    if (key.length > 50) return l10n.profile_nameTooLong;
    return null;
  }

  // ── 通用 UI ───────────────────────────────────────────────────────────────

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<bool?> _showConfirm({
    required String title,
    required String content,
    bool destructive = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.common_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text(l10n.common_confirm),
          ),
        ],
      ),
    );
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.profile_personalTitle),
          centerTitle: true,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final coreFields = _buildCoreFields(l10n);
    final extendedFields = _buildExtendedFields(l10n);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.profile_personalTitle),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
          // ── 核心字段 ───────────────────────────────
          _sectionHeader(l10n.profile_coreInfo),
          for (final f in coreFields)
            _buildPresetField(f),

          const Divider(height: 32),

          // ── 扩展字段 ───────────────────────────────
          _sectionHeader(l10n.profile_extendedInfo),
          for (final f in extendedFields)
            _buildPresetField(f),

          const Divider(height: 32),

          // ── 自定义属性 ─────────────────────────────
          Row(
            children: [
              Expanded(child: _sectionHeader(l10n.profile_customAttrs)),
              TextButton.icon(
                onPressed: _addCustomAttr,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.profile_add),
              ),
            ],
          ),
          if (_customAttrs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.profile_noCustomAttrs,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                    ),
              ),
            )
          else
            for (var i = 0; i < _customAttrs.length; i++)
              _buildCustomAttrRow(_customAttrs[i], i, l10n),

          const SizedBox(height: 32),

          // ── 底部操作 ───────────────────────────────
          OutlinedButton.icon(
            onPressed: _isSaving ? null : _resetProfile,
            icon: const Icon(Icons.refresh, color: Colors.red),
            label: Text(
              l10n.profile_reset,
              style: const TextStyle(color: Colors.red),
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          const SizedBox(height: 16),
              ],
            ),
          ),
          FormBottomBar(
            child: FormPrimaryButton(
              onPressed: _saveProfile,
              icon: Icons.save,
              label: l10n.common_save,
              isLoading: _isSaving,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: Colors.grey[600],
            ),
      ),
    );
  }

  Widget _buildPresetField(_FieldDef f) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _controllers[f.key],
        keyboardType: f.inputType,
        minLines: f.minLines,
        maxLines: f.minLines > 1 ? f.minLines + 2 : 1,
        decoration: InputDecoration(
          labelText: f.label,
          hintText: f.hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.grey[300]!),
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildCustomAttrRow(_CustomAttr attr, int index, AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: attr.valueController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: attr.key,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: Colors.grey[300]!),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                // 右侧嵌入"Custom"标签，与预设字段视觉区分
                suffixIcon: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Chip(
                    label: Text(
                      l10n.profile_customLabel,
                      style: const TextStyle(fontSize: 11),
                    ),
                    padding: EdgeInsets.zero,
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    backgroundColor: Colors.orange[50],
                    side: BorderSide(color: Colors.orange[300]!),
                  ),
                ),
                suffixIconConstraints: const BoxConstraints(minWidth: 0),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => _removeCustomAttr(index),
            icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
            tooltip: l10n.common_delete,
          ),
        ],
      ),
    );
  }
}

// ── Helper 数据类 ─────────────────────────────────────────────────────────────

/// 预设字段定义（运行时从 l10n 获取 label/hint）
class _FieldDef {
  final String key;
  final String label;
  final String? hint;
  final TextInputType inputType;
  final int minLines;

  const _FieldDef({
    required this.key,
    required this.label,
    this.hint,
    this.inputType = TextInputType.text,
    this.minLines = 1,
  });
}

/// 用户自定义属性（运行时状态）
class _CustomAttr {
  final String key;
  final TextEditingController valueController;

  _CustomAttr({required this.key, required this.valueController});
}
