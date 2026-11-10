import 'package:flutter/widgets.dart';

/// The strings of the app.
///
/// The app ships in English only: a single table keeps every text next to the
/// code that uses it and makes a missing key obvious (it falls back to the key
/// itself). `test/l10n_test.dart` asserts that the table is complete and that
/// the placeholders of the interpolated strings are used consistently.
class L10n {
  const L10n();

  String t(String key) => _en[key] ?? key;

  /// Like [t], but fills the `%s` placeholders in order.
  String tf(String key, List<Object> values) {
    var text = t(key);
    for (final value in values) {
      text = text.replaceFirst('%s', '$value');
    }
    return text;
  }

  static const L10n instance = L10n();

  /// Short helper for lookups inside widgets.
  static L10n of(BuildContext context) => instance;

  /// The raw table, used by the tests.
  static Map<String, String> table(String code) =>
      code == 'en' ? _en : const {};

  static const Map<String, String> _en = {
    'appName': 'Y-Node',
    'appTagline': 'A Yggdrasil network client',
    'ok': 'OK',
    'cancel': 'Cancel',
    'save': 'Save',
    'delete': 'Delete',
    'add': 'Add',
    'edit': 'Edit',
    'close': 'Close',
    'copy': 'Copy',
    'copied': 'Copied',
    'retry': 'Retry',
    'search': 'Search',
    'done': 'Done',
    'skip': 'Skip',
    'next': 'Next',
    'back': 'Back',
    'apply': 'Apply',
    'import': 'Import',
    'remove': 'Remove',
    'clear': 'Clear',
    'refresh': 'Refresh',
    'unknown': 'unknown',
    'yes': 'Yes',
    'no': 'No',

    'navHome': 'Tunnel',
    'navPeers': 'Peers',
    'navBook': 'Address book',
    'navSplit': 'Apps',
    'navSettings': 'Settings',

    'statusDisconnected': 'Disconnected',
    'statusConnecting': 'Connecting…',
    'statusConnected': 'Connected',
    'statusReconnecting': 'Reconnecting…',
    'statusDisconnecting': 'Disconnecting…',
    'connect': 'Connect',
    'disconnect': 'Disconnect',
    'yourAddress': 'Your address',
    'yourKey': 'Public key',
    'subnet': 'Subnet',
    'addressCopied': 'Address copied',
    'connectedFor': 'Connected for %s',
    'latency': 'Latency',
    'trafficDown': 'Received',
    'trafficUp': 'Sent',
    'uptime': 'Uptime',
    'noPeersYet': 'No peers selected',
    'addPeersHint': 'Open Peers to find nodes',
    'pickPeers': 'Find peers',
    'errorNoPeers': 'Add at least one peer first',
    'errorIdentityMissing': 'Could not create the node identity',
    'errorVpnPermission': 'Android did not grant the VPN permission',
    'errorNodeStart': 'Could not start the Yggdrasil node',
    'errorTakenOver': 'Another VPN app took the slot',
    'errorConnectCommand':
        'Android did not accept the connect command. Try again',
    'errorGeneric': 'Connection error',

    'stagePermission': 'Waiting for the VPN permission',
    'stagePreparing': 'Preparing the tunnel',
    'stageStarting': 'Starting the Yggdrasil node',
    'stageTunnel': 'Creating the tunnel',
    'stagePeers': 'Dialling peers: %s of %s connected',
    'stageWaiting': 'Waiting for the first peer to answer',
    'stageNetwork': 'Network changed, redialling',
    'stageReady': 'The tunnel is up',

    'latencyHint':
        'Latency is the round-trip time between the node on this phone and each '
        'connected peer, averaged over the peers that are up. Yggdrasil sends a '
        'signed request over every link and waits for a valid signed response; '
        'the figure shown is an exponential average of those round trips. It is '
        'a protocol measurement, not an ICMP ping.',
    'latencyShort': 'Average round-trip to the connected peers',
    'latencyRefresh': 'Refreshed every %s s · Settings → Connection',
    'refreshPeers': 'Re-check now',
    'peersRefreshed': 'Peer state re-read from the node',
    'refreshPeersHint':
        'Reads the live peer state from the node right away. Otherwise the list '
        'and the latency are refreshed at the check interval.',

    'peersTitle': 'Peers',
    'activePeers': 'Active peers',
    'peersConnected': '%s of %s connected',
    'replacementPool': 'Replacement pool',
    'poolHint': 'Live nodes ready to replace a peer that drops',
    'findPeers': 'Find peers',
    'findPeersHint':
        'Searches the public peer list, measures the nodes and adds the best '
        'ones to the tunnel. It can take a minute.',
    'findPeersDone': 'Peers added to the tunnel',
    'findPeersTitle': 'Peer discovery',
    'probing': 'Testing nodes…',
    'probePreparing': 'Locating you',
    'probeDownloading': 'Downloading the public peer list',
    'probeRanking': 'Ranking by distance',
    'probeTcp': 'Checking reachability',
    'probeYgg': 'Measuring Yggdrasil latency',
    'probeDone': 'Done',
    'probeResults': 'Results',
    'probeAlive': 'alive',
    'probeChecked': 'checked',
    'probeNothing': 'No live node was found. Try again later.',
    'addBest': 'Add the best',
    'addBestN': 'Add the best %s',
    'addManually': 'Add manually',
    'peerUri': 'Peer address',
    'peerUriHint': 'tls://host:port or wss://host:port/path',
    'invalidUri': 'Use an address like tcp://host:port or tls://host:port',
    'peerAlreadyExists': 'That peer is already added',
    'peerAdded': 'Peer added',
    'peerCountRaised': 'Peer added. Peers in the tunnel raised to %s',
    'peerSetUpdated': 'Kept the best %s peers in the tunnel',
    'peerSetUnchanged': 'These are already the best peers',
    'peerRemoved': 'Peer removed',
    'noActivePeers': 'No active peers',
    'poolEmpty': 'The pool is empty — run a peer test',
    'peerUp': 'online',
    'peerDown': 'offline',
    'peerConnected': 'connected',
    'peerOnline': 'online',
    'peerWaiting': 'waiting',
    'peerOffline': 'offline',
    'country': 'Country',
    'city': 'City',
    'tcpRtt': 'TCP',
    'yggLatency': 'Yggdrasil',
    'detectedLocation': 'Detected location',
    'changeCountry': 'Pick a country manually',
    'autoDetect': 'Detect automatically',
    'peersEmptyHint': 'No peer has been added yet',
    'removePeer': 'Remove peer',
    'peerCountLabel': 'Peers in the tunnel: %s',
    'latencyUnknown': '—',
    'peerExitNode': 'Exit node',
    'peerPinnedHint':
        'Pinned by an exit profile. Remove the exit node to drop this peer.',
    'peersClearBody': 'All peers except the pinned exit nodes will be removed.',

    'peerDetails': 'Peer details',
    'peerDirection': 'Direction',
    'peerInbound': 'inbound',
    'peerOutbound': 'outbound',
    'peerKey': 'Public key',
    'peerYggAddress': 'Yggdrasil address',
    'peerUptime': 'Link uptime',
    'peerTraffic': 'Traffic',
    'peerCost': 'Cost',
    'peerLastError': 'Last error',
    'peerNoErrors': 'none',
    'peerErrorCurrent': 'current',
    'peerErrorInactive': 'inactive',
    'peerErrorLastSeen': 'last seen %s',
    'peerScheme': 'Protocol',
    'peerPort': 'Port',

    'browseAllPeers': 'Browse all public peers',
    'peerCatalog': 'Public peers',
    'peerCatalogHint':
        'The whole public-peer list with every transport: tls, tcp, quic, ws '
        'and wss. Filter it, test it and add what you need.',
    'filterCountry': 'Country',
    'filterScheme': 'Protocol',
    'onlyPort443': 'Port 443 only',
    'allCountries': 'All countries',
    'allSchemes': 'All protocols',
    'catalogEmpty': 'No peer matches these filters',
    'catalogCount': 'Peers: %s',
    'catalogLoad': 'Load the peer list',
    'catalogLoading': 'Loading the peer list…',
    'addToTunnel': 'Add to the tunnel',
    'alreadyAdded': 'Already added',
    'notTested': 'not tested',
    'probeFailed': 'no handshake',
    'testVisible': 'Test latency',
    'testingVisible': 'Testing…',
    'testVisibleHint':
        'Tests the first 25 peers of the current list, five at a time. Tap a '
        'single peer to test just that one.',
    'testVisibleCount': 'Tests the first %s of %s peers',
    'testingProgress': 'Testing %s of %s',
    'catalogSortHint':
        'Sorted by distance from your location, peers in your country first. '
        'The list keeps this order while you filter it.',
    'peerTesting': 'Testing…',

    'bookTitle': 'Address book',
    'bookEmpty': 'The list is empty',
    'addResource': 'Add a resource',
    'editResource': 'Edit resource',
    'resourceTitle': 'Title',
    'resourceUrl': 'Address',
    'resourceDescription': 'Description',
    'openInBrowser': 'Open in browser',
    'browserHint':
        'Yggdrasil resources open in an external browser. For the site to load, '
        'that browser has to be in the VPN app list.',
    'addBrowserToSplit': 'Add the browser to the VPN',
    'browserAdded': 'The browser was added to the VPN app list',
    'browserNotFound': 'Could not determine the default browser',
    'dontShowAgain': "Don't show again",
    'browseDirectory': 'Browse the web directory',
    'directoryHint': 'Resources published in the Yggdrasil web directory',
    'directoryLoading': 'Reading the directory through the tunnel…',
    'directoryEmpty':
        'The directory has no resources that are not in the book yet',
    'directoryFailed':
        'Could not read the directory. Check the tunnel and try again.',
    'needConnectionTitle': 'Yggdrasil is off',
    'needConnectionBody':
        'Connect the client first: the web directory lives inside the Yggdrasil '
        'network and is not reachable without the tunnel.',
    'connectNow': 'Connect now',
    'importPreview': 'What to add',
    'importCount': 'Resources found: %s',
    'importSelectAll': 'Select all',
    'importApply': 'Add selected',
    'importDone': 'Resources added: %s',
    'importNothing': 'No new resources found',
    'deleteResource': 'Delete this resource?',
    'resourceDeleted': 'Resource deleted',
    'builtIn': 'built in',
    'invalidUrl': 'The address must start with http:// or https://',
    'bookSearchHint': 'Search by title or address',
    'bookSelect': 'Select',
    'bookSelectCancel': 'Done',
    'bookSelectedCount': '%s selected',
    'bookDeleteSelected': 'Delete selected',
    'bookDeleteSelectedBody': 'Delete the selected resources from the book?',
    'bookDeletedCount': 'Resources deleted: %s',
    'bookReorderHint': 'Long-press a card to move it',

    'splitTitle': 'Apps',
    'splitEnabled': 'Split tunnelling',
    'splitDescription':
        'Only the selected apps go through Yggdrasil. Yggdrasil addresses are '
        'reachable directly, and the ordinary internet goes through the built-in '
        'forwarder.',
    'splitSearch': 'Search apps',
    'splitSystemApps': 'System',
    'splitSelectedCount': '%s apps in the tunnel',
    'splitSelectedCountOne': '1 app in the tunnel',
    'splitPresets': 'Quick pick',
    'splitPresetBrowsers': 'Browsers',
    'splitPresetMessengers': 'Messengers',
    'splitPresetClear': 'Clear all',
    'splitApplied': 'Applied to the running tunnel',
    'splitOffHint':
        'Split tunnelling is off: every app goes through the tunnel',
    'splitRestartTitle': 'Restart the tunnel?',
    'splitRestartBody':
        'Android applies the app list only when the VPN is created, so the '
        'tunnel has to reconnect. Traffic stops for a few seconds.',
    'splitRestartAction': 'Restart',
    'splitNoApps': 'No apps found',
    'splitAllApps':
        'With an empty list every app goes through the VPN: Yggdrasil and the '
        'ordinary internet through the forwarder',
    'splitChangesPending': 'Changes are not applied yet',
    'splitNoChanges': 'Nothing to apply',
    'reconnectNow': 'Reconnect',
    'reconnectingNow': 'Reconnecting…',
    'reconnectDone': 'The tunnel is back up with the new app list',
    'reconnectFailed':
        'The tunnel did not come back with the new app list. Try again.',

    'exitNode': 'Exit node',
    'exitManage': 'Manage',
    'exitAddNode': 'Add an exit node',
    'exitStateOff': 'Off',
    'exitStateNoProfile': 'No node',
    'exitStateConnecting': 'Connecting…',
    'exitStateOnline': 'Online',
    'exitStateDegraded': 'Degraded',
    'exitStateFallback': 'Direct fallback',
    'exitStateDenied': 'Not allowed',
    'exitStateUnreachable': 'Unreachable',
    'exitCardOffHint': 'Public traffic leaves the phone directly',
    'exitCardNoProfileHint': 'Add a node to send public traffic through it',
    'exitCardConnectingHint': 'Bringing the exit node up',
    'exitCardOnlineHint': '%s · %s ms',
    'exitCardDirect': 'direct',
    'exitCardDegradedHint':
        'The active node is not answering; another one is used',
    'exitCardFallbackHint':
        'No exit node answered, public traffic uses the direct connection',
    'exitCardDeniedHint': 'The exit node does not allow this device',
    'exitCardUnreachableHint': 'No exit node is reachable',
    'exitNoProfiles': 'Add an exit node first',
    'exitCheckNow': 'Check now',
    'exitChecking': 'Checking…',
    'exitChecked': 'Exit nodes checked',
    'exitCheckFailed': 'Could not check the exit nodes',
    'exitApiLimited': 'API access is limited',
    'exitApiLimitedHint':
        'The exit wants an API token. The app fetches it automatically when '
        'this node is in the allowlist; otherwise ask the operator.',
    'exitQuotaTitle': 'Traffic quota',
    'exitQuotaMonth': 'This month %s of %s',
    'exitQuotaDay': 'Today %s of %s',
    'exitQuotaDown': 'Download limit %s',
    'exitQuotaUp': 'Upload limit %s',
    'exitQuotaExhaustedShort': 'Exhausted',
    'exitQuotaExhausted': 'The traffic quota is exhausted',
    'exitQuotaDailyExhausted': 'The daily traffic quota is exhausted',
    'exitQuotaMonthlyExhausted': 'The monthly traffic quota is exhausted',
    'exitQuotaExhaustedHint':
        'New connections are refused until the quota resets. Open connections '
        'keep working.',
    'exitSuspendedShort': 'Suspended',
    'exitSuspended': 'The operator suspended this client',
    'exitSuspendedHint':
        'The exit node refuses new connections until the operator resumes this '
        'device. Its quota, counters and token are kept.',
    'exitProfilesTitle': 'Exit nodes',
    'exitProfilesHint':
        'Public traffic goes through the first working node. Drag a row to '
        'change the failover order.',
    'exitScanQr': 'Scan QR code',
    'exitImportLink': 'Import from link',
    'exitLinkTitle': 'Import an exit link',
    'exitLinkField': 'Invite link',
    'exitLinkHint': 'yggnode://exit?v=1&a=…&i=…',
    'exitLinkHelper':
        'The same link the QR code carries: copy it from the server output, a '
        'chat or a file',
    'exitLinkEmpty': 'Paste the invite link first',
    'exitLinkInvalid': 'This is not a Y-Node exit link',
    'exitPaste': 'Paste from clipboard',
    'exitPasteEmpty': 'The clipboard is empty',
    'exitAddManually': 'Add manually',
    'exitName': 'Name',
    'exitNameHint': 'Shown on the Tunnel tab and in the QR code',
    'exitAddress': 'Yggdrasil address',
    'exitAddressHint': '200:…',
    'exitSocksPort': 'SOCKS port',
    'exitApiPort': 'API port',
    'exitApiPortHint': '0 = share the SOCKS port',
    'exitInvite': 'Invite token',
    'exitInviteHint':
        'From the server QR code. Redeemed at once when the tunnel is up; '
        'leave it empty for a plain SOCKS5 profile',
    'exitToken': 'API token',
    'exitTokenHint':
        'Optional. Issued by the exit with "x-node allow token <address>" or '
        'in its web panel; unlocks counters, limits and the IPv6 state',
    'exitTokenShow': 'Show token',
    'exitTokenHide': 'Hide token',
    'exitSocksOnly': 'SOCKS5 only',
    'exitSocksOnlyShort': 'SOCKS5',
    'exitSocksOnlyHint':
        'The exit is used as a plain SOCKS5 proxy: the address and the port '
        'are enough. Add an API token to unlock counters and limits.',
    'exitSocksOnlyPeerHint':
        'The exit is used as a plain SOCKS5 proxy and is reached through the '
        'public mesh. Add its peer address for a direct link.',
    'exitSocksOnlyFormHint':
        'Only the Yggdrasil address and the SOCKS port are required. Leave the '
        'invite and token empty to add the node as a plain SOCKS5 proxy; add '
        'them later to unlock the full status.',
    'exitSocksOnlySaved': 'Exit node saved as a SOCKS5 proxy',
    'exitIpv6BrokenShort': 'IPv6 not routed',
    'exitIpv6NoneShort': 'No IPv6',
    'exitIpv6BrokenHint':
        'The exit has an IPv6 address, but its provider does not route IPv6. '
        'IPv6 traffic is not sent through this exit.',
    'exitIpv6NoneHint':
        'The exit has no global IPv6 address. IPv6 traffic is not sent '
        'through this exit.',
    'exitPeer': 'Peer address',
    'exitPeerHint': 'tls://host:port?key=…',
    'exitPeerHelper':
        'From the server QR code. The exit node is added as a pinned peer so '
        'the tunnel reaches it directly.',
    'exitPeerInvalid': 'Enter a Yggdrasil peering URI like tls://host:port',
    'exitInvalidAddress': 'Enter a Yggdrasil IPv6 address (200::/7)',
    'exitInvalidPort': 'Enter a port between 1 and 65535',
    'exitActive': 'Active',
    'exitSetActive': 'Use this node',
    'exitRemoveTitle': 'Remove this exit node?',
    'exitRemoveBody': '%s will be removed from the failover list.',
    'exitRemoved': 'Exit node removed',
    'exitSaved': 'Exit node saved',
    'exitRegistered': 'Registered with %s',
    'exitRegisterFailed': 'Registration failed: %s',
    'exitRetryRegistration': 'Retry registration',
    'exitInviteMissing': 'No invite token. Scan the server QR code again.',
    'exitNeedTunnel':
        'Connect the tunnel first: registration goes through Yggdrasil.',
    'exitReconnectHint': 'Changes take effect after the tunnel reconnects',
    'exitFallbackDirect': 'Use the direct connection if the exit is down',
    'exitFallbackHint':
        'When no exit answers, public traffic leaves the phone directly',
    'exitLocalDns': 'Resolve local names on the local network',
    'exitLocalDnsHint':
        'Names like router.lan or nas.local are sent to the DNS of the real '
        'network instead of the exit',
    'exitDnsNode': 'DNS exit node',
    'exitDnsNodeHint':
        'Use the resolver the exit node publishes for its clients',
    'exitDnsNodeUnavailable':
        'The active exit node does not publish a resolver',
    'exitDnsAdvertised': 'DNS %s',
    'exitDnsTitle': 'Exit DNS',
    'exitDnsHint':
        'Public names are resolved through the exit with these servers',
    'exitLocalDnsTitle': 'Local DNS',
    'exitLocalDnsServersHint':
        'For local names. Empty means the DNS servers of the real network.',
    'exitDnsSystem': 'Automatic (real network)',
    'exitDnsInvalid': 'Enter IP addresses separated by commas or spaces',
    'exitDnsSaved': 'DNS servers saved',
    'exitUdp': 'Carry UDP through the exit',
    'exitUdpHint':
        'DNS and QUIC use the UDP relay of the exit node. When it is off, '
        'public UDP is dropped instead of leaking around the exit.',
    'exitUdpTitle': 'UDP relay',
    'exitUdpOnline': 'Through %s',
    'exitUdpIdle': 'Ready, opens with the first datagram',
    'exitUdpOff': 'Public UDP is not carried by the exit',
    'exitUdpError': 'UDP relay failed: %s',
    'exitUdpTraffic': '↓ %s (%s) · ↑ %s (%s)',
    'exitUdpTrafficHint': 'Datagrams and bytes carried by the exit',
    'exitUdpTrafficFull': '%s datagrams in (%s) · %s datagrams out (%s)',
    'exitUdpTest': 'Check UDP and QUIC',
    'exitUdpTesting': 'Checking UDP and QUIC…',
    'exitUdpTestTitle': 'UDP relay check',
    'exitUdpTestUdp': 'UDP · DNS through the exit',
    'exitUdpTestQuic': 'QUIC · h3 handshake',
    'exitUdpTestOk': 'OK · %s ms',
    'exitUdpTestSkipped': 'not run',
    'exitUdpTestThrough': 'Carried by %s',
    'exitUdpTestTraffic': '%s datagram(s) out, %s in',
    'exitUdpTestFailed': 'The check could not run',
    'exitIpv6Title': 'IPv6',
    'exitIpv6Hint': 'Global IPv6 addresses go through the exit node',
    'exitIpv6Test': 'Check IPv6',
    'exitIpv6TestTitle': 'IPv6 check',
    'exitIpv6TestTcp': 'TCP · HTTPS over IPv6',
    'exitIpv6TestUdp': 'UDP · DNS over IPv6',
    'exitIpv6TestAddress': 'The exit uses %s',
    'exitIpv6TestThrough': 'Carried by %s',
    'exitIpv6TestFailed': 'The IPv6 check could not run',
    'exitUdpLimit': 'The exit refused %s connection(s) at its limit of %s',
    'exitUdpLimitNoMax': 'The exit refused %s connection(s)',
    'exitUdpLimitHint':
        'Raise maxConnsPerClient on the exit node, or close some tabs',
    'heroMe': 'Me',
    'ipDirectTitle': 'Without the tunnel',
    'ipExitTitle': 'Through the exit',
    'ipDirectHint': 'What websites see on the real network',
    'ipExitHint': 'What websites see while the exit carries the traffic',
    'ipChecking': 'Checking the address…',
    'ipExitOff': 'The exit is off',
    'ipTunnelOff': 'Connect the tunnel first',
    'ipTimeout': 'The check timed out',
    'ipFailed': 'Could not read the address',
    'ipTapHint': 'Tap to see the address',
    'ipCopied': 'Address copied',
    'exitQrTitle': 'Scan the exit QR code',
    'exitQrHint': 'Point the camera at the QR code printed by ygg-exit invite.',
    'exitQrInvalid': 'This QR code is not a Y-Node exit invite',
    'exitQrTorch': 'Torch',
    'exitProfileOnline': 'online',
    'exitProfileUnreachable': 'unreachable',
    'exitProfileDenied': 'not allowed',
    'exitProfileUnknown': 'not checked',
    'exitLastChecked': 'Checked %s',
    'exitNeverChecked': 'Not checked yet',
    'exitUseNode': 'Use this exit node for public traffic?',
    'exitUseNodeBody':
        '%s will carry public TCP traffic. The tunnel has to reconnect to '
        'apply the change.',
    'exitEnable': 'Enable',
    'exitNotNow': 'Not now',

    'settingsTitle': 'Settings',
    'sectionConnection': 'Connection',
    'peerCount': 'Peers in the tunnel',
    'peerCountHint': 'How many nodes to keep connected at once',
    'autoReplace': 'Replace dropped peers',
    'autoReplaceHint': 'Swap a lost node for a live one from the pool',
    'deadTimeout': 'Treat a peer as dead after',
    'healthCheck': 'Check interval',
    'healthCheckHint':
        'How often the peer list and the latency are re-read from the node',
    'sectionDns': 'DNS',
    'dnsMode': 'DNS mode',
    'dnsYggdrasil': 'Yggdrasil internal DNS',
    'dnsSystem': 'System DNS',
    'dnsCustom': 'Custom servers',
    'dnsServers': 'DNS servers',
    'dnsAddServer': 'Add a server',
    'dnsHint':
        'The internal DNS servers resolve .ygg names and Yggdrasil addresses. '
        'With System DNS those names will not resolve.',
    'dnsInvalid': 'Enter an IPv6 DNS server address',
    'dnsCheck': 'Check now',
    'dnsChecking': 'Checking…',
    'dnsOk': 'Resolved in %s ms',
    'dnsOkTcp': 'Resolved in %s ms over TCP',
    'dnsFailed': 'No answer',
    'dnsNotWorking': 'Not working',
    'dnsNotWorkingTitle': 'Not working',
    'dnsForget': 'Remove from the list',
    'dnsName': 'Test name',
    'dnsAnswer': '%s → %s',
    'dnsUnknown': 'Not checked',
    'dnsNeedTunnel': 'Connect the tunnel to test the DNS servers',
    'dnsWaitingPeers':
        'The tunnel is up; the DNS test starts once a peer answers',
    'dnsAutoHint':
        'Every server is checked by resolving a few in-network names once the '
        'tunnel is fully up and a peer answers. A failed server is checked '
        'again after 5 and 15 seconds; only then is it dropped and, if none is '
        'left, replaced.',
    'dnsInUse': 'In use',
    'dnsAvailable': 'Available servers',
    'dnsAvailableHint':
        'Servers published in the Yggdrasil wiki and by your exit nodes',
    'dnsFromExitNode': 'DNS from exit node',
    'dnsExitLocked': 'Managed by the DNS exit node switch',
    'dnsReplaced': 'Dead servers replaced: %s',
    'dnsAllDead': 'No DNS server answered; check the tunnel',
    'dnsSource': 'List source: Yggdrasil wiki',
    'sectionNetwork': 'Network',
    'mtu': 'MTU',
    'mtuHint':
        '1280 bytes is the smallest MTU IPv6 allows. Yggdrasil runs over IPv6 '
        'and the path to a peer may cross tunnels with a smaller MTU, so a '
        'larger value risks silent packet loss. Change it only if you know the '
        'path is clean.',
    'sectionPower': 'Power',
    'energySaving': 'Save battery',
    'energySavingHint': 'Refresh the UI and the notification less often. The tunnel itself is unaffected',
    'batteryExemption': 'Ignore battery optimisation',
    'batteryOn': 'On — the VPN keeps running with the screen off',
    'batteryOff': 'Off — Android may stop the VPN in the background',
    'batteryGranted': 'Exemption granted',
    'batteryRequest': 'Request the exemption',
    'batteryRemoveHint': 'Turn the exemption off for Y-Node in the system list',
    'batteryRequestFailed': 'Could not open the battery optimisation settings',
    'sectionLogs': 'Diagnostics',
    'logging': 'Write a log',
    'loggingHint': 'The log file is capped at 512 KB',
    'viewLog': 'Open the log',
    'clearLog': 'Clear the log',
    'logCleared': 'The log was cleared',
    'notifications': 'Notifications',
    'notificationsHint': 'Needed for the ongoing VPN notification',
    'notificationsRequest': 'Allow notifications',
    'sectionAppearance': 'Appearance',
    'theme': 'Theme',
    'themeAuto': 'System',
    'themeLight': 'Light',
    'themeDark': 'Dark',
    'sectionDonate': 'Donate',
    'donateHint': 'Tap an address to copy it',
    'donationCopied': '%s address copied',
    'sectionUpdate': 'Update',
    'updateCheckAuto': 'Check for updates automatically',
    'updateCheckAutoHint': 'Look for a newer release when the app starts',
    'updateCheckNow': 'Check for updates now',
    'updateChecking': 'Checking…',
    'updateLatest': 'You are running the latest version',
    'updateAvailableTitle': 'Update available',
    'updateAvailableBody': 'Y-Node %s has been released.',
    'updateOpenRelease': 'Open the release page',
    'updateLater': 'Later',
    'updateFailed': 'Could not check for updates: %s',
    'updateOpenFor': 'Open the release page for %s',
    'sectionAbout': 'About',
    'version': 'Version',
    'yggVersion': 'Yggdrasil version',
    'yggAddress': 'Node address',
    'sourceCode': 'Source code',
    'yggSource': 'Yggdrasil source code',
    'yggSourceHint': 'github.com/yggdrasil-network/yggdrasil-go',
    'linkFailed': 'Could not open the link',
    'license': 'License',
    'advanced': 'Advanced',

    'logTitle': 'Log',
    'logEmpty': 'The log is empty',
    'logCopied': 'The log was copied',
    'logPath': 'File',
    'logSize': 'Size',
    'logWrap': 'Wrap lines',

    'onboardingWelcomeTitle': 'Welcome to Y-Node',
    'onboardingWelcomeBody':
        'Y-Node connects your phone to Yggdrasil, a decentralised IPv6 network '
        'running on top of the ordinary internet. Traffic is encrypted end to end.',
    'onboardingIdentityTitle': 'Your address',
    'onboardingIdentityBody':
        'The address is derived from your key and never changes. It is not tied '
        'to your location or identity.',
    'onboardingPeersTitle': 'Connecting',
    'onboardingPeersBody':
        'The node joins the network through public peers. We will find the ones '
        'closest to you and measure their Yggdrasil latency.',
    'onboardingFinish': 'Get started',
    'onboardingSkipPeers': 'Set up peers later',
    'onboardingLocation': 'Your location',
    'onboardingSearching': 'Looking for nearby nodes…',
    'onboardingFound': 'Live nodes found: %s',

    'seconds': 's',
    'minutes': 'min',
    'hours': 'h',
    'days': 'd',
    'justNow': 'just now',
    'ago': 'ago',
    'downloadFailed': 'The download failed, the bundled list is used',
    'noNetwork': 'No internet connection',
    'loading': 'Loading…',
  };
}
