import 'dart:async';

import '../peer/models/paired_peer.dart';
import '../services/cli_pouch.dart';
import '../storage/pouch_catalog.dart';

/// 刚配上的主机已经有袋子。一只就用它；多只时优先上次登录的那只。
PouchDescriptor? choosePhonePouch(
  List<PouchDescriptor> pouches, {
  String? savedId,
}) {
  if (pouches.isEmpty) return null;
  final saved = savedId?.trim() ?? '';
  if (saved.isNotEmpty) {
    for (final pouch in pouches) {
      if (pouch.id == saved) return pouch;
    }
  }
  return pouches.first;
}

/// 主机已经回答就用它的名单，空名单也算回答。还没问到时用记住的。
List<PouchDescriptor> phonePouchesToShow({
  required List<PouchDescriptor>? live,
  required List<PouchDescriptor> remembered,
}) {
  if (live != null) return live;
  return remembered;
}

/// 按名称选出储物袋。名称只对上一只就用它；同名多只时只认上次的 ID。
PouchPickResult pickPhonePouch({
  required String typedName,
  required List<PouchDescriptor> pouches,
  String? savedId,
}) {
  return pickPouchAccount(
    typedName: typedName,
    accounts: [
      for (final pouch in pouches)
        CliPouchAccount(id: pouch.id, name: pouch.name),
    ],
    savedId: savedId,
  );
}

/// 这次探测失败值不值得丢掉旧连接再问一次。
///
/// 超时（以及底层还没连上）多半是息屏 / 切网后留下的半开连接；主机明确回
/// 「版本太旧」时重试没有意义。
bool probeRetryable(Object error) {
  if (error is TimeoutException) return true;
  if (error is StateError) return !error.message.contains('旧版本');
  return false;
}

/// 登录该用哪个地址：本机通道优先，然后局域网，最后隧道。
String hubUrlFor(PairedPeer host, {String? localCliEndpoint}) {
  final cli = localCliEndpoint?.trim() ?? '';
  if (cli.isNotEmpty) return cli;
  final local = host.localEndpoint?.trim() ?? '';
  if (local.isNotEmpty) return local;
  return host.channelEndpoint ?? '';
}

/// 欢迎语用的名字。「Eden 的储物袋」→「Eden」。
String welcomeName(String? pouchName) {
  final name = pouchName?.trim() ?? '';
  if (name.isEmpty) return '';
  const suffix = '的储物袋';
  if (name.endsWith(suffix) && name.length > suffix.length) {
    return name.substring(0, name.length - suffix.length);
  }
  return name;
}
