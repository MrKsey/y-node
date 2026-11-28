# Changelog

All notable changes to Y-Node are documented here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

The release workflow publishes the section of the tag as the GitHub release body, so every release has a short human-readable summary of what changed. Keep each bullet on a single line: GitHub turns every newline in a release body into a hard break, so a wrapped bullet would render as a narrow column instead of using the full width.

## [1.5.41] — 2026-11-28

### Fixed

- **The panel follows the links right after the screen comes back.** With "Keep only the exit node with the screen off" the wake restored the peers and redialled the links, but the loop still waited out the hidden-window interval of a minute, so the notification sat at "1/4 peers" until its next tick; opening the window forced a fresh read, which is why it showed "4/4" at once. The wake now re-enters the one-second pace for two minutes, the fast pace wins over the hidden interval, and a restore or a redial restarts it as well.
- **The battery badge is gone from the app bar.** The exemption is still shown and switched in Settings, where the switch also explains what turning it off does.

### Changed

- **The UDP relay line shows the traffic volume only.** The datagram counters said nothing a reader could act on, so the line now reads "↓ 30.1 MB · ↑ 1.5 MB" and the screen reader gets the same figures with words.

## [1.5.40] — 2026-11-28

### Fixed

- **The overlay no longer freezes under a busy video feed.** Ironwood applied backpressure to a session while its packet reader was waiting for the consumer, and that consumer could be inside a write to the same session: every actor of the core stopped answering, the exit looked dead and the DNS resolvers timed out until the tunnel was rebuilt. The bundled copy of ironwood breaks that cycle, so a long Reels session keeps the core responsive.
- **A frozen core is named in the log and the tunnel rebuilds itself.** When the state query of the core does not answer within three seconds, the service writes the stacks of the overlay goroutines to the log and recreates the tunnel instead of waiting for the exit health checks to give up, at most once every thirty seconds.

## [1.5.39] — 2026-11-27

### Fixed

- **A silent public link is swapped after ten seconds instead of thirty.** The in-network resolvers of the DNS list travel over the same overlay as the exit: when one link kept its socket open while its session was gone, every Yggdrasil address behind it stopped answering at once, and the resolvers looked dead. The shorter window replaces such a link before a browser gives up on its lookup.
- **A failed in-network lookup names the state of every link in the log.** The line `dns: no in-network resolver answered, links: …` shows whether one link went silent or every link is down, so the next report points at the link instead of the resolver.

## [1.5.38] — 2026-11-27

### Fixed

- **The exit link is redialled as soon as its overlay session dies, not two health polls later.** The pinned link to the exit node can keep its socket open after ironwood dropped the session: the core still reports the link as up and the tree keeps sending through it, so every packet is lost while the exit looks connected. The supervisor now watches the overlay latency of that link and recreates it after six seconds of silence, which turns the dropout that ran for half a minute every few minutes into a redial that finishes in under a second.
- **The health ticks run every five seconds while the window is on screen.** A link that went silent is noticed at the next tick instead of on the next health interval, and the counters in the panel follow the same pace.
- **An exit outage names the state of every link in the log.** The first failed poll of an outage writes one line with every link, whether it is up and its overlay latency, so the next report shows whether the exit link itself went silent or the route through another peer did.

## [1.5.37] — 2026-11-27

### Fixed

- **Waking the phone no longer shows "0/4 peers" while the exit node is still working.** The wake path recreated every link older than ten seconds, and the pinned exit link was always one of them: for the length of its fresh handshake the panel had no live link to report, even though the route was fine a moment earlier. A link whose overlay session still answers is now left alone; only a link that is down or has lost its overlay session is redialled.
- **The panel reports the exit link as up right after the screen comes back.** The "Keep only exit node with the screen off" mode returns the public peers on wake, so the total becomes four again; the exit link now stays connected through the wake, which makes the first line "1/4" and it climbs to "4/4" as the public peers finish their handshakes instead of starting from "0/4".

## [1.5.36] — 2026-11-27

### Fixed

- **The notification panel no longer sticks at "0/0 peers" after a long sleep.** A wake restart of the links could leave the node without any of them while the active list still named them, and the panel published that as "no peers at all"; the supervisor now dials every configured link the node has forgotten, and the total never drops below the configured count, so the worst line is "0 of 3" and it recovers to the live figures by itself.
- **The peer counters are published as soon as the screen or the window comes back.** The supervisor may be parked for a minute after the wake, so the service reads the node right away instead of waiting for its next tick.
- **A link restart that cannot bring every link back says so in the log.** The panel is refreshed from the node even when no link came back, instead of keeping the figures from before the restart.

## [1.5.35] — 2026-11-27

### Fixed

- **The traffic counters in the notification panel follow a download again.** With the window hidden the panel was redrawn at most once every thirty seconds, so a download that ran for minutes showed the same number and read as a frozen counter; the figures are now refreshed every five seconds, and a post still happens only when the text changed, so an idle tunnel costs nothing.

## [1.5.34] — 2026-11-27

### Fixed

- **The tunnel no longer runs out of local ports after a few minutes of browsing.** Every app connection that goes through the exit node is an endpoint of the node's own userspace stack, and a closed one held its port for the default 60-second TIME_WAIT; a social network opened short connections faster than a range of 900 ports could release them, and the dial then failed for the exit health poll, the Yggdrasil DNS check and every new proxied connection alike, which looked like a dead core although every link was up. The range is now 4000 ports (61000-64999), the stack chooses the port itself so a lingering one can be reused, and TIME_WAIT is 5 seconds.
- **A link whose socket is alive but whose overlay session is gone is replaced.** The core reports such a peer as "up" because the TCP connection is open, while ironwood has already dropped it and nothing is routed through it; the supervisor now treats a link with no measured overlay latency for 30 seconds as dead and swaps in a fresh peer from the pool.
- **A failed internal dial names its cause in the log.** The number of connected endpoints and of opened and closed connections is logged with the port failure, so the next report shows whether the range was exhausted or something else broke.

## [1.5.33] — 2026-11-27

### Fixed

- **A tunnel that goes dead after a few minutes of use now recovers by itself.** Recreating only the pinned exit link was not enough: the route to the exit is chosen from the whole peer set, so a dead socket of any other peer blackholes it while still reporting "up"; a silent exit now walks a ladder — the pinned link, then every active link, then a full tunnel rebuild — with one fresh health poll between the steps, which is what a manual reconnect did.
- **A dead data path rebuilds the tunnel instead of staying silent.** The two bridge threads carry every packet in both directions, and a thread that ended left the node and its links looking healthy while nothing was read from the node, which also starved the exit health poll; either thread ending now rebuilds the tunnel.
- **A slow TUN write no longer stops the whole tunnel.** Both directions wrote into the descriptor from the thread that reads the node, so a blocking write froze `Recv` and with it the node's own connections; the writes now go through one writer thread and a bounded queue, and a full queue drops a packet instead of stalling the data path.

## [1.5.32] — 2026-11-27

### Fixed

- **The exit node no longer stays "unavailable" until the tunnel is restarted.** The Yggdrasil core has no keep-alive and no read deadline on a TCP link, so a link whose path died keeps reporting "up" while the node writes into a socket that carries nothing; the exit health poll is the one request that goes through Yggdrasil to the exit, so two polls that cannot reach it now drop the pinned link and dial it again, with a wait that doubles from a minute to five while the node is really offline.
- **The notification panel follows the peer counts again.** The panel was redrawn only by the stats loop, so a tunnel that woke with "0/0" or "1/4" kept that line until the app was opened; every supervisor tick now refreshes the notification, and a wake re-enters the fast start pace so the links come up one by one in the panel.
- **A missed screen-on broadcast no longer freezes the panel.** The service now re-reads the real screen state on its own timer while the screen is supposed to be off, so a lost `ACTION_SCREEN_ON` no longer keeps the stats loop parked and the peers of the "exit node only" mode dropped until the window is opened.
- **The stats loop survives a failed snapshot.** A throw in one stats push used to end the thread for good and leave the panel with the figures from that moment.

## [1.5.31] — 2026-11-26

### Fixed

- **The public peers come back on their own after a long sleep.** The "exit node only" mode parked the peer loop until `ACTION_SCREEN_ON`, and some vendor builds lose that broadcast after a deep sleep, so the loop stayed parked with the public peers dropped until the window was opened; the parked loop now re-reads the real screen state every fifteen seconds and runs the whole wake path as soon as the screen is back.
- **Unlocking the phone also ends the "exit node only" mode.** The service now listens for `ACTION_USER_PRESENT` next to the screen broadcasts, so a build that drops the screen-on signal still wakes the peers when the phone is unlocked, before the app is opened.
- **A peer waiting for its retry is restored in seconds, not a minute.** After a wake the network may still be coming up and the node refuses a peer; the supervisor now ticks at the five-second retry pace while such a peer is pending instead of waiting out the hidden-window interval.
- **A wake-up alarm slot re-reads the screen state too.** An alarm that fires after the screen is already back no longer acts on the stale "screen off" cache: the service checks the power manager first and runs the wake path.

## [1.5.30] — 2026-11-26

### Fixed

- **The public peers come back after a long screen-off in the "exit node only" mode.** The wake restart cancelled a link and immediately added it again, but the core keeps a removed link in its map until the goroutine that owns it exits, and the add was answered with "already configured" without dialling, so the peer stayed dead until the tunnel was rebuilt; the links are now dropped first, the node is polled until it forgets them, and only then added back.
- **A peer the node refused to restore is retried instead of lost.** The restore after the sleep puts such a peer back on the list and the supervisor asks the node again on every tick, so a network that was still coming up no longer costs the peer until a reconnect.
- **A missed screen-on broadcast no longer keeps the public peers dropped.** When the window comes back and the cached screen state still says "off", the service re-reads the real state from the power manager and runs the whole wake path, restoring the peers and recreating the links that did not survive the sleep.

## [1.5.29] — 2026-11-26

### Fixed

- **The tunnel keeps working after a long screen-off.** Android freezes the network while the device sleeps, and a peer link that lost its path stays "up" in the core, which has no keep-alive and no read deadline on a TCP link; the service now recreates the links when the screen comes back after two minutes off, so the exit node and the Yggdrasil network answer again without reconnecting the tunnel by hand.
- **The Active peers list fills in as the links come up.** The first thirty seconds after a connect are checked every second instead of waiting for the fifteen-second health interval, so the rows stop sitting at "0 of 3" while the handshakes finish.
- **Re-check now waits for the node.** The button used to show its confirmation before the service read anything; it now waits for the supervisor tick and says when the node did not answer.

## [1.5.28] — 2026-11-26

### Fixed

- **The first-run peer search counts the answers it gets.** The onboarding screen read the result list, which is filled only when the round ends, so it said "Live nodes found: 0" for the whole search even after nodes had answered; the counter now follows the running round and appears with the first answer, and a round that has not reached the Yggdrasil handshake yet no longer claims a zero.

## [1.5.27] — 2026-11-25

### Fixed

- **A plain SOCKS5 exit no longer shows as "Unreachable".** A profile added without an invite and token has no status API, so the missing answer was read as a dead node while every connection went through it; the bridge now checks the SOCKS port when the API stays silent, marks such a profile online with a "SOCKS5" pill and a hint that there are no counters, and keeps "Unreachable" for a node whose SOCKS port does not answer either.

## [1.5.26] — 2026-11-25

### Changed

- **The Reconnect button on the exit screen is gone.** Changes that need a rebuilt tunnel are applied when the screen closes, so the list of exits and its switches no longer end with a button that could be forgotten; a change that needs nothing still costs nothing.
- **"DNS exit node" turns itself on for an exit that publishes a resolver.** A server installed with the Alfis DNS answers only after its zone has synced, so the QR code used to add an exit without DNS; the switch now follows the resolver when the status reports it and adds it to the DNS list at once. A switch flipped by hand keeps the stored choice.

### Fixed

- **"Replace dropped peers" is off by default.** A fresh installation no longer swaps a lost peer for a stranger from the pool unless the switch is turned on.
- **Onboarding names the other two products** instead of a generic energy-saving line: X-Node, the exit node, and Y-Node Desktop.
- **The connect button says why it is disabled.** With no peers in the list the hero button stays dimmed and a line under it asks to add a peer first, instead of a button that looks ready and does nothing.

## [1.5.25] — 2026-11-24

### Added

- **Settings → Diagnostics → Counters**: a tap on a counter explains what it measures, and a long press clears it, so a fresh measurement can be started without reinstalling the app. Transit peers stays a live value of the running tunnel and has nothing to reset.

## [1.5.24] — 2026-11-23

### Fixed

- A window that came back after the screen was off could show the tunnel and every public peer exactly as they were before the pause, even when the "exit node only" mode had dropped the peers or the tunnel had been closed. The service skipped the listeners while the window was hidden, and the first frame after the wake was built from the state that was never delivered; it is now sent explicitly, and the peer counts are published the moment the list changes.
- A wake-up for the "exit node only" mode could be lost when the screen went off during a supervisor tick, which left the peer counters at their old values until the next alarm. The request flag is set now, so one fresh look always follows the drop or the restore.

### Added

- **Settings → Diagnostics** shows **Screen-off pauses** and **Screen-off peer drops**: how often the two Power switches really fired. A window that comes back already connected cannot tell whether the tunnel was paused or the peers were dropped, so the service counts both.

### Changed

- **Settings → Diagnostics** keeps the counters under a collapsed **Counters** dropdown, so the switch that matters stays in view.
- **Settings** puts the **Startup** section above **Power**.

## [1.5.22] — 2026-11-23

### Changed

- **Keep only the exit node with the screen off** now parks the peer supervisor for as long as the mode is on. With the public peers gone there is nothing to replace and nothing to top up, and the wake-up alarm already asks for one check per slot, so the loop used to wake the CPU a second time for the same look.

## [1.5.21] — 2026-11-23

### Added

- **Settings → Diagnostics** shows **Transit peers**: how many nodes chose this one as their parent in the spanning tree and therefore send their traffic through it. Zero means the phone is a leaf and only its own traffic passes the node.
- **Settings → Power → Keep only the exit node with the screen off** drops every public peer while the screen is off and keeps just the link to the exit node. The peers come back when the screen turns on, and the switch does nothing when no exit node is configured.
- **Settings → Power → Disconnect with the screen off** closes the tunnel when the screen goes off and rebuilds it when the screen comes back. The service stays in the notification panel with a "Paused while the screen is off" note, because Android does not deliver `ACTION_SCREEN_ON` to a manifest receiver and the running service is the only place that can hear the screen return.

### Changed

- **Settings → About** starts with the app version and no longer links to the Yggdrasil source code.
- The **Save battery** description now matches what the switch does: with the screen off the peers are checked every fifteen minutes instead of every five and the notification counters stay still until the screen is back, while traffic keeps full speed.

## [1.5.20] — 2026-11-22

### Changed

- The wake lock that keeps the CPU up after a burst of traffic with the screen off now lasts three seconds instead of ten. It is renewed by every further burst, so a download keeps the CPU up for as long as it runs and the speed is not limited; only the tail after the last packet is shorter.
- **Settings → Diagnostics** shows how many wake-up alarms the tunnel fired today, so the background work can be checked on the phone itself.
- **Save battery** switches itself on when the battery drops below 15% and the phone is not charging. It happens once per discharge: the flag is cleared when the phone starts charging, so a manual switch-off is not overridden again and again.
- The app reads only the keys it needs when the window comes back to the foreground instead of the whole preference store.
- The five tabs are created when they are first opened instead of all at once on the first frame.
- The DNS health check waits while the window is hidden and runs on the first visible frame, instead of resolving a name through the tunnel for a screen nobody sees.

### Fixed

- A tunnel that lost every peer while the replacement pool was empty stayed dead until the app was opened. The service now probes the cached peer catalogue in the background (rounds of five, capped at a minute, at most every ten minutes) and refills the pool, so the tunnel recovers on its own.
- The peer error history is no longer rebuilt and written to the store while the window is hidden: only a visible screen shows it.

## [1.5.19] — 2026-11-22

### Changed

- The client no longer works in the background when there is nothing to do. With the screen off the peer supervisor and the exit health loop run once per wake-up slot instead of every health interval, and the slot is five minutes (fifteen with **Save battery**). The wake-up alarm is armed only while a tunnel is up and **Replace dropped peers** is on; with the switch off the supervisor parks completely and only a real request wakes it. Without a tunnel nothing is armed at all.
- A hidden window is no longer redrawn. The service stops building stats with the screen off, drops the event stream while the app is in the background, and the uptime clock stops its one-second timer. On the way back the service sends one fresh round of stats, peer links and exit health, and the periodic poll resumes. The counters in the notification are refreshed every thirty seconds while the window is hidden instead of every second.
- The exit health check runs at most once a minute with the window hidden and once per wake-up slot with the screen off, so the exit keeps its registration fresh without an HTTP round trip every fifteen seconds.
- The app polls the service every three seconds while the tunnel is down instead of every second: nothing but a tap can change the screen in that state.

## [1.5.18] — 2026-11-22

### Fixed

- **Find peers ranks the answers by access time, not by country.** The list was grouped: every server of the detected country came first, so a node in Vladivostok was shown above a faster one in Finland. The country is only a prior now — the round still starts with the local servers, but it also tests the nearest foreign ones, and the Results card, **Add the best N** and the replacement pool all follow the measured Yggdrasil time. A client whose country has no peers of its own falls back to the closest countries, as before.

## [1.5.17] — 2026-11-22

### Fixed

- The pinned peer of the exit node now shows a cross instead of the lock while the exit switch is off, and the cross removes the peer from the active list. Switching the exit on brings the peer back with its lock. The resolver the **DNS exit node** switch owns behaves the same way: it can be removed while the exit is off and comes back, first in the tunnel list, when the exit is switched on. The **DNS exit node** switch itself stays on, so the intent is not lost.
- **Find peers** no longer skips the peers of the detected country. The probe sorted the whole candidate list by TCP round trip and stopped as soon as it had enough live peers, so the nearest peers were often never dialled and the card showed only distant ones: with the location detected in Russia the list held German, Dutch and French nodes. The peers of the detected country are now probed first and the early stop waits until all of them have been tested; the card keeps the country order instead of re-sorting the result by latency alone.

## [1.5.16] — 2026-11-21

### Fixed

- An invite scanned while the tunnel is down is now redeemed by itself once the tunnel connects. The profile was stored with its invite, but the registration needs Yggdrasil and was never retried: the service only refreshed its own fields with an empty invite, which X-Node refuses for an address that is not allowlisted yet, so the exit showed **API access is limited** with an empty API field while the invite stayed unused. The app now redeems every stored invite as soon as the link carries traffic, retries while the exit peer finishes its handshake, and saves the API token it receives.
- The service no longer sends an empty registration for a profile that has not redeemed its invite yet, so the exit log is not filled with `invite_invalid`.
- The hint after scanning an invite without a running tunnel says the invite is saved and will be redeemed on connect, instead of asking to connect first.

## [1.5.15] — 2026-11-21

### Fixed

- DNS resolution now matches the desktop client: the resolvers of one group are queried in parallel and the first usable answer wins, so one dead Yggdrasil resolver no longer delays every `.ygg` name by its timeout. Each group (exit, local, system) has its own three-second budget instead of one shared timeout, and an error answer is no longer cached for thirty seconds.
- The **Source code** line in **Settings → About** opens `https://github.com/MrKsey/y-node`; the yggdrasil-go link is a separate row.
- The status polling stops while the app is in the background and resumes when it comes back to the foreground, so the client no longer polls the node and the exit from a hidden window.

## [1.5.14] — 2026-11-21

### Fixed

- The Results card is sorted by latency, in the same order "Add the best" ranks it, so the peers the button keeps are the rows at the top of the card.

## [1.5.13] — 2026-11-21

### Fixed

- The exit node and the X-Node web panel now show the current app version. A registered client registers once per connect to refresh its device name and version; the server accepts an empty invite for an address that is already allowlisted, so no new invite is needed after an upgrade.
- Rebuilding the forwarding stack no longer leaves the previous exit manager's UDP association and sockets open: the manager is closed together with the old stack.

## [1.5.12] — 2026-11-20

### Fixed

- Disconnecting the tunnel now really leaves the Yggdrasil network. The exit manager kept its UDP association and its sockets after the node was stopped, so the client could stay visible on the exit node and keep a relay open while the app already showed "Disconnected". The association is closed together with the node, the same way the desktop core now does it.

## [1.5.11] — 2026-11-20

### Fixed

- The exit node card shows when IPv6 is turned off on the server: an **IPv6 off** pill and a hint that only IPv4 traffic goes through the exit, instead of the generic line that promised global IPv6 addresses would go through it. The exit is polled in the background (every 15 seconds by default), so a change on the server appears without pressing **Check now**.

## [1.5.10] — 2026-11-20

### Changed

- **Services → Browse the web directory** now shows a spinner in the button and a progress bar while the directory is read through the tunnel, and the button stays disabled until the read is over, so a second tap cannot start another load. The desktop app works the same way.
- A directory read that fails or finds nothing new is reported with a notification on the Services screen itself instead of the error line under the tunnel button.
- After an import the next browse reads the directory again, so entries published later are not missing from the list.

## [1.5.9] — 2026-11-18

### Fixed

- A connect started from the notification panel no longer disappears without a word. When it fails, a "Could not connect" notification stays in the panel, explains the reason and opens the app, and the VPN interface is requested up to three times because Android can refuse it for a moment right after a reboot.
- A connect that failed after the Yggdrasil node had started no longer leaves that node running in the background. The next attempt used to start a second node with the same identity, so the exit node saw two clients for one address and the exit link stayed down until the app was force-stopped and started again.
- The Connect action of the panel opens the app when Android has not yet been asked to allow the VPN connection, because that question can only be shown over an app window.
- An unexpected error in the connect path is reported in the panel instead of leaving the notification on "Connecting…".

## [1.5.8] — 2026-11-18

### Added

- **Settings → Startup → Connect on launch** brings the tunnel up when the app opens. It is off by default, and a tunnel that is already running (for example after a reboot) is left alone.
- **Settings → Startup → Start with the system** brings the app back after the phone boots without opening a window: it waits in the notification panel with a Connect action, and connects by itself only when the tunnel was on before the reboot or "Connect on launch" is enabled. The switch asks for the notification permission, without which Android would hide the panel entry.
- **Services** has a restore button that brings back the built-in resources deleted earlier, as in the desktop app.

### Changed

- A built-in resource deleted from **Services** stays deleted across restarts and upgrades instead of returning on every launch, and the order the user gave the list is kept.
- The resolver published by the exit node is the first entry of **Settings → DNS → In use** and of the list handed to the tunnel, so the server that answers in-network names is used first.

## [1.5.7] — 2026-11-16

### Added

- **Exit node → Manage → Settings** has a new **My name on exit node** option. When it is off or the name is empty, the exit node shows the device name. The name is sent as the client label and is limited to 32 characters; the X-Node operator can allow or forbid client labels.

### Changed

- The **Address book** menu and screen are now called **Services**.

## [1.5.6] — 2026-11-14

### Fixed

- The DNS server published by the newly selected exit node is checked right after a switch. The row in **Settings → DNS → In use** used to stay without a result while every other server showed its state, because only the server list was updated and no query was sent through the fresh resolver.
- The notification names the exit node: with an active exit the heading reads `Connected - <name>`, without one it stays `Connected`. The name is part of the notification key, so a switch repaints the panel at once instead of keeping the name of the previous node.

## [1.5.5] — 2026-11-13

### Fixed

- Switching the exit node while the tunnel is up no longer loses the new node on a reconnect. The peer list is now applied to the running supervisor before the UI continues, and stopping the supervisor no longer writes its in-memory list back over the list the app had just saved, which used to restore the previous exit peer and leave the tunnel without a route to the selected node.
- The selected exit node is reached directly right after a switch: its pinned peer is added to the live Yggdrasil node and the old one is removed in the same call, so the exit server sees the client and split-tunnel apps keep leaving through it.
- The Reconnect banner no longer flashes on every switch of the exit node. The switch is applied to the running forwarder in place, so no reconnect is needed and no pending-change banner is shown for it.

## [1.5.4] — 2026-11-13

### Fixed

- With several exit nodes configured, only the selected one is used. The Go bridge no longer tries the other profiles as a failover chain, so public TCP, UDP and DNS never leave through a node the user did not pick.
- IPv6 follows the selected profile only. An unselected node that can carry IPv6 no longer keeps IPv6 enabled, so a selected node without IPv6 stops IPv6 traffic instead of sending it through another exit.
- The exit icon on the tunnel screen shows the flag of the selected node, not the first pinned peer, and only that node is marked with the lock in the peer list.
- Only the selected profile gets a pinned exit peer. Switching the node moves the pinned link and rebuilds the forwarder at once, without waiting for a reconnect.

## [1.5.3] — 2026-11-11

### Fixed

- A rotated API token issued by the exit is stored in the profile again. The token was adopted only when another field of the status answer had changed too, so after the operator pressed **New token** in the exit dashboard the app kept showing the revoked token while the bridge already worked with the fresh one.

## [1.5.2] — 2026-11-10

### Added

- The **DNS exit node** switch stores the user's intent: it can be turned on before the exit publishes a resolver, and the server is added to the DNS list as soon as the status API reports it. The switch is always active, and its subtitle no longer shows the address.
- The switch owns its resolver only while it is on: a server added by hand while the switch is off stays an ordinary entry without a lock, and the switch does not turn itself on.
- Turning the switch on still selects Yggdrasil DNS when the system resolver was selected, but only when the resolver is known; without one the DNS mode is left alone.

### Changed

- The resolver of the active exit node is added to the tunnel list as soon as the status API reports it, even when the switch was already on. The stored switch state is migrated from the old derived value on the first start, so an upgrade keeps the previous choice.

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
