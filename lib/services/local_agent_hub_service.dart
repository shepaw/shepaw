import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../peer/models/pairing_payload.dart';
import '../peer/services/peer_pairing_service.dart';
import '../peer/services/peer_storage_service.dart';
import 'local_agent_hub_host.dart';
import 'local_agent_hub_models.dart';

typedef LocalHubPairedCheck = Future<bool> Function(String fingerprint);
typedef LocalHubPairFn = Future<void> Function(PeerPairingInfo info);

enum LocalHubProgressStep {
  checkingNode,
  installing,
  starting,
  pairing,
}

/// Detects a local Shepaw Agent Hub, pairs the desktop app with it, and can
/// install `shepaw-agent-hub` when nothing is present.
class LocalAgentHubService {
  LocalAgentHubService({
    LocalAgentHubHost? host,
    http.Client? httpClient,
    LocalHubPairedCheck? isPaired,
    LocalHubPairFn? pairFn,
    Future<SharedPreferences> Function()? prefsFactory,
    this.dashboardUrl = kLocalAgentHubDashboardUrl,
    this.clock,
  })  : _host = host ?? LocalAgentHubHost.platform(),
        _http = httpClient ?? http.Client(),
        _isPaired = isPaired ?? _defaultIsPaired,
        _pairFn = pairFn ?? _defaultPair,
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  static final LocalAgentHubService instance = LocalAgentHubService();

  static const _prefSnoozeUntil = 'local_hub.snooze_until';
  static const _prefGuideShown = 'local_hub.add_agent_guide_shown';

  final LocalAgentHubHost _host;
  final http.Client _http;
  final LocalHubPairedCheck _isPaired;
  final LocalHubPairFn _pairFn;
  final Future<SharedPreferences> Function() _prefsFactory;
  final String dashboardUrl;
  final DateTime Function()? clock;

  DateTime get _now => clock?.call() ?? DateTime.now();

  static Future<bool> _defaultIsPaired(String fingerprint) async {
    final peer = await PeerStorageService().getPeerByFingerprint(fingerprint);
    return peer != null;
  }

  static Future<void> _defaultPair(PeerPairingInfo info) {
    return PeerPairingService.instance.requestPairing(info);
  }

  Uri get _dashboardUri => Uri.parse(dashboardUrl);

  String get hubRoot {
    final explicit = _host.env['SHEPAW_HUB_HOME'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final xdg = _host.env['XDG_CONFIG_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return joinPathSegments([xdg, 'shepaw-hub'], windows: _host.isWindows);
    }
    return joinPathSegments(
      [_host.homeDir(), '.config', 'shepaw-hub'],
      windows: _host.isWindows,
    );
  }

  Future<bool> isSnoozed() async {
    final prefs = await _prefsFactory();
    final until = prefs.getInt(_prefSnoozeUntil) ?? 0;
    return until > _now.millisecondsSinceEpoch;
  }

  Future<void> snooze() async {
    final prefs = await _prefsFactory();
    await prefs.setInt(
      _prefSnoozeUntil,
      _now.add(kLocalAgentHubSnooze).millisecondsSinceEpoch,
    );
  }

  Future<bool> addAgentGuideShown() async {
    final prefs = await _prefsFactory();
    return prefs.getBool(_prefGuideShown) ?? false;
  }

  Future<void> markAddAgentGuideShown() async {
    final prefs = await _prefsFactory();
    await prefs.setBool(_prefGuideShown, true);
  }

  Future<LocalHubDetection> detect() async {
    final fingerprint = _readHubFingerprint();
    final alreadyPaired =
        fingerprint != null ? await _isPaired(fingerprint) : false;
    final hubBinary = await _resolveBinary('shepaw-hub');
    final node = await _resolveBinary('node');
    var nodeAvailable = false;
    if (node != null) {
      final ver = await _host.run(
        node,
        ['-v'],
        environment: _host.augmentedEnvironment(),
        timeout: const Duration(seconds: 5),
      );
      nodeAvailable = ver.success && nodeVersionMeetsHub(ver.stdout);
    }

    final health = await _getHealth();
    if (health != null) {
      int? instances;
      if (!health.authRequired) {
        instances = await _fetchInstanceCount();
      }
      return LocalHubDetection(
        presence: LocalHubPresence.running,
        alreadyPaired: alreadyPaired,
        dashboardAuthRequired: health.authRequired,
        instanceCount: instances,
        hubFingerprint: fingerprint,
        hubBinary: hubBinary,
        nodeAvailable: nodeAvailable,
      );
    }

    final configExists = _host.fileExists(
      joinPathSegments([hubRoot, 'hub.json'], windows: _host.isWindows),
    );
    if (hubBinary != null || configExists) {
      return LocalHubDetection(
        presence: LocalHubPresence.installed,
        alreadyPaired: alreadyPaired,
        hubFingerprint: fingerprint,
        hubBinary: hubBinary,
        nodeAvailable: nodeAvailable,
      );
    }

    return LocalHubDetection(
      presence: LocalHubPresence.missing,
      alreadyPaired: alreadyPaired,
      hubFingerprint: fingerprint,
      nodeAvailable: nodeAvailable,
    );
  }

  /// Start the dashboard if needed, mint a pairing QR, and pair this app.
  Future<LocalHubDetection> join({
    void Function(LocalHubProgressStep step)? onProgress,
  }) async {
    onProgress?.call(LocalHubProgressStep.starting);
    await ensureDashboardRunning();
    onProgress?.call(LocalHubProgressStep.pairing);
    await pairWithRunningHub();
    return detect();
  }

  /// `npm install -g shepaw-agent-hub`, start the dashboard, then pair.
  Future<LocalHubDetection> installAndJoin({
    void Function(LocalHubProgressStep step)? onProgress,
  }) async {
    onProgress?.call(LocalHubProgressStep.checkingNode);
    final node = await _resolveBinary('node');
    if (node == null) {
      throw LocalHubException(
        'Node.js is not installed',
        code: 'node-missing',
      );
    }
    final ver = await _host.run(
      node,
      ['-v'],
      environment: _host.augmentedEnvironment(),
      timeout: const Duration(seconds: 5),
    );
    if (!ver.success || !nodeVersionMeetsHub(ver.stdout)) {
      throw LocalHubException(
        'Node.js >= 18.17 is required (found ${ver.stdout.trim()})',
        code: 'node-old',
      );
    }

    onProgress?.call(LocalHubProgressStep.installing);
    final npm = await _resolveBinary('npm');
    if (npm == null) {
      throw LocalHubException('npm is not installed', code: 'npm-missing');
    }
    final install = await _host.run(
      npm,
      ['install', '-g', kLocalAgentHubNpmPackage],
      environment: _host.augmentedEnvironment(),
      timeout: const Duration(minutes: 5),
    );
    if (!install.success) {
      final detail = install.stderr.trim().isNotEmpty
          ? install.stderr.trim()
          : install.stdout.trim();
      final eacces = detail.contains('EACCES') || detail.contains('permission');
      throw LocalHubException(
        eacces
            ? 'npm global install needs write permission. Run in a terminal:\nnpm install -g $kLocalAgentHubNpmPackage'
            : 'npm install failed (exit ${install.exitCode}): $detail',
        code: eacces ? 'npm-eacces' : 'npm-install-failed',
      );
    }

    onProgress?.call(LocalHubProgressStep.starting);
    await ensureDashboardRunning();
    onProgress?.call(LocalHubProgressStep.pairing);
    await pairWithRunningHub();
    return detect();
  }

  Future<void> ensureDashboardRunning({
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (await _getHealth() != null) return;

    final hub = await _resolveBinary('shepaw-hub');
    if (hub == null) {
      throw LocalHubException(
        'shepaw-hub is not installed',
        code: 'hub-missing',
      );
    }
    final env = _host.augmentedEnvironment();
    await _host.run(
      hub,
      ['init'],
      environment: env,
      timeout: const Duration(seconds: 20),
    );
    await _host.startDetached(hub, ['web', '--no-open'], environment: env);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _getHealth() != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw LocalHubException(
      'Agent Hub dashboard did not become ready at $dashboardUrl',
      code: 'dashboard-timeout',
    );
  }

  Future<void> pairWithRunningHub() async {
    final health = await _getHealth();
    if (health == null) {
      throw LocalHubException(
        'Agent Hub dashboard is not running',
        code: 'dashboard-down',
      );
    }
    if (health.authRequired) {
      throw LocalHubException(
        'Dashboard requires SHEPAW_HUB_TOKEN',
        code: 'auth-required',
      );
    }

    await _postJson('/api/peer/start');
    final ticketJson = await _postJson('/api/peer/pair');
    final ticket = parsePairTicket(ticketJson);
    if (ticket == null) {
      throw LocalHubException(
        'Hub pairing response missing QR payload',
        code: 'bad-pair-response',
      );
    }
    final info = PeerPairingInfo.tryParse(ticket.qrPayload);
    if (info == null) {
      throw LocalHubException(
        'Hub pairing QR is invalid',
        code: 'bad-pair-qr',
      );
    }
    final locals = await _host.localIpv4s();
    final rewritten = info.localEndpoint == null
        ? info
        : PeerPairingInfo(
            localEndpoint: preferLoopbackIfLocal(info.localEndpoint!, locals),
            channelEndpoint: info.channelEndpoint,
            code: info.code,
            fingerprint: info.fingerprint,
            publicKey: info.publicKey,
          );
    await _pairFn(rewritten);
  }

  String? _readHubFingerprint() {
    final path = joinPathSegments(
      [hubRoot, 'peer-identity.json'],
      windows: _host.isWindows,
    );
    final raw = _host.readFile(path);
    if (raw == null) return null;
    return fingerprintFromIdentityJson(raw);
  }

  Future<String?> _resolveBinary(String name) async {
    final env = _host.augmentedEnvironment();
    final probe = _host.isWindows ? 'where' : 'which';
    final result = await _host.run(
      probe,
      [name],
      environment: env,
      timeout: const Duration(seconds: 5),
    );
    if (result.success) {
      final first = result.stdout
          .split(RegExp(r'[\r\n]+'))
          .map((s) => s.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      if (first.isNotEmpty) return first;
    }
    final suffix = _host.isWindows
        ? <String>['.cmd', '.exe', '']
        : <String>[''];
    for (final dir in _host.extraBinDirs()) {
      for (final ext in suffix) {
        final candidate = joinPathSegments([dir, '$name$ext'], windows: _host.isWindows);
        if (_host.fileExists(candidate)) return candidate;
      }
    }
    return null;
  }

  Future<_Health?> _getHealth() async {
    try {
      final resp = await _http
          .get(_dashboardUri.replace(path: '/api/health'))
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != 200) return null;
      if (!parseDashboardHealthOk(resp.body)) return null;
      return _Health(authRequired: parseDashboardAuthRequired(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<int?> _fetchInstanceCount() async {
    try {
      final resp = await _http
          .get(_dashboardUri.replace(path: '/api/instances'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return null;
      return parseInstanceCount(jsonDecode(resp.body));
    } catch (_) {
      return null;
    }
  }

  Future<Object> _postJson(String path) async {
    final resp = await _http
        .post(
          _dashboardUri.replace(path: path),
          headers: const {'content-type': 'application/json'},
          body: '{}',
        )
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode == 401) {
      throw LocalHubException(
        'Dashboard requires SHEPAW_HUB_TOKEN',
        code: 'auth-required',
      );
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LocalHubException(
        'Hub $path failed HTTP ${resp.statusCode}: ${resp.body}',
        code: 'http-${resp.statusCode}',
      );
    }
    if (resp.body.isEmpty) return const <String, dynamic>{};
    return jsonDecode(resp.body);
  }
}

class _Health {
  const _Health({required this.authRequired});
  final bool authRequired;
}
