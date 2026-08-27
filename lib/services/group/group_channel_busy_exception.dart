/// Thrown when [ChatService.sendMessageToGroup] refuses a send because that
/// channel already has an in-flight orchestration loop.
class GroupChannelBusyException implements Exception {
  final String channelId;

  const GroupChannelBusyException(this.channelId);

  @override
  String toString() =>
      'GroupChannelBusyException: channel $channelId is already orchestrating';
}
