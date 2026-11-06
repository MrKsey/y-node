# Changelog

All notable changes to Y-Node are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

The release workflow publishes the section of the tag as the GitHub release
body, so every release has a short human-readable summary of what changed.

## [1.4.5] — 2026-11-06

### Fixed

- A suspended exit profile no longer shows "The exit refused N connection(s) at
  its limit". The exit reports suspended refusals in a separate counter, so an
  operator suspension and a real connection limit are no longer confused.
- The warning disappears as soon as the profile is resumed instead of staying
  until the counters are reset.

## [1.4.4] — 2026-11-06

### Added

- The app checks GitHub for a newer release on start, from the settings and from
  the home screen, and opens the release page when one is available. It only
  reads the release list: the APK is never downloaded or installed by the app.

## [1.4.3] — 2026-11-06

### Added

- An operator suspension of the exit profile is shown on the exit card, with the
  reason reported by the server instead of a generic connection error.

## [1.4.2] — 2026-11-05

### Fixed

- An exhausted exit quota is reported in the VPN notification, so a dropped
  connection no longer looks like a network problem.

## [1.4.1] — 2026-11-05

### Fixed

- The app version is refreshed on the exit after an upgrade instead of keeping
  the one from the first registration.
- The quota state stays stable between status polls and no longer flickers when
  a client is close to its limit.

## [1.4.0] — 2026-11-04

### Added

- The exit card shows the quota and the traffic used against it, with the
  limits the server reports.
- A refused connection now names the real reason: quota, speed limit or the
  connection limit of the exit.

## [1.3.7] — 2026-11-04

### Changed

- Releases contain only the APKs and their checksums.
- A 32-bit `armeabi-v7a` build is published next to `arm64-v8a`.
