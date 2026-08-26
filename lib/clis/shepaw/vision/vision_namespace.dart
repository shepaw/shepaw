import '../../cli_base.dart';
import '../../../services/vision/reference_album_service.dart';
import 'album_namespace.dart';
import 'profile_namespace.dart';
import 'recognize_command.dart';
import 'vision_status_command.dart';

/// [TOOLING 层] vision 命名空间 — 设备端人脸识别（参考相册 + 视觉档案）。
///
/// 全部计算在本地完成（隐私优先）：
/// - `status`                引擎 / 相册状态
/// - `recognize`             识别一张图中的所有人脸
/// - `album.enroll|list|remove`  参考相册管理
/// - `profile.build|get`     结构化视觉档案构建 / 读取
///
/// 分层结构（She 用点号路由，如 `shepaw vision album.enroll`）：
/// - 扁平命令：`status`、`recognize`
/// - 子命名空间：`album`、`profile`
class VisionNamespace extends CliNamespace {
  static final VisionNamespace instance = VisionNamespace._();
  VisionNamespace._();

  /// 可注入的相册服务（测试注入内存 veda + Debug 引擎；默认懒加载真实服务）。
  ReferenceAlbumService? albumServiceOverride;

  ReferenceAlbumService get albumService =>
      albumServiceOverride ??= ReferenceAlbumService();

  @override
  String get namespace => 'vision';

  @override
  String get description =>
      'On-device face recognition — reference album and visual profiles';

  @override
  String get usage => 'shepaw vision <command|sub-namespace.action> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'status': VisionStatusCommand(),
        'recognize': VisionRecognizeCommand(),
      };

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'album': AlbumNamespace.instance,
        'profile': ProfileNamespace.instance,
      };
}
