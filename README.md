# Y-Node 1.3.6

An Android client for the [Yggdrasil](https://yggdrasil-network.github.io/)
network, packaged as a VPN service. Built with Flutter + Kotlin + Go
(yggdrasil-go 0.5.15 through gomobile). The server side is the
[X-Node](https://github.com/MrKsey/x-node) exit node.

*[Русская версия](README.ru.md)*

## Files

| File | Architecture | Size | SHA-256 |
| --- | --- | --- | --- |
| `Y-Node-1.3.6-arm64-v8a.apk` | arm64-v8a (almost every phone) | 42.2 MB | `8b9266a7081a2d1165b95bf5b13ebde3cb684458aaa608c95ee42cf814b04fcd` |

APKs 1.0.0–1.3.5 are kept in the backup for rollback. Since 1.1.2 the build is
arm64-v8a only: there is one phone, 32-bit and x86_64 are not needed.

Requirements: Android 8.0 (API 26) or newer, targetSdk 36.

## Installation

1. Allow installation from unknown sources.
2. Install the APK for your architecture (`arm64-v8a` if unsure).
3. Open the app and complete the first-run wizard: test public peers, "add the
   best 3".
4. Press "Connect" and allow the VPN connection.

## Features

- **Yggdrasil VPN tunnel** in userspace: no root, no system TUN device.
- **Public peers**: the list is downloaded from
  `yggdrasil-network/public-peers`, the country and city are resolved by GeoIP,
  TCP RTT is measured, and then latency is measured over the Yggdrasil protocol
  itself in batches of five nodes until five live ones are found.
- **Peer auto-replacement**: a supervisor watches the links and replaces a dead
  peer from the pool (threshold and interval are configurable). A fresh peer
  gets 90 seconds for the handshake, and at most one peer is replaced per tick.
- **Per-app split tunnelling** (allow list) with search and presets. Android
  reads the app list only when the VPN is created, so changing the mode or the
  list restarts the tunnel: the "Apps" screen shows whether the live tunnel
  matches the settings and offers the restart itself.
- **Exit node**: public traffic leaves through the selected Yggdrasil node
  (SOCKS5 + `/v1/register`), profiles fail over to each other. The QR code
  carries `wss://host:port/ygg?key=…` (or `tls://host:port?key=…`), which is
  added as a **pinned** peer at the top of the list: the phone connects to the
  exit node directly, the server sees it as an inbound peer, and the traffic to
  the exit takes one hop. A pinned peer is never replaced by the supervisor and
  is not removed by "Clear".
  The first profile in the list turns the exit on automatically; removing the
  last profile turns the switch off, and in every other case the user's choice
  is kept. If a profile was added by hand and carries an invite, registration
  runs right after saving (with the tunnel up). "Retry registration" in the
  profile menu is shown only for profiles with an invite: it repeats the
  registration after a failure, when the invite is already stored. An invite is
  not only a QR code: the same link can be pasted into "Import from link" or
  taken from the clipboard, where it is picked up automatically.
- **Exit node API token**: a 1.3+ server with `apiToken: "required"` returns
  the client status only for `Authorization: Bearer`. Without a token
  `/v1/status` says nothing about the exit except that a token is required. The
  app receives the token during registration or fetches one with `POST
  /v1/token`, stores it in the profile and reuses it; without a token the exit
  card shows "API access is limited" instead of the counters. Profiles created
  before 1.3 keep working: the token is restored from the Yggdrasil address
  without a new QR. A fresh token wins over a stored one: issuing a new one
  revokes the old one, so the client does not ask for a token on every poll and
  backs off after a 429.
- **TCP and UDP through the exit**: TCP uses plain SOCKS5, UDP uses
  `UDP ASSOCIATE` (RFC 1928), so DNS and QUIC leave through the exit as well. If
  UDP is off or broken on the exit, a public datagram is dropped instead of
  leaking around the tunnel: QUIC falls back to TCP on its own. The "UDP through
  exit" switch is in the exit profiles, and the datagram counters are shown on
  the card. The client closes an idle UDP association earlier than the exit (45
  s against 2 min) and does not reuse it after a long phone sleep: otherwise
  datagrams would go to a relay the server had already forgotten.
- **IPv6 through the exit**: global addresses (`2000::/3`) are routed into the
  tunnel and leave through the exit — `CONNECT` with `ATYP=4` for TCP and
  `UDP ASSOCIATE` for UDP — so IPv6-only sites open and AAAA records do not
  bypass the tunnel. Service ranges (Yggdrasil `200::/7`, ULA `fc00::/7`,
  link-local `fe80::/10`, loopback, multicast, documentation and other
  reserved blocks) never go to the exit: Yggdrasil addresses are still served
  by the Go core, everything else is dropped. The server applies the policy
  twice — on its side and in the app. The exit card has a "Check IPv6" button:
  it makes a real HTTPS request over IPv6 and an AAAA lookup through the UDP
  relay of the exit and shows the result in a dialog, without a browser and
  without split tunnelling. The "UDP relay" and "IPv6" rows are visible only
  with the tunnel up: without it there is no relay and no IPv6 path, and the
  check buttons cannot work.
- **Domain names on the exit**: X-Node 1.4 resolves names itself
  (`ATYP=domain`), so DNS answers and connections cannot diverge, and an AAAA
  record without an IPv6 route costs a quarter of a second instead of a
  timeout. With an older server the app still resolves names locally.
- **Quotas on the exit**: the server counts the traffic of a client and can cap
  it per month or per day and throttle its speed. When a quota is exhausted, a
  new connection gets a SOCKS5 "not allowed" reply — the app shows an error,
  while open connections are not torn down. The limits and the usage are shown
  in the X-Node web interface.
- **Peers and the exit node**: the "Peers in the tunnel" setting counts public
  nodes only. The pinned exit peer sits on top as +1 and is not part of that
  number, which is why with 3 the buttons say "Add the best 3", not 4.
- **Peers on the exit node**: the X-Node server keeps the configured number of
  public peers (`peerCount`, 1..50) and replaces unreachable or clearly slower
  ones — through the Yggdrasil admin socket, without restarting the node.
  Replacement can be turned off (`peerAutoReplace` or `x-node peers auto off`);
  inbound clients of the exit node are never counted, replaced or dropped.
- **Ordinary internet for the listed apps**: Android 12 does not let an app
  from the allow list reach the network around the VPN, so IPv4 and global IPv6
  are routed into the tunnel and forwarded by the built-in tun2socks (gVisor
  netstack) through `VpnService.protect`.
- **Yggdrasil internal DNS**: presets from the wiki, "Yggdrasil"/"System" modes,
  custom servers. `.ygg` names resolve, ordinary names too.
- **Address book**: six preset resources, add/remove/search, open in a browser
  with an offer to add it to split tunnelling, import of web resources from
  `yggwiki.cc` with a preview.
- **Tunnel keep-alive**: a foreground service, `START_STICKY`, recovery after
  the VPN slot is revoked, an alarm while the screen is off, a battery
  optimisation exemption request, and a quick-settings tile.
- **Log**: a file up to 512 KB with a session header, the Go core log and DNS
  diagnostics; view, copy and clear from the app.
- **Smooth UI under load**: traffic counters arrive on a separate value stream
  and do not rebuild the tabs every second; the peer status map is cached per
  snapshot, and the app and address-book lists are not re-sorted without a
  change. The notification is updated only when its text changes. On an ALT-L29
  (120 Hz) scrolling with the tunnel up and a background download does not drop
  frames.

## Notes

- IPv6 works only with the exit node on. Without an exit, global IPv6 addresses
  are refused immediately and the browser falls back to IPv4 (Happy Eyeballs) —
  there is no direct IPv6 leak around the tunnel.
- The tunnel MTU is 1280 by default (the IPv6 minimum); it can be raised to
  1500 in the settings. For UDP through the exit the safe datagram payload is
  1232 bytes (1280 minus the IPv6 and RFC 1928 headers).
- With "System DNS" enabled, `.ygg` names do not resolve — only the internal DNS
  of the Yggdrasil network knows them.
- The traffic of the allow-listed apps goes through the userspace forwarder, so
  it is slower than a direct connection. Traffic to Yggdrasil addresses goes
  straight into the Go core and does not depend on the forwarder.

## Server side

The exit node lives in a separate repository,
[MrKsey/x-node](https://github.com/MrKsey/x-node): SOCKS5 over Yggdrasil,
registration by invite, allowlist, quotas, traffic accounting and a web
interface.

```bash
# on Ubuntu 24.04, as root
tar -xzf x-node-1.4.0-linux-amd64.tar.gz
cd x-node-1.4.0-linux-amd64
sudo ./install.sh
```

The installer prints the web password and offers to create the first invite: the
QR code is scanned in the app through **Exit node → +**. The exit address and its
Yggdrasil peer come from the same QR code, so nothing has to be typed in.

Details are in the [X-Node README](https://github.com/MrKsey/x-node/blob/main/README.md):
installation, IPv6, quotas, the web interface, switching to a real TLS
certificate and migrating from the old `ygg-exit`.

## Building from source

```powershell
# 1. Go bridge (needs Go 1.26+, NDK, JDK 17)
powershell -ExecutionPolicy Bypass -File tool/build_aar.ps1

# 2. Flutter APK (arm64 only)
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

Result: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
`--split-per-abi` is required: without it the build script does not apply the
ABI slot and versionCode stays 10 instead of 182.

Toolchain used for the verified build: Go 1.26.4, Flutter 3.47.6, Android SDK
36, NDK 27/28, JDK 17. The AAR needs `-ldflags=-checklinkname=0`.

The AAR is not stored in the repository: the script builds it from `go-bridge`
into `android/app/libs/yggnode.aar`, and CI does the same before building the
APK. CI builds with NDK 28.2.13676358; on a tag the APK is signed with the key
from the repository secrets, checked against the SHA-256 of the certificate, and
published together with the AAR and `SHA256SUMS.txt`.

Repository secrets used for signing: `ANDROID_KEYSTORE_BASE64` (the keystore in
base64, `base64 -w0 android/app/y-node.keystore`), `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS` (`ynode`), `ANDROID_KEY_PASSWORD`. Without them the release
stops before signing, and an APK signed with another certificate is never
published.

## Structure

- `go-bridge/yggnode` — the Go bridge: the Yggdrasil node, peers, latency
  probing, tun2socks.
- `android/app/src/main/kotlin/com/yggnode/app/vpn` — `VpnService`, the data
  path, the peer supervisor, tunnel keep-alive, the log.
- `lib/` — Flutter UI, state, public peer parsers, GeoIP, the wiki.

## License

MIT, see [LICENSE](LICENSE).
