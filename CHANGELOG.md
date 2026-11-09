# Changelog

All notable changes to Y-Node are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

The release workflow publishes the section of the tag as the GitHub release body, so every release has a short human-readable summary of what changed. Keep each bullet on a single line: GitHub turns every newline in a release body into a hard break, so a wrapped bullet would render as a narrow column instead of using the full width.

## [1.5.1] — 2026-11-09

### Fixed

- The **DNS exit node** switch becomes usable for a profile that was imported before the exit node turned DNS on: the app now reads the resolver from the exit status capabilities, stores it in the profile and runs one check after the tunnel connects.
- A registration answer now stores the resolver the exit publishes, so a freshly added profile offers the switch without waiting for the next status poll.
- New exit profiles default to API port `1080`, matching the X-Node installer default where the API shares the SOCKS5 listener.

## [1.5.0] — 2026-11-09

### Added

- An exit node that runs the Alfis DNS server for its clients now advertises the resolver in its invite. The server appears in **Settings → DNS → Available servers** with the note **DNS from exit node** and the name of the exit node.
- The **DNS exit node** switch in the Exit node settings puts the resolver of the active exit node into the DNS list, selects Yggdrasil DNS when the system resolver was on, and checks the server right away when the tunnel is up. The entry is marked with a lock instead of a remove button, because the switch owns it.
- The resolver follows the active exit profile: switching to another node replaces the server in the list, and removing the profile removes it.
- A non-default resolver port from the invite is kept as `[address]:port` and understood by the Go bridge; the system resolver still receives the bare address.
- The **Log** screen has a **Wrap lines** switch, on by default. Turning it off keeps every entry on one line and scrolls long lines horizontally.

## [1.4.7] — 2026-11-08

### Added

- The built-in DNS list includes the tilde.horse resolver at `202:cbff:6f7f:fa95:c6e9:3768:a96e:d1c8`, described as an ALFIS/meshname resolver.
- The **Search apps** field on the **Apps** tab has a clear button that appears while a query is typed and resets the filter.

### Fixed

- A renamed exit profile is shown under its new name in the **UDP relay** line and in both self-check dialogs, instead of the name captured when the relay association or the check started.
- App icons in the split-tunnel list stay with their own package after a search: a filtered row no longer shows the icon of a hidden app.

## [1.4.6] — 2026-11-08

### Added

- An exit node can be added as a plain SOCKS5 proxy: only the Yggdrasil address and the port are needed. Such a profile is marked **SOCKS5** in the card and the list, recommends adding the exit as a peer, and can be turned into a full profile later by adding an API token or an invite.
- The edit dialog has an API token field, so a token issued by the exit can be pasted into an existing profile. A token learned by the bridge is still saved automatically.
- A `yggnode://exit` link without an invite is accepted and adds the node as a SOCKS5-only profile. This is the link X-Node shows for a client that is already allowed, so a deleted exit profile can be restored without a new invite.
- The exit card and the profile list show the IPv6 state reported by the exit: no address, or an address the provider does not route.

### Fixed

- IPv6 traffic is no longer sent through an exit whose provider does not route it. The bridge follows the `ipv6` capability of the exit status and stops forwarding IPv6 packets that could only time out, without restarting the tunnel.
- Editing an exit profile no longer drops its stored API token.

## [1.4.5] — 2026-11-06

### Fixed

- A suspended exit profile no longer shows "The exit refused N connection(s) at its limit". The exit reports suspended refusals in a separate counter, so an operator suspension and a real connection limit are no longer confused.
- The warning disappears as soon as the profile is resumed instead of staying until the counters are reset.

## [1.4.4] — 2026-11-06

### Added

- The app checks GitHub for a newer release on start, from the settings and from the home screen, and opens the release page when one is available. It only reads the release list: the APK is never downloaded or installed by the app.

## [1.4.3] — 2026-11-06

### Added

- An operator suspension of the exit profile is shown on the exit card, with the reason reported by the server instead of a generic connection error.

## [1.4.2] — 2026-11-05

### Fixed

- An exhausted exit quota is reported in the VPN notification, so a dropped connection no longer looks like a network problem.

## [1.4.1] — 2026-11-05

### Fixed

- The app version is refreshed on the exit after an upgrade instead of keeping the one from the first registration.
- The quota state stays stable between status polls and no longer flickers when a client is close to its limit.

## [1.4.0] — 2026-11-04

### Added

- The exit card shows the quota and the traffic used against it, with the limits the server reports.
- A refused connection now names the real reason: quota, speed limit or the connection limit of the exit.

## [1.3.7] — 2026-11-04

### Changed

- Releases contain only the APKs and their checksums.
- A 32-bit `armeabi-v7a` build is published next to `arm64-v8a`.
