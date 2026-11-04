# Y-Node

A [Yggdrasil](https://yggdrasil-network.github.io/) client for Android.
The app brings up a VPN tunnel into Yggdrasil right on the phone — no root,
no manual setup and no third-party servers. And when you want regular
internet through a trusted node, Y-Node connects to an exit node with a
single QR scan.

For that second part Y-Node pairs with
[X-Node](https://github.com/MrKsey/x-node), a self-hosted exit node for
Yggdrasil. X-Node installs on Ubuntu or Debian with one command, hands out
QR-code invites, meters traffic and enforces volume and speed quotas. It is
optional: without it Y-Node remains a full-featured Yggdrasil client.

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

## Building from source

The build runs on Linux. Install Go, JDK 17, Flutter and the Android SDK with
the NDK, then set the paths:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/<version>"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export PATH="$JAVA_HOME/bin:$(go env GOPATH)/bin:$PATH"

# 1. Go bridge (requires Go, Android NDK and JDK 17)
go install golang.org/x/mobile/cmd/gomobile@latest
mkdir -p android/app/libs
cd go-bridge
gomobile init
gomobile bind -target=android/arm,android/arm64 -androidapi=26 \
  -ldflags=-checklinkname=0 -o ../android/app/libs/yggnode.aar ./yggnode
cd ..

# 2. APK for both architectures
flutter pub get
flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

The finished files land in `build/app/outputs/flutter-apk/`.

## License

MIT, see [LICENSE](LICENSE).
