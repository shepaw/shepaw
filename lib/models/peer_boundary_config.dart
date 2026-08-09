/// Boundary policy when a local agent is serving a paired peer (inbound).
///
/// Persisted as `RemoteAgent.metadata['peer_boundary']`. Missing metadata
/// uses [defaults] — privacy-first for external users.
library;

/// Controls prompt stripping and CLI denials for peer-inbound sessions.
class PeerBoundaryConfig {
  /// Inject an external-serving identity / privacy preamble.
  final bool injectExternalPreamble;

  /// Strip host Master profile, user cognition, and private agent memories
  /// from the system prompt (keep agent identity / soul description).
  final bool stripHostUserContext;

  /// Deny all `os.*` CLI tools for peer-inbound turns.
  final bool disableOsTools;

  /// Deny memory / profile / cognition write CLIs that mutate host data.
  final bool disableMemoryWrites;

  /// Skip session-end instructions that encourage writing to host memory.
  final bool disableSessionEndWrites;

  const PeerBoundaryConfig({
    this.injectExternalPreamble = true,
    this.stripHostUserContext = true,
    this.disableOsTools = true,
    this.disableMemoryWrites = true,
    this.disableSessionEndWrites = true,
  });

  /// Shipping defaults for external serving (privacy-first).
  static const defaults = PeerBoundaryConfig();

  /// No extra peer restrictions (same as local DM aside from channel isolation).
  static const open = PeerBoundaryConfig(
    injectExternalPreamble: false,
    stripHostUserContext: false,
    disableOsTools: false,
    disableMemoryWrites: false,
    disableSessionEndWrites: false,
  );

  factory PeerBoundaryConfig.fromJson(Map<String, dynamic> json) {
    bool flag(String key, bool fallback) => json[key] as bool? ?? fallback;
    return PeerBoundaryConfig(
      injectExternalPreamble:
          flag('inject_external_preamble', defaults.injectExternalPreamble),
      stripHostUserContext:
          flag('strip_host_user_context', defaults.stripHostUserContext),
      disableOsTools: flag('disable_os_tools', defaults.disableOsTools),
      disableMemoryWrites:
          flag('disable_memory_writes', defaults.disableMemoryWrites),
      disableSessionEndWrites:
          flag('disable_session_end_writes', defaults.disableSessionEndWrites),
    );
  }

  Map<String, dynamic> toJson() => {
        'inject_external_preamble': injectExternalPreamble,
        'strip_host_user_context': stripHostUserContext,
        'disable_os_tools': disableOsTools,
        'disable_memory_writes': disableMemoryWrites,
        'disable_session_end_writes': disableSessionEndWrites,
      };

  PeerBoundaryConfig copyWith({
    bool? injectExternalPreamble,
    bool? stripHostUserContext,
    bool? disableOsTools,
    bool? disableMemoryWrites,
    bool? disableSessionEndWrites,
  }) {
    return PeerBoundaryConfig(
      injectExternalPreamble:
          injectExternalPreamble ?? this.injectExternalPreamble,
      stripHostUserContext: stripHostUserContext ?? this.stripHostUserContext,
      disableOsTools: disableOsTools ?? this.disableOsTools,
      disableMemoryWrites: disableMemoryWrites ?? this.disableMemoryWrites,
      disableSessionEndWrites:
          disableSessionEndWrites ?? this.disableSessionEndWrites,
    );
  }

  /// Whether a shepaw CLI call should be denied under this boundary.
  bool blocksCli({
    required String namespace,
    required String subcommand,
  }) {
    final ns = namespace.trim().toLowerCase();
    final sub = subcommand.trim().toLowerCase();
    final id = sub.isEmpty ? ns : '$ns.$sub';

    if (disableOsTools && (ns == 'os' || id.startsWith('os.'))) {
      return true;
    }

    if (disableMemoryWrites) {
      if (ns == 'profile' &&
          (sub.contains('write') || sub.contains('update') || sub.contains('set'))) {
        return true;
      }
      if (id.contains('memory.write') ||
          id.contains('memory.append') ||
          id.contains('memory-write') ||
          id.contains('cognition-write') ||
          id.contains('profile.write')) {
        return true;
      }
    }

    return false;
  }
}

/// Prompt helpers for peer-inbound boundary.
class PeerBoundaryPrompt {
  PeerBoundaryPrompt._();

  /// Privacy / identity preamble for paired-device users.
  static String buildPreamble({String? peerDisplayName}) {
    final who = (peerDisplayName != null && peerDisplayName.trim().isNotEmpty)
        ? peerDisplayName.trim()
        : 'a user on a paired device';
    return '''
## External serving mode
You are currently assisting $who over a paired peer connection — not your host owner's private chat.

Rules:
- Do not reveal the host owner's private profile, notes, or memories.
- Do not write the remote user's information into the host's long-term memory, profile, or cognition stores.
- Do not run local OS / filesystem / shell tools (`os.*`) for the remote user.
- **Store is allowed and preferred for shareable artifacts**: use `shepaw store write` / `shepaw store read` (cite returned `store://` URIs as-is). Do not invent URIs; do not use `os.file.*` as a substitute.
- Stay helpful within conversation, web/search (if available), store tools, and other non-OS tools that are not blocked.
''';
  }
}
