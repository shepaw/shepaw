import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ChangeNotifier that persists notification preferences via SharedPreferences.
class NotificationProvider extends ChangeNotifier {
  static const _keyEnabled = 'notif_enabled';
  static const _keySound = 'notif_sound';
  static const _keyPreview = 'notif_preview';
  static const _keyMutedAgents = 'notif_muted_agents';

  bool _enabled = true;
  bool _soundEnabled = true;
  bool _showPreview = true;
  Set<String> _mutedAgentIds = {};

  bool get enabled => _enabled;
  bool get soundEnabled => _soundEnabled;
  bool get showPreview => _showPreview;
  Set<String> get mutedAgentIds => Set.unmodifiable(_mutedAgentIds);

  NotificationProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_keyEnabled) ?? true;
    _soundEnabled = prefs.getBool(_keySound) ?? true;
    _showPreview = prefs.getBool(_keyPreview) ?? true;
    final mutedList = prefs.getStringList(_keyMutedAgents);
    if (mutedList != null) {
      _mutedAgentIds = mutedList.toSet();
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, value);
    notifyListeners();
  }

  Future<void> setSoundEnabled(bool value) async {
    if (_soundEnabled == value) return;
    _soundEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySound, value);
    notifyListeners();
  }

  Future<void> setShowPreview(bool value) async {
    if (_showPreview == value) return;
    _showPreview = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyPreview, value);
    notifyListeners();
  }

  Future<void> muteAgent(String agentId) async {
    if (_mutedAgentIds.contains(agentId)) return;
    _mutedAgentIds.add(agentId);
    await _saveMutedAgents();
    notifyListeners();
  }

  Future<void> unmuteAgent(String agentId) async {
    if (!_mutedAgentIds.contains(agentId)) return;
    _mutedAgentIds.remove(agentId);
    await _saveMutedAgents();
    notifyListeners();
  }

  Future<void> _saveMutedAgents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyMutedAgents, _mutedAgentIds.toList());
  }

  /// Returns true if a notification should fire for [agentId].
  bool shouldNotify(String agentId) {
    if (!_enabled) return false;
    if (_mutedAgentIds.contains(agentId)) return false;
    return true;
  }
}
