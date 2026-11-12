import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../screens/storage_directory_opener.dart';
import '../services/error_handler_service.dart';
import '../services/store_open_service.dart';
import '../storage/store_protocol.dart';
import '../storage/workspace_link_resolver.dart';

/// Markdown 里点链接的统一出口（聊天气泡、工作流节点输出共用）。
///
/// - `pouch://…` 与能映射到 [workspaceUris] 的相对路径：走储物袋打开
/// - 其余交给外部浏览器；打不开（返回 false / 抛异常）时弹「无法打开链接」
/// - 相对路径但没有可用的工作区根：同样按打不开处理，不拿相对 URI 去试外部应用
Future<void> openMarkdownLink(
  BuildContext context,
  String href, {
  Iterable<String> workspaceUris = const [],
}) async {
  final resolved = resolveWorkspaceHref(href, workspaceUris) ??
      (isPouchUri(href) ? href : null);
  if (resolved != null && isPouchUri(resolved)) {
    registerStorageDirectoryOpener();
    await StoreOpenService.instance.openStoreUri(context, resolved);
    return;
  }
  final uri = isRelativeWorkspaceHref(href) ? null : Uri.tryParse(href.trim());
  var opened = false;
  if (uri != null) {
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
  }
  if (opened || !context.mounted) return;
  showTopToast(
    context,
    AppLocalizations.of(context).widget_cannotOpenLink(href),
    icon: Icons.error_outline,
    color: Colors.red.shade400,
  );
}
