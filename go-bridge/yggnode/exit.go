package yggnode

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ExitProfile is one exit server known to the app. The list order is the
// failover order; the active profile is tried first.
type ExitProfile struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Address   string `json:"address"`
	SocksPort int    `json:"socksPort"`
	APIPort   int    `json:"apiPort"`

	// Token is the API credential issued by the exit at registration (or
	// fetched from /v1/token when an older profile has none). It is bound to
	// the Yggdrasil address of this node, so it only unlocks its own counters.
	Token string `json:"token,omitempty"`
}

// exitConfig is the JSON contract between Kotlin and the Go bridge.
type exitConfig struct {
	Enabled        bool          `json:"enabled"`
	Profiles       []ExitProfile `json:"profiles"`
	ActiveID       string        `json:"activeId"`
	FallbackDirect bool          `json:"fallbackDirect"`
	DNS            []string      `json:"dns"`
	SystemDNS      []string      `json:"systemDns"`
	YggDNS         []string      `json:"yggDns"`
	LocalDNS       bool          `json:"localDns"`

	// UDP enables the SOCKS5 UDP ASSOCIATE path. It is a pointer so a config
	// written by an older build (no field) keeps UDP on, while an explicit
	// false disables it and makes public UDP fail closed instead of leaking.
	UDP *bool `json:"udp,omitempty"`
}

// udpEnabled reports whether public UDP may leave through the exit.
func (c exitConfig) udpEnabled() bool {
	return c.UDP == nil || *c.UDP
}

const (
	exitStateUnknown     = "unknown"
	exitStateOnline      = "online"
	exitStateUnreachable = "unreachable"
	exitStateDenied      = "denied"

	exitDeniedBackoff = 5 * time.Minute

	// exitUDPUnsupportedBackoff keeps an exit that answered "command not
	// supported" out of the UDP failover list. The check repeats rarely enough
	// to notice a server upgrade without slowing every datagram down.
	exitUDPUnsupportedBackoff = 10 * time.Minute

	// tokenRetryBackoff is how long the bridge waits after the exit answered
	// 429 on /v1/token. The exit allows five issues per ten minutes; retrying
	// sooner only keeps the window full.
	tokenRetryBackoff = 2 * time.Minute
)

type profileHealth struct {
	State       string  `json:"state"`
	LatencyMs   float64 `json:"latencyMs"`
	Error       string  `json:"error,omitempty"`
	CheckedAt   int64   `json:"checkedAt"`
	deniedUntil time.Time

	// Authenticated is what the exit reported for the last status request. A
	// pre-1.3 server has no auth at all and is always treated as authenticated.
	Authenticated bool
	// TokenRequired is true when the exit answered with the minimal payload:
	// it wants a token and this profile has none yet (or the old one was
	// rotated). The card shows a hint instead of pretending the counters are 0.
	TokenRequired bool

	// Load reported by the status API of the exit. Refused is the number of
	// connections the exit turned away since it started, which is how the app
	// tells a limit problem from a dead exit.
	Connections  int
	Refused      int
	QuotaRefused int
	// LimitRefused is the part of Refused caused by the connection limit. The
	// exit counts quota and suspension refusals separately; nil when the
	// server is too old to report it.
	LimitRefused       *int
	MaxConns           int
	UDPAssociations    int
	MaxUDPAssociations int
	// Quota is the traffic quota the exit applies to this client. Nil when the
	// exit has no quota for it or is too old to report one.
	Quota *exitQuota
	// Suspended is the temporary block the operator set in the web interface.
	// The exit still knows the client but refuses every new connection until
	// the block is lifted.
	Suspended bool
	// IPv6Available is what the exit reported about its own outbound IPv6:
	// true when a global address answered, false when the host has no address
	// or the provider does not route it. Nil means "not reported" (an exit
	// from before 1.6.21, or a status that was answered without a token).
	IPv6Available *bool
	// IPv6State explains the flag: "ok", "none", "broken", "off" or
	// "checking". It is only shown in the UI; the traffic decision uses
	// IPv6Available.
	IPv6State string
	// CapsKnown is true after a status answer carried the capabilities block.
	// DNSAddress and DNSPort are the resolver the exit publishes for its
	// clients; they stay empty when the exit runs without DNS.
	CapsKnown  bool
	DNSAddress string
	DNSPort    int
	// udpUnsupportedUntil keeps an exit that answered "command not supported"
	// out of the UDP failover list for a while, so every DNS query does not pay
	// for another refused handshake.
	udpUnsupportedUntil time.Time
}

// upstreamDialer is the single place tun2socks sends its upstream connections
// to. The direct implementation uses a protected socket; the exit manager
// wraps a SOCKS5 connection through Yggdrasil.
type upstreamDialer interface {
	DialContext(ctx context.Context, network, address string) (net.Conn, error)
}

// directDialer opens ordinary sockets on the underlying network. The protector
// is what keeps Android from routing these sockets back into the VPN.
type directDialer struct {
	prot    Protector
	timeout time.Duration
}

func newDirectDialer(prot Protector, timeout time.Duration) *directDialer {
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	return &directDialer{prot: prot, timeout: timeout}
}

func (d *directDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	dialer := net.Dialer{
		Timeout: d.timeout,
		Control: func(_, _ string, raw syscall.RawConn) error {
			if d.prot == nil {
				return nil
			}
			var protectErr error
			err := raw.Control(func(fd uintptr) {
				if !d.prot.Protect(int(fd)) {
					protectErr = errors.New("the socket could not be bound to the real network")
				}
			})
			if err != nil {
				return err
			}
			return protectErr
		},
	}
	return dialer.DialContext(ctx, network, address)
}

// exitManager owns the exit profile list, the failover order and the health
// state. It is safe for concurrent use.
type exitManager struct {
	mu     sync.RWMutex
	cfg    exitConfig
	inner  *internalNet
	direct upstreamDialer
	log    *goLogger
	health map[string]*profileHealth

	// tokens holds API tokens learned at run time: issued by a registration
	// or fetched from /v1/token. The status JSON carries them back to the app,
	// which stores them in the profile so a restart does not lose them.
	tokens map[string]string

	// tokenRetryAt defers the next /v1/token request after the exit rate
	// limited it. The exit allows five issues per ten minutes, so retrying on
	// every status poll would keep the client locked out.
	tokenRetryAt time.Time

	// dialAPI opens the TCP connection to the API port of an exit. It is a
	// field so the token tests can point the API client at a local server
	// instead of a live Yggdrasil address.
	dialAPI func(ctx context.Context, network, address string) (net.Conn, error)

	// udp is the shared SOCKS5 UDP association. udpMu only guards the pointer
	// and the dial in progress; the association itself is dialed without the
	// lock, so a status read never waits for a slow exit.
	udpMu       sync.Mutex
	udp         *socksUDPAssociation
	udpDialing  chan struct{}
	udpClosed   bool
	udpErr      string
	udpIn       atomic.Uint64
	udpOut      atomic.Uint64
	udpBytesIn  atomic.Uint64
	udpBytesOut atomic.Uint64

	// ipv6Path is carriesIPv6 in one word. The forwarding stack asks it for
	// every IPv6 packet, so it must not take a lock: the health map is updated
	// by the status poll, which is far less frequent than the packet path.
	ipv6Path atomic.Bool
}

func newExitManager(raw string, inner *internalNet, direct *directDialer, log *goLogger) (*exitManager, error) {
	cfg, err := parseExitConfig(raw)
	if err != nil {
		return nil, err
	}
	m := &exitManager{
		cfg:    cfg,
		inner:  inner,
		direct: direct,
		log:    log,
		health: make(map[string]*profileHealth),
		tokens: make(map[string]string),
	}
	for _, profile := range cfg.Profiles {
		m.health[profile.ID] = &profileHealth{State: exitStateUnknown}
	}
	// Until a status poll says otherwise, an exit is assumed to carry IPv6.
	// That keeps exits from before 1.6.21 working: they never report the
	// capability, and turning IPv6 off for them would break a working path.
	m.ipv6Path.Store(cfg.Enabled && len(cfg.Profiles) > 0)
	return m, nil
}

func parseExitConfig(raw string) (exitConfig, error) {
	var cfg exitConfig
	if strings.TrimSpace(raw) == "" {
		return cfg, nil
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return cfg, fmt.Errorf("bad exit config: %w", err)
	}
	for i := range cfg.Profiles {
		profile := &cfg.Profiles[i]
		profile.Address = strings.TrimSpace(profile.Address)
		if profile.ID == "" {
			profile.ID = profile.Address + ":" + strconv.Itoa(profile.SocksPort)
		}
		if profile.Name == "" {
			profile.Name = profile.Address
		}
		if !cfg.Enabled {
			continue
		}
		if ip := net.ParseIP(profile.Address); ip == nil || !yggRange.Contains(ip) {
			return cfg, fmt.Errorf("exit profile %q: %q is not a Yggdrasil address", profile.Name, profile.Address)
		}
		if profile.SocksPort <= 0 || profile.SocksPort > 65535 {
			return cfg, fmt.Errorf("exit profile %q: bad SOCKS port %d", profile.Name, profile.SocksPort)
		}
		if profile.APIPort <= 0 || profile.APIPort > 65535 {
			return cfg, fmt.Errorf("exit profile %q: bad API port %d", profile.Name, profile.APIPort)
		}
	}
	cfg.DNS = cleanServers(cfg.DNS)
	if len(cfg.DNS) == 0 {
		cfg.DNS = []string{"1.1.1.1", "9.9.9.9"}
	}
	cfg.SystemDNS = cleanServers(cfg.SystemDNS)
	cfg.YggDNS = cleanServers(cfg.YggDNS)
	return cfg, nil
}

func cleanServers(values []string) []string {
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{})
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || !validDNSServer(value) {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

// validDNSServer accepts a bare address or the [address]:port form an exit
// node uses when its resolver listens on a non-default port.
func validDNSServer(value string) bool {
	if net.ParseIP(value) != nil {
		return true
	}
	host, port, err := net.SplitHostPort(value)
	if err != nil || net.ParseIP(host) == nil {
		return false
	}
	number, err := strconv.Atoi(port)
	return err == nil && number >= 1 && number <= 65535
}

func (m *exitManager) config() exitConfig {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.cfg
}

func (m *exitManager) enabled() bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.cfg.Enabled && len(m.cfg.Profiles) > 0
}

// profileToken returns the API token of a profile. A token learned during this
// session wins over the stored one: issuing a new token revokes the previous
// one, so the stored copy is stale from that moment on. Without this the bridge
// would present the revoked token on every poll, fetch a fresh one, and burn
// the token rate limit while the exit kept answering with the minimal status.
func (m *exitManager) profileToken(profile ExitProfile) string {
	m.mu.RLock()
	learned := m.tokens[profile.ID]
	m.mu.RUnlock()
	if token := strings.TrimSpace(learned); token != "" {
		return token
	}
	return strings.TrimSpace(profile.Token)
}

// rememberToken keeps a token issued at run time. It is published in the
// status JSON so the app can save it in the profile.
func (m *exitManager) rememberToken(id, token string) {
	token = strings.TrimSpace(token)
	if id == "" || token == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.tokens[id] = token
}

// markAuth stores whether the exit accepted our token on the last check.
func (m *exitManager) markAuth(id string, authenticated, required bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.Authenticated = authenticated
	health.TokenRequired = required
}

// carriesIPv6 reports whether global IPv6 destinations may be forwarded. The
// exit node connects to them from its own host, so this does not depend on the
// phone having an IPv6 uplink. Without an exit the tunnel has no IPv6 path and
// the forwarding stack resets or drops such packets.
//
// The answer follows the last status poll: an exit whose host has no IPv6 or
// whose provider does not route it reports ipv6=false, and the tunnel then
// stops sending IPv6 traffic that could only time out. A pre-1.6.21 exit does
// not report the capability and keeps the old behaviour.
func (m *exitManager) carriesIPv6() bool {
	return m.ipv6Path.Load()
}

// markCapabilities stores what the exit said about itself: the IPv6 path and
// the DNS resolver it publishes for its clients. UDP support is discovered on
// the data path, where a refusal is immediate and specific.
func (m *exitManager) markCapabilities(id string, caps *exitAPICapabilities) {
	if caps == nil {
		return
	}
	m.mu.Lock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	available := caps.IPv6
	health.IPv6Available = &available
	health.IPv6State = strings.TrimSpace(caps.IPv6State)
	health.CapsKnown = true
	if caps.DNS {
		health.DNSAddress = strings.TrimSpace(caps.DNSAddress)
		health.DNSPort = caps.DNSPort
		if health.DNSPort <= 0 {
			health.DNSPort = 53
		}
	} else {
		health.DNSAddress = ""
		health.DNSPort = 0
	}
	allowed := m.ipv6PathLocked()
	m.mu.Unlock()
	m.ipv6Path.Store(allowed)
}

// ipv6PathLocked answers whether any profile might still carry IPv6. A profile
// whose capability is unknown counts as usable: the tunnel must not stop IPv6
// because one exit is old or was not polled yet. The caller holds m.mu.
func (m *exitManager) ipv6PathLocked() bool {
	if !m.cfg.Enabled || len(m.cfg.Profiles) == 0 {
		return false
	}
	for _, profile := range m.cfg.Profiles {
		health := m.health[profile.ID]
		if health == nil || health.IPv6Available == nil || *health.IPv6Available {
			return true
		}
	}
	return false
}

// ordered returns the profiles in the order they should be tried: the active
// one first, then the rest of the list in the order the user arranged.
func (m *exitManager) ordered() []ExitProfile {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if len(m.cfg.Profiles) == 0 {
		return nil
	}
	out := make([]ExitProfile, 0, len(m.cfg.Profiles))
	var active *ExitProfile
	for i := range m.cfg.Profiles {
		if m.cfg.Profiles[i].ID == m.cfg.ActiveID {
			active = &m.cfg.Profiles[i]
			break
		}
	}
	if active != nil {
		out = append(out, *active)
	}
	for _, profile := range m.cfg.Profiles {
		if active != nil && profile.ID == active.ID {
			continue
		}
		out = append(out, profile)
	}
	return out
}

// DialContext sends one upstream connection through the exit list. Private and
// link-local destinations never leave the phone. TCP falls back to the direct
// connection when the configuration allows it; UDP never does, because a leaked
// datagram would bypass the user's choice, so a failed exit means a dropped
// datagram and the app retries over TCP.
func (m *exitManager) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	switch network {
	case "udp", "udp4", "udp6":
		return m.dialUDP(ctx, network, address)
	case "tcp", "tcp4", "tcp6":
	default:
		return m.direct.DialContext(ctx, network, address)
	}
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port <= 0 || port > 65535 {
		return nil, fmt.Errorf("bad destination port %q", portText)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return m.direct.DialContext(ctx, network, address)
	}
	if isLocalDestination(ip) {
		return m.direct.DialContext(ctx, network, address)
	}
	if !m.enabled() {
		return m.direct.DialContext(ctx, network, address)
	}

	var lastErr error
	var destinationErr error
	for _, profile := range m.ordered() {
		if m.isDenied(profile.ID) {
			continue
		}
		started := time.Now()
		conn, err := m.dialViaProfile(ctx, profile, ip, port)
		if err == nil {
			m.markSuccess(profile.ID, time.Since(started))
			return conn, nil
		}
		lastErr = err
		var reply *socksReplyError
		if errors.As(err, &reply) {
			switch reply.Code {
			case socksReplyNotAllowed:
				// The exit answered and refused this client: no point in
				// retrying it for a while.
				m.markFailure(profile.ID, err)
			case socksReplyConnRefused:
				// The exit is healthy, the destination is not. Falling back to
				// a direct connection would bypass the user's choice.
				m.markReachable(profile.ID, time.Since(started), err)
				destinationErr = err
			default:
				m.markReachable(profile.ID, time.Since(started), err)
			}
		} else {
			m.markFailure(profile.ID, err)
		}
		m.log.emit("debug", "exit %s: %v", profile.Name, err)
	}

	if destinationErr != nil {
		return nil, destinationErr
	}
	cfg := m.config()
	if cfg.FallbackDirect {
		m.log.emit("warn", "no exit node is reachable, using the direct connection")
		return m.direct.DialContext(ctx, network, address)
	}
	if lastErr == nil {
		lastErr = errors.New("no exit node is available")
	}
	return nil, lastErr
}

func (m *exitManager) dialViaProfile(ctx context.Context, profile ExitProfile, ip net.IP, port int) (net.Conn, error) {
	if m.inner == nil {
		return nil, errors.New("the Yggdrasil stack is not available")
	}
	conn, err := m.inner.dialContext(ctx, "tcp", net.JoinHostPort(profile.Address, strconv.Itoa(profile.SocksPort)))
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", profile.Address, err)
	}
	if err := socks5Connect(ctx, conn, ip, port); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

// udpEnabled reports whether public UDP is currently carried by an exit node.
func (m *exitManager) udpEnabled() bool {
	cfg := m.config()
	return cfg.Enabled && len(cfg.Profiles) > 0 && cfg.udpEnabled()
}

// dialUDP opens one forwarded datagram flow. A private destination or a
// disabled exit keeps the old direct behaviour; with an exit enabled the
// datagram goes through it or is dropped, never around it.
func (m *exitManager) dialUDP(ctx context.Context, network, address string) (net.Conn, error) {
	host, portText, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port <= 0 || port > 65535 {
		return nil, fmt.Errorf("bad destination port %q", portText)
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// A name cannot be resolved by the exit: its UDP relay only accepts
		// addresses, and resolving here would leak the lookup.
		return nil, fmt.Errorf("UDP needs an IP destination, got %q", host)
	}
	if isLocalDestination(ip) || !m.enabled() {
		return m.direct.DialContext(ctx, network, address)
	}
	if !m.config().udpEnabled() {
		return nil, errUDPDisabled
	}

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		association, err := m.udpAssociation(ctx)
		if err != nil {
			return nil, err
		}
		flow, err := association.openFlow(ip, port)
		if err == nil {
			return flow, nil
		}
		// The association died between the lookup and the registration. The
		// next attempt dials a fresh one.
		lastErr = err
	}
	if lastErr == nil {
		lastErr = errUDPNoAssociation
	}
	return nil, lastErr
}

// udpAssociation returns the live association, dialing a new one when there is
// none. Only one dial runs at a time: every other caller waits for it instead
// of opening a second relay.
func (m *exitManager) udpAssociation(ctx context.Context) (*socksUDPAssociation, error) {
	for attempt := 0; attempt < 3; attempt++ {
		m.udpMu.Lock()
		if m.udpClosed {
			m.udpMu.Unlock()
			return nil, errExitStopped
		}
		if association := m.udp; association != nil && association.isAlive() {
			if !association.expired() {
				m.udpMu.Unlock()
				return association, nil
			}
			// The exit drops an association that stayed silent past its own
			// idle timeout, and a phone that was asleep never saw the close.
			// Reusing it would feed a relay the exit has already forgotten.
			m.udp = nil
			m.udpMu.Unlock()
			association.close(nil)
			continue
		}
		if wait := m.udpDialing; wait != nil {
			m.udpMu.Unlock()
			select {
			case <-wait:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			continue
		}
		done := make(chan struct{})
		m.udpDialing = done
		m.udpMu.Unlock()

		association, err := m.openUDPAssociation(ctx)

		m.udpMu.Lock()
		m.udpDialing = nil
		closed := m.udpClosed
		usable := err == nil && association != nil && association.isAlive() && !closed
		if usable {
			m.udp = association
			m.udpErr = ""
		} else {
			if err == nil {
				err = errUDPNoAssociation
			}
			if !closed {
				m.udpErr = err.Error()
			}
		}
		m.udpMu.Unlock()
		close(done)

		if closed && association != nil {
			association.close(errExitStopped)
		}
		return association, err
	}
	return nil, errUDPNoAssociation
}

// openUDPAssociation walks the failover list until one exit accepts the
// association.
func (m *exitManager) openUDPAssociation(ctx context.Context) (*socksUDPAssociation, error) {
	var lastErr error
	for _, profile := range m.ordered() {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if m.isDenied(profile.ID) || m.isUDPUnsupported(profile.ID) {
			continue
		}
		started := time.Now()
		association, err := m.dialUDPAssociation(ctx, profile)
		if err == nil {
			m.markSuccess(profile.ID, time.Since(started))
			m.log.emit("info", "exit %s: UDP association on %s", profile.Name, association.relay.RemoteAddr())
			return association, nil
		}
		lastErr = err
		var reply *socksReplyError
		if errors.As(err, &reply) {
			switch reply.Code {
			case socksReplyCommandNotSupp:
				// The exit runs with UDP disabled: keep it for TCP but stop
				// asking it for a relay on every datagram.
				m.markUDPUnsupported(profile.ID)
				m.markReachable(profile.ID, time.Since(started), err)
			case socksReplyNotAllowed:
				m.markFailure(profile.ID, err)
			default:
				m.markReachable(profile.ID, time.Since(started), err)
			}
		} else {
			m.markFailure(profile.ID, err)
		}
		m.log.emit("debug", "exit %s: UDP associate: %v", profile.Name, err)
	}
	if lastErr == nil {
		lastErr = errUDPNoAssociation
	}
	return nil, lastErr
}

// dialUDPAssociation opens the control connection and the relay socket of one
// association.
func (m *exitManager) dialUDPAssociation(ctx context.Context, profile ExitProfile) (*socksUDPAssociation, error) {
	if m.inner == nil {
		return nil, errors.New("the Yggdrasil stack is not available")
	}
	control, err := m.inner.dialContext(ctx, "tcp", net.JoinHostPort(profile.Address, strconv.Itoa(profile.SocksPort)))
	if err != nil {
		return nil, fmt.Errorf("connect to %s: %w", profile.Address, err)
	}
	relayAddr, err := socks5UDPAssociate(ctx, control)
	if err != nil {
		_ = control.Close()
		return nil, err
	}
	relay, err := m.inner.dialContext(ctx, "udp", relayAddr.String())
	if err != nil {
		_ = control.Close()
		return nil, fmt.Errorf("UDP relay socket: %w", err)
	}
	association := newSocksUDPAssociation(m, profile, control, relay, m.log)
	association.start()
	return association, nil
}

// dropUDPAssociation forgets an association that closed itself.
func (m *exitManager) dropUDPAssociation(association *socksUDPAssociation, reason error) {
	m.udpMu.Lock()
	if m.udp == association {
		m.udp = nil
	}
	// An idle timeout ends the association without an error and the next
	// datagram opens a new one, so the card goes back to "idle" instead of
	// showing a failure that never happened.
	if reason != nil {
		m.udpErr = reason.Error()
	} else if m.udp == nil {
		m.udpErr = ""
	}
	m.udpMu.Unlock()
}

// close releases the association, if any. It is called when the forwarding
// stack is rebuilt or stopped.
func (m *exitManager) close() {
	m.udpMu.Lock()
	m.udpClosed = true
	association := m.udp
	m.udp = nil
	m.udpMu.Unlock()
	if association != nil {
		association.close(errExitStopped)
	}
}

// noteUDPTraffic adds one datagram to the counters the UI shows.
func (m *exitManager) noteUDPTraffic(in, out, bytesIn, bytesOut uint64) {
	if in > 0 {
		m.udpIn.Add(in)
	}
	if out > 0 {
		m.udpOut.Add(out)
	}
	if bytesIn > 0 {
		m.udpBytesIn.Add(bytesIn)
	}
	if bytesOut > 0 {
		m.udpBytesOut.Add(bytesOut)
	}
}

func (m *exitManager) isUDPUnsupported(id string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	health, ok := m.health[id]
	return ok && !health.udpUnsupportedUntil.IsZero() && time.Now().Before(health.udpUnsupportedUntil)
}

func (m *exitManager) markUDPUnsupported(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.udpUnsupportedUntil = time.Now().Add(exitUDPUnsupportedBackoff)
}

func (m *exitManager) isDenied(id string) bool {
	m.mu.RLock()
	defer m.mu.RUnlock()
	health, ok := m.health[id]
	return ok && !health.deniedUntil.IsZero() && time.Now().Before(health.deniedUntil)
}

// markLoad stores the counters the status API reported for this client.
func (m *exitManager) markLoad(id string, connections, refused, quotaRefused int, limitRefused *int, maxConns, udpAssociations, maxUDPAssociations int, suspended bool, quota *exitQuota) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.Connections = connections
	health.Refused = refused
	health.QuotaRefused = quotaRefused
	if limitRefused != nil {
		value := *limitRefused
		health.LimitRefused = &value
	} else {
		health.LimitRefused = nil
	}
	health.MaxConns = maxConns
	health.UDPAssociations = udpAssociations
	health.MaxUDPAssociations = maxUDPAssociations
	health.Suspended = suspended
	health.Quota = quota
}

func (m *exitManager) markSuccess(id string, latency time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.State = exitStateOnline
	health.LatencyMs = float64(latency.Microseconds()) / 1000.0
	health.Error = ""
	health.CheckedAt = time.Now().Unix()
	health.deniedUntil = time.Time{}
}

func (m *exitManager) markFailure(id string, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.State = exitStateUnreachable
	health.Error = err.Error()
	health.CheckedAt = time.Now().Unix()
	if isSocksDenied(err) {
		// An exhausted traffic quota or an operator suspension is answered with
		// the same SOCKS reply as a real denial. Neither denies this device: the
		// exit still knows the client and only refuses new connections until
		// the cap resets or the operator resumes it. Marking it denied made the
		// card flip between "Online" (the status API still answers) and "Not
		// allowed" (the data path is refused) on every poll.
		if health.Suspended || (health.Quota != nil && health.Quota.Exhausted) {
			health.State = exitStateOnline
			return
		}
		health.State = exitStateDenied
		health.deniedUntil = time.Now().Add(exitDeniedBackoff)
	}
}

// markReachable records that the exit answered but the destination did not
// accept the connection. The exit stays online: its failover slot must not be
// taken by another profile because one host refused a port.
func (m *exitManager) markReachable(id string, latency time.Duration, err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	health, ok := m.health[id]
	if !ok {
		health = &profileHealth{}
		m.health[id] = health
	}
	health.State = exitStateOnline
	health.LatencyMs = float64(latency.Microseconds()) / 1000.0
	health.Error = err.Error()
	health.CheckedAt = time.Now().Unix()
	health.deniedUntil = time.Time{}
}

func isSocksDenied(err error) bool {
	var reply *socksReplyError
	return errors.As(err, &reply) && reply.Code == socksReplyNotAllowed
}

type socksReplyError struct {
	Code byte
}

func (e *socksReplyError) Error() string {
	switch e.Code {
	case socksReplyNotAllowed:
		return "the exit node did not allow the connection"
	case socksReplyConnRefused:
		return "the destination refused the connection"
	case socksReplyHostUnreach:
		return "the destination host is unreachable"
	case socksReplyNetworkUnreach:
		return "the destination network is unreachable"
	case socksReplyCommandNotSupp:
		return "the exit node does not support UDP"
	default:
		return fmt.Sprintf("SOCKS5 error %d", e.Code)
	}
}

const (
	socksVersion = 5

	socksCmdConnect      = 1
	socksCmdUDPAssociate = 3

	socksAtypIPv4   = 1
	socksAtypDomain = 3
	socksAtypIPv6   = 4

	socksReplySuccess        = 0
	socksReplyNotAllowed     = 2
	socksReplyNetworkUnreach = 3
	socksReplyHostUnreach    = 4
	socksReplyConnRefused    = 5
	socksReplyCommandNotSupp = 7

	// socksUDPHeaderMax is the largest RFC 1928 UDP header: RSV(2) FRAG(1)
	// ATYP(1), an IPv6 address and the port.
	socksUDPHeaderMax = 22
)

// errExitDropped means the exit closed the TCP control connection before it
// answered the SOCKS5 greeting. The server does that when a connection limit
// turns the client away: unlike an allowlist denial, it has no reply to send.
var errExitDropped = errors.New("the exit dropped the connection before the SOCKS5 greeting (connection limit?)")

// socks5Connect performs a no-auth CONNECT on an already connected socket.
func socks5Connect(ctx context.Context, conn net.Conn, ip net.IP, port int) error {
	if err := socks5Greeting(ctx, conn); err != nil {
		return err
	}
	_, _, err := socks5Request(ctx, conn, socksCmdConnect, ip, port)
	return err
}

// socks5UDPAssociate opens one UDP association and returns the relay address
// the exit named in its reply.
func socks5UDPAssociate(ctx context.Context, conn net.Conn) (*net.UDPAddr, error) {
	if err := socks5Greeting(ctx, conn); err != nil {
		return nil, err
	}
	// All zeroes: the exit pins the source port on the first datagram.
	ip, port, err := socks5Request(ctx, conn, socksCmdUDPAssociate, net.IPv4zero, 0)
	if err != nil {
		return nil, err
	}
	if port == 0 {
		return nil, errors.New("the exit did not name a UDP relay port")
	}
	return &net.UDPAddr{IP: ip, Port: port}, nil
}

// socks5Greeting negotiates the no-authentication method.
func socks5Greeting(ctx context.Context, conn net.Conn) error {
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	}
	defer conn.SetDeadline(time.Time{})

	if _, err := conn.Write([]byte{socksVersion, 1, 0}); err != nil {
		return fmt.Errorf("SOCKS5 greeting: %w", err)
	}
	var method [2]byte
	if _, err := io.ReadFull(conn, method[:]); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			// No SOCKS5 reply at all: the exit refused the connection before
			// the handshake, which is what its connection limit does.
			return fmt.Errorf("%w: %v", errExitDropped, err)
		}
		return fmt.Errorf("SOCKS5 greeting reply: %w", err)
	}
	if method[0] != socksVersion || method[1] != 0 {
		return errors.New("the exit node requires an unsupported authentication method")
	}
	return nil
}

// socks5Request sends one CONNECT or UDP ASSOCIATE request and returns the
// address of the reply.
func socks5Request(ctx context.Context, conn net.Conn, cmd byte, ip net.IP, port int) (net.IP, int, error) {
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	}
	defer conn.SetDeadline(time.Time{})

	request := make([]byte, 0, 22)
	request = append(request, socksVersion, cmd, 0)
	if v4 := ip.To4(); v4 != nil {
		request = append(request, socksAtypIPv4)
		request = append(request, v4...)
	} else if v6 := ip.To16(); v6 != nil {
		request = append(request, socksAtypIPv6)
		request = append(request, v6...)
	} else {
		return nil, 0, errors.New("bad destination address")
	}
	var portRaw [2]byte
	binary.BigEndian.PutUint16(portRaw[:], uint16(port))
	request = append(request, portRaw[:]...)
	if _, err := conn.Write(request); err != nil {
		return nil, 0, fmt.Errorf("SOCKS5 request: %w", err)
	}

	var header [4]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return nil, 0, fmt.Errorf("SOCKS5 reply: %w", err)
	}
	if header[0] != socksVersion {
		return nil, 0, fmt.Errorf("unexpected SOCKS version %d", header[0])
	}
	if header[1] != socksReplySuccess {
		return nil, 0, &socksReplyError{Code: header[1]}
	}
	switch header[3] {
	case socksAtypIPv4:
		var raw [6]byte
		if _, err := io.ReadFull(conn, raw[:]); err != nil {
			return nil, 0, err
		}
		return net.IP(append([]byte(nil), raw[0:4]...)), int(binary.BigEndian.Uint16(raw[4:6])), nil
	case socksAtypIPv6:
		var raw [18]byte
		if _, err := io.ReadFull(conn, raw[:]); err != nil {
			return nil, 0, err
		}
		return net.IP(append([]byte(nil), raw[0:16]...)), int(binary.BigEndian.Uint16(raw[16:18])), nil
	case socksAtypDomain:
		var length [1]byte
		if _, err := io.ReadFull(conn, length[:]); err != nil {
			return nil, 0, err
		}
		raw := make([]byte, int(length[0])+2)
		if _, err := io.ReadFull(conn, raw); err != nil {
			return nil, 0, err
		}
		return nil, int(binary.BigEndian.Uint16(raw[len(raw)-2:])), nil
	default:
		return nil, 0, fmt.Errorf("unexpected SOCKS address type %d", header[3])
	}
}

var localDestinations = mustCIDRs(
	"0.0.0.0/8",
	"10.0.0.0/8",
	"100.64.0.0/10",
	"127.0.0.0/8",
	"169.254.0.0/16",
	"172.16.0.0/12",
	"192.0.0.0/24",
	"192.0.2.0/24",
	"192.88.99.0/24",
	"192.168.0.0/16",
	"198.18.0.0/15",
	"198.51.100.0/24",
	"203.0.113.0/24",
	"224.0.0.0/4",
	"240.0.0.0/4",
	"::1/128",
	"fc00::/7",
	"fe80::/10",
	"ff00::/8",
)

func mustCIDRs(values ...string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(values))
	for _, value := range values {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			panic("bad built-in CIDR " + value + ": " + err.Error())
		}
		out = append(out, network)
	}
	return out
}

// isLocalDestination reports whether the address must stay on the phone's own
// network. Yggdrasil addresses never reach the forwarder, but the check keeps
// the function safe if it is called from somewhere else.
func isLocalDestination(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if v4 := ip.To4(); v4 != nil {
		for _, network := range localDestinations {
			if network.Contains(v4) {
				return true
			}
		}
		return v4.Equal(net.IPv4bcast)
	}
	v6 := ip.To16()
	if v6 == nil {
		return true
	}
	if yggRange.Contains(v6) {
		return true
	}
	for _, network := range localDestinations {
		if network.Contains(v6) {
			return true
		}
	}
	return false
}

// exitStatus is the JSON shape the UI reads.
type exitStatus struct {
	Enabled   bool                `json:"enabled"`
	State     string              `json:"state"`
	ActiveID  string              `json:"activeId"`
	Fallback  bool                `json:"fallbackDirect"`
	Profiles  []exitProfileStatus `json:"profiles"`
	UDP       exitUDPStatus       `json:"udp"`
	UpdatedAt int64               `json:"updatedAt"`
}

// exitUDPStatus describes the UDP relay the exit carries for this client.
type exitUDPStatus struct {
	Enabled      bool   `json:"enabled"`
	State        string `json:"state"`
	ProfileID    string `json:"profileId,omitempty"`
	ProfileName  string `json:"profileName,omitempty"`
	DatagramsIn  uint64 `json:"datagramsIn"`
	DatagramsOut uint64 `json:"datagramsOut"`
	BytesIn      uint64 `json:"bytesIn"`
	BytesOut     uint64 `json:"bytesOut"`
	Error        string `json:"error,omitempty"`
}

type exitProfileStatus struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Address   string  `json:"address"`
	State     string  `json:"state"`
	LatencyMs float64 `json:"latencyMs"`
	Error     string  `json:"error,omitempty"`
	CheckedAt int64   `json:"checkedAt"`

	// Authenticated is false when the exit answered with the minimal status:
	// it wants an API token this profile does not have yet.
	Authenticated bool `json:"authenticated"`
	// Token is a credential learned during this session, so the app can store
	// it in the profile and stop asking. Empty when the profile already has one.
	Token string `json:"token,omitempty"`

	// Load of this client on the exit, from the last status poll.
	Connections  int `json:"connections"`
	Refused      int `json:"refused"`
	QuotaRefused int `json:"quotaRefused,omitempty"`
	// LimitRefused is sent by exits from 1.6.11. A pointer keeps a real zero
	// distinct from "the server does not send the field".
	LimitRefused       *int `json:"limitRefused,omitempty"`
	MaxConns           int  `json:"maxConns"`
	UDPAssociations    int  `json:"udpAssociations"`
	MaxUDPAssociations int  `json:"maxUdpAssociations"`

	// Quota is the effective traffic quota of this client. Nil when the exit
	// does not limit it or is too old to report quotas.
	Quota *exitQuota `json:"quota,omitempty"`

	// Suspended is the operator block from the exit web interface. It keeps the
	// profile online, because the API answers; only new connections are refused.
	Suspended bool `json:"suspended,omitempty"`

	// IPv6Available is the exit's own outbound IPv6 state, as reported by the
	// exit. Nil when the server is too old to send it or answered without a
	// token; the card then shows no IPv6 line instead of guessing.
	IPv6Available *bool `json:"ipv6Available,omitempty"`
	// IPv6State is the short reason: ok, none, broken, off or checking.
	IPv6State string `json:"ipv6State,omitempty"`

	// DNSAddress is the resolver the exit publishes for its clients. Empty
	// when the exit has no DNS, and DNSKnown is true only after a status
	// answer carried the capabilities block: the app uses the pair to fill a
	// profile that was imported before the server turned DNS on, and to clear
	// it when the server turns DNS off.
	DNSAddress string `json:"dnsAddress,omitempty"`
	DNSPort    int    `json:"dnsPort,omitempty"`
	DNSKnown   bool   `json:"dnsKnown,omitempty"`
}

// exitQuota mirrors the quota block of the exit status API. Limits are 0 when
// unset; used counters are bytes since the start of the day and the month.
type exitQuota struct {
	MonthlyBytes int64  `json:"monthlyBytes"`
	DailyBytes   int64  `json:"dailyBytes"`
	DownKbps     int    `json:"downKbps"`
	UpKbps       int    `json:"upKbps"`
	DayUsed      uint64 `json:"dayUsed"`
	MonthUsed    uint64 `json:"monthUsed"`
	Exhausted    bool   `json:"exhausted"`
	Reason       string `json:"reason,omitempty"`
}

func (m *exitManager) status() exitStatus {
	out := m.statusBase()
	out.UDP = m.udpStatus()
	return out
}

// udpStatus is read without the manager lock: the association pointer has its
// own mutex and the counters are atomic, so a status poll never waits for a
// dial that is stuck on a dead exit.
func (m *exitManager) udpStatus() exitUDPStatus {
	cfg := m.config()
	out := exitUDPStatus{
		Enabled:      cfg.Enabled && len(cfg.Profiles) > 0 && cfg.udpEnabled(),
		DatagramsIn:  m.udpIn.Load(),
		DatagramsOut: m.udpOut.Load(),
		BytesIn:      m.udpBytesIn.Load(),
		BytesOut:     m.udpBytesOut.Load(),
	}
	if !out.Enabled {
		out.State = "off"
		return out
	}
	m.udpMu.Lock()
	association := m.udp
	errText := m.udpErr
	m.udpMu.Unlock()
	switch {
	case association != nil:
		out.State = "online"
		out.ProfileID = association.profile.ID
		// The association remembers the profile it was created with, so a
		// rename in the app would keep the old name until the relay reconnects.
		// The current configuration is the source of truth for the name.
		out.ProfileName = association.profile.Name
		for _, profile := range cfg.Profiles {
			if profile.ID == out.ProfileID && profile.Name != "" {
				out.ProfileName = profile.Name
				break
			}
		}
	case errText != "":
		out.State = "error"
		out.Error = errText
	default:
		out.State = "idle"
	}
	return out
}

func (m *exitManager) statusBase() exitStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := exitStatus{
		Enabled:   m.cfg.Enabled,
		ActiveID:  m.cfg.ActiveID,
		Fallback:  m.cfg.FallbackDirect,
		UpdatedAt: time.Now().Unix(),
	}
	if !m.cfg.Enabled {
		out.State = "off"
		return out
	}
	if len(m.cfg.Profiles) == 0 {
		out.State = "no_profile"
		return out
	}
	online := 0
	denied := 0
	unreachable := 0
	for _, profile := range m.cfg.Profiles {
		health := m.health[profile.ID]
		state := exitStateUnknown
		item := exitProfileStatus{
			ID:      profile.ID,
			Name:    profile.Name,
			Address: profile.Address,
		}
		if health != nil {
			state = health.State
			item.State = health.State
			item.LatencyMs = health.LatencyMs
			item.Error = health.Error
			item.CheckedAt = health.CheckedAt
			item.Authenticated = health.Authenticated
			item.Connections = health.Connections
			item.Refused = health.Refused
			item.QuotaRefused = health.QuotaRefused
			item.LimitRefused = health.LimitRefused
			item.MaxConns = health.MaxConns
			item.UDPAssociations = health.UDPAssociations
			item.MaxUDPAssociations = health.MaxUDPAssociations
			item.Quota = health.Quota
			item.Suspended = health.Suspended
			item.IPv6Available = health.IPv6Available
			item.IPv6State = health.IPv6State
			item.DNSAddress = health.DNSAddress
			item.DNSPort = health.DNSPort
			item.DNSKnown = health.CapsKnown
		}
		// Publish a token learned at run time, unless the profile already
		// carries the same one: the app saves the difference.
		if learned := m.tokens[profile.ID]; learned != "" && learned != profile.Token {
			item.Token = learned
		}
		if item.State == "" {
			item.State = exitStateUnknown
		}
		switch state {
		case exitStateOnline:
			online++
		case exitStateDenied:
			denied++
		case exitStateUnreachable:
			unreachable++
		}
		out.Profiles = append(out.Profiles, item)
	}
	switch {
	case online > 0:
		out.State = "online"
	case denied == len(m.cfg.Profiles):
		out.State = "denied"
	case unreachable > 0:
		out.State = "unreachable"
	default:
		out.State = "unknown"
	}
	return out
}

func (m *exitManager) statusJSON() string {
	raw, err := json.Marshal(m.status())
	if err != nil {
		return `{"enabled":false,"state":"off","profiles":[]}`
	}
	return string(raw)
}

// checkProfile asks the exit status API whether this client is allowed. The
// request goes through Yggdrasil, so it also proves that the exit is reachable
// right now.
// exitAPIStatus is the part of /v1/status the bridge reads. Without a token the
// exit sends only ok, authenticated and auth, so every other field is optional.
type exitAPIStatus struct {
	Allowlisted   *bool  `json:"allowlisted"`
	Open          bool   `json:"open"`
	Authenticated bool   `json:"authenticated"`
	Auth          string `json:"auth"`
	ExitName      string `json:"exitName"`
	Suspended     bool   `json:"suspended"`

	Connections        int        `json:"connections"`
	Refused            int        `json:"refused"`
	QuotaRefused       int        `json:"quotaRefused"`
	LimitRefused       *int       `json:"limitRefused"`
	MaxConns           int        `json:"maxConnsPerClient"`
	UDPAssociations    int        `json:"udpAssociations"`
	MaxUDPAssociations int        `json:"maxUdpAssociations"`
	Quota              *exitQuota `json:"quota,omitempty"`

	// Capabilities is what the exit can do. It is sent only to an
	// authenticated caller, so nil means "not reported", not "nothing works".
	Capabilities *exitAPICapabilities `json:"capabilities,omitempty"`
}

// exitAPICapabilities mirrors the capabilities block of the exit status API.
type exitAPICapabilities struct {
	UDP          bool   `json:"udp"`
	IPv6         bool   `json:"ipv6"`
	Registration bool   `json:"registration"`
	Token        bool   `json:"token"`
	IPv6State    string `json:"ipv6State,omitempty"`

	// DNS tells the client that the exit runs a resolver for its clients.
	// DNSAddress is the Yggdrasil address to query; DNSPort is normally 53.
	DNS        bool   `json:"dns"`
	DNSAddress string `json:"dnsAddress,omitempty"`
	DNSPort    int    `json:"dnsPort,omitempty"`
}

// apiCall performs one HTTP request against the API of an exit through
// Yggdrasil. The exit listens on a Yggdrasil address only, so this is the same
// path as the proxied traffic, on the API port.
func (m *exitManager) apiCall(ctx context.Context, profile ExitProfile, method, path string, body []byte, token string) (int, []byte, error) {
	dial := m.dialAPI
	if dial == nil {
		if m.inner == nil {
			return 0, nil, errors.New("the Yggdrasil stack is not available")
		}
		dial = m.inner.dialContext
	}
	conn, err := dial(ctx, "tcp", net.JoinHostPort(profile.Address, strconv.Itoa(profile.APIPort)))
	if err != nil {
		return 0, nil, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	}

	var request strings.Builder
	fmt.Fprintf(&request, "%s %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nUser-Agent: Y-Node\r\n",
		method, path, profile.Address)
	if token != "" {
		fmt.Fprintf(&request, "Authorization: Bearer %s\r\n", token)
	}
	if body != nil {
		fmt.Fprintf(&request, "Content-Type: application/json\r\nContent-Length: %d\r\n", len(body))
	}
	request.WriteString("\r\n")
	if _, err := io.WriteString(conn, request.String()); err != nil {
		return 0, nil, err
	}
	if len(body) > 0 {
		if _, err := conn.Write(body); err != nil {
			return 0, nil, err
		}
	}
	response, err := http.ReadResponse(bufioReader(conn), nil)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 8192))
	if err != nil {
		return 0, nil, err
	}
	return response.StatusCode, raw, nil
}

// apiStatusError is a non-200 answer from the exit API, with the machine
// readable code the exit puts in its JSON body.
type apiStatusError struct {
	Code int
	Name string
}

func (e *apiStatusError) Error() string {
	if e.Name == "" {
		return fmt.Sprintf("API returned status %d", e.Code)
	}
	return fmt.Sprintf("API returned status %d (%s)", e.Code, e.Name)
}

// fetchToken asks an allowlisted exit for an API token. The Yggdrasil source
// address is the credential: the exit knows which node is asking, so a profile
// from before 1.3 (or one whose token was rotated) gets a working one back.
func (m *exitManager) fetchToken(ctx context.Context, profile ExitProfile) (string, error) {
	// The exit rate-limits token issues, so a refusal has to stop the polling
	// loop: asking again every fifteen seconds only extends the lockout.
	m.mu.RLock()
	wait := time.Until(m.tokenRetryAt)
	m.mu.RUnlock()
	if wait > 0 {
		return "", fmt.Errorf("token request deferred for %s", wait.Round(time.Second))
	}
	code, raw, err := m.apiCall(ctx, profile, http.MethodPost, "/v1/token", nil, "")
	if err != nil {
		return "", err
	}
	if code != http.StatusOK {
		var failure struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(raw, &failure)
		if code == http.StatusTooManyRequests {
			m.mu.Lock()
			m.tokenRetryAt = time.Now().Add(tokenRetryBackoff)
			m.mu.Unlock()
		}
		return "", &apiStatusError{Code: code, Name: failure.Error}
	}
	var payload struct {
		OK    bool   `json:"ok"`
		Token string `json:"token"`
		Open  bool   `json:"open"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", err
	}
	if payload.Open {
		// Open mode has no tokens to bind: nothing to store.
		return "", nil
	}
	if !payload.OK || strings.TrimSpace(payload.Token) == "" {
		if payload.Error == "" {
			payload.Error = "no token in the answer"
		}
		return "", fmt.Errorf("token API refused: %s", payload.Error)
	}
	m.rememberToken(profile.ID, payload.Token)
	m.mu.Lock()
	m.tokenRetryAt = time.Time{}
	m.mu.Unlock()
	m.log.emit("info", "exit %s: API token received", profile.Name)
	return payload.Token, nil
}

// checkProfile asks the exit status API whether this client is allowed. The
// request goes through Yggdrasil, so it also proves that the exit is reachable
// right now. When the exit wants a token and the profile has none, the bridge
// fetches one and retries once; the token is published in the status JSON so
// the app can store it.
func (m *exitManager) checkProfile(ctx context.Context, profile ExitProfile) error {
	if m.inner == nil && m.dialAPI == nil {
		return errors.New("the Yggdrasil stack is not available")
	}
	started := time.Now()
	token := m.profileToken(profile)
	for attempt := 0; ; attempt++ {
		code, raw, err := m.apiCall(ctx, profile, http.MethodGet, "/v1/status", nil, token)
		if err != nil {
			m.markFailure(profile.ID, fmt.Errorf("status API: %w", err))
			return err
		}
		if code != http.StatusOK {
			var failure struct {
				Error string `json:"error"`
			}
			_ = json.Unmarshal(raw, &failure)
			err := fmt.Errorf("status API returned status %d (%s)", code, failure.Error)
			m.markFailure(profile.ID, err)
			return err
		}
		var payload exitAPIStatus
		if err := json.Unmarshal(raw, &payload); err != nil {
			m.markFailure(profile.ID, fmt.Errorf("status API: %w", err))
			return err
		}
		// A pre-1.3 exit sends no auth fields and always sends the full
		// status, so a missing mode must not be read as "refused".
		authenticated := payload.Authenticated || payload.Auth == "" ||
			payload.Auth == "off" || payload.Auth == "optional"
		if !authenticated && payload.Auth == "required" && attempt == 0 {
			fresh, tokenErr := m.fetchToken(ctx, profile)
			if tokenErr == nil && fresh != "" {
				token = fresh
				continue
			}
			if tokenErr != nil {
				m.log.emit("debug", "exit %s: no API token: %v", profile.Name, tokenErr)
				// The exit refused to issue a token because this node is not
				// in its allowlist: that is a hard denial, not a bad token.
				var refused *apiStatusError
				if errors.As(tokenErr, &refused) && refused.Name == "not_allowed" {
					err := &socksReplyError{Code: socksReplyNotAllowed}
					m.markFailure(profile.ID, err)
					return err
				}
			}
		}
		m.markAuth(profile.ID, authenticated, payload.Auth == "required" && !authenticated)
		m.markLoad(profile.ID, payload.Connections, payload.Refused, payload.QuotaRefused,
			payload.LimitRefused, payload.MaxConns, payload.UDPAssociations, payload.MaxUDPAssociations,
			payload.Suspended, payload.Quota)
		m.markCapabilities(profile.ID, payload.Capabilities)
		// Without a token the exit publishes nothing about allowlist, so a
		// missing field is "unknown", not "denied".
		if payload.Allowlisted != nil && !*payload.Allowlisted && !payload.Open {
			err := &socksReplyError{Code: socksReplyNotAllowed}
			m.markFailure(profile.ID, err)
			return err
		}
		m.markSuccess(profile.ID, time.Since(started))
		return nil
	}
}

// checkAll refreshes every profile and returns the new status JSON.
func (m *exitManager) checkAll(ctx context.Context) string {
	cfg := m.config()
	if cfg.Enabled {
		for _, profile := range cfg.Profiles {
			if ctx.Err() != nil {
				break
			}
			_ = m.checkProfile(ctx, profile)
		}
	}
	return m.statusJSON()
}

// registerResult is the JSON shape returned to the UI after an invite is
// redeemed. Error carries the machine-readable code of the exit API.
type registerResult struct {
	OK          bool   `json:"ok"`
	Allowlisted bool   `json:"allowlisted"`
	Registered  bool   `json:"registered"`
	ExitName    string `json:"exitName,omitempty"`
	Error       string `json:"error,omitempty"`
	Message     string `json:"message,omitempty"`
	// Token is the API credential the exit issued. The app stores it in the
	// profile; it is never shown in the UI.
	Token string `json:"token,omitempty"`
	// DNSAddress is the resolver the exit published in the registration
	// answer. The app stores it in the profile, so the "DNS exit node" switch
	// becomes usable right after the invite is redeemed.
	DNSAddress string `json:"dnsAddress,omitempty"`
	DNSPort    int    `json:"dnsPort,omitempty"`
}

// profile returns one configured profile by id. An empty id selects the active
// profile, or the first one when no active profile is set.
func (m *exitManager) profile(id string) (ExitProfile, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if id == "" {
		id = m.cfg.ActiveID
	}
	for _, profile := range m.cfg.Profiles {
		if profile.ID == id {
			return profile, true
		}
	}
	if id == "" && len(m.cfg.Profiles) > 0 {
		return m.cfg.Profiles[0], true
	}
	return ExitProfile{}, false
}

// register redeems an invite token on the exit API. The request travels through
// Yggdrasil, so the exit sees the node address as the source and the invite is
// bound to it. Registration is not an exit data-path operation: it works even
// when the exit itself is disabled, as long as the tunnel is up.
func (m *exitManager) register(ctx context.Context, profileID, invite, address, publicKey, deviceName, appVersion string) registerResult {
	profile, ok := m.profile(profileID)
	if !ok {
		return registerResult{Error: "unknown_profile", Message: "the exit profile is not configured"}
	}
	ip := net.ParseIP(profile.Address)
	if ip == nil || !yggRange.Contains(ip) {
		return registerResult{Error: "bad_profile", Message: "the exit address is not a Yggdrasil address"}
	}
	if m.inner == nil && m.dialAPI == nil {
		return registerResult{Error: "tunnel_unavailable", Message: "the Yggdrasil stack is not available"}
	}

	body, err := json.Marshal(map[string]string{
		"invite":     strings.TrimSpace(invite),
		"address":    address,
		"publicKey":  publicKey,
		"deviceName": strings.TrimSpace(deviceName),
		"appVersion": strings.TrimSpace(appVersion),
	})
	if err != nil {
		return registerResult{Error: "encode_failed"}
	}

	started := time.Now()
	code, raw, err := m.apiCall(ctx, profile, http.MethodPost, "/v1/register", body, "")
	if err != nil {
		return registerResult{Error: "unreachable", Message: err.Error()}
	}

	var payload struct {
		OK          bool   `json:"ok"`
		Allowlisted bool   `json:"allowlisted"`
		Registered  bool   `json:"registered"`
		ExitName    string `json:"exitName"`
		Error       string `json:"error"`
		Message     string `json:"message"`
		Token       string `json:"token"`

		Capabilities *exitAPICapabilities `json:"capabilities,omitempty"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return registerResult{Error: "bad_response", Message: err.Error()}
	}
	if code != http.StatusOK || !payload.OK || !payload.Allowlisted {
		name := payload.Error
		if name == "" {
			name = "registration_failed"
		}
		return registerResult{Error: name, Message: payload.Message}
	}

	// The token is bound to this node's Yggdrasil address. Keep it for the
	// running session and hand it to the app through the result and the status
	// JSON, so the profile can store it.
	m.rememberToken(profile.ID, payload.Token)
	m.markAuth(profile.ID, true, false)
	m.markCapabilities(profile.ID, payload.Capabilities)
	m.markSuccess(profile.ID, time.Since(started))
	m.log.emit("info", "registered with exit %s (%s)", profile.Name, payload.ExitName)
	result := registerResult{
		OK:          true,
		Allowlisted: true,
		Registered:  payload.Registered,
		ExitName:    payload.ExitName,
		Token:       payload.Token,
	}
	if payload.Capabilities != nil && payload.Capabilities.DNS {
		result.DNSAddress = strings.TrimSpace(payload.Capabilities.DNSAddress)
		result.DNSPort = payload.Capabilities.DNSPort
		if result.DNSPort <= 0 {
			result.DNSPort = 53
		}
	}
	return result
}

// bufioReader avoids importing bufio at the top of the file only for one call.
func bufioReader(r io.Reader) *bufio.Reader { return bufio.NewReader(r) }
