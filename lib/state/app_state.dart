import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/scheduler.dart';

import '../data/geo.dart';
import '../data/geoip.dart';
import '../data/ip_check.dart';
import '../data/models.dart';
import '../data/native.dart';
import '../data/peers_source.dart';
import '../data/probe_service.dart';
import '../data/update_service.dart';
import '../data/web_directory.dart';
import '../data/wiki.dart';
import '../l10n/strings.dart';

/// The state of the whole app: settings, peers, the address book and the live
/// tunnel status.
///
/// Everything persistent is written straight to the shared preference store that
/// the VPN service reads, so the service keeps working (and keeps replacing dead
/// peers) while the UI is not running.
class AppState extends ChangeNotifier {
  AppState({
    PeersSource? peersSource,
    GeoIpService? geoIp,
    ProbeService? probeService,
    WikiService? wiki,
    UpdateService? updateService,
  }) : _peersSource =
           peersSource ??
           PeersSource(
             readCache: () => Native.read(_kPeerCache),
             writeCache: (value) => Native.write(_kPeerCache, value),
           ),
       _geoIp = geoIp ?? GeoIpService(),
       _probe = probeService ?? ProbeService(),
       _wiki = wiki ?? WikiService(),
       _updates = updateService ?? UpdateService();

  final PeersSource _peersSource;
  final GeoIpService _geoIp;
  final ProbeService _probe;
  final WikiService _wiki;
  final UpdateService _updates;

  // Storage keys, shared with `Prefs.kt`.
  static const String _kSettings = 'settings';
  static const String _kPeers = 'peers';
  static const String _kPool = 'pool';
  static const String _kIdentity = 'identity';
  static const String _kBook = 'book';
  static const String _kTheme = 'theme';
  static const String _kCountry = 'country';
  static const String _kOnboarded = 'onboarded';
  static const String _kPeersUpdated = 'peers_updated_at';
  static const String _kPeerSnapshot = 'peers_snapshot';
  static const String _kPeerErrors = 'peer_errors';

  /// Automatic release check and the version the user was already told about.
  static const String _kUpdateCheck = 'update_check';
  static const String _kUpdateNotified = 'update_notified';

  /// The last public peer list that came from the network, so the app still has
  /// a catalogue when GitHub is unreachable.
  static const String _kPeerCache = 'peers_cache';

  /// One-shot switch that turns the connection log off for installs that were
  /// created while logging was still on by default.
  static const String _kLogDefaultOff = 'log_default_off';

  /// Set when the user ticked "Don't show again" in the browser hint dialog.
  static const String _kBrowserHintOff = 'browser_hint_off';

  /// How many candidates get the cheap TCP pass before the protocol probes.
  static const int _probePoolSize = 160;

  /// Hosts whose exit country was already looked up in this session.
  final Set<String> _exitGeoDone = {};

  AppSettings settings = const AppSettings();
  Identity? identity;
  List<PeerEntry> _peers = const [];
  List<PeerEntry> pool = const [];

  /// The peer list the screens read. Every replacement invalidates the cached
  /// URI map, so a row never shows a status from a peer that was just removed.
  List<PeerEntry> get peers => _peers;

  set peers(List<PeerEntry> value) {
    _peers = value;
    _peerStatusVersion++;
  }

  /// The last error reported by each peer, kept after the link recovers. The
  /// running supervisor writes the same map into the shared store; the copy
  /// here lets the details dialog show it while the tunnel is down.
  Map<String, PeerErrorRecord> peerErrors = const {};

  List<Resource> resources = const [];
  VpnSnapshot snapshot = const VpnSnapshot();

  /// The byte counters, kept apart from [snapshot] on purpose. They change every
  /// second while the tunnel carries data; notifying the whole app for them
  /// rebuilt all five tabs and made the scrolling stutter.
  final ValueNotifier<TrafficCounters> traffic = ValueNotifier(
    const TrafficCounters(),
  );

  ThemeMode themeMode = ThemeMode.system;
  bool onboarded = false;

  /// The country the user picked, or the one GeoIP detected.
  String countrySlug = '';
  String detectedCity = '';
  double? detectedLat;
  double? detectedLon;

  /// Every peer of the public list, ranked by distance. The whole catalogue is
  /// kept so the browser on the Peers tab can filter it; the quick probe only
  /// looks at the first [_probePoolSize] entries.
  List<PeerCandidate> candidates = const [];
  List<ProbeResult> probeAlive = const [];

  /// Every peer that took part in the last probe, alive or not, so the catalogue
  /// can show a measured latency or a failure for each of them.
  List<ProbeResult> probeResults = const [];
  ProbeProgress? probeProgress;
  bool probing = false;

  /// The URIs the catalogue is testing right now, so their rows can show it.
  Set<String> probingUris = const {};
  bool loadingPeers = false;
  bool _probeCancelled = false;

  List<DnsPreset> dnsPresets = WikiService.defaultDnsPresets;

  /// The wiki list plus the resolver of every exit node that publishes one.
  /// Exit entries come first and win over a wiki entry with the same address,
  /// so the row says where the server came from.
  List<DnsPreset> get allDnsPresets {
    final fromExit = <String, DnsPreset>{};
    for (final profile in settings.exitProfiles) {
      if (!profile.hasDns) continue;
      fromExit.putIfAbsent(
        profile.dnsServer,
        () => DnsPreset(
          address: profile.dnsServer,
          location: profile.title,
          note: l10n.t('dnsFromExitNode'),
          fromExit: true,
        ),
      );
    }
    if (fromExit.isEmpty) return dnsPresets;
    return [
      ...fromExit.values,
      for (final preset in dnsPresets)
        if (!fromExit.containsKey(preset.address)) preset,
    ];
  }

  /// DNS health, keyed by server address, measured through the running node.
  Map<String, DnsCheck> dnsChecks = const {};
  bool checkingDns = false;

  /// Servers that were dropped after a failed check, shown until the next run.
  List<String> dnsReplaced = const [];

  /// Dead servers removed from the tunnel list by the automatic check; kept
  /// visible (and marked red) until the user adds them back or checks again.
  List<String> dnsDead = const [];

  /// Servers the user removed from the "not working" block; the automatic check
  /// will not put them back.
  final Set<String> _dnsDismissed = {};
  bool _dnsVerified = false;
  bool _dnsScheduled = false;

  /// When the tunnel first became able to carry DNS. The check waits a few
  /// seconds from this moment: the node reports "connected" before the gVisor
  /// stack and the first peer are really ready to resolve a name.
  DateTime? _dnsReadySince;

  /// Bumped whenever the tunnel drops, so a check that was waiting gives up
  /// instead of measuring a dead link.
  int _dnsGeneration = 0;
  bool _presetsRefreshed = false;

  /// The resources of the Yggdrasil web directory, loaded through the tunnel.
  List<Resource> directoryResources = const [];
  bool loadingDirectory = false;

  List<InstalledApp> installedApps = const [];
  bool loadingApps = false;

  String appVersion = '';
  String yggVersion = '';
  bool batteryExempt = false;
  bool notificationsAllowed = true;

  /// Automatic release check against the project's GitHub releases. Off by
  /// default: the check contacts GitHub, so the user opts in from Settings.
  bool updateCheckEnabled = false;

  /// The last newer release found by a check, or null when the build is up to
  /// date. The Update section keeps it after the dialog is dismissed.
  UpdateInfo? availableUpdate;

  /// True while a release check is in flight.
  bool updateCheckInFlight = false;

  /// The version the user was already notified about at startup.
  String _lastNotifiedVersion = '';

  DateTime? peersUpdatedAt;

  /// A translation key of the last failure, or null.
  String? lastError;

  /// True from the tap on Connect until the service reports a state. The
  /// permission dialog can be up for a while before the service says anything,
  /// so the UI uses this flag to show that the work has started.
  bool connecting = false;

  /// True while a disconnect is being confirmed by the service, so a second
  /// tap on the button does not start a parallel teardown.
  bool _disconnecting = false;

  /// The split-tunnelling configuration the running tunnel was started with.
  /// The Apps tab compares the settings against it to decide whether a restart
  /// is needed.
  List<String> appliedSplitApps = const [];
  bool appliedSplitEnabled = false;

  /// The exit configuration the running tunnel was started with. The Exit node
  /// screen shows a Reconnect banner while this differs from the settings.
  String appliedExitSignature = '';

  /// The last exit health read from the bridge, kept until a new snapshot with
  /// its own exit status arrives.
  ExitStatus? _exitChecked;
  bool checkingExit = false;
  // A capability check runs once per connection, after the first peer has
  // finished its handshake: the status API goes through Yggdrasil and cannot
  // answer before that.
  bool _exitCheckedOnConnect = false;

  /// True while the UDP relay self-check runs.
  bool testingUdp = false;

  /// True while the IPv6 self-check runs.
  bool testingIpv6 = false;

  /// The user asked not to see the "add the browser to the VPN" hint again.
  bool browserHintDismissed = false;

  bool _refreshingCache = false;

  /// A translation key to show once after a peer was added, or null.
  String? peerNotice;

  bool _initialised = false;
  StreamSubscription<VpnSnapshot>? _statusSub;
  Timer? _poll;
  bool _polling = false;
  String _lastSignature = '';

  /// Bumped whenever [snapshot] or [peers] changes; the URI map is rebuilt only
  /// then. Several widgets look a peer up per row, so building the map on every
  /// call made the list quadratic in the number of peers.
  int _peerStatusVersion = 0;
  Map<String, PeerStatus>? _peerStatusCache;
  int _peerStatusCacheVersion = -1;

  @override
  void notifyListeners() {
    // A timer can fire while the frame is being built or laid out. Marking an
    // element dirty in that phase does not schedule a new frame, so on a slow
    // first layout (onboarding, first connect) the UI could stay frozen on the
    // old snapshot until the user touched a tab. Defer such a notification to
    // the end of the frame, where a new frame is always scheduled.
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.transientCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.persistentCallbacks) {
      if (_notifyDeferred) return;
      _notifyDeferred = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _notifyDeferred = false;
        super.notifyListeners();
      });
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    super.notifyListeners();
  }

  bool _notifyDeferred = false;

  L10n get l10n => L10n.instance;
  bool get isConnected => snapshot.isConnected;
  bool get isBusy => snapshot.isBusy;
  bool get isRunning => !snapshot.isDisconnected;

  /// True when the node can really carry DNS queries. "Connected" only means
  /// that the VPN interface is up: an in-network resolver stays unreachable
  /// until the first peer has finished its handshake, and a check started
  /// before that marks every server dead.
  bool get dnsReady =>
      snapshot.isConnected && !snapshot.isBusy && snapshot.peersUp > 0;

  int get peersUp => snapshot.peersUp;
  String get nodeAddress => identity?.address ?? snapshot.nodeAddress;

  /// Pinned links belong to exit profiles. They are infrastructure, not peers
  /// the user picked, so they never count against [AppSettings.peerCount].
  int get pinnedPeerCount => peers.where((peer) => peer.pinned).length;

  int get publicPeerCount => peers.length - pinnedPeerCount;

  /// How many links the node keeps in total: the configured number of public
  /// peers plus the pinned exit peers.
  int get peerTarget => settings.peerCount + pinnedPeerCount;

  /// Connected public peers, for the counters on the tunnel screen.
  ({int up, int total}) get publicPeerStats {
    final statuses = statusByUri;
    var up = 0;
    var total = 0;
    for (final peer in peers) {
      if (peer.pinned) continue;
      total++;
      if (statuses[peer.uri]?.up ?? false) up++;
    }
    return (up: up, total: total);
  }

  /// True when the exit node is switched on and the tunnel carries traffic
  /// through it.
  bool get exitInUse => settings.exitActive && snapshot.isConnected;

  /// The active exit profile when it publishes a DNS resolver. The
  /// "DNS exit node" switch in the exit settings controls this one server.
  ExitProfile? get exitDnsProfile {
    final profile = settings.exitActiveProfile;
    return profile != null && profile.hasDns ? profile : null;
  }

  /// The resolver the active exit node publishes, empty when there is none.
  String get exitDnsServer => exitDnsProfile?.dnsServer ?? '';

  /// True when the resolver of the active exit node is in the tunnel list and
  /// the app actually uses that list.
  bool get exitDnsInUse =>
      settings.dnsMode != DnsMode.system &&
      exitDnsServer.isNotEmpty &&
      settings.dnsServers.contains(exitDnsServer);

  /// True when [server] is the resolver of the active exit node. Such an entry
  /// belongs to the "DNS exit node" switch, so the DNS list shows a lock
  /// instead of a remove button.
  bool isExitDnsServer(String server) =>
      exitDnsServer.isNotEmpty && server == exitDnsServer;

  /// True when [server] is published by any exit profile. The DNS list uses
  /// this to mark the row as an exit-node server, not a wiki one.
  bool isExitDnsPreset(String server) {
    for (final profile in settings.exitProfiles) {
      if (profile.hasDns && profile.dnsServer == server) return true;
    }
    return false;
  }

  /// True while the service is still bringing the link up: either the status
  /// says so, or the tunnel is up but no peer has finished its handshake yet.
  bool get establishing {
    if (connecting) return true;
    if (snapshot.isBusy) return true;
    if (!snapshot.isConnected) return false;
    if (snapshot.peersUp > 0) return false;
    final started = snapshot.connectedAt;
    if (started <= 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - started;
    return age < 30000;
  }

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    final stored = await Native.readAll();
    if (stored.containsKey(_kSettings)) {
      settings = AppSettings.fromJson(_decode(stored[_kSettings]));
    }
    // The log used to be on by default. Turn it off once for installs that were
    // created before that changed; a later manual choice is kept.
    if (stored[_kLogDefaultOff] != '1') {
      if (settings.logging) {
        settings = settings.copyWith(logging: false);
        await Native.write(_kSettings, _encode(settings.toJson()));
      }
      await Native.write(_kLogDefaultOff, '1');
    }
    final migrated = _migrateDns(settings);
    if (migrated != settings) {
      settings = migrated;
      await Native.write(_kSettings, _encode(settings.toJson()));
    }
    appliedSplitApps = [...settings.splitApps];
    appliedSplitEnabled = settings.splitEnabled;
    if (stored.containsKey(_kIdentity)) {
      identity = decodeIdentity(stored[_kIdentity] ?? '');
    }
    peers = PeerEntry.listFromJson(stored[_kPeers]);
    pool = PeerEntry.listFromJson(stored[_kPool]);
    peerErrors = PeerErrorRecord.mapFromJson(stored[_kPeerErrors]);
    resources = Resource.listFromJson(stored[_kBook]);
    themeMode = _themeFromCode(stored[_kTheme]);
    countrySlug = stored[_kCountry] ?? '';
    onboarded = stored[_kOnboarded] == '1';
    browserHintDismissed = stored[_kBrowserHintOff] == '1';
    updateCheckEnabled = stored[_kUpdateCheck] == '1';
    _lastNotifiedVersion = stored[_kUpdateNotified] ?? '';
    probeAlive = _probeFromPeers(
      PeerEntry.listFromJson(stored[_kPeerSnapshot]),
    );
    // An install that stored an exit profile before the pinned peer existed (or
    // a list that was cleared) gets its direct exit link back on start.
    await _syncExitPeers(settings.exitProfiles);
    unawaited(_resolveExitCountries());
    peersUpdatedAt = DateTime.tryParse(stored[_kPeersUpdated] ?? '');
    final book = _withCurrentBuiltins(
      resources.isEmpty ? _defaultResources : resources,
    );
    if (!_sameResources(book, resources)) {
      resources = book;
      await _persistResources();
    }

    _listenToStatus();
    _startPolling();
    notifyListeners();

    unawaited(_loadDiagnostics());
    unawaited(refreshPeerCache());
    if (identity == null) {
      unawaited(ensureIdentity());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _statusSub?.cancel();
    traffic.dispose();
    super.dispose();
  }

  /// The service pushes snapshots through an event channel, but a plain poll is
  /// kept as the source of truth: it is one small map per second and it always
  /// converges, including after the activity has been paused behind a system
  /// dialog.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollState());
  }

  Future<void> _pollState() async {
    if (_polling) return;
    _polling = true;
    try {
      final next = await Native.getState();
      if (next == null) return;
      final signature = _signatureOf(next);
      if (signature == _lastSignature) {
        // Only the byte counters moved: publish them without waking the tabs.
        _publishTraffic(next);
        return;
      }
      _applySnapshot(next);
    } catch (_) {
      // The Android side is missing (tests, desktop).
    } finally {
      _polling = false;
    }
  }

  void _publishTraffic(VpnSnapshot next) {
    traffic.value = TrafficCounters(rx: next.rxBytes, tx: next.txBytes);
  }

  /// Stores a new snapshot and, once the tunnel is really ready to carry DNS,
  /// schedules the checks that only make sense while the node is up: the DNS
  /// servers and the wiki list of them.
  void _applySnapshot(VpnSnapshot next) {
    final signature = _signatureOf(next);
    final changed = signature != _lastSignature;
    final wasConnected = snapshot.isConnected;
    snapshot = next;
    _lastSignature = signature;
    _peerStatusVersion++;
    _publishTraffic(next);
    // A stats tick that only moved the byte counters is not a state change:
    // nothing the screens show has moved, so they must not be rebuilt.
    if (!changed) return;
    // A lookup that failed before the link was up is retried here, so the exit
    // node shows its flag on the first connection instead of the next launch.
    if (!wasConnected && next.isConnected) {
      unawaited(_resolveExitCountries());
    }
    if (next.exit.updatedAt > 0) _exitChecked = null;
    // The bridge publishes a token it learned; keep it in the profile.
    _adoptExitStatus(next.exit);
    // A manual check belongs to the session it ran in: while the tunnel is
    // down or reconnecting the live snapshot is the only source of truth.
    if (!next.isConnected) {
      _exitChecked = null;
      _exitCheckedOnConnect = false;
    }
    // The status answer carries the resolver the exit publishes. Checking once
    // when the tunnel is ready lets a profile that was imported before the
    // server turned DNS on pick the resolver up without a manual check.
    if (next.isConnected &&
        dnsReady &&
        !_exitCheckedOnConnect &&
        settings.exitActive) {
      _exitCheckedOnConnect = true;
      unawaited(checkExitProfiles());
    }
    if (next.isConnected && appliedExitSignature.isEmpty) {
      appliedExitSignature = _exitSignatureOf(settings);
    }
    if (next.isDisconnected) appliedExitSignature = '';
    _rememberPeerErrors(next.peers);
    final ready = dnsReady;
    if (!ready) {
      _dnsVerified = false;
      _dnsScheduled = false;
      _dnsReadySince = null;
      _dnsGeneration++;
    } else {
      _dnsReadySince ??= DateTime.now();
      if (!_dnsVerified && !_dnsScheduled) {
        _dnsScheduled = true;
        final generation = ++_dnsGeneration;
        unawaited(_afterTunnelUp(generation));
      }
      if (!_presetsRefreshed) {
        _presetsRefreshed = true;
        unawaited(refreshDnsPresets());
      }
    }
    notifyListeners();
  }

  /// Keeps the last error of every peer in memory even after the link recovers
  /// or the tunnel goes down. The supervisor already persists the same map, but
  /// this copy is what the details dialog reads when the service has no live
  /// status for the peer.
  void _rememberPeerErrors(List<PeerStatus> peers) {
    Map<String, PeerErrorRecord>? next;
    for (final peer in peers) {
      final current = peer.lastError.isNotEmpty;
      final message = current ? peer.lastError : peer.lastErrorWas;
      if (message.isEmpty) continue;
      final at = current ? peer.lastErrorUnix : peer.lastErrorWasUnix;
      final known = peerErrors[peer.uri];
      if (known != null &&
          known.message == message &&
          known.lastSeenUnix == at) {
        continue;
      }
      next ??= {...peerErrors};
      next[peer.uri] = PeerErrorRecord(message: message, lastSeenUnix: at);
    }
    if (next != null) peerErrors = next;
  }

  /// Waits until the link has been stable for a few seconds and then checks the
  /// DNS servers, retrying while the stack is still warming up. A failed check
  /// is not remembered as "done": the next attempt runs as long as the tunnel
  /// stays up.
  Future<void> _afterTunnelUp(int generation) async {
    try {
      if (settings.dnsMode == DnsMode.system) {
        // Nothing to resolve through the node: the system resolver is used.
        _dnsVerified = true;
        return;
      }
      while (true) {
        if (generation != _dnsGeneration || !dnsReady) return;
        final since = _dnsReadySince;
        if (since == null) return;
        final age = DateTime.now().difference(since);
        if (age >= const Duration(seconds: 6)) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      for (var attempt = 0; attempt < 4; attempt++) {
        if (generation != _dnsGeneration || !dnsReady) return;
        if (await verifyDns()) {
          _dnsVerified = true;
          return;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    } finally {
      if (generation == _dnsGeneration) _dnsScheduled = false;
    }
  }

  /// Everything the screens show, except the byte counters. The counters have
  /// their own notifier, so a traffic tick does not count as a state change.
  ///
  /// `updatedAt` is left out on purpose: the bridge stamps it with the current
  /// second on every poll, so including it would wake the UI once a second
  /// while nothing has really changed.
  static String _signatureOf(VpnSnapshot value) => [
    value.status,
    value.stage,
    value.error,
    value.nodeAddress,
    value.subnet,
    value.publicKey,
    value.peersUp,
    value.peersTotal,
    value.latencyMs,
    value.connectedAt,
    value.dns,
    value.mtu,
    value.peers.length,
    value.peers.where((peer) => peer.up).length,
    // A peer can report a new error, recover or change its cost without any
    // of the numbers above moving; the details dialog still has to refresh.
    for (final peer in value.peers)
      '${peer.uri}|${peer.up}|${peer.latencyMs}|${peer.cost}|'
          '${peer.lastError}|${peer.lastErrorUnix}|'
          '${peer.lastErrorWas}|${peer.lastErrorWasUnix}',
    // The exit card shows the profile health, the load counters and the UDP
    // relay figures, so they are part of the state the screens depend on.
    value.exit.enabled,
    value.exit.state,
    value.exit.activeId,
    value.exit.fallbackDirect,
    value.exit.udp.enabled,
    value.exit.udp.state,
    value.exit.udp.profileId,
    value.exit.udp.profileName,
    value.exit.udp.datagramsIn,
    value.exit.udp.datagramsOut,
    value.exit.udp.bytesIn,
    value.exit.udp.bytesOut,
    value.exit.udp.error,
    for (final profile in value.exit.profiles)
      '${profile.id}|${profile.name}|${profile.address}|${profile.state}|'
          '${profile.latencyMs}|${profile.error}|${profile.checkedAt}|'
          '${profile.connections}|${profile.refused}|${profile.quotaRefused}|'
          '${profile.maxConns}|${profile.udpAssociations}|'
          '${profile.maxUdpAssociations}|'
          '${profile.quota?.monthlyBytes}|${profile.quota?.dailyBytes}|'
          '${profile.quota?.downKbps}|${profile.quota?.upKbps}|'
          '${profile.quota?.dayUsed}|${profile.quota?.monthUsed}|'
          '${profile.quota?.exhausted}|${profile.quota?.reason}|'
          '${profile.ipv6Available}|${profile.ipv6State}',
  ].join('|');

  void _listenToStatus() {
    try {
      _statusSub = Native.statusStream().listen(
        (next) => _applySnapshot(next),
        onError: (Object _) {
          // The poll below is the fallback.
        },
        cancelOnError: false,
      );
    } catch (_) {
      // Same as above.
    }
  }

  Future<void> _loadDiagnostics() async {
    final results = await Future.wait([
      Native.appVersion(),
      Native.yggVersion(),
      Native.isBatteryExempt(),
      Native.hasNotificationPermission(),
    ]);
    appVersion = results[0] as String;
    yggVersion = results[1] as String;
    batteryExempt = results[2] as bool;
    notificationsAllowed = results[3] as bool;
    notifyListeners();
  }

  /// Re-reads the peers the service may have replaced while the UI was away and
  /// asks it to look at the live links right away. A phone that was asleep for a
  /// while comes back with a frozen supervisor thread, so without the request
  /// the latency column stays empty until the next manual refresh.
  Future<void> refreshFromStore() async {
    final stored = await Native.readAll();
    peers = PeerEntry.listFromJson(stored[_kPeers]);
    pool = PeerEntry.listFromJson(stored[_kPool]);
    peerErrors = PeerErrorRecord.mapFromJson(stored[_kPeerErrors]);
    peersUpdatedAt =
        DateTime.tryParse(stored[_kPeersUpdated] ?? '') ?? peersUpdatedAt;
    batteryExempt = await Native.isBatteryExempt();
    if (snapshot.isConnected) {
      await Native.refreshPeers();
      // Give the supervisor a moment to read the node state, then take the
      // fresh numbers even if the pushed snapshot has not arrived yet.
      for (var attempt = 0; attempt < 2; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await _pollState();
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Identity
  // ------------------------------------------------------------------

  Future<Identity?> ensureIdentity() async {
    if (identity != null) return identity;
    final generated = await Native.generateIdentity();
    if (generated == null) return null;
    identity = generated;
    await Native.write(_kIdentity, _encode(generated.toJson()));
    notifyListeners();
    return generated;
  }

  // ------------------------------------------------------------------
  // Preferences
  // ------------------------------------------------------------------

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    await Native.write(_kTheme, _themeCode(value));
  }

  Future<void> setCountry(String slug) async {
    countrySlug = slug;
    notifyListeners();
    await Native.write(_kCountry, slug);
  }

  Future<void> saveSettings(AppSettings next) async {
    settings = next;
    notifyListeners();
    await Native.write(_kSettings, _encode(next.toJson()));
  }

  Future<void> setOnboarded() async {
    onboarded = true;
    notifyListeners();
    await Native.write(_kOnboarded, '1');
  }

  /// Remembers that the browser hint was dismissed for good.
  Future<void> dismissBrowserHint() async {
    if (browserHintDismissed) return;
    browserHintDismissed = true;
    notifyListeners();
    await Native.write(_kBrowserHintOff, '1');
  }

  /// Persists the automatic update-check preference.
  Future<void> saveUpdateCheck(bool enabled) async {
    updateCheckEnabled = enabled;
    notifyListeners();
    await Native.write(_kUpdateCheck, enabled ? '1' : '');
  }

  /// Runs a release check. Throws [UpdateCheckException] when it fails. On
  /// success [availableUpdate] holds the newer release, or null when the app is
  /// up to date.
  Future<UpdateInfo?> checkForUpdate() async {
    if (updateCheckInFlight) return availableUpdate;
    updateCheckInFlight = true;
    notifyListeners();
    try {
      if (appVersion.isEmpty) {
        appVersion = await Native.appVersion();
      }
      final update = await _updates.checkForUpdate(currentVersion: appVersion);
      availableUpdate = update;
      return update;
    } finally {
      updateCheckInFlight = false;
      notifyListeners();
    }
  }

  /// Startup check. Announces a newer release once per version, and only when
  /// the user turned the automatic check on.
  Future<UpdateInfo?> checkForUpdateOnStart() async {
    if (!updateCheckEnabled) return null;
    try {
      final update = await checkForUpdate();
      if (update == null || update.version == _lastNotifiedVersion) return null;
      return update;
    } catch (_) {
      // A failed startup check is silent: it must not interrupt the tunnel.
      // The manual "Check for updates now" reports the error instead.
      return null;
    }
  }

  /// Remembers the release the user was already shown, so the same version is
  /// not announced on every start.
  Future<void> markUpdateNotified(UpdateInfo info) async {
    _lastNotifiedVersion = info.version;
    await Native.write(_kUpdateNotified, info.version);
  }

  Future<void> refreshBattery() async {
    batteryExempt = await Native.isBatteryExempt();
    notificationsAllowed = await Native.hasNotificationPermission();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Tunnel
  // ------------------------------------------------------------------

  Future<bool> connect() async {
    if (peers.isEmpty) {
      lastError = 'errorNoPeers';
      notifyListeners();
      return false;
    }
    if (connecting) return false;
    // The Android permission dialog and the service start can take a moment;
    // from this point the UI already knows the work has begun.
    connecting = true;
    lastError = null;
    notifyListeners();
    try {
      // Android 13+ hides the foreground-service notification without the
      // runtime permission, which makes a working tunnel look dead. Ask once,
      // without blocking the connect itself.
      if (!notificationsAllowed) {
        unawaited(Native.requestNotifications());
      }
      // A discovery can still be dialling dozens of nodes on the bridge thread;
      // the tunnel comes first and the probe stops after its current round.
      if (probing) cancelProbe();
      final granted = await Native.prepare();
      if (!granted) {
        lastError = 'errorVpnPermission';
        return false;
      }
      if (identity == null) {
        await ensureIdentity();
      }
      if (identity == null) {
        lastError = 'errorIdentityMissing';
        return false;
      }
      await Native.applyPeers(peers, pool);
      if (!await Native.connect()) {
        // Android refused the service (or the command never arrived). Without
        // this the button stayed busy and nothing was ever reported.
        lastError = 'errorConnectCommand';
        return false;
      }
      appliedSplitApps = [...settings.splitApps];
      appliedSplitEnabled = settings.splitEnabled;
      appliedExitSignature = _exitSignatureOf(settings);
      // Wait for the first sign of life so the caller (and the split-tunnel
      // restart) sees a real transition instead of a still-disconnected state.
      for (var attempt = 0; attempt < 30; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        final next = await Native.getState();
        if (next == null) continue;
        if (!next.isDisconnected) {
          _applySnapshot(next);
          break;
        }
        if (next.error != null && next.error!.isNotEmpty) {
          lastError = _errorKeyFor(next.error!);
          return false;
        }
      }
      return true;
    } finally {
      connecting = false;
      notifyListeners();
      unawaited(_pollState());
    }
  }

  static String _errorKeyFor(String code) => switch (code) {
    'no_peers' => 'errorNoPeers',
    'identity_missing' => 'errorIdentityMissing',
    'node_start' => 'errorNodeStart',
    'vpn_permission' => 'errorVpnPermission',
    'vpn_taken_over' => 'errorTakenOver',
    _ => 'errorGeneric',
  };

  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;
    try {
      await Native.disconnect();
      // The service releases the node, the tunnel and the supervisor on its own
      // thread. Waiting for the "disconnected" snapshot here means the next tap
      // of the button sees the real state instead of a stale "connected".
      for (var attempt = 0; attempt < 25; attempt++) {
        final next = await Native.getState();
        if (next == null) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        _applySnapshot(next);
        if (next.isDisconnected) return;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> toggle() async {
    if (connecting || _disconnecting) return;
    if (isConnected || isBusy) {
      await disconnect();
      return;
    }
    // The UI can lag behind the service (a snapshot lost while the app was in
    // the background). Reading the live state first keeps a tap on the button
    // from restarting a tunnel that is already up instead of stopping it.
    final live = await Native.getState();
    if (live != null) _applySnapshot(live);
    final current = live ?? snapshot;
    if (current.isConnected || current.isBusy) {
      await disconnect();
    } else {
      await connect();
    }
  }

  /// Drops the tunnel and brings it up again, waiting until the service has
  /// actually released it and until the new tunnel is really connected. Used
  /// after the split-tunnelling list changes: the service reads that list only
  /// when it starts.
  Future<bool> reconnect() async {
    // A previous connect or disconnect may still be running: wait for it
    // instead of failing with a misleading message.
    for (var attempt = 0; attempt < 50 && (isBusy || connecting); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final next = await Native.getState();
      if (next != null) _applySnapshot(next);
    }
    await disconnect();
    var disconnected = false;
    for (var attempt = 0; attempt < 50; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final next = await Native.getState();
      if (next == null) continue;
      _applySnapshot(next);
      if (next.isDisconnected) {
        disconnected = true;
        break;
      }
    }
    if (!disconnected) {
      lastError = 'reconnectFailed';
      notifyListeners();
      return false;
    }
    // The service calls `stopSelf()` right after it reports "disconnected", so
    // a start command sent in that instant can be lost.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!await connect()) {
      lastError ??= 'reconnectFailed';
      notifyListeners();
      return false;
    }
    // `connect` only proves that the start command was accepted; the split
    // list is applied when the service reaches "connected".
    for (var attempt = 0; attempt < 80; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final next = await Native.getState();
      if (next == null) continue;
      _applySnapshot(next);
      if (next.isConnected && !next.isBusy) return true;
      if (next.isDisconnected && next.error != null && next.error!.isNotEmpty) {
        lastError = _errorKeyFor(next.error!);
        notifyListeners();
        return false;
      }
    }
    lastError = 'reconnectFailed';
    notifyListeners();
    return false;
  }

  Future<void> retryPeersNow() async {
    await Native.applyPeers(peers, pool);
  }

  /// Asks the service to re-read the live peer state immediately instead of
  /// waiting for the next health-check tick.
  Future<void> refreshPeers() async {
    await Native.refreshPeers();
    await _pollState();
  }

  // ------------------------------------------------------------------
  // Exit node
  // ------------------------------------------------------------------

  /// The exit state the UI should show: the measured one while the tunnel is
  /// up, otherwise a state derived from the stored configuration.
  ExitStatus get exitStatus {
    final checked = _exitChecked;
    if (checked != null) return _namedExitStatus(checked);
    if (snapshot.isConnected && snapshot.exit.updatedAt > 0) {
      return _namedExitStatus(snapshot.exit);
    }
    final activeId = settings.exitActiveProfile?.id ?? '';
    return ExitStatus(
      enabled: settings.exitActive,
      state: !settings.exitEnabled
          ? 'off'
          : settings.exitProfiles.isEmpty
          ? 'no_profile'
          : 'unknown',
      activeId: activeId,
      fallbackDirect: settings.exitFallbackDirect,
      profiles: [
        for (final profile in settings.exitProfiles)
          ExitProfileStatus(
            id: profile.id,
            name: profile.name,
            address: profile.address,
          ),
      ],
    );
  }

  /// The bridge reports the names it received with the last configuration, so a
  /// renamed profile would keep its old name until the tunnel reconnects. The
  /// stored list is the source of truth for the UI.
  ExitStatus _namedExitStatus(ExitStatus status) {
    if (settings.exitProfiles.isEmpty) return status;
    final names = {
      for (final profile in settings.exitProfiles) profile.id: profile.name,
    };
    var changed = false;
    final profiles = <ExitProfileStatus>[];
    for (final profile in status.profiles) {
      final name = names[profile.id];
      if (name != null && name.isNotEmpty && name != profile.name) {
        profiles.add(profile.copyWith(name: name));
        changed = true;
      } else {
        profiles.add(profile);
      }
    }
    // The UDP association remembers the profile it was created with, so a
    // rename would leave its own name stale even when the profile list above
    // is already correct.
    var udp = status.udp;
    final udpName = names[udp.profileId];
    if (udpName != null && udpName.isNotEmpty && udpName != udp.profileName) {
      udp = udp.copyWith(profileName: udpName);
      changed = true;
    }
    if (!changed) return status;
    return ExitStatus(
      enabled: status.enabled,
      state: status.state,
      activeId: status.activeId,
      fallbackDirect: status.fallbackDirect,
      profiles: profiles,
      udp: udp,
      updatedAt: status.updatedAt,
    );
  }

  /// The name to show for a profile reported by the bridge. The self-checks
  /// carry the name the bridge knew when the check ran; a profile renamed in
  /// the app keeps its id, so the stored list wins.
  String exitProfileName(String profileId, String fallback) {
    for (final profile in settings.exitProfiles) {
      if (profile.id == profileId && profile.name.isNotEmpty) {
        return profile.name;
      }
    }
    return fallback;
  }

  /// Moves API tokens and the DNS resolver learned by the bridge into the
  /// profiles. The bridge gets a token when an exit issues it at registration,
  /// or fetches it from `/v1/token` when a profile predates the token scheme;
  /// the status JSON carries it back here so it survives a restart and is sent
  /// on every poll. The same answer carries the resolver the exit publishes,
  /// so a profile imported before DNS was enabled starts offering the "DNS
  /// exit node" switch without a new invite.
  void _adoptExitStatus(ExitStatus? status) {
    if (status == null || status.profiles.isEmpty) return;
    var changed = false;
    final next = <ExitProfile>[];
    for (final profile in settings.exitProfiles) {
      var updated = profile;
      for (final item in status.profiles) {
        if (item.id != profile.id) continue;
        if (item.token.isNotEmpty && item.token != updated.token) {
          updated = updated.copyWith(token: item.token);
        }
        if (item.dnsKnown) {
          if (item.dnsAddress.isNotEmpty &&
              (item.dnsAddress != updated.dnsAddress ||
                  item.dnsPort != updated.dnsPort)) {
            updated = updated.copyWith(
              dnsAddress: item.dnsAddress,
              dnsPort: item.dnsPort > 0 ? item.dnsPort : 53,
            );
          } else if (item.dnsAddress.isEmpty && updated.dnsAddress.isNotEmpty) {
            // The exit sent capabilities and they say "no DNS": the old
            // resolver is gone, so the switch must not offer a dead server.
            updated = updated.copyWith(dnsAddress: '', dnsPort: 53);
          }
        }
        break;
      }
      if (!identical(updated, profile)) changed = true;
      next.add(updated);
    }
    if (!changed) return;
    unawaited(saveSettings(settings.copyWith(exitProfiles: next)));
  }

  /// True when the running tunnel was created with a different split-tunnel
  /// configuration than the one stored in the settings. Android reads the
  /// allow list only when the VPN interface is created, so a change needs a
  /// reconnect; the Apps tab shows the warning and the restart button.
  bool get splitChangesPending {
    if (appliedSplitEnabled != settings.splitEnabled) return true;
    if (!settings.splitEnabled) return false;
    final applied = appliedSplitApps.toSet();
    final wanted = settings.splitApps.toSet();
    return applied.length != wanted.length || !applied.containsAll(wanted);
  }

  bool get exitChangesPending =>
      snapshot.isConnected &&
      appliedExitSignature.isNotEmpty &&
      appliedExitSignature != _exitSignatureOf(settings);

  static String _exitSignatureOf(AppSettings value) => [
    value.exitEnabled,
    value.exitActiveId,
    value.exitFallbackDirect,
    value.exitLocalDns,
    value.exitUdp,
    ...value.exitDnsServers,
    ...value.exitLocalDnsServers,
    value.dnsMode,
    ...value.dnsServers,
    for (final profile in value.exitProfiles)
      '${profile.id}|${profile.address}|${profile.socksPort}|${profile.apiPort}',
  ].join('|');

  Future<void> setExitEnabled(bool enabled) async {
    if (enabled && settings.exitProfiles.isEmpty) {
      lastError = 'exitNoProfiles';
      notifyListeners();
      return;
    }
    if (settings.exitEnabled == enabled) return;
    await saveSettings(settings.copyWith(exitEnabled: enabled));
    if (snapshot.isConnected) await reconnect();
  }

  Future<void> setExitFallbackDirect(bool value) =>
      saveSettings(settings.copyWith(exitFallbackDirect: value));

  Future<void> setExitLocalDns(bool value) =>
      saveSettings(settings.copyWith(exitLocalDns: value));

  /// Adds or removes the resolver published by the active exit node. Turning
  /// the switch on also selects Yggdrasil DNS: the system resolver would ignore
  /// the list. The server is checked right away when the tunnel is up.
  Future<void> setExitDns(bool value) async {
    final profile = exitDnsProfile;
    if (profile == null) return;
    final server = profile.dnsServer;
    final servers = [...settings.dnsServers];
    if (value) {
      if (!servers.contains(server)) servers.add(server);
    } else {
      servers.remove(server);
    }
    final modeChanged = value && settings.dnsMode == DnsMode.system;
    await saveSettings(
      settings.copyWith(
        dnsServers: servers,
        dnsMode: modeChanged ? DnsMode.yggdrasil : settings.dnsMode,
      ),
    );
    if (modeChanged) {
      resetDnsVerification();
    } else if (value) {
      unawaited(checkDnsServer(server));
    }
  }

  /// Turns the UDP relay of the exit on or off. The bridge opens its SOCKS5
  /// association once, when the tunnel starts, so a running tunnel would keep
  /// the old mode until the next connect: the switch rebuilds it right away.
  /// Returns true when a restart was needed and the tunnel came back up.
  Future<bool> setExitUdp(bool value) async {
    if (settings.exitUdp == value) return false;
    await saveSettings(settings.copyWith(exitUdp: value));
    if (!snapshot.isConnected) return false;
    return reconnect();
  }

  Future<void> setExitDnsServers(List<String> servers) =>
      saveSettings(settings.copyWith(exitDnsServers: servers));

  Future<void> setExitLocalDnsServers(List<String> servers) =>
      saveSettings(settings.copyWith(exitLocalDnsServers: servers));

  Future<void> setExitActive(String id) async {
    if (settings.exitActiveId == id) return;
    final next = settings.exitProfiles.where((profile) => profile.id == id);
    if (next.isEmpty) return;
    // The resolver of the exit node follows the active profile: a server the
    // switch put in the list is replaced with the resolver of the new node.
    final previous = exitDnsServer;
    final servers = [...settings.dnsServers];
    if (previous.isNotEmpty && servers.contains(previous)) {
      servers.remove(previous);
      final dns = next.first.dnsServer;
      if (dns.isNotEmpty) servers.add(dns);
    }
    await saveSettings(
      settings.copyWith(exitActiveId: id, dnsServers: servers),
    );
  }

  /// The resolvers the exit profiles publish. Used to keep the tunnel list in
  /// step with the profile list.
  static Set<String> _exitDnsAddresses(Iterable<ExitProfile> profiles) => {
    for (final profile in profiles)
      if (profile.hasDns) profile.dnsServer,
  };

  Future<void> saveExitProfiles(List<ExitProfile> profiles) async {
    var activeId = settings.exitActiveId;
    if (!profiles.any((profile) => profile.id == activeId)) {
      activeId = profiles.isEmpty ? '' : profiles.first.id;
    }
    // A resolver that belonged to a profile which is gone (or no longer
    // publishes one) leaves the list with it. When the switch was on, the
    // resolver of the profile that is active now takes its place.
    final before = _exitDnsAddresses(settings.exitProfiles);
    final after = _exitDnsAddresses(profiles);
    final previous = exitDnsServer;
    final hadExitDns =
        previous.isNotEmpty && settings.dnsServers.contains(previous);
    final servers = [
      for (final server in settings.dnsServers)
        if (!before.contains(server) || after.contains(server)) server,
    ];
    if (hadExitDns) {
      final active = profiles.isEmpty
          ? null
          : profiles.firstWhere(
              (profile) => profile.id == activeId,
              orElse: () => profiles.first,
            );
      final dns = active?.dnsServer ?? '';
      if (dns.isNotEmpty && !servers.contains(dns)) servers.add(dns);
    }
    await saveSettings(
      settings.copyWith(
        exitProfiles: profiles,
        exitActiveId: activeId,
        exitEnabled: exitEnabledAfter(
          settings.exitProfiles,
          profiles,
          settings.exitEnabled,
        ),
        dnsServers: servers,
      ),
    );
    await _syncExitPeers(profiles);
    unawaited(_resolveExitCountries());
  }

  /// Whether the exit switch is on after the profile list changed. Adding the
  /// first node turns it on: that is the moment the user asked for public
  /// traffic to go through an exit. Removing the last node turns it off, since
  /// there is nothing left to route through. In every other case the user's
  /// own choice of the switch stands.
  static bool exitEnabledAfter(
    List<ExitProfile> before,
    List<ExitProfile> after,
    bool current,
  ) {
    if (after.isEmpty) return false;
    return before.isEmpty || current;
  }

  /// Keeps the peer list in step with the exit profiles. Every profile that
  /// carries a peering URI gets one pinned peer: the tunnel then reaches the
  /// exit node directly instead of hoping that the public mesh has a route to
  /// it. The pinned entry is never removed by the supervisor or by "Clear".
  Future<void> _syncExitPeers(List<ExitProfile> profiles) async {
    final wanted = <String>{};
    for (final profile in profiles) {
      final uri = profile.peer.trim();
      if (uri.isNotEmpty) wanted.add(uri);
    }
    final wantedHosts = {for (final uri in wanted) _hostOf(uri)};

    final seen = <String>{};
    final pinned = <PeerEntry>[];
    final others = <PeerEntry>[];
    for (final peer in peers) {
      if (peer.pinned) {
        if (wanted.contains(peer.uri) && seen.add(peer.uri)) {
          pinned.add(peer);
        }
      } else {
        others.add(peer);
      }
    }
    for (final profile in profiles) {
      final uri = profile.peer.trim();
      if (uri.isEmpty || !seen.add(uri)) continue;
      final entry = PeerEntry(uri: uri, pinned: true);
      // A manually added copy of the same server is replaced, so the pinned
      // URI (with the key of the exit node) is the one that gets dialled.
      final index = others.indexWhere(
        (peer) => _hostOf(peer.uri) == _hostOf(uri),
      );
      if (index >= 0) others.removeAt(index);
      pinned.add(entry);
    }
    // The pinned exit peers come first: the node dials the direct link before
    // the public pool, and the list shows it at the top.
    final next = [...pinned, ...others];

    var same = next.length == peers.length;
    if (same) {
      for (var i = 0; i < next.length; i++) {
        if (next[i].uri != peers[i].uri || next[i].pinned != peers[i].pinned) {
          same = false;
          break;
        }
      }
    }
    if (same) return;

    peers = next;
    pool = [
      for (final peer in pool)
        if (!wantedHosts.contains(_hostOf(peer.uri))) peer,
    ];
    await _persistPeers();
  }

  /// Fills in the country of the pinned exit peers.
  ///
  /// The public catalogue carries the country of every peer it lists, but the
  /// exit node is not in that list: its address comes from the invite. The
  /// lookup asks a GeoIP service about the server address itself, so the flag
  /// in the peer list shows where the exit server is.
  Future<void> _resolveExitCountries() async {
    final pending = [
      for (final peer in peers)
        if (peer.pinned &&
            peer.country.isEmpty &&
            !_exitGeoDone.contains(_hostOf(peer.uri)))
          peer,
    ];
    if (pending.isEmpty) return;
    var changed = false;
    for (final peer in pending) {
      final host = _hostOf(peer.uri);
      if (host.isEmpty) continue;
      // A Yggdrasil address has no country of its own: the GeoIP services
      // cannot place it, and the peer link always carries the real transport
      // address.
      if (host.contains(':')) continue;
      final geo = await _geoIp.lookupAddress(host);
      if (geo == null || geo.countrySlug.isEmpty) continue;
      // Only a success is remembered: an exit node added while the network was
      // down gets another try instead of a blank flag for the whole session.
      _exitGeoDone.add(host);
      peers = [
        for (final item in peers)
          if (item.uri == peer.uri)
            item.copyWith(country: geo.countrySlug, city: geo.city)
          else
            item,
      ];
      changed = true;
    }
    if (!changed) return;
    notifyListeners();
    await _persistPeers();
  }

  Future<void> addExitProfile(ExitProfile profile) async {
    final next = [...settings.exitProfiles];
    final index = next.indexWhere(
      (item) =>
          item.id == profile.id ||
          (item.address == profile.address &&
              item.socksPort == profile.socksPort),
    );
    if (index >= 0) {
      final previous = next[index];
      // A link or a QR code carries the invite, not the API token the exit
      // issued to this node: importing the same server again must not throw
      // the token away, or the bridge would have to ask for a new one.
      next[index] = previous.token.isNotEmpty && profile.token.isEmpty
          ? profile.copyWith(token: previous.token)
          : profile;
    } else {
      next.add(profile);
    }
    await saveExitProfiles(next);
  }

  Future<void> updateExitProfile(ExitProfile profile) async {
    final next = [
      for (final item in settings.exitProfiles)
        if (item.id == profile.id) profile else item,
    ];
    await saveExitProfiles(next);
  }

  Future<void> removeExitProfile(String id) async {
    final next = [
      for (final profile in settings.exitProfiles)
        if (profile.id != id) profile,
    ];
    await saveExitProfiles(next);
  }

  Future<void> reorderExitProfiles(int oldIndex, int newIndex) async {
    final list = [...settings.exitProfiles];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final target = newIndex.clamp(0, list.length - 1);
    if (target == oldIndex) return;
    final item = list.removeAt(oldIndex);
    list.insert(target, item);
    await saveExitProfiles(list);
  }

  /// Rebuilds the forwarder with the stored exit configuration. Needed before a
  /// registration: the running bridge only knows the profiles from the last
  /// connect.
  Future<void> applyExitConfig() async {
    if (!snapshot.isConnected) return;
    await Native.applyExitConfig();
  }

  /// Redeems an invite on [profile]. The profile is stored first so the bridge
  /// can find it, then the request goes through the live tunnel.
  Future<ExitRegistration> registerExit(
    ExitProfile profile,
    String invite,
  ) async {
    final token = invite.trim();
    if (token.isEmpty) {
      return const ExitRegistration(error: 'invite_missing');
    }
    await addExitProfile(profile.copyWith(invite: token));
    if (!snapshot.isConnected) {
      return const ExitRegistration(error: 'vpn_not_running');
    }
    await applyExitConfig();
    final result =
        await Native.registerExit(profileId: profile.id, invite: token) ??
        const ExitRegistration(error: 'native_error');
    if (result.ok) {
      final dns = result.dnsAddress;
      if (result.token.isNotEmpty ||
          (dns.isNotEmpty && dns != profile.dnsAddress)) {
        await updateExitProfile(
          profile.copyWith(
            invite: token,
            token: result.token.isNotEmpty ? result.token : null,
            dnsAddress: dns.isNotEmpty ? dns : null,
            dnsPort: result.dnsPort > 0 ? result.dnsPort : null,
          ),
        );
      }
      _exitChecked = await Native.exitStatus();
    }
    notifyListeners();
    return result;
  }

  Future<ExitStatus?> refreshExitStatus() async {
    if (!snapshot.isConnected) return null;
    final status = await Native.exitStatus();
    if (status != null) {
      _adoptExitStatus(status);
      _exitChecked = status;
      notifyListeners();
    }
    return status;
  }

  Future<ExitStatus?> checkExitProfiles() async {
    if (checkingExit || !snapshot.isConnected) return null;
    checkingExit = true;
    notifyListeners();
    try {
      final status = await Native.checkExitProfiles(
        timeoutMs: settings.exitProfiles.length * 6000 + 4000,
      );
      if (status != null) {
        _adoptExitStatus(status);
        _exitChecked = status;
      }
      return status;
    } finally {
      checkingExit = false;
      notifyListeners();
    }
  }

  /// Runs the UDP relay self-check of the active exit: a DNS query through the
  /// exit and a real QUIC handshake. Returns null when the tunnel is down.
  Future<UdpProbeResult?> testExitUdp() async {
    if (testingUdp || !snapshot.isConnected) return null;
    testingUdp = true;
    notifyListeners();
    try {
      final result = await Native.testExitUdp();
      if (result != null) {
        // The check opens a real association, so the counters moved: refresh
        // the card so the numbers match what the user just saw.
        _exitChecked = await Native.exitStatus() ?? _exitChecked;
      }
      return result;
    } finally {
      testingUdp = false;
      notifyListeners();
    }
  }

  /// Runs the IPv6 self-check of the active exit: an HTTPS request to a
  /// literal IPv6 address and an AAAA query over the UDP relay. Returns null
  /// when the tunnel is down.
  Future<Ipv6ProbeResult?> testExitIpv6() async {
    if (testingIpv6 || !snapshot.isConnected) return null;
    testingIpv6 = true;
    notifyListeners();
    try {
      final result = await Native.testExitIpv6();
      if (result != null) {
        // The check opens real connections, so the exit counters moved:
        // refresh the card so the numbers match what the user just saw.
        _exitChecked = await Native.exitStatus() ?? _exitChecked;
      }
      return result;
    } finally {
      testingIpv6 = false;
      notifyListeners();
    }
  }

  /// The address a remote service sees for this device: on the real network or
  /// through the exit node. A failure is a code in [PublicIpResult.error], so
  /// the balloon can explain what went wrong instead of showing nothing.
  Future<PublicIpResult> publicIp({required bool viaExit}) async {
    if (!viaExit) return fetchDirectIp();
    final result = await Native.exitPublicIp();
    return result ?? const PublicIpResult(via: 'exit', error: 'failed');
  }

  // ------------------------------------------------------------------
  // Peers
  // ------------------------------------------------------------------

  Future<void> _persistPeers() async {
    await Native.write(_kPeers, PeerEntry.listToJson(peers));
    await Native.write(_kPool, PeerEntry.listToJson(pool));
    await Native.applyPeers(peers, pool);
    notifyListeners();
  }

  Future<void> _persistProbe() async {
    await Native.write(
      _kPeerSnapshot,
      PeerEntry.listToJson([for (final result in probeAlive) result.toPeer()]),
    );
    if (peersUpdatedAt != null) {
      await Native.write(_kPeersUpdated, peersUpdatedAt!.toIso8601String());
    }
  }

  /// Downloads (or takes the bundled copy of) the public peer list, ranks it by
  /// distance and measures the real Yggdrasil latency in small batches.
  Future<void> probePeers({bool allowDownload = true}) async {
    if (probing) return;
    probing = true;
    _probeCancelled = false;
    lastError = null;
    probeProgress = const ProbeProgress(
      phase: 'preparing',
      tested: 0,
      total: 0,
      alive: 0,
    );
    notifyListeners();

    try {
      final geo = await _geoIp.lookup();
      if (geo != null) {
        detectedCity = geo.city;
        detectedLat = geo.lat;
        detectedLon = geo.lon;
        if (countrySlug.isEmpty && geo.countrySlug.isNotEmpty) {
          countrySlug = geo.countrySlug;
          await Native.write(_kCountry, countrySlug);
        }
      }

      probeProgress = ProbeProgress(
        phase: 'downloading',
        tested: 0,
        total: 0,
        alive: 0,
      );
      notifyListeners();

      final loaded = await _peersSource.load(allowDownload: allowDownload);
      if (loaded.peers.isEmpty) {
        lastError = 'probeNothing';
        return;
      }

      final ranked = PeersSource.rankByDistance(
        loaded.peers,
        lat: detectedLat,
        lon: detectedLon,
        countrySlug: countrySlug,
      );
      // The whole catalogue is kept: the peer browser on the Peers tab filters
      // it. The protocol probe still only walks the most promising part.
      candidates = ranked;
      final probePool = ranked.length > _probePoolSize
          ? ranked.sublist(0, _probePoolSize)
          : ranked;

      final target = (settings.peerCount * 3).clamp(6, 15);
      final session = await _probe.run(
        probePool,
        batch: settings.probeBatch,
        timeoutMs: settings.probeTimeoutMs,
        targetAlive: target,
        onProgress: (progress) {
          probeProgress = progress;
          notifyListeners();
        },
        isCancelled: () => _probeCancelled,
      );

      probeAlive = session.alive;
      probeResults = [...session.alive, ...session.dead];
      peersUpdatedAt = DateTime.now();
      await _persistProbe();

      // A probe is also the only way to refill the replacement pool, so the
      // spares are stored right away: otherwise the supervisor would drain the
      // pool and the user would have no way to top it up again.
      if (!_probeCancelled) {
        final activeUris = {for (final peer in peers) peer.uri};
        final activeHosts = {for (final peer in peers) _hostOf(peer.uri)};
        final spare = [
          for (final result in probeAlive)
            if (!activeUris.contains(result.uri) &&
                !activeHosts.contains(_hostOf(result.uri)))
              result.toPeer(),
        ];
        if (spare.isNotEmpty) {
          pool = spare;
          await _persistPeers();
        }
      }
    } catch (error) {
      lastError = 'errorGeneric';
    } finally {
      probing = false;
      probeProgress = null;
      notifyListeners();
    }
  }

  void cancelProbe() {
    _probeCancelled = true;
  }

  /// Downloads (or takes the bundled copy of) the public peer list and ranks it,
  /// without running the protocol probe. Used by the catalogue browser, which
  /// tests only the peers the user actually looks at.
  Future<void> loadCandidates({bool allowDownload = true}) async {
    if (loadingPeers) return;
    loadingPeers = true;
    notifyListeners();
    try {
      final loaded = await _peersSource.load(
        allowDownload: allowDownload,
        allTransports: true,
      );
      if (loaded.peers.isEmpty) {
        lastError = 'probeNothing';
        return;
      }
      candidates = PeersSource.rankByDistance(
        loaded.peers,
        lat: detectedLat,
        lon: detectedLon,
        countrySlug: countrySlug,
      );
    } catch (_) {
      lastError = 'errorGeneric';
    } finally {
      loadingPeers = false;
      notifyListeners();
    }
  }

  /// The message to show after a peer was added, or null. The notice is cleared
  /// as it is taken so it is shown once.
  String? takePeerNotice() {
    final key = peerNotice;
    peerNotice = null;
    if (key == null) return null;
    if (key == 'peerCountRaised') {
      return l10n.tf(key, [settings.peerCount]);
    }
    return l10n.t(key);
  }

  /// Measures the Yggdrasil latency of an explicit list of peers, used by the
  /// catalogue browser. Results are merged into [probeResults] so the rows keep
  /// their latency when the filters change.
  Future<void> probeUris(List<String> uris) async {
    if (uris.isEmpty || probing) return;
    probing = true;
    probingUris = uris.toSet();
    _probeCancelled = false;
    probeProgress = ProbeProgress(
      phase: 'ygg',
      tested: 0,
      total: uris.length,
      alive: 0,
    );
    notifyListeners();
    final merged = <String, ProbeResult>{
      for (final result in probeResults) result.uri: result,
    };
    try {
      var tested = 0;
      var alive = 0;
      for (var start = 0; start < uris.length; start += settings.probeBatch) {
        if (_probeCancelled) break;
        final slice = uris.skip(start).take(settings.probeBatch).toList();
        final results = await Native.probe(
          slice,
          timeoutMs: settings.probeTimeoutMs,
        );
        final byUri = {for (final result in results) result.uri: result};
        for (final uri in slice) {
          final result = byUri[uri] ?? ProbeResult(uri: uri, up: false);
          merged[uri] = result;
          if (result.up) alive++;
          tested++;
        }
        probeProgress = ProbeProgress(
          phase: 'ygg',
          tested: tested,
          total: uris.length,
          alive: alive,
        );
        notifyListeners();
      }
      probeResults = merged.values.toList();
    } finally {
      probing = false;
      probingUris = const {};
      probeProgress = null;
      notifyListeners();
    }
  }

  /// Fills the active list up to [count] peers with the fastest probed ones and
  /// puts the rest into the replacement pool.
  Future<int> addBestPeers({int? count}) async {
    final active = [...peers];
    // The target counts public peers only: the pinned exit links are always
    // there on top of the configured number.
    var target = (count ?? settings.peerCount) + pinnedPeerCount;
    final activeUris = {for (final peer in active) peer.uri};
    final activeHosts = {for (final peer in active) _hostOf(peer.uri)};
    for (final result in probeAlive) {
      if (active.length >= target) break;
      if (activeUris.contains(result.uri)) continue;
      if (!activeHosts.add(_hostOf(result.uri))) continue;
      active.add(result.toPeer());
      activeUris.add(result.uri);
    }
    final unchanged = active.length == peers.length;

    peers = active;
    pool = [
      for (final result in probeAlive)
        if (!activeUris.contains(result.uri) &&
            !activeHosts.contains(_hostOf(result.uri)))
          result.toPeer(),
    ];
    // The lists are already visible in memory: tell the UI before the store
    // round-trip, so the card fills in as soon as the probe is done.
    notifyListeners();
    if (publicPeerCount > settings.peerCount) {
      settings = settings.copyWith(peerCount: publicPeerCount);
      await Native.write(_kSettings, _encode(settings.toJson()));
      peerNotice = 'peerCountRaised';
    }
    await _persistPeers();
    return unchanged ? 0 : publicPeerCount;
  }

  /// Makes the active list the best one the last probe found without growing it.
  ///
  /// The tunnel keeps [AppSettings.peerCount] links, so the button on the
  /// Results card replaces the slowest of them instead of appending new ones:
  /// a candidate only takes the place of a peer that is measurably worse.
  /// Returns how many links changed.
  Future<int> applyBestPeers() async {
    // The setting describes public peers; the pinned exit links are extra.
    final target = settings.peerCount.clamp(1, 50) + pinnedPeerCount;
    final active = [...peers];
    final dropped = <String>{};

    // What the node reports now is the best measure; the value from the last
    // probe is the fallback, and a link with no numbers at all is the worst.
    // A pinned exit peer is never the worst link: it is not a candidate.
    double qualityOf(PeerEntry peer) {
      if (peer.pinned) return double.negativeInfinity;
      final status = statusByUri[peer.uri];
      if (status != null) {
        if (!status.up) return double.infinity;
        if (status.latencyMs > 0) return status.latencyMs;
      }
      if (peer.latencyMs > 0) return peer.latencyMs;
      return double.infinity;
    }

    final ranked = [
      for (final result in probeAlive)
        if (result.latencyMs > 0) result,
    ]..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));

    var usedUris = {for (final peer in active) peer.uri};
    var usedHosts = {for (final peer in active) _hostOf(peer.uri)};
    var changes = 0;

    for (final candidate in ranked) {
      if (usedUris.contains(candidate.uri)) continue;
      if (usedHosts.contains(_hostOf(candidate.uri))) continue;

      // Below the configured size the list is simply filled up.
      if (active.length < target) {
        active.add(candidate.toPeer());
        usedUris.add(candidate.uri);
        usedHosts.add(_hostOf(candidate.uri));
        changes++;
        continue;
      }

      // The slowest link, and only when it is really worse than the candidate.
      var worstIndex = -1;
      var worstQuality = 0.0;
      for (var i = 0; i < active.length; i++) {
        if (active[i].pinned) continue;
        final quality = qualityOf(active[i]);
        if (quality <= candidate.latencyMs) continue;
        if (worstIndex < 0 || quality > worstQuality) {
          worstIndex = i;
          worstQuality = quality;
        }
      }
      if (worstIndex < 0) continue;

      final previous = active[worstIndex];
      usedUris.remove(previous.uri);
      usedHosts.remove(_hostOf(previous.uri));
      active[worstIndex] = candidate.toPeer();
      usedUris.add(candidate.uri);
      usedHosts.add(_hostOf(candidate.uri));
      dropped.add(previous.uri);
      changes++;
    }

    // More links than the setting asks for: keep the pinned exit peers and the
    // fastest of the rest.
    if (active.length > target) {
      final keptUris = {
        for (final peer in active)
          if (peer.pinned) peer.uri,
      };
      final rest = [
        for (final peer in active)
          if (!peer.pinned) peer,
      ]..sort((a, b) => qualityOf(a).compareTo(qualityOf(b)));
      for (final peer in rest) {
        if (keptUris.length >= target) break;
        keptUris.add(peer.uri);
      }
      final kept = [
        for (final peer in active)
          if (keptUris.contains(peer.uri)) peer,
      ];
      for (final peer in active) {
        if (!keptUris.contains(peer.uri)) dropped.add(peer.uri);
      }
      changes += active.length - kept.length;
      active
        ..clear()
        ..addAll(kept);
      usedUris = keptUris;
    }

    peers = active;
    pool = [
      for (final result in ranked)
        if (!usedUris.contains(result.uri) && !dropped.contains(result.uri))
          result.toPeer(),
    ];
    // The list is already visible in memory: show it before the store round-trip.
    notifyListeners();
    await _persistPeers();
    return changes;
  }

  /// Runs the discovery and adds the best nodes to the tunnel in one go. Used
  /// by the empty Active peers card on the Tunnel tab, so the user does not
  /// have to switch to Peers and press a second button there.
  Future<bool> findAndAddPeers() async {
    if (probing) return false;
    lastError = null;
    await probePeers();
    if (_probeCancelled) return false;
    if (probeAlive.isEmpty) {
      lastError ??= 'probeNothing';
      notifyListeners();
      return false;
    }
    await addBestPeers();
    return peers.isNotEmpty;
  }

  /// Downloads the public peer list in the background so the offline copy is
  /// up to date whenever the source is reachable, and fills the catalogue when
  /// nothing has been loaded in this session yet.
  Future<void> refreshPeerCache() async {
    if (_refreshingCache) return;
    _refreshingCache = true;
    try {
      final fresh = await _peersSource.download();
      if (fresh == null || fresh.isEmpty) return;
      if (candidates.isEmpty) {
        candidates = PeersSource.rankByDistance(
          PeersSource.onePerHost(fresh),
          lat: detectedLat,
          lon: detectedLon,
          countrySlug: countrySlug,
        );
        notifyListeners();
      }
    } catch (_) {
      // Offline: the stored copy stays in place.
    } finally {
      _refreshingCache = false;
    }
  }

  Future<String?> addPeer(String rawUri) async {
    final uri = rawUri.trim();
    if (!isValidPeerUri(uri)) return 'invalidUri';
    if (peers.any((peer) => peer.uri == uri)) return 'peerAlreadyExists';
    if (pool.any((peer) => peer.uri == uri)) return 'peerAlreadyExists';
    // The same server over another transport is the same connection: keep one.
    if (peers.any((peer) => _hostOf(peer.uri) == _hostOf(uri))) {
      return 'peerAlreadyExists';
    }

    PeerCandidate? match;
    for (final candidate in candidates) {
      if (candidate.uri == uri) {
        match = candidate;
        break;
      }
    }
    peers = [
      ...peers,
      PeerEntry(
        uri: uri,
        country: match?.country ?? '',
        city: match?.city ?? '',
      ),
    ];
    peerNotice = 'peerAdded';
    // Adding a peer beyond the configured size is allowed: the tunnel grows with
    // the list instead of silently ignoring the new node. The pinned exit links
    // do not count, so only a longer public list raises the setting.
    if (publicPeerCount > settings.peerCount) {
      settings = settings.copyWith(peerCount: publicPeerCount);
      await Native.write(_kSettings, _encode(settings.toJson()));
      peerNotice = 'peerCountRaised';
    }
    await _persistPeers();
    return null;
  }

  static String _hostOf(String uri) {
    final parsed = Uri.tryParse(uri);
    return (parsed?.host ?? uri).toLowerCase();
  }

  /// The node reports a configured peer without its query string: yggdrasil
  /// drops `?key=...` from the link info it keeps for the live status. Matching
  /// on scheme, host, port and path keeps a pinned exit peer connected in the UI.
  static String _peerKey(String uri) => peerKeyOf(uri);

  Future<void> removePeer(String uri) async {
    // A pinned peer belongs to an exit profile. It goes away with the profile,
    // not with a tap in the peer list.
    if (peers.any((peer) => peer.uri == uri && peer.pinned)) return;
    peers = [
      for (final peer in peers)
        if (peer.uri != uri) peer,
    ];
    _topUpFromPool();
    await _persistPeers();
  }

  Future<void> clearPeers() async {
    // Clearing the list keeps the exit nodes: they are infrastructure, not
    // candidates the user picked from the public list.
    peers = [
      for (final peer in peers)
        if (peer.pinned) peer,
    ];
    pool = const [];
    await _persistPeers();
  }

  void _topUpFromPool() {
    if (!settings.autoReplace) return;
    if (publicPeerCount >= settings.peerCount) return;
    final next = [...peers];
    final usedHosts = {for (final peer in next) _hostOf(peer.uri)};
    final remaining = <PeerEntry>[];
    var public = publicPeerCount;
    for (final candidate in pool) {
      if (public < settings.peerCount &&
          usedHosts.add(_hostOf(candidate.uri))) {
        next.add(candidate);
        public++;
      } else {
        remaining.add(candidate);
      }
    }
    peers = next;
    pool = remaining;
  }

  /// Peer statuses from the running service, keyed by URI. Both the exact URI
  /// and its query-free form are present, because the bridge reports a live
  /// peer without the `?key=...` the profile was configured with.
  ///
  /// The map is cached until the snapshot or the peer list changes: every peer
  /// row asks for its own status, and rebuilding the whole map per row made the
  /// list quadratic.
  Map<String, PeerStatus> get statusByUri {
    final cached = _peerStatusCache;
    if (cached != null && _peerStatusCacheVersion == _peerStatusVersion) {
      return cached;
    }
    final out = <String, PeerStatus>{};
    for (final status in snapshot.peers) {
      out[status.uri] = status;
      out.putIfAbsent(_peerKey(status.uri), () => status);
    }
    for (final peer in peers) {
      final status = out[_peerKey(peer.uri)];
      if (status != null) out[peer.uri] = status;
    }
    _peerStatusCache = out;
    _peerStatusCacheVersion = _peerStatusVersion;
    return out;
  }

  /// The last error the supervisor recorded for [uri], if any. The supervisor
  /// stores it under the query-free form of the URI, so a pinned exit peer is
  /// looked up both ways.
  PeerErrorRecord? peerErrorFor(String uri) =>
      peerErrors[uri] ?? peerErrors[_peerKey(uri)];

  // ------------------------------------------------------------------
  // Address book
  // ------------------------------------------------------------------

  static const List<Resource> _defaultResources = [
    Resource(
      id: 'builtin:directory',
      title: 'Yggdrasil Web directory',
      url: 'http://[21e:a51c:885b:7db0:166e:927:98cd:d186]/',
      description: 'A catalogue of sites published inside Yggdrasil',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:howto',
      title: 'HowTo Ygg',
      url: 'http://[222:a8e4:50cd:55c:788e:b0a5:4e2f:a92c]/',
      description: 'Guides, articles and cheatsheets (Yggdrasil wiki)',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:forum',
      title: 'Forum in Yggdrasil',
      url: 'http://[21a:34aa:c782:3ad2:1bf8:73f8:141:66e8]/',
      description: 'A forum in Yggdrasil, about Yggdrasil',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:librespeed',
      title: 'LibreSpeed instance',
      url: 'http://[300:ffb4:8643:34d8::f1fa:1]/',
      description: 'Measure the throughput of your Yggdrasil link',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:peers',
      title: 'Public peers',
      url: 'http://[200:2688:699a:ce30:5897:cd3d:f999:8782]/',
      description: 'The public peer list, served inside the network',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:search',
      title: 'Search engine for Yggdrasil',
      url: 'http://[200:b48d:469e:c7c7:3e13:c41d:ba4d:d2b8]/',
      description: 'A search engine that indexes Yggdrasil sites',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:ipcheck',
      title: 'IP and Port Checker',
      url: 'http://[200:56bd:a9e9:c1fa:8f99:1d3c:3c84:6507]/',
      description: 'Check the address and ports your peer sees',
      builtIn: true,
    ),
    Resource(
      id: 'builtin:myip',
      title: 'Show my IP address',
      url: 'http://[320:9c1:e1fa:a105::ad]/',
      description: 'Shows the Yggdrasil address you are using',
      builtIn: true,
    ),
  ];

  /// The address of the web directory the cloud button reads.
  static const String directoryUrl =
      'http://[21e:a51c:885b:7db0:166e:927:98cd:d186]/';

  /// Refreshes the built-in entries without touching the order the user gave
  /// them: a default keeps its place, a default from a newer build goes on top,
  /// and a built-in the user deleted comes back (they are defaults, not data).
  static List<Resource> _withCurrentBuiltins(List<Resource> current) {
    final defaults = {for (final item in _defaultResources) item.id: item};
    final present = <String>{};
    final ordered = <Resource>[];
    for (final item in current) {
      if (!item.builtIn) {
        ordered.add(item);
        continue;
      }
      final fresh = defaults[item.id];
      if (fresh == null) continue;
      present.add(item.id);
      ordered.add(fresh);
    }
    final missing = [
      for (final item in _defaultResources)
        if (!present.contains(item.id)) item,
    ];
    return [...missing, ...ordered];
  }

  static bool _sameResources(List<Resource> a, List<Resource> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].url != b[i].url) return false;
    }
    return true;
  }

  Future<void> _persistResources() =>
      Native.write(_kBook, Resource.listToJson(resources));

  Future<void> addResource(Resource resource) async {
    resources = [...resources, resource];
    notifyListeners();
    await _persistResources();
  }

  Future<void> updateResource(Resource resource) async {
    resources = [
      for (final item in resources)
        if (item.id == resource.id) resource else item,
    ];
    notifyListeners();
    await _persistResources();
  }

  Future<void> deleteResource(String id) async {
    resources = [
      for (final item in resources)
        if (item.id != id) item,
    ];
    notifyListeners();
    await _persistResources();
  }

  /// Moves a resource to a new place in the book. The index follows the
  /// `ReorderableListView.onReorderItem` convention: [newIndex] is the slot in
  /// the list after the moved item has been taken out.
  Future<void> reorderResources(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= resources.length) return;
    final target = newIndex.clamp(0, resources.length - 1);
    if (target == oldIndex) return;
    final next = [...resources];
    final item = next.removeAt(oldIndex);
    next.insert(target, item);
    resources = next;
    await _persistResources();
    notifyListeners();
  }

  Future<int> deleteResources(Iterable<String> ids) async {
    final doomed = ids.toSet();
    if (doomed.isEmpty) return 0;
    final before = resources.length;
    resources = [
      for (final item in resources)
        if (!doomed.contains(item.id)) item,
    ];
    await _persistResources();
    notifyListeners();
    return before - resources.length;
  }

  /// Reads the web directory through the running node. The app process sits
  /// outside the VPN, so the page is fetched by the node itself; without a
  /// tunnel there is nothing to read.
  Future<void> loadDirectory() async {
    if (loadingDirectory) return;
    loadingDirectory = true;
    lastError = null;
    notifyListeners();
    try {
      final fetched = await Native.fetchUrl(directoryUrl);
      if (!fetched.ok) {
        lastError = 'directoryFailed';
        return;
      }
      final known = {for (final item in resources) item.url};
      directoryResources = [
        for (final item in WebDirectory.parse(
          fetched.body,
          baseUrl: directoryUrl,
        ))
          if (!known.contains(item.url)) item,
      ];
      if (directoryResources.isEmpty) lastError = 'directoryEmpty';
    } finally {
      loadingDirectory = false;
      notifyListeners();
    }
  }

  /// How long to wait before checking a failed DNS server again. A resolver can
  /// be slow or briefly unreachable while the link is settling, so one missed
  /// answer is not enough to declare it dead.
  static const List<Duration> _dnsRetryDelays = [
    Duration(seconds: 5),
    Duration(seconds: 15),
  ];

  /// Resolves a real in-network name through every configured DNS server. A
  /// server that fails is checked again after 5 and then 15 seconds; only after
  /// all three attempts fail is it dropped from the list. When none is left,
  /// unused servers from the wiki take its place. `Check now` calls the same
  /// routine but keeps the list as it is.
  ///
  /// Returns true when the node actually answered for the list (even if every
  /// server failed): an empty result means the stack was not ready yet, and the
  /// caller may try again.
  Future<bool> verifyDns({bool replaceDead = true}) async {
    if (checkingDns) return false;
    final servers = settings.effectiveDns;
    if (servers.isEmpty || !dnsReady) return false;
    final generation = _dnsGeneration;
    checkingDns = true;
    dnsReplaced = const [];
    notifyListeners();
    try {
      final results = await _checkDnsWithRetries(
        servers,
        generation,
        onSettled: (checks) {
          dnsChecks = {
            ...dnsChecks,
            for (final check in checks) check.server: check,
          };
          final recovered = {
            for (final check in checks)
              if (check.ok) check.server,
          };
          if (recovered.isNotEmpty) {
            dnsDead = [
              for (final server in dnsDead)
                if (!recovered.contains(server)) server,
            ];
          }
          notifyListeners();
        },
      );
      // The tunnel can drop while the queries are in flight: a failure then
      // says nothing about the servers, so the results are thrown away instead
      // of marking every server dead.
      if (results == null) return false;
      dnsChecks = {
        ...dnsChecks,
        for (final check in results) check.server: check,
      };
      final dead = [
        for (final check in results)
          if (!check.ok) check.server,
      ];
      dnsDead = dead;
      if (dead.isEmpty) return true;
      if (!replaceDead) return true;
      // The resolver of the active exit node belongs to its switch: a failed
      // check marks it red but does not drop it, or the switch would turn
      // itself off behind the user's back.
      final pinned = exitDnsServer;
      var next = [
        for (final server in settings.dnsServers)
          if (!dead.contains(server) || server == pinned) server,
      ];
      if (next.isEmpty) {
        final used = {...settings.dnsServers, ...dead};
        next = [
          for (final preset in allDnsPresets)
            if (!preset.deprecated &&
                !used.contains(preset.address) &&
                !_dnsDismissed.contains(preset.address))
              preset.address,
        ].take(2).toList();
        dnsReplaced = dead;
      }
      if (next.isNotEmpty) {
        await saveSettings(settings.copyWith(dnsServers: next));
      }
      return true;
    } finally {
      checkingDns = false;
      notifyListeners();
    }
  }

  /// Checks [servers] and retries only the ones that failed. The first failure
  /// is kept private: the previous state stays on screen until the server either
  /// answers or fails all [_dnsRetryDelays] retries. Results that are already
  /// final are reported through [onSettled] as soon as they are known.
  ///
  /// Returns null when the tunnel went down or the native side gave no usable
  /// answer: such a round says nothing about the servers.
  Future<List<DnsCheck>?> _checkDnsWithRetries(
    List<String> servers,
    int generation, {
    void Function(List<DnsCheck> settled)? onSettled,
  }) async {
    final results = <String, DnsCheck>{};
    var pending = [...servers];
    var attempt = 0;
    while (pending.isNotEmpty) {
      if (generation != _dnsGeneration || !dnsReady) return null;
      final checks = await Native.checkDns(pending);
      if (generation != _dnsGeneration || !dnsReady) return null;
      if (checks.isEmpty) return null;
      final byServer = {for (final check in checks) check.server: check};
      final retry = <String>[];
      final settled = <DnsCheck>[];
      for (final server in pending) {
        final check = byServer[server];
        if (check == null) return null;
        results[server] = check;
        if (!check.ok && attempt < _dnsRetryDelays.length) {
          retry.add(server);
        } else {
          settled.add(check);
        }
      }
      if (settled.isNotEmpty) onSettled?.call(settled);
      pending = retry;
      if (pending.isEmpty) break;
      await Future<void>.delayed(_dnsRetryDelays[attempt]);
      attempt++;
    }
    return [
      for (final server in servers)
        if (results[server] != null) results[server]!,
    ];
  }

  /// Forgets the automatic DNS result, so the next snapshot checks the list
  /// again. Called when the DNS mode changes while the tunnel is up.
  void resetDnsVerification() {
    _dnsVerified = false;
    _dnsScheduled = false;
    _dnsReadySince = null;
    _dnsGeneration++;
    notifyListeners();
  }

  /// Checks one server that was just added to the list, so the new entry shows
  /// its real state at once instead of waiting for the next full check. The
  /// same 5 s / 15 s retries apply: a single missed answer does not turn the
  /// row red.
  Future<void> checkDnsServer(String server) async {
    if (!dnsReady || server.isEmpty) return;
    if (settings.dnsMode != DnsMode.yggdrasil) return;
    if (checkingDns) return;
    final generation = _dnsGeneration;
    checkingDns = true;
    notifyListeners();
    try {
      final results = await _checkDnsWithRetries(
        [server],
        generation,
        onSettled: (checks) {
          dnsChecks = {
            ...dnsChecks,
            for (final check in checks) check.server: check,
          };
          notifyListeners();
        },
      );
      // Same as in [verifyDns]: a link that dropped mid-check must not leave a
      // red "no answer" on a healthy server.
      if (results == null || results.isEmpty) return;
      dnsChecks = {
        ...dnsChecks,
        for (final check in results) check.server: check,
      };
    } finally {
      checkingDns = false;
      notifyListeners();
    }
  }

  /// Forgets a server in the "not working" block. The automatic check will not
  /// put it back during this session.
  void dismissDnsDead(String server) {
    dnsDead = [
      for (final item in dnsDead)
        if (item != server) item,
    ];
    _dnsDismissed.add(server);
    notifyListeners();
  }

  /// Re-reads the wiki list of internal DNS servers once per session, so the
  /// available list follows the page instead of the bundled snapshot.
  Future<void> refreshDnsPresets() async {
    try {
      final presets = await _wiki.loadDns();
      if (presets.isEmpty) return;
      final known = {for (final preset in dnsPresets) preset.address};
      final extra = [
        for (final preset in presets)
          if (!known.contains(preset.address)) preset,
      ];
      if (extra.isEmpty) return;
      dnsPresets = [...dnsPresets, ...extra];
      notifyListeners();
    } catch (_) {
      // The bundled list stays.
    }
  }

  Future<int> importResources(Iterable<Resource> selected) async {
    final existing = {for (final item in resources) item.url};
    final added = <Resource>[];
    for (final item in selected) {
      if (existing.add(item.url)) added.add(item);
    }
    if (added.isEmpty) return 0;
    resources = [...resources, ...added];
    // The book has to show the new entries at once: the write below goes
    // through the platform channel and must never hold the list back.
    notifyListeners();
    await _persistResources();
    return added.length;
  }

  // ------------------------------------------------------------------
  // Split tunnelling
  // ------------------------------------------------------------------

  Future<void> loadInstalledApps({bool force = false}) async {
    if (loadingApps) return;
    if (!force && installedApps.isNotEmpty) return;
    loadingApps = true;
    notifyListeners();
    try {
      final apps = await Native.listApps();
      apps.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      installedApps = apps;
    } finally {
      loadingApps = false;
      notifyListeners();
    }
  }

  Future<void> setSplitApps(List<String> packages) =>
      saveSettings(settings.copyWith(splitApps: packages));

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      if (value is Map) return Map<String, dynamic>.from(value);
      return const {};
    } catch (_) {
      return const {};
    }
  }

  static String _encode(Map<String, dynamic> value) => jsonEncode(value);

  static List<ProbeResult> _probeFromPeers(List<PeerEntry> entries) => [
    for (final entry in entries)
      ProbeResult(
        uri: entry.uri,
        up: true,
        latencyMs: entry.latencyMs,
        country: entry.country,
        city: entry.city,
        tcpRttMs: entry.tcpRttMs,
      ),
  ];

  static ThemeMode _themeFromCode(String? code) => switch (code) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _themeCode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };

  /// Older builds shipped a single DNS server and a third `custom` mode that
  /// duplicated the "Add a server" flow. Two servers are wanted now and the
  /// mode is gone, so the old default is upgraded once; a list the user edited
  /// is left alone.
  static AppSettings _migrateDns(AppSettings value) {
    var next = value;
    if (next.dnsMode == DnsMode.custom) {
      next = next.copyWith(dnsMode: DnsMode.yggdrasil);
    }
    if (next.dnsMode == DnsMode.system) return next;
    if (next.dnsServers.length == 1 &&
        next.dnsServers.first == '308:84:68:55::') {
      return next.copyWith(dnsServers: AppSettings.defaultDnsServers);
    }
    return next;
  }

  /// Country display name.
  String countryNameOf(String slug) => countryName(slug);

  /// Feeds a snapshot through the same path the service stream uses.
  ///
  /// The real entry points are private and need a platform channel, so the
  /// tests call this instead of poking at the fields: the point of the tests is
  /// exactly the "is this a change?" decision made here.
  @visibleForTesting
  void applySnapshotForTest(VpnSnapshot next) => _applySnapshot(next);
}
