import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @appTitle.
  ///
  /// In zh, this message translates to:
  /// **'ShePaw'**
  String get appTitle;

  /// No description provided for @appVersion.
  ///
  /// In zh, this message translates to:
  /// **'ShePaw v1.0.0'**
  String get appVersion;

  /// No description provided for @appDescription.
  ///
  /// In zh, this message translates to:
  /// **'安全 AI Agent 管理平台'**
  String get appDescription;

  /// No description provided for @common_cancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get common_cancel;

  /// No description provided for @common_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get common_confirm;

  /// No description provided for @common_save.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get common_save;

  /// No description provided for @common_delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get common_delete;

  /// No description provided for @common_edit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get common_edit;

  /// No description provided for @common_close.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get common_close;

  /// No description provided for @common_loading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载...'**
  String get common_loading;

  /// No description provided for @common_retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get common_retry;

  /// No description provided for @common_ok.
  ///
  /// In zh, this message translates to:
  /// **'知道了'**
  String get common_ok;

  /// No description provided for @common_copy.
  ///
  /// In zh, this message translates to:
  /// **'复制'**
  String get common_copy;

  /// No description provided for @common_reply.
  ///
  /// In zh, this message translates to:
  /// **'回复'**
  String get common_reply;

  /// No description provided for @common_search.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get common_search;

  /// No description provided for @common_refresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get common_refresh;

  /// No description provided for @common_clear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get common_clear;

  /// No description provided for @common_optional.
  ///
  /// In zh, this message translates to:
  /// **'可选'**
  String get common_optional;

  /// No description provided for @common_featureComingSoon.
  ///
  /// In zh, this message translates to:
  /// **'功能即将推出'**
  String get common_featureComingSoon;

  /// No description provided for @common_operationFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败: {error}'**
  String common_operationFailed(String error);

  /// No description provided for @common_error.
  ///
  /// In zh, this message translates to:
  /// **'错误: {error}'**
  String common_error(String error);

  /// No description provided for @splash_loading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载...'**
  String get splash_loading;

  /// No description provided for @login_title.
  ///
  /// In zh, this message translates to:
  /// **'ShePaw'**
  String get login_title;

  /// No description provided for @login_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码解锁'**
  String get login_subtitle;

  /// No description provided for @login_password.
  ///
  /// In zh, this message translates to:
  /// **'密码'**
  String get login_password;

  /// No description provided for @login_passwordHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入您的密码'**
  String get login_passwordHint;

  /// No description provided for @login_button.
  ///
  /// In zh, this message translates to:
  /// **'登录'**
  String get login_button;

  /// No description provided for @login_forgotPassword.
  ///
  /// In zh, this message translates to:
  /// **'忘记密码？'**
  String get login_forgotPassword;

  /// No description provided for @login_emptyPassword.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get login_emptyPassword;

  /// No description provided for @login_tooManyAttempts.
  ///
  /// In zh, this message translates to:
  /// **'密码错误次数过多，请稍后再试'**
  String get login_tooManyAttempts;

  /// No description provided for @login_wrongPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码错误，请重试 ({attempts}/3)'**
  String login_wrongPassword(int attempts);

  /// No description provided for @login_failed.
  ///
  /// In zh, this message translates to:
  /// **'登录失败: {error}'**
  String login_failed(String error);

  /// No description provided for @login_resetPasswordTitle.
  ///
  /// In zh, this message translates to:
  /// **'重置密码'**
  String get login_resetPasswordTitle;

  /// No description provided for @login_resetPasswordContent.
  ///
  /// In zh, this message translates to:
  /// **'重置密码后将进入全新的数据空间。'**
  String get login_resetPasswordContent;

  /// No description provided for @login_resetPasswordVaultHint.
  ///
  /// In zh, this message translates to:
  /// **'旧数据会被安全加密保存，您可以随时通过 设置 → 历史数据保险库 用旧密码恢复。'**
  String get login_resetPasswordVaultHint;

  /// No description provided for @login_confirmReset.
  ///
  /// In zh, this message translates to:
  /// **'确认重置'**
  String get login_confirmReset;

  /// No description provided for @passwordSetup_title.
  ///
  /// In zh, this message translates to:
  /// **'设置登录密码'**
  String get passwordSetup_title;

  /// No description provided for @passwordSetup_subtitle.
  ///
  /// In zh, this message translates to:
  /// **'请设置一个安全的密码来保护您的账户'**
  String get passwordSetup_subtitle;

  /// No description provided for @passwordSetup_password.
  ///
  /// In zh, this message translates to:
  /// **'设置密码'**
  String get passwordSetup_password;

  /// No description provided for @passwordSetup_passwordHint.
  ///
  /// In zh, this message translates to:
  /// **'至少6位，包含字母和数字'**
  String get passwordSetup_passwordHint;

  /// No description provided for @passwordSetup_confirmPassword.
  ///
  /// In zh, this message translates to:
  /// **'确认密码'**
  String get passwordSetup_confirmPassword;

  /// No description provided for @passwordSetup_confirmPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请再次输入密码'**
  String get passwordSetup_confirmPasswordHint;

  /// No description provided for @passwordSetup_submit.
  ///
  /// In zh, this message translates to:
  /// **'完成设置'**
  String get passwordSetup_submit;

  /// No description provided for @passwordSetup_requirementsTitle.
  ///
  /// In zh, this message translates to:
  /// **'密码要求：'**
  String get passwordSetup_requirementsTitle;

  /// No description provided for @passwordSetup_reqLength.
  ///
  /// In zh, this message translates to:
  /// **'长度6-20位'**
  String get passwordSetup_reqLength;

  /// No description provided for @passwordSetup_reqAlphaNum.
  ///
  /// In zh, this message translates to:
  /// **'包含字母和数字'**
  String get passwordSetup_reqAlphaNum;

  /// No description provided for @passwordSetup_reqSpecialChars.
  ///
  /// In zh, this message translates to:
  /// **'建议使用特殊字符增强安全性'**
  String get passwordSetup_reqSpecialChars;

  /// No description provided for @passwordSetup_emptyPassword.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get passwordSetup_emptyPassword;

  /// No description provided for @passwordSetup_tooShort.
  ///
  /// In zh, this message translates to:
  /// **'密码长度至少6位'**
  String get passwordSetup_tooShort;

  /// No description provided for @passwordSetup_tooLong.
  ///
  /// In zh, this message translates to:
  /// **'密码长度不超过20位'**
  String get passwordSetup_tooLong;

  /// No description provided for @passwordSetup_needAlphaNum.
  ///
  /// In zh, this message translates to:
  /// **'密码必须包含字母和数字'**
  String get passwordSetup_needAlphaNum;

  /// No description provided for @passwordSetup_mismatch.
  ///
  /// In zh, this message translates to:
  /// **'两次输入的密码不一致'**
  String get passwordSetup_mismatch;

  /// No description provided for @passwordSetup_setFailed.
  ///
  /// In zh, this message translates to:
  /// **'密码设置失败，请重试'**
  String get passwordSetup_setFailed;

  /// No description provided for @passwordSetup_errorOccurred.
  ///
  /// In zh, this message translates to:
  /// **'发生错误: {error}'**
  String passwordSetup_errorOccurred(String error);

  /// No description provided for @passwordSetup_agreePrefix.
  ///
  /// In zh, this message translates to:
  /// **'我已阅读并同意'**
  String get passwordSetup_agreePrefix;

  /// No description provided for @passwordSetup_and.
  ///
  /// In zh, this message translates to:
  /// **'和'**
  String get passwordSetup_and;

  /// No description provided for @passwordSetup_termsNotAccepted.
  ///
  /// In zh, this message translates to:
  /// **'请先阅读并同意服务条款和隐私政策'**
  String get passwordSetup_termsNotAccepted;

  /// No description provided for @changePassword_title.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get changePassword_title;

  /// No description provided for @changePassword_currentPassword.
  ///
  /// In zh, this message translates to:
  /// **'当前密码'**
  String get changePassword_currentPassword;

  /// No description provided for @changePassword_currentPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入当前密码'**
  String get changePassword_currentPasswordHint;

  /// No description provided for @changePassword_newPassword.
  ///
  /// In zh, this message translates to:
  /// **'新密码'**
  String get changePassword_newPassword;

  /// No description provided for @changePassword_newPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'至少6位，包含字母和数字'**
  String get changePassword_newPasswordHint;

  /// No description provided for @changePassword_confirmNewPassword.
  ///
  /// In zh, this message translates to:
  /// **'确认新密码'**
  String get changePassword_confirmNewPassword;

  /// No description provided for @changePassword_confirmNewPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请再次输入新密码'**
  String get changePassword_confirmNewPasswordHint;

  /// No description provided for @changePassword_submit.
  ///
  /// In zh, this message translates to:
  /// **'确认修改'**
  String get changePassword_submit;

  /// No description provided for @changePassword_requirementsTitle.
  ///
  /// In zh, this message translates to:
  /// **'新密码要求：'**
  String get changePassword_requirementsTitle;

  /// No description provided for @changePassword_reqLength.
  ///
  /// In zh, this message translates to:
  /// **'长度6-20位'**
  String get changePassword_reqLength;

  /// No description provided for @changePassword_reqAlphaNum.
  ///
  /// In zh, this message translates to:
  /// **'包含字母和数字'**
  String get changePassword_reqAlphaNum;

  /// No description provided for @changePassword_reqDifferent.
  ///
  /// In zh, this message translates to:
  /// **'不能与当前密码相同'**
  String get changePassword_reqDifferent;

  /// No description provided for @changePassword_emptyCurrentPassword.
  ///
  /// In zh, this message translates to:
  /// **'请输入当前密码'**
  String get changePassword_emptyCurrentPassword;

  /// No description provided for @changePassword_sameAsOld.
  ///
  /// In zh, this message translates to:
  /// **'新密码不能与当前密码相同'**
  String get changePassword_sameAsOld;

  /// No description provided for @changePassword_newMismatch.
  ///
  /// In zh, this message translates to:
  /// **'两次输入的新密码不一致'**
  String get changePassword_newMismatch;

  /// No description provided for @changePassword_success.
  ///
  /// In zh, this message translates to:
  /// **'密码修改成功'**
  String get changePassword_success;

  /// No description provided for @changePassword_wrongCurrent.
  ///
  /// In zh, this message translates to:
  /// **'当前密码错误，请重试'**
  String get changePassword_wrongCurrent;

  /// No description provided for @changePassword_failed.
  ///
  /// In zh, this message translates to:
  /// **'修改失败: {error}'**
  String changePassword_failed(String error);

  /// No description provided for @home_noAgents.
  ///
  /// In zh, this message translates to:
  /// **'暂无 Agent'**
  String get home_noAgents;

  /// No description provided for @home_noAgentsHint.
  ///
  /// In zh, this message translates to:
  /// **'点击菜单添加 Agent'**
  String get home_noAgentsHint;

  /// No description provided for @home_noMessages.
  ///
  /// In zh, this message translates to:
  /// **'暂无消息'**
  String get home_noMessages;

  /// No description provided for @home_typing.
  ///
  /// In zh, this message translates to:
  /// **'对方正在输入...'**
  String get home_typing;

  /// No description provided for @home_statusOnline.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get home_statusOnline;

  /// No description provided for @home_statusOffline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get home_statusOffline;

  /// No description provided for @home_statusThinking.
  ///
  /// In zh, this message translates to:
  /// **'思考中'**
  String get home_statusThinking;

  /// No description provided for @home_yesterday.
  ///
  /// In zh, this message translates to:
  /// **'昨天'**
  String get home_yesterday;

  /// No description provided for @home_weekMon.
  ///
  /// In zh, this message translates to:
  /// **'周一'**
  String get home_weekMon;

  /// No description provided for @home_weekTue.
  ///
  /// In zh, this message translates to:
  /// **'周二'**
  String get home_weekTue;

  /// No description provided for @home_weekWed.
  ///
  /// In zh, this message translates to:
  /// **'周三'**
  String get home_weekWed;

  /// No description provided for @home_weekThu.
  ///
  /// In zh, this message translates to:
  /// **'周四'**
  String get home_weekThu;

  /// No description provided for @home_weekFri.
  ///
  /// In zh, this message translates to:
  /// **'周五'**
  String get home_weekFri;

  /// No description provided for @home_weekSat.
  ///
  /// In zh, this message translates to:
  /// **'周六'**
  String get home_weekSat;

  /// No description provided for @home_weekSun.
  ///
  /// In zh, this message translates to:
  /// **'周日'**
  String get home_weekSun;

  /// No description provided for @home_addAgent.
  ///
  /// In zh, this message translates to:
  /// **'添加 Agent'**
  String get home_addAgent;

  /// No description provided for @home_createGroup.
  ///
  /// In zh, this message translates to:
  /// **'创建群组'**
  String get home_createGroup;

  /// No description provided for @home_agentsCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} agents'**
  String home_agentsCount(int count);

  /// No description provided for @drawer_myProfile.
  ///
  /// In zh, this message translates to:
  /// **'我的资料'**
  String get drawer_myProfile;

  /// No description provided for @drawer_newAgent.
  ///
  /// In zh, this message translates to:
  /// **'新建 Agent'**
  String get drawer_newAgent;

  /// No description provided for @drawer_newGroup.
  ///
  /// In zh, this message translates to:
  /// **'新建群组'**
  String get drawer_newGroup;

  /// No description provided for @drawer_settings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get drawer_settings;

  /// No description provided for @drawer_logout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get drawer_logout;

  /// No description provided for @logout_confirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认退出'**
  String get logout_confirmTitle;

  /// No description provided for @logout_confirmContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出登录吗？'**
  String get logout_confirmContent;

  /// No description provided for @settings_title.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settings_title;

  /// No description provided for @settings_security.
  ///
  /// In zh, this message translates to:
  /// **'安全'**
  String get settings_security;

  /// No description provided for @settings_changePassword.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get settings_changePassword;

  /// No description provided for @settings_changePasswordSub.
  ///
  /// In zh, this message translates to:
  /// **'修改您的登录密码'**
  String get settings_changePasswordSub;

  /// No description provided for @settings_biometric.
  ///
  /// In zh, this message translates to:
  /// **'生物识别认证'**
  String get settings_biometric;

  /// No description provided for @settings_biometricSub.
  ///
  /// In zh, this message translates to:
  /// **'使用指纹或面容 ID'**
  String get settings_biometricSub;

  /// No description provided for @settings_biometricComingSoon.
  ///
  /// In zh, this message translates to:
  /// **'生物识别认证即将推出'**
  String get settings_biometricComingSoon;

  /// No description provided for @settings_biometricNotSupported.
  ///
  /// In zh, this message translates to:
  /// **'此设备不支持生物识别认证'**
  String get settings_biometricNotSupported;

  /// No description provided for @settings_biometricEnablePrompt.
  ///
  /// In zh, this message translates to:
  /// **'请先验证身份以启用生物识别'**
  String get settings_biometricEnablePrompt;

  /// No description provided for @settings_biometricEnabled.
  ///
  /// In zh, this message translates to:
  /// **'生物识别已启用'**
  String get settings_biometricEnabled;

  /// No description provided for @settings_biometricDisabled.
  ///
  /// In zh, this message translates to:
  /// **'生物识别已关闭'**
  String get settings_biometricDisabled;

  /// No description provided for @login_biometricPrompt.
  ///
  /// In zh, this message translates to:
  /// **'验证身份以登录 ShePaw'**
  String get login_biometricPrompt;

  /// No description provided for @login_useBiometric.
  ///
  /// In zh, this message translates to:
  /// **'使用生物识别登录'**
  String get login_useBiometric;

  /// No description provided for @settings_account.
  ///
  /// In zh, this message translates to:
  /// **'账户'**
  String get settings_account;

  /// No description provided for @settings_profile.
  ///
  /// In zh, this message translates to:
  /// **'个人资料'**
  String get settings_profile;

  /// No description provided for @settings_profileSub.
  ///
  /// In zh, this message translates to:
  /// **'管理您的个人信息'**
  String get settings_profileSub;

  /// No description provided for @settings_notifications.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get settings_notifications;

  /// No description provided for @settings_notificationsSub.
  ///
  /// In zh, this message translates to:
  /// **'管理推送通知'**
  String get settings_notificationsSub;

  /// No description provided for @settings_dataManagement.
  ///
  /// In zh, this message translates to:
  /// **'数据管理'**
  String get settings_dataManagement;

  /// No description provided for @settings_exportData.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get settings_exportData;

  /// No description provided for @settings_exportDataSub.
  ///
  /// In zh, this message translates to:
  /// **'备份所有应用数据到文件'**
  String get settings_exportDataSub;

  /// No description provided for @settings_clearAllData.
  ///
  /// In zh, this message translates to:
  /// **'清除所有数据'**
  String get settings_clearAllData;

  /// No description provided for @settings_clearAllDataSub.
  ///
  /// In zh, this message translates to:
  /// **'删除所有 Agent、消息和文件'**
  String get settings_clearAllDataSub;

  /// No description provided for @settings_about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settings_about;

  /// No description provided for @settings_aboutVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本 1.0.0'**
  String get settings_aboutVersion;

  /// No description provided for @settings_checkForUpdates.
  ///
  /// In zh, this message translates to:
  /// **'检查更新'**
  String get settings_checkForUpdates;

  /// No description provided for @settings_checkForUpdatesSub.
  ///
  /// In zh, this message translates to:
  /// **'检查是否有最新版本'**
  String get settings_checkForUpdatesSub;

  /// No description provided for @update_checking.
  ///
  /// In zh, this message translates to:
  /// **'正在检查更新...'**
  String get update_checking;

  /// No description provided for @update_upToDate.
  ///
  /// In zh, this message translates to:
  /// **'已是最新版本'**
  String get update_upToDate;

  /// No description provided for @update_upToDateSub.
  ///
  /// In zh, this message translates to:
  /// **'Paw {version} 已是最新版本。'**
  String update_upToDateSub(String version);

  /// No description provided for @update_available.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本'**
  String get update_available;

  /// No description provided for @update_availableVersion.
  ///
  /// In zh, this message translates to:
  /// **'Paw {version} 现在可用'**
  String update_availableVersion(String version);

  /// No description provided for @update_mandatoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'强制更新'**
  String get update_mandatoryTitle;

  /// No description provided for @update_mandatoryMessage.
  ///
  /// In zh, this message translates to:
  /// **'此更新为必须更新，请升级到 {version} 版本才能继续使用 Paw。'**
  String update_mandatoryMessage(String version);

  /// No description provided for @update_releaseNotes.
  ///
  /// In zh, this message translates to:
  /// **'更新内容'**
  String get update_releaseNotes;

  /// No description provided for @update_downloadNow.
  ///
  /// In zh, this message translates to:
  /// **'立即下载'**
  String get update_downloadNow;

  /// No description provided for @update_remindLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后提醒'**
  String get update_remindLater;

  /// No description provided for @update_skipVersion.
  ///
  /// In zh, this message translates to:
  /// **'跳过此版本'**
  String get update_skipVersion;

  /// No description provided for @update_checkFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法检查更新，请检查网络连接。'**
  String get update_checkFailed;

  /// No description provided for @update_currentVersion.
  ///
  /// In zh, this message translates to:
  /// **'当前版本：{version}'**
  String update_currentVersion(String version);

  /// No description provided for @update_downloading.
  ///
  /// In zh, this message translates to:
  /// **'正在下载...'**
  String get update_downloading;

  /// No description provided for @update_downloadingFile.
  ///
  /// In zh, this message translates to:
  /// **'正在下载 {fileName}'**
  String update_downloadingFile(String fileName);

  /// No description provided for @update_downloadProgress.
  ///
  /// In zh, this message translates to:
  /// **'{downloaded} / {total}'**
  String update_downloadProgress(String downloaded, String total);

  /// No description provided for @update_downloadSpeed.
  ///
  /// In zh, this message translates to:
  /// **'{speed}/秒'**
  String update_downloadSpeed(String speed);

  /// No description provided for @update_downloadTimeRemaining.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {time}'**
  String update_downloadTimeRemaining(String time);

  /// No description provided for @update_downloadCompleted.
  ///
  /// In zh, this message translates to:
  /// **'下载完成'**
  String get update_downloadCompleted;

  /// No description provided for @update_downloadFailed.
  ///
  /// In zh, this message translates to:
  /// **'下载失败'**
  String get update_downloadFailed;

  /// No description provided for @update_retryDownload.
  ///
  /// In zh, this message translates to:
  /// **'重试下载'**
  String get update_retryDownload;

  /// No description provided for @update_notification_availableTitle.
  ///
  /// In zh, this message translates to:
  /// **'发现新版本 {version}'**
  String update_notification_availableTitle(String version);

  /// No description provided for @update_notification_availableBody.
  ///
  /// In zh, this message translates to:
  /// **'点击查看更新详情'**
  String get update_notification_availableBody;

  /// No description provided for @update_notification_readyTitle.
  ///
  /// In zh, this message translates to:
  /// **'更新已就绪'**
  String get update_notification_readyTitle;

  /// No description provided for @update_notification_readyBody.
  ///
  /// In zh, this message translates to:
  /// **'点击安装 {version}'**
  String update_notification_readyBody(String version);

  /// No description provided for @update_action_accept.
  ///
  /// In zh, this message translates to:
  /// **'立即下载'**
  String get update_action_accept;

  /// No description provided for @update_action_decline.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get update_action_decline;

  /// No description provided for @update_action_installNow.
  ///
  /// In zh, this message translates to:
  /// **'立即安装'**
  String get update_action_installNow;

  /// No description provided for @update_action_installLater.
  ///
  /// In zh, this message translates to:
  /// **'稍后'**
  String get update_action_installLater;

  /// No description provided for @update_pendingInstallTitle.
  ///
  /// In zh, this message translates to:
  /// **'更新已就绪'**
  String get update_pendingInstallTitle;

  /// No description provided for @update_pendingInstallBody.
  ///
  /// In zh, this message translates to:
  /// **'{version} 已下载完成，是否立即安装？'**
  String update_pendingInstallBody(String version);

  /// No description provided for @settings_privacyPolicy.
  ///
  /// In zh, this message translates to:
  /// **'隐私政策'**
  String get settings_privacyPolicy;

  /// No description provided for @settings_termsOfService.
  ///
  /// In zh, this message translates to:
  /// **'服务条款'**
  String get settings_termsOfService;

  /// No description provided for @settings_language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settings_language;

  /// No description provided for @settings_languageSub.
  ///
  /// In zh, this message translates to:
  /// **'更改应用显示语言'**
  String get settings_languageSub;

  /// No description provided for @settings_languageFollowSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settings_languageFollowSystem;

  /// No description provided for @settings_languageEnglish.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get settings_languageEnglish;

  /// No description provided for @settings_languageChinese.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get settings_languageChinese;

  /// No description provided for @settings_languageDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择语言'**
  String get settings_languageDialogTitle;

  /// No description provided for @settings_exportDataTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出数据'**
  String get settings_exportDataTitle;

  /// No description provided for @settings_exportDataContent.
  ///
  /// In zh, this message translates to:
  /// **'将导出所有应用数据（包括 Agent 配置、聊天记录、文件等）为一个备份文件。\n\n导出完成后可以通过系统分享发送到其他位置。'**
  String get settings_exportDataContent;

  /// No description provided for @settings_exportingData.
  ///
  /// In zh, this message translates to:
  /// **'正在导出数据...'**
  String get settings_exportingData;

  /// No description provided for @settings_exportSuccess.
  ///
  /// In zh, this message translates to:
  /// **'数据导出成功'**
  String get settings_exportSuccess;

  /// No description provided for @settings_exportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败: {error}'**
  String settings_exportFailed(String error);

  /// No description provided for @settings_clearAllDataTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除所有数据'**
  String get settings_clearAllDataTitle;

  /// No description provided for @settings_clearAllDataContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除所有数据，包括：\n\n• 所有 Agent 配置\n• 所有聊天记录和消息\n• 所有文件和图片\n\n此操作不可恢复！建议先导出备份。\n\n是否继续？'**
  String get settings_clearAllDataContent;

  /// No description provided for @settings_clearAllDataButton.
  ///
  /// In zh, this message translates to:
  /// **'清除所有数据'**
  String get settings_clearAllDataButton;

  /// No description provided for @settings_clearingAllData.
  ///
  /// In zh, this message translates to:
  /// **'正在清除所有数据...'**
  String get settings_clearingAllData;

  /// No description provided for @settings_clearAllDataSuccess.
  ///
  /// In zh, this message translates to:
  /// **'所有数据已清除'**
  String get settings_clearAllDataSuccess;

  /// No description provided for @settings_clearAllDataFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除数据失败: {error}'**
  String settings_clearAllDataFailed(String error);

  /// No description provided for @addAgent_connectTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接远端助手'**
  String get addAgent_connectTitle;

  /// No description provided for @addAgent_createTitle.
  ///
  /// In zh, this message translates to:
  /// **'创建助手配置'**
  String get addAgent_createTitle;

  /// No description provided for @addAgent_modeConnect.
  ///
  /// In zh, this message translates to:
  /// **'连接远端 Agent'**
  String get addAgent_modeConnect;

  /// No description provided for @addAgent_modeCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建本地配置'**
  String get addAgent_modeCreate;

  /// No description provided for @addAgent_basicInfo.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get addAgent_basicInfo;

  /// No description provided for @addAgent_agentName.
  ///
  /// In zh, this message translates to:
  /// **'助手名称'**
  String get addAgent_agentName;

  /// No description provided for @addAgent_agentNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：我的 AI 助手'**
  String get addAgent_agentNameHint;

  /// No description provided for @addAgent_agentNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入助手名称'**
  String get addAgent_agentNameRequired;

  /// No description provided for @addAgent_agentBio.
  ///
  /// In zh, this message translates to:
  /// **'助手描述（可选）'**
  String get addAgent_agentBio;

  /// No description provided for @addAgent_agentBioHint.
  ///
  /// In zh, this message translates to:
  /// **'简单描述这个助手的功能'**
  String get addAgent_agentBioHint;

  /// No description provided for @addAgent_systemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词（可选）'**
  String get addAgent_systemPrompt;

  /// No description provided for @addAgent_systemPromptHint.
  ///
  /// In zh, this message translates to:
  /// **'定义 Agent 的角色和能力范围'**
  String get addAgent_systemPromptHint;

  /// No description provided for @addAgent_connectConfig.
  ///
  /// In zh, this message translates to:
  /// **'连接配置'**
  String get addAgent_connectConfig;

  /// No description provided for @addAgent_tokenAuth.
  ///
  /// In zh, this message translates to:
  /// **'Token 认证'**
  String get addAgent_tokenAuth;

  /// No description provided for @addAgent_tokenHint.
  ///
  /// In zh, this message translates to:
  /// **'输入 Token 或点击右侧按钮随机生成'**
  String get addAgent_tokenHint;

  /// No description provided for @addAgent_generateToken.
  ///
  /// In zh, this message translates to:
  /// **'随机生成 Token'**
  String get addAgent_generateToken;

  /// No description provided for @addAgent_tokenRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入或生成 Token'**
  String get addAgent_tokenRequired;

  /// No description provided for @addAgent_endpointUrl.
  ///
  /// In zh, this message translates to:
  /// **'端点 URL'**
  String get addAgent_endpointUrl;

  /// No description provided for @addAgent_endpointUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'ws://example.com:8080/acp/ws'**
  String get addAgent_endpointUrlHint;

  /// No description provided for @addAgent_endpointHelper.
  ///
  /// In zh, this message translates to:
  /// **'远端 Agent 的服务地址'**
  String get addAgent_endpointHelper;

  /// No description provided for @addAgent_endpointRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入端点 URL'**
  String get addAgent_endpointRequired;

  /// No description provided for @addAgent_endpointInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的 URL（http://, https://, ws://, wss://）'**
  String get addAgent_endpointInvalid;

  /// No description provided for @addAgent_modelConfig.
  ///
  /// In zh, this message translates to:
  /// **'模型配置'**
  String get addAgent_modelConfig;

  /// No description provided for @addAgent_modelConfigHint.
  ///
  /// In zh, this message translates to:
  /// **'选择 LLM 服务商，将自动填充默认配置'**
  String get addAgent_modelConfigHint;

  /// No description provided for @addAgent_modelName.
  ///
  /// In zh, this message translates to:
  /// **'模型名称'**
  String get addAgent_modelName;

  /// No description provided for @addAgent_modelNameHint.
  ///
  /// In zh, this message translates to:
  /// **'输入模型名称'**
  String get addAgent_modelNameHint;

  /// No description provided for @addAgent_selectModel.
  ///
  /// In zh, this message translates to:
  /// **'选择模型'**
  String get addAgent_selectModel;

  /// No description provided for @addAgent_apiKeyNotRequired.
  ///
  /// In zh, this message translates to:
  /// **'本地服务无需 API Key'**
  String get addAgent_apiKeyNotRequired;

  /// No description provided for @addAgent_apiKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'输入 API Key'**
  String get addAgent_apiKeyHint;

  /// No description provided for @addAgent_connectSteps.
  ///
  /// In zh, this message translates to:
  /// **'连接步骤'**
  String get addAgent_connectSteps;

  /// No description provided for @addAgent_connectStep1.
  ///
  /// In zh, this message translates to:
  /// **'输入远端 Agent 提供的 Token 或随机生成'**
  String get addAgent_connectStep1;

  /// No description provided for @addAgent_connectStep2.
  ///
  /// In zh, this message translates to:
  /// **'填写远端 Agent 的服务地址'**
  String get addAgent_connectStep2;

  /// No description provided for @addAgent_connectStep3.
  ///
  /// In zh, this message translates to:
  /// **'连接成功后可以开始对话'**
  String get addAgent_connectStep3;

  /// No description provided for @addAgent_connectButton.
  ///
  /// In zh, this message translates to:
  /// **'连接远端助手'**
  String get addAgent_connectButton;

  /// No description provided for @addAgent_createButton.
  ///
  /// In zh, this message translates to:
  /// **'创建助手配置'**
  String get addAgent_createButton;

  /// No description provided for @addAgent_createFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建失败: {error}'**
  String addAgent_createFailed(String error);

  /// No description provided for @addAgent_testingConnection.
  ///
  /// In zh, this message translates to:
  /// **'正在测试 Agent 连接...'**
  String get addAgent_testingConnection;

  /// No description provided for @addAgent_connectSuccess.
  ///
  /// In zh, this message translates to:
  /// **'连接成功！Agent 在线可用'**
  String get addAgent_connectSuccess;

  /// No description provided for @addAgent_createSuccess.
  ///
  /// In zh, this message translates to:
  /// **'助手创建成功！'**
  String get addAgent_createSuccess;

  /// No description provided for @addAgent_connectFailTitle.
  ///
  /// In zh, this message translates to:
  /// **'连接测试失败'**
  String get addAgent_connectFailTitle;

  /// No description provided for @addAgent_connectFailContent.
  ///
  /// In zh, this message translates to:
  /// **'Agent 健康检查失败，无法建立连接。\n\n可能的原因：\n• Endpoint URL 不正确\n• Token 无效\n• Agent 服务未运行\n• 网络连接问题\n\n是否仍要保留此 Agent 配置？'**
  String get addAgent_connectFailContent;

  /// No description provided for @addAgent_deleteConfig.
  ///
  /// In zh, this message translates to:
  /// **'删除配置'**
  String get addAgent_deleteConfig;

  /// No description provided for @addAgent_keepConfig.
  ///
  /// In zh, this message translates to:
  /// **'保留配置'**
  String get addAgent_keepConfig;

  /// No description provided for @addAgent_configDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除 Agent 配置'**
  String get addAgent_configDeleted;

  /// No description provided for @addAgent_configKeptOffline.
  ///
  /// In zh, this message translates to:
  /// **'已保留 Agent 配置（离线状态）'**
  String get addAgent_configKeptOffline;

  /// No description provided for @addAgent_operationFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败: {error}'**
  String addAgent_operationFailed(String error);

  /// No description provided for @addAgent_duplicateTitle.
  ///
  /// In zh, this message translates to:
  /// **'Agent 已存在'**
  String get addAgent_duplicateTitle;

  /// No description provided for @addAgent_existingInfo.
  ///
  /// In zh, this message translates to:
  /// **'已有 Agent 信息：'**
  String get addAgent_existingInfo;

  /// No description provided for @addAgent_existingName.
  ///
  /// In zh, this message translates to:
  /// **'名称: {name}'**
  String addAgent_existingName(String name);

  /// No description provided for @addAgent_existingProtocol.
  ///
  /// In zh, this message translates to:
  /// **'协议: {protocol}'**
  String addAgent_existingProtocol(String protocol);

  /// No description provided for @addAgent_selectAvatar.
  ///
  /// In zh, this message translates to:
  /// **'选择头像'**
  String get addAgent_selectAvatar;

  /// No description provided for @addAgent_endpointConfigTitle.
  ///
  /// In zh, this message translates to:
  /// **'端点配置'**
  String get addAgent_endpointConfigTitle;

  /// No description provided for @addAgent_endpointOptional.
  ///
  /// In zh, this message translates to:
  /// **'端点 URL（可选）'**
  String get addAgent_endpointOptional;

  /// No description provided for @addAgent_endpointOptionalHelper.
  ///
  /// In zh, this message translates to:
  /// **'可以稍后配置'**
  String get addAgent_endpointOptionalHelper;

  /// No description provided for @addAgent_remoteAgentId.
  ///
  /// In zh, this message translates to:
  /// **'远端 Agent ID'**
  String get addAgent_remoteAgentId;

  /// No description provided for @addAgent_remoteAgentIdHint.
  ///
  /// In zh, this message translates to:
  /// **'可选，对方 Agent 的 ID'**
  String get addAgent_remoteAgentIdHint;

  /// No description provided for @addAgent_remoteAgentIdHelper.
  ///
  /// In zh, this message translates to:
  /// **'填写后可精确连接指定 Agent（可选）'**
  String get addAgent_remoteAgentIdHelper;

  /// No description provided for @createGroup_title.
  ///
  /// In zh, this message translates to:
  /// **'创建群聊'**
  String get createGroup_title;

  /// No description provided for @createGroup_create.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get createGroup_create;

  /// No description provided for @createGroup_groupName.
  ///
  /// In zh, this message translates to:
  /// **'群聊名称'**
  String get createGroup_groupName;

  /// No description provided for @createGroup_purpose.
  ///
  /// In zh, this message translates to:
  /// **'群聊目的（可选）'**
  String get createGroup_purpose;

  /// No description provided for @createGroup_purposeHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：协作完成前端开发任务'**
  String get createGroup_purposeHint;

  /// No description provided for @createGroup_selectAgent.
  ///
  /// In zh, this message translates to:
  /// **'选择 Agent'**
  String get createGroup_selectAgent;

  /// No description provided for @createGroup_agentCount.
  ///
  /// In zh, this message translates to:
  /// **'({selected}/{total} 个)'**
  String createGroup_agentCount(int selected, int total);

  /// No description provided for @createGroup_noAgents.
  ///
  /// In zh, this message translates to:
  /// **'暂无 Agent，请先添加 Agent'**
  String get createGroup_noAgents;

  /// No description provided for @createGroup_setAsAdmin.
  ///
  /// In zh, this message translates to:
  /// **'设为管理员'**
  String get createGroup_setAsAdmin;

  /// No description provided for @createGroup_nameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入群聊名称'**
  String get createGroup_nameRequired;

  /// No description provided for @createGroup_agentRequired.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个 Agent'**
  String get createGroup_agentRequired;

  /// No description provided for @createGroup_adminRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择一个 Admin（管理员）'**
  String get createGroup_adminRequired;

  /// No description provided for @createGroup_button.
  ///
  /// In zh, this message translates to:
  /// **'创建群聊'**
  String get createGroup_button;

  /// No description provided for @createGroup_systemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词（可选）'**
  String get createGroup_systemPrompt;

  /// No description provided for @createGroup_systemPromptHint.
  ///
  /// In zh, this message translates to:
  /// **'为群内 Agent 定义约束或指令'**
  String get createGroup_systemPromptHint;

  /// No description provided for @createGroup_groupRole.
  ///
  /// In zh, this message translates to:
  /// **'群内职责（可选）'**
  String get createGroup_groupRole;

  /// No description provided for @createGroup_groupRoleHint.
  ///
  /// In zh, this message translates to:
  /// **'描述该 Agent 在本群中的职责'**
  String get createGroup_groupRoleHint;

  /// No description provided for @createGroup_maxLoopRounds.
  ///
  /// In zh, this message translates to:
  /// **'最大编排轮次'**
  String get createGroup_maxLoopRounds;

  /// No description provided for @createGroup_maxLoopRoundsHint.
  ///
  /// In zh, this message translates to:
  /// **'管理员循环编排的最大轮次（默认 50）'**
  String get createGroup_maxLoopRoundsHint;

  /// No description provided for @permission_title.
  ///
  /// In zh, this message translates to:
  /// **'权限请求管理'**
  String get permission_title;

  /// No description provided for @permission_filterLabel.
  ///
  /// In zh, this message translates to:
  /// **'状态筛选：'**
  String get permission_filterLabel;

  /// No description provided for @permission_noRequests.
  ///
  /// In zh, this message translates to:
  /// **'暂无权限请求'**
  String get permission_noRequests;

  /// No description provided for @permission_noRequestsOfType.
  ///
  /// In zh, this message translates to:
  /// **'暂无{status}的权限请求'**
  String permission_noRequestsOfType(String status);

  /// No description provided for @permission_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败: {error}'**
  String permission_loadFailed(String error);

  /// No description provided for @permission_approved.
  ///
  /// In zh, this message translates to:
  /// **'权限已批准'**
  String get permission_approved;

  /// No description provided for @permission_rejected.
  ///
  /// In zh, this message translates to:
  /// **'权限已拒绝'**
  String get permission_rejected;

  /// No description provided for @permission_typeLabel.
  ///
  /// In zh, this message translates to:
  /// **'权限类型'**
  String get permission_typeLabel;

  /// No description provided for @permission_reasonLabel.
  ///
  /// In zh, this message translates to:
  /// **'请求原因'**
  String get permission_reasonLabel;

  /// No description provided for @permission_timeLabel.
  ///
  /// In zh, this message translates to:
  /// **'请求时间'**
  String get permission_timeLabel;

  /// No description provided for @permission_expiryLabel.
  ///
  /// In zh, this message translates to:
  /// **'有效期至'**
  String get permission_expiryLabel;

  /// No description provided for @permission_reject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get permission_reject;

  /// No description provided for @permission_approve.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get permission_approve;

  /// No description provided for @permission_revoke.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get permission_revoke;

  /// No description provided for @permission_approveTitle.
  ///
  /// In zh, this message translates to:
  /// **'批准权限'**
  String get permission_approveTitle;

  /// No description provided for @permission_approveContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要批准 {agentName} 的 {permissionType} 权限吗？'**
  String permission_approveContent(String agentName, String permissionType);

  /// No description provided for @permission_rejectTitle.
  ///
  /// In zh, this message translates to:
  /// **'拒绝权限'**
  String get permission_rejectTitle;

  /// No description provided for @permission_rejectContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要拒绝 {agentName} 的权限请求吗？'**
  String permission_rejectContent(String agentName);

  /// No description provided for @permission_revokeTitle.
  ///
  /// In zh, this message translates to:
  /// **'撤销权限'**
  String get permission_revokeTitle;

  /// No description provided for @permission_revokeContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要撤销 {agentName} 的权限吗？撤销后该 Agent 将无法继续访问相关功能。'**
  String permission_revokeContent(String agentName);

  /// No description provided for @permission_statusPending.
  ///
  /// In zh, this message translates to:
  /// **'待审批'**
  String get permission_statusPending;

  /// No description provided for @permission_statusApproved.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get permission_statusApproved;

  /// No description provided for @permission_statusRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get permission_statusRejected;

  /// No description provided for @permission_statusExpired.
  ///
  /// In zh, this message translates to:
  /// **'已过期'**
  String get permission_statusExpired;

  /// No description provided for @permission_typeInitiateChat.
  ///
  /// In zh, this message translates to:
  /// **'发起聊天'**
  String get permission_typeInitiateChat;

  /// No description provided for @permission_typeGetAgentList.
  ///
  /// In zh, this message translates to:
  /// **'获取 Agent 列表'**
  String get permission_typeGetAgentList;

  /// No description provided for @permission_typeGetCapabilities.
  ///
  /// In zh, this message translates to:
  /// **'获取 Agent 能力'**
  String get permission_typeGetCapabilities;

  /// No description provided for @permission_typeSubscribeChannel.
  ///
  /// In zh, this message translates to:
  /// **'订阅 Channel'**
  String get permission_typeSubscribeChannel;

  /// No description provided for @permission_typeSendFile.
  ///
  /// In zh, this message translates to:
  /// **'发送文件'**
  String get permission_typeSendFile;

  /// No description provided for @permission_typeGetSessions.
  ///
  /// In zh, this message translates to:
  /// **'获取会话列表'**
  String get permission_typeGetSessions;

  /// No description provided for @permission_typeGetSessionMessages.
  ///
  /// In zh, this message translates to:
  /// **'获取会话消息'**
  String get permission_typeGetSessionMessages;

  /// No description provided for @permission_typeGetAttachmentContent.
  ///
  /// In zh, this message translates to:
  /// **'获取附件内容'**
  String get permission_typeGetAttachmentContent;

  /// No description provided for @permissionDialog_title.
  ///
  /// In zh, this message translates to:
  /// **'权限请求'**
  String get permissionDialog_title;

  /// No description provided for @permissionDialog_agent.
  ///
  /// In zh, this message translates to:
  /// **'Agent'**
  String get permissionDialog_agent;

  /// No description provided for @permissionDialog_action.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get permissionDialog_action;

  /// No description provided for @permissionDialog_reason.
  ///
  /// In zh, this message translates to:
  /// **'原因'**
  String get permissionDialog_reason;

  /// No description provided for @permissionDialog_time.
  ///
  /// In zh, this message translates to:
  /// **'时间'**
  String get permissionDialog_time;

  /// No description provided for @permissionDialog_reject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get permissionDialog_reject;

  /// No description provided for @permissionDialog_approve.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get permissionDialog_approve;

  /// No description provided for @log_title.
  ///
  /// In zh, this message translates to:
  /// **'系统日志'**
  String get log_title;

  /// No description provided for @log_filterTooltip.
  ///
  /// In zh, this message translates to:
  /// **'筛选日志级别'**
  String get log_filterTooltip;

  /// No description provided for @log_all.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get log_all;

  /// No description provided for @log_enableAutoScroll.
  ///
  /// In zh, this message translates to:
  /// **'启用自动滚动'**
  String get log_enableAutoScroll;

  /// No description provided for @log_disableAutoScroll.
  ///
  /// In zh, this message translates to:
  /// **'禁用自动滚动'**
  String get log_disableAutoScroll;

  /// No description provided for @log_export.
  ///
  /// In zh, this message translates to:
  /// **'导出日志'**
  String get log_export;

  /// No description provided for @log_exported.
  ///
  /// In zh, this message translates to:
  /// **'日志已导出'**
  String get log_exported;

  /// No description provided for @log_clearTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除日志'**
  String get log_clearTitle;

  /// No description provided for @log_clearContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有日志吗？此操作不可恢复。'**
  String get log_clearContent;

  /// No description provided for @log_clearButton.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get log_clearButton;

  /// No description provided for @log_noLogs.
  ///
  /// In zh, this message translates to:
  /// **'暂无日志'**
  String get log_noLogs;

  /// No description provided for @log_total.
  ///
  /// In zh, this message translates to:
  /// **'总计'**
  String get log_total;

  /// No description provided for @agentDetail_title.
  ///
  /// In zh, this message translates to:
  /// **'Agent 详情'**
  String get agentDetail_title;

  /// No description provided for @agentDetail_editTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑 Agent'**
  String get agentDetail_editTitle;

  /// No description provided for @agentDetail_editTooltip.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get agentDetail_editTooltip;

  /// No description provided for @agentDetail_startConversation.
  ///
  /// In zh, this message translates to:
  /// **'发起对话'**
  String get agentDetail_startConversation;

  /// No description provided for @agentDetail_deleteAgent.
  ///
  /// In zh, this message translates to:
  /// **'删除 Agent'**
  String get agentDetail_deleteAgent;

  /// No description provided for @agentDetail_confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'确认删除'**
  String get agentDetail_confirmDelete;

  /// No description provided for @agentDetail_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除助手「{name}」吗？\n\n删除后将无法恢复，相关的聊天记录也可能受到影响。'**
  String agentDetail_deleteContent(String name);

  /// No description provided for @agentDetail_deleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除「{name}」'**
  String agentDetail_deleted(String name);

  /// No description provided for @agentDetail_deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败: {error}'**
  String agentDetail_deleteFailed(String error);

  /// No description provided for @agentDetail_connectionInfo.
  ///
  /// In zh, this message translates to:
  /// **'连接信息'**
  String get agentDetail_connectionInfo;

  /// No description provided for @agentDetail_protocol.
  ///
  /// In zh, this message translates to:
  /// **'协议'**
  String get agentDetail_protocol;

  /// No description provided for @agentDetail_connectionType.
  ///
  /// In zh, this message translates to:
  /// **'连接方式'**
  String get agentDetail_connectionType;

  /// No description provided for @agentDetail_endpoint.
  ///
  /// In zh, this message translates to:
  /// **'端点'**
  String get agentDetail_endpoint;

  /// No description provided for @agentDetail_capabilities.
  ///
  /// In zh, this message translates to:
  /// **'能力'**
  String get agentDetail_capabilities;

  /// No description provided for @agentDetail_systemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词'**
  String get agentDetail_systemPrompt;

  /// No description provided for @agentDetail_llmConfig.
  ///
  /// In zh, this message translates to:
  /// **'LLM 配置'**
  String get agentDetail_llmConfig;

  /// No description provided for @agentDetail_provider.
  ///
  /// In zh, this message translates to:
  /// **'服务商'**
  String get agentDetail_provider;

  /// No description provided for @agentDetail_model.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get agentDetail_model;

  /// No description provided for @agentDetail_lastActive.
  ///
  /// In zh, this message translates to:
  /// **'最后活跃'**
  String get agentDetail_lastActive;

  /// No description provided for @agentDetail_createdAt.
  ///
  /// In zh, this message translates to:
  /// **'创建时间'**
  String get agentDetail_createdAt;

  /// No description provided for @agentDetail_authToken.
  ///
  /// In zh, this message translates to:
  /// **'认证 Token'**
  String get agentDetail_authToken;

  /// No description provided for @agentDetail_copyToken.
  ///
  /// In zh, this message translates to:
  /// **'复制 Token'**
  String get agentDetail_copyToken;

  /// No description provided for @agentDetail_tokenCopied.
  ///
  /// In zh, this message translates to:
  /// **'Token 已复制到剪贴板'**
  String get agentDetail_tokenCopied;

  /// No description provided for @agentDetail_nameRequired.
  ///
  /// In zh, this message translates to:
  /// **'助手名称不能为空'**
  String get agentDetail_nameRequired;

  /// No description provided for @agentDetail_tokenRequired.
  ///
  /// In zh, this message translates to:
  /// **'Token 不能为空'**
  String get agentDetail_tokenRequired;

  /// No description provided for @agentDetail_tokenHint.
  ///
  /// In zh, this message translates to:
  /// **'粘贴远端 Agent 提供的 Token'**
  String get agentDetail_tokenHint;

  /// No description provided for @agentDetail_saveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'保存成功'**
  String get agentDetail_saveSuccess;

  /// No description provided for @agentDetail_saveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败: {error}'**
  String agentDetail_saveFailed(String error);

  /// No description provided for @agentDetail_changeAvatar.
  ///
  /// In zh, this message translates to:
  /// **'更换头像'**
  String get agentDetail_changeAvatar;

  /// No description provided for @agentDetail_selectBuiltinAvatar.
  ///
  /// In zh, this message translates to:
  /// **'选择内置图标'**
  String get agentDetail_selectBuiltinAvatar;

  /// No description provided for @agentDetail_selectFromGallery.
  ///
  /// In zh, this message translates to:
  /// **'从相册选择'**
  String get agentDetail_selectFromGallery;

  /// No description provided for @agentDetail_takePhoto.
  ///
  /// In zh, this message translates to:
  /// **'拍照'**
  String get agentDetail_takePhoto;

  /// No description provided for @agentDetail_galleryFailed.
  ///
  /// In zh, this message translates to:
  /// **'选择图片失败: {error}'**
  String agentDetail_galleryFailed(String error);

  /// No description provided for @agentDetail_cameraFailed.
  ///
  /// In zh, this message translates to:
  /// **'拍照失败: {error}'**
  String agentDetail_cameraFailed(String error);

  /// No description provided for @agentDetail_saveImageFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存图片失败: {error}'**
  String agentDetail_saveImageFailed(String error);

  /// No description provided for @agentDetail_protocolType.
  ///
  /// In zh, this message translates to:
  /// **'协议类型'**
  String get agentDetail_protocolType;

  /// No description provided for @agentDetail_connectionTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'连接方式'**
  String get agentDetail_connectionTypeLabel;

  /// No description provided for @agentDetail_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get agentDetail_custom;

  /// No description provided for @agentDetail_copyTokenTooltip.
  ///
  /// In zh, this message translates to:
  /// **'复制 Token'**
  String get agentDetail_copyTokenTooltip;

  /// No description provided for @agentDetail_justNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get agentDetail_justNow;

  /// No description provided for @agentDetail_minutesAgo.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分钟前'**
  String agentDetail_minutesAgo(int minutes);

  /// No description provided for @agentDetail_hoursAgo.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时前'**
  String agentDetail_hoursAgo(int hours);

  /// No description provided for @profile_title.
  ///
  /// In zh, this message translates to:
  /// **'我的资料'**
  String get profile_title;

  /// No description provided for @profile_email.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get profile_email;

  /// No description provided for @profile_phone.
  ///
  /// In zh, this message translates to:
  /// **'电话'**
  String get profile_phone;

  /// No description provided for @profile_birthday.
  ///
  /// In zh, this message translates to:
  /// **'生日'**
  String get profile_birthday;

  /// No description provided for @profile_location.
  ///
  /// In zh, this message translates to:
  /// **'位置'**
  String get profile_location;

  /// No description provided for @profile_notSet.
  ///
  /// In zh, this message translates to:
  /// **'未设置'**
  String get profile_notSet;

  /// No description provided for @profile_agents.
  ///
  /// In zh, this message translates to:
  /// **'Agent'**
  String get profile_agents;

  /// No description provided for @profile_groups.
  ///
  /// In zh, this message translates to:
  /// **'群组'**
  String get profile_groups;

  /// No description provided for @profile_messages.
  ///
  /// In zh, this message translates to:
  /// **'消息'**
  String get profile_messages;

  /// No description provided for @profile_editProfile.
  ///
  /// In zh, this message translates to:
  /// **'编辑资料'**
  String get profile_editProfile;

  /// No description provided for @collaboration_title.
  ///
  /// In zh, this message translates to:
  /// **'Agent 协作'**
  String get collaboration_title;

  /// No description provided for @collaboration_description.
  ///
  /// In zh, this message translates to:
  /// **'让多个 Agent 协作完成复杂任务，支持多种协作策略。'**
  String get collaboration_description;

  /// No description provided for @collaboration_taskName.
  ///
  /// In zh, this message translates to:
  /// **'任务名称'**
  String get collaboration_taskName;

  /// No description provided for @collaboration_taskNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例: 市场调研报告'**
  String get collaboration_taskNameHint;

  /// No description provided for @collaboration_taskNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入任务名称'**
  String get collaboration_taskNameRequired;

  /// No description provided for @collaboration_taskDescription.
  ///
  /// In zh, this message translates to:
  /// **'任务描述'**
  String get collaboration_taskDescription;

  /// No description provided for @collaboration_taskDescriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'详细描述要完成的任务'**
  String get collaboration_taskDescriptionHint;

  /// No description provided for @collaboration_taskDescriptionRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入任务描述'**
  String get collaboration_taskDescriptionRequired;

  /// No description provided for @collaboration_initialMessage.
  ///
  /// In zh, this message translates to:
  /// **'初始消息'**
  String get collaboration_initialMessage;

  /// No description provided for @collaboration_initialMessageHint.
  ///
  /// In zh, this message translates to:
  /// **'开始协作的消息'**
  String get collaboration_initialMessageHint;

  /// No description provided for @collaboration_initialMessageRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入初始消息'**
  String get collaboration_initialMessageRequired;

  /// No description provided for @collaboration_strategy.
  ///
  /// In zh, this message translates to:
  /// **'协作策略'**
  String get collaboration_strategy;

  /// No description provided for @collaboration_selectAgent.
  ///
  /// In zh, this message translates to:
  /// **'选择 Agent'**
  String get collaboration_selectAgent;

  /// No description provided for @collaboration_selectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选择 {selected}/{total}'**
  String collaboration_selectedCount(int selected, int total);

  /// No description provided for @collaboration_noAgents.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用的 Agent'**
  String get collaboration_noAgents;

  /// No description provided for @collaboration_noDescription.
  ///
  /// In zh, this message translates to:
  /// **'无描述'**
  String get collaboration_noDescription;

  /// No description provided for @collaboration_start.
  ///
  /// In zh, this message translates to:
  /// **'开始协作'**
  String get collaboration_start;

  /// No description provided for @collaboration_result.
  ///
  /// In zh, this message translates to:
  /// **'协作结果'**
  String get collaboration_result;

  /// No description provided for @collaboration_finalOutput.
  ///
  /// In zh, this message translates to:
  /// **'最终输出'**
  String get collaboration_finalOutput;

  /// No description provided for @collaboration_agentResults.
  ///
  /// In zh, this message translates to:
  /// **'各 Agent 结果'**
  String get collaboration_agentResults;

  /// No description provided for @collaboration_success.
  ///
  /// In zh, this message translates to:
  /// **'协作任务执行成功'**
  String get collaboration_success;

  /// No description provided for @collaboration_taskFailed.
  ///
  /// In zh, this message translates to:
  /// **'协作任务执行失败: {error}'**
  String collaboration_taskFailed(String error);

  /// No description provided for @collaboration_loadAgentFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载 Agent 失败'**
  String get collaboration_loadAgentFailed;

  /// No description provided for @collaboration_executeFailed.
  ///
  /// In zh, this message translates to:
  /// **'执行协作任务失败'**
  String get collaboration_executeFailed;

  /// No description provided for @collaboration_selectAgentWarning.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个 Agent'**
  String get collaboration_selectAgentWarning;

  /// No description provided for @collaboration_strategySequential.
  ///
  /// In zh, this message translates to:
  /// **'顺序执行'**
  String get collaboration_strategySequential;

  /// No description provided for @collaboration_strategyParallel.
  ///
  /// In zh, this message translates to:
  /// **'并行执行'**
  String get collaboration_strategyParallel;

  /// No description provided for @collaboration_strategyVoting.
  ///
  /// In zh, this message translates to:
  /// **'投票机制'**
  String get collaboration_strategyVoting;

  /// No description provided for @collaboration_strategyPipeline.
  ///
  /// In zh, this message translates to:
  /// **'流水线'**
  String get collaboration_strategyPipeline;

  /// No description provided for @collaboration_strategySequentialDesc.
  ///
  /// In zh, this message translates to:
  /// **'Agent 按顺序依次处理，上一个的输出作为下一个的输入'**
  String get collaboration_strategySequentialDesc;

  /// No description provided for @collaboration_strategyParallelDesc.
  ///
  /// In zh, this message translates to:
  /// **'所有 Agent 同时处理相同的输入'**
  String get collaboration_strategyParallelDesc;

  /// No description provided for @collaboration_strategyVotingDesc.
  ///
  /// In zh, this message translates to:
  /// **'多个 Agent 投票选择最佳结果'**
  String get collaboration_strategyVotingDesc;

  /// No description provided for @collaboration_strategyPipelineDesc.
  ///
  /// In zh, this message translates to:
  /// **'每个 Agent 处理特定阶段'**
  String get collaboration_strategyPipelineDesc;

  /// No description provided for @collaboration_helpTitle.
  ///
  /// In zh, this message translates to:
  /// **'协作策略说明'**
  String get collaboration_helpTitle;

  /// No description provided for @collaboration_helpSequential.
  ///
  /// In zh, this message translates to:
  /// **'Agent 按顺序依次处理，适合需要逐步优化的任务。'**
  String get collaboration_helpSequential;

  /// No description provided for @collaboration_helpParallel.
  ///
  /// In zh, this message translates to:
  /// **'所有 Agent 同时处理，适合需要多角度分析的任务。'**
  String get collaboration_helpParallel;

  /// No description provided for @collaboration_helpVoting.
  ///
  /// In zh, this message translates to:
  /// **'多个 Agent 投票选择最佳方案，适合决策类任务。'**
  String get collaboration_helpVoting;

  /// No description provided for @collaboration_helpPipeline.
  ///
  /// In zh, this message translates to:
  /// **'每个 Agent 处理特定阶段，适合复杂的分步任务。'**
  String get collaboration_helpPipeline;

  /// No description provided for @incoming_title.
  ///
  /// In zh, this message translates to:
  /// **'主动消息'**
  String get incoming_title;

  /// No description provided for @incoming_unreadCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条未读'**
  String incoming_unreadCount(int count);

  /// No description provided for @incoming_clearAll.
  ///
  /// In zh, this message translates to:
  /// **'清空所有消息'**
  String get incoming_clearAll;

  /// No description provided for @incoming_noMessages.
  ///
  /// In zh, this message translates to:
  /// **'暂无主动消息'**
  String get incoming_noMessages;

  /// No description provided for @incoming_noMessagesHint.
  ///
  /// In zh, this message translates to:
  /// **'当 Agent 主动联系您时，消息会显示在这里'**
  String get incoming_noMessagesHint;

  /// No description provided for @incoming_markAsRead.
  ///
  /// In zh, this message translates to:
  /// **'标记已读'**
  String get incoming_markAsRead;

  /// No description provided for @incoming_view.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get incoming_view;

  /// No description provided for @incoming_time.
  ///
  /// In zh, this message translates to:
  /// **'时间: {time}'**
  String incoming_time(String time);

  /// No description provided for @incoming_clearAllTitle.
  ///
  /// In zh, this message translates to:
  /// **'清空所有消息'**
  String get incoming_clearAllTitle;

  /// No description provided for @incoming_clearAllContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清空所有消息吗？此操作不可撤销。'**
  String get incoming_clearAllContent;

  /// No description provided for @incoming_clearButton.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get incoming_clearButton;

  /// No description provided for @incoming_justNow.
  ///
  /// In zh, this message translates to:
  /// **'刚刚'**
  String get incoming_justNow;

  /// No description provided for @incoming_minutesAgo.
  ///
  /// In zh, this message translates to:
  /// **'{minutes} 分钟前'**
  String incoming_minutesAgo(int minutes);

  /// No description provided for @incoming_hoursAgo.
  ///
  /// In zh, this message translates to:
  /// **'{hours} 小时前'**
  String incoming_hoursAgo(int hours);

  /// No description provided for @incoming_daysAgo.
  ///
  /// In zh, this message translates to:
  /// **'{days} 天前'**
  String incoming_daysAgo(int days);

  /// No description provided for @chat_noAgentSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选择 Agent'**
  String get chat_noAgentSelected;

  /// No description provided for @chat_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载消息失败: {error}'**
  String chat_loadFailed(String error);

  /// No description provided for @chat_checkingHealth.
  ///
  /// In zh, this message translates to:
  /// **'正在检查 Agent 状态...'**
  String get chat_checkingHealth;

  /// No description provided for @chat_reconnectingAttempt.
  ///
  /// In zh, this message translates to:
  /// **'正在重连… ({attempt}/{total})'**
  String chat_reconnectingAttempt(int attempt, int total);

  /// No description provided for @chat_reconnectFailed.
  ///
  /// In zh, this message translates to:
  /// **'无法连接到 Agent，请检查 Agent 是否在线。'**
  String get chat_reconnectFailed;

  /// No description provided for @chat_responseError.
  ///
  /// In zh, this message translates to:
  /// **'获取 {agentName} 的回复失败'**
  String chat_responseError(String agentName);

  /// No description provided for @chat_voiceTooShort.
  ///
  /// In zh, this message translates to:
  /// **'语音消息太短'**
  String get chat_voiceTooShort;

  /// No description provided for @chat_historyRequestTitle.
  ///
  /// In zh, this message translates to:
  /// **'Agent 请求查看更多聊天记录'**
  String get chat_historyRequestTitle;

  /// No description provided for @chat_historyIgnore.
  ///
  /// In zh, this message translates to:
  /// **'忽略'**
  String get chat_historyIgnore;

  /// No description provided for @chat_historyApprove.
  ///
  /// In zh, this message translates to:
  /// **'同意'**
  String get chat_historyApprove;

  /// No description provided for @chat_loadingHistory.
  ///
  /// In zh, this message translates to:
  /// **'正在加载更多聊天记录...'**
  String get chat_loadingHistory;

  /// No description provided for @chat_noMoreHistory.
  ///
  /// In zh, this message translates to:
  /// **'没有更多历史记录可加载'**
  String get chat_noMoreHistory;

  /// No description provided for @chat_historyLoaded.
  ///
  /// In zh, this message translates to:
  /// **'历史记录已加载，Agent 正在重新回答...'**
  String get chat_historyLoaded;

  /// No description provided for @chat_historyLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载历史记录失败: {error}'**
  String chat_historyLoadFailed(String error);

  /// No description provided for @chat_historyIgnored.
  ///
  /// In zh, this message translates to:
  /// **'已忽略历史记录请求'**
  String get chat_historyIgnored;

  /// No description provided for @chat_messageHint.
  ///
  /// In zh, this message translates to:
  /// **'输入消息...'**
  String get chat_messageHint;

  /// No description provided for @chat_holdToRecord.
  ///
  /// In zh, this message translates to:
  /// **'按住录制语音消息'**
  String get chat_holdToRecord;

  /// No description provided for @chat_holdToTalk.
  ///
  /// In zh, this message translates to:
  /// **'按住 说话'**
  String get chat_holdToTalk;

  /// No description provided for @chat_releaseToSend.
  ///
  /// In zh, this message translates to:
  /// **'松开 发送'**
  String get chat_releaseToSend;

  /// No description provided for @chat_releaseToCancel.
  ///
  /// In zh, this message translates to:
  /// **'松开 取消'**
  String get chat_releaseToCancel;

  /// No description provided for @chat_micNotAvailable.
  ///
  /// In zh, this message translates to:
  /// **'无法开始录音，麦克风可能不可用。'**
  String get chat_micNotAvailable;

  /// No description provided for @chat_photoLibrary.
  ///
  /// In zh, this message translates to:
  /// **'相册'**
  String get chat_photoLibrary;

  /// No description provided for @chat_camera.
  ///
  /// In zh, this message translates to:
  /// **'相机'**
  String get chat_camera;

  /// No description provided for @chat_file.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get chat_file;

  /// No description provided for @chat_sendImageError.
  ///
  /// In zh, this message translates to:
  /// **'发送图片失败: {error}'**
  String chat_sendImageError(String error);

  /// No description provided for @chat_sendFileError.
  ///
  /// In zh, this message translates to:
  /// **'发送文件失败: {error}'**
  String chat_sendFileError(String error);

  /// No description provided for @chat_searchError.
  ///
  /// In zh, this message translates to:
  /// **'搜索出错: {error}'**
  String chat_searchError(String error);

  /// No description provided for @chat_cannotDelete.
  ///
  /// In zh, this message translates to:
  /// **'无法删除此消息'**
  String get chat_cannotDelete;

  /// No description provided for @chat_deleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除消息'**
  String get chat_deleteTitle;

  /// No description provided for @chat_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这条消息吗？'**
  String get chat_deleteContent;

  /// No description provided for @chat_deleted.
  ///
  /// In zh, this message translates to:
  /// **'消息已删除'**
  String get chat_deleted;

  /// No description provided for @chat_rollbackTitle.
  ///
  /// In zh, this message translates to:
  /// **'回滚消息'**
  String get chat_rollbackTitle;

  /// No description provided for @chat_reEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'重新编辑消息'**
  String get chat_reEditTitle;

  /// No description provided for @chat_rollbackContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除此消息及之后的所有消息，此操作不可撤销。'**
  String get chat_rollbackContent;

  /// No description provided for @chat_rollbackSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已回滚 {count} 条消息'**
  String chat_rollbackSuccess(int count);

  /// No description provided for @chat_reEditSuccess.
  ///
  /// In zh, this message translates to:
  /// **'重新编辑消息：已回滚 {count} 条消息'**
  String chat_reEditSuccess(int count);

  /// No description provided for @chat_rollbackFailed.
  ///
  /// In zh, this message translates to:
  /// **'回滚失败: {error}'**
  String chat_rollbackFailed(String error);

  /// No description provided for @chat_copiedToClipboard.
  ///
  /// In zh, this message translates to:
  /// **'已复制到剪贴板'**
  String get chat_copiedToClipboard;

  /// No description provided for @chat_download.
  ///
  /// In zh, this message translates to:
  /// **'下载'**
  String get chat_download;

  /// No description provided for @chat_rollback.
  ///
  /// In zh, this message translates to:
  /// **'回滚'**
  String get chat_rollback;

  /// No description provided for @chat_rollbackSub.
  ///
  /// In zh, this message translates to:
  /// **'删除此消息及之后的所有消息'**
  String get chat_rollbackSub;

  /// No description provided for @chat_reEdit.
  ///
  /// In zh, this message translates to:
  /// **'重新编辑'**
  String get chat_reEdit;

  /// No description provided for @chat_reEditSub.
  ///
  /// In zh, this message translates to:
  /// **'回滚并编辑此消息'**
  String get chat_reEditSub;

  /// No description provided for @chat_editGroupInfo.
  ///
  /// In zh, this message translates to:
  /// **'编辑群组信息'**
  String get chat_editGroupInfo;

  /// No description provided for @chat_groupName.
  ///
  /// In zh, this message translates to:
  /// **'群组名称'**
  String get chat_groupName;

  /// No description provided for @chat_groupDescription.
  ///
  /// In zh, this message translates to:
  /// **'描述（可选）'**
  String get chat_groupDescription;

  /// No description provided for @chat_groupNameEmpty.
  ///
  /// In zh, this message translates to:
  /// **'群组名称不能为空'**
  String get chat_groupNameEmpty;

  /// No description provided for @chat_groupMembers.
  ///
  /// In zh, this message translates to:
  /// **'群组成员'**
  String get chat_groupMembers;

  /// No description provided for @chat_groupMembersCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个 Agent'**
  String chat_groupMembersCount(int count);

  /// No description provided for @chat_addMember.
  ///
  /// In zh, this message translates to:
  /// **'添加成员'**
  String get chat_addMember;

  /// No description provided for @chat_noMoreAgents.
  ///
  /// In zh, this message translates to:
  /// **'没有更多可添加的 Agent'**
  String get chat_noMoreAgents;

  /// No description provided for @chat_changeAdmin.
  ///
  /// In zh, this message translates to:
  /// **'更换管理员'**
  String get chat_changeAdmin;

  /// No description provided for @chat_currentAdmin.
  ///
  /// In zh, this message translates to:
  /// **'当前: {name}'**
  String chat_currentAdmin(String name);

  /// No description provided for @chat_adminChanged.
  ///
  /// In zh, this message translates to:
  /// **'{name} 已成为管理员'**
  String chat_adminChanged(String name);

  /// No description provided for @chat_removeMember.
  ///
  /// In zh, this message translates to:
  /// **'移除成员'**
  String get chat_removeMember;

  /// No description provided for @chat_removeMemberContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要将 {name} 移出群组吗？'**
  String chat_removeMemberContent(String name);

  /// No description provided for @chat_removeButton.
  ///
  /// In zh, this message translates to:
  /// **'移除'**
  String get chat_removeButton;

  /// No description provided for @chat_cannotRemoveLast.
  ///
  /// In zh, this message translates to:
  /// **'无法移除最后一个成员'**
  String get chat_cannotRemoveLast;

  /// No description provided for @chat_waitingForAction.
  ///
  /// In zh, this message translates to:
  /// **'等待你的操作'**
  String get chat_waitingForAction;

  /// No description provided for @chat_searchMessages.
  ///
  /// In zh, this message translates to:
  /// **'搜索消息'**
  String get chat_searchMessages;

  /// No description provided for @chat_newSession.
  ///
  /// In zh, this message translates to:
  /// **'新建会话'**
  String get chat_newSession;

  /// No description provided for @chat_sessionList.
  ///
  /// In zh, this message translates to:
  /// **'会话列表'**
  String get chat_sessionList;

  /// No description provided for @chat_clearSessionHistory.
  ///
  /// In zh, this message translates to:
  /// **'清除会话历史'**
  String get chat_clearSessionHistory;

  /// No description provided for @chat_clearSessionSub.
  ///
  /// In zh, this message translates to:
  /// **'清除当前会话并重置 Agent'**
  String get chat_clearSessionSub;

  /// No description provided for @chat_clearSessionSubSingle.
  ///
  /// In zh, this message translates to:
  /// **'清除当前会话并重置远端 Agent'**
  String get chat_clearSessionSubSingle;

  /// No description provided for @chat_clearAllSessions.
  ///
  /// In zh, this message translates to:
  /// **'清除所有会话'**
  String get chat_clearAllSessions;

  /// No description provided for @chat_clearAllSessionsSub.
  ///
  /// In zh, this message translates to:
  /// **'清除所有会话并重置 Agent'**
  String get chat_clearAllSessionsSub;

  /// No description provided for @chat_clearAllSessionsSubSingle.
  ///
  /// In zh, this message translates to:
  /// **'清除所有会话并重置远端 Agent'**
  String get chat_clearAllSessionsSubSingle;

  /// No description provided for @chat_resetSession.
  ///
  /// In zh, this message translates to:
  /// **'重置会话'**
  String get chat_resetSession;

  /// No description provided for @chat_editAgent.
  ///
  /// In zh, this message translates to:
  /// **'编辑 Agent'**
  String get chat_editAgent;

  /// No description provided for @chat_viewDetails.
  ///
  /// In zh, this message translates to:
  /// **'查看详情'**
  String get chat_viewDetails;

  /// No description provided for @chat_customSystemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'自定义系统提示词'**
  String get chat_customSystemPrompt;

  /// No description provided for @chat_systemPromptTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义系统提示词'**
  String get chat_systemPromptTitle;

  /// No description provided for @chat_systemPromptHint.
  ///
  /// In zh, this message translates to:
  /// **'为本会话覆盖 Agent 的系统提示词'**
  String get chat_systemPromptHint;

  /// No description provided for @chat_systemPromptSaved.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词已保存'**
  String get chat_systemPromptSaved;

  /// No description provided for @chat_moreActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get chat_moreActions;

  /// No description provided for @chat_clearSessionTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除会话历史'**
  String get chat_clearSessionTitle;

  /// No description provided for @chat_clearSessionContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除当前会话的所有消息并重置远端 Agent 连接，此操作不可撤销。'**
  String get chat_clearSessionContent;

  /// No description provided for @chat_clearSessionGroupContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除当前会话的所有消息并重置所有 Agent 连接，此操作不可撤销。'**
  String get chat_clearSessionGroupContent;

  /// No description provided for @chat_sessionCleared.
  ///
  /// In zh, this message translates to:
  /// **'会话历史已清除'**
  String get chat_sessionCleared;

  /// No description provided for @chat_clearSessionFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除会话失败: {error}'**
  String chat_clearSessionFailed(String error);

  /// No description provided for @chat_clearAllSessionsTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除所有会话'**
  String get chat_clearAllSessionsTitle;

  /// No description provided for @chat_clearAllSessionsContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除所有会话及其消息，仅保留默认会话，此操作不可撤销。'**
  String get chat_clearAllSessionsContent;

  /// No description provided for @chat_clearAllGroupSessionsContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除此群组的所有会话及其消息，仅保留默认会话，此操作不可撤销。'**
  String get chat_clearAllGroupSessionsContent;

  /// No description provided for @chat_allSessionsCleared.
  ///
  /// In zh, this message translates to:
  /// **'所有会话历史已清除'**
  String get chat_allSessionsCleared;

  /// No description provided for @chat_allGroupSessionsCleared.
  ///
  /// In zh, this message translates to:
  /// **'所有群组会话已清除'**
  String get chat_allGroupSessionsCleared;

  /// No description provided for @chat_groupSessionCleared.
  ///
  /// In zh, this message translates to:
  /// **'群组会话历史已清除'**
  String get chat_groupSessionCleared;

  /// No description provided for @chat_clearGroupSessionFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除群组会话失败: {error}'**
  String chat_clearGroupSessionFailed(String error);

  /// No description provided for @chat_clearAllGroupSessionsFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除所有群组会话失败: {error}'**
  String chat_clearAllGroupSessionsFailed(String error);

  /// No description provided for @chat_clearingSession.
  ///
  /// In zh, this message translates to:
  /// **'正在清除会话...'**
  String get chat_clearingSession;

  /// No description provided for @chat_clearingAllSessions.
  ///
  /// In zh, this message translates to:
  /// **'正在清除所有会话...'**
  String get chat_clearingAllSessions;

  /// No description provided for @chat_clearingGroupSession.
  ///
  /// In zh, this message translates to:
  /// **'正在清除群组会话...'**
  String get chat_clearingGroupSession;

  /// No description provided for @chat_clearingAllGroupSessions.
  ///
  /// In zh, this message translates to:
  /// **'正在清除所有群组会话...'**
  String get chat_clearingAllGroupSessions;

  /// No description provided for @chat_noAdminSet.
  ///
  /// In zh, this message translates to:
  /// **'未设置管理员'**
  String get chat_noAdminSet;

  /// No description provided for @chat_groupSessions.
  ///
  /// In zh, this message translates to:
  /// **'群组会话'**
  String get chat_groupSessions;

  /// No description provided for @chat_sessions.
  ///
  /// In zh, this message translates to:
  /// **'会话'**
  String get chat_sessions;

  /// No description provided for @chat_sessionsCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个会话'**
  String chat_sessionsCount(int count);

  /// No description provided for @chat_mentionAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get chat_mentionAll;

  /// No description provided for @chat_mentionAllSub.
  ///
  /// In zh, this message translates to:
  /// **'提及全部 {count} 个 Agent'**
  String chat_mentionAllSub(int count);

  /// No description provided for @chat_mentionNotify.
  ///
  /// In zh, this message translates to:
  /// **'通知 TA（触发回复）'**
  String get chat_mentionNotify;

  /// No description provided for @chat_mentionCcOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅提及（不触发回复）'**
  String get chat_mentionCcOnly;

  /// No description provided for @chat_add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get chat_add;

  /// No description provided for @chat_groupDescriptionOptional.
  ///
  /// In zh, this message translates to:
  /// **'描述（可选）'**
  String get chat_groupDescriptionOptional;

  /// No description provided for @chat_groupSystemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词（可选）'**
  String get chat_groupSystemPrompt;

  /// No description provided for @chat_groupSystemPromptHint.
  ///
  /// In zh, this message translates to:
  /// **'为群内 Agent 定义约束或指令'**
  String get chat_groupSystemPromptHint;

  /// No description provided for @chat_switchSession.
  ///
  /// In zh, this message translates to:
  /// **'会话已清除，切换至 {sessionId}'**
  String chat_switchSession(String sessionId);

  /// No description provided for @chat_allSessionsSwitched.
  ///
  /// In zh, this message translates to:
  /// **'所有会话已清除，切换至 {sessionId}'**
  String chat_allSessionsSwitched(String sessionId);

  /// No description provided for @chat_clearAllSessionsFailed.
  ///
  /// In zh, this message translates to:
  /// **'清除所有会话失败: {error}'**
  String chat_clearAllSessionsFailed(String error);

  /// No description provided for @chat_deleteSession.
  ///
  /// In zh, this message translates to:
  /// **'删除会话'**
  String get chat_deleteSession;

  /// No description provided for @chat_deleteSessionContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除此会话及其所有消息，此操作不可撤销。'**
  String get chat_deleteSessionContent;

  /// No description provided for @chat_deleteAllSessions.
  ///
  /// In zh, this message translates to:
  /// **'删除所有会话'**
  String get chat_deleteAllSessions;

  /// No description provided for @chat_deleteAllSessionsContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除所有会话及其消息，仅保留默认会话，此操作不可撤销。'**
  String get chat_deleteAllSessionsContent;

  /// No description provided for @chat_deleteAllGroupSessionsContent.
  ///
  /// In zh, this message translates to:
  /// **'这将删除此群组的所有会话及其消息，仅保留默认会话，此操作不可撤销。'**
  String get chat_deleteAllGroupSessionsContent;

  /// No description provided for @chat_newSessionFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建新会话失败: {error}'**
  String chat_newSessionFailed(String error);

  /// No description provided for @chat_newGroupSessionFailed.
  ///
  /// In zh, this message translates to:
  /// **'创建新群组会话失败: {error}'**
  String chat_newGroupSessionFailed(String error);

  /// No description provided for @chat_loadSessionsFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载会话失败: {error}'**
  String chat_loadSessionsFailed(String error);

  /// No description provided for @chat_loadGroupSessionsFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载群组会话失败: {error}'**
  String chat_loadGroupSessionsFailed(String error);

  /// No description provided for @chat_groupRoleTitle.
  ///
  /// In zh, this message translates to:
  /// **'{name} - 群组角色'**
  String chat_groupRoleTitle(String name);

  /// No description provided for @chat_groupCapabilityLabel.
  ///
  /// In zh, this message translates to:
  /// **'群组能力描述'**
  String get chat_groupCapabilityLabel;

  /// No description provided for @chat_groupCapabilityHint.
  ///
  /// In zh, this message translates to:
  /// **'留空则使用 Agent 的默认描述'**
  String get chat_groupCapabilityHint;

  /// No description provided for @chat_resetButton.
  ///
  /// In zh, this message translates to:
  /// **'重置'**
  String get chat_resetButton;

  /// No description provided for @chat_stopped.
  ///
  /// In zh, this message translates to:
  /// **'已停止'**
  String get chat_stopped;

  /// No description provided for @chat_groupChatError.
  ///
  /// In zh, this message translates to:
  /// **'群聊出错: {error}'**
  String chat_groupChatError(String error);

  /// No description provided for @chat_fileMessageFailed.
  ///
  /// In zh, this message translates to:
  /// **'文件消息失败: {error}'**
  String chat_fileMessageFailed(String error);

  /// No description provided for @status_online.
  ///
  /// In zh, this message translates to:
  /// **'在线'**
  String get status_online;

  /// No description provided for @status_offline.
  ///
  /// In zh, this message translates to:
  /// **'离线'**
  String get status_offline;

  /// No description provided for @status_connecting.
  ///
  /// In zh, this message translates to:
  /// **'连接中...'**
  String get status_connecting;

  /// No description provided for @status_error.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get status_error;

  /// No description provided for @status_protocolAcp.
  ///
  /// In zh, this message translates to:
  /// **'ACP'**
  String get status_protocolAcp;

  /// No description provided for @status_protocolCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get status_protocolCustom;

  /// No description provided for @widget_typing.
  ///
  /// In zh, this message translates to:
  /// **'正在输入...'**
  String get widget_typing;

  /// No description provided for @widget_stop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get widget_stop;

  /// No description provided for @widget_cannotOpenLink.
  ///
  /// In zh, this message translates to:
  /// **'无法打开链接: {url}'**
  String widget_cannotOpenLink(String url);

  /// No description provided for @widget_originalMessageUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'原消息不可用'**
  String get widget_originalMessageUnavailable;

  /// No description provided for @widget_retry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get widget_retry;

  /// No description provided for @widget_formSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'表单已提交'**
  String get widget_formSubmitted;

  /// No description provided for @widget_submit.
  ///
  /// In zh, this message translates to:
  /// **'提交'**
  String get widget_submit;

  /// No description provided for @widget_confirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get widget_confirm;

  /// No description provided for @widget_changeFiles.
  ///
  /// In zh, this message translates to:
  /// **'更换文件'**
  String get widget_changeFiles;

  /// No description provided for @widget_details.
  ///
  /// In zh, this message translates to:
  /// **'详情'**
  String get widget_details;

  /// No description provided for @privacy_title.
  ///
  /// In zh, this message translates to:
  /// **'隐私政策'**
  String get privacy_title;

  /// No description provided for @privacy_content.
  ///
  /// In zh, this message translates to:
  /// **'隐私政策\n\n最后更新：2026-02-28\n\nPaw（以下简称“我们”）致力于保护您的隐私。Paw 是一款完全本地化的应用程序，我们不会收集、上传或存储您的任何个人数据。您的所有数据始终保留在您的设备上，完全由您掌控。\n\n1. 数据存储\n\nPaw 不设有服务器，不收集任何用户数据。您在使用过程中产生的所有数据，包括：\n- 账户凭证\n- Agent 配置数据\n- 聊天消息和对话历史记录\n\n均仅存储在您的设备本地，我们无法也不会访问这些数据。\n\n2. 数据安全\n\n我们通过以下措施保护您的本地数据安全：\n- 本地数据加密\n- 安全的 WebSocket 连接（WSS）用于远程通信\n- 生物识别认证支持\n- 密码保护访问\n\n3. 第三方服务\n\n当您主动配置并连接远端 AI Agent 时，您的消息将直接在您的设备和您配置的 Agent 端点之间传输，不经过我们的任何服务器。我们不对第三方 Agent 服务的数据处理行为负责。\n\n4. 您的权利\n\n由于所有数据均存储在您的设备本地，您可以随时：\n- 查看您的所有数据\n- 通过清除应用数据或卸载应用来彻底删除数据\n- 使用应用内导出功能导出数据\n\n5. 政策变更\n\n我们可能会不时更新本隐私政策。我们将通过更新“最后更新”日期来通知您任何变更。\n\n6. 联系我们\n\n如果您对本隐私政策有任何疑问，请通过以下方式联系我们：\nsupport@metamessager.com'**
  String get privacy_content;

  /// No description provided for @terms_title.
  ///
  /// In zh, this message translates to:
  /// **'服务条款'**
  String get terms_title;

  /// No description provided for @terms_content.
  ///
  /// In zh, this message translates to:
  /// **'服务条款\n\n最后更新：2026-02-28\n\n请在使用 Paw 应用程序之前仔细阅读这些服务条款。\n\n1. 条款接受\n\n访问或使用 Paw 即表示您同意受这些条款的约束。如果您不同意，请勿使用本应用程序。\n\n2. 服务描述\n\nPaw 是一个 AI Agent 管理平台，允许您：\n- 连接和与 AI Agent 通信\n- 管理多个 Agent 配置\n- 促进 Agent 之间的协作\n- 与 Agent 传输文件和媒体\n\n3. 用户责任\n\n您同意：\n- 遵守所有适用法律使用本应用\n- 不将本应用用于任何非法或未经授权的目的\n- 不试图干扰应用的功能\n- 对您的账户凭证安全负责\n- 对您通过应用发送的内容负责\n\n4. 知识产权\n\n本应用及其原创内容、功能和特性归我们所有，受国际版权、商标和其他知识产权法律保护。\n\n5. 第三方 Agent 服务\n\n我们的应用允许您连接第三方 AI Agent 服务。我们不控制这些服务，也不对其内容、隐私政策或实践负责。\n\n6. 免责声明\n\n本应用按“原样”提供，不提供任何形式的保证。我们不保证应用会不间断、安全或无错误地运行。\n\n7. 责任限制\n\n在任何情况下，我们均不对因您使用本应用而产生的任何间接、偶发、特殊、后果性或惩罚性损害承担责任。\n\n8. 条款变更\n\n我们保留随时修改这些条款的权利。您在变更后继续使用应用即表示接受新条款。\n\n9. 联系我们\n\n如果您对这些条款有任何疑问，请通过以下方式联系我们：\nsupport@metamessager.com'**
  String get terms_content;

  /// No description provided for @notif_enableAll.
  ///
  /// In zh, this message translates to:
  /// **'启用通知'**
  String get notif_enableAll;

  /// No description provided for @notif_enableAllSub.
  ///
  /// In zh, this message translates to:
  /// **'接收 Agent 消息通知'**
  String get notif_enableAllSub;

  /// No description provided for @notif_sound.
  ///
  /// In zh, this message translates to:
  /// **'声音'**
  String get notif_sound;

  /// No description provided for @notif_soundSub.
  ///
  /// In zh, this message translates to:
  /// **'通知时播放提示音'**
  String get notif_soundSub;

  /// No description provided for @notif_showPreview.
  ///
  /// In zh, this message translates to:
  /// **'显示预览'**
  String get notif_showPreview;

  /// No description provided for @notif_showPreviewSub.
  ///
  /// In zh, this message translates to:
  /// **'在通知中显示消息内容'**
  String get notif_showPreviewSub;

  /// No description provided for @notif_permissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'通知权限被拒绝，请在系统设置中开启。'**
  String get notif_permissionDenied;

  /// No description provided for @notif_newMessage.
  ///
  /// In zh, this message translates to:
  /// **'新消息'**
  String get notif_newMessage;

  /// No description provided for @notif_newMessageFrom.
  ///
  /// In zh, this message translates to:
  /// **'来自 {name} 的新消息'**
  String notif_newMessageFrom(String name);

  /// No description provided for @osTool_configTitle.
  ///
  /// In zh, this message translates to:
  /// **'CLI 管理'**
  String get osTool_configTitle;

  /// No description provided for @osTool_configHint.
  ///
  /// In zh, this message translates to:
  /// **'启用 OS 级别工具，让 Agent 可以操作您的本地设备（文件、命令、剪贴板等）。'**
  String get osTool_configHint;

  /// No description provided for @osTool_selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get osTool_selectAll;

  /// No description provided for @osTool_deselectAll.
  ///
  /// In zh, this message translates to:
  /// **'全不选'**
  String get osTool_deselectAll;

  /// No description provided for @osTool_catCommand.
  ///
  /// In zh, this message translates to:
  /// **'命令与系统'**
  String get osTool_catCommand;

  /// No description provided for @osTool_catFile.
  ///
  /// In zh, this message translates to:
  /// **'文件操作'**
  String get osTool_catFile;

  /// No description provided for @osTool_catApp.
  ///
  /// In zh, this message translates to:
  /// **'应用与浏览器'**
  String get osTool_catApp;

  /// No description provided for @osTool_catClipboard.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板'**
  String get osTool_catClipboard;

  /// No description provided for @osTool_catMacos.
  ///
  /// In zh, this message translates to:
  /// **'macOS 专属'**
  String get osTool_catMacos;

  /// No description provided for @osTool_catProcess.
  ///
  /// In zh, this message translates to:
  /// **'进程管理'**
  String get osTool_catProcess;

  /// No description provided for @osTool_notSupported.
  ///
  /// In zh, this message translates to:
  /// **'当前平台 ({platform}) 不支持'**
  String osTool_notSupported(String platform);

  /// No description provided for @osTool_confirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认操作'**
  String get osTool_confirmTitle;

  /// No description provided for @osTool_confirmDescription.
  ///
  /// In zh, this message translates to:
  /// **'此操作将在您的设备上执行。是否继续？'**
  String get osTool_confirmDescription;

  /// No description provided for @osTool_highRisk.
  ///
  /// In zh, this message translates to:
  /// **'高风险'**
  String get osTool_highRisk;

  /// No description provided for @osTool_tool.
  ///
  /// In zh, this message translates to:
  /// **'工具'**
  String get osTool_tool;

  /// No description provided for @osTool_approve.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get osTool_approve;

  /// No description provided for @osTool_deny.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get osTool_deny;

  /// No description provided for @skill_configTitle.
  ///
  /// In zh, this message translates to:
  /// **'技能'**
  String get skill_configTitle;

  /// No description provided for @skill_configHint.
  ///
  /// In zh, this message translates to:
  /// **'启用基于 Markdown 的技能，引导 Agent 完成复杂的多步骤任务。'**
  String get skill_configHint;

  /// No description provided for @skill_selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get skill_selectAll;

  /// No description provided for @skill_deselectAll.
  ///
  /// In zh, this message translates to:
  /// **'全不选'**
  String get skill_deselectAll;

  /// No description provided for @skill_rescan.
  ///
  /// In zh, this message translates to:
  /// **'重新扫描'**
  String get skill_rescan;

  /// No description provided for @skill_noSkillsFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到技能。可导入技能 ZIP 包或将技能子目录添加到技能文件夹。'**
  String get skill_noSkillsFound;

  /// No description provided for @settings_agentConfig.
  ///
  /// In zh, this message translates to:
  /// **'Agent 配置'**
  String get settings_agentConfig;

  /// No description provided for @settings_skillDirectory.
  ///
  /// In zh, this message translates to:
  /// **'技能管理'**
  String get settings_skillDirectory;

  /// No description provided for @skillMgmt_title.
  ///
  /// In zh, this message translates to:
  /// **'技能管理'**
  String get skillMgmt_title;

  /// No description provided for @skillMgmt_importZip.
  ///
  /// In zh, this message translates to:
  /// **'导入技能 (ZIP)'**
  String get skillMgmt_importZip;

  /// No description provided for @skillMgmt_importing.
  ///
  /// In zh, this message translates to:
  /// **'正在导入技能...'**
  String get skillMgmt_importing;

  /// No description provided for @skillMgmt_importSuccess.
  ///
  /// In zh, this message translates to:
  /// **'技能「{name}」导入成功'**
  String skillMgmt_importSuccess(String name);

  /// No description provided for @skillMgmt_importFailed.
  ///
  /// In zh, this message translates to:
  /// **'导入失败: {error}'**
  String skillMgmt_importFailed(String error);

  /// No description provided for @skillMgmt_deleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除技能'**
  String get skillMgmt_deleteTitle;

  /// No description provided for @skillMgmt_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除技能「{name}」吗？这将删除技能目录中的所有文件，且不可恢复。'**
  String skillMgmt_deleteContent(String name);

  /// No description provided for @skillMgmt_deleted.
  ///
  /// In zh, this message translates to:
  /// **'技能「{name}」已删除'**
  String skillMgmt_deleted(String name);

  /// No description provided for @skillMgmt_deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除失败: {error}'**
  String skillMgmt_deleteFailed(String error);

  /// No description provided for @skillMgmt_noSkills.
  ///
  /// In zh, this message translates to:
  /// **'未找到技能'**
  String get skillMgmt_noSkills;

  /// No description provided for @skillMgmt_noSkillsHint.
  ///
  /// In zh, this message translates to:
  /// **'导入技能 ZIP 包，或将技能子目录添加到配置的目录中。'**
  String get skillMgmt_noSkillsHint;

  /// No description provided for @skillMgmt_fileCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 个文件}}'**
  String skillMgmt_fileCount(int count);

  /// No description provided for @skillMgmt_skillCount.
  ///
  /// In zh, this message translates to:
  /// **'{count, plural, other{{count} 个技能}}'**
  String skillMgmt_skillCount(int count);

  /// No description provided for @skillMgmt_conflictTitle.
  ///
  /// In zh, this message translates to:
  /// **'技能已存在'**
  String get skillMgmt_conflictTitle;

  /// No description provided for @skillMgmt_conflictContent.
  ///
  /// In zh, this message translates to:
  /// **'名为「{name}」的技能已存在。是否替换？'**
  String skillMgmt_conflictContent(String name);

  /// No description provided for @skillMgmt_replace.
  ///
  /// In zh, this message translates to:
  /// **'替换'**
  String get skillMgmt_replace;

  /// No description provided for @skillMgmt_rescan.
  ///
  /// In zh, this message translates to:
  /// **'重新扫描'**
  String get skillMgmt_rescan;

  /// No description provided for @skillMgmt_openDirectory.
  ///
  /// In zh, this message translates to:
  /// **'打开技能目录'**
  String get skillMgmt_openDirectory;

  /// No description provided for @skillMgmt_importUrl.
  ///
  /// In zh, this message translates to:
  /// **'从 URL 导入'**
  String get skillMgmt_importUrl;

  /// No description provided for @skillMgmt_importUrlTitle.
  ///
  /// In zh, this message translates to:
  /// **'从 URL 导入技能'**
  String get skillMgmt_importUrlTitle;

  /// No description provided for @skillMgmt_importUrlHint.
  ///
  /// In zh, this message translates to:
  /// **'输入 .zip 或 .md 文件的直链 URL'**
  String get skillMgmt_importUrlHint;

  /// No description provided for @skillMgmt_downloading.
  ///
  /// In zh, this message translates to:
  /// **'下载中... {percent}%'**
  String skillMgmt_downloading(int percent);

  /// No description provided for @skillMgmt_downloadingIndeterminate.
  ///
  /// In zh, this message translates to:
  /// **'下载中...'**
  String get skillMgmt_downloadingIndeterminate;

  /// No description provided for @skillMgmt_invalidUrl.
  ///
  /// In zh, this message translates to:
  /// **'URL 无效，请输入 .zip 或 .md 文件的 http/https 直链'**
  String get skillMgmt_invalidUrl;

  /// No description provided for @agentDetail_noOsToolsEnabled.
  ///
  /// In zh, this message translates to:
  /// **'未启用任何 OS 工具'**
  String get agentDetail_noOsToolsEnabled;

  /// No description provided for @agentDetail_noSkillsEnabled.
  ///
  /// In zh, this message translates to:
  /// **'未启用任何技能'**
  String get agentDetail_noSkillsEnabled;

  /// No description provided for @settings_developerTools.
  ///
  /// In zh, this message translates to:
  /// **'开发者工具'**
  String get settings_developerTools;

  /// No description provided for @settings_inferenceLog.
  ///
  /// In zh, this message translates to:
  /// **'推理日志'**
  String get settings_inferenceLog;

  /// No description provided for @settings_inferenceLogSub.
  ///
  /// In zh, this message translates to:
  /// **'查看 LLM 请求/响应详情'**
  String get settings_inferenceLogSub;

  /// No description provided for @settings_systemLog.
  ///
  /// In zh, this message translates to:
  /// **'系统日志'**
  String get settings_systemLog;

  /// No description provided for @settings_systemLogSub.
  ///
  /// In zh, this message translates to:
  /// **'查看应用系统日志'**
  String get settings_systemLogSub;

  /// No description provided for @inferenceLog_title.
  ///
  /// In zh, this message translates to:
  /// **'推理日志'**
  String get inferenceLog_title;

  /// No description provided for @inferenceLog_empty.
  ///
  /// In zh, this message translates to:
  /// **'暂无推理日志'**
  String get inferenceLog_empty;

  /// No description provided for @inferenceLog_emptyHint.
  ///
  /// In zh, this message translates to:
  /// **'与本地 LLM Agent 对话后，日志将显示在这里'**
  String get inferenceLog_emptyHint;

  /// No description provided for @inferenceLog_filterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get inferenceLog_filterAll;

  /// No description provided for @inferenceLog_filterCompleted.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get inferenceLog_filterCompleted;

  /// No description provided for @inferenceLog_filterError.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get inferenceLog_filterError;

  /// No description provided for @inferenceLog_filterInProgress.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get inferenceLog_filterInProgress;

  /// No description provided for @inferenceLog_total.
  ///
  /// In zh, this message translates to:
  /// **'总计'**
  String get inferenceLog_total;

  /// No description provided for @inferenceLog_completed.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get inferenceLog_completed;

  /// No description provided for @inferenceLog_errors.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get inferenceLog_errors;

  /// No description provided for @inferenceLog_inProgress.
  ///
  /// In zh, this message translates to:
  /// **'进行中'**
  String get inferenceLog_inProgress;

  /// No description provided for @inferenceLog_rounds.
  ///
  /// In zh, this message translates to:
  /// **'{count} 轮'**
  String inferenceLog_rounds(int count);

  /// No description provided for @inferenceLog_toolCalls.
  ///
  /// In zh, this message translates to:
  /// **'{count} 次工具调用'**
  String inferenceLog_toolCalls(int count);

  /// No description provided for @inferenceLog_clearTitle.
  ///
  /// In zh, this message translates to:
  /// **'清除推理日志'**
  String get inferenceLog_clearTitle;

  /// No description provided for @inferenceLog_clearContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要清除所有推理日志吗？此操作不可恢复。'**
  String get inferenceLog_clearContent;

  /// No description provided for @inferenceLog_clearButton.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get inferenceLog_clearButton;

  /// No description provided for @inferenceLog_cleared.
  ///
  /// In zh, this message translates to:
  /// **'推理日志已清除'**
  String get inferenceLog_cleared;

  /// No description provided for @inferenceLog_exported.
  ///
  /// In zh, this message translates to:
  /// **'推理日志已导出'**
  String get inferenceLog_exported;

  /// No description provided for @inferenceLog_exportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败: {error}'**
  String inferenceLog_exportFailed(String error);

  /// No description provided for @inferenceLog_loggingEnabled.
  ///
  /// In zh, this message translates to:
  /// **'推理日志记录已启用'**
  String get inferenceLog_loggingEnabled;

  /// No description provided for @inferenceLog_loggingDisabled.
  ///
  /// In zh, this message translates to:
  /// **'推理日志记录已关闭'**
  String get inferenceLog_loggingDisabled;

  /// No description provided for @inferenceLog_userMessage.
  ///
  /// In zh, this message translates to:
  /// **'用户消息'**
  String get inferenceLog_userMessage;

  /// No description provided for @inferenceLog_systemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词'**
  String get inferenceLog_systemPrompt;

  /// No description provided for @inferenceLog_roundLabel.
  ///
  /// In zh, this message translates to:
  /// **'第 {number} 轮'**
  String inferenceLog_roundLabel(int number);

  /// No description provided for @inferenceLog_response.
  ///
  /// In zh, this message translates to:
  /// **'响应'**
  String get inferenceLog_response;

  /// No description provided for @inferenceLog_toolCall.
  ///
  /// In zh, this message translates to:
  /// **'工具调用: {name}'**
  String inferenceLog_toolCall(String name);

  /// No description provided for @inferenceLog_toolResult.
  ///
  /// In zh, this message translates to:
  /// **'工具结果: {name}'**
  String inferenceLog_toolResult(String name);

  /// No description provided for @inferenceLog_stopReason.
  ///
  /// In zh, this message translates to:
  /// **'停止原因'**
  String get inferenceLog_stopReason;

  /// No description provided for @inferenceLog_error.
  ///
  /// In zh, this message translates to:
  /// **'错误'**
  String get inferenceLog_error;

  /// No description provided for @inferenceLog_detailTitle.
  ///
  /// In zh, this message translates to:
  /// **'推理详情'**
  String get inferenceLog_detailTitle;

  /// No description provided for @inferenceLog_timeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get inferenceLog_timeline;

  /// No description provided for @inferenceLog_noText.
  ///
  /// In zh, this message translates to:
  /// **'（无文本）'**
  String get inferenceLog_noText;

  /// No description provided for @chat_selectSessions.
  ///
  /// In zh, this message translates to:
  /// **'选择会话'**
  String get chat_selectSessions;

  /// No description provided for @chat_selectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 个'**
  String chat_selectedCount(int count);

  /// No description provided for @chat_invertSelection.
  ///
  /// In zh, this message translates to:
  /// **'反选'**
  String get chat_invertSelection;

  /// No description provided for @chat_deleteSelected.
  ///
  /// In zh, this message translates to:
  /// **'删除 ({count})'**
  String chat_deleteSelected(int count);

  /// No description provided for @chat_batchDeleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定删除 {count} 个会话及其所有消息？此操作不可撤销。'**
  String chat_batchDeleteContent(int count);

  /// No description provided for @chat_batchDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已删除 {count} 个会话'**
  String chat_batchDeleteSuccess(int count);

  /// No description provided for @chat_maxAttachments.
  ///
  /// In zh, this message translates to:
  /// **'最多只能添加 {count} 个附件'**
  String chat_maxAttachments(int count);

  /// No description provided for @chat_connectionInterrupted.
  ///
  /// In zh, this message translates to:
  /// **'后台运行期间连接中断'**
  String get chat_connectionInterrupted;

  /// No description provided for @chat_connectionInterruptedRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get chat_connectionInterruptedRetry;

  /// No description provided for @chat_loopRoundLimitReached.
  ///
  /// In zh, this message translates to:
  /// **'编排循环已达到最大轮次 {count} 次，已自动停止。'**
  String chat_loopRoundLimitReached(int count);

  /// No description provided for @modelRouting_title.
  ///
  /// In zh, this message translates to:
  /// **'多模态模型路由'**
  String get modelRouting_title;

  /// No description provided for @modelRouting_hint.
  ///
  /// In zh, this message translates to:
  /// **'为不同内容类型配置不同的模型，未配置的项使用上方的默认模型。'**
  String get modelRouting_hint;

  /// No description provided for @modelRouting_text.
  ///
  /// In zh, this message translates to:
  /// **'文本聊天'**
  String get modelRouting_text;

  /// No description provided for @modelRouting_image.
  ///
  /// In zh, this message translates to:
  /// **'图片理解'**
  String get modelRouting_image;

  /// No description provided for @modelRouting_audio.
  ///
  /// In zh, this message translates to:
  /// **'音频理解'**
  String get modelRouting_audio;

  /// No description provided for @modelRouting_video.
  ///
  /// In zh, this message translates to:
  /// **'视频理解'**
  String get modelRouting_video;

  /// No description provided for @modelRouting_modelHint.
  ///
  /// In zh, this message translates to:
  /// **'模型名称（留空则继承默认）'**
  String get modelRouting_modelHint;

  /// No description provided for @modelRouting_providerHint.
  ///
  /// In zh, this message translates to:
  /// **'服务商（留空则继承默认）'**
  String get modelRouting_providerHint;

  /// No description provided for @modelRouting_apiBaseHint.
  ///
  /// In zh, this message translates to:
  /// **'API Base（留空则继承默认）'**
  String get modelRouting_apiBaseHint;

  /// No description provided for @modelRouting_apiKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'API Key（留空则继承默认）'**
  String get modelRouting_apiKeyHint;

  /// No description provided for @modelRouting_advanced.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get modelRouting_advanced;

  /// No description provided for @modelRouting_selectFromRegistry.
  ///
  /// In zh, this message translates to:
  /// **'从模型列表选择'**
  String get modelRouting_selectFromRegistry;

  /// No description provided for @modelRouting_usingDefault.
  ///
  /// In zh, this message translates to:
  /// **'使用默认模型'**
  String get modelRouting_usingDefault;

  /// No description provided for @modelRouting_configured.
  ///
  /// In zh, this message translates to:
  /// **'已配置'**
  String get modelRouting_configured;

  /// No description provided for @modelRouting_enableStreaming.
  ///
  /// In zh, this message translates to:
  /// **'启用流式传输 (SSE)'**
  String get modelRouting_enableStreaming;

  /// No description provided for @modelRouting_apiPath.
  ///
  /// In zh, this message translates to:
  /// **'API 路径'**
  String get modelRouting_apiPath;

  /// No description provided for @modelRouting_apiPathHint.
  ///
  /// In zh, this message translates to:
  /// **'覆盖端点路径（如 /images/generations）'**
  String get modelRouting_apiPathHint;

  /// No description provided for @modelRouting_requestBodyTemplate.
  ///
  /// In zh, this message translates to:
  /// **'请求体模板'**
  String get modelRouting_requestBodyTemplate;

  /// No description provided for @modelRouting_requestBodyTemplateHint.
  ///
  /// In zh, this message translates to:
  /// **'JSON 模板，支持 \$model、\$prompt 变量替换'**
  String get modelRouting_requestBodyTemplateHint;

  /// No description provided for @modelRouting_responseBodyPath.
  ///
  /// In zh, this message translates to:
  /// **'响应提取路径'**
  String get modelRouting_responseBodyPath;

  /// No description provided for @modelRouting_responseBodyPathHint.
  ///
  /// In zh, this message translates to:
  /// **'JSON 路径提取内容（如 data[0].url）'**
  String get modelRouting_responseBodyPathHint;

  /// No description provided for @modelRouting_customModalities.
  ///
  /// In zh, this message translates to:
  /// **'自定义模态'**
  String get modelRouting_customModalities;

  /// No description provided for @modelRouting_customModalitiesHint.
  ///
  /// In zh, this message translates to:
  /// **'定义自定义任务类型，通过意图识别自动路由'**
  String get modelRouting_customModalitiesHint;

  /// No description provided for @modelRouting_addCustomModality.
  ///
  /// In zh, this message translates to:
  /// **'添加自定义模态'**
  String get modelRouting_addCustomModality;

  /// No description provided for @modelRouting_modalityKey.
  ///
  /// In zh, this message translates to:
  /// **'标识符'**
  String get modelRouting_modalityKey;

  /// No description provided for @modelRouting_modalityKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'如 image_gen、tts'**
  String get modelRouting_modalityKeyHint;

  /// No description provided for @modelRouting_modalityLabel.
  ///
  /// In zh, this message translates to:
  /// **'显示名称'**
  String get modelRouting_modalityLabel;

  /// No description provided for @modelRouting_modalityLabelHint.
  ///
  /// In zh, this message translates to:
  /// **'如 图片生成'**
  String get modelRouting_modalityLabelHint;

  /// No description provided for @modelRouting_modalityDescription.
  ///
  /// In zh, this message translates to:
  /// **'意图描述'**
  String get modelRouting_modalityDescription;

  /// No description provided for @modelRouting_modalityDescriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'描述何时使用此模态（用于意图分类）'**
  String get modelRouting_modalityDescriptionHint;

  /// No description provided for @modelRouting_deleteModality.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get modelRouting_deleteModality;

  /// No description provided for @addAgent_osToolsCount.
  ///
  /// In zh, this message translates to:
  /// **'已启用 {count} 个工具'**
  String addAgent_osToolsCount(int count);

  /// No description provided for @addAgent_noOsTools.
  ///
  /// In zh, this message translates to:
  /// **'未选择工具'**
  String get addAgent_noOsTools;

  /// No description provided for @addAgent_skillsCount.
  ///
  /// In zh, this message translates to:
  /// **'已启用 {count} 个技能'**
  String addAgent_skillsCount(int count);

  /// No description provided for @addAgent_noSkills.
  ///
  /// In zh, this message translates to:
  /// **'未选择技能'**
  String get addAgent_noSkills;

  /// No description provided for @addAgent_modelRoutingCount.
  ///
  /// In zh, this message translates to:
  /// **'已配置 {count} 个模态'**
  String addAgent_modelRoutingCount(int count);

  /// No description provided for @addAgent_noModelRouting.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get addAgent_noModelRouting;

  /// No description provided for @addAgent_configureTools.
  ///
  /// In zh, this message translates to:
  /// **'配置工具'**
  String get addAgent_configureTools;

  /// No description provided for @addAgent_configureSkills.
  ///
  /// In zh, this message translates to:
  /// **'配置技能'**
  String get addAgent_configureSkills;

  /// No description provided for @addAgent_configureModelRouting.
  ///
  /// In zh, this message translates to:
  /// **'配置模型路由'**
  String get addAgent_configureModelRouting;

  /// No description provided for @contacts_title.
  ///
  /// In zh, this message translates to:
  /// **'通讯录'**
  String get contacts_title;

  /// No description provided for @contacts_agents.
  ///
  /// In zh, this message translates to:
  /// **'Agent'**
  String get contacts_agents;

  /// No description provided for @contacts_groups.
  ///
  /// In zh, this message translates to:
  /// **'群组'**
  String get contacts_groups;

  /// No description provided for @contacts_noAgents.
  ///
  /// In zh, this message translates to:
  /// **'暂无 Agent'**
  String get contacts_noAgents;

  /// No description provided for @contacts_noGroups.
  ///
  /// In zh, this message translates to:
  /// **'暂无群组'**
  String get contacts_noGroups;

  /// No description provided for @contacts_agentCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个 Agent'**
  String contacts_agentCount(int count);

  /// No description provided for @contacts_groupCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个群组'**
  String contacts_groupCount(int count);

  /// No description provided for @contacts_memberCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个成员'**
  String contacts_memberCount(int count);

  /// No description provided for @groupDetail_title.
  ///
  /// In zh, this message translates to:
  /// **'群组详情'**
  String get groupDetail_title;

  /// No description provided for @groupDetail_editTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑群组'**
  String get groupDetail_editTitle;

  /// No description provided for @groupDetail_editGroup.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get groupDetail_editGroup;

  /// No description provided for @groupDetail_members.
  ///
  /// In zh, this message translates to:
  /// **'成员'**
  String get groupDetail_members;

  /// No description provided for @groupDetail_admin.
  ///
  /// In zh, this message translates to:
  /// **'管理员'**
  String get groupDetail_admin;

  /// No description provided for @groupDetail_member.
  ///
  /// In zh, this message translates to:
  /// **'成员'**
  String get groupDetail_member;

  /// No description provided for @groupDetail_systemPrompt.
  ///
  /// In zh, this message translates to:
  /// **'系统提示词'**
  String get groupDetail_systemPrompt;

  /// No description provided for @groupDetail_maxLoopRounds.
  ///
  /// In zh, this message translates to:
  /// **'最大编排轮次'**
  String get groupDetail_maxLoopRounds;

  /// No description provided for @groupDetail_startChat.
  ///
  /// In zh, this message translates to:
  /// **'发起聊天'**
  String get groupDetail_startChat;

  /// No description provided for @groupDetail_deleteGroup.
  ///
  /// In zh, this message translates to:
  /// **'删除群组'**
  String get groupDetail_deleteGroup;

  /// No description provided for @groupDetail_confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除群组？'**
  String get groupDetail_confirmDelete;

  /// No description provided for @groupDetail_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除群组「{name}」吗？这将删除所有消息。'**
  String groupDetail_deleteContent(String name);

  /// No description provided for @groupDetail_deleted.
  ///
  /// In zh, this message translates to:
  /// **'群组「{name}」已删除'**
  String groupDetail_deleted(String name);

  /// No description provided for @groupDetail_deleteFailed.
  ///
  /// In zh, this message translates to:
  /// **'删除群组失败: {error}'**
  String groupDetail_deleteFailed(String error);

  /// No description provided for @drawer_contacts.
  ///
  /// In zh, this message translates to:
  /// **'通讯录'**
  String get drawer_contacts;

  /// No description provided for @toolModel_managementTitle.
  ///
  /// In zh, this message translates to:
  /// **'模型管理'**
  String get toolModel_managementTitle;

  /// No description provided for @toolModel_configTitle.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get toolModel_configTitle;

  /// No description provided for @toolModel_configHint.
  ///
  /// In zh, this message translates to:
  /// **'为此 Agent 选择模型。作为工具模型时，主 LLM 可通过工具调用委派任务；也可用于多模态路由。'**
  String get toolModel_configHint;

  /// No description provided for @toolModel_configureTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择模型'**
  String get toolModel_configureTitle;

  /// No description provided for @toolModel_addTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加模型'**
  String get toolModel_addTitle;

  /// No description provided for @toolModel_editTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑模型'**
  String get toolModel_editTitle;

  /// No description provided for @toolModel_displayName.
  ///
  /// In zh, this message translates to:
  /// **'显示名称'**
  String get toolModel_displayName;

  /// No description provided for @toolModel_displayNameHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：图片生成、GPT-4o'**
  String get toolModel_displayNameHint;

  /// No description provided for @toolModel_displayNameRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入显示名称'**
  String get toolModel_displayNameRequired;

  /// No description provided for @toolModel_description.
  ///
  /// In zh, this message translates to:
  /// **'描述'**
  String get toolModel_description;

  /// No description provided for @toolModel_descriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'作为工具模型时，此描述帮助 LLM 判断何时调用（可选）'**
  String get toolModel_descriptionHint;

  /// No description provided for @toolModel_descriptionRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入描述'**
  String get toolModel_descriptionRequired;

  /// No description provided for @toolModel_model.
  ///
  /// In zh, this message translates to:
  /// **'模型'**
  String get toolModel_model;

  /// No description provided for @toolModel_modelHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：dall-e-3、gpt-4o'**
  String get toolModel_modelHint;

  /// No description provided for @toolModel_modelRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入模型名称'**
  String get toolModel_modelRequired;

  /// No description provided for @toolModel_apiBase.
  ///
  /// In zh, this message translates to:
  /// **'API 地址'**
  String get toolModel_apiBase;

  /// No description provided for @toolModel_apiBaseHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：https://api.openai.com/v1'**
  String get toolModel_apiBaseHint;

  /// No description provided for @toolModel_apiBaseRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入 API 地址'**
  String get toolModel_apiBaseRequired;

  /// No description provided for @toolModel_apiKey.
  ///
  /// In zh, this message translates to:
  /// **'API Key'**
  String get toolModel_apiKey;

  /// No description provided for @toolModel_apiKeyHint.
  ///
  /// In zh, this message translates to:
  /// **'输入 API Key（可选）'**
  String get toolModel_apiKeyHint;

  /// No description provided for @toolModel_provider.
  ///
  /// In zh, this message translates to:
  /// **'服务商'**
  String get toolModel_provider;

  /// No description provided for @toolModel_providerHint.
  ///
  /// In zh, this message translates to:
  /// **'例如：openai'**
  String get toolModel_providerHint;

  /// No description provided for @toolModel_selectProvider.
  ///
  /// In zh, this message translates to:
  /// **'选择服务商（自动填充 API 地址）'**
  String get toolModel_selectProvider;

  /// No description provided for @toolModel_customProvider.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get toolModel_customProvider;

  /// No description provided for @toolModel_noModels.
  ///
  /// In zh, this message translates to:
  /// **'暂无模型'**
  String get toolModel_noModels;

  /// No description provided for @toolModel_noModelsHint.
  ///
  /// In zh, this message translates to:
  /// **'点击 + 添加模型配置，可供各 Agent 复用。'**
  String get toolModel_noModelsHint;

  /// No description provided for @toolModel_noModelsAvailable.
  ///
  /// In zh, this message translates to:
  /// **'尚未配置模型。请在设置 > 模型管理中添加。'**
  String get toolModel_noModelsAvailable;

  /// No description provided for @toolModel_count.
  ///
  /// In zh, this message translates to:
  /// **'{count} 个模型'**
  String toolModel_count(int count);

  /// No description provided for @toolModel_deleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除模型'**
  String get toolModel_deleteTitle;

  /// No description provided for @toolModel_deleteContent.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除模型 {name} 吗？'**
  String toolModel_deleteContent(String name);

  /// No description provided for @toolModel_deleted.
  ///
  /// In zh, this message translates to:
  /// **'模型 {name} 已删除'**
  String toolModel_deleted(String name);

  /// No description provided for @toolModel_selectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get toolModel_selectAll;

  /// No description provided for @toolModel_deselectAll.
  ///
  /// In zh, this message translates to:
  /// **'取消全选'**
  String get toolModel_deselectAll;

  /// No description provided for @toolModel_scenarioLabel.
  ///
  /// In zh, this message translates to:
  /// **'使用场景'**
  String get toolModel_scenarioLabel;

  /// No description provided for @toolModel_scenarioHint.
  ///
  /// In zh, this message translates to:
  /// **'描述何时应调用此模型（覆盖全局描述）'**
  String get toolModel_scenarioHint;

  /// No description provided for @toolModel_scenarioPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'例如：用于图片生成任务'**
  String get toolModel_scenarioPlaceholder;

  /// No description provided for @addAgent_noToolModels.
  ///
  /// In zh, this message translates to:
  /// **'未选择模型'**
  String get addAgent_noToolModels;

  /// No description provided for @addAgent_toolModelsCount.
  ///
  /// In zh, this message translates to:
  /// **'已启用 {count} 个模型'**
  String addAgent_toolModelsCount(int count);

  /// No description provided for @agentDetail_noToolModelsEnabled.
  ///
  /// In zh, this message translates to:
  /// **'未启用模型'**
  String get agentDetail_noToolModelsEnabled;

  /// No description provided for @chat_mentionMode.
  ///
  /// In zh, this message translates to:
  /// **'提及模式'**
  String get chat_mentionMode;

  /// No description provided for @chat_mentionModeAdminOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅管理员'**
  String get chat_mentionModeAdminOnly;

  /// No description provided for @chat_mentionModeAllMembers.
  ///
  /// In zh, this message translates to:
  /// **'所有成员'**
  String get chat_mentionModeAllMembers;

  /// No description provided for @chat_mentionModeAdminOnlyDesc.
  ///
  /// In zh, this message translates to:
  /// **'仅管理员可以 @提及并激活其他成员'**
  String get chat_mentionModeAdminOnlyDesc;

  /// No description provided for @chat_mentionModeAllMembersDesc.
  ///
  /// In zh, this message translates to:
  /// **'任何成员都可以 @提及并激活其他成员'**
  String get chat_mentionModeAllMembersDesc;

  /// No description provided for @createGroup_mentionMode.
  ///
  /// In zh, this message translates to:
  /// **'提及模式'**
  String get createGroup_mentionMode;

  /// No description provided for @chat_planningMode.
  ///
  /// In zh, this message translates to:
  /// **'计划模式'**
  String get chat_planningMode;

  /// No description provided for @chat_planningModeDesc.
  ///
  /// In zh, this message translates to:
  /// **'启用后 Admin 会先生成任务计划，用户确认后再执行'**
  String get chat_planningModeDesc;

  /// No description provided for @chat_flowMode.
  ///
  /// In zh, this message translates to:
  /// **'Flow 模式'**
  String get chat_flowMode;

  /// No description provided for @chat_flowModeDesc.
  ///
  /// In zh, this message translates to:
  /// **'Admin 生成阶段化 FlowPlan，各阶段串行、阶段内步骤并行执行'**
  String get chat_flowModeDesc;

  /// No description provided for @chat_viewTrace.
  ///
  /// In zh, this message translates to:
  /// **'查看 Trace'**
  String get chat_viewTrace;

  /// No description provided for @modelType_sectionLabel.
  ///
  /// In zh, this message translates to:
  /// **'模型类型'**
  String get modelType_sectionLabel;

  /// No description provided for @modelType_sectionHint.
  ///
  /// In zh, this message translates to:
  /// **'选择此模型支持的能力类型（可多选）'**
  String get modelType_sectionHint;

  /// No description provided for @modelType_text.
  ///
  /// In zh, this message translates to:
  /// **'文本'**
  String get modelType_text;

  /// No description provided for @modelType_imageUnderstanding.
  ///
  /// In zh, this message translates to:
  /// **'图片理解'**
  String get modelType_imageUnderstanding;

  /// No description provided for @modelType_audioUnderstanding.
  ///
  /// In zh, this message translates to:
  /// **'语音理解'**
  String get modelType_audioUnderstanding;

  /// No description provided for @modelType_videoUnderstanding.
  ///
  /// In zh, this message translates to:
  /// **'视频理解'**
  String get modelType_videoUnderstanding;

  /// No description provided for @modelType_imageGeneration.
  ///
  /// In zh, this message translates to:
  /// **'图片生成'**
  String get modelType_imageGeneration;

  /// No description provided for @modelType_tts.
  ///
  /// In zh, this message translates to:
  /// **'语音合成'**
  String get modelType_tts;

  /// No description provided for @modelType_videoGeneration.
  ///
  /// In zh, this message translates to:
  /// **'视频生成'**
  String get modelType_videoGeneration;

  /// No description provided for @common_required.
  ///
  /// In zh, this message translates to:
  /// **'必填'**
  String get common_required;

  /// No description provided for @addAgent_modelRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择模型'**
  String get addAgent_modelRequired;

  /// No description provided for @addAgent_noModels.
  ///
  /// In zh, this message translates to:
  /// **'未配置模型，请先在设置中添加模型'**
  String get addAgent_noModels;

  /// No description provided for @toolModel_goToManagement.
  ///
  /// In zh, this message translates to:
  /// **'前往模型管理'**
  String get toolModel_goToManagement;

  /// No description provided for @settings_disableServiceTitle.
  ///
  /// In zh, this message translates to:
  /// **'关闭本地服务'**
  String get settings_disableServiceTitle;

  /// No description provided for @settings_disableServiceContent.
  ///
  /// In zh, this message translates to:
  /// **'关闭后，所有已配置「允许外部访问」的 Agent 将无法接受外网连接，正在连接的客户端也会立即断开。\n\n确认关闭？'**
  String get settings_disableServiceContent;

  /// No description provided for @settings_disableServiceConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认关闭'**
  String get settings_disableServiceConfirm;

  /// No description provided for @settings_localService.
  ///
  /// In zh, this message translates to:
  /// **'本地服务'**
  String get settings_localService;

  /// No description provided for @settings_localServiceDesc.
  ///
  /// In zh, this message translates to:
  /// **'允许内网或外网设备以 Remote Agent 形式连接'**
  String get settings_localServiceDesc;

  /// No description provided for @settings_lanAddress.
  ///
  /// In zh, this message translates to:
  /// **'内网连接地址'**
  String get settings_lanAddress;

  /// No description provided for @settings_lanAddressSub.
  ///
  /// In zh, this message translates to:
  /// **'同局域网设备可通过以下地址连接'**
  String get settings_lanAddressSub;

  /// No description provided for @settings_channelTunnel.
  ///
  /// In zh, this message translates to:
  /// **'Channel Tunnel（外网穿透）'**
  String get settings_channelTunnel;

  /// No description provided for @settings_tunnelNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置'**
  String get settings_tunnelNotConfigured;

  /// No description provided for @settings_tunnelConnected.
  ///
  /// In zh, this message translates to:
  /// **'已连接'**
  String get settings_tunnelConnected;

  /// No description provided for @settings_tunnelConnecting.
  ///
  /// In zh, this message translates to:
  /// **'连接中'**
  String get settings_tunnelConnecting;

  /// No description provided for @settings_tunnelDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'已断开'**
  String get settings_tunnelDisconnected;

  /// No description provided for @settings_tunnelError.
  ///
  /// In zh, this message translates to:
  /// **'连接错误'**
  String get settings_tunnelError;

  /// No description provided for @settings_configureTunnel.
  ///
  /// In zh, this message translates to:
  /// **'配置 Tunnel'**
  String get settings_configureTunnel;

  /// No description provided for @settings_copyLanAddress.
  ///
  /// In zh, this message translates to:
  /// **'复制内网地址'**
  String get settings_copyLanAddress;

  /// No description provided for @settings_copyPublicAddress.
  ///
  /// In zh, this message translates to:
  /// **'复制外网地址'**
  String get settings_copyPublicAddress;

  /// No description provided for @settings_acpServerRunning.
  ///
  /// In zh, this message translates to:
  /// **'ACP Server 运行中'**
  String get settings_acpServerRunning;

  /// No description provided for @settings_acpServerStopped.
  ///
  /// In zh, this message translates to:
  /// **'ACP Server 未运行'**
  String get settings_acpServerStopped;

  /// No description provided for @settings_tunnelServerUrl.
  ///
  /// In zh, this message translates to:
  /// **'Channel 服务地址'**
  String get settings_tunnelServerUrl;

  /// No description provided for @settings_tunnelChannelId.
  ///
  /// In zh, this message translates to:
  /// **'Channel ID'**
  String get settings_tunnelChannelId;

  /// No description provided for @settings_tunnelSecret.
  ///
  /// In zh, this message translates to:
  /// **'Secret'**
  String get settings_tunnelSecret;

  /// No description provided for @settings_tunnelAutoConnect.
  ///
  /// In zh, this message translates to:
  /// **'自动连接'**
  String get settings_tunnelAutoConnect;

  /// No description provided for @settings_tunnelPublicAddress.
  ///
  /// In zh, this message translates to:
  /// **'外网访问地址'**
  String get settings_tunnelPublicAddress;

  /// No description provided for @settings_tunnelConfigRequiredFields.
  ///
  /// In zh, this message translates to:
  /// **'请填写所有必填字段'**
  String get settings_tunnelConfigRequiredFields;

  /// No description provided for @settings_deleteTunnelConfig.
  ///
  /// In zh, this message translates to:
  /// **'删除配置'**
  String get settings_deleteTunnelConfig;

  /// No description provided for @settings_noLanAddress.
  ///
  /// In zh, this message translates to:
  /// **'暂未获取到局域网地址'**
  String get settings_noLanAddress;

  /// No description provided for @settings_acpPort.
  ///
  /// In zh, this message translates to:
  /// **'端口'**
  String get settings_acpPort;

  /// No description provided for @settings_acpPortSuffix.
  ///
  /// In zh, this message translates to:
  /// **'（1024-65535）'**
  String get settings_acpPortSuffix;

  /// No description provided for @settings_acpChangePort.
  ///
  /// In zh, this message translates to:
  /// **'修改端口'**
  String get settings_acpChangePort;

  /// No description provided for @settings_acpPortHint.
  ///
  /// In zh, this message translates to:
  /// **'修改端口后需要重启 App 才能生效。其他设备需使用新端口重新连接。'**
  String get settings_acpPortHint;

  /// No description provided for @settings_acpPortInvalid.
  ///
  /// In zh, this message translates to:
  /// **'端口号无效，请输入 1024-65535 之间的数字'**
  String get settings_acpPortInvalid;

  /// No description provided for @settings_acpPortRestarting.
  ///
  /// In zh, this message translates to:
  /// **'正在重启 ACP Server...'**
  String get settings_acpPortRestarting;

  /// No description provided for @settings_acpPortRestartRequired.
  ///
  /// In zh, this message translates to:
  /// **'端口已保存，重启 App 后生效'**
  String get settings_acpPortRestartRequired;

  /// No description provided for @settings_acpToken.
  ///
  /// In zh, this message translates to:
  /// **'连接 Token'**
  String get settings_acpToken;

  /// No description provided for @settings_acpTokenCopy.
  ///
  /// In zh, this message translates to:
  /// **'复制 Token'**
  String get settings_acpTokenCopy;

  /// No description provided for @settings_acpTokenRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新 Token'**
  String get settings_acpTokenRefresh;

  /// No description provided for @settings_acpTokenRefreshed.
  ///
  /// In zh, this message translates to:
  /// **'Token 已刷新，旧连接需重新连接'**
  String get settings_acpTokenRefreshed;

  /// No description provided for @agent_enableExternalAccessTitle.
  ///
  /// In zh, this message translates to:
  /// **'开启外网访问'**
  String get agent_enableExternalAccessTitle;

  /// No description provided for @agent_enableExternalAccessNeedService.
  ///
  /// In zh, this message translates to:
  /// **'当前「本地服务总控开关」已关闭，外网访问功能无法使用。\n\n是否同时开启本地服务？'**
  String get agent_enableExternalAccessNeedService;

  /// No description provided for @agent_enableServiceAndContinue.
  ///
  /// In zh, this message translates to:
  /// **'开启本地服务'**
  String get agent_enableServiceAndContinue;

  /// No description provided for @agent_keepDisabled.
  ///
  /// In zh, this message translates to:
  /// **'仅保存设置'**
  String get agent_keepDisabled;

  /// No description provided for @agent_allowExternalAccess.
  ///
  /// In zh, this message translates to:
  /// **'允许外部访问'**
  String get agent_allowExternalAccess;

  /// No description provided for @agent_allowExternalAccessDesc.
  ///
  /// In zh, this message translates to:
  /// **'开启后，外部 App 可通过 Remote Agent 方式加入对话'**
  String get agent_allowExternalAccessDesc;

  /// No description provided for @agent_externalAccessUrl.
  ///
  /// In zh, this message translates to:
  /// **'访问地址'**
  String get agent_externalAccessUrl;

  /// No description provided for @agent_externalAccessUrlLan.
  ///
  /// In zh, this message translates to:
  /// **'局域网访问地址'**
  String get agent_externalAccessUrlLan;

  /// No description provided for @agent_externalAccessUrlPublic.
  ///
  /// In zh, this message translates to:
  /// **'公网访问地址'**
  String get agent_externalAccessUrlPublic;

  /// No description provided for @agent_externalAccessDisabled.
  ///
  /// In zh, this message translates to:
  /// **'外部访问已关闭'**
  String get agent_externalAccessDisabled;

  /// No description provided for @agent_externalAccessNeedsService.
  ///
  /// In zh, this message translates to:
  /// **'需先在「设置」中开启本地服务'**
  String get agent_externalAccessNeedsService;

  /// No description provided for @agent_copyAccessUrl.
  ///
  /// In zh, this message translates to:
  /// **'复制访问地址'**
  String get agent_copyAccessUrl;

  /// No description provided for @agent_accessUrlCopied.
  ///
  /// In zh, this message translates to:
  /// **'访问地址已复制'**
  String get agent_accessUrlCopied;

  /// No description provided for @agent_accessUrlCopiedHint.
  ///
  /// In zh, this message translates to:
  /// **'可粘贴到端点 URL 处进行连接'**
  String get agent_accessUrlCopiedHint;

  /// No description provided for @agent_regenerateToken.
  ///
  /// In zh, this message translates to:
  /// **'刷新 Token'**
  String get agent_regenerateToken;

  /// No description provided for @agent_regenerateTokenConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认刷新 Token'**
  String get agent_regenerateTokenConfirmTitle;

  /// No description provided for @agent_regenerateTokenConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'刷新后旧 Token 将立即失效，已连接的客户端需使用新 Token 重新连接。确认继续吗？'**
  String get agent_regenerateTokenConfirmBody;

  /// No description provided for @agent_tokenRegenerated.
  ///
  /// In zh, this message translates to:
  /// **'Token 已更新'**
  String get agent_tokenRegenerated;

  /// No description provided for @agent_tokenRegenerateFailed.
  ///
  /// In zh, this message translates to:
  /// **'刷新失败: {error}'**
  String agent_tokenRegenerateFailed(String error);

  /// No description provided for @agent_channelConfig.
  ///
  /// In zh, this message translates to:
  /// **'公网 Channel 配置'**
  String get agent_channelConfig;

  /// No description provided for @agent_channelServerUrl.
  ///
  /// In zh, this message translates to:
  /// **'Server 地址'**
  String get agent_channelServerUrl;

  /// No description provided for @agent_channelId.
  ///
  /// In zh, this message translates to:
  /// **'Channel ID'**
  String get agent_channelId;

  /// No description provided for @agent_channelSecret.
  ///
  /// In zh, this message translates to:
  /// **'Channel 密钥'**
  String get agent_channelSecret;

  /// No description provided for @agent_channelEndpoint.
  ///
  /// In zh, this message translates to:
  /// **'Channel Endpoint（可选）'**
  String get agent_channelEndpoint;

  /// No description provided for @agent_channelNotConfigured.
  ///
  /// In zh, this message translates to:
  /// **'未配置公网 Channel'**
  String get agent_channelNotConfigured;

  /// No description provided for @agent_channelConfigure.
  ///
  /// In zh, this message translates to:
  /// **'去配置'**
  String get agent_channelConfigure;

  /// No description provided for @she_pinned_label.
  ///
  /// In zh, this message translates to:
  /// **'置顶'**
  String get she_pinned_label;

  /// No description provided for @she_bio.
  ///
  /// In zh, this message translates to:
  /// **'你的专属守护者'**
  String get she_bio;

  /// No description provided for @settings_userProfile.
  ///
  /// In zh, this message translates to:
  /// **'个人档案'**
  String get settings_userProfile;

  /// No description provided for @settings_userProfileSub.
  ///
  /// In zh, this message translates to:
  /// **'管理你的个人信息'**
  String get settings_userProfileSub;

  /// No description provided for @settings_agentMemories.
  ///
  /// In zh, this message translates to:
  /// **'Agent 记忆'**
  String get settings_agentMemories;

  /// No description provided for @settings_agentMemoriesSub.
  ///
  /// In zh, this message translates to:
  /// **'查看和管理每个 Agent 的记忆'**
  String get settings_agentMemoriesSub;

  /// No description provided for @memory_title.
  ///
  /// In zh, this message translates to:
  /// **'记忆'**
  String get memory_title;

  /// No description provided for @memory_add.
  ///
  /// In zh, this message translates to:
  /// **'添加笔记'**
  String get memory_add;

  /// No description provided for @memory_structured.
  ///
  /// In zh, this message translates to:
  /// **'结构化视图'**
  String get memory_structured;

  /// No description provided for @memory_timeline.
  ///
  /// In zh, this message translates to:
  /// **'时间线'**
  String get memory_timeline;

  /// No description provided for @memory_export.
  ///
  /// In zh, this message translates to:
  /// **'导出'**
  String get memory_export;

  /// No description provided for @memory_json.
  ///
  /// In zh, this message translates to:
  /// **'JSON'**
  String get memory_json;

  /// No description provided for @memory_markdown.
  ///
  /// In zh, this message translates to:
  /// **'Markdown'**
  String get memory_markdown;

  /// No description provided for @memory_clearAll.
  ///
  /// In zh, this message translates to:
  /// **'清除全部'**
  String get memory_clearAll;

  /// No description provided for @memory_delete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get memory_delete;

  /// No description provided for @memory_noMemories.
  ///
  /// In zh, this message translates to:
  /// **'暂无记忆'**
  String get memory_noMemories;

  /// No description provided for @memory_addNoteHint.
  ///
  /// In zh, this message translates to:
  /// **'添加笔记以保存记忆'**
  String get memory_addNoteHint;

  /// No description provided for @memory_view.
  ///
  /// In zh, this message translates to:
  /// **'查看'**
  String get memory_view;

  /// No description provided for @memory_noAgents.
  ///
  /// In zh, this message translates to:
  /// **'没有可用的 Agent'**
  String get memory_noAgents;

  /// No description provided for @memory_addAgents.
  ///
  /// In zh, this message translates to:
  /// **'添加 Agent 以管理其记忆'**
  String get memory_addAgents;

  /// No description provided for @memory_created.
  ///
  /// In zh, this message translates to:
  /// **'创建于'**
  String get memory_created;

  /// No description provided for @memory_updated.
  ///
  /// In zh, this message translates to:
  /// **'更新于'**
  String get memory_updated;

  /// No description provided for @profile_personalTitle.
  ///
  /// In zh, this message translates to:
  /// **'个人档案'**
  String get profile_personalTitle;

  /// No description provided for @profile_coreInfo.
  ///
  /// In zh, this message translates to:
  /// **'核心信息'**
  String get profile_coreInfo;

  /// No description provided for @profile_extendedInfo.
  ///
  /// In zh, this message translates to:
  /// **'附加信息'**
  String get profile_extendedInfo;

  /// No description provided for @profile_customAttrs.
  ///
  /// In zh, this message translates to:
  /// **'自定义属性'**
  String get profile_customAttrs;

  /// No description provided for @profile_add.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get profile_add;

  /// No description provided for @profile_reset.
  ///
  /// In zh, this message translates to:
  /// **'重置全部'**
  String get profile_reset;

  /// No description provided for @profile_nameField.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get profile_nameField;

  /// No description provided for @profile_ageField.
  ///
  /// In zh, this message translates to:
  /// **'年龄'**
  String get profile_ageField;

  /// No description provided for @profile_genderField.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get profile_genderField;

  /// No description provided for @profile_occupationField.
  ///
  /// In zh, this message translates to:
  /// **'职业'**
  String get profile_occupationField;

  /// No description provided for @profile_cityField.
  ///
  /// In zh, this message translates to:
  /// **'城市'**
  String get profile_cityField;

  /// No description provided for @profile_interestsField.
  ///
  /// In zh, this message translates to:
  /// **'兴趣爱好'**
  String get profile_interestsField;

  /// No description provided for @profile_interestsHint.
  ///
  /// In zh, this message translates to:
  /// **'用逗号分隔'**
  String get profile_interestsHint;

  /// No description provided for @profile_valuesField.
  ///
  /// In zh, this message translates to:
  /// **'价值观'**
  String get profile_valuesField;

  /// No description provided for @profile_valuesHint.
  ///
  /// In zh, this message translates to:
  /// **'对你最重要的是什么'**
  String get profile_valuesHint;

  /// No description provided for @profile_goalsField.
  ///
  /// In zh, this message translates to:
  /// **'目标和需求'**
  String get profile_goalsField;

  /// No description provided for @profile_goalsHint.
  ///
  /// In zh, this message translates to:
  /// **'你的愿景和抱负'**
  String get profile_goalsHint;

  /// No description provided for @profile_communicationStyleField.
  ///
  /// In zh, this message translates to:
  /// **'沟通风格'**
  String get profile_communicationStyleField;

  /// No description provided for @profile_communicationStyleHint.
  ///
  /// In zh, this message translates to:
  /// **'你偏好的沟通方式'**
  String get profile_communicationStyleHint;

  /// No description provided for @profile_workStyleField.
  ///
  /// In zh, this message translates to:
  /// **'工作风格'**
  String get profile_workStyleField;

  /// No description provided for @profile_workStyleHint.
  ///
  /// In zh, this message translates to:
  /// **'你的工作习惯和偏好'**
  String get profile_workStyleHint;

  /// No description provided for @profile_lifeStageField.
  ///
  /// In zh, this message translates to:
  /// **'人生阶段'**
  String get profile_lifeStageField;

  /// No description provided for @profile_lifeStageHint.
  ///
  /// In zh, this message translates to:
  /// **'如：学生、职场人士、退休人员'**
  String get profile_lifeStageHint;

  /// No description provided for @profile_importantPeopleField.
  ///
  /// In zh, this message translates to:
  /// **'重要的人'**
  String get profile_importantPeopleField;

  /// No description provided for @profile_importantPeopleHint.
  ///
  /// In zh, this message translates to:
  /// **'家人、朋友、导师'**
  String get profile_importantPeopleHint;

  /// No description provided for @profile_healthField.
  ///
  /// In zh, this message translates to:
  /// **'健康状况'**
  String get profile_healthField;

  /// No description provided for @profile_healthHint.
  ///
  /// In zh, this message translates to:
  /// **'健康问题、过敏情况'**
  String get profile_healthHint;

  /// No description provided for @profile_languageField.
  ///
  /// In zh, this message translates to:
  /// **'语言偏好'**
  String get profile_languageField;

  /// No description provided for @profile_languageHint.
  ///
  /// In zh, this message translates to:
  /// **'如：中文、English、日本語'**
  String get profile_languageHint;

  /// No description provided for @profile_timezoneField.
  ///
  /// In zh, this message translates to:
  /// **'时区'**
  String get profile_timezoneField;

  /// No description provided for @profile_timezoneHint.
  ///
  /// In zh, this message translates to:
  /// **'如：CST、PST、UTC+8'**
  String get profile_timezoneHint;

  /// No description provided for @profile_notesField.
  ///
  /// In zh, this message translates to:
  /// **'其他备注'**
  String get profile_notesField;

  /// No description provided for @profile_notesHint.
  ///
  /// In zh, this message translates to:
  /// **'其他任何补充信息'**
  String get profile_notesHint;

  /// No description provided for @profile_addCustomTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加自定义属性'**
  String get profile_addCustomTitle;

  /// No description provided for @profile_attributeName.
  ///
  /// In zh, this message translates to:
  /// **'属性名称'**
  String get profile_attributeName;

  /// No description provided for @profile_attributeNameHint.
  ///
  /// In zh, this message translates to:
  /// **'如：宠物名、最喜欢的食物'**
  String get profile_attributeNameHint;

  /// No description provided for @profile_attributeValue.
  ///
  /// In zh, this message translates to:
  /// **'值'**
  String get profile_attributeValue;

  /// No description provided for @profile_attributeValueHint.
  ///
  /// In zh, this message translates to:
  /// **'输入属性值'**
  String get profile_attributeValueHint;

  /// No description provided for @profile_removeAttrTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除属性'**
  String get profile_removeAttrTitle;

  /// No description provided for @profile_removeAttrContent.
  ///
  /// In zh, this message translates to:
  /// **'删除「{name}」？'**
  String profile_removeAttrContent(String name);

  /// No description provided for @profile_customLabel.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get profile_customLabel;

  /// No description provided for @profile_noCustomAttrs.
  ///
  /// In zh, this message translates to:
  /// **'暂无自定义属性，点击「添加」创建'**
  String get profile_noCustomAttrs;

  /// No description provided for @profile_resetTitle.
  ///
  /// In zh, this message translates to:
  /// **'重置档案'**
  String get profile_resetTitle;

  /// No description provided for @profile_resetContent.
  ///
  /// In zh, this message translates to:
  /// **'这将清除所有个人信息，此操作不可撤销。'**
  String get profile_resetContent;

  /// No description provided for @profile_saved.
  ///
  /// In zh, this message translates to:
  /// **'档案已保存'**
  String get profile_saved;

  /// No description provided for @profile_saveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存出错: {error}'**
  String profile_saveFailed(String error);

  /// No description provided for @profile_loadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载档案失败'**
  String get profile_loadFailed;

  /// No description provided for @profile_resetSuccess.
  ///
  /// In zh, this message translates to:
  /// **'档案已重置'**
  String get profile_resetSuccess;

  /// No description provided for @profile_resetFailed.
  ///
  /// In zh, this message translates to:
  /// **'重置档案失败'**
  String get profile_resetFailed;

  /// No description provided for @profile_nameEmpty.
  ///
  /// In zh, this message translates to:
  /// **'属性名称不能为空'**
  String get profile_nameEmpty;

  /// No description provided for @profile_nameReserved.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」是保留字段名'**
  String profile_nameReserved(String name);

  /// No description provided for @profile_nameDuplicate.
  ///
  /// In zh, this message translates to:
  /// **'「{name}」已存在'**
  String profile_nameDuplicate(String name);

  /// No description provided for @profile_nameStartWithUnderscore.
  ///
  /// In zh, this message translates to:
  /// **'名称不能以下划线开头'**
  String get profile_nameStartWithUnderscore;

  /// No description provided for @profile_nameInvalidChars.
  ///
  /// In zh, this message translates to:
  /// **'只允许使用字母、数字和下划线'**
  String get profile_nameInvalidChars;

  /// No description provided for @profile_nameTooLong.
  ///
  /// In zh, this message translates to:
  /// **'名称过长（最多 50 个字符）'**
  String get profile_nameTooLong;

  /// No description provided for @profile_loadingProfile.
  ///
  /// In zh, this message translates to:
  /// **'正在加载档案...'**
  String get profile_loadingProfile;

  /// No description provided for @scheduledTasks_title.
  ///
  /// In zh, this message translates to:
  /// **'定时任务'**
  String get scheduledTasks_title;

  /// No description provided for @scheduledTasks_description.
  ///
  /// In zh, this message translates to:
  /// **'管理自动执行的定时任务'**
  String get scheduledTasks_description;

  /// No description provided for @scheduledTasks_noTasks.
  ///
  /// In zh, this message translates to:
  /// **'还没有定时任务'**
  String get scheduledTasks_noTasks;

  /// No description provided for @scheduledTasks_noTasksHint.
  ///
  /// In zh, this message translates to:
  /// **'创建一个新任务来开始'**
  String get scheduledTasks_noTasksHint;

  /// No description provided for @scheduledTasks_createTask.
  ///
  /// In zh, this message translates to:
  /// **'创建任务'**
  String get scheduledTasks_createTask;

  /// No description provided for @scheduledTasks_editTask.
  ///
  /// In zh, this message translates to:
  /// **'编辑任务'**
  String get scheduledTasks_editTask;

  /// No description provided for @scheduledTasks_deleteTask.
  ///
  /// In zh, this message translates to:
  /// **'删除任务'**
  String get scheduledTasks_deleteTask;

  /// No description provided for @scheduledTasks_activateTask.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get scheduledTasks_activateTask;

  /// No description provided for @scheduledTasks_pauseTask.
  ///
  /// In zh, this message translates to:
  /// **'暂停'**
  String get scheduledTasks_pauseTask;

  /// No description provided for @scheduledTasks_executeNow.
  ///
  /// In zh, this message translates to:
  /// **'立即执行'**
  String get scheduledTasks_executeNow;

  /// No description provided for @scheduledTasks_form_title.
  ///
  /// In zh, this message translates to:
  /// **'任务详情'**
  String get scheduledTasks_form_title;

  /// No description provided for @scheduledTasks_form_description.
  ///
  /// In zh, this message translates to:
  /// **'描述'**
  String get scheduledTasks_form_description;

  /// No description provided for @scheduledTasks_form_descriptionHint.
  ///
  /// In zh, this message translates to:
  /// **'这个任务的用途是什么？'**
  String get scheduledTasks_form_descriptionHint;

  /// No description provided for @scheduledTasks_form_instruction.
  ///
  /// In zh, this message translates to:
  /// **'指令'**
  String get scheduledTasks_form_instruction;

  /// No description provided for @scheduledTasks_form_instructionHint.
  ///
  /// In zh, this message translates to:
  /// **'输入任务指令或提示'**
  String get scheduledTasks_form_instructionHint;

  /// No description provided for @scheduledTasks_form_selectAgent.
  ///
  /// In zh, this message translates to:
  /// **'选择智能体'**
  String get scheduledTasks_form_selectAgent;

  /// No description provided for @scheduledTasks_form_scheduleType.
  ///
  /// In zh, this message translates to:
  /// **'计划类型'**
  String get scheduledTasks_form_scheduleType;

  /// No description provided for @scheduledTasks_form_schedulePattern.
  ///
  /// In zh, this message translates to:
  /// **'时间安排'**
  String get scheduledTasks_form_schedulePattern;

  /// No description provided for @scheduledTasks_form_schedulePatternHint.
  ///
  /// In zh, this message translates to:
  /// **'Cron: 0 9 * * * 或 Duration: PT5M'**
  String get scheduledTasks_form_schedulePatternHint;

  /// No description provided for @scheduledTasks_form_optional.
  ///
  /// In zh, this message translates to:
  /// **'可选'**
  String get scheduledTasks_form_optional;

  /// No description provided for @scheduledTasks_form_selectChannel.
  ///
  /// In zh, this message translates to:
  /// **'选择频道（可选）'**
  String get scheduledTasks_form_selectChannel;

  /// No description provided for @scheduledTasks_scheduleType_cron.
  ///
  /// In zh, this message translates to:
  /// **'Cron 表达式'**
  String get scheduledTasks_scheduleType_cron;

  /// No description provided for @scheduledTasks_scheduleType_interval.
  ///
  /// In zh, this message translates to:
  /// **'间隔时长'**
  String get scheduledTasks_scheduleType_interval;

  /// No description provided for @scheduledTasks_scheduleType_once.
  ///
  /// In zh, this message translates to:
  /// **'一次性'**
  String get scheduledTasks_scheduleType_once;

  /// No description provided for @scheduledTasks_cronExamples.
  ///
  /// In zh, this message translates to:
  /// **'Cron 示例'**
  String get scheduledTasks_cronExamples;

  /// No description provided for @scheduledTasks_cronExample_daily.
  ///
  /// In zh, this message translates to:
  /// **'每天早上 9 点: 0 9 * * *'**
  String get scheduledTasks_cronExample_daily;

  /// No description provided for @scheduledTasks_cronExample_hourly.
  ///
  /// In zh, this message translates to:
  /// **'每小时: 0 * * * *'**
  String get scheduledTasks_cronExample_hourly;

  /// No description provided for @scheduledTasks_cronExample_weekdays.
  ///
  /// In zh, this message translates to:
  /// **'工作日早上 9 点: 0 9 * * 1-5'**
  String get scheduledTasks_cronExample_weekdays;

  /// No description provided for @scheduledTasks_cronExample_everyMinute.
  ///
  /// In zh, this message translates to:
  /// **'每分钟: * * * * *'**
  String get scheduledTasks_cronExample_everyMinute;

  /// No description provided for @scheduledTasks_intervalExamples.
  ///
  /// In zh, this message translates to:
  /// **'时长示例'**
  String get scheduledTasks_intervalExamples;

  /// No description provided for @scheduledTasks_intervalExample_5min.
  ///
  /// In zh, this message translates to:
  /// **'每 5 分钟: PT5M'**
  String get scheduledTasks_intervalExample_5min;

  /// No description provided for @scheduledTasks_intervalExample_1hour.
  ///
  /// In zh, this message translates to:
  /// **'每 1 小时: PT1H'**
  String get scheduledTasks_intervalExample_1hour;

  /// No description provided for @scheduledTasks_intervalExample_30min.
  ///
  /// In zh, this message translates to:
  /// **'每 30 分钟: PT30M'**
  String get scheduledTasks_intervalExample_30min;

  /// No description provided for @scheduledTasks_status_pending.
  ///
  /// In zh, this message translates to:
  /// **'待处理'**
  String get scheduledTasks_status_pending;

  /// No description provided for @scheduledTasks_status_active.
  ///
  /// In zh, this message translates to:
  /// **'活跃'**
  String get scheduledTasks_status_active;

  /// No description provided for @scheduledTasks_status_paused.
  ///
  /// In zh, this message translates to:
  /// **'已暂停'**
  String get scheduledTasks_status_paused;

  /// No description provided for @scheduledTasks_status_completed.
  ///
  /// In zh, this message translates to:
  /// **'已完成'**
  String get scheduledTasks_status_completed;

  /// No description provided for @scheduledTasks_status_failed.
  ///
  /// In zh, this message translates to:
  /// **'失败'**
  String get scheduledTasks_status_failed;

  /// No description provided for @scheduledTasks_nextRun.
  ///
  /// In zh, this message translates to:
  /// **'下次运行: {time}'**
  String scheduledTasks_nextRun(String time);

  /// No description provided for @scheduledTasks_lastRun.
  ///
  /// In zh, this message translates to:
  /// **'最后运行: {time}'**
  String scheduledTasks_lastRun(String time);

  /// No description provided for @scheduledTasks_executionCount.
  ///
  /// In zh, this message translates to:
  /// **'执行次数: {count}'**
  String scheduledTasks_executionCount(String count);

  /// No description provided for @scheduledTasks_failureCount.
  ///
  /// In zh, this message translates to:
  /// **'失败次数: {count}'**
  String scheduledTasks_failureCount(String count);

  /// No description provided for @scheduledTasks_noLastError.
  ///
  /// In zh, this message translates to:
  /// **'无错误'**
  String get scheduledTasks_noLastError;

  /// No description provided for @scheduledTasks_lastError.
  ///
  /// In zh, this message translates to:
  /// **'最后错误: {error}'**
  String scheduledTasks_lastError(String error);

  /// No description provided for @scheduledTasks_confirmDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除任务？'**
  String get scheduledTasks_confirmDelete;

  /// No description provided for @scheduledTasks_confirmDeleteMsg.
  ///
  /// In zh, this message translates to:
  /// **'确定要删除这个定时任务吗？此操作无法撤销。'**
  String get scheduledTasks_confirmDeleteMsg;

  /// No description provided for @scheduledTasks_confirmPause.
  ///
  /// In zh, this message translates to:
  /// **'暂停任务？'**
  String get scheduledTasks_confirmPause;

  /// No description provided for @scheduledTasks_confirmPauseMsg.
  ///
  /// In zh, this message translates to:
  /// **'任务将停止执行。您可以稍后恢复。'**
  String get scheduledTasks_confirmPauseMsg;

  /// No description provided for @scheduledTasks_invalidSchedule.
  ///
  /// In zh, this message translates to:
  /// **'无效的时间安排'**
  String get scheduledTasks_invalidSchedule;

  /// No description provided for @scheduledTasks_invalidScheduleMsg.
  ///
  /// In zh, this message translates to:
  /// **'请检查您的 cron 表达式或时长格式'**
  String get scheduledTasks_invalidScheduleMsg;

  /// No description provided for @scheduledTasks_missingInstruction.
  ///
  /// In zh, this message translates to:
  /// **'指令不能为空'**
  String get scheduledTasks_missingInstruction;

  /// No description provided for @scheduledTasks_missingAgent.
  ///
  /// In zh, this message translates to:
  /// **'请选择一个智能体'**
  String get scheduledTasks_missingAgent;

  /// No description provided for @scheduledTasks_createSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务创建成功'**
  String get scheduledTasks_createSuccess;

  /// No description provided for @scheduledTasks_updateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务更新成功'**
  String get scheduledTasks_updateSuccess;

  /// No description provided for @scheduledTasks_deleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务删除成功'**
  String get scheduledTasks_deleteSuccess;

  /// No description provided for @scheduledTasks_activateSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务已启用'**
  String get scheduledTasks_activateSuccess;

  /// No description provided for @scheduledTasks_pauseSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务已暂停'**
  String get scheduledTasks_pauseSuccess;

  /// No description provided for @scheduledTasks_executeNowSuccess.
  ///
  /// In zh, this message translates to:
  /// **'任务执行已开始'**
  String get scheduledTasks_executeNowSuccess;

  /// No description provided for @scheduledTasks_filterByAgent.
  ///
  /// In zh, this message translates to:
  /// **'按智能体筛选'**
  String get scheduledTasks_filterByAgent;

  /// No description provided for @scheduledTasks_filterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get scheduledTasks_filterAll;

  /// No description provided for @scheduledTasks_createError.
  ///
  /// In zh, this message translates to:
  /// **'创建任务失败: {error}'**
  String scheduledTasks_createError(String error);

  /// No description provided for @scheduledTasks_updateError.
  ///
  /// In zh, this message translates to:
  /// **'更新任务失败: {error}'**
  String scheduledTasks_updateError(String error);

  /// No description provided for @scheduledTasks_deleteError.
  ///
  /// In zh, this message translates to:
  /// **'删除任务失败: {error}'**
  String scheduledTasks_deleteError(String error);

  /// No description provided for @scheduledTasks_activateError.
  ///
  /// In zh, this message translates to:
  /// **'启用任务失败: {error}'**
  String scheduledTasks_activateError(String error);

  /// No description provided for @scheduledTasks_targetAgent.
  ///
  /// In zh, this message translates to:
  /// **'Agent 任务'**
  String get scheduledTasks_targetAgent;

  /// No description provided for @scheduledTasks_targetGroup.
  ///
  /// In zh, this message translates to:
  /// **'群任务'**
  String get scheduledTasks_targetGroup;

  /// No description provided for @scheduledTasks_form_optionalChannel.
  ///
  /// In zh, this message translates to:
  /// **'指定频道（可选）'**
  String get scheduledTasks_form_optionalChannel;

  /// No description provided for @scheduledTasks_form_selectGroupChannel.
  ///
  /// In zh, this message translates to:
  /// **'选择群频道'**
  String get scheduledTasks_form_selectGroupChannel;

  /// No description provided for @scheduledTasks_form_selectGroup.
  ///
  /// In zh, this message translates to:
  /// **'选择群'**
  String get scheduledTasks_form_selectGroup;

  /// No description provided for @scheduledTasks_form_selectGroupAgents.
  ///
  /// In zh, this message translates to:
  /// **'群内 Agent'**
  String get scheduledTasks_form_selectGroupAgents;

  /// No description provided for @scheduledTasks_form_selectMentions.
  ///
  /// In zh, this message translates to:
  /// **'@提及的 Agent（可选）'**
  String get scheduledTasks_form_selectMentions;

  /// No description provided for @scheduledTasks_missingChannel.
  ///
  /// In zh, this message translates to:
  /// **'请选择频道'**
  String get scheduledTasks_missingChannel;

  /// No description provided for @scheduledTasks_missingGroupAgents.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个 Agent'**
  String get scheduledTasks_missingGroupAgents;

  /// No description provided for @scheduledTasks_form_scheduleTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'时间规则类型'**
  String get scheduledTasks_form_scheduleTypeLabel;

  /// No description provided for @scheduledTasks_form_scheduleType_interval.
  ///
  /// In zh, this message translates to:
  /// **'间隔重复'**
  String get scheduledTasks_form_scheduleType_interval;

  /// No description provided for @scheduledTasks_form_scheduleType_cron.
  ///
  /// In zh, this message translates to:
  /// **'Cron 计划'**
  String get scheduledTasks_form_scheduleType_cron;

  /// No description provided for @scheduledTasks_form_scheduleType_once.
  ///
  /// In zh, this message translates to:
  /// **'一次性'**
  String get scheduledTasks_form_scheduleType_once;

  /// No description provided for @scheduledTasks_form_interval_value.
  ///
  /// In zh, this message translates to:
  /// **'间隔数值'**
  String get scheduledTasks_form_interval_value;

  /// No description provided for @scheduledTasks_form_interval_unit_minutes.
  ///
  /// In zh, this message translates to:
  /// **'分钟'**
  String get scheduledTasks_form_interval_unit_minutes;

  /// No description provided for @scheduledTasks_form_interval_unit_hours.
  ///
  /// In zh, this message translates to:
  /// **'小时'**
  String get scheduledTasks_form_interval_unit_hours;

  /// No description provided for @scheduledTasks_form_interval_unit_days.
  ///
  /// In zh, this message translates to:
  /// **'天'**
  String get scheduledTasks_form_interval_unit_days;

  /// No description provided for @scheduledTasks_form_interval_preview.
  ///
  /// In zh, this message translates to:
  /// **'每 {value} {unit}执行一次'**
  String scheduledTasks_form_interval_preview(String value, String unit);

  /// No description provided for @scheduledTasks_form_preset_label.
  ///
  /// In zh, this message translates to:
  /// **'快捷预设'**
  String get scheduledTasks_form_preset_label;

  /// No description provided for @scheduledTasks_form_preset_5min.
  ///
  /// In zh, this message translates to:
  /// **'5分钟'**
  String get scheduledTasks_form_preset_5min;

  /// No description provided for @scheduledTasks_form_preset_30min.
  ///
  /// In zh, this message translates to:
  /// **'30分钟'**
  String get scheduledTasks_form_preset_30min;

  /// No description provided for @scheduledTasks_form_preset_1h.
  ///
  /// In zh, this message translates to:
  /// **'1小时'**
  String get scheduledTasks_form_preset_1h;

  /// No description provided for @scheduledTasks_form_preset_6h.
  ///
  /// In zh, this message translates to:
  /// **'6小时'**
  String get scheduledTasks_form_preset_6h;

  /// No description provided for @scheduledTasks_form_preset_1d.
  ///
  /// In zh, this message translates to:
  /// **'每天'**
  String get scheduledTasks_form_preset_1d;

  /// No description provided for @scheduledTasks_form_cron_frequency.
  ///
  /// In zh, this message translates to:
  /// **'执行频率'**
  String get scheduledTasks_form_cron_frequency;

  /// No description provided for @scheduledTasks_form_cron_freq_daily.
  ///
  /// In zh, this message translates to:
  /// **'每天'**
  String get scheduledTasks_form_cron_freq_daily;

  /// No description provided for @scheduledTasks_form_cron_freq_weekly.
  ///
  /// In zh, this message translates to:
  /// **'每周'**
  String get scheduledTasks_form_cron_freq_weekly;

  /// No description provided for @scheduledTasks_form_cron_freq_monthly.
  ///
  /// In zh, this message translates to:
  /// **'每月'**
  String get scheduledTasks_form_cron_freq_monthly;

  /// No description provided for @scheduledTasks_form_cron_freq_custom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get scheduledTasks_form_cron_freq_custom;

  /// No description provided for @scheduledTasks_form_cron_time.
  ///
  /// In zh, this message translates to:
  /// **'执行时间'**
  String get scheduledTasks_form_cron_time;

  /// No description provided for @scheduledTasks_form_cron_weekdays.
  ///
  /// In zh, this message translates to:
  /// **'执行星期'**
  String get scheduledTasks_form_cron_weekdays;

  /// No description provided for @scheduledTasks_form_cron_monthdays.
  ///
  /// In zh, this message translates to:
  /// **'执行日期'**
  String get scheduledTasks_form_cron_monthdays;

  /// No description provided for @scheduledTasks_form_cron_advanced.
  ///
  /// In zh, this message translates to:
  /// **'查看 Cron 表达式'**
  String get scheduledTasks_form_cron_advanced;

  /// No description provided for @scheduledTasks_form_cron_preview.
  ///
  /// In zh, this message translates to:
  /// **'接下来的执行时间'**
  String get scheduledTasks_form_cron_preview;

  /// No description provided for @scheduledTasks_form_cron_custom_hint.
  ///
  /// In zh, this message translates to:
  /// **'分 时 日 月 周（如：0 9 * * 1-5）'**
  String get scheduledTasks_form_cron_custom_hint;

  /// No description provided for @scheduledTasks_form_cron_weekday_mon.
  ///
  /// In zh, this message translates to:
  /// **'一'**
  String get scheduledTasks_form_cron_weekday_mon;

  /// No description provided for @scheduledTasks_form_cron_weekday_tue.
  ///
  /// In zh, this message translates to:
  /// **'二'**
  String get scheduledTasks_form_cron_weekday_tue;

  /// No description provided for @scheduledTasks_form_cron_weekday_wed.
  ///
  /// In zh, this message translates to:
  /// **'三'**
  String get scheduledTasks_form_cron_weekday_wed;

  /// No description provided for @scheduledTasks_form_cron_weekday_thu.
  ///
  /// In zh, this message translates to:
  /// **'四'**
  String get scheduledTasks_form_cron_weekday_thu;

  /// No description provided for @scheduledTasks_form_cron_weekday_fri.
  ///
  /// In zh, this message translates to:
  /// **'五'**
  String get scheduledTasks_form_cron_weekday_fri;

  /// No description provided for @scheduledTasks_form_cron_weekday_sat.
  ///
  /// In zh, this message translates to:
  /// **'六'**
  String get scheduledTasks_form_cron_weekday_sat;

  /// No description provided for @scheduledTasks_form_cron_weekday_sun.
  ///
  /// In zh, this message translates to:
  /// **'日'**
  String get scheduledTasks_form_cron_weekday_sun;

  /// No description provided for @scheduledTasks_form_once_datetime.
  ///
  /// In zh, this message translates to:
  /// **'执行时间'**
  String get scheduledTasks_form_once_datetime;

  /// No description provided for @scheduledTasks_form_once_pickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get scheduledTasks_form_once_pickDate;

  /// No description provided for @scheduledTasks_form_once_pickTime.
  ///
  /// In zh, this message translates to:
  /// **'选择时间'**
  String get scheduledTasks_form_once_pickTime;

  /// No description provided for @scheduledTasks_form_saveAndActivate.
  ///
  /// In zh, this message translates to:
  /// **'保存并启用'**
  String get scheduledTasks_form_saveAndActivate;

  /// No description provided for @scheduledTasks_form_scheduleSection.
  ///
  /// In zh, this message translates to:
  /// **'时间规则'**
  String get scheduledTasks_form_scheduleSection;

  /// No description provided for @scheduledTasks_form_targetSection.
  ///
  /// In zh, this message translates to:
  /// **'执行目标'**
  String get scheduledTasks_form_targetSection;

  /// No description provided for @scheduledTasks_form_contentSection.
  ///
  /// In zh, this message translates to:
  /// **'任务内容'**
  String get scheduledTasks_form_contentSection;

  /// No description provided for @scheduledTasks_form_invalidInterval.
  ///
  /// In zh, this message translates to:
  /// **'请输入有效的间隔数值（最小 1）'**
  String get scheduledTasks_form_invalidInterval;

  /// No description provided for @scheduledTasks_form_invalidCron.
  ///
  /// In zh, this message translates to:
  /// **'请完善 Cron 规则配置'**
  String get scheduledTasks_form_invalidCron;

  /// No description provided for @scheduledTasks_form_invalidOnce.
  ///
  /// In zh, this message translates to:
  /// **'请选择一个未来的执行时间'**
  String get scheduledTasks_form_invalidOnce;

  /// No description provided for @scheduledTasks_form_oncePastError.
  ///
  /// In zh, this message translates to:
  /// **'执行时间必须在当前时间之后'**
  String get scheduledTasks_form_oncePastError;

  /// No description provided for @scheduledTasks_form_agentConversation.
  ///
  /// In zh, this message translates to:
  /// **'指定会话'**
  String get scheduledTasks_form_agentConversation;

  /// No description provided for @scheduledTasks_form_agentConversationHint.
  ///
  /// In zh, this message translates to:
  /// **'选择该智能体的会话（默认当前激活会话）'**
  String get scheduledTasks_form_agentConversationHint;

  /// No description provided for @scheduledTasks_form_agentNoConversation.
  ///
  /// In zh, this message translates to:
  /// **'该智能体暂无会话记录'**
  String get scheduledTasks_form_agentNoConversation;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
