import '../models/attachment_data.dart';
import '../models/model_routing_config.dart';
import '../models/pending_attachment.dart';
import '../models/remote_agent.dart';

/// Result of checking whether attachments are compatible with an agent.
class AttachmentValidationResult {
  final bool ok;
  final String? errorKey;

  const AttachmentValidationResult._({required this.ok, this.errorKey});

  factory AttachmentValidationResult.success() =>
      const AttachmentValidationResult._(ok: true);

  factory AttachmentValidationResult.failure(String errorKey) =>
      AttachmentValidationResult._(ok: false, errorKey: errorKey);
}

/// Pure modality checks for pending / saved attachments against a local agent.
class ChatAttachmentValidator {
  ChatAttachmentValidator._();

  /// Validate UI-pending attachments before they are persisted.
  static AttachmentValidationResult validatePendingForAgent(
    RemoteAgent agent,
    List<PendingAttachment> attachments,
  ) {
    if (!agent.isLocal) return AttachmentValidationResult.success();
    for (final att in attachments) {
      if (att.type == PendingAttachmentType.image &&
          !agent.supportsModality(ModalityType.image)) {
        return AttachmentValidationResult.failure(
          'chat_modalityNotSupported:image',
        );
      }
    }
    return AttachmentValidationResult.success();
  }

  /// Validate a saved [AttachmentData] before sending to the agent.
  static AttachmentValidationResult validateDataForAgent(
    RemoteAgent agent,
    AttachmentData attachment,
  ) {
    if (!agent.isLocal) return AttachmentValidationResult.success();
    final modality =
        ModelRoutingConfig.detectModality([attachment.semanticType]);
    if (modality == ModalityType.text) {
      return AttachmentValidationResult.success();
    }
    if (!agent.supportsModality(modality)) {
      return AttachmentValidationResult.failure(
        'chat_modalityNotSupported:${modality.name}',
      );
    }
    return AttachmentValidationResult.success();
  }
}
