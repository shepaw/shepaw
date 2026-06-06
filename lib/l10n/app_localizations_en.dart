// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'ShePaw';

  @override
  String get appVersion => 'ShePaw v1.0.0';

  @override
  String get appDescription => 'Secure AI Agent Management Platform';

  @override
  String get common_cancel => 'Cancel';

  @override
  String get common_confirm => 'Confirm';

  @override
  String get common_save => 'Save';

  @override
  String get common_delete => 'Delete';

  @override
  String get common_edit => 'Edit';

  @override
  String get common_close => 'Close';

  @override
  String get common_loading => 'Loading...';

  @override
  String get common_retry => 'Retry';

  @override
  String get common_ok => 'OK';

  @override
  String get common_copy => 'Copy';

  @override
  String get common_reply => 'Reply';

  @override
  String get common_search => 'Search';

  @override
  String get common_refresh => 'Refresh';

  @override
  String get common_clear => 'Clear';

  @override
  String get common_optional => 'Optional';

  @override
  String get common_featureComingSoon => 'Feature coming soon';

  @override
  String common_operationFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String common_error(String error) {
    return 'Error: $error';
  }

  @override
  String get splash_loading => 'Loading...';

  @override
  String get login_title => 'ShePaw';

  @override
  String get login_subtitle => 'Enter password to unlock';

  @override
  String get login_password => 'Password';

  @override
  String get login_passwordHint => 'Enter your password';

  @override
  String get login_button => 'Login';

  @override
  String get login_forgotPassword => 'Forgot password?';

  @override
  String get login_emptyPassword => 'Please enter your password';

  @override
  String get login_tooManyAttempts =>
      'Too many failed attempts. Please try again later';

  @override
  String login_wrongPassword(int attempts) {
    return 'Wrong password. Please try again ($attempts/3)';
  }

  @override
  String login_failed(String error) {
    return 'Login failed: $error';
  }

  @override
  String get login_resetPasswordTitle => 'Reset Password';

  @override
  String get login_resetPasswordContent =>
      'After resetting your password, you will enter a completely new data space.';

  @override
  String get login_resetPasswordVaultHint =>
      'Your old data will be securely encrypted and saved. You can restore it anytime via Settings → Data Vault using your old password.';

  @override
  String get login_confirmReset => 'Confirm Reset';

  @override
  String get passwordSetup_title => 'Set Login Password';

  @override
  String get passwordSetup_subtitle =>
      'Set a secure password to protect your account';

  @override
  String get passwordSetup_password => 'Set Password';

  @override
  String get passwordSetup_passwordHint =>
      'At least 6 characters, including letters and numbers';

  @override
  String get passwordSetup_confirmPassword => 'Confirm Password';

  @override
  String get passwordSetup_confirmPasswordHint => 'Enter password again';

  @override
  String get passwordSetup_submit => 'Complete Setup';

  @override
  String get passwordSetup_requirementsTitle => 'Password requirements:';

  @override
  String get passwordSetup_reqLength => '6-20 characters';

  @override
  String get passwordSetup_reqAlphaNum => 'Must include letters and numbers';

  @override
  String get passwordSetup_reqSpecialChars =>
      'Special characters recommended for stronger security';

  @override
  String get passwordSetup_emptyPassword => 'Please enter a password';

  @override
  String get passwordSetup_tooShort => 'Password must be at least 6 characters';

  @override
  String get passwordSetup_tooLong => 'Password must not exceed 20 characters';

  @override
  String get passwordSetup_needAlphaNum =>
      'Password must include letters and numbers';

  @override
  String get passwordSetup_mismatch => 'Passwords do not match';

  @override
  String get passwordSetup_setFailed =>
      'Failed to set password. Please try again';

  @override
  String passwordSetup_errorOccurred(String error) {
    return 'An error occurred: $error';
  }

  @override
  String get passwordSetup_agreePrefix => 'I have read and agree to the';

  @override
  String get passwordSetup_and => 'and';

  @override
  String get passwordSetup_termsNotAccepted =>
      'Please read and agree to the Terms of Service and Privacy Policy';

  @override
  String get changePassword_title => 'Change Password';

  @override
  String get changePassword_currentPassword => 'Current Password';

  @override
  String get changePassword_currentPasswordHint => 'Enter current password';

  @override
  String get changePassword_newPassword => 'New Password';

  @override
  String get changePassword_newPasswordHint =>
      'At least 6 characters, including letters and numbers';

  @override
  String get changePassword_confirmNewPassword => 'Confirm New Password';

  @override
  String get changePassword_confirmNewPasswordHint =>
      'Enter new password again';

  @override
  String get changePassword_submit => 'Confirm Change';

  @override
  String get changePassword_requirementsTitle => 'New password requirements:';

  @override
  String get changePassword_reqLength => '6-20 characters';

  @override
  String get changePassword_reqAlphaNum => 'Must include letters and numbers';

  @override
  String get changePassword_reqDifferent => 'Must differ from current password';

  @override
  String get changePassword_emptyCurrentPassword =>
      'Please enter current password';

  @override
  String get changePassword_sameAsOld =>
      'New password must differ from current password';

  @override
  String get changePassword_newMismatch => 'New passwords do not match';

  @override
  String get changePassword_success => 'Password changed successfully';

  @override
  String get changePassword_wrongCurrent =>
      'Incorrect current password. Please try again';

  @override
  String changePassword_failed(String error) {
    return 'Failed to change password: $error';
  }

  @override
  String get home_noAgents => 'No Agents';

  @override
  String get home_noAgentsHint => 'Tap the menu to add agents';

  @override
  String get home_noMessages => 'No messages';

  @override
  String get home_typing => 'Typing...';

  @override
  String get home_statusOnline => 'Online';

  @override
  String get home_statusOffline => 'Offline';

  @override
  String get home_statusThinking => 'Thinking';

  @override
  String get home_yesterday => 'Yesterday';

  @override
  String get home_weekMon => 'Mon';

  @override
  String get home_weekTue => 'Tue';

  @override
  String get home_weekWed => 'Wed';

  @override
  String get home_weekThu => 'Thu';

  @override
  String get home_weekFri => 'Fri';

  @override
  String get home_weekSat => 'Sat';

  @override
  String get home_weekSun => 'Sun';

  @override
  String get home_addAgent => 'Add Agent';

  @override
  String get home_createGroup => 'Create Group';

  @override
  String get home_addDevice => 'Device Pairing';

  @override
  String get home_scanConnect => 'Scan to Connect';

  @override
  String get home_searchEmptyHint => 'Search agents, groups, and messages';

  @override
  String get home_searchNoResults => 'No results found';

  @override
  String get home_searchSectionAgents => 'Agents';

  @override
  String get home_searchSectionGroups => 'Groups';

  @override
  String get home_searchSectionMessages => 'Messages';

  @override
  String home_agentsCount(int count) {
    return '$count agents';
  }

  @override
  String get drawer_myProfile => 'My Profile';

  @override
  String get drawer_newAgent => 'New Agent';

  @override
  String get drawer_newGroup => 'New Group';

  @override
  String get drawer_newDevice => 'New Device';

  @override
  String get drawer_settings => 'Settings';

  @override
  String get drawer_logout => 'Logout';

  @override
  String get logout_confirmTitle => 'Confirm Logout';

  @override
  String get logout_confirmContent => 'Are you sure you want to logout?';

  @override
  String get settings_title => 'Settings';

  @override
  String get settings_security => 'Security';

  @override
  String get settings_changePassword => 'Change Password';

  @override
  String get settings_changePasswordSub => 'Change your login password';

  @override
  String get settings_dataVault => 'Data Vault';

  @override
  String get settings_dataVaultSub =>
      'View and restore data backups from before password reset';

  @override
  String get vault_emptyTitle => 'No backups yet';

  @override
  String get vault_emptyDesc =>
      'Each time you reset your password,\nold data is automatically encrypted and saved here.';

  @override
  String get vault_infoBanner =>
      'Each time you reset your password, your old data is automatically encrypted and saved.\nTap \"Restore\" and enter the corresponding old password to recover your data.';

  @override
  String get vault_restoreTitle => 'Restore Old Data';

  @override
  String vault_backupTime(String date) {
    return 'Backup time: $date';
  }

  @override
  String vault_fileSize(String size) {
    return 'File size: $size';
  }

  @override
  String vault_size(String size) {
    return 'Size: $size';
  }

  @override
  String get vault_restorePasswordPrompt =>
      'Enter the old password for this backup to unlock:';

  @override
  String get vault_oldPassword => 'Old Password';

  @override
  String get vault_restoreWarning =>
      'Restoring will overwrite all current data. This cannot be undone.';

  @override
  String get vault_confirmRestore => 'Confirm Restore';

  @override
  String get vault_emptyPassword => 'Please enter the old password';

  @override
  String get vault_restoreFailed =>
      'Wrong password or corrupted backup. Please try again.';

  @override
  String get vault_restoreSuccess =>
      'Data restored successfully! Please restart the app to load the restored data.';

  @override
  String get vault_deleteTitle => 'Delete Backup';

  @override
  String vault_deleteConfirm(String date) {
    return 'Are you sure you want to permanently delete this backup?\n\nBackup time: $date\nThe data cannot be recovered after deletion.';
  }

  @override
  String get vault_deleted => 'Backup deleted';

  @override
  String get vault_restore => 'Restore';

  @override
  String get vault_deleteTooltip => 'Delete backup';

  @override
  String get settings_biometric => 'Biometric Authentication';

  @override
  String get settings_biometricSub => 'Use fingerprint or face ID';

  @override
  String get settings_biometricComingSoon =>
      'Biometric authentication coming soon';

  @override
  String get settings_biometricNotSupported =>
      'Biometric authentication is not supported on this device';

  @override
  String get settings_biometricEnablePrompt =>
      'Please verify your identity to enable biometric authentication';

  @override
  String get settings_biometricEnabled => 'Biometric authentication enabled';

  @override
  String get settings_biometricDisabled => 'Biometric authentication disabled';

  @override
  String get login_biometricPrompt => 'Verify your identity to unlock ShePaw';

  @override
  String get login_useBiometric => 'Use biometric authentication';

  @override
  String get settings_account => 'Account';

  @override
  String get settings_profile => 'Profile';

  @override
  String get settings_profileSub => 'Manage your profile information';

  @override
  String get settings_notifications => 'Notifications';

  @override
  String get settings_notificationsSub => 'Manage push notifications';

  @override
  String get settings_dataManagement => 'Data Management';

  @override
  String get settings_exportData => 'Export Data';

  @override
  String get settings_exportDataSub => 'Backup all app data to a file';

  @override
  String get settings_clearAllData => 'Clear All Data';

  @override
  String get settings_clearAllDataSub =>
      'Delete all agents, messages, and files';

  @override
  String get settings_about => 'About';

  @override
  String get settings_aboutVersion => 'Version 1.0.0';

  @override
  String get settings_checkForUpdates => 'Check for Updates';

  @override
  String get settings_checkForUpdatesSub => 'Check for the latest version';

  @override
  String get update_checking => 'Checking for updates...';

  @override
  String get update_upToDate => 'You\'re up to date!';

  @override
  String update_upToDateSub(String version) {
    return 'Paw $version is the latest version.';
  }

  @override
  String get update_available => 'Update Available';

  @override
  String update_availableVersion(String version) {
    return 'Paw $version is now available';
  }

  @override
  String get update_mandatoryTitle => 'Required Update';

  @override
  String update_mandatoryMessage(String version) {
    return 'This update is required to continue using Paw. Please update to version $version.';
  }

  @override
  String get update_releaseNotes => 'Release Notes';

  @override
  String get update_downloadNow => 'Download Now';

  @override
  String get update_remindLater => 'Remind Me Later';

  @override
  String get update_skipVersion => 'Skip This Version';

  @override
  String get update_checkFailed =>
      'Unable to check for updates. Please check your network connection.';

  @override
  String update_currentVersion(String version) {
    return 'Current version: $version';
  }

  @override
  String get update_downloading => 'Downloading...';

  @override
  String update_downloadingFile(String fileName) {
    return 'Downloading $fileName';
  }

  @override
  String update_downloadProgress(String downloaded, String total) {
    return '$downloaded / $total';
  }

  @override
  String update_downloadSpeed(String speed) {
    return '$speed/s';
  }

  @override
  String update_downloadTimeRemaining(String time) {
    return '$time remaining';
  }

  @override
  String get update_downloadCompleted => 'Download completed';

  @override
  String get update_downloadFailed => 'Download failed';

  @override
  String get update_retryDownload => 'Retry Download';

  @override
  String update_notification_availableTitle(String version) {
    return 'New version $version available';
  }

  @override
  String get update_notification_availableBody => 'Tap to view update details';

  @override
  String get update_notification_readyTitle => 'Update ready to install';

  @override
  String update_notification_readyBody(String version) {
    return 'Tap to install $version';
  }

  @override
  String get update_action_accept => 'Download Now';

  @override
  String get update_action_decline => 'Not Now';

  @override
  String get update_action_installNow => 'Install Now';

  @override
  String get update_action_installLater => 'Later';

  @override
  String get update_pendingInstallTitle => 'Update ready';

  @override
  String update_pendingInstallBody(String version) {
    return 'Version $version has been downloaded. Install now?';
  }

  @override
  String get settings_privacyPolicy => 'Privacy Policy';

  @override
  String get settings_termsOfService => 'Terms of Service';

  @override
  String get settings_language => 'Language';

  @override
  String get settings_languageSub => 'Change app display language';

  @override
  String get settings_languageFollowSystem => 'Follow System';

  @override
  String get settings_languageEnglish => 'English';

  @override
  String get settings_languageChinese => '中文';

  @override
  String get settings_languageDialogTitle => 'Select Language';

  @override
  String get settings_exportDataTitle => 'Export Data';

  @override
  String get settings_exportDataContent =>
      'This will export all app data (including agent configurations, chat history, files, etc.) as a backup file.\n\nOnce exported, you can share it to another location.';

  @override
  String get settings_exportingData => 'Exporting data...';

  @override
  String get settings_exportSuccess => 'Data exported successfully';

  @override
  String settings_exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get settings_clearAllDataTitle => 'Clear All Data';

  @override
  String get settings_clearAllDataContent =>
      'This will delete ALL data, including:\n\n• All agent configurations\n• All chat history and messages\n• All files and images\n\nThis action cannot be undone! It is recommended to export a backup first.\n\nContinue?';

  @override
  String get settings_clearAllDataButton => 'Clear All Data';

  @override
  String get settings_clearingAllData => 'Clearing all data...';

  @override
  String get settings_clearAllDataSuccess => 'All data has been cleared';

  @override
  String settings_clearAllDataFailed(String error) {
    return 'Failed to clear data: $error';
  }

  @override
  String get addAgent_connectTitle => 'Connect Remote Agent';

  @override
  String get addAgent_createTitle => 'Create Agent Configuration';

  @override
  String get addAgent_modeConnect => 'Connect Remote Agent';

  @override
  String get addAgent_modeCreate => 'Create Local Configuration';

  @override
  String get addAgent_basicInfo => 'Basic Info';

  @override
  String get addAgent_agentName => 'Agent Name';

  @override
  String get addAgent_agentNameHint => 'e.g., My AI Assistant';

  @override
  String get addAgent_agentNameRequired => 'Please enter agent name';

  @override
  String get addAgent_agentBio => 'Description (optional)';

  @override
  String get addAgent_agentBioHint =>
      'Briefly describe the agent\'s capabilities';

  @override
  String get addAgent_systemPrompt => 'System Prompt (optional)';

  @override
  String get addAgent_systemPromptHint =>
      'Define the agent\'s role and capabilities';

  @override
  String get addAgent_connectConfig => 'Connection Configuration';

  @override
  String get addAgent_tokenAuth => 'Token Authentication';

  @override
  String get addAgent_tokenHint => 'Enter Token or click button to generate';

  @override
  String get addAgent_generateToken => 'Generate Random Token';

  @override
  String get addAgent_tokenRequired => 'Please enter or generate a Token';

  @override
  String get addAgent_endpointUrl => 'Endpoint URL';

  @override
  String get addAgent_endpointUrlHint => 'ws://example.com:8080/acp/ws';

  @override
  String get addAgent_endpointHelper => 'Remote agent service address';

  @override
  String get addAgent_endpointRequired => 'Please enter endpoint URL';

  @override
  String get addAgent_endpointInvalid =>
      'Please enter a valid URL (http://, https://, ws://, wss://)';

  @override
  String get addAgent_modelConfig => 'Model Configuration';

  @override
  String get addAgent_modelConfigHint =>
      'Select LLM provider to auto-fill default configuration';

  @override
  String get addAgent_modelName => 'Model Name';

  @override
  String get addAgent_modelNameHint => 'Enter model name';

  @override
  String get addAgent_selectModel => 'Select Model';

  @override
  String get addAgent_apiKeyNotRequired =>
      'No API Key required for local services';

  @override
  String get addAgent_apiKeyHint => 'Enter API Key';

  @override
  String get addAgent_connectSteps => 'Connection Steps';

  @override
  String get addAgent_connectStep1 =>
      'Enter Token provided by remote Agent or generate one';

  @override
  String get addAgent_connectStep2 => 'Enter the remote Agent service address';

  @override
  String get addAgent_connectStep3 =>
      'Start chatting after successful connection';

  @override
  String get addAgent_connectButton => 'Connect Remote Agent';

  @override
  String get addAgent_createButton => 'Create Agent Configuration';

  @override
  String addAgent_createFailed(String error) {
    return 'Creation failed: $error';
  }

  @override
  String get addAgent_testingConnection => 'Testing agent connection...';

  @override
  String get addAgent_connectSuccess =>
      'Connection successful! Agent is online';

  @override
  String get addAgent_createSuccess => 'Agent created successfully!';

  @override
  String get addAgent_connectFailTitle => 'Connection Test Failed';

  @override
  String get addAgent_connectFailContent =>
      'Agent health check failed. Cannot establish connection.\n\nPossible causes:\n• Incorrect Endpoint URL\n• Invalid Token\n• Agent service not running\n• Network connection issues\n\nDo you still want to keep this Agent configuration?';

  @override
  String get addAgent_deleteConfig => 'Delete Configuration';

  @override
  String get addAgent_keepConfig => 'Keep Configuration';

  @override
  String get addAgent_configDeleted => 'Agent configuration deleted';

  @override
  String get addAgent_configKeptOffline => 'Agent configuration kept (offline)';

  @override
  String addAgent_operationFailed(String error) {
    return 'Operation failed: $error';
  }

  @override
  String get addAgent_duplicateTitle => 'Agent Already Exists';

  @override
  String get addAgent_existingInfo => 'Existing agent info:';

  @override
  String addAgent_existingName(String name) {
    return 'Name: $name';
  }

  @override
  String addAgent_existingProtocol(String protocol) {
    return 'Protocol: $protocol';
  }

  @override
  String get addAgent_selectAvatar => 'Select Avatar';

  @override
  String get addAgent_endpointConfigTitle => 'Endpoint Configuration';

  @override
  String get addAgent_endpointOptional => 'Endpoint URL (optional)';

  @override
  String get addAgent_endpointOptionalHelper => 'Can be configured later';

  @override
  String get addAgent_remoteAgentId => 'Remote Agent ID';

  @override
  String get addAgent_remoteAgentIdHint => 'Optional, the remote agent\'s ID';

  @override
  String get addAgent_remoteAgentIdHelper =>
      'Specify the target agent ID (optional)';

  @override
  String get createGroup_title => 'Create Group';

  @override
  String get createGroup_create => 'Create';

  @override
  String get createGroup_groupName => 'Group Name';

  @override
  String get createGroup_purpose => 'Group Purpose (optional)';

  @override
  String get createGroup_purposeHint =>
      'e.g., Collaborate on frontend development tasks';

  @override
  String get createGroup_selectAgent => 'Select Agents';

  @override
  String createGroup_agentCount(int selected, int total) {
    return '($selected/$total)';
  }

  @override
  String get createGroup_noAgents =>
      'No agents available. Please add an agent first';

  @override
  String get createGroup_setAsAdmin => 'Set as Admin';

  @override
  String get createGroup_nameRequired => 'Please enter group name';

  @override
  String get createGroup_agentRequired => 'Please select at least one agent';

  @override
  String get createGroup_adminRequired => 'Please select an admin';

  @override
  String get createGroup_button => 'Create Group';

  @override
  String get createGroup_systemPrompt => 'System Prompt (optional)';

  @override
  String get createGroup_systemPromptHint =>
      'Define constraints or instructions for agents in this group';

  @override
  String get createGroup_groupRole => 'Role in group (optional)';

  @override
  String get createGroup_groupRoleHint =>
      'Describe this agent\'s role in the group';

  @override
  String get createGroup_maxLoopRounds => 'Max Orchestration Rounds';

  @override
  String get createGroup_maxLoopRoundsHint =>
      'Max loop rounds for admin orchestration (default 50)';

  @override
  String get permission_title => 'Permission Request Management';

  @override
  String get permission_filterLabel => 'Filter by status:';

  @override
  String get permission_noRequests => 'No permission requests';

  @override
  String permission_noRequestsOfType(String status) {
    return 'No $status permission requests';
  }

  @override
  String permission_loadFailed(String error) {
    return 'Load failed: $error';
  }

  @override
  String get permission_approved => 'Permission approved';

  @override
  String get permission_rejected => 'Permission rejected';

  @override
  String get permission_typeLabel => 'Permission Type';

  @override
  String get permission_reasonLabel => 'Reason';

  @override
  String get permission_timeLabel => 'Request Time';

  @override
  String get permission_expiryLabel => 'Valid Until';

  @override
  String get permission_reject => 'Reject';

  @override
  String get permission_approve => 'Approve';

  @override
  String get permission_revoke => 'Revoke';

  @override
  String get permission_approveTitle => 'Approve Permission';

  @override
  String permission_approveContent(String agentName, String permissionType) {
    return 'Approve $permissionType permission for $agentName?';
  }

  @override
  String get permission_rejectTitle => 'Reject Permission';

  @override
  String permission_rejectContent(String agentName) {
    return 'Reject permission request from $agentName?';
  }

  @override
  String get permission_revokeTitle => 'Revoke Permission';

  @override
  String permission_revokeContent(String agentName) {
    return 'Revoke permission for $agentName? The agent will no longer be able to access related features.';
  }

  @override
  String get permission_statusPending => 'Pending';

  @override
  String get permission_statusApproved => 'Approved';

  @override
  String get permission_statusRejected => 'Rejected';

  @override
  String get permission_statusExpired => 'Expired';

  @override
  String get permission_typeInitiateChat => 'Initiate Chat';

  @override
  String get permission_typeGetAgentList => 'Get Agent List';

  @override
  String get permission_typeGetCapabilities => 'Get Agent Capabilities';

  @override
  String get permission_typeSubscribeChannel => 'Subscribe Channel';

  @override
  String get permission_typeSendFile => 'Send File';

  @override
  String get permission_typeGetSessions => 'Get Session List';

  @override
  String get permission_typeGetSessionMessages => 'Get Session Messages';

  @override
  String get permission_typeGetAttachmentContent => 'Get Attachment Content';

  @override
  String get permissionDialog_title => 'Permission Request';

  @override
  String get permissionDialog_agent => 'Agent';

  @override
  String get permissionDialog_action => 'Action';

  @override
  String get permissionDialog_reason => 'Reason';

  @override
  String get permissionDialog_time => 'Time';

  @override
  String get permissionDialog_reject => 'Reject';

  @override
  String get permissionDialog_approve => 'Approve';

  @override
  String get log_title => 'System Logs';

  @override
  String get log_filterTooltip => 'Filter log level';

  @override
  String get log_all => 'All';

  @override
  String get log_enableAutoScroll => 'Enable auto-scroll';

  @override
  String get log_disableAutoScroll => 'Disable auto-scroll';

  @override
  String get log_export => 'Export Logs';

  @override
  String get log_exported => 'Logs exported';

  @override
  String get log_clearTitle => 'Clear Logs';

  @override
  String get log_clearContent =>
      'Are you sure you want to clear all logs? This action cannot be undone.';

  @override
  String get log_clearButton => 'Clear';

  @override
  String get log_noLogs => 'No logs';

  @override
  String get log_total => 'Total';

  @override
  String get agentDetail_title => 'Agent Details';

  @override
  String get agentDetail_editTitle => 'Edit Agent';

  @override
  String get agentDetail_editTooltip => 'Edit';

  @override
  String get agentDetail_startConversation => 'Start Conversation';

  @override
  String get agentDetail_deleteAgent => 'Delete Agent';

  @override
  String get agentDetail_confirmDelete => 'Confirm Delete';

  @override
  String agentDetail_deleteContent(String name) {
    return 'Are you sure you want to delete agent \"$name\"?\n\nThis cannot be undone, and related chat history may be affected.';
  }

  @override
  String agentDetail_deleted(String name) {
    return 'Deleted \"$name\"';
  }

  @override
  String agentDetail_deleteFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get agentDetail_connectionInfo => 'Connection Info';

  @override
  String get agentDetail_protocol => 'Protocol';

  @override
  String get agentDetail_connectionType => 'Connection Type';

  @override
  String get agentDetail_endpoint => 'Endpoint';

  @override
  String get agentDetail_capabilities => 'Capabilities';

  @override
  String get agentDetail_systemPrompt => 'System Prompt';

  @override
  String get agentDetail_llmConfig => 'LLM Configuration';

  @override
  String get agentDetail_provider => 'Provider';

  @override
  String get agentDetail_model => 'Model';

  @override
  String get agentDetail_lastActive => 'Last Active';

  @override
  String get agentDetail_createdAt => 'Created';

  @override
  String get agentDetail_authToken => 'Auth Token';

  @override
  String get agentDetail_copyToken => 'Copy Token';

  @override
  String get agentDetail_tokenCopied => 'Token copied to clipboard';

  @override
  String get agentDetail_nameRequired => 'Agent name cannot be empty';

  @override
  String get agentDetail_tokenRequired => 'Token cannot be empty';

  @override
  String get agentDetail_tokenHint =>
      'Paste the token provided by the remote agent';

  @override
  String get agentDetail_saveSuccess => 'Saved successfully';

  @override
  String agentDetail_saveFailed(String error) {
    return 'Save failed: $error';
  }

  @override
  String get agentDetail_changeAvatar => 'Change Avatar';

  @override
  String get agentDetail_selectBuiltinAvatar => 'Select Built-in Icon';

  @override
  String get agentDetail_selectFromGallery => 'Choose from Gallery';

  @override
  String get agentDetail_takePhoto => 'Take Photo';

  @override
  String agentDetail_galleryFailed(String error) {
    return 'Failed to pick image: $error';
  }

  @override
  String agentDetail_cameraFailed(String error) {
    return 'Failed to take photo: $error';
  }

  @override
  String agentDetail_saveImageFailed(String error) {
    return 'Failed to save image: $error';
  }

  @override
  String get agentDetail_protocolType => 'Protocol Type';

  @override
  String get agentDetail_connectionTypeLabel => 'Connection Type';

  @override
  String get agentDetail_custom => 'Custom';

  @override
  String get agentDetail_copyTokenTooltip => 'Copy Token';

  @override
  String get agentDetail_justNow => 'Just now';

  @override
  String agentDetail_minutesAgo(int minutes) {
    return '$minutes min ago';
  }

  @override
  String agentDetail_hoursAgo(int hours) {
    return '$hours hr ago';
  }

  @override
  String get profile_title => 'My Profile';

  @override
  String get profile_email => 'Email';

  @override
  String get profile_phone => 'Phone';

  @override
  String get profile_birthday => 'Birthday';

  @override
  String get profile_location => 'Location';

  @override
  String get profile_notSet => 'Not set';

  @override
  String get profile_agents => 'Agents';

  @override
  String get profile_groups => 'Groups';

  @override
  String get profile_messages => 'Messages';

  @override
  String get profile_editProfile => 'Edit Profile';

  @override
  String get collaboration_title => 'Agent Collaboration';

  @override
  String get collaboration_description =>
      'Have multiple agents collaborate on complex tasks with various strategies.';

  @override
  String get collaboration_taskName => 'Task Name';

  @override
  String get collaboration_taskNameHint => 'e.g., Market Research Report';

  @override
  String get collaboration_taskNameRequired => 'Please enter task name';

  @override
  String get collaboration_taskDescription => 'Task Description';

  @override
  String get collaboration_taskDescriptionHint => 'Describe the task in detail';

  @override
  String get collaboration_taskDescriptionRequired =>
      'Please enter task description';

  @override
  String get collaboration_initialMessage => 'Initial Message';

  @override
  String get collaboration_initialMessageHint =>
      'Message to start collaboration';

  @override
  String get collaboration_initialMessageRequired =>
      'Please enter initial message';

  @override
  String get collaboration_strategy => 'Collaboration Strategy';

  @override
  String get collaboration_selectAgent => 'Select Agents';

  @override
  String collaboration_selectedCount(int selected, int total) {
    return 'Selected $selected/$total';
  }

  @override
  String get collaboration_noAgents => 'No agents available';

  @override
  String get collaboration_noDescription => 'No description';

  @override
  String get collaboration_start => 'Start Collaboration';

  @override
  String get collaboration_result => 'Collaboration Result';

  @override
  String get collaboration_finalOutput => 'Final Output';

  @override
  String get collaboration_agentResults => 'Agent Results';

  @override
  String get collaboration_success => 'Collaboration completed successfully';

  @override
  String collaboration_taskFailed(String error) {
    return 'Collaboration failed: $error';
  }

  @override
  String get collaboration_loadAgentFailed => 'Failed to load agents';

  @override
  String get collaboration_executeFailed => 'Failed to execute collaboration';

  @override
  String get collaboration_selectAgentWarning =>
      'Please select at least one agent';

  @override
  String get collaboration_strategySequential => 'Sequential';

  @override
  String get collaboration_strategyParallel => 'Parallel';

  @override
  String get collaboration_strategyVoting => 'Voting';

  @override
  String get collaboration_strategyPipeline => 'Pipeline';

  @override
  String get collaboration_strategySequentialDesc =>
      'Agents process sequentially, each using the previous output as input';

  @override
  String get collaboration_strategyParallelDesc =>
      'All agents process the same input simultaneously';

  @override
  String get collaboration_strategyVotingDesc =>
      'Multiple agents vote for the best result';

  @override
  String get collaboration_strategyPipelineDesc =>
      'Each agent handles a specific stage';

  @override
  String get collaboration_helpTitle => 'Strategy Guide';

  @override
  String get collaboration_helpSequential =>
      'Agents process sequentially, suitable for tasks needing iterative refinement.';

  @override
  String get collaboration_helpParallel =>
      'All agents process simultaneously, suitable for multi-perspective analysis.';

  @override
  String get collaboration_helpVoting =>
      'Multiple agents vote for the best approach, suitable for decision-making tasks.';

  @override
  String get collaboration_helpPipeline =>
      'Each agent handles a specific stage, suitable for complex multi-step tasks.';

  @override
  String get incoming_title => 'Incoming Messages';

  @override
  String incoming_unreadCount(int count) {
    return '$count unread';
  }

  @override
  String get incoming_clearAll => 'Clear all messages';

  @override
  String get incoming_noMessages => 'No incoming messages';

  @override
  String get incoming_noMessagesHint => 'Messages from agents will appear here';

  @override
  String get incoming_markAsRead => 'Mark as read';

  @override
  String get incoming_view => 'View';

  @override
  String incoming_time(String time) {
    return 'Time: $time';
  }

  @override
  String get incoming_clearAllTitle => 'Clear All Messages';

  @override
  String get incoming_clearAllContent =>
      'Are you sure you want to clear all messages? This cannot be undone.';

  @override
  String get incoming_clearButton => 'Clear';

  @override
  String get incoming_justNow => 'Just now';

  @override
  String incoming_minutesAgo(int minutes) {
    return '$minutes min ago';
  }

  @override
  String incoming_hoursAgo(int hours) {
    return '$hours hr ago';
  }

  @override
  String incoming_daysAgo(int days) {
    return '$days days ago';
  }

  @override
  String get chat_noAgentSelected => 'No agent selected';

  @override
  String chat_loadFailed(String error) {
    return 'Failed to load messages: $error';
  }

  @override
  String get chat_checkingHealth => 'Checking agent health...';

  @override
  String chat_reconnectingAttempt(int attempt, int total) {
    return 'Reconnecting… ($attempt/$total)';
  }

  @override
  String get chat_reconnectFailed =>
      'Unable to reach agent. Please verify the agent is online.';

  @override
  String chat_responseError(String agentName) {
    return 'Failed to get response from $agentName';
  }

  @override
  String get chat_voiceTooShort => 'Voice message too short';

  @override
  String get chat_historyRequestTitle =>
      'Agent requests to view more chat history';

  @override
  String get chat_historyIgnore => 'Ignore';

  @override
  String get chat_historyApprove => 'Approve';

  @override
  String get chat_loadingHistory => 'Loading more chat history...';

  @override
  String get chat_noMoreHistory => 'No more history to load';

  @override
  String get chat_historyLoaded => 'History loaded, agent is re-answering...';

  @override
  String chat_historyLoadFailed(String error) {
    return 'Failed to load history: $error';
  }

  @override
  String get chat_historyIgnored => 'History request ignored';

  @override
  String get chat_messageHint => 'Type a message...';

  @override
  String get chat_holdToRecord => 'Hold to record a voice message';

  @override
  String get chat_holdToTalk => 'Hold to Talk';

  @override
  String get chat_releaseToSend => 'Release to Send';

  @override
  String get chat_releaseToCancel => 'Release to Cancel';

  @override
  String get chat_micNotAvailable =>
      'Cannot start recording. Microphone may not be available on this device.';

  @override
  String get chat_photoLibrary => 'Photo Library';

  @override
  String get chat_camera => 'Camera';

  @override
  String get chat_file => 'File';

  @override
  String chat_sendImageError(String error) {
    return 'Error sending image: $error';
  }

  @override
  String chat_sendFileError(String error) {
    return 'Error sending file: $error';
  }

  @override
  String chat_searchError(String error) {
    return 'Search error: $error';
  }

  @override
  String get chat_cannotDelete => 'Cannot delete this message';

  @override
  String get chat_deleteTitle => 'Delete Message';

  @override
  String get chat_deleteContent =>
      'Are you sure you want to delete this message?';

  @override
  String get chat_deleted => 'Message deleted';

  @override
  String get chat_rollbackTitle => 'Rollback Messages';

  @override
  String get chat_reEditTitle => 'Re-edit Message';

  @override
  String get chat_rollbackContent =>
      'This will delete this message and all messages after it. This action cannot be undone.';

  @override
  String chat_rollbackSuccess(int count) {
    return 'Rolled back $count messages';
  }

  @override
  String chat_reEditSuccess(int count) {
    return 'Re-editing message: rolled back $count messages';
  }

  @override
  String chat_rollbackFailed(String error) {
    return 'Rollback failed: $error';
  }

  @override
  String get chat_copiedToClipboard => 'Copied to clipboard';

  @override
  String get chat_download => 'Download';

  @override
  String get chat_rollback => 'Rollback';

  @override
  String get chat_rollbackSub => 'Delete this and all later messages';

  @override
  String get chat_reEdit => 'Re-edit';

  @override
  String get chat_reEditSub => 'Rollback and edit this message';

  @override
  String get chat_editGroupInfo => 'Edit Group Info';

  @override
  String get chat_groupName => 'Group Name';

  @override
  String get chat_groupDescription => 'Description (optional)';

  @override
  String get chat_groupNameEmpty => 'Group name cannot be empty';

  @override
  String get chat_groupMembers => 'Group Members';

  @override
  String chat_groupMembersCount(int count) {
    return '$count agents';
  }

  @override
  String get chat_addMember => 'Add Member';

  @override
  String get chat_noMoreAgents => 'No more agents available to add';

  @override
  String get chat_changeAdmin => 'Change Admin';

  @override
  String chat_currentAdmin(String name) {
    return 'Current: $name';
  }

  @override
  String chat_adminChanged(String name) {
    return '$name is now the admin';
  }

  @override
  String get chat_removeMember => 'Remove Member';

  @override
  String chat_removeMemberContent(String name) {
    return 'Remove $name from this group?';
  }

  @override
  String get chat_removeButton => 'Remove';

  @override
  String get chat_cannotRemoveLast => 'Cannot remove the last member';

  @override
  String get chat_waitingForAction => 'is waiting for your action';

  @override
  String get chat_searchMessages => 'Search Messages';

  @override
  String get chat_workflow => 'Workflow';

  @override
  String get chat_newSession => 'New Session';

  @override
  String get chat_sessionList => 'Session List';

  @override
  String get chat_clearSessionHistory => 'Clear Session History';

  @override
  String get chat_clearSessionSub => 'Clear current session and reset agents';

  @override
  String get chat_clearSessionSubSingle =>
      'Clear current session and reset remote agent';

  @override
  String get chat_clearAllSessions => 'Clear All Sessions';

  @override
  String get chat_clearAllSessionsSub => 'Clear all sessions and reset agents';

  @override
  String get chat_clearAllSessionsSubSingle =>
      'Clear all sessions and reset remote agent';

  @override
  String get chat_resetSession => 'Reset Session';

  @override
  String get chat_editAgent => 'Edit Agent';

  @override
  String get chat_viewDetails => 'View Details';

  @override
  String get chat_customSystemPrompt => 'Custom System Prompt';

  @override
  String get chat_systemPromptTitle => 'Custom System Prompt';

  @override
  String get chat_systemPromptHint =>
      'Override the agent\'s system prompt for this chat';

  @override
  String get chat_systemPromptSaved => 'System prompt saved';

  @override
  String get chat_moreActions => 'More Actions';

  @override
  String get chat_clearSessionTitle => 'Clear Session History';

  @override
  String get chat_clearSessionContent =>
      'This will delete all messages in the current session and reset the remote agent connection. This action cannot be undone.';

  @override
  String get chat_clearSessionGroupContent =>
      'This will delete all messages in the current session and reset all agent connections. This action cannot be undone.';

  @override
  String get chat_sessionCleared => 'Session history cleared';

  @override
  String chat_clearSessionFailed(String error) {
    return 'Failed to clear session: $error';
  }

  @override
  String get chat_clearAllSessionsTitle => 'Clear All Sessions';

  @override
  String get chat_clearAllSessionsContent =>
      'This will delete ALL sessions and their messages. Only the default session will remain. This action cannot be undone.';

  @override
  String get chat_clearAllGroupSessionsContent =>
      'This will delete ALL sessions in this group and their messages. Only the default session will remain. This action cannot be undone.';

  @override
  String get chat_allSessionsCleared => 'All session history cleared';

  @override
  String get chat_allGroupSessionsCleared => 'All group sessions cleared';

  @override
  String get chat_groupSessionCleared => 'Group session history cleared';

  @override
  String chat_clearGroupSessionFailed(String error) {
    return 'Failed to clear group session: $error';
  }

  @override
  String chat_clearAllGroupSessionsFailed(String error) {
    return 'Failed to clear all group sessions: $error';
  }

  @override
  String get chat_clearingSession => 'Clearing session...';

  @override
  String get chat_clearingAllSessions => 'Clearing all sessions...';

  @override
  String get chat_clearingGroupSession => 'Clearing group session...';

  @override
  String get chat_clearingAllGroupSessions => 'Clearing all group sessions...';

  @override
  String get chat_noAdminSet => 'No admin set';

  @override
  String get chat_groupSessions => 'Group Sessions';

  @override
  String get chat_sessions => 'Sessions';

  @override
  String chat_sessionsCount(int count) {
    return '$count sessions';
  }

  @override
  String get chat_mentionAll => 'All';

  @override
  String chat_mentionAllSub(int count) {
    return 'Mention all $count agents';
  }

  @override
  String get chat_mentionNotify => 'Notify (trigger reply)';

  @override
  String get chat_mentionCcOnly => 'CC only (no reply)';

  @override
  String get chat_add => 'Add';

  @override
  String get chat_groupDescriptionOptional => 'Description (optional)';

  @override
  String get chat_groupSystemPrompt => 'System Prompt (optional)';

  @override
  String get chat_groupSystemPromptHint =>
      'Define constraints or instructions for agents in this group';

  @override
  String chat_switchSession(String sessionId) {
    return 'Session cleared. Switching to $sessionId';
  }

  @override
  String chat_allSessionsSwitched(String sessionId) {
    return 'All sessions cleared. Switching to $sessionId';
  }

  @override
  String chat_clearAllSessionsFailed(String error) {
    return 'Failed to clear all sessions: $error';
  }

  @override
  String get chat_deleteSession => 'Delete Session';

  @override
  String get chat_deleteSessionContent =>
      'This will delete this session and all its messages. This action cannot be undone.';

  @override
  String get chat_deleteAllSessions => 'Delete All Sessions';

  @override
  String get chat_deleteAllSessionsContent =>
      'This will delete ALL sessions and their messages. Only the default session will remain. This action cannot be undone.';

  @override
  String get chat_deleteAllGroupSessionsContent =>
      'This will delete ALL sessions in this group and their messages. Only the default session will remain. This action cannot be undone.';

  @override
  String chat_newSessionFailed(String error) {
    return 'Failed to create new session: $error';
  }

  @override
  String chat_newGroupSessionFailed(String error) {
    return 'Failed to create new group session: $error';
  }

  @override
  String chat_loadSessionsFailed(String error) {
    return 'Failed to load sessions: $error';
  }

  @override
  String chat_loadGroupSessionsFailed(String error) {
    return 'Failed to load group sessions: $error';
  }

  @override
  String chat_groupRoleTitle(String name) {
    return '$name - Group Role';
  }

  @override
  String get chat_groupCapabilityLabel => 'Group Capability Description';

  @override
  String get chat_groupCapabilityHint =>
      'Leave empty to use the agent\'s default description';

  @override
  String get chat_resetButton => 'Reset';

  @override
  String get chat_stopped => 'Stopped';

  @override
  String chat_groupChatError(String error) {
    return 'Group chat error: $error';
  }

  @override
  String chat_fileMessageFailed(String error) {
    return 'File message failed: $error';
  }

  @override
  String get status_online => 'Online';

  @override
  String get status_offline => 'Offline';

  @override
  String get status_connecting => 'Connecting...';

  @override
  String get status_error => 'Error';

  @override
  String get status_protocolAcp => 'ACP';

  @override
  String get status_protocolCustom => 'Custom';

  @override
  String get widget_typing => 'Typing...';

  @override
  String get widget_stop => 'Stop';

  @override
  String widget_cannotOpenLink(String url) {
    return 'Cannot open link: $url';
  }

  @override
  String get widget_originalMessageUnavailable =>
      'Original message unavailable';

  @override
  String get widget_retry => 'Retry';

  @override
  String get widget_formSubmitted => 'Form submitted';

  @override
  String get widget_submit => 'Submit';

  @override
  String get widget_confirm => 'Confirm';

  @override
  String get widget_changeFiles => 'Change files';

  @override
  String get widget_details => 'Details';

  @override
  String get privacy_title => 'Privacy Policy';

  @override
  String get privacy_content =>
      'Privacy Policy\n\nLast updated: 2026-02-28\n\nPaw (\"we\", \"our\", or \"us\") is committed to protecting your privacy. Paw is a fully local application — we do not collect, upload, or store any of your personal data. All your data remains on your device and is entirely under your control.\n\n1. Data Storage\n\nPaw does not have any servers and does not collect any user data. All data generated during your use, including:\n- Account credentials\n- Agent configuration data\n- Chat messages and conversation history\n\nis stored exclusively on your local device. We cannot and will not access this data.\n\n2. Data Security\n\nWe protect your local data through the following measures:\n- Local data encryption\n- Secure WebSocket connections (WSS) for remote communications\n- Biometric authentication support\n- Password-protected access\n\n3. Third-Party Services\n\nWhen you actively configure and connect to remote AI agents, your messages are transmitted directly between your device and the agent endpoint you configure, without passing through any of our servers. We are not responsible for the data handling practices of third-party agent services.\n\n4. Your Rights\n\nSince all data is stored locally on your device, you can at any time:\n- View all your data\n- Permanently delete your data by clearing app data or uninstalling the app\n- Export your data using the in-app export feature\n\n5. Changes to This Policy\n\nWe may update this Privacy Policy from time to time. We will notify you of any changes by updating the \"Last updated\" date.';

  @override
  String get terms_title => 'Terms of Service';

  @override
  String get terms_content =>
      'Terms of Service\n\nLast updated: 2026-02-28\n\nPlease read these Terms of Service carefully before using the Paw application.\n\n1. Acceptance of Terms\n\nBy accessing or using Paw, you agree to be bound by these Terms. If you do not agree, do not use the application.\n\n2. Description of Service\n\nPaw is an AI agent management platform that allows you to:\n- Connect to and communicate with AI agents\n- Manage multiple agent configurations\n- Facilitate agent-to-agent collaboration\n- Transfer files and media with agents\n\n3. User Responsibilities\n\nYou agree to:\n- Use the app in compliance with all applicable laws\n- Not use the app for any illegal or unauthorized purpose\n- Not attempt to interfere with the app\'s functionality\n- Be responsible for the security of your account credentials\n- Be responsible for the content you send through the app\n\n4. Intellectual Property\n\nThe app and its original content, features, and functionality are owned by us and are protected by international copyright, trademark, and other intellectual property laws.\n\n5. Third-Party Agent Services\n\nOur app allows you to connect to third-party AI agent services. We do not control these services and are not responsible for their content, privacy policies, or practices.\n\n6. Disclaimer of Warranties\n\nThe app is provided \"as is\" without warranty of any kind. We do not guarantee that the app will be uninterrupted, secure, or error-free.\n\n7. Limitation of Liability\n\nIn no event shall we be liable for any indirect, incidental, special, consequential, or punitive damages arising from your use of the app.\n\n8. Changes to Terms\n\nWe reserve the right to modify these Terms at any time. Your continued use of the app after changes constitutes acceptance of the new Terms.';

  @override
  String get notif_enableAll => 'Enable Notifications';

  @override
  String get notif_enableAllSub => 'Receive notifications for agent messages';

  @override
  String get notif_sound => 'Sound';

  @override
  String get notif_soundSub => 'Play sound with notifications';

  @override
  String get notif_showPreview => 'Show Preview';

  @override
  String get notif_showPreviewSub => 'Show message content in notifications';

  @override
  String get notif_permissionDenied =>
      'Notification permission denied. Please enable it in system settings.';

  @override
  String get notif_newMessage => 'New message';

  @override
  String notif_newMessageFrom(String name) {
    return 'New message from $name';
  }

  @override
  String get osTool_configTitle => 'CLI Management';

  @override
  String get osTool_configHint =>
      'Enable OS-level tools for this agent to interact with your local machine (files, commands, clipboard, etc.).';

  @override
  String get osTool_selectAll => 'Select All';

  @override
  String get osTool_deselectAll => 'Deselect All';

  @override
  String get osTool_catCommand => 'Command & System';

  @override
  String get osTool_catFile => 'File Operations';

  @override
  String get osTool_catApp => 'App & Browser';

  @override
  String get osTool_catClipboard => 'Clipboard';

  @override
  String get osTool_catMacos => 'macOS Only';

  @override
  String get osTool_catProcess => 'Process Management';

  @override
  String osTool_notSupported(String platform) {
    return 'Not supported on $platform';
  }

  @override
  String get osTool_confirmTitle => 'Confirm Operation';

  @override
  String get osTool_confirmDescription =>
      'This operation will be executed on your device. Do you want to proceed?';

  @override
  String get osTool_highRisk => 'HIGH RISK';

  @override
  String get osTool_tool => 'Tool';

  @override
  String get osTool_approve => 'Approve';

  @override
  String get osTool_deny => 'Deny';

  @override
  String get skill_configTitle => 'Skills';

  @override
  String get skill_configHint =>
      'Enable markdown-based skills to guide the agent through complex multi-step tasks.';

  @override
  String get skill_selectAll => 'Select All';

  @override
  String get skill_deselectAll => 'Deselect All';

  @override
  String get skill_rescan => 'Rescan';

  @override
  String get skill_noSkillsFound =>
      'No skills found. Import a skill ZIP or add subdirectories to the skills folder.';

  @override
  String get settings_agentConfig => 'Agent Configuration';

  @override
  String get settings_skillDirectory => 'Skill Management';

  @override
  String get skillMgmt_title => 'Skill Management';

  @override
  String get skillMgmt_importZip => 'Import Skill (ZIP)';

  @override
  String get skillMgmt_importing => 'Importing skill...';

  @override
  String skillMgmt_importSuccess(String name) {
    return 'Skill \"$name\" imported successfully';
  }

  @override
  String skillMgmt_importFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get skillMgmt_deleteTitle => 'Delete Skill';

  @override
  String skillMgmt_deleteContent(String name) {
    return 'Are you sure you want to delete the skill \"$name\"? This will remove all files in the skill directory and cannot be undone.';
  }

  @override
  String skillMgmt_deleted(String name) {
    return 'Skill \"$name\" deleted';
  }

  @override
  String skillMgmt_deleteFailed(String error) {
    return 'Delete failed: $error';
  }

  @override
  String get skillMgmt_noSkills => 'No skills found';

  @override
  String get skillMgmt_noSkillsHint =>
      'Import a skill ZIP package or add skill subdirectories to the configured directory.';

  @override
  String skillMgmt_fileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String skillMgmt_skillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count skills',
      one: '1 skill',
    );
    return '$_temp0';
  }

  @override
  String get skillMgmt_conflictTitle => 'Skill Already Exists';

  @override
  String skillMgmt_conflictContent(String name) {
    return 'A skill named \"$name\" already exists. Do you want to replace it?';
  }

  @override
  String get skillMgmt_replace => 'Replace';

  @override
  String get skillMgmt_rescan => 'Rescan';

  @override
  String get skillMgmt_openDirectory => 'Open Skills Directory';

  @override
  String get skillMgmt_importUrl => 'Import from URL';

  @override
  String get skillMgmt_importUrlTitle => 'Import Skill from URL';

  @override
  String get skillMgmt_importUrlHint =>
      'Enter a direct URL to a .zip or .md file';

  @override
  String skillMgmt_downloading(int percent) {
    return 'Downloading... $percent%';
  }

  @override
  String get skillMgmt_downloadingIndeterminate => 'Downloading...';

  @override
  String get skillMgmt_invalidUrl =>
      'Invalid URL. Please enter a direct http/https link to a .zip or .md file';

  @override
  String get agentDetail_noOsToolsEnabled => 'No OS tools enabled';

  @override
  String get agentDetail_noSkillsEnabled => 'No skills enabled';

  @override
  String get settings_developerTools => 'Developer Tools';

  @override
  String get settings_inferenceLog => 'Inference Logs';

  @override
  String get settings_inferenceLogSub => 'Inspect LLM request/response details';

  @override
  String get settings_systemLog => 'System Logs';

  @override
  String get settings_systemLogSub => 'View application system logs';

  @override
  String get inferenceLog_title => 'Inference Logs';

  @override
  String get inferenceLog_empty => 'No inference logs yet';

  @override
  String get inferenceLog_emptyHint =>
      'Logs will appear here after you chat with a local LLM agent';

  @override
  String get inferenceLog_filterAll => 'All';

  @override
  String get inferenceLog_filterCompleted => 'Completed';

  @override
  String get inferenceLog_filterError => 'Error';

  @override
  String get inferenceLog_filterInProgress => 'In Progress';

  @override
  String get inferenceLog_total => 'Total';

  @override
  String get inferenceLog_completed => 'Completed';

  @override
  String get inferenceLog_errors => 'Errors';

  @override
  String get inferenceLog_inProgress => 'Active';

  @override
  String inferenceLog_rounds(int count) {
    return '$count rounds';
  }

  @override
  String inferenceLog_toolCalls(int count) {
    return '$count tool calls';
  }

  @override
  String get inferenceLog_clearTitle => 'Clear Inference Logs';

  @override
  String get inferenceLog_clearContent =>
      'Are you sure you want to clear all inference logs? This action cannot be undone.';

  @override
  String get inferenceLog_clearButton => 'Clear';

  @override
  String get inferenceLog_cleared => 'Inference logs cleared';

  @override
  String get inferenceLog_exported => 'Inference logs exported';

  @override
  String inferenceLog_exportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String get inferenceLog_loggingEnabled => 'Inference logging enabled';

  @override
  String get inferenceLog_loggingDisabled => 'Inference logging disabled';

  @override
  String get inferenceLog_userMessage => 'User Message';

  @override
  String get inferenceLog_systemPrompt => 'System Prompt';

  @override
  String inferenceLog_roundLabel(int number) {
    return 'Round $number';
  }

  @override
  String get inferenceLog_response => 'Response';

  @override
  String inferenceLog_toolCall(String name) {
    return 'Tool Call: $name';
  }

  @override
  String inferenceLog_toolResult(String name) {
    return 'Tool Result: $name';
  }

  @override
  String get inferenceLog_stopReason => 'Stop Reason';

  @override
  String get inferenceLog_error => 'Error';

  @override
  String get inferenceLog_detailTitle => 'Inference Detail';

  @override
  String get inferenceLog_timeline => 'Timeline';

  @override
  String get inferenceLog_noText => '(no text)';

  @override
  String get chat_selectSessions => 'Select Sessions';

  @override
  String chat_selectedCount(int count) {
    return '$count selected';
  }

  @override
  String get chat_invertSelection => 'Invert';

  @override
  String chat_deleteSelected(int count) {
    return 'Delete ($count)';
  }

  @override
  String chat_batchDeleteContent(int count) {
    return 'Delete $count session(s) and all their messages? This cannot be undone.';
  }

  @override
  String chat_batchDeleteSuccess(int count) {
    return 'Deleted $count sessions';
  }

  @override
  String chat_maxAttachments(int count) {
    return 'Maximum $count attachments allowed';
  }

  @override
  String get chat_connectionInterrupted =>
      'Connection lost while in background';

  @override
  String get chat_connectionInterruptedRetry => 'Retry';

  @override
  String chat_loopRoundLimitReached(int count) {
    return 'Orchestration loop reached the maximum of $count rounds and has been stopped.';
  }

  @override
  String get modelRouting_title => 'Multi-modal Model Routing';

  @override
  String get modelRouting_hint =>
      'Configure different models for different content types. Unconfigured items use the default model above.';

  @override
  String get modelRouting_text => 'Text Chat';

  @override
  String get modelRouting_image => 'Image Understanding';

  @override
  String get modelRouting_audio => 'Audio Understanding';

  @override
  String get modelRouting_video => 'Video Understanding';

  @override
  String get modelRouting_modelHint => 'Model name (inherit default if empty)';

  @override
  String get modelRouting_providerHint => 'Provider (inherit default if empty)';

  @override
  String get modelRouting_apiBaseHint => 'API Base (inherit default if empty)';

  @override
  String get modelRouting_apiKeyHint => 'API Key (inherit default if empty)';

  @override
  String get modelRouting_advanced => 'Advanced';

  @override
  String get modelRouting_selectFromRegistry => 'Select from model list';

  @override
  String get modelRouting_usingDefault => 'Using default model';

  @override
  String get modelRouting_configured => 'Configured';

  @override
  String get modelRouting_enableStreaming => 'Enable Streaming (SSE)';

  @override
  String get modelRouting_apiPath => 'API Path';

  @override
  String get modelRouting_apiPathHint =>
      'Override endpoint (e.g. /images/generations)';

  @override
  String get modelRouting_requestBodyTemplate => 'Request Body Template';

  @override
  String get modelRouting_requestBodyTemplateHint =>
      'JSON template with \$model, \$prompt variables';

  @override
  String get modelRouting_responseBodyPath => 'Response Path';

  @override
  String get modelRouting_responseBodyPathHint =>
      'JSON path to extract content (e.g. data[0].url)';

  @override
  String get modelRouting_customModalities => 'Custom Modalities';

  @override
  String get modelRouting_customModalitiesHint =>
      'Define custom task types with intent-based routing';

  @override
  String get modelRouting_addCustomModality => 'Add Custom Modality';

  @override
  String get modelRouting_modalityKey => 'Key';

  @override
  String get modelRouting_modalityKeyHint => 'e.g. image_gen, tts';

  @override
  String get modelRouting_modalityLabel => 'Display Name';

  @override
  String get modelRouting_modalityLabelHint => 'e.g. Image Generation';

  @override
  String get modelRouting_modalityDescription => 'Intent Description';

  @override
  String get modelRouting_modalityDescriptionHint =>
      'Describe when to use this modality (for classifier)';

  @override
  String get modelRouting_deleteModality => 'Delete';

  @override
  String addAgent_osToolsCount(int count) {
    return '$count tools enabled';
  }

  @override
  String get addAgent_noOsTools => 'No tools selected';

  @override
  String addAgent_skillsCount(int count) {
    return '$count skills enabled';
  }

  @override
  String get addAgent_noSkills => 'No skills selected';

  @override
  String addAgent_modelRoutingCount(int count) {
    return '$count modalities configured';
  }

  @override
  String get addAgent_noModelRouting => 'Not configured';

  @override
  String get addAgent_configureTools => 'Configure Tools';

  @override
  String get addAgent_configureSkills => 'Configure Skills';

  @override
  String get addAgent_configureModelRouting => 'Configure Model Routing';

  @override
  String get contacts_title => 'Contacts';

  @override
  String get contacts_agents => 'Agents';

  @override
  String get contacts_groups => 'Groups';

  @override
  String get contacts_devices => 'Devices';

  @override
  String get contacts_noPeers => 'No paired devices yet';

  @override
  String get contacts_startPairing => 'Start Pairing';

  @override
  String get contacts_addPairingDevice => 'Add Paired Device';

  @override
  String get contacts_noAgents => 'No agents yet';

  @override
  String get contacts_noGroups => 'No groups yet';

  @override
  String contacts_agentCount(int count) {
    return '$count agents';
  }

  @override
  String contacts_groupCount(int count) {
    return '$count groups';
  }

  @override
  String contacts_memberCount(int count) {
    return '$count members';
  }

  @override
  String get groupDetail_title => 'Group Details';

  @override
  String get groupDetail_editTitle => 'Edit Group';

  @override
  String get groupDetail_editGroup => 'Edit';

  @override
  String get groupDetail_members => 'Members';

  @override
  String get groupDetail_admin => 'Admin';

  @override
  String get groupDetail_member => 'Member';

  @override
  String get groupDetail_systemPrompt => 'System Prompt';

  @override
  String get groupDetail_maxLoopRounds => 'Max Orchestration Rounds';

  @override
  String get groupDetail_startChat => 'Start Chat';

  @override
  String get groupDetail_deleteGroup => 'Delete Group';

  @override
  String get groupDetail_confirmDelete => 'Delete Group?';

  @override
  String groupDetail_deleteContent(String name) {
    return 'Are you sure you want to delete the group \"$name\"? This will delete all messages.';
  }

  @override
  String groupDetail_deleted(String name) {
    return 'Group \"$name\" deleted';
  }

  @override
  String groupDetail_deleteFailed(String error) {
    return 'Failed to delete group: $error';
  }

  @override
  String get drawer_contacts => 'Contacts';

  @override
  String get toolModel_managementTitle => 'Model Management';

  @override
  String get toolModel_configTitle => 'Models';

  @override
  String get toolModel_configHint =>
      'Select models for this agent. Tool models are exposed to the main LLM via tool calls; other models can be used for multi-modal routing.';

  @override
  String get toolModel_configureTitle => 'Select Models';

  @override
  String get toolModel_addTitle => 'Add Model';

  @override
  String get toolModel_editTitle => 'Edit Model';

  @override
  String get toolModel_displayName => 'Display Name';

  @override
  String get toolModel_displayNameHint => 'e.g., Image Generation, GPT-4o';

  @override
  String get toolModel_displayNameRequired => 'Display name is required';

  @override
  String get toolModel_description => 'Description';

  @override
  String get toolModel_descriptionHint =>
      'When used as a tool model, this helps the LLM decide when to call it (optional)';

  @override
  String get toolModel_descriptionRequired => 'Description is required';

  @override
  String get toolModel_model => 'Model';

  @override
  String get toolModel_modelHint => 'e.g., dall-e-3, gpt-4o';

  @override
  String get toolModel_modelRequired => 'Model name is required';

  @override
  String get toolModel_apiBase => 'API Base';

  @override
  String get toolModel_apiBaseHint => 'e.g., https://api.openai.com/v1';

  @override
  String get toolModel_apiBaseRequired => 'API Base URL is required';

  @override
  String get toolModel_apiKey => 'API Key';

  @override
  String get toolModel_apiKeyHint => 'Enter API Key (optional)';

  @override
  String get toolModel_provider => 'Provider';

  @override
  String get toolModel_providerHint => 'e.g., openai';

  @override
  String get toolModel_selectProvider => 'Select provider (auto-fill API base)';

  @override
  String get toolModel_customProvider => 'Custom';

  @override
  String get toolModel_noModels => 'No models';

  @override
  String get toolModel_noModelsHint =>
      'Tap + to add a model configuration that can be reused across agents.';

  @override
  String get toolModel_noModelsAvailable =>
      'No models configured. Add them in Settings > Model Management.';

  @override
  String toolModel_count(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count models',
      one: '1 model',
    );
    return '$_temp0';
  }

  @override
  String get toolModel_deleteTitle => 'Delete Model';

  @override
  String toolModel_deleteContent(String name) {
    return 'Are you sure you want to delete the model \"$name\"?';
  }

  @override
  String toolModel_deleted(String name) {
    return 'Model \"$name\" deleted';
  }

  @override
  String get toolModel_selectAll => 'Select All';

  @override
  String get toolModel_deselectAll => 'Deselect All';

  @override
  String get toolModel_scenarioLabel => 'Usage scenario';

  @override
  String get toolModel_scenarioHint =>
      'Describe when the agent should call this model (overrides global description)';

  @override
  String get toolModel_scenarioPlaceholder =>
      'e.g., Use for image generation tasks';

  @override
  String get addAgent_noToolModels => 'No models selected';

  @override
  String addAgent_toolModelsCount(int count) {
    return '$count models enabled';
  }

  @override
  String get agentDetail_noToolModelsEnabled => 'No models enabled';

  @override
  String get chat_mentionMode => 'Mention Mode';

  @override
  String get chat_mentionModeAdminOnly => 'Admin Only';

  @override
  String get chat_mentionModeAllMembers => 'All Members';

  @override
  String get chat_mentionModeAdminOnlyDesc =>
      'Only admin can @mention and activate other members';

  @override
  String get chat_mentionModeAllMembersDesc =>
      'Any member can @mention and activate other members';

  @override
  String get createGroup_mentionMode => 'Mention Mode';

  @override
  String get chat_planningMode => 'Planning Mode';

  @override
  String get chat_planningModeDesc =>
      'Admin generates a plan first, execution begins after user approval';

  @override
  String get chat_flowMode => 'Flow Mode';

  @override
  String get chat_flowModeDesc =>
      'Admin generates a staged FlowPlan; executor drives stages serially, steps in parallel';

  @override
  String get chat_viewTrace => 'View Trace';

  @override
  String get modelType_sectionLabel => 'Model Types';

  @override
  String get modelType_sectionHint =>
      'Select the capability types this model supports (multi-select)';

  @override
  String get modelType_text => 'Text';

  @override
  String get modelType_imageUnderstanding => 'Image Understanding';

  @override
  String get modelType_audioUnderstanding => 'Audio Understanding';

  @override
  String get modelType_videoUnderstanding => 'Video Understanding';

  @override
  String get modelType_imageGeneration => 'Image Generation';

  @override
  String get modelType_tts => 'Text-to-Speech';

  @override
  String get modelType_videoGeneration => 'Video Generation';

  @override
  String get common_required => 'Required';

  @override
  String get addAgent_modelRequired => 'Please select a model';

  @override
  String get addAgent_noModels =>
      'No models configured. Please add models in Settings first.';

  @override
  String get toolModel_goToManagement => 'Go to Model Management';

  @override
  String get settings_disableServiceTitle => 'Disable Local Service';

  @override
  String get settings_disableServiceContent =>
      'After disabling, all agents configured with \"Allow External Access\" will no longer accept external connections, and any connected clients will be disconnected immediately.\n\nConfirm?';

  @override
  String get settings_disableServiceConfirm => 'Confirm Disable';

  @override
  String get settings_localService => 'Local Service';

  @override
  String get settings_localServiceDesc =>
      'Allow LAN or internet devices to connect as a Remote Agent';

  @override
  String get settings_lanAddress => 'LAN Address';

  @override
  String get settings_lanAddressSub =>
      'Devices on the same network can connect via these addresses';

  @override
  String get settings_channelTunnel => 'Channel Tunnel (Remote Access)';

  @override
  String get settings_tunnelNotConfigured => 'Not configured';

  @override
  String get settings_tunnelConnected => 'Connected';

  @override
  String get settings_tunnelConnecting => 'Connecting';

  @override
  String get settings_tunnelDisconnected => 'Disconnected';

  @override
  String get settings_tunnelError => 'Connection error';

  @override
  String get settings_configureTunnel => 'Configure Tunnel';

  @override
  String get settings_copyLanAddress => 'Copy LAN Address';

  @override
  String get settings_copyPublicAddress => 'Copy Public Address';

  @override
  String get settings_acpServerRunning => 'ACP Server running';

  @override
  String get settings_acpServerStopped => 'ACP Server not running';

  @override
  String get settings_tunnelServerUrl => 'Channel Server URL';

  @override
  String get settings_tunnelChannelId => 'Channel ID';

  @override
  String get settings_tunnelSecret => 'Secret';

  @override
  String get settings_tunnelAutoConnect => 'Auto Connect';

  @override
  String get settings_tunnelPublicAddress => 'Public Address';

  @override
  String get settings_tunnelConfigRequiredFields =>
      'Please fill in all required fields';

  @override
  String get settings_deleteTunnelConfig => 'Delete Configuration';

  @override
  String get settings_noLanAddress => 'No LAN address found';

  @override
  String get settings_acpPort => 'Port';

  @override
  String get settings_acpPortSuffix => '(1024-65535)';

  @override
  String get settings_acpChangePort => 'Change Port';

  @override
  String get settings_acpPortHint =>
      'App restart is required after changing the port. Other devices need to reconnect using the new address.';

  @override
  String get settings_acpPortInvalid =>
      'Invalid port number. Please enter a value between 1024 and 65535.';

  @override
  String get settings_acpPortRestarting => 'Restarting ACP Server...';

  @override
  String get settings_acpPortRestartRequired =>
      'Port saved. Restart the app to apply.';

  @override
  String get settings_acpToken => 'Connection Token';

  @override
  String get settings_acpTokenCopy => 'Copy Token';

  @override
  String get settings_acpTokenRefresh => 'Refresh Token';

  @override
  String get settings_acpTokenRefreshed =>
      'Token refreshed. Existing connections must reconnect.';

  @override
  String get agent_enableExternalAccessTitle => 'Enable External Access';

  @override
  String get agent_enableExternalAccessNeedService =>
      'The local service master switch is currently off, so external access cannot work.\n\nWould you like to enable the local service now?';

  @override
  String get agent_enableServiceAndContinue => 'Enable Local Service';

  @override
  String get agent_keepDisabled => 'Save Settings Only';

  @override
  String get agent_allowExternalAccess => 'Allow External Access';

  @override
  String get agent_allowExternalAccessDesc =>
      'When enabled, paired devices can see and chat with this agent in their conversation list';

  @override
  String get agent_externalAccessPeerEnabled =>
      'Enabled: paired devices can see and chat with this agent in their conversation list';

  @override
  String get agent_externalAccessUrl => 'Access URL';

  @override
  String get agent_externalAccessUrlLan => 'LAN Access URL';

  @override
  String get agent_externalAccessUrlPublic => 'Public Access URL';

  @override
  String get agent_externalAccessDisabled => 'External access is disabled';

  @override
  String get agent_externalAccessNeedsService =>
      'Enable local service in Settings first';

  @override
  String get agent_copyAccessUrl => 'Copy Access URL';

  @override
  String get agent_accessUrlCopied => 'Access URL copied';

  @override
  String get agent_accessUrlCopiedHint =>
      'Paste it as the Endpoint URL to connect';

  @override
  String get agent_regenerateToken => 'Regenerate Token';

  @override
  String get agent_regenerateTokenConfirmTitle => 'Regenerate Token?';

  @override
  String get agent_regenerateTokenConfirmBody =>
      'The old token will be invalidated immediately. Connected clients will need to reconnect with the new token. Continue?';

  @override
  String get agent_tokenRegenerated => 'Token updated';

  @override
  String agent_tokenRegenerateFailed(String error) {
    return 'Failed to regenerate: $error';
  }

  @override
  String get agent_channelConfig => 'Public Channel Config';

  @override
  String get agent_channelServerUrl => 'Server URL';

  @override
  String get agent_channelId => 'Channel ID';

  @override
  String get agent_channelSecret => 'Channel Secret';

  @override
  String get agent_channelEndpoint => 'Channel Endpoint (optional)';

  @override
  String get agent_channelNotConfigured => 'Public channel not configured';

  @override
  String get agent_channelConfigure => 'Configure';

  @override
  String get she_pinned_label => 'Pinned';

  @override
  String get she_name => 'She';

  @override
  String get she_bio => 'Your master\'s devoted spirit companion';

  @override
  String get settings_userProfile => 'Personal Profile';

  @override
  String get settings_userProfileSub => 'Manage your personal information';

  @override
  String get settings_agentMemories => 'Agent Memories';

  @override
  String get settings_agentMemoriesSub =>
      'View and manage memories for each agent';

  @override
  String get memory_title => 'Memories';

  @override
  String get memory_add => 'Add Note';

  @override
  String get memory_structured => 'Structured';

  @override
  String get memory_timeline => 'Timeline';

  @override
  String get memory_export => 'Export';

  @override
  String get memory_json => 'JSON';

  @override
  String get memory_markdown => 'Markdown';

  @override
  String get memory_clearAll => 'Clear All';

  @override
  String get memory_delete => 'Delete';

  @override
  String get memory_noMemories => 'No Memories Yet';

  @override
  String get memory_addNoteHint => 'Add notes to store memories';

  @override
  String get memory_view => 'View';

  @override
  String get memory_noAgents => 'No Agents Available';

  @override
  String get memory_addAgents => 'Add agents to manage their memories';

  @override
  String get memory_created => 'Created';

  @override
  String get memory_updated => 'Updated';

  @override
  String get profile_personalTitle => 'Personal Profile';

  @override
  String get profile_coreInfo => 'Core Information';

  @override
  String get profile_extendedInfo => 'Additional Information';

  @override
  String get profile_customAttrs => 'Custom Attributes';

  @override
  String get profile_add => 'Add';

  @override
  String get profile_reset => 'Reset All';

  @override
  String get profile_nameField => 'Name';

  @override
  String get profile_ageField => 'Age';

  @override
  String get profile_genderField => 'Gender';

  @override
  String get profile_occupationField => 'Occupation';

  @override
  String get profile_cityField => 'City';

  @override
  String get profile_interestsField => 'Interests';

  @override
  String get profile_interestsHint => 'Comma separated';

  @override
  String get profile_valuesField => 'Values';

  @override
  String get profile_valuesHint => 'What matters most to you';

  @override
  String get profile_goalsField => 'Goals & Needs';

  @override
  String get profile_goalsHint => 'Your aspirations';

  @override
  String get profile_communicationStyleField => 'Communication Style';

  @override
  String get profile_communicationStyleHint => 'How you prefer to communicate';

  @override
  String get profile_workStyleField => 'Work Style';

  @override
  String get profile_workStyleHint => 'Your work preferences';

  @override
  String get profile_lifeStageField => 'Life Stage';

  @override
  String get profile_lifeStageHint =>
      'e.g., student, working professional, retired';

  @override
  String get profile_importantPeopleField => 'Important People';

  @override
  String get profile_importantPeopleHint => 'Family, friends, mentors';

  @override
  String get profile_healthField => 'Health';

  @override
  String get profile_healthHint => 'Health conditions, allergies';

  @override
  String get profile_languageField => 'Language Preference';

  @override
  String get profile_languageHint => 'e.g., English, Chinese, Spanish';

  @override
  String get profile_timezoneField => 'Timezone';

  @override
  String get profile_timezoneHint => 'e.g., EST, PST, UTC+8';

  @override
  String get profile_notesField => 'Other Notes';

  @override
  String get profile_notesHint => 'Any additional information';

  @override
  String get profile_addCustomTitle => 'Add Custom Attribute';

  @override
  String get profile_attributeName => 'Attribute Name';

  @override
  String get profile_attributeNameHint => 'e.g., pet_name, favorite_food';

  @override
  String get profile_attributeValue => 'Value';

  @override
  String get profile_attributeValueHint => 'Enter the value';

  @override
  String get profile_removeAttrTitle => 'Remove Attribute';

  @override
  String profile_removeAttrContent(String name) {
    return 'Remove \"$name\"?';
  }

  @override
  String get profile_customLabel => 'Custom';

  @override
  String get profile_noCustomAttrs =>
      'No custom attributes yet. Tap \"Add\" to create one.';

  @override
  String get profile_resetTitle => 'Reset Profile';

  @override
  String get profile_resetContent =>
      'This will clear all personal information. This cannot be undone.';

  @override
  String get profile_saved => 'Profile saved';

  @override
  String profile_saveFailed(String error) {
    return 'Error: $error';
  }

  @override
  String get profile_loadFailed => 'Failed to load profile';

  @override
  String get profile_resetSuccess => 'Profile reset';

  @override
  String get profile_resetFailed => 'Failed to reset profile';

  @override
  String get profile_nameEmpty => 'Name cannot be empty';

  @override
  String profile_nameReserved(String name) {
    return '\"$name\" is a reserved field name';
  }

  @override
  String profile_nameDuplicate(String name) {
    return '\"$name\" already exists';
  }

  @override
  String get profile_nameStartWithUnderscore =>
      'Name cannot start with underscore';

  @override
  String get profile_nameInvalidChars =>
      'Only letters, numbers and underscore allowed';

  @override
  String get profile_nameTooLong => 'Name too long (max 50 chars)';

  @override
  String get profile_loadingProfile => 'Loading profile...';

  @override
  String get scheduledTasks_title => 'Scheduled Tasks';

  @override
  String get scheduledTasks_description =>
      'Manage automated tasks that run on a schedule';

  @override
  String get scheduledTasks_noTasks => 'No scheduled tasks yet';

  @override
  String get scheduledTasks_noTasksHint => 'Create a new task to get started';

  @override
  String get scheduledTasks_createTask => 'Create Task';

  @override
  String get scheduledTasks_editTask => 'Edit Task';

  @override
  String get scheduledTasks_deleteTask => 'Delete Task';

  @override
  String get scheduledTasks_activateTask => 'Activate';

  @override
  String get scheduledTasks_pauseTask => 'Pause';

  @override
  String get scheduledTasks_executeNow => 'Execute Now';

  @override
  String get scheduledTasks_form_title => 'Task Details';

  @override
  String get scheduledTasks_form_description => 'Description';

  @override
  String get scheduledTasks_form_descriptionHint => 'What does this task do?';

  @override
  String get scheduledTasks_form_instruction => 'Instruction';

  @override
  String get scheduledTasks_form_instructionHint =>
      'Enter the task instruction or prompt';

  @override
  String get scheduledTasks_form_selectAgent => 'Select Agent';

  @override
  String get scheduledTasks_form_scheduleType => 'Schedule Type';

  @override
  String get scheduledTasks_form_schedulePattern => 'Schedule Pattern';

  @override
  String get scheduledTasks_form_schedulePatternHint =>
      'Cron: 0 9 * * * or Duration: PT5M';

  @override
  String get scheduledTasks_form_optional => 'Optional';

  @override
  String get scheduledTasks_form_selectChannel => 'Select Channel (Optional)';

  @override
  String get scheduledTasks_scheduleType_cron => 'Cron Expression';

  @override
  String get scheduledTasks_scheduleType_interval => 'Interval Duration';

  @override
  String get scheduledTasks_scheduleType_once => 'One-Time';

  @override
  String get scheduledTasks_cronExamples => 'Cron Examples';

  @override
  String get scheduledTasks_cronExample_daily => 'Daily at 9:00 AM: 0 9 * * *';

  @override
  String get scheduledTasks_cronExample_hourly => 'Every hour: 0 * * * *';

  @override
  String get scheduledTasks_cronExample_weekdays =>
      'Weekdays at 9:00 AM: 0 9 * * 1-5';

  @override
  String get scheduledTasks_cronExample_everyMinute =>
      'Every minute: * * * * *';

  @override
  String get scheduledTasks_intervalExamples => 'Duration Examples';

  @override
  String get scheduledTasks_intervalExample_5min => 'Every 5 minutes: PT5M';

  @override
  String get scheduledTasks_intervalExample_1hour => 'Every 1 hour: PT1H';

  @override
  String get scheduledTasks_intervalExample_30min => 'Every 30 minutes: PT30M';

  @override
  String get scheduledTasks_status_pending => 'Pending';

  @override
  String get scheduledTasks_status_active => 'Active';

  @override
  String get scheduledTasks_status_paused => 'Paused';

  @override
  String get scheduledTasks_status_completed => 'Completed';

  @override
  String get scheduledTasks_status_failed => 'Failed';

  @override
  String scheduledTasks_nextRun(String time) {
    return 'Next Run: $time';
  }

  @override
  String scheduledTasks_lastRun(String time) {
    return 'Last Run: $time';
  }

  @override
  String scheduledTasks_executionCount(String count) {
    return 'Executions: $count';
  }

  @override
  String scheduledTasks_failureCount(String count) {
    return 'Failures: $count';
  }

  @override
  String get scheduledTasks_noLastError => 'No errors';

  @override
  String scheduledTasks_lastError(String error) {
    return 'Last Error: $error';
  }

  @override
  String get scheduledTasks_confirmDelete => 'Delete Task?';

  @override
  String get scheduledTasks_confirmDeleteMsg =>
      'Are you sure you want to delete this scheduled task? This action cannot be undone.';

  @override
  String get scheduledTasks_confirmPause => 'Pause Task?';

  @override
  String get scheduledTasks_confirmPauseMsg =>
      'The task will stop executing. You can resume it later.';

  @override
  String get scheduledTasks_invalidSchedule => 'Invalid schedule pattern';

  @override
  String get scheduledTasks_invalidScheduleMsg =>
      'Please check your cron expression or duration format';

  @override
  String get scheduledTasks_missingInstruction => 'Instruction is required';

  @override
  String get scheduledTasks_missingAgent => 'Please select an agent';

  @override
  String get scheduledTasks_createSuccess => 'Task created successfully';

  @override
  String get scheduledTasks_updateSuccess => 'Task updated successfully';

  @override
  String get scheduledTasks_deleteSuccess => 'Task deleted successfully';

  @override
  String get scheduledTasks_activateSuccess => 'Task activated';

  @override
  String get scheduledTasks_pauseSuccess => 'Task paused';

  @override
  String get scheduledTasks_executeNowSuccess => 'Task execution started';

  @override
  String get scheduledTasks_filterByAgent => 'FILTER BY AGENT';

  @override
  String get scheduledTasks_filterAll => 'All';

  @override
  String scheduledTasks_createError(String error) {
    return 'Failed to create task: $error';
  }

  @override
  String scheduledTasks_updateError(String error) {
    return 'Failed to update task: $error';
  }

  @override
  String scheduledTasks_deleteError(String error) {
    return 'Failed to delete task: $error';
  }

  @override
  String scheduledTasks_activateError(String error) {
    return 'Failed to activate task: $error';
  }

  @override
  String get scheduledTasks_targetAgent => 'Agent Task';

  @override
  String get scheduledTasks_targetGroup => 'Group Task';

  @override
  String get scheduledTasks_form_optionalChannel =>
      'Override channel (optional)';

  @override
  String get scheduledTasks_form_selectGroupChannel => 'Select group channel';

  @override
  String get scheduledTasks_form_selectGroup => 'Select group';

  @override
  String get scheduledTasks_form_selectGroupAgents => 'Agents in group';

  @override
  String get scheduledTasks_form_selectMentions =>
      'Agents to mention (optional)';

  @override
  String get scheduledTasks_missingChannel => 'Please select a channel';

  @override
  String get scheduledTasks_missingGroupAgents =>
      'Please select at least one agent';

  @override
  String get scheduledTasks_form_scheduleTypeLabel => 'Schedule Type';

  @override
  String get scheduledTasks_form_scheduleType_interval => 'Repeat Interval';

  @override
  String get scheduledTasks_form_scheduleType_cron => 'Cron Schedule';

  @override
  String get scheduledTasks_form_scheduleType_once => 'One-Time';

  @override
  String get scheduledTasks_form_interval_value => 'Interval Value';

  @override
  String get scheduledTasks_form_interval_unit_minutes => 'minutes';

  @override
  String get scheduledTasks_form_interval_unit_hours => 'hours';

  @override
  String get scheduledTasks_form_interval_unit_days => 'days';

  @override
  String scheduledTasks_form_interval_preview(String value, String unit) {
    return 'Runs every $value $unit';
  }

  @override
  String get scheduledTasks_form_preset_label => 'Quick Presets';

  @override
  String get scheduledTasks_form_preset_5min => '5 min';

  @override
  String get scheduledTasks_form_preset_30min => '30 min';

  @override
  String get scheduledTasks_form_preset_1h => '1 hour';

  @override
  String get scheduledTasks_form_preset_6h => '6 hours';

  @override
  String get scheduledTasks_form_preset_1d => 'Daily';

  @override
  String get scheduledTasks_form_cron_frequency => 'Frequency';

  @override
  String get scheduledTasks_form_cron_freq_daily => 'Daily';

  @override
  String get scheduledTasks_form_cron_freq_weekly => 'Weekly';

  @override
  String get scheduledTasks_form_cron_freq_monthly => 'Monthly';

  @override
  String get scheduledTasks_form_cron_freq_custom => 'Custom';

  @override
  String get scheduledTasks_form_cron_time => 'Time';

  @override
  String get scheduledTasks_form_cron_weekdays => 'Day(s) of Week';

  @override
  String get scheduledTasks_form_cron_monthdays => 'Day(s) of Month';

  @override
  String get scheduledTasks_form_cron_advanced => 'View Cron Expression';

  @override
  String get scheduledTasks_form_cron_preview => 'Upcoming runs';

  @override
  String get scheduledTasks_form_cron_custom_hint =>
      'min hour day month weekday (e.g. 0 9 * * 1-5)';

  @override
  String get scheduledTasks_form_cron_weekday_mon => 'Mon';

  @override
  String get scheduledTasks_form_cron_weekday_tue => 'Tue';

  @override
  String get scheduledTasks_form_cron_weekday_wed => 'Wed';

  @override
  String get scheduledTasks_form_cron_weekday_thu => 'Thu';

  @override
  String get scheduledTasks_form_cron_weekday_fri => 'Fri';

  @override
  String get scheduledTasks_form_cron_weekday_sat => 'Sat';

  @override
  String get scheduledTasks_form_cron_weekday_sun => 'Sun';

  @override
  String get scheduledTasks_form_once_datetime => 'Run At';

  @override
  String get scheduledTasks_form_once_pickDate => 'Pick Date';

  @override
  String get scheduledTasks_form_once_pickTime => 'Pick Time';

  @override
  String get scheduledTasks_form_saveAndActivate => 'Save & Activate';

  @override
  String get scheduledTasks_form_scheduleSection => 'Schedule';

  @override
  String get scheduledTasks_form_targetSection => 'Execution Target';

  @override
  String get scheduledTasks_form_contentSection => 'Task Content';

  @override
  String get scheduledTasks_form_invalidInterval =>
      'Please enter a valid interval (minimum 1)';

  @override
  String get scheduledTasks_form_invalidCron =>
      'Please complete the cron configuration';

  @override
  String get scheduledTasks_form_invalidOnce =>
      'Please select a future run time';

  @override
  String get scheduledTasks_form_oncePastError =>
      'Run time must be in the future';

  @override
  String get scheduledTasks_form_agentConversation => 'Conversation';

  @override
  String get scheduledTasks_form_agentConversationHint =>
      'Select a conversation for this agent (defaults to the active session)';

  @override
  String get scheduledTasks_form_agentNoConversation =>
      'No conversations found for this agent';

  @override
  String get peerPairing_title => 'Pair Device';

  @override
  String get peerPairing_tabMyQr => 'My QR Code';

  @override
  String get peerPairing_tabScan => 'Scan';

  @override
  String get peerPairing_tabManual => 'Enter';

  @override
  String get peerPairing_copyLink => 'Copy pairing link';

  @override
  String get peerPairing_linkCopied => 'Pairing link copied';

  @override
  String get peerManual_title => 'Manual pairing';

  @override
  String get peerManual_desc =>
      'Copy the pairing link from the other device\'s \"My QR Code\" page and paste it below to start pairing.';

  @override
  String get peerManual_inputHint =>
      'shepaw://peer?local=...&code=...#fp=...&pk=...';

  @override
  String get peerManual_paste => 'Paste';

  @override
  String get peerManual_submit => 'Start pairing';

  @override
  String get peerManual_emptyError =>
      'Please paste the other device\'s pairing content';

  @override
  String get peerManual_invalidError =>
      'Invalid content. Please paste the full pairing link (shepaw://peer?...)';

  @override
  String get peerManual_connecting => 'Connecting...';

  @override
  String get peerManual_waitingConfirm => 'Waiting for confirmation...';

  @override
  String get peerManual_success => 'Paired successfully!';

  @override
  String get peerManual_rejected =>
      'The other device rejected the pairing request';

  @override
  String get peerManual_timeout => 'Pairing timed out, please retry';

  @override
  String peerManual_failed(String error) {
    return 'Pairing failed: $error';
  }

  @override
  String get peerRole_initiatorShort => 'Initiated by me';

  @override
  String get peerRole_responderShort => 'Initiated by peer';

  @override
  String get peerRole_initiatorDesc => 'Paired by scanning on this device';

  @override
  String get peerRole_responderDesc => 'Paired when peer scanned';

  @override
  String get peerChat_emptyMessages =>
      'No messages yet\nSend the first message to start chatting';

  @override
  String get peerChat_hintOnline => 'Type a message...';

  @override
  String get peerChat_hintOffline =>
      'Offline · Messages will send when connected';

  @override
  String get peerChat_statusOnlinePrefix => 'Online · ';

  @override
  String get peerChat_e2eEncryption => 'End-to-end encrypted';

  @override
  String get peerChat_statusOnline => 'Online · End-to-end encrypted';

  @override
  String get peerChat_statusConnecting => 'Connecting...';

  @override
  String get peerChat_statusOffline => 'Offline';

  @override
  String get peerChat_agentList => 'Shared Agents';

  @override
  String peerChat_yesterday(String time) {
    return 'Yesterday $time';
  }

  @override
  String get peerSettings_title => 'Device Settings';

  @override
  String get peerSettings_online => 'Online';

  @override
  String get peerSettings_offline => 'Offline';

  @override
  String get peerSettings_sectionBasic => 'Basic Info';

  @override
  String get peerSettings_aliasName => 'Display Name';

  @override
  String get peerSettings_fingerprint => 'Device Fingerprint';

  @override
  String get peerSettings_pairedAt => 'Paired At';

  @override
  String get peerSettings_connectionInitiator => 'Connection Initiator';

  @override
  String get peerSettings_sectionConnection => 'Connection Info';

  @override
  String get peerSettings_localAddress => 'Local Address';

  @override
  String get peerSettings_relayAddress => 'Relay Endpoint';

  @override
  String get peerSettings_encryption => 'Encryption';

  @override
  String get peerSettings_encryptionValue =>
      'Noise IK (X25519 + ChaCha20-Poly1305)';

  @override
  String get peerSettings_startChat => 'Start Chat';

  @override
  String get peerSettings_deletePairing => 'Remove Pairing';

  @override
  String get peerSettings_editAliasTitle => 'Edit Display Name';

  @override
  String get peerSettings_editAliasHint => 'Enter display name';

  @override
  String peerSettings_deleteConfirm(String name) {
    return 'Are you sure you want to remove pairing with $name?\nAll message history will also be deleted.';
  }

  @override
  String get peerSettings_noShareableAgents => 'No agents available to share';

  @override
  String get peerSettings_enableExternalAccessHint =>
      'Enable \"Allow External Access\" in agent settings to share agents with this device';

  @override
  String get peerSettings_shareAgentsTitle => 'Agents Shared with This Device';

  @override
  String peerSettings_shareAgentsTitleCount(int shared, int total) {
    return 'Agents Shared with This Device ($shared/$total)';
  }

  @override
  String get peerSettings_noPeerAgentsConnected =>
      'This device has not shared any agents';

  @override
  String get peerSettings_noPeerAgentsOffline =>
      'Device offline, no agents available';

  @override
  String get peerSettings_peerEnableExternalHint =>
      'The peer can enable \"Allow External Access\" in agent settings';

  @override
  String get peerSettings_syncAgentsOnConnect =>
      'Available agents will sync automatically when connected';

  @override
  String get peerSettings_connectableAgentsTitle => 'Connectable Agents';

  @override
  String peerSettings_connectableAgentsTitleCount(int count) {
    return 'Connectable Agents ($count)';
  }

  @override
  String get peerList_connected => 'Connected';

  @override
  String get peerList_connectedE2e => 'Connected (End-to-end encrypted)';

  @override
  String get peerList_disconnected => 'Not connected';
}
