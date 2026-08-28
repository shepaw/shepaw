import 'package:shared_preferences/shared_preferences.dart';

import 'she_service.dart';

/// In-app confirmation policy for `location_get`.
///
/// OS location permission is the real gate. This only controls whether She
/// must also pop an in-app review dialog on each call.
///
/// - She: skip by default; Settings → Location can require confirmation.
/// - Other agents: always confirm (and can disable the tool entirely).
class LocationAccessPolicy {
  LocationAccessPolicy._();

  static const prefsKey = 'location_she_auto_approve';
  static const defaultSheAutoApprove = true;

  /// Tests can pin this to avoid SharedPreferences.
  static bool? sheAutoApproveOverride;

  static Future<bool> sheAutoApprove() async {
    if (sheAutoApproveOverride != null) return sheAutoApproveOverride!;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? defaultSheAutoApprove;
  }

  static Future<void> setSheAutoApprove(bool value) async {
    sheAutoApproveOverride = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, value);
  }

  /// Whether the OS-tool confirmation dialog should be skipped.
  static bool shouldSkipOsConfirmation({
    required String agentId,
    required String toolName,
    required bool sheAutoApprove,
  }) {
    if (toolName != 'location_get') return false;
    if (!SheService.isSheIdentity(agentId)) return false;
    return sheAutoApprove;
  }

  static Future<bool> shouldSkipOsConfirmationFor({
    required String agentId,
    required String toolName,
  }) async {
    return shouldSkipOsConfirmation(
      agentId: agentId,
      toolName: toolName,
      sheAutoApprove: await sheAutoApprove(),
    );
  }
}
