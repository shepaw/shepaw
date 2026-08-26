import '../../cli_base.dart';
import 'album_enroll_command.dart';
import 'album_list_command.dart';
import 'album_remove_command.dart';

/// `vision album` 子命名空间 — 参考相册管理。
class AlbumNamespace extends CliNamespace {
  static final AlbumNamespace instance = AlbumNamespace._();
  AlbumNamespace._();

  @override
  String get namespace => 'album';

  @override
  String get description =>
      'Reference album — enroll, list and remove family members';

  @override
  String get usage => 'shepaw vision album.<enroll|list|remove> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'enroll': AlbumEnrollCommand(),
        'list': AlbumListCommand(),
        'remove': AlbumRemoveCommand(),
      };
}
