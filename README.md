# Y-Node

A [Yggdrasil](https://yggdrasil-network.github.io/) client for Android.
The app brings up a VPN tunnel into Yggdrasil right on the phone — no root,
no manual setup and no third-party servers. And when you want regular
internet through a trusted node, Y-Node connects to an exit node with a
single QR scan.

*[Русская версия](README.ru.md)*

## Installation

1. Download the APK from the [latest release](https://github.com/MrKsey/y-node/releases/latest).
   `arm64-v8a` fits most phones; `armeabi-v7a` is for older 32-bit devices.
2. Allow installation from unknown sources and open the downloaded file.
3. Launch the app: the first-run wizard checks public peers and offers to add
   the best ones.
4. Tap "Connect" and allow Android to create the VPN connection.

## Features

- **Yggdrasil in one tap.** A real IPv6 tunnel into the distributed network:
  `.ygg` addresses, internal sites and services open like any other.
- **Public peers, handled for you.** The app downloads the peer list, measures
  latency and keeps the fastest nodes. No hunting for addresses, copying keys
  or editing configs.
- **A connection that stays up.** A supervisor watches the peers and replaces a
  dead or noticeably slower node from the pool, so the tunnel keeps working.
- **Your own exit node.** One QR code and all regular traffic goes through the
  node you trust. Profiles fail over automatically, and the phone connects to
  the exit directly, in a single hop.
- **IPv6 without surprises.** Global IPv6 addresses go through the exit while
  Yggdrasil's service ranges stay inside the network. A built-in check shows
  whether IPv6 really works.
- **UDP and QUIC.** DNS, video calls and QUIC traffic also go through the exit
  instead of trying to bypass the tunnel.
- **Quotas under control.** If the exit node limits traffic or speed, the app
  shows usage and a clear error instead of silently dropping connections.
- **Per-app VPN.** Pick the apps that need the tunnel and leave the rest on the
  direct connection. Search and ready-made presets included.
- **Yggdrasil DNS.** Internal `.ygg` names resolve out of the box; regular
  names go through the system DNS or servers you choose.
- **Address book.** The best sites of the network are already there: add your
  own, search and open them in a browser.
- **Works in the background.** The tunnel survives screen lock, network changes
  and restarts, and a quick-settings tile turns it on with one touch.
- **Clear diagnostics.** A log with core output and DNS checks can be viewed,
  copied and cleared right in the app.

## Server side

Y-Node works without a server: public peers are enough to reach the Yggdrasil
network. To route regular internet traffic, however, you need an **exit node**
— a server that accepts traffic from Yggdrasil and forwards it to the internet.

Such a node comes from a separate project,
[X-Node](https://github.com/MrKsey/x-node): it installs on Ubuntu with one
command, hands out QR-code invites and can meter traffic and enforce quotas.
X-Node is **optional** — without it Y-Node remains a full-featured Yggdrasil
client.

## Building from source

```powershell
# 1. Go bridge (requires Go, Android NDK and JDK 17)
powershell -ExecutionPolicy Bypass -File tool/build_aar.ps1

# 2. APK for both architectures
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

The finished files land in `build/app/outputs/flutter-apk/`.

## License

MIT, see [LICENSE](LICENSE).
