/// ACP Agent Connection
/// Manages a single WebSocket connection to a remote Agent,
/// implementing bidirectional JSON-RPC 2.0 communication.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/acp_protocol.dart';
import 'acp_hub_handlers.dart';
import 'logger_service.dart';
import 'noise/noise_envelope.dart';
import 'noise/noise_session.dart';
import 'noise_identity.dart';
import 'ui_component_registry.dart';

/// Cancellation token for ACP protocol operations.
/// Sends `agent.cancelTask` to the remote Agent when cancelled,
/// and invokes a local [onCancelled] callback so the waiting
/// `taskCompleter` can be resolved immediately without relying
/// on the remote Agent to respond.
class ACPCancellationToken {
  bool _isCancelled = false;
  ACPAgentConnection? _connection;
  String? _taskId;

  /// Callback invoked synchronously when [cancel] is called.
  /// Used by the chat service to complete the task completer locally.
  void Function()? onCancelled;

  bool get isCancelled => _isCancelled;

  void bind(ACPAgentConnection connection, String taskId) {
    _connection = connection;
    _taskId = taskId;
  }

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    // Notify local listeners first so the UI unblocks immediately.
    onCancelled?.call();
    // Then best-effort tell the remote Agent to stop.
    if (_connection != null && _taskId != null) {
      _connection!.cancelTask(_taskId!).catchError((_) => ACPResponse(jsonrpc: '2.0', id: 0));
    }
  }
}

/// Per-task callback bundle, keyed by task_id in ACPAgentConnection.
class TaskCallbacks {
  final void Function(Map<String, dynamic> data)? onTextContent;
  final void Function(Map<String, dynamic> data)? onActionConfirmation;
  final void Function(Map<String, dynamic> data)? onSingleSelect;
  final void Function(Map<String, dynamic> data)? onMultiSelect;
  final void Function(Map<String, dynamic> data)? onFileUpload;
  final void Function(Map<String, dynamic> data)? onForm;
  final Future<void> Function(Map<String, dynamic> data)? onFileMessage;
  final void Function(Map<String, dynamic> data)? onMessageMetadata;
  final void Function(Map<String, dynamic> data)? onRequestHistory;
  final void Function(Map<String, dynamic> data)? onTaskStarted;
  final void Function(Map<String, dynamic> data)? onTaskCompleted;
  final void Function(Map<String, dynamic> data)? onTaskError;

  const TaskCallbacks({
    this.onTextContent,
    this.onActionConfirmation,
    this.onSingleSelect,
    this.onMultiSelect,
    this.onFileUpload,
    this.onForm,
    this.onFileMessage,
    this.onMessageMetadata,
    this.onRequestHistory,
    this.onTaskStarted,
    this.onTaskCompleted,
    this.onTaskError,
  });
}

/// Manages a single WebSocket connection to a remote Agent.
///
/// Implements the full ACP bidirectional JSON-RPC 2.0 protocol:
/// - App -> Agent: requests (agent.chat, agent.cancelTask, etc.)
/// - Agent -> App: notifications (ui.textContent, task.*, etc.)
/// - Agent -> App: requests (hub.*) delegated to [ACPHubHandlers]
class ACPAgentConnection {
  final String agentId;
  final ACPHubHandlers? _hubHandlers;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  int _requestId = 0;
  bool _isConnected = false;
  bool _isAuthenticated = false;
  /// 当 [dispose] 被调用后置 true。后续任何错误/断开事件都不再触发自动重连，
  /// 避免"被主动替换掉的旧连接"在后台重新抢活，影响新连接的生命周期。
  bool _disposed = false;
  String? _wsUrl;
  String? _token;

  /// Pending request completers (keyed by request ID)
  final Map<dynamic, Completer<ACPResponse>> _pendingRequests = {};

  /// Active Noise v2 session for this connection. `null` while no connection
  /// is established; set once the IK handshake completes.
  NoiseSession? _noise;

  /// 32-byte peer static public key learned during the last successful
  /// handshake. Exposed via [peerStaticPublicKey] so callers can persist it
  /// to the remote-agent record (used by re-pair detection on subsequent
  /// connects).
  Uint8List? _peerStaticPublicKeyAfterHandshake;

  /// Heartbeat timer
  Timer? _heartbeatTimer;
  final int heartbeatIntervalSeconds;
  int _consecutiveHeartbeatFailures = 0;
  final int maxHeartbeatFailures;

  /// Auto-reconnect
  final bool autoReconnect;
  final int reconnectDelayMs;
  int _reconnectAttempts = 0;
  final int maxReconnectAttempts;

  // ==================== Per-task Callback Registry ====================

  /// Per-task callback registry. key = task_id (UUID string).
  final Map<String, TaskCallbacks> _taskCallbacks = {};

  void registerTaskCallbacks(String taskId, TaskCallbacks callbacks) {
    _taskCallbacks[taskId] = callbacks;
  }

  void unregisterTaskCallbacks(String taskId) {
    _taskCallbacks.remove(taskId);
  }

  // ==================== File Transfer Callbacks ====================

  void Function(String fileId, Uint8List chunk)? onFileChunk;
  void Function(String fileId, int totalBytes)? onFileTransferComplete;
  void Function(String fileId, String error)? onFileTransferError;

  /// Called when connection state changes
  void Function(bool isConnected)? onConnectionStateChanged;

  ACPAgentConnection({
    required this.agentId,
    ACPHubHandlers? hubHandlers,
    this.heartbeatIntervalSeconds = 30,
    this.autoReconnect = true,
    this.reconnectDelayMs = 3000,
    this.maxReconnectAttempts = 5,
    this.maxHeartbeatFailures = 3,
  }) : _hubHandlers = hubHandlers;

  /// The targetAgentId used during the initial [connect] call.
  /// Preserved so that [tryReconnectNow] can pass it through on reconnect.
  String? _targetAgentId;

  /// Pinned fingerprint + cached peer pubkey from the most recent [connect],
  /// so reconnect paths can re-run the handshake without the caller re-passing.
  String? _pinnedFingerprint;
  Uint8List? _cachedPeerStaticPublicKey;

  bool get isConnected => _isConnected;
  bool get isAuthenticated => _isAuthenticated;

  /// Peer static public key learned during the Noise handshake. Null until
  /// [connect] completes successfully. Callers may persist this in their
  /// remote-agent record so the fingerprint can be re-verified on reconnect
  /// without re-walking the handshake.
  Uint8List? get peerStaticPublicKey => _peerStaticPublicKeyAfterHandshake;

  /// Connect to the Agent's WebSocket endpoint using the v2.1 ACP protocol
  /// (Noise IK over WebSocket, authorized-peer allowlist).
  ///
  /// [wsUrl] - base WebSocket URL (without query params).
  /// [token] - IGNORED in v2.1. The parameter is kept for API compatibility
  ///   with call sites that still pass it; it is not sent to the agent in
  ///   any form. Authentication in v2.1 is entirely by this app's static
  ///   X25519 public key being present in the agent's `authorized_peers.json`
  ///   — if it isn't, the handshake closes with WS 4405 and [connect] throws
  ///   [PeerNotAuthorizedException]. To authorize this device, run
  ///   `shepaw-codebuddy-code peers add <publicKeyBase64>` on the agent host.
  /// [pinnedFingerprint] - required. 16-hex short fingerprint (first 8 bytes
  ///   of SHA-256(peerStaticPub)) obtained out-of-band from the agent's
  ///   banner URL fragment `#fp=…`. If the agent's real static pubkey does
  ///   NOT hash to this value, [connect] throws [FingerprintMismatchException]
  ///   and the connection is closed — do not auto-accept.
  ///
  ///   Callers that don't yet track fingerprints (legacy call sites) may
  ///   pass an empty string — [connect] will immediately throw
  ///   [FingerprintMissingException] so the UI can prompt re-pairing rather
  ///   than falling back to plaintext.
  /// [cachedPeerStaticPublicKey] - optional cached 32-byte full pubkey from
  ///   a previous successful connect. When provided it's cross-checked
  ///   against what we learn this round; a mismatch throws. If absent, the
  ///   pubkey is looked up from the post-handshake state and the caller can
  ///   persist it via [peerStaticPublicKey].
  /// [targetAgentId] - optional; if set, passed into the handshake-1 payload
  ///   as `agentId` so the server can reject handshake if its own identity
  ///   differs.
  Future<void> connect(
    String wsUrl,
    // ignore: avoid_positional_boolean_parameters
    String token, {
    String pinnedFingerprint = '',
    Uint8List? cachedPeerStaticPublicKey,
    String? targetAgentId,
    String? enrollmentCode,
  }) async {
    if (_isConnected) return;

    if (pinnedFingerprint.isEmpty) {
      throw FingerprintMissingException(
        'Cannot connect: no pinned fingerprint provided. This agent was '
        'paired before v2 — please remove and re-add it using the URL from '
        'the agent banner (the URL should include `#fp=…`).',
      );
    }
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(pinnedFingerprint)) {
      throw ArgumentError(
        'pinnedFingerprint must be 16 lowercase hex chars (got "$pinnedFingerprint")',
      );
    }

    _wsUrl = wsUrl;
    _token = token; // stored only for reconnect-condition parity; never sent
    _targetAgentId = targetAgentId;
    _pinnedFingerprint = pinnedFingerprint;
    _cachedPeerStaticPublicKey = cachedPeerStaticPublicKey;

    try {
      // Load (or generate) this app's long-term Noise static keypair.
      final identity = await NoiseIdentity.loadOrCreate();

      // v2.1 URI construction: no `?token=` query param, no `Authorization`
      // header. The only pre-handshake metadata is the agentId hint (routing
      // optimization — the agent still validates the real identity after
      // Noise completes).
      final base = Uri.parse(wsUrl);
      final params = Map<String, String>.from(base.queryParameters);
      params.remove('token'); // defense in depth if caller's URL still had one
      if (targetAgentId != null && targetAgentId.isNotEmpty) {
        params['agentId'] = targetAgentId;
      }
      final uri = base.replace(queryParameters: params);

      // Open the WS. No Authorization header in v2.1 — authorization is
      // by the app's static public key presented during the Noise handshake
      // and checked against the agent's allowlist.
      final ioSocket = await io.WebSocket.connect(uri.toString());
      _channel = IOWebSocketChannel(ioSocket);
      await _channel!.ready;

      // Drive the Noise IK handshake BEFORE marking the connection as ready
      // for general JSON-RPC traffic. If anything here throws the connection
      // is torn down and we rethrow.
      await _driveHandshake(
        identity: identity,
        pinnedFingerprint: pinnedFingerprint,
        cachedPeerStaticPublicKey: cachedPeerStaticPublicKey,
        claimedAgentId: targetAgentId,
        enrollmentCode: enrollmentCode,
      );

      _isConnected = true;
      _isAuthenticated = true; // authenticated via Noise IK handshake
      _reconnectAttempts = 0;
      _consecutiveHeartbeatFailures = 0;
      onConnectionStateChanged?.call(true);

      // Attach the normal message listener for post-handshake traffic.
      _subscription = _channel!.stream.listen(
        _handleMessage,
        onError: _handleError,
        onDone: _handleDisconnect,
        cancelOnError: false,
      );

      // Start heartbeat
      _startHeartbeat();

      LoggerService().debug('Connected to $wsUrl (v2.1)', tag: 'ACP');
    } catch (e) {
      _isConnected = false;
      _isAuthenticated = false;
      // Translate known WS close codes from the v2.1 server into typed
      // exceptions before rethrowing — the UI needs to distinguish
      // "unauthorized, re-pair" from "revoked, delete agent" from generic
      // transport errors.
      final translated = _translateCloseCode(e);
      try {
        _noise?.close();
      } catch (_) {}
      _noise = null;
      try {
        await _channel?.sink.close();
      } catch (_) {}
      _channel = null;
      onConnectionStateChanged?.call(false);
      if (translated != null) throw translated;
      rethrow;
    }
  }

  /// Map the WS close code the server sent (visible on [WebSocketException]
  /// inside `io.WebSocket.connect` or on the channel's `closeCode` after a
  /// clean close) into the v2.1-specific exception classes the UI handles.
  /// Returns `null` if no code match — callers fall back to rethrowing the
  /// original error unchanged.
  Exception? _translateCloseCode(Object err) {
    final code = _channel?.closeCode;
    if (code == null) return null;
    switch (code) {
      case 4403:
        return FingerprintMismatchException(
          'Agent reported a different public-key fingerprint than the one '
          'pinned during pairing. Possible agent-host compromise or key '
          'rotation; re-pair to continue.',
        );
      case 4404:
        return AgentIdMismatchException(
          'Agent reported a different agentId than expected.',
        );
      case 4405:
        return PeerNotAuthorizedException(
          'This device is not authorized on the agent.\n\n'
          'Ask the agent operator to run:\n'
          '  <gateway> peers add <your-public-key>\n\n'
          'Your public key is on the "Add remote agent" screen.',
        );
      case 4411:
        return PeerUnregisteredException(
          'The agent removed this device from its allowlist. '
          'Re-pair if you still need access.',
        );
      default:
        return null;
    }
  }

  /// Perform the v2 Noise IK handshake. Sets `_noise` and
  /// `_peerStaticPublicKeyAfterHandshake` on success; throws otherwise.
  ///
  /// During the handshake we temporarily consume the raw WebSocket stream
  /// rather than routing through `_handleMessage` — this keeps the handshake
  /// self-contained and avoids interleaving with post-handshake dispatch.
  Future<void> _driveHandshake({
    required NoiseIdentity identity,
    required String pinnedFingerprint,
    required Uint8List? cachedPeerStaticPublicKey,
    required String? claimedAgentId,
    String? enrollmentCode,
  }) async {
    // We don't know the real peer static pubkey yet. IK requires it upfront.
    // The fingerprint gives us a commit: after the handshake we verify
    // sha256(actualPeerStatic)[0..8] == pinnedFingerprint. But IK's initiator
    // must pass *some* 32-byte key to the Noise initialization that, once
    // used in `es`/`ss` DH, makes the responder's decrypt succeed.
    //
    // If we have a cached full pubkey from a previous successful connect, we
    // use it; if it's wrong (agent rotated keys), the handshake will fail
    // with a clear "fingerprint mismatch or identity rotated" error.
    //
    // If we DON'T have a cached pubkey (first connect), we cannot run IK —
    // we don't know the 32-byte key. We need a pre-pair round trip to learn
    // it. For v2 we require the caller to persist it after the first
    // handshake; to bootstrap that, we support an "unsafe-first-connect"
    // mode by rejecting right here with a specific error that says
    // "provide cachedPeerStaticPublicKey or complete first-pair flow".
    //
    // FIRST-PAIR WORKAROUND: since fingerprint alone is NOT enough for IK,
    // the add-remote-agent flow must either (a) include the full pubkey in
    // the URL (base64) alongside the fp, or (b) the first connect uses XX
    // pattern which doesn't require the static key upfront. For v2 scope,
    // we REQUIRE the URL fragment to carry both, or the caller to have
    // previously paired out-of-band. See SECURITY.md for discussion.
    final peerStaticCandidate = cachedPeerStaticPublicKey;
    if (peerStaticCandidate == null) {
      throw FingerprintMismatchException(
        'No cached peer static public key available. First-pair flow must '
        'include the full responder public key alongside the fingerprint '
        '(URL fragment `#fp=<fp>&pk=<b64>`), or the user must re-pair.',
      );
    }

    // Cross-check the candidate against the pinned fingerprint.
    final candidateFp = _computeFingerprint(peerStaticCandidate);
    if (candidateFp != pinnedFingerprint) {
      throw FingerprintMismatchException(
        'Cached peer pubkey fingerprint ($candidateFp) does not match '
        'pinned fingerprint ($pinnedFingerprint). Agent identity may have '
        'been rotated — re-pair from the current URL, or verify the agent '
        "host wasn't compromised.",
      );
    }

    final session = await NoiseSession.initiator(
      staticPublicKey: identity.publicKey,
      staticPrivateKey: identity.privateKey,
      pinnedPeerStaticPublicKey: peerStaticCandidate,
    );

    // Build handshake-1 payload.
    // v2.1: optionally include `enroll` — a single-use pairing code the user
    // typed from the agent's `enroll` CLI output. The agent consumes the
    // token and auto-adds our static pubkey to its authorized_peers.json,
    // promoting a "first pair" connection into the steady state. After this
    // one handshake the code is invalid; subsequent reconnects MUST NOT send
    // it (loadOrCreate caller stashes enrollmentCode only for the very first
    // connect call, never for reconnects).
    final hs1Payload = <String, dynamic>{
      'agentId': claimedAgentId ?? '',
      'clientVersion': 'shepaw/v2.1',
    };
    if (enrollmentCode != null && enrollmentCode.isNotEmpty) {
      hs1Payload['enroll'] = enrollmentCode;
    }
    final msg1 = await session.writeHandshake1(
      utf8.encode(jsonEncode(hs1Payload)),
    );
    _channel!.sink.add(encodeFrame(Frame(t: FrameType.hs, payload: msg1)));

    // Wait for msg2 via a one-shot stream listener.
    final msg2Completer = Completer<String>();
    late StreamSubscription hsSub;
    hsSub = _channel!.stream.listen(
      (raw) {
        if (msg2Completer.isCompleted) return;
        if (raw is String) {
          msg2Completer.complete(raw);
        } else if (raw is List<int>) {
          msg2Completer.complete(utf8.decode(raw));
        } else {
          msg2Completer.completeError(
            StateError('unexpected WS frame type ${raw.runtimeType}'),
          );
        }
      },
      onError: (Object e, StackTrace st) {
        if (!msg2Completer.isCompleted) msg2Completer.completeError(e, st);
      },
      onDone: () {
        if (!msg2Completer.isCompleted) {
          msg2Completer.completeError(
            StateError('ws closed before handshake 2'),
          );
        }
      },
      cancelOnError: false,
    );

    Future<String> withTimeout() => msg2Completer.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException('Noise handshake timeout'),
        );
    final String msg2Raw;
    try {
      msg2Raw = await withTimeout();
    } finally {
      await hsSub.cancel();
    }

    final Frame frame;
    try {
      frame = decodeFrame(msg2Raw, maxPayload: maxFrameAgentToApp);
    } on EnvelopeError catch (e) {
      throw NoiseHandshakeError('handshake-2 envelope error: ${e.message}');
    }
    if (frame.t != FrameType.hs) {
      throw NoiseHandshakeError('expected hs frame, got ${frame.t}');
    }

    final hs2 = await session.readHandshake2(frame.payload);

    // Double-check: the session's remote static pubkey must still hash to
    // the pinned fingerprint. This should always hold because the initiator
    // pinned it at construction, but defense in depth.
    final finalFp = _computeFingerprint(hs2.peerStaticPublicKey);
    if (finalFp != pinnedFingerprint) {
      throw FingerprintMismatchException(
        'Post-handshake fingerprint mismatch (got $finalFp, expected $pinnedFingerprint)',
      );
    }

    // Validate agentId in hs2 payload if we claimed one.
    if (claimedAgentId != null && claimedAgentId.isNotEmpty) {
      try {
        final payloadObj =
            jsonDecode(utf8.decode(hs2.msg2Payload)) as Map<String, dynamic>;
        final serverAgentId = payloadObj['agentId'] as String?;
        if (serverAgentId != null && serverAgentId != claimedAgentId) {
          throw AgentIdMismatchException(
            'Server reported agentId=$serverAgentId, expected $claimedAgentId',
          );
        }
      } catch (e) {
        if (e is AgentIdMismatchException) rethrow;
        // Payload not JSON — accept but don't crash. Older servers may not
        // populate this.
      }
    }

    _noise = session;
    _peerStaticPublicKeyAfterHandshake = hs2.peerStaticPublicKey;
    LoggerService().info(
      'Noise v2 handshake complete (fp=$finalFp)',
      tag: 'ACP',
    );
  }

  /// Compute the 16-hex fingerprint of a 32-byte static public key.
  /// Matches agent's `identity.ts:derivedFingerprint`.
  String _computeFingerprint(Uint8List publicKey) {
    // Reuse the same routine the NoiseIdentity class uses internally —
    // extract the algorithm to keep it in one place. We inline here for
    // convenience; if the hash ever changes we update both sites together.
    final digest = _sha256(publicKey);
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  Uint8List _sha256(Uint8List input) {
    return Uint8List.fromList(crypto.sha256.convert(input).bytes);
  }

  /// Disconnect from the Agent.
  Future<void> disconnect() async {
    _stopHeartbeat();
    _subscription?.cancel();
    _subscription = null;

    try {
      _noise?.close();
    } catch (_) {}
    _noise = null;
    _peerStaticPublicKeyAfterHandshake = null;

    try {
      await _channel?.sink.close();
    } catch (_) {}

    _channel = null;
    _isConnected = false;
    _isAuthenticated = false;
    onConnectionStateChanged?.call(false);

    // Fail all pending requests
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('Connection closed'));
      }
    }
    _pendingRequests.clear();
  }

  /// v2.1: ask the agent to remove this device from its `authorized_peers.json`
  /// before the app forgets the agent locally. The agent identifies the peer
  /// via the session's Noise static public key (unforgeable), so no params
  /// are needed — just the `peer.unregister` notification method name.
  ///
  /// Best-effort: returns silently if no session is live, or if the send
  /// fails partway. Callers (typically `RemoteAgentService.deleteAgent`)
  /// should proceed with local deletion regardless — the user's intent is
  /// "forget this agent on this phone", and failure here only means the
  /// agent's allowlist stays stale (harmless: the entry just ages out when
  /// the operator cleans up, or stays inert if the app never reconnects).
  ///
  /// Waits up to 500 ms for the agent to process + close (it responds with
  /// WS close 4411) so the notification gets on the wire before we tear down.
  Future<void> unregisterSelfFromAgent({
    Duration waitForClose = const Duration(milliseconds: 500),
  }) async {
    final session = _noise;
    if (session == null || !session.ready || !_isConnected) {
      LoggerService().debug(
        'unregisterSelfFromAgent: no live session; nothing to do',
        tag: 'ACP',
      );
      return;
    }
    try {
      sendNotification('peer.unregister');
      // Give the server a moment to process + close the WS with 4411.
      // We don't require the 4411 to arrive — on mobile the app often
      // tears down the whole Dart isolate right after this call anyway.
      await _channel?.sink.done
          .timeout(waitForClose, onTimeout: () {})
          .catchError((_) {});
    } catch (e) {
      LoggerService().warning(
        'unregisterSelfFromAgent send failed (ignored): $e',
        tag: 'ACP',
      );
    }
  }

  /// Authenticate with the Agent.
  Future<ACPResponse> authenticate(String token) async {
    final response = await sendRequest(
      ACPMethod.authAuthenticate,
      params: {'token': token},
    );

    if (response.isSuccess) {
      _isAuthenticated = true;
    } else {
      throw Exception('Authentication failed: ${response.error?.message}');
    }

    return response;
  }

  /// Send a chat message to the Agent.
  Future<ACPResponse> sendChatMessage({
    required String taskId,
    required String sessionId,
    required String message,
    required String userId,
    required String messageId,
    List<Map<String, dynamic>>? history,
    bool historySupplement = false,
    List<Map<String, dynamic>>? additionalHistory,
    String? originalQuestion,
    int? totalMessageCount,
    String? systemPrompt,
    Map<String, dynamic>? groupContext,
    List<Map<String, dynamic>>? attachments,
  }) async {
    final params = <String, dynamic>{
      'task_id': taskId,
      'session_id': sessionId,
      'message': message,
      'user_id': userId,
      'message_id': messageId,
    };

    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      params['system_prompt'] = systemPrompt;
    }

    if (history != null && history.isNotEmpty) {
      params['history'] = history;
    }

    if (totalMessageCount != null) {
      params['total_message_count'] = totalMessageCount;
    }

    params['ui_component_version'] = UIComponentRegistry.version;

    if (historySupplement) {
      params['history_supplement'] = true;
      if (additionalHistory != null) {
        params['additional_history'] = additionalHistory;
      }
      if (originalQuestion != null) {
        params['original_question'] = originalQuestion;
      }
    }

    if (groupContext != null && groupContext.isNotEmpty) {
      params['group_context'] = groupContext;
    }

    if (attachments != null && attachments.isNotEmpty) {
      params['attachments'] = attachments;
    }

    return await sendRequest(ACPMethod.agentChat, params: params);
  }

  /// Cancel a running task.
  Future<ACPResponse> cancelTask(String taskId) async {
    return await sendRequest(
      ACPMethod.agentCancelTask,
      params: {'task_id': taskId},
    );
  }

  /// Submit an interactive response (action confirmation, select, form, etc.)
  Future<ACPResponse> submitResponse({
    required String taskId,
    required String responseType,
    required Map<String, dynamic> responseData,
  }) async {
    return await sendRequest(
      ACPMethod.agentSubmitResponse,
      params: {
        'task_id': taskId,
        'response_type': responseType,
        'response_data': responseData,
      },
    );
  }

  /// Rollback a message.
  Future<ACPResponse> rollback({
    required String sessionId,
    required String messageId,
  }) async {
    return await sendRequest(
      ACPMethod.agentRollback,
      params: {
        'session_id': sessionId,
        'message_id': messageId,
      },
    );
  }

  /// Get the Agent card.
  Future<ACPResponse> getAgentCard() async {
    return await sendRequest(ACPMethod.agentGetCard);
  }

  /// Send a ping.
  Future<ACPResponse> ping() async {
    return await sendRequest(ACPMethod.ping);
  }

  /// Attempt a one-shot reconnect (e.g. after returning from background).
  /// Resets the reconnect counter so that the full retry budget is available.
  /// Returns `true` if the connection is established, `false` otherwise.
  Future<bool> tryReconnectNow() async {
    if (_isConnected) return true;
    if (_wsUrl == null || _token == null || _pinnedFingerprint == null) {
      return false;
    }

    _reconnectAttempts = 0;
    try {
      await connect(
        _wsUrl!,
        _token!,
        pinnedFingerprint: _pinnedFingerprint!,
        cachedPeerStaticPublicKey:
            _peerStaticPublicKeyAfterHandshake ?? _cachedPeerStaticPublicKey,
        targetAgentId: _targetAgentId,
      );
      return _isConnected;
    } catch (e) {
      LoggerService().error('tryReconnectNow failed', tag: 'ACP', error: e);
      return false;
    }
  }

  // ==================== Low-level send/receive ====================

  /// Send a JSON-RPC request and wait for response.
  Future<ACPResponse> sendRequest(String method, {Map<String, dynamic>? params}) async {
    if (!_isConnected) {
      throw Exception('Not connected to Agent');
    }

    final id = _nextRequestId();
    final request = ACPRequest(method: method, params: params, id: id);

    final completer = Completer<ACPResponse>();
    _pendingRequests[id] = completer;

    await _sendEncrypted(request.toJsonString());

    return completer.future.timeout(
      const Duration(seconds: 120),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('Request timeout for $method');
      },
    );
  }

  /// Send a JSON-RPC notification (no response expected).
  void sendNotification(String method, {Map<String, dynamic>? params}) {
    if (!_isConnected) return;

    final notification = ACPNotification(method: method, params: params);
    // Fire-and-forget: _sendEncrypted is async because encrypt() is async,
    // but sendNotification has always been sync in its public contract.
    // Schedule the send and swallow any error (connection teardown will
    // surface it through the usual channel).
    unawaited(_sendEncrypted(notification.toJsonString()));
  }

  /// Serialise + encrypt + write one JSON-RPC message. Handles the two cases:
  ///   - Noise session ready: wrap in a `data` frame with AEAD ciphertext
  ///   - Noise session not ready (shouldn't happen post-handshake; logged):
  ///     drop and log. We DO NOT fall back to plaintext — that would create
  ///     a downgrade vector.
  Future<void> _sendEncrypted(String jsonPayload) async {
    final session = _noise;
    final channel = _channel;
    if (session == null || !session.ready || channel == null) {
      LoggerService().warning(
        'Dropping outbound message — Noise session not ready',
        tag: 'ACP',
      );
      return;
    }
    final ct = await session.encrypt(utf8.encode(jsonPayload));
    channel.sink.add(encodeFrame(Frame(t: FrameType.data, payload: ct)));
  }

  // ==================== Message handling ====================

  Future<void> _handleMessage(dynamic rawMessage) async {
    try {
      // v2 protocol: every inbound frame is a JSON envelope wrapping either
      // a handshake message, an encrypted data payload, or a plaintext error.
      // We drop binary frames entirely — v2 never uses them on the wire
      // (file chunks, when they come back in v2.1, will travel as `data`
      // frames with a JSON-RPC binary_chunk payload inside).
      if (rawMessage is! String) {
        LoggerService().warning(
          'Dropping unexpected non-text WS frame (type=${rawMessage.runtimeType})',
          tag: 'ACP',
        );
        return;
      }

      final Frame frame;
      try {
        frame = decodeFrame(rawMessage, maxPayload: maxFrameAgentToApp);
      } on EnvelopeError catch (e) {
        LoggerService().error(
          'Envelope decode failed (${e.code}): ${e.message}',
          tag: 'ACP',
        );
        return;
      }

      if (frame.t == FrameType.err) {
        // Server told us they're aborting. Log and let the close flow handle
        // teardown — there's nothing useful to reply with.
        LoggerService().warning(
          'Agent sent an err frame (${utf8.decode(frame.payload, allowMalformed: true)})',
          tag: 'ACP',
        );
        return;
      }

      if (frame.t != FrameType.data) {
        // Hs frames after handshake complete → protocol violation. Drop.
        LoggerService().warning(
          'Ignoring unexpected ${frame.t} frame post-handshake',
          tag: 'ACP',
        );
        return;
      }

      final session = _noise;
      if (session == null || !session.ready) {
        LoggerService().error(
          'Received data frame but Noise session is not ready',
          tag: 'ACP',
        );
        return;
      }

      final Uint8List plaintext;
      try {
        plaintext = await session.decrypt(frame.payload);
      } catch (e) {
        // Any decrypt failure is fatal — session may be out of sync or
        // under attack. Surface via logs and close.
        LoggerService().error(
          'Transport decrypt failed; closing connection',
          tag: 'ACP',
          error: e,
        );
        try {
          await _channel?.sink.close();
        } catch (_) {}
        return;
      }

      final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;

      final hasId = json.containsKey('id') && json['id'] != null;
      final hasMethod = json.containsKey('method') && json['method'] != null;

      if (hasId && hasMethod) {
        // Agent -> App Request (has both id and method, e.g. hub.*)
        _handleIncomingRequest(json);
      } else if (hasId && !hasMethod) {
        // Response to our request (has id, no method)
        _handleResponse(json);
      } else if (hasMethod && !hasId) {
        // Notification from Agent (has method, no id, e.g. ui.*, task.*)
        await _handleNotification(json);
      }
    } catch (e) {
      LoggerService().error('Failed to parse message', tag: 'ACP', error: e);
    }
  }

  /// Handle a response to one of our pending requests.
  void _handleResponse(Map<String, dynamic> json) {
    final response = ACPResponse.fromJson(json);
    // The pending requests map is keyed by int (from _nextRequestId).
    // The server may echo the id back as a String (e.g. "1") or as an int (1).
    // Normalise to int so the map lookup always succeeds.
    final rawId = response.id;
    final id = rawId is int ? rawId : int.tryParse(rawId.toString()) ?? rawId;
    final completer = _pendingRequests.remove(id);

    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
  }

  /// Handle an incoming request from the Agent (hub.* methods).
  Future<void> _handleIncomingRequest(Map<String, dynamic> json) async {
    final request = ACPRequest.fromJson(json);

    if (_hubHandlers != null) {
      final response = await _hubHandlers!.handleRequest(
        method: request.method,
        id: request.id,
        params: request.params,
        agentId: agentId,
      );
      await _sendEncrypted(response.toJsonString());
    } else {
      // No full hub handlers — handle lightweight requests directly
      final response = _handleRequestWithoutHubHandlers(request);
      await _sendEncrypted(response.toJsonString());
    }
  }

  /// Handle select hub requests that don't require full ACPHubHandlers.
  ACPResponse _handleRequestWithoutHubHandlers(ACPRequest request) {
    if (request.method == ACPMethod.hubGetUIComponentTemplates) {
      return ACPResponse.success(
        id: request.id,
        result: UIComponentRegistry.instance.toTemplatePayload(),
      );
    }
    return ACPResponse.error(
      id: request.id,
      code: ACPErrorCode.methodNotFound,
      message: 'Hub handlers not available for: ${request.method}',
    );
  }

  /// Handle a notification from the Agent (ui.* and task.* methods).
  Future<void> _handleNotification(Map<String, dynamic> json) async {
    final method = json['method'] as String;
    final params = json['params'] as Map<String, dynamic>? ?? {};

    final taskId = params['task_id'] as String?;
    final cb = (taskId != null) ? _taskCallbacks[taskId] : null;

    if (cb == null && taskId != null) {
      LoggerService().debug(
        'No callbacks for task_id=$taskId, method=$method (task may have been unregistered)',
        tag: 'ACP',
      );
    }

    switch (method) {
      case ACPMethod.uiTextContent:
        cb?.onTextContent?.call(params);
        break;
      case ACPMethod.uiActionConfirmation:
        cb?.onActionConfirmation?.call(params);
        break;
      case ACPMethod.uiSingleSelect:
        cb?.onSingleSelect?.call(params);
        break;
      case ACPMethod.uiMultiSelect:
        cb?.onMultiSelect?.call(params);
        break;
      case ACPMethod.uiFileUpload:
        cb?.onFileUpload?.call(params);
        break;
      case ACPMethod.uiForm:
        cb?.onForm?.call(params);
        break;
      case ACPMethod.uiFileMessage:
        await cb?.onFileMessage?.call(params);
        break;
      case ACPMethod.uiMessageMetadata:
        cb?.onMessageMetadata?.call(params);
        break;
      case ACPMethod.uiRequestHistory:
        cb?.onRequestHistory?.call(params);
        break;
      case ACPMethod.taskStarted:
        cb?.onTaskStarted?.call(params);
        break;
      case ACPMethod.taskCompleted:
        cb?.onTaskCompleted?.call(params);
        break;
      case ACPMethod.taskError:
        cb?.onTaskError?.call(params);
        break;
      case ACPMethod.fileTransferComplete:
        final fileId = params['file_id'] as String? ?? '';
        final totalBytes = params['total_bytes'] as int? ?? 0;
        onFileTransferComplete?.call(fileId, totalBytes);
        break;
      case ACPMethod.fileTransferError:
        final fileId = params['file_id'] as String? ?? '';
        final error = params['error'] as String? ?? 'Unknown error';
        onFileTransferError?.call(fileId, error);
        break;
      default:
        LoggerService().debug('Unknown notification: $method', tag: 'ACP');
    }
  }

  // ==================== Binary frame handling ====================

  /// Parse a binary WebSocket frame containing a file chunk.
  /// Header: [4 bytes magic "FILE"] [12 bytes file_id, null-padded UTF-8] [rest: chunk data]
  ///
  /// v2 protocol: kept intentionally. Raw binary WebSocket frames are no
  /// longer sent on the wire (they would bypass Noise), but this parser is
  /// preserved so a future v2.1 file-transfer flow that wraps binary chunks
  /// in encrypted `data` frames can reuse the same file-id protocol
  /// (JSON-RPC notification carries the base64 body → this routine parses
  /// the binary form once it's been decrypted).
  // ignore: unused_element
  void _handleBinaryFrame(Uint8List data) {
    if (data.length < 16) return; // Too short to contain header

    // Validate magic bytes: 0x46494C45 ("FILE")
    if (data[0] != 0x46 || data[1] != 0x49 || data[2] != 0x4C || data[3] != 0x45) {
      LoggerService().debug('Binary frame with unknown magic, ignoring', tag: 'ACP');
      return;
    }

    // Extract file_id from bytes 4-16 (null-padded UTF-8)
    final fileIdBytes = data.sublist(4, 16);
    int nullIdx = fileIdBytes.indexOf(0);
    if (nullIdx == -1) nullIdx = 12;
    final fileId = String.fromCharCodes(fileIdBytes.sublist(0, nullIdx));

    // Extract payload from byte 16+
    final payload = data.sublist(16);

    onFileChunk?.call(fileId, payload);
  }

  // ==================== Connection lifecycle ====================

  void _handleError(dynamic error) {
    LoggerService().error('WebSocket error', tag: 'ACP', error: error);
    if (autoReconnect && !_disposed) {
      _tryReconnect();
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _isAuthenticated = false;
    _stopHeartbeat();
    onConnectionStateChanged?.call(false);

    if (autoReconnect && !_disposed) {
      _tryReconnect();
    }
  }

  Future<void> _tryReconnect() async {
    if (_disposed) return;
    if (_wsUrl == null || _token == null) return;
    if (_reconnectAttempts >= maxReconnectAttempts) {
      LoggerService().debug('Max reconnect attempts reached', tag: 'ACP');
      return;
    }

    _reconnectAttempts++;
    await Future.delayed(Duration(milliseconds: reconnectDelayMs));
    if (_disposed) return;

    if (_wsUrl == null || _token == null || _pinnedFingerprint == null) {
      LoggerService().error(
        'Cannot auto-reconnect: missing wsUrl/token/pinnedFingerprint',
        tag: 'ACP',
      );
      return;
    }

    try {
      await connect(
        _wsUrl!,
        _token!,
        pinnedFingerprint: _pinnedFingerprint!,
        cachedPeerStaticPublicKey:
            _peerStaticPublicKeyAfterHandshake ?? _cachedPeerStaticPublicKey,
        targetAgentId: _targetAgentId,
      );
    } catch (e) {
      LoggerService().error('Reconnect failed', tag: 'ACP', error: e);
      if (autoReconnect && !_disposed && _reconnectAttempts < maxReconnectAttempts) {
        _tryReconnect();
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      Duration(seconds: heartbeatIntervalSeconds),
      (_) => _sendHeartbeat(),
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _sendHeartbeat() {
    if (!_isConnected) return;
    ping().then((_) {
      _consecutiveHeartbeatFailures = 0;
    }).catchError((e) {
      _consecutiveHeartbeatFailures++;
      LoggerService().error('Heartbeat failed ($_consecutiveHeartbeatFailures/$maxHeartbeatFailures)', tag: 'ACP', error: e);
      if (_consecutiveHeartbeatFailures >= maxHeartbeatFailures) {
        LoggerService().error('Max heartbeat failures reached, disconnecting', tag: 'ACP');
        disconnect();
      }
    });
  }

  int _nextRequestId() => ++_requestId;

  /// Clean up resources.
  ///
  /// 设置 [_disposed] 标志后，任何进行中/后续的错误、断开事件都不会再触发
  /// 自动重连。该方法用于"主动替换连接"场景（例如 AgentMessagingService 的
  /// 重试循环）——旧实例被 dispose 后不会与新实例抢生命周期。
  void dispose() {
    _disposed = true;
    disconnect();
  }
}

/// Thrown when the agent's real static public key does not hash to the
/// fingerprint the app was given. UI should surface this as a re-pair flow.
class FingerprintMismatchException implements Exception {
  final String message;
  FingerprintMismatchException(this.message);
  @override
  String toString() => 'FingerprintMismatchException: $message';
}

/// Thrown when [ACPAgentConnection.connect] is called without a pinned
/// fingerprint. Separate from [FingerprintMismatchException] so the UI can
/// distinguish "your saved agent is too old, re-pair" from "the agent you're
/// pairing now doesn't match what you saved".
class FingerprintMissingException implements Exception {
  final String message;
  FingerprintMissingException(this.message);
  @override
  String toString() => 'FingerprintMissingException: $message';
}

/// Thrown when the agent's reported agentId does not match the one the app
/// expected to talk to.
class AgentIdMismatchException implements Exception {
  final String message;
  AgentIdMismatchException(this.message);
  @override
  String toString() => 'AgentIdMismatchException: $message';
}

/// Thrown for any other handshake-level failure (Noise decrypt failure,
/// malformed frame, timeout). The underlying cause is deliberately NOT
/// surfaced to prevent oracle-style leaks when this error is shown to a
/// peer via UI.
class NoiseHandshakeError implements Exception {
  final String message;
  NoiseHandshakeError(this.message);
  @override
  String toString() => 'NoiseHandshakeError: $message';
}

/// v2.1: thrown when the agent accepted the Noise handshake but this device's
/// static public key is NOT on its `authorized_peers.json` allowlist. The UI
/// should surface the app's own public key (from [NoiseIdentity.publicKeyBase64])
/// and guide the user to run `<gateway> peers add <pubkey>` on the agent host.
///
/// Distinct from [FingerprintMismatchException] (which means "agent identity
/// changed") — a 4405 means "agent identity is fine, but you personally are
/// not on the guest list yet".
class PeerNotAuthorizedException implements Exception {
  final String message;
  PeerNotAuthorizedException(this.message);
  @override
  String toString() => 'PeerNotAuthorizedException: $message';
}

/// v2.1: thrown when the agent closed the connection with WS 4411 because it
/// just removed this device from its allowlist (either via `peers remove`
/// CLI invocation or in response to this app's own `peer.unregister`). UI
/// should tell the user their access was revoked and offer a re-pair flow.
class PeerUnregisteredException implements Exception {
  final String message;
  PeerUnregisteredException(this.message);
  @override
  String toString() => 'PeerUnregisteredException: $message';
}
