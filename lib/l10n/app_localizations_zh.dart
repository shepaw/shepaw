// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '惜宝';

  @override
  String get appVersion => 'ShePaw v1.0.0';

  @override
  String get appDescription => '本地优先的 AI 伴侣与多 Agent 协作中枢';

  @override
  String get about_content =>
      '惜宝（ShePaw）是本地优先的 AI 伴侣与多 Agent 协作中枢。她可以是你的 AI 伴侣，也可以是你最忠实的闺蜜。相处越久，会越懂你。\n\n每个人都可以有多个 AI 助手，和一个「她」。数据默认留在本机，由你掌控。';

  @override
  String get about_legalese => '© 2026 ShePaw Contributors。以 MIT 许可证发布。';

  @override
  String get about_sourceRepo => '查看开源仓库';

  @override
  String get common_cancel => '取消';

  @override
  String get common_confirm => '确认';

  @override
  String get common_save => '保存';

  @override
  String get common_delete => '删除';

  @override
  String get common_edit => '编辑';

  @override
  String get common_close => '关闭';

  @override
  String get common_loading => '正在加载...';

  @override
  String get common_retry => '重试';

  @override
  String get common_ok => '知道了';

  @override
  String get common_copy => '复制';

  @override
  String get common_reply => '回复';

  @override
  String get common_search => '搜索';

  @override
  String get common_refresh => '刷新';

  @override
  String get common_clear => '清除';

  @override
  String get common_optional => '可选';

  @override
  String get common_listSeparator => '、';

  @override
  String get common_featureComingSoon => '功能即将推出';

  @override
  String common_operationFailed(String error) {
    return '操作失败: $error';
  }

  @override
  String common_error(String error) {
    return '错误: $error';
  }

  @override
  String get splash_loading => '正在加载...';

  @override
  String get login_title => '惜宝';

  @override
  String get login_subtitle => '请输入密码解锁';

  @override
  String get login_password => '密码';

  @override
  String get login_passwordHint => '请输入您的密码';

  @override
  String get login_button => '登录';

  @override
  String get login_forgotPassword => '忘记密码？';

  @override
  String get login_emptyPassword => '请输入密码';

  @override
  String get login_tooManyAttempts => '密码错误次数过多，请稍后再试';

  @override
  String login_wrongPassword(int attempts) {
    return '密码错误，请重试 ($attempts/3)';
  }

  @override
  String login_failed(String error) {
    return '登录失败: $error';
  }

  @override
  String get login_resetPasswordTitle => '重置密码';

  @override
  String get login_resetPasswordContent => '重置密码后将进入全新的数据空间。';

  @override
  String get login_resetPasswordVaultHint =>
      '旧数据会被安全加密保存，您可以随时通过 设置 → 历史数据保险库 用旧密码恢复。';

  @override
  String get login_confirmReset => '确认重置';

  @override
  String get passwordSetup_title => '设置登录密码';

  @override
  String get passwordSetup_subtitle => '请设置一个安全的密码来保护您的账户';

  @override
  String get passwordSetup_password => '设置密码';

  @override
  String get passwordSetup_passwordHint => '至少6位，包含字母和数字';

  @override
  String get passwordSetup_confirmPassword => '确认密码';

  @override
  String get passwordSetup_confirmPasswordHint => '请再次输入密码';

  @override
  String get passwordSetup_submit => '完成设置';

  @override
  String get passwordSetup_requirementsTitle => '密码要求：';

  @override
  String get passwordSetup_reqLength => '长度6-20位';

  @override
  String get passwordSetup_reqAlphaNum => '包含字母和数字';

  @override
  String get passwordSetup_reqSpecialChars => '建议使用特殊字符增强安全性';

  @override
  String get passwordSetup_emptyPassword => '请输入密码';

  @override
  String get passwordSetup_tooShort => '密码长度至少6位';

  @override
  String get passwordSetup_tooLong => '密码长度不超过20位';

  @override
  String get passwordSetup_needAlphaNum => '密码必须包含字母和数字';

  @override
  String get passwordSetup_mismatch => '两次输入的密码不一致';

  @override
  String get passwordSetup_setFailed => '密码设置失败，请重试';

  @override
  String passwordSetup_errorOccurred(String error) {
    return '发生错误: $error';
  }

  @override
  String get passwordSetup_agreePrefix => '我已阅读并同意';

  @override
  String get passwordSetup_and => '和';

  @override
  String get passwordSetup_termsNotAccepted => '请先阅读并同意服务条款和隐私政策';

  @override
  String get changePassword_title => '修改密码';

  @override
  String get changePassword_currentPassword => '当前密码';

  @override
  String get changePassword_currentPasswordHint => '请输入当前密码';

  @override
  String get changePassword_newPassword => '新密码';

  @override
  String get changePassword_newPasswordHint => '至少6位，包含字母和数字';

  @override
  String get changePassword_confirmNewPassword => '确认新密码';

  @override
  String get changePassword_confirmNewPasswordHint => '请再次输入新密码';

  @override
  String get changePassword_submit => '确认修改';

  @override
  String get changePassword_requirementsTitle => '新密码要求：';

  @override
  String get changePassword_reqLength => '长度6-20位';

  @override
  String get changePassword_reqAlphaNum => '包含字母和数字';

  @override
  String get changePassword_reqDifferent => '不能与当前密码相同';

  @override
  String get changePassword_emptyCurrentPassword => '请输入当前密码';

  @override
  String get changePassword_sameAsOld => '新密码不能与当前密码相同';

  @override
  String get changePassword_newMismatch => '两次输入的新密码不一致';

  @override
  String get changePassword_success => '密码修改成功';

  @override
  String get changePassword_wrongCurrent => '当前密码错误，请重试';

  @override
  String changePassword_failed(String error) {
    return '修改失败: $error';
  }

  @override
  String get home_noAgents => '暂无 Agent';

  @override
  String get home_noAgentsHint => '点击菜单添加 Agent';

  @override
  String get home_noMessages => '暂无消息';

  @override
  String get home_draftPrefix => '[草稿]';

  @override
  String get home_typing => '对方正在输入...';

  @override
  String get home_statusOnline => '在线';

  @override
  String get home_statusOffline => '离线';

  @override
  String get home_statusThinking => '思考中';

  @override
  String get home_yesterday => '昨天';

  @override
  String get home_weekMon => '周一';

  @override
  String get home_weekTue => '周二';

  @override
  String get home_weekWed => '周三';

  @override
  String get home_weekThu => '周四';

  @override
  String get home_weekFri => '周五';

  @override
  String get home_weekSat => '周六';

  @override
  String get home_weekSun => '周日';

  @override
  String get home_addAgent => '添加 Agent';

  @override
  String get home_createGroup => '创建群组';

  @override
  String get home_addDevice => '设备配对';

  @override
  String get home_scanConnect => '扫码连接';

  @override
  String get home_searchEmptyHint => '搜索 Agent、群组、消息和设备聊天';

  @override
  String get home_searchNoResults => '未找到相关结果';

  @override
  String get home_searchSectionAgents => 'Agent';

  @override
  String get home_searchSectionGroups => '群组';

  @override
  String get home_searchSectionMessages => '消息';

  @override
  String get home_searchSectionPeerMessages => '设备聊天';

  @override
  String home_agentsCount(int count) {
    return '$count agents';
  }

  @override
  String get home_collapsePeerAgents => '折叠 Agent';

  @override
  String get home_expandPeerAgents => '展开 Agent';

  @override
  String get drawer_myProfile => '我的资料';

  @override
  String get drawer_newAgent => '新建 Agent';

  @override
  String get drawer_newGroup => '新建群组';

  @override
  String get drawer_newDevice => '新建设备';

  @override
  String get drawer_settings => '设置';

  @override
  String get drawer_logout => '退出登录';

  @override
  String get logout_confirmTitle => '确认退出';

  @override
  String get logout_confirmContent => '确定要退出登录吗？';

  @override
  String get settings_title => '设置';

  @override
  String get settings_security => '安全';

  @override
  String get settings_changePassword => '修改密码';

  @override
  String get settings_changePasswordSub => '修改您的登录密码';

  @override
  String get settings_dataVault => '历史数据保险库';

  @override
  String get settings_dataVaultSub => '查看并恢复重置密码前的数据备份';

  @override
  String get vault_emptyTitle => '暂无历史备份';

  @override
  String get vault_emptyDesc => '每次重置密码时，旧数据会自动\n加密保存到此处';

  @override
  String get vault_infoBanner => '每次重置密码时，旧数据会自动加密保存。\n点击「恢复」并输入对应的旧密码即可还原数据。';

  @override
  String get vault_restoreTitle => '恢复旧数据';

  @override
  String vault_backupTime(String date) {
    return '备份时间: $date';
  }

  @override
  String vault_fileSize(String size) {
    return '文件大小: $size';
  }

  @override
  String vault_size(String size) {
    return '大小: $size';
  }

  @override
  String get vault_restorePasswordPrompt => '请输入该备份对应的旧密码以解锁：';

  @override
  String get vault_oldPassword => '旧密码';

  @override
  String get vault_restoreWarning => '恢复将覆盖当前所有数据，此操作不可撤销。';

  @override
  String get vault_confirmRestore => '确认恢复';

  @override
  String get vault_emptyPassword => '请输入旧密码';

  @override
  String get vault_restoreFailed => '密码错误或备份文件损坏，请重试';

  @override
  String get vault_restoreSuccess => '数据恢复成功！请重启应用以加载恢复的数据。';

  @override
  String get vault_deleteTitle => '删除备份';

  @override
  String vault_deleteConfirm(String date) {
    return '确定要永久删除此备份？\n\n备份时间: $date\n删除后数据将无法恢复。';
  }

  @override
  String get vault_deleted => '备份已删除';

  @override
  String get vault_restore => '恢复';

  @override
  String get vault_deleteTooltip => '删除备份';

  @override
  String vault_count(int count) {
    return '$count 个备份';
  }

  @override
  String get settings_biometric => '生物识别认证';

  @override
  String get settings_biometricSub => '使用指纹或面容 ID';

  @override
  String get settings_biometricComingSoon => '生物识别认证即将推出';

  @override
  String get settings_biometricNotSupported => '此设备不支持生物识别认证';

  @override
  String get settings_biometricEnablePrompt => '请先验证身份以启用生物识别';

  @override
  String get settings_biometricEnabled => '生物识别已启用';

  @override
  String get settings_biometricDisabled => '生物识别已关闭';

  @override
  String get login_biometricPrompt => '验证身份以登录惜宝';

  @override
  String get login_useBiometric => '使用生物识别登录';

  @override
  String get settings_account => '账户';

  @override
  String get settings_profile => '个人资料';

  @override
  String get settings_profileSub => '管理您的个人信息';

  @override
  String get settings_notifications => '通知';

  @override
  String get settings_notificationsSub => '管理推送通知';

  @override
  String get settings_dataManagement => '数据管理';

  @override
  String get settings_toolsSection => '工具与能力';

  @override
  String get settings_batteryOptimization => '电池优化';

  @override
  String get settings_batteryOptimizationSub => '关闭后可减少后台任务被系统中断';

  @override
  String get settings_skillsSub => '导入与管理 Agent 技能包';

  @override
  String get settings_cliSub => '配置系统 CLI 与 OS 工具';

  @override
  String get settings_exportData => '导出数据';

  @override
  String get settings_exportDataSub => '备份所有应用数据到文件';

  @override
  String get settings_clearAllData => '清除所有数据';

  @override
  String get settings_clearAllDataSub => '删除所有 Agent、消息和文件';

  @override
  String get settings_about => '关于';

  @override
  String get settings_aboutVersion => '版本 1.0.0';

  @override
  String get settings_checkForUpdates => '检查更新';

  @override
  String get settings_checkForUpdatesSub => '检查是否有最新版本';

  @override
  String get settings_checkForUpdatesNew => '新';

  @override
  String update_checkUrlSub(String url) {
    return '检查地址：$url';
  }

  @override
  String update_checkingFromUrl(String url) {
    return '正在从 $url 检查更新...';
  }

  @override
  String get update_editCheckDomain => '修改更新服务器';

  @override
  String get update_checkDomainTitle => '更新服务器域名';

  @override
  String get update_checkDomainHint => 'release.shepaw.com';

  @override
  String get update_checkDomainInvalid => '请输入有效的域名或 http/https 地址';

  @override
  String update_checkUrlFixedPath(String path) {
    return '检查路径：$path（固定）';
  }

  @override
  String get update_checkUrlReset => '恢复默认';

  @override
  String get update_checking => '正在检查更新...';

  @override
  String get update_upToDate => '已是最新版本';

  @override
  String update_upToDateSub(String version) {
    return 'Paw $version 已是最新版本。';
  }

  @override
  String get update_available => '发现新版本';

  @override
  String update_availableVersion(String version) {
    return 'Paw $version 现在可用';
  }

  @override
  String get update_mandatoryTitle => '强制更新';

  @override
  String update_mandatoryMessage(String version) {
    return '此更新为必须更新，请升级到 $version 版本才能继续使用 Paw。';
  }

  @override
  String get update_releaseNotes => '更新内容';

  @override
  String get update_downloadNow => '立即下载';

  @override
  String get update_remindLater => '稍后提醒';

  @override
  String get update_skipVersion => '跳过此版本';

  @override
  String get update_checkFailed => '无法检查更新，请检查网络连接。';

  @override
  String update_currentVersion(String version) {
    return '当前版本：$version';
  }

  @override
  String get update_downloading => '正在下载...';

  @override
  String update_downloadingFile(String fileName) {
    return '正在下载 $fileName';
  }

  @override
  String update_downloadProgress(String downloaded, String total) {
    return '$downloaded / $total';
  }

  @override
  String update_downloadSpeed(String speed) {
    return '$speed/秒';
  }

  @override
  String update_downloadTimeRemaining(String time) {
    return '剩余 $time';
  }

  @override
  String get update_downloadCompleted => '下载完成';

  @override
  String get update_downloadFailed => '下载失败';

  @override
  String get update_retryDownload => '重试下载';

  @override
  String update_notification_availableTitle(String version) {
    return '发现新版本 $version';
  }

  @override
  String get update_notification_availableBody => '点击查看更新详情';

  @override
  String get update_notification_readyTitle => '更新已就绪';

  @override
  String update_notification_readyBody(String version) {
    return '点击安装 $version';
  }

  @override
  String get update_action_accept => '立即下载';

  @override
  String get update_action_decline => '拒绝';

  @override
  String get update_action_installNow => '立即安装';

  @override
  String get update_action_installLater => '稍后';

  @override
  String get update_pendingInstallTitle => '更新已就绪';

  @override
  String update_pendingInstallBody(String version) {
    return '$version 已下载完成，是否立即安装？';
  }

  @override
  String get settings_privacyPolicy => '隐私政策';

  @override
  String get settings_termsOfService => '服务条款';

  @override
  String get settings_language => '语言';

  @override
  String get settings_languageSub => '更改应用显示语言';

  @override
  String get settings_languageFollowSystem => '跟随系统';

  @override
  String get settings_languageEnglish => 'English';

  @override
  String get settings_languageChinese => '中文';

  @override
  String get settings_languageDialogTitle => '选择语言';

  @override
  String get settings_exportDataTitle => '导出数据';

  @override
  String get settings_exportDataContent =>
      '将导出所有应用数据（包括 Agent 配置、聊天记录、文件等）为一个备份文件。\n\n导出完成后可以通过系统分享发送到其他位置。';

  @override
  String get settings_exportingData => '正在导出数据...';

  @override
  String get settings_exportSuccess => '数据导出成功';

  @override
  String settings_exportFailed(String error) {
    return '导出失败: $error';
  }

  @override
  String get settings_clearAllDataTitle => '清除所有数据';

  @override
  String get settings_clearAllDataContent =>
      '这将删除所有数据，包括：\n\n• 所有 Agent 配置\n• 所有聊天记录和消息\n• 所有文件和图片\n\n此操作不可恢复！建议先导出备份。\n\n是否继续？';

  @override
  String get settings_clearAllDataButton => '清除所有数据';

  @override
  String get settings_clearingAllData => '正在清除所有数据...';

  @override
  String get settings_clearAllDataSuccess => '所有数据已清除';

  @override
  String settings_clearAllDataFailed(String error) {
    return '清除数据失败: $error';
  }

  @override
  String get addAgent_connectTitle => '连接远端助手';

  @override
  String get addAgent_createTitle => '创建助手配置';

  @override
  String get addAgent_modeConnect => '连接远端 Agent';

  @override
  String get addAgent_modeCreate => '创建本地配置';

  @override
  String get addAgent_basicInfo => '基本信息';

  @override
  String get addAgent_agentName => '助手名称';

  @override
  String get addAgent_agentNameHint => '例如：我的 AI 助手';

  @override
  String get addAgent_agentNameRequired => '请输入助手名称';

  @override
  String get addAgent_agentBio => '助手描述（可选）';

  @override
  String get addAgent_agentBioHint => '简单描述这个助手的功能';

  @override
  String get addAgent_systemPrompt => 'Soul（可选）';

  @override
  String get addAgent_systemPromptHint => '定义 Agent 的身份、角色与原则（写入 soul.md）';

  @override
  String get addAgent_connectConfig => '连接配置';

  @override
  String get addAgent_tokenAuth => 'Token 认证';

  @override
  String get addAgent_tokenHint => '输入 Token 或点击右侧按钮随机生成';

  @override
  String get addAgent_generateToken => '随机生成 Token';

  @override
  String get addAgent_tokenRequired => '请输入或生成 Token';

  @override
  String get addAgent_endpointUrl => '端点 URL';

  @override
  String get addAgent_endpointUrlHint => 'ws://example.com:8080/acp/ws';

  @override
  String get addAgent_endpointHelper => '远端 Agent 的服务地址';

  @override
  String get addAgent_endpointRequired => '请输入端点 URL';

  @override
  String get addAgent_endpointInvalid =>
      '请输入有效的 URL（http://, https://, ws://, wss://）';

  @override
  String get addAgent_modelConfig => '模型配置';

  @override
  String get addAgent_modelConfigHint => '选择主对话模型；各场景未单独配置时，输入类场景默认继承主模型。';

  @override
  String get agentModelConfig_mainChat => '主对话模型';

  @override
  String get agentModelConfig_selectMainChat => '选择主对话模型';

  @override
  String get agentModelConfig_attachmentsSection => '按场景配置模型';

  @override
  String get addAgent_modelName => '模型名称';

  @override
  String get addAgent_modelNameHint => '输入模型名称';

  @override
  String get addAgent_selectModel => '选择模型';

  @override
  String get addAgent_apiKeyNotRequired => '本地服务无需 API Key';

  @override
  String get addAgent_apiKeyHint => '输入 API Key';

  @override
  String get addAgent_connectSteps => '连接步骤';

  @override
  String get addAgent_connectStep1 => '输入远端 Agent 提供的 Token 或随机生成';

  @override
  String get addAgent_connectStep2 => '填写远端 Agent 的服务地址';

  @override
  String get addAgent_connectStep3 => '连接成功后可以开始对话';

  @override
  String get addAgent_connectButton => '连接远端助手';

  @override
  String get addAgent_createButton => '创建助手配置';

  @override
  String addAgent_createFailed(String error) {
    return '创建失败: $error';
  }

  @override
  String get addAgent_testingConnection => '正在测试 Agent 连接...';

  @override
  String get addAgent_connectSuccess => '连接成功！Agent 在线可用';

  @override
  String get addAgent_createSuccess => '助手创建成功！';

  @override
  String get addAgent_connectFailTitle => '连接测试失败';

  @override
  String get addAgent_connectFailContent =>
      'Agent 健康检查失败，无法建立连接。\n\n可能的原因：\n• Endpoint URL 不正确\n• Token 无效\n• Agent 服务未运行\n• 网络连接问题\n\n是否仍要保留此 Agent 配置？';

  @override
  String get addAgent_deleteConfig => '删除配置';

  @override
  String get addAgent_keepConfig => '保留配置';

  @override
  String get addAgent_configDeleted => '已删除 Agent 配置';

  @override
  String get addAgent_configKeptOffline => '已保留 Agent 配置（离线状态）';

  @override
  String addAgent_operationFailed(String error) {
    return '操作失败: $error';
  }

  @override
  String get addAgent_duplicateTitle => 'Agent 已存在';

  @override
  String get addAgent_existingInfo => '已有 Agent 信息：';

  @override
  String addAgent_existingName(String name) {
    return '名称: $name';
  }

  @override
  String addAgent_existingProtocol(String protocol) {
    return '协议: $protocol';
  }

  @override
  String get addAgent_selectAvatar => '选择头像';

  @override
  String get addAgent_endpointConfigTitle => '端点配置';

  @override
  String get addAgent_endpointOptional => '端点 URL（可选）';

  @override
  String get addAgent_endpointOptionalHelper => '可以稍后配置';

  @override
  String get addAgent_remoteAgentId => '远端 Agent ID';

  @override
  String get addAgent_remoteAgentIdHint => '可选，对方 Agent 的 ID';

  @override
  String get addAgent_remoteAgentIdHelper => '填写后可精确连接指定 Agent（可选）';

  @override
  String get createGroup_title => '创建群聊';

  @override
  String get createGroup_create => '创建';

  @override
  String get createGroup_groupName => '群聊名称';

  @override
  String get createGroup_purpose => '群聊目的（可选）';

  @override
  String get createGroup_purposeHint => '例如：协作完成前端开发任务';

  @override
  String get createGroup_selectAgent => '选择 Agent';

  @override
  String createGroup_agentCount(int selected, int total) {
    return '($selected/$total 个)';
  }

  @override
  String get createGroup_noAgents => '暂无 Agent，请先添加 Agent';

  @override
  String get createGroup_setAsAdmin => '设为管理员';

  @override
  String get createGroup_nameRequired => '请输入群聊名称';

  @override
  String get createGroup_agentRequired => '请至少选择一个 Agent';

  @override
  String get createGroup_adminRequired => '请选择一个 Admin（管理员）';

  @override
  String get createGroup_button => '创建群聊';

  @override
  String get createGroup_systemPrompt => '系统提示词（可选）';

  @override
  String get createGroup_systemPromptHint => '为群内 Agent 定义约束或指令';

  @override
  String get createGroup_groupRole => '群内职责（可选）';

  @override
  String get createGroup_groupRoleHint => '描述该 Agent 在本群中的职责';

  @override
  String get createGroup_maxLoopRounds => '最大编排轮次';

  @override
  String get createGroup_maxLoopRoundsHint => '管理员循环编排的最大轮次（默认 50）';

  @override
  String get permission_title => '权限请求管理';

  @override
  String get permission_filterLabel => '状态筛选：';

  @override
  String get permission_noRequests => '暂无权限请求';

  @override
  String permission_noRequestsOfType(String status) {
    return '暂无$status的权限请求';
  }

  @override
  String permission_loadFailed(String error) {
    return '加载失败: $error';
  }

  @override
  String get permission_approved => '权限已批准';

  @override
  String get permission_rejected => '权限已拒绝';

  @override
  String get permission_typeLabel => '权限类型';

  @override
  String get permission_reasonLabel => '请求原因';

  @override
  String get permission_timeLabel => '请求时间';

  @override
  String get permission_expiryLabel => '有效期至';

  @override
  String get permission_reject => '拒绝';

  @override
  String get permission_approve => '批准';

  @override
  String get permission_revoke => '撤销';

  @override
  String get permission_approveTitle => '批准权限';

  @override
  String permission_approveContent(String agentName, String permissionType) {
    return '确定要批准 $agentName 的 $permissionType 权限吗？';
  }

  @override
  String get permission_rejectTitle => '拒绝权限';

  @override
  String permission_rejectContent(String agentName) {
    return '确定要拒绝 $agentName 的权限请求吗？';
  }

  @override
  String get permission_revokeTitle => '撤销权限';

  @override
  String permission_revokeContent(String agentName) {
    return '确定要撤销 $agentName 的权限吗？撤销后该 Agent 将无法继续访问相关功能。';
  }

  @override
  String get permission_statusPending => '待审批';

  @override
  String get permission_statusApproved => '已批准';

  @override
  String get permission_statusRejected => '已拒绝';

  @override
  String get permission_statusExpired => '已过期';

  @override
  String get permission_typeInitiateChat => '发起聊天';

  @override
  String get permission_typeGetAgentList => '获取 Agent 列表';

  @override
  String get permission_typeGetCapabilities => '获取 Agent 能力';

  @override
  String get permission_typeSubscribeChannel => '订阅 Channel';

  @override
  String get permission_typeSendFile => '发送文件';

  @override
  String get permission_typeGetSessions => '获取会话列表';

  @override
  String get permission_typeGetSessionMessages => '获取会话消息';

  @override
  String get permission_typeGetAttachmentContent => '获取附件内容';

  @override
  String get permissionDialog_title => '权限请求';

  @override
  String get permissionDialog_agent => 'Agent';

  @override
  String get permissionDialog_action => '操作';

  @override
  String get permissionDialog_reason => '原因';

  @override
  String get permissionDialog_time => '时间';

  @override
  String get permissionDialog_reject => '拒绝';

  @override
  String get permissionDialog_approve => '批准';

  @override
  String get log_title => '系统日志';

  @override
  String get log_filterTooltip => '筛选日志级别';

  @override
  String get log_all => '全部';

  @override
  String get log_enableAutoScroll => '启用自动滚动';

  @override
  String get log_disableAutoScroll => '禁用自动滚动';

  @override
  String get log_export => '导出日志';

  @override
  String get log_exported => '日志已导出';

  @override
  String get log_clearTitle => '清除日志';

  @override
  String get log_clearContent => '确定要清除所有日志吗？此操作不可恢复。';

  @override
  String get log_clearButton => '清除';

  @override
  String get log_noLogs => '暂无日志';

  @override
  String get log_total => '总计';

  @override
  String get log_filterByTag => '按标签筛选';

  @override
  String get log_allTags => '全部标签';

  @override
  String get log_levelDebug => 'Debug';

  @override
  String get log_levelInfo => 'Info';

  @override
  String get log_levelWarning => 'Warning';

  @override
  String get log_levelError => 'Error';

  @override
  String get log_searchHint => '搜索日志';

  @override
  String get log_problemsOnly => '仅问题';

  @override
  String get log_visible => '可见';

  @override
  String get log_noMatch => '没有匹配的日志';

  @override
  String get log_noMatchHint => '试试调整筛选条件或搜索关键词。';

  @override
  String get log_emptyHint => '运行过程中产生的系统日志会显示在这里。';

  @override
  String get log_cleared => '日志已清除';

  @override
  String get log_copied => '已复制到剪贴板';

  @override
  String get agentDetail_title => 'Agent 详情';

  @override
  String get agentDetail_editTitle => '编辑 Agent';

  @override
  String get agentDetail_editTooltip => '编辑';

  @override
  String get agentDetail_startConversation => '发起对话';

  @override
  String get agentDetail_deleteAgent => '删除 Agent';

  @override
  String get agentDetail_confirmDelete => '确认删除';

  @override
  String agentDetail_deleteContent(String name) {
    return '确定要删除助手「$name」吗？\n\n删除后将无法恢复，相关的聊天记录也可能受到影响。';
  }

  @override
  String agentDetail_deleted(String name) {
    return '已删除「$name」';
  }

  @override
  String agentDetail_deleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String get agentDetail_connectionInfo => '连接信息';

  @override
  String get agentDetail_protocol => '协议';

  @override
  String get agentDetail_connectionType => '连接方式';

  @override
  String get agentDetail_endpoint => '端点';

  @override
  String get agentDetail_capabilities => '能力';

  @override
  String get agentDetail_systemPrompt => 'Soul';

  @override
  String get agentDetail_llmConfig => '模型配置';

  @override
  String get agentDetail_provider => '服务商';

  @override
  String get agentDetail_model => '模型';

  @override
  String get agentDetail_mode => '模式';

  @override
  String get agentDetail_lastActive => '最后活跃';

  @override
  String get agentDetail_createdAt => '创建时间';

  @override
  String get agentDetail_updatedAt => '更新时间';

  @override
  String get agentDetail_sourceDevice => '来源设备';

  @override
  String get agentDetail_peerTunnel => 'P2P 隧道（配对设备）';

  @override
  String get agentDetail_cliCommands => 'CLI 命令';

  @override
  String get agentDetail_allCliCommands => '全部可用（默认放行）';

  @override
  String get agentDetail_authToken => '认证 Token';

  @override
  String get agentDetail_copyToken => '复制 Token';

  @override
  String get agentDetail_tokenCopied => 'Token 已复制到剪贴板';

  @override
  String get agentDetail_nameRequired => '助手名称不能为空';

  @override
  String get agentDetail_tokenRequired => 'Token 不能为空';

  @override
  String get agentDetail_tokenHint => '粘贴远端 Agent 提供的 Token';

  @override
  String get agentDetail_saveSuccess => '保存成功';

  @override
  String agentDetail_saveFailed(String error) {
    return '保存失败: $error';
  }

  @override
  String get agentDetail_changeAvatar => '更换头像';

  @override
  String get agentDetail_selectBuiltinAvatar => '选择内置图标';

  @override
  String get agentDetail_selectFromGallery => '从相册选择';

  @override
  String get agentDetail_takePhoto => '拍照';

  @override
  String agentDetail_galleryFailed(String error) {
    return '选择图片失败: $error';
  }

  @override
  String agentDetail_cameraFailed(String error) {
    return '拍照失败: $error';
  }

  @override
  String agentDetail_saveImageFailed(String error) {
    return '保存图片失败: $error';
  }

  @override
  String get agentDetail_protocolType => '协议类型';

  @override
  String get agentDetail_connectionTypeLabel => '连接方式';

  @override
  String get agentDetail_custom => '自定义';

  @override
  String get agentDetail_copyTokenTooltip => '复制 Token';

  @override
  String get agentDetail_justNow => '刚刚';

  @override
  String agentDetail_minutesAgo(int minutes) {
    return '$minutes 分钟前';
  }

  @override
  String agentDetail_hoursAgo(int hours) {
    return '$hours 小时前';
  }

  @override
  String get profile_title => '我的资料';

  @override
  String get profile_email => '邮箱';

  @override
  String get profile_phone => '电话';

  @override
  String get profile_birthday => '生日';

  @override
  String get profile_location => '位置';

  @override
  String get profile_notSet => '未设置';

  @override
  String get profile_agents => 'Agent';

  @override
  String get profile_groups => '群组';

  @override
  String get profile_messages => '消息';

  @override
  String get profile_editProfile => '编辑资料';

  @override
  String get collaboration_title => 'Agent 协作';

  @override
  String get collaboration_description => '让多个 Agent 协作完成复杂任务，支持多种协作策略。';

  @override
  String get collaboration_taskName => '任务名称';

  @override
  String get collaboration_taskNameHint => '例: 市场调研报告';

  @override
  String get collaboration_taskNameRequired => '请输入任务名称';

  @override
  String get collaboration_taskDescription => '任务描述';

  @override
  String get collaboration_taskDescriptionHint => '详细描述要完成的任务';

  @override
  String get collaboration_taskDescriptionRequired => '请输入任务描述';

  @override
  String get collaboration_initialMessage => '初始消息';

  @override
  String get collaboration_initialMessageHint => '开始协作的消息';

  @override
  String get collaboration_initialMessageRequired => '请输入初始消息';

  @override
  String get collaboration_strategy => '协作策略';

  @override
  String get collaboration_selectAgent => '选择 Agent';

  @override
  String collaboration_selectedCount(int selected, int total) {
    return '已选择 $selected/$total';
  }

  @override
  String get collaboration_noAgents => '暂无可用的 Agent';

  @override
  String get collaboration_noDescription => '无描述';

  @override
  String get collaboration_start => '开始协作';

  @override
  String get collaboration_result => '协作结果';

  @override
  String get collaboration_finalOutput => '最终输出';

  @override
  String get collaboration_agentResults => '各 Agent 结果';

  @override
  String get collaboration_success => '协作任务执行成功';

  @override
  String collaboration_taskFailed(String error) {
    return '协作任务执行失败: $error';
  }

  @override
  String get collaboration_loadAgentFailed => '加载 Agent 失败';

  @override
  String get collaboration_executeFailed => '执行协作任务失败';

  @override
  String get collaboration_selectAgentWarning => '请至少选择一个 Agent';

  @override
  String get collaboration_strategySequential => '顺序执行';

  @override
  String get collaboration_strategyParallel => '并行执行';

  @override
  String get collaboration_strategyVoting => '投票机制';

  @override
  String get collaboration_strategyPipeline => '流水线';

  @override
  String get collaboration_strategySequentialDesc =>
      'Agent 按顺序依次处理，上一个的输出作为下一个的输入';

  @override
  String get collaboration_strategyParallelDesc => '所有 Agent 同时处理相同的输入';

  @override
  String get collaboration_strategyVotingDesc => '多个 Agent 投票选择最佳结果';

  @override
  String get collaboration_strategyPipelineDesc => '每个 Agent 处理特定阶段';

  @override
  String get collaboration_helpTitle => '协作策略说明';

  @override
  String get collaboration_helpSequential => 'Agent 按顺序依次处理，适合需要逐步优化的任务。';

  @override
  String get collaboration_helpParallel => '所有 Agent 同时处理，适合需要多角度分析的任务。';

  @override
  String get collaboration_helpVoting => '多个 Agent 投票选择最佳方案，适合决策类任务。';

  @override
  String get collaboration_helpPipeline => '每个 Agent 处理特定阶段，适合复杂的分步任务。';

  @override
  String get incoming_title => '主动消息';

  @override
  String incoming_unreadCount(int count) {
    return '$count 条未读';
  }

  @override
  String get incoming_clearAll => '清空所有消息';

  @override
  String get incoming_noMessages => '暂无主动消息';

  @override
  String get incoming_noMessagesHint => '当 Agent 主动联系您时，消息会显示在这里';

  @override
  String get incoming_markAsRead => '标记已读';

  @override
  String get incoming_view => '查看';

  @override
  String incoming_time(String time) {
    return '时间: $time';
  }

  @override
  String get incoming_clearAllTitle => '清空所有消息';

  @override
  String get incoming_clearAllContent => '确定要清空所有消息吗？此操作不可撤销。';

  @override
  String get incoming_clearButton => '清空';

  @override
  String get incoming_justNow => '刚刚';

  @override
  String incoming_minutesAgo(int minutes) {
    return '$minutes 分钟前';
  }

  @override
  String incoming_hoursAgo(int hours) {
    return '$hours 小时前';
  }

  @override
  String incoming_daysAgo(int days) {
    return '$days 天前';
  }

  @override
  String get chat_noAgentSelected => '未选择 Agent';

  @override
  String get chat_modalityNotSupported_image =>
      '此 Agent 未配置图片理解。请在 Agent 设置 → 模型配置中指定，或为主模型勾选「图片理解」。';

  @override
  String get chat_modalityNotSupported_audio =>
      '此 Agent 未配置音频理解。请在 Agent 设置 → 模型配置中配置。';

  @override
  String get chat_modalityNotSupported_video =>
      '此 Agent 未配置视频理解。请在 Agent 设置 → 模型配置中配置。';

  @override
  String chat_loadFailed(String error) {
    return '加载消息失败: $error';
  }

  @override
  String get chat_checkingHealth => '正在检查 Agent 状态...';

  @override
  String chat_reconnectingAttempt(int attempt, int total) {
    return '正在重连… ($attempt/$total)';
  }

  @override
  String get chat_reconnectFailed => '无法连接到 Agent，请检查 Agent 是否在线。';

  @override
  String chat_responseError(String agentName) {
    return '获取 $agentName 的回复失败';
  }

  @override
  String get chat_voiceTooShort => '语音消息太短';

  @override
  String get chat_historyRequestTitle => 'Agent 请求查看更多聊天记录';

  @override
  String get chat_historyIgnore => '忽略';

  @override
  String get chat_historyApprove => '同意';

  @override
  String get chat_loadingHistory => '正在加载更多聊天记录...';

  @override
  String get chat_noMoreHistory => '没有更多历史记录可加载';

  @override
  String get chat_historyLoaded => '历史记录已加载，Agent 正在重新回答...';

  @override
  String chat_historyLoadFailed(String error) {
    return '加载历史记录失败: $error';
  }

  @override
  String get chat_historyIgnored => '已忽略历史记录请求';

  @override
  String get chat_messageHint => '输入消息...';

  @override
  String get chat_send => '发送';

  @override
  String get chat_holdToRecord => '按住录制语音消息';

  @override
  String get chat_holdToTalk => '按住 说话';

  @override
  String get chat_releaseToSend => '松开 发送';

  @override
  String get chat_releaseToCancel => '松开 取消';

  @override
  String get chat_micNotAvailable => '无法开始录音，麦克风可能不可用。';

  @override
  String get chat_photoLibrary => '相册';

  @override
  String get chat_camera => '相机';

  @override
  String get chat_file => '文件';

  @override
  String get chat_storageBag => '储物袋';

  @override
  String get chat_storageFilePickerTitle => '选择储物袋文件';

  @override
  String get chat_storageFilePickerHint => '从本机储物袋空间选择文件作为聊天附件。';

  @override
  String get chat_storageFilePickerConfirm => '添加';

  @override
  String get chat_storageFilePickerEmpty => '当前空间暂无文件';

  @override
  String chat_storageFilePickerSelected(int count) {
    return '已选 $count';
  }

  @override
  String chat_sendImageError(String error) {
    return '发送图片失败: $error';
  }

  @override
  String chat_sendFileError(String error) {
    return '发送文件失败: $error';
  }

  @override
  String chat_searchError(String error) {
    return '搜索出错: $error';
  }

  @override
  String get chat_cannotDelete => '无法删除此消息';

  @override
  String get chat_deleteTitle => '删除消息';

  @override
  String get chat_deleteContent => '确定要删除这条消息吗？';

  @override
  String get chat_deleted => '消息已删除';

  @override
  String get chat_rollbackTitle => '回滚消息';

  @override
  String get chat_reEditTitle => '重新编辑消息';

  @override
  String get chat_rollbackContent => '这将删除此消息及之后的所有消息，此操作不可撤销。';

  @override
  String chat_rollbackSuccess(int count) {
    return '已回滚 $count 条消息';
  }

  @override
  String chat_reEditSuccess(int count) {
    return '重新编辑消息：已回滚 $count 条消息';
  }

  @override
  String chat_rollbackFailed(String error) {
    return '回滚失败: $error';
  }

  @override
  String get chat_copiedToClipboard => '已复制到剪贴板';

  @override
  String get chat_download => '下载';

  @override
  String get chat_rollback => '回滚';

  @override
  String get chat_rollbackSub => '删除此消息及之后的所有消息';

  @override
  String get chat_reEdit => '重新编辑';

  @override
  String get chat_reEditSub => '回滚并编辑此消息';

  @override
  String get chat_editGroupInfo => '编辑群组信息';

  @override
  String get chat_groupName => '群组名称';

  @override
  String get chat_groupDescription => '描述（可选）';

  @override
  String get chat_groupNameEmpty => '群组名称不能为空';

  @override
  String get chat_groupMembers => '群组成员';

  @override
  String chat_groupMembersCount(int count) {
    return '$count 个 Agent';
  }

  @override
  String get chat_addMember => '添加成员';

  @override
  String get chat_noMoreAgents => '没有更多可添加的 Agent';

  @override
  String get chat_changeAdmin => '更换管理员';

  @override
  String chat_currentAdmin(String name) {
    return '当前: $name';
  }

  @override
  String chat_adminChanged(String name) {
    return '$name 已成为管理员';
  }

  @override
  String get chat_removeMember => '移除成员';

  @override
  String chat_removeMemberContent(String name) {
    return '确定要将 $name 移出群组吗？';
  }

  @override
  String get chat_removeButton => '移除';

  @override
  String get chat_cannotRemoveLast => '无法移除最后一个成员';

  @override
  String get chat_waitingForAction => '等待你的操作';

  @override
  String get chat_searchMessages => '搜索消息';

  @override
  String get chat_workflow => '工作流';

  @override
  String get chat_newSession => '新建会话';

  @override
  String get chat_sessionList => '会话列表';

  @override
  String get chat_sessionHistory => '会话历史';

  @override
  String get chat_clearSessionHistory => '清除会话历史';

  @override
  String get chat_clearSessionSub => '清除当前会话并重置 Agent';

  @override
  String get chat_clearSessionSubSingle => '清除当前会话并重置远端 Agent';

  @override
  String get chat_clearAllSessions => '清除所有会话';

  @override
  String get chat_clearAllSessionsSub => '清除所有会话并重置 Agent';

  @override
  String get chat_clearAllSessionsSubSingle => '清除所有会话并重置远端 Agent';

  @override
  String get chat_resetSession => '重置会话';

  @override
  String get chat_editAgent => '编辑 Agent';

  @override
  String get chat_viewDetails => '查看详情';

  @override
  String get chat_storageSpace => '储物空间';

  @override
  String get chat_customSystemPrompt => '编辑 Soul';

  @override
  String get chat_systemPromptTitle => '编辑 Soul';

  @override
  String get chat_systemPromptHint => 'Agent 的身份与角色定义（soul.md）';

  @override
  String get chat_systemPromptSaved => 'Soul 已保存';

  @override
  String get chat_soulTitle => '编辑 Soul';

  @override
  String get chat_soulHint => 'Agent 的身份与角色定义（soul.md）';

  @override
  String get chat_soulSaved => 'Soul 已保存';

  @override
  String get chat_soulDenied => '对端未允许修改 Soul';

  @override
  String get chat_soulReadOnlyPeer => '只读：宿主未开启配对设备修改 Soul';

  @override
  String get chat_moreActions => '更多操作';

  @override
  String get chat_clearSessionTitle => '清除会话历史';

  @override
  String get chat_clearSessionContent => '这将删除当前会话的所有消息并重置远端 Agent 连接，此操作不可撤销。';

  @override
  String get chat_clearSessionGroupContent =>
      '这将删除当前会话的所有消息并重置所有 Agent 连接，此操作不可撤销。';

  @override
  String get chat_sessionCleared => '会话历史已清除';

  @override
  String chat_clearSessionFailed(String error) {
    return '清除会话失败: $error';
  }

  @override
  String get chat_clearAllSessionsTitle => '清除所有会话';

  @override
  String get chat_clearAllSessionsContent => '这将删除所有会话及其消息，仅保留默认会话，此操作不可撤销。';

  @override
  String get chat_clearAllGroupSessionsContent =>
      '这将删除此群组的所有会话及其消息，仅保留默认会话，此操作不可撤销。';

  @override
  String get chat_allSessionsCleared => '所有会话历史已清除';

  @override
  String get chat_allGroupSessionsCleared => '所有群组会话已清除';

  @override
  String get chat_groupSessionCleared => '群组会话历史已清除';

  @override
  String chat_clearGroupSessionFailed(String error) {
    return '清除群组会话失败: $error';
  }

  @override
  String chat_clearAllGroupSessionsFailed(String error) {
    return '清除所有群组会话失败: $error';
  }

  @override
  String get chat_clearingSession => '正在清除会话...';

  @override
  String get chat_clearingAllSessions => '正在清除所有会话...';

  @override
  String get chat_clearingGroupSession => '正在清除群组会话...';

  @override
  String get chat_clearingAllGroupSessions => '正在清除所有群组会话...';

  @override
  String get chat_noAdminSet => '未设置管理员';

  @override
  String get chat_groupSessions => '群组会话';

  @override
  String get chat_groupBoundInputDisabled => '此会话由群聊产生，不能在此直接对话';

  @override
  String get chat_openLinkedGroup => '打开群聊';

  @override
  String chat_openLinkedGroupNamed(String name) {
    return '打开群聊「$name」';
  }

  @override
  String get chat_sheBoundInputDisabled => '此会话来自 She 与助手的对话，不能在此直接发消息';

  @override
  String get chat_openLinkedShe => '打开 She 会话';

  @override
  String get chat_sessions => '会话';

  @override
  String chat_sessionsCount(int count) {
    return '$count 个会话';
  }

  @override
  String get chat_markAllSessionsRead => '全部已读';

  @override
  String get chat_mentionAll => '全部';

  @override
  String chat_mentionAllSub(int count) {
    return '提及全部 $count 个 Agent';
  }

  @override
  String get chat_mentionNotify => '通知 TA（触发回复）';

  @override
  String get chat_mentionCcOnly => '仅提及（不触发回复）';

  @override
  String get chat_add => '添加';

  @override
  String get chat_groupDescriptionOptional => '描述（可选）';

  @override
  String get chat_groupSystemPrompt => '系统提示词（可选）';

  @override
  String get chat_groupSystemPromptHint => '为群内 Agent 定义约束或指令';

  @override
  String chat_switchSession(String sessionId) {
    return '会话已清除，切换至 $sessionId';
  }

  @override
  String chat_allSessionsSwitched(String sessionId) {
    return '所有会话已清除，切换至 $sessionId';
  }

  @override
  String chat_clearAllSessionsFailed(String error) {
    return '清除所有会话失败: $error';
  }

  @override
  String get chat_deleteSession => '删除会话';

  @override
  String get chat_deleteSessionContent => '这将删除此会话及其所有消息，此操作不可撤销。';

  @override
  String get chat_deleteAllSessions => '删除所有会话';

  @override
  String get chat_deleteAllSessionsContent => '这将删除所有会话及其消息，仅保留默认会话，此操作不可撤销。';

  @override
  String get chat_deleteAllGroupSessionsContent =>
      '这将删除此群组的所有会话及其消息，仅保留默认会话，此操作不可撤销。';

  @override
  String chat_newSessionFailed(String error) {
    return '创建新会话失败: $error';
  }

  @override
  String chat_newGroupSessionFailed(String error) {
    return '创建新群组会话失败: $error';
  }

  @override
  String chat_loadSessionsFailed(String error) {
    return '加载会话失败: $error';
  }

  @override
  String chat_loadGroupSessionsFailed(String error) {
    return '加载群组会话失败: $error';
  }

  @override
  String chat_groupRoleTitle(String name) {
    return '$name - 群组角色';
  }

  @override
  String get chat_groupCapabilityLabel => '群组能力描述';

  @override
  String get chat_groupCapabilityHint => '留空则使用 Agent 的默认描述';

  @override
  String get chat_resetButton => '重置';

  @override
  String get chat_stopped => '已停止';

  @override
  String chat_groupChatError(String error) {
    return '群聊出错: $error';
  }

  @override
  String chat_fileMessageFailed(String error) {
    return '文件消息失败: $error';
  }

  @override
  String get status_online => '在线';

  @override
  String get status_offline => '离线';

  @override
  String get status_connecting => '连接中...';

  @override
  String get status_error => '错误';

  @override
  String get status_protocolAcp => 'ACP';

  @override
  String get status_protocolCustom => '自定义';

  @override
  String get widget_typing => '正在输入...';

  @override
  String get widget_collapseMessage => '折叠消息';

  @override
  String get widget_expandMessage => '展开消息';

  @override
  String get widget_stop => '停止';

  @override
  String widget_cannotOpenLink(String url) {
    return '无法打开链接: $url';
  }

  @override
  String get widget_originalMessageUnavailable => '原消息不可用';

  @override
  String get widget_retry => '重试';

  @override
  String get widget_formSubmitted => '表单已提交';

  @override
  String get widget_submit => '提交';

  @override
  String get widget_confirm => '确认';

  @override
  String get widget_changeFiles => '更换文件';

  @override
  String get widget_details => '详情';

  @override
  String get privacy_title => '隐私政策';

  @override
  String get privacy_content =>
      '隐私政策\n\n最后更新：2026-08-15\n\nShePaw / 惜宝（以下简称“我们”）致力于保护您的隐私。本应用采用本地优先设计：我们不运营收集用户数据的云后端，不内置广告或追踪分析，也不会在未经您配置的情况下上传您的个人数据。您的应用数据默认保留在本机，由您掌控。\n\n1. 本机存储的数据\n\n本应用不设强制云账号，也不运营自有的用户数据服务器。使用过程中产生的数据默认仅保存在您的设备上，可能包括：\n- 本地身份、设备配对与信任关系\n- Agent / 模型配置、技能包\n- 聊天消息、附件与对话历史\n- 用户资料、She 记忆与 Agent 记忆\n- 储物袋（Store）中的文件、工作区与产物\n- 推理日志、系统日志等诊断信息\n- 应用锁相关的密码哈希与生物识别偏好\n\n我们无法也不会访问这些本地数据，也不会出售您的个人数据。\n\n2. 何时数据会离开本机\n\n仅在您主动使用相关功能时，数据才会离开本机：\n- 您配置的 LLM、Agent 或 Hub 端点：消息、附件以及您授权的上下文会直接发往该端点\n- 设备配对与群组：按您的配对与授权，在设备间同步消息；储物袋中按信任关系或您显式分享的内容，可被已配对设备读取\n- 检查更新：应用可能向更新服务器（默认 release.shepaw.com，可自定义）发送平台类型、当前版本号与构建号，不含聊天内容或身份数据\n- 从 URL 导入技能包：会向您指定的地址发起下载请求\n\n我们不对第三方服务的数据处理行为负责。请只连接您信任的端点。\n\n3. 设备权限与本地能力\n\n按功能需要，应用可能请求：\n- 相机 / 相册：拍摄、选择或保存聊天图片\n- 麦克风：录制语音消息\n- 通知：Agent 消息与待审核提醒\n- 生物识别：解锁应用\n- 本地网络与后台：局域网 ACP、设备配对与本地服务（需您在设置中开启）\n\n系统工具（OS Tools）仅在您授权时访问本机文件、进程或系统信息。\n\n4. 数据安全（与实现对齐）\n\n- API Key、Noise 身份私钥等敏感凭证：优先使用平台安全存储（如 Keychain / Keystore）保管主密钥\n- 聊天记录、储物袋与一般业务数据：默认以本机 SQLite / 文件形式存储，当前不提供全库静态加密；设备备份、越狱/Root 或他人获得本机文件系统访问权时，可能读到这些内容\n- 可选应用锁（密码 / 生物识别）用于限制打开应用\n- 与远端 Agent / LLM 通信时，请使用您信任的端点；生产路径要求有效 TLS 证书\n\n5. 您的权利\n\n由于核心数据默认在本机，您可以随时：\n- 在应用内查看与管理资料、记忆、储物袋与聊天数据\n- 使用应用内导出功能备份数据\n- 通过清除应用数据或卸载应用删除本地数据\n- 解除设备配对，以停止与对端的同步及储物袋共享\n\n6. 儿童隐私\n\n本应用不面向未满 14 周岁的儿童，也不会故意收集儿童的个人信息。\n\n7. 政策变更\n\n我们可能会不时更新本隐私政策，并通过更新“最后更新”日期进行提示。如有疑问，请通过开源仓库 https://github.com/shepaw/shepaw 联系我们。';

  @override
  String get terms_title => '服务条款';

  @override
  String get terms_content =>
      '服务条款\n\n最后更新：2026-08-15\n\n请在使用 ShePaw / 惜宝（以下简称“本应用”或“我们”）之前仔细阅读这些服务条款。访问或使用本应用，即表示您同意受这些条款以及配套《隐私政策》的约束。如果您不同意，请勿使用本应用。\n\n1. 服务描述\n\n惜宝是一款本地优先的 AI 伴侣与多 Agent 协作中枢，允许您：\n- 与本机或您配置的远端 AI Agent / 模型对话\n- 管理多个 Agent、技能包与系统工具\n- 在群组中编排多 Agent 协作\n- 在已配对设备之间同步消息，并按信任关系或显式分享读取储物袋内容\n- 在本机保存聊天、记忆、资料与文件\n\n本应用不提供强制云账号，也不运营代您托管聊天内容的云服务。功能可用性因平台、配置与您连接的第三方端点而异。\n\n2. 开源许可与知识产权\n\n本应用以 MIT 许可证发布，版权归 ShePaw Contributors 所有。您可以按照 LICENSE 的条款使用、复制、修改和分发本软件。第三方库、模型与服务仍受其各自许可与条款约束。\n\n您在本应用中创建或导入的内容（包括聊天、附件、记忆、资料与储物袋文件）归您所有。您授予本应用仅在设备本地（以及您主动启用的配对、导出或第三方端点范围内）处理这些内容所必需的有限权限。\n\nShePaw、惜宝及相关标识用于识别本应用；未经允许，请勿以引人误解的方式使用这些标识。\n\n3. 用户责任\n\n您同意：\n- 遵守所有适用法律使用本应用\n- 不将本应用用于任何非法、侵权或未经授权的目的\n- 不试图破坏、干扰或未经授权访问本应用及其他用户的设备\n- 自行保管本机应用锁、API Key、配对信息与设备安全\n- 对您发送、存储、分享或授权 Agent 处理的内容负责\n- 对您配置的第三方端点、技能包来源以及授权系统工具执行的操作负责\n- 仅与您信任的设备配对；分享储物袋或开启本地服务前，请确认对端与网络环境可信\n\n系统工具可能在您授权后读写本机文件、执行命令或获取系统信息，相关风险由您承担。\n\n4. 第三方服务与端点\n\n本应用允许您连接第三方 LLM、Agent、Hub、技能包地址或更新服务器。这些服务由相应提供方运营，我们不控制其内容、可用性、收费或数据处理，也不对其条款或损害负责。使用这些服务时，您还需遵守对方的条款与政策。\n\n5. 免责声明\n\n本应用按“原样”和“可用”提供，不提供任何明示或默示保证，包括适销性、特定用途适用性与不侵权。我们不保证本应用将不间断、及时、安全或无错误地运行，也不保证 AI 生成内容准确、完整或适合您的用途。\n\n6. 责任限制\n\n在适用法律允许的最大范围内，我们不对因使用或无法使用本应用而产生的任何间接、偶发、特殊、后果性或惩罚性损害承担责任，包括数据丢失、业务中断，或因第三方服务、已配对设备、系统工具或您自行配置的端点造成的损失。\n\n7. 儿童使用\n\n本应用不面向未满 14 周岁的儿童。如果您未满该年龄，请不要使用本应用。\n\n8. 条款变更\n\n我们可能会不时更新这些条款，并通过更新“最后更新”日期进行提示。您在变更后继续使用本应用，即表示接受更新后的条款。\n\n9. 联系我们\n\n如有疑问，请通过开源仓库 https://github.com/shepaw/shepaw 联系我们。';

  @override
  String get notif_enableAll => '启用通知';

  @override
  String get notif_enableAllSub => '接收 Agent 消息通知';

  @override
  String get notif_sound => '声音';

  @override
  String get notif_soundSub => '通知时播放提示音';

  @override
  String get notif_showPreview => '显示预览';

  @override
  String get notif_showPreviewSub => '在通知中显示消息内容';

  @override
  String get notif_permissionDenied => '通知权限被拒绝，请在系统设置中开启。';

  @override
  String get notif_osPermissionOffTitle => '系统通知未开启';

  @override
  String get notif_osPermissionOffBody =>
      '请在系统设置中允许本应用发送通知，否则无法在离开 App 时提醒你审核。';

  @override
  String get notif_openSystemSettings => '去系统设置';

  @override
  String get notif_newMessage => '新消息';

  @override
  String notif_newMessageFrom(String name) {
    return '来自 $name 的新消息';
  }

  @override
  String get osTool_configTitle => 'CLI 管理';

  @override
  String get osTool_configHint => '启用 OS 级别工具，让 Agent 可以操作您的本地设备（文件、命令、剪贴板等）。';

  @override
  String get osTool_selectAll => '全选';

  @override
  String get osTool_deselectAll => '全不选';

  @override
  String get osTool_catCommand => '命令与系统';

  @override
  String get osTool_catFile => '文件操作';

  @override
  String get osTool_catApp => '应用与浏览器';

  @override
  String get osTool_catClipboard => '剪贴板';

  @override
  String get osTool_catMacos => 'macOS 专属';

  @override
  String get osTool_catProcess => '进程管理';

  @override
  String osTool_notSupported(String platform) {
    return '当前平台 ($platform) 不支持';
  }

  @override
  String get osTool_confirmTitle => '确认操作';

  @override
  String get osTool_confirmDescription => '此操作将在您的设备上执行。是否继续？';

  @override
  String get osTool_highRisk => '高风险';

  @override
  String get osTool_tool => '工具';

  @override
  String get osTool_approve => '批准';

  @override
  String get osTool_deny => '拒绝';

  @override
  String get skill_configTitle => '技能';

  @override
  String get skill_configHint => '启用基于 Markdown 的技能，引导 Agent 完成复杂的多步骤任务。';

  @override
  String get skill_selectAll => '全选';

  @override
  String get skill_deselectAll => '全不选';

  @override
  String get skill_rescan => '重新扫描';

  @override
  String get skill_noSkillsFound => '未找到技能。可导入技能 ZIP 包或将技能子目录添加到技能文件夹。';

  @override
  String get settings_agentConfig => 'Agent 配置';

  @override
  String get settings_skillDirectory => '技能管理';

  @override
  String get skillMgmt_title => '技能管理';

  @override
  String get skillMgmt_importZip => '导入技能 (ZIP)';

  @override
  String get skillMgmt_importing => '正在导入技能...';

  @override
  String skillMgmt_importSuccess(String name) {
    return '技能「$name」导入成功';
  }

  @override
  String skillMgmt_importFailed(String error) {
    return '导入失败: $error';
  }

  @override
  String get skillMgmt_deleteTitle => '删除技能';

  @override
  String skillMgmt_deleteContent(String name) {
    return '确定要删除技能「$name」吗？这将删除技能目录中的所有文件，且不可恢复。';
  }

  @override
  String skillMgmt_deleted(String name) {
    return '技能「$name」已删除';
  }

  @override
  String skillMgmt_deleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String get skillMgmt_noSkills => '未找到技能';

  @override
  String get skillMgmt_noSkillsHint => '导入技能 ZIP 包，或将技能子目录添加到配置的目录中。';

  @override
  String skillMgmt_fileCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
    );
    return '$_temp0';
  }

  @override
  String skillMgmt_skillCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个技能',
    );
    return '$_temp0';
  }

  @override
  String get skillMgmt_conflictTitle => '技能已存在';

  @override
  String skillMgmt_conflictContent(String name) {
    return '名为「$name」的技能已存在。是否替换？';
  }

  @override
  String get skillMgmt_replace => '替换';

  @override
  String get skillMgmt_rescan => '重新扫描';

  @override
  String get skillMgmt_openDirectory => '打开技能目录';

  @override
  String get skillMgmt_importUrl => '从 URL 导入';

  @override
  String get skillMgmt_importUrlTitle => '从 URL 导入技能';

  @override
  String get skillMgmt_importUrlHint => '输入 .zip 或 .md 文件的直链 URL';

  @override
  String skillMgmt_downloading(int percent) {
    return '下载中... $percent%';
  }

  @override
  String get skillMgmt_downloadingIndeterminate => '下载中...';

  @override
  String get skillMgmt_invalidUrl => 'URL 无效，请输入 .zip 或 .md 文件的 http/https 直链';

  @override
  String get agentDetail_noOsToolsEnabled => '未启用任何 OS 工具';

  @override
  String get agentDetail_noSkillsEnabled => '未启用任何技能';

  @override
  String get settings_developerTools => '开发者工具';

  @override
  String get settings_inferenceLog => '推理日志';

  @override
  String get settings_inferenceLogSub => '查看 LLM 请求/响应详情';

  @override
  String get settings_systemLog => '系统日志';

  @override
  String get settings_systemLogSub => '查看应用系统日志';

  @override
  String get inferenceLog_title => '推理日志';

  @override
  String get inferenceLog_empty => '暂无推理日志';

  @override
  String get inferenceLog_emptyHint => '与本地 LLM Agent 对话后，日志将显示在这里';

  @override
  String get inferenceLog_filterAll => '全部';

  @override
  String get inferenceLog_filterCompleted => '已完成';

  @override
  String get inferenceLog_filterError => '错误';

  @override
  String get inferenceLog_filterInProgress => '进行中';

  @override
  String get inferenceLog_total => '总计';

  @override
  String get inferenceLog_completed => '已完成';

  @override
  String get inferenceLog_errors => '错误';

  @override
  String get inferenceLog_inProgress => '进行中';

  @override
  String inferenceLog_rounds(int count) {
    return '$count 轮';
  }

  @override
  String inferenceLog_toolCalls(int count) {
    return '$count 次工具调用';
  }

  @override
  String get inferenceLog_clearTitle => '清除推理日志';

  @override
  String get inferenceLog_clearContent => '确定要清除所有推理日志吗？此操作不可恢复。';

  @override
  String get inferenceLog_clearButton => '清除';

  @override
  String get inferenceLog_cleared => '推理日志已清除';

  @override
  String get inferenceLog_exported => '推理日志已导出';

  @override
  String inferenceLog_exportFailed(String error) {
    return '导出失败: $error';
  }

  @override
  String get inferenceLog_loggingEnabled => '推理日志记录已启用';

  @override
  String get inferenceLog_loggingDisabled => '推理日志记录已关闭';

  @override
  String get inferenceLog_userMessage => '用户消息';

  @override
  String get inferenceLog_systemPrompt => '系统提示词';

  @override
  String inferenceLog_roundLabel(int number) {
    return '第 $number 轮';
  }

  @override
  String get inferenceLog_response => '响应';

  @override
  String inferenceLog_toolCall(String name) {
    return '工具调用: $name';
  }

  @override
  String inferenceLog_toolResult(String name) {
    return '工具结果: $name';
  }

  @override
  String get inferenceLog_stopReason => '停止原因';

  @override
  String get inferenceLog_error => '错误';

  @override
  String get inferenceLog_detailTitle => '推理详情';

  @override
  String get inferenceLog_timeline => '时间线';

  @override
  String get inferenceLog_noText => '（无文本）';

  @override
  String get chat_selectSessions => '选择会话';

  @override
  String chat_selectedCount(int count) {
    return '已选 $count 个';
  }

  @override
  String get chat_invertSelection => '反选';

  @override
  String chat_deleteSelected(int count) {
    return '删除 ($count)';
  }

  @override
  String chat_batchDeleteContent(int count) {
    return '确定删除 $count 个会话及其所有消息？此操作不可撤销。';
  }

  @override
  String chat_batchDeleteSuccess(int count) {
    return '已删除 $count 个会话';
  }

  @override
  String chat_maxAttachments(int count) {
    return '最多只能添加 $count 个附件';
  }

  @override
  String get chat_connectionInterrupted => '后台运行期间连接中断';

  @override
  String get chat_connectionInterruptedRetry => '重试';

  @override
  String get chat_peerTurnStillRunning => '上一轮回复仍在继续，完成后即可发送';

  @override
  String chat_loopRoundLimitReached(int count) {
    return '编排循环已达到最大轮次 $count 次，已自动停止。';
  }

  @override
  String get scenarioModels_title => '按场景配置模型';

  @override
  String get scenarioModels_hint =>
      '为图片/音频/视频理解，以及图片生成、语音合成、视频生成等场景指定模型；输入类场景未配置时继承主模型。';

  @override
  String get scenarioModels_inheritMain => '继承主模型';

  @override
  String get scenarioModels_inheritMainCovered => '继承主模型（已支持）';

  @override
  String get scenarioModels_notConfigured => '未配置';

  @override
  String get scenarioModels_coveredByMain => '主模型已支持全部输入场景，无需额外配置';

  @override
  String get scenarioModels_expandToOverride => '可展开为各附件类型单独指定模型';

  @override
  String scenarioModels_needsConfig(String modalities) {
    return '主模型未支持：$modalities';
  }

  @override
  String get scenarioModels_selectMainFirst => '请先选择主模型';

  @override
  String scenarioModels_configuredCount(int count) {
    return '已配置 $count 项';
  }

  @override
  String get modelRouting_title => '多模态模型路由';

  @override
  String get modelRouting_hint => '为不同内容类型配置不同的模型，未配置的项使用上方的默认模型。';

  @override
  String get modelRouting_text => '文本聊天';

  @override
  String get modelRouting_image => '图片理解';

  @override
  String get modelRouting_audio => '音频理解';

  @override
  String get modelRouting_video => '视频理解';

  @override
  String get modelRouting_modelHint => '模型名称（留空则继承默认）';

  @override
  String get modelRouting_providerHint => '服务商（留空则继承默认）';

  @override
  String get modelRouting_apiBaseHint => 'API Base（留空则继承默认）';

  @override
  String get modelRouting_apiKeyHint => 'API Key（留空则继承默认）';

  @override
  String get modelRouting_advanced => '高级';

  @override
  String get modelRouting_selectFromRegistry => '从模型列表选择';

  @override
  String get modelRouting_usingDefault => '使用默认模型';

  @override
  String get modelRouting_configured => '已配置';

  @override
  String get modelRouting_enableStreaming => '启用流式传输 (SSE)';

  @override
  String get modelRouting_apiPath => 'API 路径';

  @override
  String get modelRouting_apiPathHint => '覆盖端点路径（如 /images/generations）';

  @override
  String get modelRouting_requestBodyTemplate => '请求体模板';

  @override
  String get modelRouting_requestBodyTemplateHint =>
      'JSON 模板，支持 \$model、\$prompt 变量替换';

  @override
  String get modelRouting_responseBodyPath => '响应提取路径';

  @override
  String get modelRouting_responseBodyPathHint => 'JSON 路径提取内容（如 data[0].url）';

  @override
  String get modelRouting_customModalities => '自定义模态';

  @override
  String get modelRouting_customModalitiesHint => '定义自定义任务类型，通过意图识别自动路由';

  @override
  String get modelRouting_addCustomModality => '添加自定义模态';

  @override
  String get modelRouting_modalityKey => '标识符';

  @override
  String get modelRouting_modalityKeyHint => '如 image_gen、tts';

  @override
  String get modelRouting_modalityLabel => '显示名称';

  @override
  String get modelRouting_modalityLabelHint => '如 图片生成';

  @override
  String get modelRouting_modalityDescription => '意图描述';

  @override
  String get modelRouting_modalityDescriptionHint => '描述何时使用此模态（用于意图分类）';

  @override
  String get modelRouting_deleteModality => '删除';

  @override
  String addAgent_osToolsCount(int count) {
    return '已启用 $count 个工具';
  }

  @override
  String get addAgent_noOsTools => '未选择工具';

  @override
  String addAgent_skillsCount(int count) {
    return '已启用 $count 个技能';
  }

  @override
  String get addAgent_noSkills => '未选择技能';

  @override
  String addAgent_modelRoutingCount(int count) {
    return '已配置 $count 个模态';
  }

  @override
  String get addAgent_noModelRouting => '未配置';

  @override
  String get addAgent_configureTools => '配置工具';

  @override
  String get addAgent_configureSkills => '配置技能';

  @override
  String get addAgent_configureModelRouting => '配置模型路由';

  @override
  String get contacts_title => '通讯录';

  @override
  String get contacts_agents => '本机';

  @override
  String get contacts_groups => '群聊';

  @override
  String get contacts_devices => '设备';

  @override
  String get contacts_noPeers => '尚未配对任何设备';

  @override
  String get contacts_startPairing => '开始配对';

  @override
  String get contacts_addPairingDevice => '添加配对设备';

  @override
  String get contacts_noAgents => '暂无 Agent';

  @override
  String get contacts_noGroups => '暂无群聊';

  @override
  String contacts_agentCount(int count) {
    return '$count 个 Agent';
  }

  @override
  String contacts_groupCount(int count) {
    return '$count 个群聊';
  }

  @override
  String contacts_memberCount(int count) {
    return '$count 个成员';
  }

  @override
  String get groupDetail_title => '群组详情';

  @override
  String get groupDetail_editTitle => '编辑群组';

  @override
  String get groupDetail_editGroup => '编辑';

  @override
  String get groupDetail_members => '成员';

  @override
  String get groupDetail_admin => '管理员';

  @override
  String get groupDetail_member => '成员';

  @override
  String get groupDetail_systemPrompt => '系统提示词';

  @override
  String get groupDetail_maxLoopRounds => '最大编排轮次';

  @override
  String get groupDetail_startChat => '发起聊天';

  @override
  String get groupDetail_deleteGroup => '删除群组';

  @override
  String get groupDetail_confirmDelete => '删除群组？';

  @override
  String groupDetail_deleteContent(String name) {
    return '确定要删除群组「$name」吗？这将删除所有消息。';
  }

  @override
  String groupDetail_deleted(String name) {
    return '群组「$name」已删除';
  }

  @override
  String groupDetail_deleteFailed(String error) {
    return '删除群组失败: $error';
  }

  @override
  String get drawer_contacts => '通讯录';

  @override
  String get toolModel_managementTitle => '模型管理';

  @override
  String get toolModel_configTitle => '生成能力';

  @override
  String get toolModel_configHint =>
      'AI 在对话中可主动调用的能力，如图片生成、语音合成。处理用户附件请在上方「模型配置」中设置。';

  @override
  String get toolModel_configureTitle => '选择生成能力';

  @override
  String get toolModel_addTitle => '添加模型';

  @override
  String get toolModel_editTitle => '编辑模型';

  @override
  String get toolModel_displayName => '显示名称';

  @override
  String get toolModel_displayNameHint => '例如：图片生成、GPT-4o';

  @override
  String get toolModel_displayNameRequired => '请输入显示名称';

  @override
  String get toolModel_description => '描述';

  @override
  String get toolModel_descriptionHint => '作为工具模型时，此描述帮助 LLM 判断何时调用（可选）';

  @override
  String get toolModel_descriptionRequired => '请输入描述';

  @override
  String get toolModel_model => '模型';

  @override
  String get toolModel_modelHint => '例如：dall-e-3、gpt-4o';

  @override
  String get toolModel_modelRequired => '请输入模型名称';

  @override
  String get toolModel_apiBase => 'API 地址';

  @override
  String get toolModel_apiBaseHint => '例如：https://api.openai.com/v1';

  @override
  String get toolModel_apiBaseRequired => '请输入 API 地址';

  @override
  String get toolModel_apiKey => 'API Key';

  @override
  String get toolModel_apiKeyHint => '输入 API Key（可选）';

  @override
  String get toolModel_provider => '服务商';

  @override
  String get toolModel_providerHint => '例如：openai';

  @override
  String get toolModel_selectProvider => '选择服务商（自动填充 API 地址）';

  @override
  String get toolModel_customProvider => '自定义';

  @override
  String get toolModel_noModels => '暂无模型';

  @override
  String get toolModel_noModelsHint => '点击 + 添加模型配置，可供各 Agent 复用。';

  @override
  String get toolModel_noModelsAvailable => '尚未配置模型。请在设置 > 模型管理中添加。';

  @override
  String toolModel_count(int count) {
    return '$count 个模型';
  }

  @override
  String get toolModel_deleteTitle => '删除模型';

  @override
  String toolModel_deleteContent(String name) {
    return '确定要删除模型 $name 吗？';
  }

  @override
  String toolModel_deleted(String name) {
    return '模型 $name 已删除';
  }

  @override
  String get toolModel_selectAll => '全选';

  @override
  String get toolModel_deselectAll => '取消全选';

  @override
  String get toolModel_scenarioLabel => '使用场景';

  @override
  String get toolModel_scenarioHint => '描述何时应调用此模型（覆盖全局描述）';

  @override
  String get toolModel_scenarioPlaceholder => '例如：用于图片生成任务';

  @override
  String get toolModel_noGenerationModels =>
      '暂无可用的生成模型。请在设置 > 模型管理中添加图片生成、语音合成等模型。';

  @override
  String get addAgent_noToolModels => '未启用生成能力';

  @override
  String addAgent_toolModelsCount(int count) {
    return '已启用 $count 项生成能力';
  }

  @override
  String get agentDetail_noToolModelsEnabled => '未启用生成能力';

  @override
  String get chat_mentionMode => '提及模式';

  @override
  String get chat_mentionModeAdminOnly => '仅管理员';

  @override
  String get chat_mentionModeAllMembers => '所有成员';

  @override
  String get chat_mentionModeAdminOnlyDesc => '仅管理员可以 @提及并激活其他成员';

  @override
  String get chat_mentionModeAllMembersDesc => '任何成员都可以 @提及并激活其他成员';

  @override
  String get createGroup_mentionMode => '提及模式';

  @override
  String get chat_planningMode => '计划模式';

  @override
  String get chat_planningModeDesc => '启用后 Admin 会先生成任务计划，用户确认后再执行';

  @override
  String get chat_flowMode => 'Flow 模式';

  @override
  String get chat_flowModeDesc => 'Admin 生成阶段化 FlowPlan，各阶段串行、阶段内步骤并行执行';

  @override
  String get chat_viewTrace => '查看 Trace';

  @override
  String get modelType_sectionLabel => '模型类型';

  @override
  String get modelType_sectionHint => '选择此模型支持的能力类型（可多选）';

  @override
  String get modelType_text => '文本';

  @override
  String get modelType_imageUnderstanding => '图片理解';

  @override
  String get modelType_audioUnderstanding => '语音理解';

  @override
  String get modelType_videoUnderstanding => '视频理解';

  @override
  String get modelType_imageGeneration => '图片生成';

  @override
  String get modelType_tts => '语音合成';

  @override
  String get modelType_videoGeneration => '视频生成';

  @override
  String get common_required => '必填';

  @override
  String get addAgent_modelRequired => '请选择模型';

  @override
  String get addAgent_noModels => '未配置模型，请先在设置中添加模型';

  @override
  String get toolModel_goToManagement => '前往模型管理';

  @override
  String get ollama_testConnection => '测试连接';

  @override
  String get ollama_testConnectionSuccess => 'Ollama 连接成功';

  @override
  String ollama_testConnectionFailed(String error) {
    return 'Ollama 连接失败: $error';
  }

  @override
  String get agent_allowExternalAccess => '分享给配对设备';

  @override
  String get agent_allowExternalAccessDesc => '开启后，已配对的设备可在会话列表中看到并与该 agent 对话';

  @override
  String get agent_allowPeerSoulEdit => '允许配对设备修改 Soul';

  @override
  String get agent_allowPeerSoulEditDesc =>
      '开启后，已分享该 agent 的配对设备可远程读取并修改其 Soul';

  @override
  String get agent_externalAccessPeerEnabled =>
      '已开启：已配对的设备可在会话列表中看到并与该 agent 对话';

  @override
  String get agent_externalAccessDisabled => '未分享给配对设备';

  @override
  String get she_pinned_label => '置顶';

  @override
  String get she_name => '惜宝';

  @override
  String get she_bio => '主人的专属灵宠';

  @override
  String get settings_userProfile => '个人档案';

  @override
  String get settings_userProfileSub => '管理你的个人信息';

  @override
  String get settings_agentMemories => 'Agent 记忆';

  @override
  String get settings_agentMemoriesSub => '查看和管理每个 Agent 的记忆';

  @override
  String get memory_title => '记忆';

  @override
  String get memory_add => '添加笔记';

  @override
  String get memory_structured => '结构化视图';

  @override
  String get memory_timeline => '时间线';

  @override
  String get memory_export => '导出';

  @override
  String get memory_json => 'JSON';

  @override
  String get memory_markdown => 'Markdown';

  @override
  String get memory_clearAll => '清除全部';

  @override
  String get memory_delete => '删除';

  @override
  String get memory_noMemories => '暂无记忆';

  @override
  String get memory_addNoteHint => '添加笔记以保存记忆';

  @override
  String get memory_view => '查看';

  @override
  String get memory_noAgents => '没有可用的 Agent';

  @override
  String get memory_addAgents => '添加 Agent 以管理其记忆';

  @override
  String get memory_created => '创建于';

  @override
  String get memory_updated => '更新于';

  @override
  String get profile_personalTitle => '个人档案';

  @override
  String get profile_coreInfo => '核心信息';

  @override
  String get profile_extendedInfo => '附加信息';

  @override
  String get profile_customAttrs => '自定义属性';

  @override
  String get profile_add => '添加';

  @override
  String get profile_reset => '重置全部';

  @override
  String get profile_nameField => '姓名';

  @override
  String get profile_ageField => '年龄';

  @override
  String get profile_genderField => '性别';

  @override
  String get profile_occupationField => '职业';

  @override
  String get profile_cityField => '城市';

  @override
  String get profile_interestsField => '兴趣爱好';

  @override
  String get profile_interestsHint => '用逗号分隔';

  @override
  String get profile_valuesField => '价值观';

  @override
  String get profile_valuesHint => '对你最重要的是什么';

  @override
  String get profile_goalsField => '目标和需求';

  @override
  String get profile_goalsHint => '你的愿景和抱负';

  @override
  String get profile_communicationStyleField => '沟通风格';

  @override
  String get profile_communicationStyleHint => '你偏好的沟通方式';

  @override
  String get profile_workStyleField => '工作风格';

  @override
  String get profile_workStyleHint => '你的工作习惯和偏好';

  @override
  String get profile_lifeStageField => '人生阶段';

  @override
  String get profile_lifeStageHint => '如：学生、职场人士、退休人员';

  @override
  String get profile_importantPeopleField => '重要的人';

  @override
  String get profile_importantPeopleHint => '家人、朋友、导师';

  @override
  String get profile_healthField => '健康状况';

  @override
  String get profile_healthHint => '健康问题、过敏情况';

  @override
  String get profile_languageField => '语言偏好';

  @override
  String get profile_languageHint => '如：中文、English、日本語';

  @override
  String get profile_timezoneField => '时区';

  @override
  String get profile_timezoneHint => '如：CST、PST、UTC+8';

  @override
  String get profile_notesField => '其他备注';

  @override
  String get profile_notesHint => '其他任何补充信息';

  @override
  String get profile_addCustomTitle => '添加自定义属性';

  @override
  String get profile_attributeName => '属性名称';

  @override
  String get profile_attributeNameHint => '如：宠物名、最喜欢的食物';

  @override
  String get profile_attributeValue => '值';

  @override
  String get profile_attributeValueHint => '输入属性值';

  @override
  String get profile_removeAttrTitle => '删除属性';

  @override
  String profile_removeAttrContent(String name) {
    return '删除「$name」？';
  }

  @override
  String get profile_customLabel => '自定义';

  @override
  String get profile_noCustomAttrs => '暂无自定义属性，点击「添加」创建';

  @override
  String get profile_resetTitle => '重置档案';

  @override
  String get profile_resetContent => '这将清除所有个人信息，此操作不可撤销。';

  @override
  String get profile_saved => '档案已保存';

  @override
  String profile_saveFailed(String error) {
    return '保存出错: $error';
  }

  @override
  String get profile_loadFailed => '加载档案失败';

  @override
  String get profile_resetSuccess => '档案已重置';

  @override
  String get profile_resetFailed => '重置档案失败';

  @override
  String get profile_nameEmpty => '属性名称不能为空';

  @override
  String profile_nameReserved(String name) {
    return '「$name」是保留字段名';
  }

  @override
  String profile_nameDuplicate(String name) {
    return '「$name」已存在';
  }

  @override
  String get profile_nameStartWithUnderscore => '名称不能以下划线开头';

  @override
  String get profile_nameInvalidChars => '只允许使用字母、数字和下划线';

  @override
  String get profile_nameTooLong => '名称过长（最多 50 个字符）';

  @override
  String get profile_loadingProfile => '正在加载档案...';

  @override
  String get scheduledTasks_title => '定时任务';

  @override
  String get scheduledTasks_description => '管理自动执行的定时任务';

  @override
  String get scheduledTasks_noTasks => '还没有定时任务';

  @override
  String get scheduledTasks_noTasksHint => '创建一个新任务来开始';

  @override
  String get scheduledTasks_createTask => '创建任务';

  @override
  String get scheduledTasks_editTask => '编辑任务';

  @override
  String get scheduledTasks_deleteTask => '删除任务';

  @override
  String get scheduledTasks_activateTask => '启用';

  @override
  String get scheduledTasks_pauseTask => '暂停';

  @override
  String get scheduledTasks_executeNow => '立即执行';

  @override
  String get scheduledTasks_form_title => '任务详情';

  @override
  String get scheduledTasks_form_description => '描述';

  @override
  String get scheduledTasks_form_descriptionHint => '这个任务的用途是什么？';

  @override
  String get scheduledTasks_form_instruction => '指令';

  @override
  String get scheduledTasks_form_instructionHint => '输入任务指令或提示';

  @override
  String get scheduledTasks_form_selectAgent => '选择智能体';

  @override
  String get scheduledTasks_form_scheduleType => '计划类型';

  @override
  String get scheduledTasks_form_schedulePattern => '时间安排';

  @override
  String get scheduledTasks_form_schedulePatternHint =>
      'Cron: 0 9 * * * 或 Duration: PT5M';

  @override
  String get scheduledTasks_form_optional => '可选';

  @override
  String get scheduledTasks_form_selectChannel => '选择频道（可选）';

  @override
  String get scheduledTasks_scheduleType_cron => 'Cron 表达式';

  @override
  String get scheduledTasks_scheduleType_interval => '间隔时长';

  @override
  String get scheduledTasks_scheduleType_once => '一次性';

  @override
  String get scheduledTasks_cronExamples => 'Cron 示例';

  @override
  String get scheduledTasks_cronExample_daily => '每天早上 9 点: 0 9 * * *';

  @override
  String get scheduledTasks_cronExample_hourly => '每小时: 0 * * * *';

  @override
  String get scheduledTasks_cronExample_weekdays => '工作日早上 9 点: 0 9 * * 1-5';

  @override
  String get scheduledTasks_cronExample_everyMinute => '每分钟: * * * * *';

  @override
  String get scheduledTasks_intervalExamples => '时长示例';

  @override
  String get scheduledTasks_intervalExample_5min => '每 5 分钟: PT5M';

  @override
  String get scheduledTasks_intervalExample_1hour => '每 1 小时: PT1H';

  @override
  String get scheduledTasks_intervalExample_30min => '每 30 分钟: PT30M';

  @override
  String get scheduledTasks_status_pending => '待处理';

  @override
  String get scheduledTasks_status_active => '活跃';

  @override
  String get scheduledTasks_status_paused => '已暂停';

  @override
  String get scheduledTasks_status_completed => '已完成';

  @override
  String get scheduledTasks_status_failed => '失败';

  @override
  String scheduledTasks_nextRun(String time) {
    return '下次运行: $time';
  }

  @override
  String scheduledTasks_lastRun(String time) {
    return '最后运行: $time';
  }

  @override
  String scheduledTasks_executionCount(String count) {
    return '执行次数: $count';
  }

  @override
  String scheduledTasks_failureCount(String count) {
    return '失败次数: $count';
  }

  @override
  String get scheduledTasks_noLastError => '无错误';

  @override
  String scheduledTasks_lastError(String error) {
    return '最后错误: $error';
  }

  @override
  String get scheduledTasks_confirmDelete => '删除任务？';

  @override
  String get scheduledTasks_confirmDeleteMsg => '确定要删除这个定时任务吗？此操作无法撤销。';

  @override
  String get scheduledTasks_confirmPause => '暂停任务？';

  @override
  String get scheduledTasks_confirmPauseMsg => '任务将停止执行。您可以稍后恢复。';

  @override
  String get scheduledTasks_invalidSchedule => '无效的时间安排';

  @override
  String get scheduledTasks_invalidScheduleMsg => '请检查您的 cron 表达式或时长格式';

  @override
  String get scheduledTasks_missingInstruction => '指令不能为空';

  @override
  String get scheduledTasks_missingAgent => '请选择一个智能体';

  @override
  String get scheduledTasks_createSuccess => '任务创建成功';

  @override
  String get scheduledTasks_updateSuccess => '任务更新成功';

  @override
  String get scheduledTasks_deleteSuccess => '任务删除成功';

  @override
  String get scheduledTasks_activateSuccess => '任务已启用';

  @override
  String get scheduledTasks_pauseSuccess => '任务已暂停';

  @override
  String get scheduledTasks_executeNowSuccess => '任务执行已开始';

  @override
  String get scheduledTasks_filterByAgent => '按智能体筛选';

  @override
  String get scheduledTasks_filterAll => '全部';

  @override
  String scheduledTasks_createError(String error) {
    return '创建任务失败: $error';
  }

  @override
  String scheduledTasks_updateError(String error) {
    return '更新任务失败: $error';
  }

  @override
  String scheduledTasks_deleteError(String error) {
    return '删除任务失败: $error';
  }

  @override
  String scheduledTasks_activateError(String error) {
    return '启用任务失败: $error';
  }

  @override
  String get scheduledTasks_targetAgent => 'Agent 任务';

  @override
  String get scheduledTasks_targetGroup => '群任务';

  @override
  String get scheduledTasks_form_optionalChannel => '指定频道（可选）';

  @override
  String get scheduledTasks_form_selectGroupChannel => '选择群频道';

  @override
  String get scheduledTasks_form_selectGroup => '选择群';

  @override
  String get scheduledTasks_form_selectGroupAgents => '群内 Agent';

  @override
  String get scheduledTasks_form_selectMentions => '@提及的 Agent（可选）';

  @override
  String get scheduledTasks_missingChannel => '请选择频道';

  @override
  String get scheduledTasks_missingGroupAgents => '请至少选择一个 Agent';

  @override
  String get scheduledTasks_form_scheduleTypeLabel => '时间规则类型';

  @override
  String get scheduledTasks_form_scheduleType_interval => '间隔重复';

  @override
  String get scheduledTasks_form_scheduleType_cron => 'Cron 计划';

  @override
  String get scheduledTasks_form_scheduleType_once => '一次性';

  @override
  String get scheduledTasks_form_interval_value => '间隔数值';

  @override
  String get scheduledTasks_form_interval_unit_minutes => '分钟';

  @override
  String get scheduledTasks_form_interval_unit_hours => '小时';

  @override
  String get scheduledTasks_form_interval_unit_days => '天';

  @override
  String scheduledTasks_form_interval_preview(String value, String unit) {
    return '每 $value $unit执行一次';
  }

  @override
  String get scheduledTasks_form_preset_label => '快捷预设';

  @override
  String get scheduledTasks_form_preset_5min => '5分钟';

  @override
  String get scheduledTasks_form_preset_30min => '30分钟';

  @override
  String get scheduledTasks_form_preset_1h => '1小时';

  @override
  String get scheduledTasks_form_preset_6h => '6小时';

  @override
  String get scheduledTasks_form_preset_1d => '每天';

  @override
  String get scheduledTasks_form_cron_frequency => '执行频率';

  @override
  String get scheduledTasks_form_cron_freq_daily => '每天';

  @override
  String get scheduledTasks_form_cron_freq_weekly => '每周';

  @override
  String get scheduledTasks_form_cron_freq_monthly => '每月';

  @override
  String get scheduledTasks_form_cron_freq_custom => '自定义';

  @override
  String get scheduledTasks_form_cron_time => '执行时间';

  @override
  String get scheduledTasks_form_cron_weekdays => '执行星期';

  @override
  String get scheduledTasks_form_cron_monthdays => '执行日期';

  @override
  String get scheduledTasks_form_cron_advanced => '查看 Cron 表达式';

  @override
  String get scheduledTasks_form_cron_preview => '接下来的执行时间';

  @override
  String get scheduledTasks_form_cron_custom_hint => '分 时 日 月 周（如：0 9 * * 1-5）';

  @override
  String get scheduledTasks_form_cron_weekday_mon => '一';

  @override
  String get scheduledTasks_form_cron_weekday_tue => '二';

  @override
  String get scheduledTasks_form_cron_weekday_wed => '三';

  @override
  String get scheduledTasks_form_cron_weekday_thu => '四';

  @override
  String get scheduledTasks_form_cron_weekday_fri => '五';

  @override
  String get scheduledTasks_form_cron_weekday_sat => '六';

  @override
  String get scheduledTasks_form_cron_weekday_sun => '日';

  @override
  String get scheduledTasks_form_once_datetime => '执行时间';

  @override
  String get scheduledTasks_form_once_pickDate => '选择日期';

  @override
  String get scheduledTasks_form_once_pickTime => '选择时间';

  @override
  String get scheduledTasks_form_saveAndActivate => '保存并启用';

  @override
  String get scheduledTasks_form_scheduleSection => '时间规则';

  @override
  String get scheduledTasks_form_targetSection => '执行目标';

  @override
  String get scheduledTasks_form_contentSection => '任务内容';

  @override
  String get scheduledTasks_form_invalidInterval => '请输入有效的间隔数值（最小 1）';

  @override
  String get scheduledTasks_form_invalidCron => '请完善 Cron 规则配置';

  @override
  String get scheduledTasks_form_invalidOnce => '请选择一个未来的执行时间';

  @override
  String get scheduledTasks_form_oncePastError => '执行时间必须在当前时间之后';

  @override
  String get scheduledTasks_form_agentConversation => '指定会话';

  @override
  String get scheduledTasks_form_agentConversationHint => '选择该智能体的会话（默认当前激活会话）';

  @override
  String get scheduledTasks_form_agentNoConversation => '该智能体暂无会话记录';

  @override
  String get peerPairing_title => '配对设备';

  @override
  String get peerPairing_tabMyQr => '我的二维码';

  @override
  String get peerPairing_tabScan => '扫一扫';

  @override
  String get peerPairing_tabManual => '输入';

  @override
  String get peerPairing_copyLink => '复制配对链接';

  @override
  String get peerPairing_linkCopied => '配对链接已复制';

  @override
  String get peerManual_title => '手动输入配对';

  @override
  String get peerManual_desc => '在对方设备的「我的二维码」页面复制配对链接，粘贴到下方发起配对。';

  @override
  String get peerManual_inputHint =>
      'shepaw://peer?local=...&code=...#fp=...&pk=...';

  @override
  String get peerManual_paste => '粘贴';

  @override
  String get peerManual_submit => '发起配对';

  @override
  String get peerManual_emptyError => '请粘贴对方的配对内容';

  @override
  String get peerManual_invalidError => '无效的配对内容，请粘贴完整的配对链接（shepaw://peer?...）';

  @override
  String get peerManual_connecting => '正在连接...';

  @override
  String get peerManual_waitingConfirm => '等待对方确认...';

  @override
  String get peerManual_success => '配对成功!';

  @override
  String get peerManual_rejected => '对方拒绝了配对请求';

  @override
  String get peerManual_timeout => '配对超时，请重试';

  @override
  String peerManual_failed(String error) {
    return '配对失败: $error';
  }

  @override
  String get peerRole_initiatorShort => '我发起';

  @override
  String get peerRole_responderShort => '对方发起';

  @override
  String get peerRole_initiatorDesc => '本机扫码发起连接';

  @override
  String get peerRole_responderDesc => '对方扫码发起连接';

  @override
  String get peerChat_emptyMessages => '暂无消息\n发送第一条消息开始对话';

  @override
  String peerChat_searchInConversation(String peerName) {
    return '搜索与 $peerName 的聊天记录';
  }

  @override
  String get peerChat_hintOnline => '输入消息...';

  @override
  String get peerChat_hintOffline => '离线 · 消息将在连接后发送';

  @override
  String get peerChat_statusOnlinePrefix => '在线 · ';

  @override
  String get peerChat_e2eEncryption => '端到端加密';

  @override
  String get peerChat_statusOnline => '在线 · 端到端加密';

  @override
  String get peerChat_statusConnecting => '连接中...';

  @override
  String get peerChat_statusOffline => '离线';

  @override
  String get peerChat_agentList => '共享 Agent';

  @override
  String peerChat_tabFromPeerCount(int count) {
    return '对方分享 ($count)';
  }

  @override
  String peerChat_tabSharedByMeCount(int count) {
    return '我分享的 ($count)';
  }

  @override
  String peerChat_yesterday(String time) {
    return '昨天 $time';
  }

  @override
  String get peerSettings_title => '设备设置';

  @override
  String get peerSettings_online => '在线';

  @override
  String get peerSettings_offline => '离线';

  @override
  String get peerSettings_sectionBasic => '基本信息';

  @override
  String get peerSettings_aliasName => '备注名称';

  @override
  String get peerSettings_fingerprint => '设备指纹';

  @override
  String get peerSettings_pairedAt => '配对时间';

  @override
  String get peerSettings_connectionInitiator => '连接发起方';

  @override
  String get peerSettings_sectionConnection => '连接信息';

  @override
  String get peerSettings_localAddress => '内网地址';

  @override
  String get peerSettings_relayAddress => '外网中继';

  @override
  String get peerSettings_encryption => '加密方式';

  @override
  String get peerSettings_encryptionValue =>
      'Noise IK (X25519 + ChaCha20-Poly1305)';

  @override
  String get peerSettings_startChat => '发起对话';

  @override
  String get peerSettings_deletePairing => '删除配对';

  @override
  String get peerSettings_editAliasTitle => '修改备注名称';

  @override
  String get peerSettings_editAliasHint => '输入备注名称';

  @override
  String peerSettings_deleteConfirm(String name) {
    return '确定要删除与 $name 的配对吗？\n所有消息记录也会被删除。';
  }

  @override
  String get peerSettings_noShareableAgents => '暂无可分享的 Agent';

  @override
  String get peerSettings_enableExternalAccessHint =>
      '在 Agent 设置中开启「允许外部访问」后即可在此分享给该设备';

  @override
  String get peerSettings_shareAgentsTitle => '分享给此设备的 Agent';

  @override
  String peerSettings_shareAgentsTitleCount(int shared, int total) {
    return '分享给此设备的 Agent ($shared/$total)';
  }

  @override
  String get peerSettings_noPeerAgentsConnected => '该设备暂未开放任何 Agent';

  @override
  String get peerSettings_noPeerAgentsOffline => '设备离线，暂无可连接的 Agent';

  @override
  String get peerSettings_peerEnableExternalHint => '对方可在 Agent 设置中开启「分享给配对设备」';

  @override
  String get peerSettings_syncAgentsOnConnect => '连接后将自动同步可连接的 Agent';

  @override
  String get peerSettings_connectableAgentsTitle => '可连接的 Agent';

  @override
  String peerSettings_connectableAgentsTitleCount(int count) {
    return '可连接的 Agent ($count)';
  }

  @override
  String get peerSettings_sectionAgents => 'Agent 管理';

  @override
  String get peerSettings_agentEnabled => '启用';

  @override
  String get peerSettings_agentDisabled => '已禁用';

  @override
  String get peerSettings_agentStart => '启动';

  @override
  String get peerSettings_agentStop => '停止';

  @override
  String get peerSettings_agentRunning => '运行中';

  @override
  String get peerSettings_agentStopped => '已停止';

  @override
  String get peerSettings_agentManageOffline => '设备离线，无法管理 Agent';

  @override
  String get peerSettings_noManagedAgents => '该设备上还没有 Agent';

  @override
  String peerSettings_agentOpFailed(String error) {
    return '操作失败：$error';
  }

  @override
  String get peerList_connected => '已连接';

  @override
  String get peerList_connectedE2e => '已连接 (端到端加密)';

  @override
  String get peerList_disconnected => '未连接';

  @override
  String get common_done => '完成';

  @override
  String get common_more => '更多';

  @override
  String get common_back => '返回';

  @override
  String get common_connect => '连接';

  @override
  String get common_submit => '提交';

  @override
  String get common_next => '下一步';

  @override
  String get common_allow => '允许';

  @override
  String get common_processing => '处理中...';

  @override
  String get common_fetching => '获取中...';

  @override
  String get common_selectAll => '全选';

  @override
  String get common_openSettings => '打开设置';

  @override
  String get common_sync => '同步';

  @override
  String get common_busy => '忙碌';

  @override
  String get common_enter => '进入';

  @override
  String common_daysAgo(int count) {
    return '$count 天前';
  }

  @override
  String common_minutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String common_hoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String get toolModel_needOpenRouterKey => '请先填写 OpenRouter API Key';

  @override
  String get toolModel_selectOpenRouter => '选择 OpenRouter 模型';

  @override
  String get toolModel_fetchOpenRouterFailed => '获取 OpenRouter 模型失败';

  @override
  String get toolModel_needOllamaBase => '请先填写 Ollama API Base 地址';

  @override
  String get toolModel_ollamaNoModels =>
      'Ollama 中暂无已安装的模型，请先运行 ollama pull <model>';

  @override
  String get toolModel_selectOllama => '选择 Ollama 本地模型';

  @override
  String get toolModel_fetchOllamaFailed => '获取 Ollama 模型失败';

  @override
  String get toolModel_fetchOllamaList => '获取 Ollama 本地模型列表';

  @override
  String get toolModel_fetchOpenRouterList => '获取 OpenRouter 模型列表';

  @override
  String get toolModel_searchHint => '搜索模型名称或 ID...';

  @override
  String get toolModel_noMatch => '无匹配模型';

  @override
  String toolModel_fetchFailed(String error) {
    return '获取模型失败: $error';
  }

  @override
  String toolModel_filteredCount(int filtered, int total) {
    return '$filtered / $total 个模型';
  }

  @override
  String get remoteAgent_title => '远端助手';

  @override
  String get remoteAgent_checkingHealth => '正在检查 Agent 健康状态...';

  @override
  String remoteAgent_healthDone(int online, int total) {
    return '健康检查完成，在线: $online/$total';
  }

  @override
  String remoteAgent_healthFailed(String error) {
    return '健康检查失败: $error';
  }

  @override
  String remoteAgent_deleteConfirm(String name) {
    return '确定要删除助手 $name 吗？\n\n删除后，远端助手将无法再使用此 Token 连接。';
  }

  @override
  String get remoteAgent_checkHealth => '检查健康状态';

  @override
  String get remoteAgent_add => '添加助手';

  @override
  String get remoteAgent_empty => '还没有远端助手';

  @override
  String get remoteAgent_emptyHint => '点击下方按钮添加第一个助手';

  @override
  String get remoteAgent_viewToken => '查看 Token';

  @override
  String remoteAgent_loadFailed(String error) {
    return '加载失败: $error';
  }

  @override
  String remoteAgent_deleted(String name) {
    return '已删除 $name';
  }

  @override
  String remoteAgent_deleteFailed(String error) {
    return '删除失败: $error';
  }

  @override
  String remoteAgent_lastActive(String time) {
    return '最后活跃: $time';
  }

  @override
  String get workflow_detailTitle => '工作流详情';

  @override
  String get workflow_notFound => '工作流不存在';

  @override
  String get workflow_approvalSubmitted => '审批已提交，请返回群聊继续工作流';

  @override
  String workflow_approvalFailed(String error) {
    return '审批提交失败: $error';
  }

  @override
  String get workflow_triggerMessage => '触发消息';

  @override
  String get workflow_returnToChatForApproval => '请返回群聊消息中完成审批';

  @override
  String get workflow_lowRiskOp => '低风险操作';

  @override
  String get workflow_execSummary => '执行摘要';

  @override
  String get workflow_noSteps => '暂无步骤信息';

  @override
  String get workflow_execStages => '执行阶段';

  @override
  String get workflow_timeInfo => '时间信息';

  @override
  String get workflow_startTime => '开始时间';

  @override
  String get workflow_endTime => '完成时间';

  @override
  String get workflow_totalDuration => '总耗时';

  @override
  String workflow_stepsCompleted(int done, int total) {
    return '$done/$total 步骤完成';
  }

  @override
  String workflow_stepsCompletedSlash(int done, int total) {
    return '$done / $total 步骤完成';
  }

  @override
  String workflow_runningFor(String duration) {
    return '已运行 $duration';
  }

  @override
  String workflow_totalDurationValue(String duration) {
    return '总耗时 $duration';
  }

  @override
  String workflow_waitingToolApproval(String agentName) {
    return '等待 @$agentName 工具审批';
  }

  @override
  String workflow_stageN(int n) {
    return '阶段 $n';
  }

  @override
  String get workflow_inProgressBanner => '工作流进行中，点击查看进度与审批';

  @override
  String workflow_waitingApprovalSteps(int total) {
    return '等待审批 · $total 步骤';
  }

  @override
  String get workflow_allDone => '全部完成';

  @override
  String get workflow_execFailed => '执行失败';

  @override
  String get workflow_needToolConfirm => '需要确认工具操作';

  @override
  String get workflow_waitingToolApprovalShort => '等待工具审批';

  @override
  String get workflow_viewRelatedMessage => '查看相关消息';

  @override
  String get workflow_goReview => '去审核';

  @override
  String get approval_goReview => '去审核';

  @override
  String get approval_waitingReview => '等待审核';

  @override
  String get approval_needsReviewTitle => '需要你审核';

  @override
  String get approval_needsPlanReview => '工作流计划等待你批准';

  @override
  String get approval_needsActionReview => '操作等待你确认';

  @override
  String get approval_kindPlan => '计划';

  @override
  String get approval_kindAction => '操作';

  @override
  String approval_bannerTitle(String agentName, String kind) {
    return '$agentName 等待审核（$kind）';
  }

  @override
  String approval_morePending(int count) {
    return '还有 $count 条待审';
  }

  @override
  String get approval_dismissReminder => '忽略';

  @override
  String get workflow_approveExec => '批准执行';

  @override
  String get workflow_revisionComment => '修改意见';

  @override
  String get workflow_revisionHint => '请描述你的修改意见...';

  @override
  String get workflow_waitingToolTap => '等待工具审批 · 点击查看';

  @override
  String workflow_stagesSteps(int stages, int steps) {
    return '$stages 阶段 · $steps 步骤';
  }

  @override
  String workflow_completedOf(int done, int total) {
    return '$done/$total 完成';
  }

  @override
  String workflow_groupTitle(String name) {
    return '$name - 工作流';
  }

  @override
  String get workflow_empty => '暂无工作流记录';

  @override
  String get workflow_emptyHint => '工作流计划获批并执行后，记录会显示在此处';

  @override
  String get workflow_statusPendingApproval => '待审批';

  @override
  String get workflow_statusRunning => '运行中';

  @override
  String get workflow_statusCompleted => '已完成';

  @override
  String get workflow_statusFailed => '失败';

  @override
  String get workflow_statusCancelled => '已取消';

  @override
  String get workflow_stepPending => '待执行';

  @override
  String get workflow_stepRunning => '执行中';

  @override
  String get workflow_stepCompleted => '已完成';

  @override
  String get workflow_stepFailed => '失败';

  @override
  String get workflow_stepSkipped => '已跳过';

  @override
  String chat_syncedRemoteSessions(int count) {
    return '已同步 $count 个远端会话';
  }

  @override
  String get chat_syncRemoteSessionsTitle => '同步远端会话';

  @override
  String chat_syncRemoteSessionsBody(String agentName, int count) {
    return '在 $agentName 上发现 $count 个尚未同步的远端会话。\n\n是否同步到本地？同步后可在会话列表中查看并继续这些会话，本地会话将与远端保持一致。\n\n此选择会记住，之后可在 Agent 设置中修改。';
  }

  @override
  String get chat_doNotSync => '不同步';

  @override
  String get chat_sheNoModel => 'She 还没有配置 AI 模型';

  @override
  String get chat_sheNoModelTapSettings => '点击这里前往设置，为 She 选择一个 LLM 模型';

  @override
  String get chat_sheTagline => '你的专属灵宠，会越来越懂你';

  @override
  String get chat_sheConfigModelCta => '配置 AI 模型，开始对话';

  @override
  String get chat_sheNeedModelHint => 'She 使用本地 LLM 运行，请先在设置中\n为她选择一个 AI 模型';

  @override
  String get chat_syncingRemote => '同步远端…';

  @override
  String get chat_toolPendingInPanel => '工具操作待确认：请在下方工作流面板中批准或拒绝';

  @override
  String get agentToken_createdSuccess => '助手创建成功';

  @override
  String get agentToken_nextSteps => '下一步';

  @override
  String get agentToken_step1 => '复制上方的 Token';

  @override
  String get agentToken_step2 => '在远端助手的配置中粘贴 Token';

  @override
  String get agentToken_step3 => '启动远端助手，等待连接';

  @override
  String get agentToken_step4 => '连接成功后，助手将显示为在线状态';

  @override
  String get agentToken_keepSafe => '请妥善保管 Token，不要泄露给他人';

  @override
  String get channel_loadFailed => '加载频道列表失败';

  @override
  String get channel_management => '频道管理';

  @override
  String get channel_create => '创建频道';

  @override
  String get channel_empty => '暂无频道';

  @override
  String get channel_emptyHint => '点击下方按钮创建您的第一个频道';

  @override
  String get channel_knotBridge => 'Knot 桥接';

  @override
  String get channel_open => '打开频道';

  @override
  String get channel_knotRemoved => 'Knot 桥接功能已移除，请使用远端助手功能';

  @override
  String get channel_name => '频道名称';

  @override
  String get channel_nameHint => '输入频道名称';

  @override
  String get channel_descOptional => '频道描述（可选）';

  @override
  String get channel_descHint => '输入频道描述';

  @override
  String get channel_nameRequired => '请输入频道名称';

  @override
  String channel_createdSuccess(String name) {
    return '频道 $name 创建成功';
  }

  @override
  String get channel_createFailed => '创建频道失败';

  @override
  String channel_loaded(int count) {
    return '加载了 $count 个频道';
  }

  @override
  String channel_opening(String name) {
    return '打开频道: $name';
  }

  @override
  String channel_createdLog(String name) {
    return '成功创建频道: $name';
  }

  @override
  String get login_backingUp => '正在安全备份数据...';

  @override
  String get agentList_loadFailed => '加载 Agent 列表失败';

  @override
  String agentList_deleteConfirm(String name) {
    return '确定要删除 Agent $name 吗？';
  }

  @override
  String get agentList_deleteFailed => '删除 Agent 失败';

  @override
  String get agentList_title => 'Agent 管理';

  @override
  String get agentList_emptyHint => '点击下方按钮添加您的第一个 Agent';

  @override
  String get agentList_selectType => '选择 Agent 类型';

  @override
  String get agentList_typeOpenClaw => '通过 ACP 协议连接 OpenClaw Gateway';

  @override
  String get agentList_typeA2a => '支持 A2A 协议的通用 Agent';

  @override
  String get agentList_typeCustom => '自定义 Agent';

  @override
  String get agentList_typeCustomDesc => '手动配置的其他类型 Agent';

  @override
  String get agentList_createConversationFailed => '创建对话失败';

  @override
  String agentList_createConversationFailedDetail(String error) {
    return '创建对话失败: $error';
  }

  @override
  String agentList_loaded(int count) {
    return '加载了 $count 个 Agent';
  }

  @override
  String agentList_typeLabel(String type) {
    return '类型: $type';
  }

  @override
  String agentList_conversationWith(String name) {
    return '与 $name 的对话';
  }

  @override
  String agentList_dmCreated(String name, String id) {
    return '创建了与 $name 的 DM 频道: $id';
  }

  @override
  String agentList_conversationCreated(String name) {
    return '已创建与 $name 的对话';
  }

  @override
  String agentList_deleted(String name) {
    return '已删除 $name';
  }

  @override
  String get agentDetail_peerOffline => '配对设备未连接';

  @override
  String get agentDetail_modelSwitchUnsupported => '该 agent 暂不支持切换模型';

  @override
  String get agentDetail_modelSwitched => '已切换模型';

  @override
  String get agentDetail_modelSwitchFailed => '切换模型失败';

  @override
  String get agentDetail_sessionSync => '会话同步';

  @override
  String get agentDetail_sessionSyncHint =>
      '开启后进入时自动同步远端会话列表与聊天记录；关闭后不再同步。可随时在此修改';

  @override
  String get agentDetail_refreshModels => '刷新模型列表';

  @override
  String get agentDetail_switchModelHint => '切换远端 agent 使用的 LLM 模型（作用于后续对话）';

  @override
  String get agentDetail_noModels => '暂无可用模型';

  @override
  String get agentDetail_modeSwitchUnsupported => '该 agent 暂不支持切换模式';

  @override
  String get agentDetail_modeSwitched => '已切换模式';

  @override
  String get agentDetail_modeSwitchFailed => '切换模式失败';

  @override
  String get agentDetail_refreshModes => '刷新模式列表';

  @override
  String get agentDetail_switchModeHint => '切换远端 agent 的会话模式（作用于当前及后续对话）';

  @override
  String get agentDetail_noModes => '暂无可用模式';

  @override
  String get agentDetail_noAiModel => '尚未配置 AI 模型';

  @override
  String get agentDetail_maxToolRounds => '最大工具调用轮次';

  @override
  String agentDetail_maxToolRoundsValue(int count) {
    return '$count 次';
  }

  @override
  String get agentDetail_taskTimeout => '任务超时时间';

  @override
  String agentDetail_taskTimeoutValue(int seconds) {
    return '$seconds 秒';
  }

  @override
  String get agentDetail_maxToolRoundsDefault => '默认 100';

  @override
  String get agentDetail_maxToolRoundsHelper => '单次对话中 LLM 最多可调用工具的轮数（1–500）';

  @override
  String get agentDetail_maxToolRoundsInvalid => '请输入 1 到 500 之间的整数';

  @override
  String get agentDetail_taskTimeoutSeconds => '任务超时时间（秒）';

  @override
  String get agentDetail_taskTimeoutDefault => '默认 600';

  @override
  String get agentDetail_taskTimeoutHelper => '单次任务的最长等待时间（60–3600 秒）';

  @override
  String get agentDetail_taskTimeoutInvalid => '请输入 60 到 3600 之间的整数';

  @override
  String agentDetail_fromSource(String name) {
    return '来自 $name';
  }

  @override
  String get agentDetail_createSuccess => 'Agent 创建成功';

  @override
  String get agentDetail_updateSuccess => 'Agent 更新成功';

  @override
  String get agentDetail_name => 'Agent 名称';

  @override
  String get agentDetail_nameHint => '输入 Agent 名称';

  @override
  String get agentDetail_type => 'Agent 类型';

  @override
  String get agentDetail_typeHint => '例如: assistant, chatbot';

  @override
  String get agentDetail_typeRequired => '请输入 Agent 类型';

  @override
  String get agentDetail_status => 'Agent 状态';

  @override
  String agentDetail_createdLog(String name) {
    return '成功创建 Agent: $name';
  }

  @override
  String agentDetail_updatedLog(String name) {
    return '成功更新 Agent: $name';
  }

  @override
  String get agentDetail_addTitle => '添加 Agent';

  @override
  String get agentDetail_viewTitle => 'Agent 详情';

  @override
  String get agentPair_unsupportedPlatform =>
      '当前平台不支持扫码。请返回手动粘贴 URL + 填写配对码，或改用手机扫码。';

  @override
  String get agentPair_scanTitle => '扫描配对二维码';

  @override
  String get agentPair_torch => '手电筒';

  @override
  String get agentPair_scanHint =>
      '对准 agent 主机上 `<gateway> enroll` / `shepaw-hub pair` 打印的二维码';

  @override
  String get agentPair_cameraDeniedTitle => '无法访问相机';

  @override
  String get agentPair_cameraDeniedBody =>
      '扫码配对需要相机权限。请到系统设置中允许 Shepaw 访问相机，或返回手动输入配对码。';

  @override
  String get agentPair_unsupportedShort => '当前平台暂不支持扫码';

  @override
  String agentPair_scanFailed(String error) {
    return '扫描失败：$error';
  }

  @override
  String agentPair_cameraInitFailed(String error) {
    return '相机初始化失败：$error';
  }

  @override
  String get addAgent_scannedHintPrefix => '已扫码：URL 与配对码已填入。点击';

  @override
  String get addAgent_scannedHintSuffix => '完成配对。';

  @override
  String get addAgent_missingFingerprint =>
      'URL 缺失指纹（`#fp=…`）。请使用 agent 终端启动时打印的完整 URL。';

  @override
  String get addAgent_devicePubkeyTitle => '本设备公钥（v2.1 授权凭证）';

  @override
  String get addAgent_loadingDeviceIdentity => '正在加载设备身份…';

  @override
  String get addAgent_fingerprintLabel => '指纹: ';

  @override
  String get addAgent_copyPubkey => '复制公钥';

  @override
  String get addAgent_pubkeyCopied => '公钥已复制到剪贴板';

  @override
  String get addAgent_runOnHost => '在 agent 主机上执行：';

  @override
  String get addAgent_myPhone => '我的手机';

  @override
  String get addAgent_agentFingerprintLabel => 'Agent 指纹: ';

  @override
  String get addAgent_verifyFingerprint =>
      '请对照 agent 终端启动时打印的 Fingerprint 是否一致';

  @override
  String get addAgent_missingFpWarning =>
      '⚠ URL 缺失 #fp=… 指纹段，配对将失败。请使用 agent 启动时打印的完整 URL。';

  @override
  String get addAgent_pairingCodeOptional => '配对码（可选，用于一键配对）';

  @override
  String get dispatch_timeout => '执行超时';

  @override
  String get dispatch_failed => '执行失败';

  @override
  String get dispatch_waitingConfirm => '等待操作确认';

  @override
  String get dispatch_running => '执行中';

  @override
  String get dispatch_goConfirm => '前往处理确认';

  @override
  String get dispatch_viewDetails => '查看执行详情';

  @override
  String get dispatch_awaitingConfirm => '等待确认';

  @override
  String get dispatch_confirmed => '已确认';

  @override
  String get dispatch_cancelled => '已取消';

  @override
  String get dispatch_confirmDispatch => '确认派发';

  @override
  String group_approvalBridgeTitle(String groupName) {
    return '群审核 · $groupName';
  }

  @override
  String get group_approvalBridgePending => '待审核';

  @override
  String group_approvalBridgeBody(String agentName, String kind) {
    return '$agentName 在绑定群会话中需要你进行$kind。';
  }

  @override
  String get group_approvalBridgeOpen => '打开群会话';

  @override
  String get group_approvalKindPlan => '工作流计划审批';

  @override
  String get group_approvalKindAction => '操作确认';

  @override
  String get group_approvalKindForm => '表单填写';

  @override
  String get group_approvalKindSelect => '选项确认';

  @override
  String get group_approvalKindUpload => '文件上传';

  @override
  String dispatch_title(String agentName) {
    return '任务派发 · $agentName';
  }

  @override
  String dispatch_pendingConfirm(String title) {
    return '待确认：$title';
  }

  @override
  String dispatch_confirmTitle(String agentName) {
    return '派发确认 · $agentName';
  }

  @override
  String get dispatch_completed => '已完成';

  @override
  String get relay_waiting => '等待审批';

  @override
  String get relay_processed => '已处理';

  @override
  String get relay_expired => '已过期';

  @override
  String get relay_failed => '处理失败';

  @override
  String get relay_goReview => '去助手会话审核';

  @override
  String relay_title(String agentName) {
    return '操作确认 · $agentName';
  }

  @override
  String relay_yourChoice(String label) {
    return '你的选择：$label';
  }

  @override
  String get plan_title => '执行计划';

  @override
  String get plan_approved => '已批准';

  @override
  String get plan_feedbackGiven => '已反馈';

  @override
  String get plan_revisionHint => '请描述你对计划的修改意见...';

  @override
  String get plan_submitFeedback => '提交意见';

  @override
  String get plan_requestRevision => '提出修改';

  @override
  String get plan_approveAndRun => '批准并执行';

  @override
  String plan_dependencies(String deps) {
    return '依赖: $deps';
  }

  @override
  String get update_emptyDownloadUrl => '下载链接为空，请联系管理员检查接口返回';

  @override
  String update_cannotOpenUrl(String url) {
    return '无法打开下载链接: $url';
  }

  @override
  String update_downloadComplete(String fileName) {
    return '$fileName 下载完成';
  }

  @override
  String get peerPairing_requestTitle => '配对请求';

  @override
  String get peerPairing_requestBody => '以下设备想要与你配对：';

  @override
  String get peerPairing_selectAgents => '选择要分享给该设备的 Agent';

  @override
  String get peerPairing_selectAgentsHint =>
      '对方将能通过配对连接使用你选中的 Agent（需已开启「允许外部访问」）';

  @override
  String get peerPairing_confirmHint => '确认配对后，双方可以直接通讯';

  @override
  String get peerPairing_confirm => '确认配对';

  @override
  String peerPairing_confirmWithCount(int count) {
    return '确认配对 ($count)';
  }

  @override
  String peerPairing_failed(String error) {
    return '配对失败: $error';
  }

  @override
  String get peerPairing_trustLevel => '信任级别';

  @override
  String get peerPairing_trustLevelHint =>
      '自己的设备选「本人」可默认开放更大储物袋分区；他人设备选「好友」默认不共享，需手动勾选。';

  @override
  String get peerPairing_trustOwner => '本人';

  @override
  String get peerPairing_trustFriend => '好友';

  @override
  String get peerPairing_selectStoreSpaces => '选择要分享的储物袋空间';

  @override
  String get peerPairing_selectStoreSpacesHint =>
      '仅勾选的分区/目录可被对方只读访问；attachments 与 backups 不可在此分享。';

  @override
  String get peerStoreShare_wholeSpace => '整区共享';

  @override
  String get peerStoreShare_wholeSpaceToggle => '共享整个分区';

  @override
  String get peerStoreShare_notShared => '未共享';

  @override
  String get peerStoreShare_noFolders => '该分区暂无顶层目录';

  @override
  String peerStoreShare_foldersCount(int count) {
    return '已选 $count 个目录';
  }

  @override
  String get peerStoreShare_panelTitle => '储物袋分享';

  @override
  String get peerStoreShare_panelHint => '管理本机储物袋对该设备的可见范围';

  @override
  String get peerSettings_trustLevel => '信任级别';

  @override
  String get peerSettings_trustOwnerHint =>
      '切换为本人后，是否套用默认的 files+artifacts 整区分享？';

  @override
  String get peerSettings_applyOwnerDefaults => '套用默认分享';

  @override
  String get peerSettings_keepShares => '保留现有分享';

  @override
  String get peerSettings_trustFriendHint => '降为好友后，未分享的空间将不可被对方访问；已有分享不会自动清空。';

  @override
  String get peerScan_desktopUnsupported => '桌面端暂不支持摄像头扫描';

  @override
  String get peerScan_useMobile => '请在移动设备上使用扫码功能';

  @override
  String get peerScan_frameHint => '将对方的二维码放入框内';

  @override
  String peerScan_cameraError(String error) {
    return '摄像头错误: $error';
  }

  @override
  String get peerList_add => '添加配对';

  @override
  String get peerList_emptyHint => '扫描对方的二维码或让对方扫描你的二维码来建立加密连接';

  @override
  String peerList_pairedSuccess(String name) {
    return '已与 $name 配对成功';
  }

  @override
  String get peerList_editAlias => '修改备注';

  @override
  String get peerQr_fillAllFields => '请填写所有字段';

  @override
  String get peerQr_cannotStart => '无法启动配对';

  @override
  String get peerQr_scanHint => '让对方扫描此二维码完成配对';

  @override
  String get peerQr_codeLabel => '配对码';

  @override
  String get peerQr_codeCopied => '配对码已复制';

  @override
  String get peerQr_waitingScan => '等待对方扫描...';

  @override
  String get peerQr_validFiveMin => '二维码 5 分钟内有效';

  @override
  String get peerQr_wanConnect => '外网连接';

  @override
  String get peerQr_wanConnectHint => '开启后可通过外网配对，不限同一局域网';

  @override
  String get peerQr_channelConnected => 'Channel 已连接';

  @override
  String get peerQr_channelConnecting => '正在连接 Channel...';

  @override
  String get peerQr_channelReconnecting => '连接断开，正在重连...';

  @override
  String get peerQr_editConfig => '修改配置';

  @override
  String get peerQr_connectFailed => '连接失败';

  @override
  String get peerQr_starting => '正在启动...';

  @override
  String get peerQr_configureChannel => '配置 Channel 服务以启用外网连接';

  @override
  String get peerQr_channelIdHint => '输入 Channel ID';

  @override
  String get peerQr_signingKeyHint => '输入签名密钥';

  @override
  String peerChat_cannotConnect(String name) {
    return '无法连接到 $name，请确认对方在线后重试';
  }

  @override
  String get memory_typeConversation => '对话';

  @override
  String get memory_typeKnowledge => '知识';

  @override
  String get memory_typeBehavior => '行为';

  @override
  String get memory_typeEvent => '事件';

  @override
  String get memory_typeEmotion => '情感';

  @override
  String get peerApproval_superseded => '被后续审批取代';

  @override
  String get peerApproval_allow => '允许';

  @override
  String get peerApproval_deny => '拒绝';

  @override
  String get status_protocolPeer => '配对设备';

  @override
  String get status_custom => '自定义';

  @override
  String get home_statusError => '错误';

  @override
  String get addAgent_pairingCodeHelper =>
      'Agent 主机运行 `<gateway> enroll` 得到类似 XXX-XXX-XXX 的短码，粘贴到这里即可自动授权本设备。不填写则走上方的「复制公钥 → peers add」手动流程。';

  @override
  String get storage_title => '储物袋';

  @override
  String get storage_subtitle => '管理本机快照、附件与产物占用';

  @override
  String get storage_snapshotSection => '本机快照';

  @override
  String get storage_snapshotDesc => '加密快照（数据库 + 设备身份）。恢复将全量替换当前数据。';

  @override
  String get storage_snapshotNow => '立即快照';

  @override
  String get storage_noSnapshots => '暂无快照';

  @override
  String get storage_restore => '恢复';

  @override
  String get storage_export => '导出';

  @override
  String get storage_dangerZone => '危险区';

  @override
  String get storage_exportTree => '导出本机存储目录';

  @override
  String get storage_exportTreeTitle => '导出本机存储目录';

  @override
  String get storage_exportTreeDesc => '将本机四分区正式文件复制到所选目录（不含未提交暂存）。与单份快照导出不同。';

  @override
  String get storage_exportTreeHint =>
      '导出完整本机 store 目录树（artifacts / files / attachments / backups）。请选择目标文件夹。';

  @override
  String storage_exportTreeDone(String path, int count, String size) {
    return '已导出到 $path（$count 个文件，$size）';
  }

  @override
  String storage_exportTreeFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String get storage_exportWebdav => '导出到 WebDAV';

  @override
  String get storage_exportWebdavTitle => '导出到 WebDAV';

  @override
  String get storage_exportWebdavDesc => '将本机四分区正式文件上传到 WebDAV（手动兜底，不占自动路径）。';

  @override
  String get storage_exportWebdavHint =>
      '输入 WebDAV 根地址与凭据。文件将上传到「前缀/device_id/…」。凭据仅用于本次导出，不会保存。';

  @override
  String get storage_exportWebdavUrl => '服务器 URL';

  @override
  String get storage_exportWebdavUser => '用户名';

  @override
  String get storage_exportWebdavPassword => '密码';

  @override
  String get storage_exportWebdavPrefix => '远程目录前缀';

  @override
  String storage_exportWebdavDone(String path, int count, String size) {
    return '已上传到 $path（$count 个文件，$size）';
  }

  @override
  String storage_exportWebdavFailed(String error) {
    return 'WebDAV 导出失败：$error';
  }

  @override
  String get storage_wipeSelf => '删除本机存储数据';

  @override
  String get storage_wipeSelfTitle => '删除本机存储数据';

  @override
  String get storage_wipeSelfDesc => '清空本机四分区正式文件与暂存（不删回收站、数据库与设备身份）。建议先导出。';

  @override
  String get storage_wipeSelfConfirm => '此操作不可从回收站还原。请输入 DELETE 确认。';

  @override
  String get storage_wipeSelfTypeHint => '输入 DELETE';

  @override
  String storage_wipeSelfDone(String size) {
    return '已清空本机存储（释放 $size）';
  }

  @override
  String storage_wipeSelfFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get storage_browseFiles => '浏览文件';

  @override
  String get storage_browserTitle => '存储文件';

  @override
  String get storage_browserHint => '浏览本机 store 正式文件（删除后进入回收站）。多设备镜像请在同步节点管理。';

  @override
  String get storage_browserDevice => '设备';

  @override
  String get storage_browserPrefix => '路径前缀';

  @override
  String get storage_browserPrefixHint => '例如 docs/ 或 task/';

  @override
  String get storage_browserEmpty => '该分区暂无文件';

  @override
  String get storage_browserHome => '首页';

  @override
  String get storage_browserTabFlat => '全部';

  @override
  String get storage_browserTabSpace => '空间';

  @override
  String get storage_browserTabRecent => '最近';

  @override
  String get storage_browserTabMine => '我的';

  @override
  String storage_browserLastAccessed(String time) {
    return '最近访问于 $time';
  }

  @override
  String storage_browserLastModified(String time) {
    return '最近修改于 $time';
  }

  @override
  String get storage_browserFolderEmpty => '这里还没有任何文件';

  @override
  String get storage_browserNewFolder => '新建文件夹';

  @override
  String get storage_browserUploadLocal => '上传本地文件';

  @override
  String get storage_browserNewDocument => '新建文档';

  @override
  String get storage_browserNewSpreadsheet => '新建表格';

  @override
  String get storage_browserNewFolderHint => '文件夹名称';

  @override
  String storage_browserNewFolderFailed(Object error) {
    return '创建文件夹失败：$error';
  }

  @override
  String storage_browserUploadFailed(Object error) {
    return '上传失败：$error';
  }

  @override
  String storage_browserUploadDone(String name) {
    return '已上传 $name';
  }

  @override
  String storage_browserNewFileFailed(Object error) {
    return '创建失败：$error';
  }

  @override
  String storage_browserCount(int count) {
    return '显示 $count 个文件';
  }

  @override
  String get storage_browserLoadMore => '加载更多';

  @override
  String get storage_browserRefresh => '刷新';

  @override
  String get storage_browserPreview => '预览';

  @override
  String get storage_browserCopyPath => '复制路径';

  @override
  String get storage_browserShareLink => '分享链接';

  @override
  String get storage_browserPathCopied => '路径已复制';

  @override
  String get storage_browserLinkCopied => '分享链接已复制';

  @override
  String get storage_browserExport => '导出到…';

  @override
  String storage_browserExportDone(String path) {
    return '已导出到 $path';
  }

  @override
  String storage_browserExportFailed(String error) {
    return '导出失败：$error';
  }

  @override
  String storage_browserExportConfirmLarge(String name, String size) {
    return '「$name」约 $size。导出将复制到所选目录，是否继续？';
  }

  @override
  String get storage_browserDelete => '删除';

  @override
  String get storage_browserDeleteTitle => '删除文件';

  @override
  String storage_browserDeleteConfirm(String path) {
    return '将删除 $path 并移入回收站。确认？';
  }

  @override
  String storage_browserDeleted(String path) {
    return '已删除 $path';
  }

  @override
  String storage_browserDeleteFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get storage_browserDeleteDenied => '无权删除他端文件（仅 master 本机）';

  @override
  String get storage_browserVersions => '版本';

  @override
  String get storage_browserManifest => '血缘';

  @override
  String get storage_browserVersionsTitle => '版本历史';

  @override
  String get storage_browserVersionsEmpty => '暂无版本记录（覆盖写入后才会产生）';

  @override
  String storage_browserVersionsFailed(String error) {
    return '加载版本失败：$error';
  }

  @override
  String get storage_browserManifestTitle => '任务血缘';

  @override
  String get storage_browserManifestEmpty => '无血缘信息';

  @override
  String storage_browserManifestFailed(String error) {
    return '加载血缘失败：$error';
  }

  @override
  String get storage_browserSearchTitle => '搜索产物';

  @override
  String get storage_browserSearchHint => '关键词';

  @override
  String get storage_browserSearchEmpty => '无匹配结果';

  @override
  String storage_browserSearchFailed(String error) {
    return '搜索失败：$error';
  }

  @override
  String get storage_browserSearchSemantic => '语义';

  @override
  String get storage_browserSearchKeyword => '关键词';

  @override
  String get storage_browserSearchDegraded => '已降级为关键词检索';

  @override
  String get storage_browserNeedMaster => '请先连接 NAS/节点作为 master';

  @override
  String get storage_deviceOffline => '设备未连接，无法查看';

  @override
  String get storage_fileKindImage => '图片';

  @override
  String get storage_fileKindAudio => '音频';

  @override
  String get storage_fileKindVideo => '视频';

  @override
  String get storage_fileKindPdf => 'PDF';

  @override
  String get storage_fileKindDocument => '文档';

  @override
  String get storage_fileKindSpreadsheet => '表格';

  @override
  String get storage_fileKindPresentation => '演示文稿';

  @override
  String get storage_fileKindText => '文本';

  @override
  String get storage_fileKindArchive => '压缩包';

  @override
  String get storage_fileKindFile => '文件';

  @override
  String storage_chatAttachmentLabel(String kind, String hash) {
    return '聊天$kind · $hash';
  }

  @override
  String storage_alertHandoffs(int count) {
    return '有 $count 条交接通知';
  }

  @override
  String get storage_handoffTitle => '交接通知';

  @override
  String get storage_handoffEmpty => '暂无交接通知';

  @override
  String get storage_handoffClear => '清除';

  @override
  String get storage_agentsAdmin => '节点 Admin（Agents）';

  @override
  String get storage_agentsAdminHint => '在浏览器管理 agent 身份与配额';

  @override
  String get storage_agentsAdminMissing => '未发现可用节点地址';

  @override
  String get storage_mirroredDevices => '他端镜像目录';

  @override
  String get storage_purgeDevice => '删除';

  @override
  String get storage_purgeDeviceTitle => '删除旧设备镜像';

  @override
  String storage_purgeDeviceConfirm(String deviceId, String size) {
    return '将永久删除 master 上设备 $deviceId 的镜像目录（约 $size），不可从回收站还原。确认继续？';
  }

  @override
  String storage_purgeDeviceDone(String deviceId, String size) {
    return '已删除 $deviceId（释放 $size）';
  }

  @override
  String storage_purgeDeviceFailed(String error) {
    return '删除失败：$error';
  }

  @override
  String get storage_purgeDeviceMasterOnly => '仅 master 本机可删除他端镜像';

  @override
  String get storage_passwordTitle => '输入主密码';

  @override
  String get storage_passwordHint => '快照以主密码派生密钥加密。';

  @override
  String get storage_passwordWrong => '密码错误';

  @override
  String get storage_snapshotDone => '快照已生成';

  @override
  String storage_snapshotFailed(String error) {
    return '快照失败：$error';
  }

  @override
  String get storage_restoreTitle => '恢复快照';

  @override
  String get storage_restoreWarning =>
      '恢复是全量替换、不合并。当前数据会先自动做一次安全快照，然后被所选快照整体替换。恢复后需要重启 App。';

  @override
  String get storage_restoreConfirm => '替换并恢复';

  @override
  String get storage_restoreDone => '恢复完成，请重启 App。';

  @override
  String storage_restoreFailed(String error) {
    return '恢复失败：$error';
  }

  @override
  String storage_exportDone(String path) {
    return '已导出到 $path';
  }

  @override
  String storage_exportDoneWithAttachments(String path, int count) {
    return '已导出到 $path（含 $count 个附件）';
  }

  @override
  String storage_exportDonePartial(String path, int packed, int missing) {
    return '已导出到 $path（打包附件 $packed，缺失 $missing）';
  }

  @override
  String get storage_verifyOk => '校验通过';

  @override
  String get storage_verifyFileTampered => '文件被篡改';

  @override
  String get storage_verifyManifestTampered => '清单被篡改';

  @override
  String get storage_verifyUnreadable => '无法读取';

  @override
  String get storage_verifyUnknown => '未校验';

  @override
  String get storage_spaceSection => '存储空间';

  @override
  String get storage_masterNode => '主存储节点（master）';

  @override
  String get storage_thisDevice => '本机';

  @override
  String get storage_migrateMaster => '迁移 Master';

  @override
  String get storage_becomeMaster => '本机升为 Master';

  @override
  String get storage_migratePick => '选择新的 Master 设备';

  @override
  String storage_migrateConfirm(String device) {
    return '将 Master 迁移到 $device？各端将按游标差量重放。';
  }

  @override
  String get storage_migrateGapWarning =>
      '当前 Master 离线：升主只迁移游标，不搬运他端历史文件；镜像可能不完整。建议等旧 Master 在线后再迁移。';

  @override
  String storage_migrateDone(int epoch) {
    return 'Master 已切换（epoch $epoch）';
  }

  @override
  String storage_migrateDoneGap(int epoch) {
    return 'Master 已切换（epoch $epoch）。旧 Master 当时不可达，镜像可能不完整，请确认各端稍后同步。';
  }

  @override
  String storage_migrateDoneHashMismatch(int epoch, int count) {
    return 'Master 已切换（epoch $epoch）。内容对账发现 $count 处差异，镜像可能不完整。';
  }

  @override
  String storage_migrateFailed(String error) {
    return '迁移失败：$error';
  }

  @override
  String get storage_reprotectNow => '立即再保护镜像树';

  @override
  String storage_reprotectDone(String id) {
    return '镜像再保护已完成：$id';
  }

  @override
  String get storage_reprotectSkipped => '再保护跳过（需本机为 Master 且已缓存密码）';

  @override
  String get storage_usageTitle => '用量';

  @override
  String storage_volumeFree(String free, String total) {
    return '卷剩余 $free / $total';
  }

  @override
  String storage_volumeWarning(int percent) {
    return '存储卷已用约 $percent%（≥80%）。请清理文件或回收站，避免同步与快照失败。';
  }

  @override
  String get storage_recycleSection => '回收站';

  @override
  String get storage_recycleEmptyHint => '回收站为空';

  @override
  String get storage_recycleRestore => '还原';

  @override
  String get storage_recycleRestored => '已还原到原路径';

  @override
  String storage_recycleRestoreFailed(String error) {
    return '还原失败：$error';
  }

  @override
  String get storage_recyclePurgeAll => '清空回收站';

  @override
  String get storage_recyclePurgeConfirm => '清空后不可恢复，确定清空回收站？';

  @override
  String storage_recyclePurged(String size) {
    return '已清理 $size';
  }

  @override
  String get storage_recyclePurgeMasterOnly => '清空回收站仅限当前 Master 本机操作';

  @override
  String storage_recyclePurgeFailed(String error) {
    return '清空失败：$error';
  }

  @override
  String storage_recycleShowMore(int count) {
    return '显示全部（$count）';
  }

  @override
  String get storage_recycleShowLess => '收起';

  @override
  String storage_deletedAt(String time) {
    return '删除于 $time';
  }

  @override
  String get storage_entrySnapshots => '备份与恢复';

  @override
  String get storage_entrySnapshotsSub => '加密快照与全量恢复';

  @override
  String get storage_createBackup => '备份当前数据';

  @override
  String get storage_noSnapshotsHint => '创建第一份加密快照，即可随时恢复本机数据。';

  @override
  String get storage_entrySpace => '本机空间';

  @override
  String get storage_moreSettings => '更多设置';

  @override
  String storage_usedBadge(String size) {
    return '已使用 $size';
  }

  @override
  String get storage_bindingsSection => '目录绑定';

  @override
  String get storage_entryAdvanced => '高级与危险区';

  @override
  String get storage_entryNas => '共享储物袋';

  @override
  String get storage_nasEntryHint => '查看配对设备储物袋，并可指定 master 备份';

  @override
  String get storage_nasHint =>
      '配对成功后即可浏览对方 files/artifacts。将 PC 等设备设为 master 后，本机变更会定期镜像备份到该端。下方还可发现局域网 Nexus Pouch 节点。';

  @override
  String get storage_nasScanning => '正在扫描局域网…';

  @override
  String get storage_nasEmpty => '未发现 Nexus Pouch 节点。也可直接配对手机/电脑互相浏览储物袋。';

  @override
  String get storage_nasConnect => '连接并设为 master';

  @override
  String storage_nasConnected(String name) {
    return '已连接 $name 并设为 master';
  }

  @override
  String storage_nasConnectFailed(String error) {
    return '连接失败：$error';
  }

  @override
  String get storage_nasMissingFingerprint => '发现结果缺少指纹，请改用扫码配对。';

  @override
  String get storage_nasNotPairedTitle => '尚未配对';

  @override
  String storage_nasNotPairedBody(String name) {
    return '$name 在局域网中，但尚未与本 App 配对。请先扫描节点二维码完成配对。';
  }

  @override
  String get storage_nasOpenPairing => '打开配对';

  @override
  String get storage_nasAddDevice => '添加设备';

  @override
  String get storage_nasPaired => '已配对';

  @override
  String get storage_pairedSection => '已配对设备';

  @override
  String get storage_pairedEmpty => '暂无配对设备。扫码配对后即可互读储物袋。';

  @override
  String get storage_discoveredSection => '局域网发现';

  @override
  String get storage_sharedDevicesSection => '共享设备';

  @override
  String get storage_sharedThisDevice => '本机';

  @override
  String get storage_sharedBrowse => '浏览储物袋';

  @override
  String get storage_sharedBrowseHint =>
      '只读浏览该设备共享分区（files / artifacts）。属主在线直读；离线时尝试 master 镜像。';

  @override
  String get storage_sharedSetMaster => '设为 master（备份目标）';

  @override
  String get storage_setMasterExplainBody =>
      '将某台设备设为主存储节点（master）后，本机储物袋的 files/artifacts 变更会定期镜像备份到该端。设备离线时，可尝试从 master 读取镜像副本。';

  @override
  String get storage_browseLocalSpace => '浏览本机储物袋';

  @override
  String get storage_peerSpaceEntry => '设备储物袋';

  @override
  String storage_sharedMasterSet(String name) {
    return '已将 $name 设为 master，本机将开始镜像备份';
  }

  @override
  String storage_sharedSyncPending(int count, String bytes) {
    return '待同步到 master：$count 项（约 $bytes）';
  }

  @override
  String get storage_sharedSyncPendingHint => '手机等移动端可将储物袋备份到 PC master';

  @override
  String get storage_sharedSyncNow => '立即同步';

  @override
  String get storage_pendingToMaster => '待同步到 master';

  @override
  String get storage_pendingWaitingMaster => '等待 master 上线';

  @override
  String get storage_pendingUploading => '正在上传';

  @override
  String storage_syncFailed(String error) {
    return '同步失败：$error';
  }

  @override
  String storage_syncStillPending(int count) {
    return '同步结束，仍有 $count 个文件待发送';
  }

  @override
  String get storage_pendingKindCommit => '上传';

  @override
  String get storage_pendingKindDelete => '删除';

  @override
  String storage_pendingMore(int count) {
    return '还有 $count 项';
  }

  @override
  String get storage_pendingSeeAll => '查看全部';

  @override
  String get storage_pendingEmpty => '已与 master 同步';

  @override
  String get storage_mirroredDevicesHint => '配对设备把本机设为 master 后，其储物袋会镜像到这里。';

  @override
  String get storage_mirroredDevicesNote => '删除镜像只释放本机空间；源设备仍在时可能再次同步过来。';

  @override
  String get storage_mirroredBrowse => '浏览';

  @override
  String get storage_mirroredEmpty => '尚无他端镜像';

  @override
  String storage_mirrorCount(int count) {
    return '$count 台镜像';
  }

  @override
  String get storage_masterBadge => 'master';

  @override
  String get storage_importEntryHint => '从旧设备迁入快照与数据';

  @override
  String get storage_advancedEntryHint => '目录导出 · WebDAV · 抹除';

  @override
  String storage_snapshotCount(int count) {
    return '$count 份快照';
  }

  @override
  String storage_alertPendingImports(int count) {
    return '$count 条导入请求待审批';
  }

  @override
  String storage_ownerPeerCount(int count) {
    return '$count 位 owner 设备';
  }

  @override
  String get storage_synced => '已同步';

  @override
  String get storage_masterIsSelf => '主节点为本机';

  @override
  String get storage_autoShortOn => '自动开';

  @override
  String get storage_autoShortOff => '自动关';

  @override
  String get storage_autoSnapshot => '每日自动快照';

  @override
  String get storage_autoSnapshotOff => '已关闭';

  @override
  String get storage_autoSnapshotRetention =>
      '不会无限堆积：按 GFS 保留最近 7 日、4 周、12 个月快照，更早的会自动清理。';

  @override
  String storage_lastSuccess(String time) {
    return '最近成功 $time';
  }

  @override
  String get storage_noKeyHint => '先手动创建一次快照以启用自动快照';

  @override
  String get storage_enableSnapshotPasswordTitle => '开启自动快照需验证主密码';

  @override
  String get storage_decryptCheck => '解密自检';

  @override
  String get storage_decryptCheckTitle => '验证主密码能否解密快照';

  @override
  String get storage_decryptCheckOk => '主密码正确，最新快照可解密；自动快照密钥已缓存';

  @override
  String get storage_decryptCheckOkNoSnapshot => '主密码正确；尚无快照可解密，密钥已缓存';

  @override
  String storage_decryptCheckFailed(String error) {
    return '解密自检失败：$error';
  }

  @override
  String get storage_snapshotWarning => '自动快照已连续失败 3 天以上，请检查存储空间或手动快照一次。';

  @override
  String get storage_needsOldPassword => '需旧密码';

  @override
  String get storage_importSection => '换机导入';

  @override
  String get storage_importRequestHint =>
      '扫码或输入旧设备 ID 发送导入请求；在旧设备（或 master）上确认。未配对时会先完成配对。';

  @override
  String get storage_oldDeviceId => '旧设备 ID（16 位十六进制）';

  @override
  String get storage_importSend => '发送导入请求';

  @override
  String get storage_importScan => '扫码';

  @override
  String get storage_importPaste => '粘贴链接';

  @override
  String get storage_importPasteHint =>
      '桌面端请粘贴旧设备「我的二维码」对应的配对链接（shepaw://peer?...）。';

  @override
  String get storage_importScanTitle => '扫描旧设备二维码';

  @override
  String get storage_importScanHint => '对准旧设备上的配对二维码';

  @override
  String get storage_importShowQr => '显示本机二维码';

  @override
  String get storage_importPairing => '正在与旧设备配对…';

  @override
  String get storage_importSent => '请求已发送，请在旧设备（或 master）上确认。';

  @override
  String get storage_importMyGrants => '我获得的导入授权';

  @override
  String get storage_importBrowse => '浏览快照';

  @override
  String get storage_importPending => '待审批的导入请求';

  @override
  String get storage_importRequestNotifyTitle => '换机导入请求';

  @override
  String storage_importRequestNotifyBody(String device) {
    return '设备 $device 请求读取本机备份与附件，请在存储空间页审批。';
  }

  @override
  String get storage_importGrantNotifyTitle => '导入授权已批准';

  @override
  String storage_importGrantNotifyBody(String device) {
    return '设备 $device 已授权你读取备份与附件，可在存储空间页导入。';
  }

  @override
  String get storage_importApprove => '批准';

  @override
  String get storage_importReject => '拒绝';

  @override
  String storage_importFrom(String device) {
    return '来自 $device';
  }

  @override
  String get storage_importPickSnapshot => '选择要导入的快照';

  @override
  String get storage_importDownloading => '正在下载快照…';

  @override
  String get storage_importDone => '快照已取回。恢复将全量替换当前数据（保留本机设备身份）。';

  @override
  String get storage_importRestore => '导入并恢复';

  @override
  String storage_importFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get storage_noRemoteSnapshots => '旧设备上没有快照';

  @override
  String storage_importExpires(String time) {
    return '有效期至 $time';
  }

  @override
  String storage_unsynced(int count, String size) {
    return '未同步 $count 条 · $size';
  }

  @override
  String storage_syncCursor(int ack, int change) {
    return '同步游标 $ack/$change';
  }

  @override
  String get storage_unsyncedWarning => '大量数据仍占用本机待上传队列，可清理本机文件或等待同步节点接收。';

  @override
  String get storage_sheCircleSection => '她的朋友圈';

  @override
  String get storage_sheCircleHint => '仅与 owner 级设备交换蒸馏摘要；关闭类别后该类别不出机。';

  @override
  String get storage_exchangeEnabled => '启用记忆交换';

  @override
  String get storage_exchangeKinds => '交换类别';

  @override
  String get storage_kindPreference => '偏好';

  @override
  String get storage_kindOngoing => '进行中';

  @override
  String get storage_kindFact => '事实';

  @override
  String get storage_exchangeNow => '立即交换';

  @override
  String get storage_exchangeDone => '摘要已推送';

  @override
  String get storage_exchangeSkipped => '未推送（未开启、无条目或无 owner 设备）';

  @override
  String get storage_renameShe => '为本机的她命名';

  @override
  String get storage_renameSheHint => '多设备时可为每台的她起名（默认按场景）。';

  @override
  String get storage_sheNameSaved => '已更新本机 she 名称';

  @override
  String storage_peerTrust(String level) {
    return '信任：$level';
  }

  @override
  String storage_externalMemories(int count) {
    return '已收摘要 $count 条';
  }

  @override
  String get storage_presenceOffline => '暂无在线画像';

  @override
  String get storage_noOwnerPeers => '暂无 owner 级配对设备';

  @override
  String get storage_sharePresenceRoster => '向圈子分享 Agent 名单';

  @override
  String get storage_sharePresenceRosterHint =>
      '关闭时仅广播类别与数量；开启后 owner 可见本机 Agent 名称并可点名委托。';

  @override
  String storage_presenceAgents(String names) {
    return 'Agent：$names';
  }

  @override
  String get storage_pickDelegateAgent => '选择委托 Agent';
}
