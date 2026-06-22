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
  String get appDescription => '安全 AI Agent 管理平台';

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
  String get login_selectAccount => '选择账号';

  @override
  String get login_createNewAccount => '创建新账号';

  @override
  String get login_resetPasswordBackingUp => '正在安全备份数据...';

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
  String get home_scanConnect => '扫码登录';

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
  String get addAgent_systemPrompt => '系统提示词（可选）';

  @override
  String get addAgent_systemPromptHint => '定义 Agent 的角色和能力范围';

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
  String get agentDetail_systemPrompt => '系统提示词';

  @override
  String get agentDetail_llmConfig => '模型配置';

  @override
  String get agentDetail_provider => '服务商';

  @override
  String get agentDetail_model => '模型';

  @override
  String get agentDetail_lastActive => '最后活跃';

  @override
  String get agentDetail_createdAt => '创建时间';

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
  String get chat_customSystemPrompt => '自定义系统提示词';

  @override
  String get chat_systemPromptTitle => '自定义系统提示词';

  @override
  String get chat_systemPromptHint => '为本会话覆盖 Agent 的系统提示词';

  @override
  String get chat_systemPromptSaved => '系统提示词已保存';

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
  String get chat_sessions => '会话';

  @override
  String chat_sessionsCount(int count) {
    return '$count 个会话';
  }

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
      '隐私政策\n\n最后更新：2026-02-28\n\nPaw（以下简称“我们”）致力于保护您的隐私。Paw 是一款完全本地化的应用程序，我们不会收集、上传或存储您的任何个人数据。您的所有数据始终保留在您的设备上，完全由您掌控。\n\n1. 数据存储\n\nPaw 不设有服务器，不收集任何用户数据。您在使用过程中产生的所有数据，包括：\n- 账户凭证\n- Agent 配置数据\n- 聊天消息和对话历史记录\n\n均仅存储在您的设备本地，我们无法也不会访问这些数据。\n\n2. 数据安全\n\n我们通过以下措施保护您的本地数据安全：\n- 本地数据加密\n- 安全的 WebSocket 连接（WSS）用于远程通信\n- 生物识别认证支持\n- 密码保护访问\n\n3. 第三方服务\n\n当您主动配置并连接远端 AI Agent 时，您的消息将直接在您的设备和您配置的 Agent 端点之间传输，不经过我们的任何服务器。我们不对第三方 Agent 服务的数据处理行为负责。\n\n4. 您的权利\n\n由于所有数据均存储在您的设备本地，您可以随时：\n- 查看您的所有数据\n- 通过清除应用数据或卸载应用来彻底删除数据\n- 使用应用内导出功能导出数据\n\n5. 政策变更\n\n我们可能会不时更新本隐私政策。我们将通过更新“最后更新”日期来通知您任何变更。';

  @override
  String get terms_title => '服务条款';

  @override
  String get terms_content =>
      '服务条款\n\n最后更新：2026-02-28\n\n请在使用 Paw 应用程序之前仔细阅读这些服务条款。\n\n1. 条款接受\n\n访问或使用 Paw 即表示您同意受这些条款的约束。如果您不同意，请勿使用本应用程序。\n\n2. 服务描述\n\nPaw 是一个 AI Agent 管理平台，允许您：\n- 连接和与 AI Agent 通信\n- 管理多个 Agent 配置\n- 促进 Agent 之间的协作\n- 与 Agent 传输文件和媒体\n\n3. 用户责任\n\n您同意：\n- 遵守所有适用法律使用本应用\n- 不将本应用用于任何非法或未经授权的目的\n- 不试图干扰应用的功能\n- 对您的账户凭证安全负责\n- 对您通过应用发送的内容负责\n\n4. 知识产权\n\n本应用及其原创内容、功能和特性归我们所有，受国际版权、商标和其他知识产权法律保护。\n\n5. 第三方 Agent 服务\n\n我们的应用允许您连接第三方 AI Agent 服务。我们不控制这些服务，也不对其内容、隐私政策或实践负责。\n\n6. 免责声明\n\n本应用按“原样”提供，不提供任何形式的保证。我们不保证应用会不间断、安全或无错误地运行。\n\n7. 责任限制\n\n在任何情况下，我们均不对因您使用本应用而产生的任何间接、偶发、特殊、后果性或惩罚性损害承担责任。\n\n8. 条款变更\n\n我们保留随时修改这些条款的权利。您在变更后继续使用应用即表示接受新条款。';

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
  String get contacts_agents => 'Agent';

  @override
  String get contacts_groups => '群组';

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
  String get contacts_noGroups => '暂无群组';

  @override
  String contacts_agentCount(int count) {
    return '$count 个 Agent';
  }

  @override
  String contacts_groupCount(int count) {
    return '$count 个群组';
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
  String get settings_disableServiceTitle => '关闭本地服务';

  @override
  String get settings_disableServiceContent =>
      '关闭后，所有已配置「允许外部访问」的 Agent 将无法接受外网连接，正在连接的客户端也会立即断开。\n\n确认关闭？';

  @override
  String get settings_disableServiceConfirm => '确认关闭';

  @override
  String get settings_localService => '本地服务';

  @override
  String get settings_localServiceDesc => '允许内网或外网设备以 Remote Agent 形式连接';

  @override
  String get settings_lanAddress => '内网连接地址';

  @override
  String get settings_lanAddressSub => '同局域网设备可通过以下地址连接';

  @override
  String get settings_channelTunnel => 'Channel Tunnel（外网穿透）';

  @override
  String get settings_tunnelNotConfigured => '未配置';

  @override
  String get settings_tunnelConnected => '已连接';

  @override
  String get settings_tunnelConnecting => '连接中';

  @override
  String get settings_tunnelDisconnected => '已断开';

  @override
  String get settings_tunnelError => '连接错误';

  @override
  String get settings_configureTunnel => '配置 Tunnel';

  @override
  String get settings_copyLanAddress => '复制内网地址';

  @override
  String get settings_copyPublicAddress => '复制外网地址';

  @override
  String get settings_acpServerRunning => 'ACP Server 运行中';

  @override
  String get settings_acpServerStopped => 'ACP Server 未运行';

  @override
  String get settings_tunnelServerUrl => 'Channel 服务地址';

  @override
  String get settings_tunnelChannelId => 'Channel ID';

  @override
  String get settings_tunnelSecret => 'Secret';

  @override
  String get settings_tunnelAutoConnect => '自动连接';

  @override
  String get settings_tunnelPublicAddress => '外网访问地址';

  @override
  String get settings_tunnelConfigRequiredFields => '请填写所有必填字段';

  @override
  String get settings_deleteTunnelConfig => '删除配置';

  @override
  String get settings_noLanAddress => '暂未获取到局域网地址';

  @override
  String get settings_acpPort => '端口';

  @override
  String get settings_acpPortSuffix => '（1024-65535）';

  @override
  String get settings_acpChangePort => '修改端口';

  @override
  String get settings_acpPortHint => '修改端口后需要重启 App 才能生效。其他设备需使用新端口重新连接。';

  @override
  String get settings_acpPortInvalid => '端口号无效，请输入 1024-65535 之间的数字';

  @override
  String get settings_acpPortRestarting => '正在重启 ACP Server...';

  @override
  String get settings_acpPortRestartRequired => '端口已保存，重启 App 后生效';

  @override
  String get settings_acpToken => '连接 Token';

  @override
  String get settings_acpTokenCopy => '复制 Token';

  @override
  String get settings_acpTokenRefresh => '刷新 Token';

  @override
  String get settings_acpTokenRefreshed => 'Token 已刷新，旧连接需重新连接';

  @override
  String get agent_enableExternalAccessTitle => '开启外网访问';

  @override
  String get agent_enableExternalAccessNeedService =>
      '当前「本地服务总控开关」已关闭，外网访问功能无法使用。\n\n是否同时开启本地服务？';

  @override
  String get agent_enableServiceAndContinue => '开启本地服务';

  @override
  String get agent_keepDisabled => '仅保存设置';

  @override
  String get agent_allowExternalAccess => '允许外部访问';

  @override
  String get agent_allowExternalAccessDesc => '开启后，已配对的设备可在会话列表中看到并与该 agent 对话';

  @override
  String get agent_externalAccessPeerEnabled =>
      '已开启：已配对的设备可在会话列表中看到并与该 agent 对话';

  @override
  String get agent_externalAccessUrl => '访问地址';

  @override
  String get agent_externalAccessUrlLan => '局域网访问地址';

  @override
  String get agent_externalAccessUrlPublic => '公网访问地址';

  @override
  String get agent_externalAccessDisabled => '外部访问已关闭';

  @override
  String get agent_externalAccessNeedsService => '需先在「设置」中开启本地服务';

  @override
  String get agent_copyAccessUrl => '复制访问地址';

  @override
  String get agent_accessUrlCopied => '访问地址已复制';

  @override
  String get agent_accessUrlCopiedHint => '可粘贴到端点 URL 处进行连接';

  @override
  String get agent_regenerateToken => '刷新 Token';

  @override
  String get agent_regenerateTokenConfirmTitle => '确认刷新 Token';

  @override
  String get agent_regenerateTokenConfirmBody =>
      '刷新后旧 Token 将立即失效，已连接的客户端需使用新 Token 重新连接。确认继续吗？';

  @override
  String get agent_tokenRegenerated => 'Token 已更新';

  @override
  String agent_tokenRegenerateFailed(String error) {
    return '刷新失败: $error';
  }

  @override
  String get agent_channelConfig => '公网 Channel 配置';

  @override
  String get agent_channelServerUrl => 'Server 地址';

  @override
  String get agent_channelId => 'Channel ID';

  @override
  String get agent_channelSecret => 'Channel 密钥';

  @override
  String get agent_channelEndpoint => 'Channel Endpoint（可选）';

  @override
  String get agent_channelNotConfigured => '未配置公网 Channel';

  @override
  String get agent_channelConfigure => '去配置';

  @override
  String get she_pinned_label => '置顶';

  @override
  String get she_name => '惜惜';

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
  String get peerSettings_peerEnableExternalHint => '对方可在 Agent 设置中开启「允许外部访问」';

  @override
  String get peerSettings_syncAgentsOnConnect => '连接后将自动同步可连接的 Agent';

  @override
  String get peerSettings_connectableAgentsTitle => '可连接的 Agent';

  @override
  String peerSettings_connectableAgentsTitleCount(int count) {
    return '可连接的 Agent ($count)';
  }

  @override
  String get peerList_connected => '已连接';

  @override
  String get peerList_connectedE2e => '已连接 (端到端加密)';

  @override
  String get peerList_disconnected => '未连接';

  @override
  String get identity_title => '账号与灵宠';

  @override
  String get identity_settingsSub => '账号身份与设备存储角色';

  @override
  String get identity_sectionAccount => '身份';

  @override
  String get identity_userId => '主人 ID（指纹）';

  @override
  String get identity_petId => '灵宠 ID（指纹）';

  @override
  String get identity_ownership => '认主状态';

  @override
  String get identity_bonded => '已与主人完成认主';

  @override
  String get identity_notBonded => '尚未认主';

  @override
  String get identity_bondAction => '指纹认主';

  @override
  String get identity_bondBiometricReason => '请验证身份以完成灵宠认主';

  @override
  String get identity_bondSuccess => '认主成功';

  @override
  String identity_bondFailed(String error) {
    return '认主失败：$error';
  }

  @override
  String get identity_sectionDeviceRole => '本机存储角色';

  @override
  String get identity_deviceRoleHint =>
      '主存储持有全量数据；备份同步全量；应用设备仅保留索引与缓存，按需向主存储拉取。';

  @override
  String get identity_rolePrimary => '主存储设备';

  @override
  String get identity_rolePrimaryDesc => '权威全量数据，聊天历史与附件的主副本';

  @override
  String get identity_roleBackup => '备份设备';

  @override
  String get identity_roleBackupDesc => '从主存储同步全量，主存储离线时可只读接管';

  @override
  String get identity_roleApp => '应用设备';

  @override
  String get identity_roleAppDesc => '轻量运行，适合手机；不保存全量历史';

  @override
  String get identity_setPrimaryTitle => '设为主存储？';

  @override
  String get identity_setPrimaryBody => '本机将持有账号全量数据。若已有其他主存储设备，其角色将调整为应用设备。';

  @override
  String get identity_primaryDevice => '当前主存储';

  @override
  String get identity_sectionOwnedDevices => '账号下设备';

  @override
  String get identity_noOwnedDevices => '暂无已登记设备';

  @override
  String get identity_thisDevice => '本机';

  @override
  String get identity_sectionMultiDevice => '多设备';

  @override
  String get identity_addDeviceTitle => '添加设备';

  @override
  String get identity_addDeviceSubtitle => '展示 P2P 配对码供新设备加入';

  @override
  String get identity_addDeviceHint =>
      '在新设备上先「加入已有账号」粘贴导出包，再扫描下方 Trust QR（或配对后自动信任）。';

  @override
  String get identity_trustQrTitle => 'Trust 邀请码';

  @override
  String get identity_exportBundleTitle => '身份导出包';

  @override
  String get identity_exportBundleHint =>
      '复制后在新设备的「加入已有账号」中粘贴（含 User / 灵宠密钥，请妥善保管）。';

  @override
  String get identity_copyExport => '复制导出包';

  @override
  String get identity_exportCopied => '已复制到剪贴板';

  @override
  String get identity_importTitle => '加入已有账号';

  @override
  String get identity_importSubtitle => '从主存储设备导入身份';

  @override
  String get identity_importHint =>
      '从主存储设备复制「身份导出包」JSON 并粘贴 below，或扫描 Trust QR。';

  @override
  String get identity_importPasteHint => '粘贴 identity export JSON…';

  @override
  String get identity_importAction => '导入账号';

  @override
  String get identity_importInvalid => '无效的导出包格式';

  @override
  String get identity_importSuccess => '账号导入成功';

  @override
  String identity_importFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get identity_trustScanSection => 'Trust 邀请（可选）';

  @override
  String get identity_trustScanHint => '导入身份后，扫描主设备上的 Trust QR 登记设备关系。';

  @override
  String get identity_scanTrustQr => '扫描 Trust QR';

  @override
  String get identity_scanUnsupported => '当前平台不支持扫码，请使用粘贴导入。';

  @override
  String get identity_trustInvalid => '无效的 Trust 邀请';

  @override
  String get identity_trustAccepted => '已接受 Trust 邀请';

  @override
  String identity_trustFailed(String error) {
    return 'Trust 失败：$error';
  }

  @override
  String get identity_syncPull => '从主存储同步';

  @override
  String get identity_syncPullSub => '拉取聊天历史与频道元数据';

  @override
  String get identity_syncPullSuccess => '同步完成';

  @override
  String identity_syncPullFailed(String error) {
    return '同步失败：$error';
  }

  @override
  String get identity_syncResync => '从主存储全量同步';

  @override
  String get identity_syncResyncSub => '重置同步游标并重新拉取全部数据';

  @override
  String get identity_syncResyncTitle => '确认全量同步？';

  @override
  String get identity_syncResyncBody =>
      '将重置本机同步游标，并从主存储设备重新下载全部数据。适用于历史记录不完整时。';

  @override
  String get identity_syncResyncSuccess => '全量同步完成';

  @override
  String identity_syncResyncFailed(String error) {
    return '全量同步失败：$error';
  }

  @override
  String get identity_syncPendingTitle => '待上传数据';

  @override
  String identity_syncPendingBody(int events, int blobs) {
    return '$events 条变更、$blobs 个附件等待同步到主存储设备';
  }

  @override
  String get identity_syncStaleCommit => '主存储已有更新版本，本机已自动刷新。';

  @override
  String get account_gateTitle => '登录账号';

  @override
  String get account_gateHeadline => '选择或创建你的账号';

  @override
  String get account_gateSubtitle => '一个账号对应一只专属灵宠。账号 ID 全局唯一，多设备登录同一账号即可共享数据。';

  @override
  String get account_gateAccountId => '账号 ID';

  @override
  String get account_gateContinue => '进入应用';

  @override
  String get account_gateCreate => '创建新账号';

  @override
  String get account_gateImport => '加入已有账号';

  @override
  String get account_gateCreateRoleHint => '选择本机在此账号下的存储角色：';

  @override
  String get account_gateSwitchAccount => '切换账号';

  @override
  String get account_gateSwitchTitle => '切换账号？';

  @override
  String get account_gateSwitchBody => '将清除本机当前账号密钥。请随后导入已有账号或创建新账号。';

  @override
  String get account_gateIdCopied => '账号 ID 已复制';

  @override
  String account_gateCreateFailed(String error) {
    return '创建账号失败：$error';
  }

  @override
  String get account_gateJoinViaPeer => '扫描主设备加入账号';

  @override
  String get account_gateOfflineImport => '离线导入（高级）';

  @override
  String get account_gateAddAccount => '添加其他账号';

  @override
  String get account_gateSetPasswordHint => '为此账号设置登录密码';

  @override
  String get account_gateOrCreate => '或创建新账号';

  @override
  String get qrLogin_scanTitle => '扫码登录';

  @override
  String get qrLogin_scanHeadline => '扫描主存储设备上的二维码，使用同一账号登录';

  @override
  String get qrLogin_scanButton => '扫码登录';

  @override
  String get qrLogin_joinSuccess => '登录成功，正在从主存储设备同步数据…';

  @override
  String get qrLogin_displayTitle => '扫码登录';

  @override
  String get qrLogin_displayHeadline => '让其他设备扫码登录';

  @override
  String get qrLogin_displayHint =>
      '在手机上打开惜宝 → 会话主页右上角 ➕ →「扫码登录」，扫描下方二维码。本设备会弹出确认请求。';

  @override
  String get qrLogin_displayButton => '展示手机扫码登录二维码';

  @override
  String get qrLogin_displayNoPasswordHint => '无需输入密码，手机扫码后在本设备确认即可';

  @override
  String qrLogin_displayFailed(String error) {
    return '无法展示二维码：$error';
  }

  @override
  String get qrLogin_stepScan => '手机扫描此二维码完成配对';

  @override
  String get qrLogin_stepApprove => '在本设备确认登录请求';

  @override
  String get qrLogin_stepSync => '设备保持关联，连接后自动同步数据';

  @override
  String get qrLogin_appRoleHint => '本地缓存常用数据，全量数据保存在主存储设备';

  @override
  String get qrLogin_rolePrimaryDesc => '账号权威全量存储';

  @override
  String get qrLogin_roleBackupDesc => '从主存储设备镜像全量数据';

  @override
  String get qrLogin_roleAppDesc => '轻量客户端，与主存储设备增量同步';

  @override
  String get qrLogin_connectingAccount => '正在连接账号…';

  @override
  String get qrLogin_syncing => '正在从主存储设备同步数据…';

  @override
  String get qrLogin_reconnected => '已重新连接，正在同步最新数据…';

  @override
  String qrLogin_syncFailed(String error) {
    return '登录成功，但首次同步失败：$error。连接恢复后将自动重试。';
  }

  @override
  String get qrLogin_errorNotPrimary =>
      '仅主存储设备可展示扫码登录二维码。请切换到主存储设备，或在账号设置中调整本设备角色。';

  @override
  String get qrLogin_errorPrimaryRequired => '扫描的设备不是主存储设备，请使用主存储设备上的二维码。';

  @override
  String get qrLogin_errorJoinTimeout => '等待确认超时。请保持两台设备在同一网络后重试。';

  @override
  String get qrLogin_errorJoinRejected => '主设备已拒绝或取消了登录请求。';

  @override
  String get qrLogin_errorPairingUnavailable =>
      '无法启动配对：请开启 Channel 隧道，或确保两台设备在同一局域网。';

  @override
  String get qrLogin_errorPeerConnection => '无法连接主存储设备，请检查网络或 Channel 配置后重试。';

  @override
  String qrLogin_errorPairingStart(String error) {
    return '无法启动配对：$error';
  }

  @override
  String get qrLogin_pairingStartFailed => '无法启动配对';

  @override
  String get qrLogin_displayKeepForeground =>
      '请保持本页面在前台，直至手机完成登录；收到请求时请在本设备确认。';

  @override
  String get account_joinTitle => '加入已有账号';

  @override
  String get account_joinHint =>
      '在已登录账号的主存储设备上打开「添加设备」，展示 P2P 配对码。本机扫描该码完成配对后，主设备会弹出确认并安全下发账号密钥。';

  @override
  String get account_joinScanPeer => '扫描 P2P 配对码';

  @override
  String get account_joinManualPeer => '手动输入配对链接';

  @override
  String get account_joinWaitingApproval => '等待主设备确认…';

  @override
  String get account_joinSuccess => '已成功加入账号';

  @override
  String account_joinFailed(String error) {
    return '加入失败：$error';
  }

  @override
  String get account_joinDialogTitle => '允许加入账号？';

  @override
  String account_joinDialogBody(String deviceName, String role) {
    return '设备「$deviceName」请求加入你的账号（角色：$role）。';
  }

  @override
  String get account_joinApprove => '允许';

  @override
  String account_joinApproved(String deviceName) {
    return '已允许 $deviceName 加入';
  }

  @override
  String account_joinApproveFailed(String error) {
    return '批准失败：$error';
  }

  @override
  String get identity_addDevicePeerHint =>
      '请在新设备上选择「扫描主设备加入账号」，扫描下方 P2P 配对码。确认后账号密钥将通过加密通道自动下发。';

  @override
  String get identity_importOfflineTitle => '离线导入账号';

  @override
  String get identity_importOfflineHint => '当无法与主设备在线配对时使用。从主设备复制身份导出包并粘贴到下方。';
}
