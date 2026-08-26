import '../../cli_base.dart';
import 'profile_build_command.dart';
import 'profile_get_command.dart';

/// `vision profile` 子命名空间 — 结构化视觉档案。
class ProfileNamespace extends CliNamespace {
  static final ProfileNamespace instance = ProfileNamespace._();
  ProfileNamespace._();

  @override
  String get namespace => 'profile';

  @override
  String get description => 'Structured visual profile (build / get)';

  @override
  String get usage => 'shepaw vision profile.<build|get> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'build': ProfileBuildCommand(),
        'get': ProfileGetCommand(),
      };
}
