// Package yggnode exposes the Yggdrasil node to Android through gomobile.
//
// The node runs entirely in userspace: the IPv6 packets are exchanged with the
// Android VpnService file descriptor by the Kotlin side, so no root and no
// system TUN device are needed.
package yggnode

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
	"github.com/yggdrasil-network/yggdrasil-go/src/version"
)

// Logger receives the log lines produced by the node. Android passes an
// implementation that appends them to the connection log.
type Logger interface {
	Log(level string, message string)
}

// yggRange is the whole Yggdrasil address space. Peer links pointing into it are
// refused: on Android a peering URI inside the tunnel would route the peering
// traffic through the tunnel itself.
var yggRange = net.IPNet{IP: net.ParseIP("200::"), Mask: net.CIDRMask(7, 128)}

// maxPeerURILength keeps a malformed URI from reaching the parser.
const maxPeerURILength = 512

// yggVersion is the Yggdrasil core that this library is built against.
const yggVersion = "0.5.15"

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// goLogger implements core.Logger and forwards every level to the Android
// logger. Debug lines carry the dial errors of the peer links, which is the
// only way to see why a peer did not come up; trace lines are dropped.
type goLogger struct {
	mu  sync.RWMutex
	out Logger
}

func (g *goLogger) setTarget(l Logger) {
	g.mu.Lock()
	g.out = l
	g.mu.Unlock()
}

func (g *goLogger) emit(level, format string, args ...any) {
	g.mu.RLock()
	out := g.out
	g.mu.RUnlock()
	if out == nil {
		return
	}
	msg := format
	if len(args) > 0 {
		msg = fmt.Sprintf(format, args...)
	}
	msg = strings.TrimRight(msg, "\n")
	if msg == "" {
		return
	}
	out.Log(level, msg)
}

func (g *goLogger) Printf(f string, a ...any) { g.emit("info", f, a...) }
func (g *goLogger) Println(a ...any)          { g.emit("info", "%s", fmt.Sprint(a...)) }
func (g *goLogger) Infof(f string, a ...any)  { g.emit("info", f, a...) }
func (g *goLogger) Infoln(a ...any)           { g.emit("info", "%s", fmt.Sprint(a...)) }
func (g *goLogger) Warnf(f string, a ...any)  { g.emit("warn", f, a...) }
func (g *goLogger) Warnln(a ...any)           { g.emit("warn", "%s", fmt.Sprint(a...)) }
func (g *goLogger) Errorf(f string, a ...any) { g.emit("error", f, a...) }
func (g *goLogger) Errorln(a ...any)          { g.emit("error", "%s", fmt.Sprint(a...)) }
func (g *goLogger) Debugf(f string, a ...any) { g.emit("debug", f, a...) }
func (g *goLogger) Debugln(a ...any)          { g.emit("debug", "%s", fmt.Sprint(a...)) }
func (g *goLogger) Traceln(...any)            {}

// ---------------------------------------------------------------------------
// Node
// ---------------------------------------------------------------------------

// PeerStatus is the JSON shape returned by GetPeersJSON.
type PeerStatus struct {
	URI           string  `json:"uri"`
	Up            bool    `json:"up"`
	Inbound       bool    `json:"inbound"`
	Key           string  `json:"key"`
	IP            string  `json:"ip"`
	LatencyMs     float64 `json:"latencyMs"`
	Cost          uint64  `json:"cost"`
	RXBytes       uint64  `json:"rxBytes"`
	TXBytes       uint64  `json:"txBytes"`
	UptimeSeconds float64 `json:"uptimeSeconds"`
	LastError     string  `json:"lastError"`
	LastErrorUnix int64   `json:"lastErrorUnix"`
}

// Node is a running Yggdrasil instance. Only one instance is used per process.
type Node struct {
	mu      sync.Mutex
	core    *core.Core
	rwc     *ipv6rwc.ReadWriteCloser
	tun     *tun2socks
	inner   *internalNet
	exit    *exitManager
	dns     *dnsRouter
	logger  *goLogger
	running bool
	mtu     int
	address string
	subnet  string
	pubkey  string

	// Forwarder settings are kept so the stack can be rebuilt when the exit
	// configuration changes without restarting the whole node.
	exitRaw   string
	protector Protector
	writer    PacketWriter
	tunMTU    int
	tunV4     net.IP
	tunGen    uint64
}

// NewNode creates a stopped node.
func NewNode() *Node {
	return &Node{logger: &goLogger{}, mtu: 1280}
}

// SetLogger attaches the Android logger. Safe to call at any time.
func (n *Node) SetLogger(l Logger) {
	n.logger.setTarget(l)
}

type startConfig struct {
	PrivateKey string   `json:"privateKey"`
	Peers      []string `json:"peers"`
	MTU        int      `json:"mtu"`
}

// GenerateKey creates a fresh identity and returns it as JSON:
// {"privateKey":"..","publicKey":"..","address":"200:.."}.
func GenerateKey() string {
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return `{"error":"` + err.Error() + `"}`
	}
	addr := address.AddrForKey(pub)
	out := map[string]string{
		"privateKey": hex.EncodeToString(priv),
		"publicKey":  hex.EncodeToString(pub),
		"address":    net.IP(addr[:]).String(),
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// SummaryForPrivateKey derives the public key and address from a private key.
func SummaryForPrivateKey(privateKeyHex string) string {
	priv, err := parsePrivateKey(privateKeyHex)
	if err != nil {
		return `{"error":"` + err.Error() + `"}`
	}
	pub := priv.Public().(ed25519.PublicKey)
	addr := address.AddrForKey(pub)
	snet := address.SubnetForKey(pub)
	subnetIP := append(snet[:], 0, 0, 0, 0, 0, 0, 0, 0)
	out := map[string]string{
		"privateKey": hex.EncodeToString(priv),
		"publicKey":  hex.EncodeToString(pub),
		"address":    net.IP(addr[:]).String(),
		"subnet":     net.IP(subnetIP).String() + "/64",
	}
	b, _ := json.Marshal(out)
	return string(b)
}

func parsePrivateKey(h string) (ed25519.PrivateKey, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(h))
	if err != nil {
		return nil, fmt.Errorf("private key is not hex: %w", err)
	}
	switch len(raw) {
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	default:
		return nil, fmt.Errorf("unexpected private key length %d", len(raw))
	}
}

// Start brings the node up with the given configuration JSON:
//
//	{"privateKey":"..","peers":["tls://host:port"],"mtu":1280}
//
// An empty private key generates a new identity, which is only useful for the
// probe node; the app always passes a persisted key.
func (n *Node) Start(cfgJSON string) error {
	n.mu.Lock()
	if n.running {
		n.mu.Unlock()
		return errors.New("node is already running")
	}
	n.mu.Unlock()

	var sc startConfig
	if strings.TrimSpace(cfgJSON) == "" {
		sc = startConfig{}
	} else if err := json.Unmarshal([]byte(cfgJSON), &sc); err != nil {
		return fmt.Errorf("bad start config: %w", err)
	}

	var priv ed25519.PrivateKey
	var err error
	if strings.TrimSpace(sc.PrivateKey) == "" {
		_, priv, err = ed25519.GenerateKey(nil)
	} else {
		priv, err = parsePrivateKey(sc.PrivateKey)
	}
	if err != nil {
		return err
	}

	mtu := sc.MTU
	if mtu < 1280 {
		mtu = 1280
	}

	nc := config.GenerateConfig()
	nc.PrivateKey = config.KeyBytes(priv)
	if err := nc.GenerateSelfSignedCertificate(); err != nil {
		return fmt.Errorf("could not build the node certificate: %w", err)
	}
	// A phone is a leaf node: it never listens, never runs the admin socket and
	// never advertises over multicast. Android blocks the multicast traffic and
	// the node is meant to reach the network through the chosen peers only.
	nc.IfName = "none"
	nc.Listen = []string{}
	nc.AdminListen = "none"
	nc.MulticastInterfaces = nil
	nc.Peers = nil
	nc.IfMTU = uint64(mtu)
	nc.NodeInfo = map[string]any{
		"name":     "Y-Node",
		"platform": "android",
	}

	opts := []core.SetupOption{
		core.NodeInfo(nc.NodeInfo),
		core.NodeInfoPrivacy(false),
		core.PeerFilter(func(ip net.IP) bool {
			// Never peer with an address inside the tunnel itself.
			return !yggRange.Contains(ip)
		}),
	}

	c, err := core.New(nc.Certificate, n.logger, opts...)
	if err != nil {
		return fmt.Errorf("could not start the node: %w", err)
	}

	rwc := ipv6rwc.NewReadWriteCloser(c)
	if max := int(rwc.MaxMTU()); mtu > max {
		mtu = max
	}
	rwc.SetMTU(uint64(mtu))

	added := 0
	for _, uri := range sc.Peers {
		if err := addPeer(c, uri); err != nil {
			n.logger.emit("warn", "peer %q was not added: %v", uri, err)
			continue
		}
		added++
	}

	pub := c.PublicKey()
	addr := address.AddrForKey(pub)
	snet := address.SubnetForKey(pub)
	subnetIP := append(snet[:], 0, 0, 0, 0, 0, 0, 0, 0)

	n.mu.Lock()
	n.core = c
	n.rwc = rwc
	n.mtu = mtu
	n.running = true
	n.address = net.IP(addr[:]).String()
	n.subnet = net.IP(subnetIP).String() + "/64"
	n.pubkey = hex.EncodeToString(pub)
	n.mu.Unlock()

	// The stack the node uses for its own DNS and HTTP requests. It is a
	// convenience, not part of the tunnel, so a failure only disables the DNS
	// health check and the web-directory browser.
	inner, ierr := newInternalNet(mtu, n.address, func(packet []byte) error {
		_, werr := rwc.Write(packet)
		return werr
	}, n.logger)
	if ierr != nil {
		n.logger.emit("warn", "internal network is unavailable: %v", ierr)
	} else {
		n.mu.Lock()
		n.inner = inner
		n.mu.Unlock()
	}

	n.logger.emit("info", "node started: address=%s peers=%d mtu=%d", net.IP(addr[:]).String(), added, mtu)
	return nil
}

func addPeer(c *core.Core, uri string) error {
	uri = strings.TrimSpace(uri)
	if uri == "" {
		return errors.New("empty peer URI")
	}
	if len(uri) > maxPeerURILength {
		return errors.New("peer URI is too long")
	}
	u, err := url.Parse(uri)
	if err != nil {
		return fmt.Errorf("bad peer URI: %w", err)
	}
	if u.Host == "" {
		return errors.New("peer URI has no host")
	}
	if ip := net.ParseIP(u.Hostname()); ip != nil && yggRange.Contains(ip) {
		return errors.New("peer is inside the Yggdrasil range")
	}
	return c.AddPeer(u, "")
}

// Stop shuts the node down and releases the goroutines. It unblocks a pending
// Recv, so the data path thread can exit.
func (n *Node) Stop() {
	n.mu.Lock()
	wasRunning := n.running
	n.running = false
	rwc := n.rwc
	tun := n.tun
	n.rwc = nil
	n.tun = nil
	n.exit = nil
	n.dns = nil
	n.core = nil
	n.protector = nil
	n.writer = nil
	n.tunV4 = nil
	n.tunGen++
	n.mu.Unlock()

	if tun != nil {
		tun.stop()
	}
	n.mu.Lock()
	inner := n.inner
	n.inner = nil
	n.mu.Unlock()
	if inner != nil {
		inner.stop()
	}
	if rwc != nil {
		// Close stops the core and unblocks ReadFrom.
		_ = rwc.Close()
	}
	if wasRunning {
		n.logger.emit("info", "node stopped")
	}
}

// IsRunning reports whether the node is up.
func (n *Node) IsRunning() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.running
}

// Send hands one fully formed IPv6 packet to the network.
func (n *Node) Send(p []byte, length int) error {
	n.mu.Lock()
	rwc := n.rwc
	running := n.running
	n.mu.Unlock()
	if !running || rwc == nil {
		return errors.New("node is not running")
	}
	if length < 0 || length > len(p) {
		return fmt.Errorf("bad packet length %d", length)
	}
	if length == 0 {
		return nil
	}
	_, err := rwc.Write(p[:length])
	// A rejected packet is normal: the core drops link-local traffic and the
	// duplicate-address-detection probes the kernel sends from `::` right after
	// the interface comes up. The caller logs it and keeps the data path alive.
	return err
}

// Recv blocks until one IPv6 packet arrives and copies it into buf. It returns
// the number of bytes written. The call unblocks with an error after Stop.
//
// Packets that belong to the node's own connections (the DNS check and the web
// directory) are consumed here: they never reach the TUN, where no socket of the
// kernel is waiting for them.
func (n *Node) Recv(buf []byte) (int, error) {
	n.mu.Lock()
	rwc := n.rwc
	running := n.running
	n.mu.Unlock()
	if !running || rwc == nil {
		return 0, errors.New("node is not running")
	}
	for {
		read, err := rwc.Read(buf)
		if err != nil {
			return 0, err
		}
		n.mu.Lock()
		stillRunning := n.running
		n.mu.Unlock()
		if !stillRunning {
			return 0, errors.New("node stopped")
		}
		if read <= 0 {
			continue
		}
		if inner := n.internal(); inner != nil && inner.owns(buf[:read]) {
			inner.inject(buf[:read])
			continue
		}
		return read, nil
	}
}

// internal returns the userspace stack of the node's own connections.
func (n *Node) internal() *internalNet {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.running {
		return nil
	}
	return n.inner
}

// tunSettings are the pieces the Kotlin side provides to the forwarder. They
// are kept so the stack can be rebuilt when the exit configuration changes.
type tunSettings struct {
	protector Protector
	writer    PacketWriter
	mtu       int
	v4        net.IP
}

// EnableTun2Socks starts the userspace TCP/IP stack that carries ordinary
// internet traffic for the apps of the VPN allow list. Their sockets are bound
// to the VPN network by Android and never fall back to the real one, so the
// tunnel has to forward IPv4 itself. protector and writer are implemented on
// the Kotlin side: the first protects an upstream socket, the second writes a
// packet back into the tunnel.
//
// exitConfigJSON is the exit node configuration: when it enables an exit, every
// public TCP connection is sent through SOCKS5 over Yggdrasil. Private and LAN
// destinations always stay on the phone's own network.
func (n *Node) EnableTun2Socks(protector Protector, writer PacketWriter, mtu int, v4Address string, exitConfigJSON string) error {
	n.mu.Lock()
	running := n.running
	previous := n.tun
	raw := n.exitRaw
	if strings.TrimSpace(exitConfigJSON) != "" {
		raw = exitConfigJSON
	}
	n.tun = nil
	n.exit = nil
	n.dns = nil
	n.tunGen++
	gen := n.tunGen
	n.mu.Unlock()

	if previous != nil {
		previous.stop()
	}
	if !running {
		return errors.New("node is not running")
	}

	var v4 net.IP
	if strings.TrimSpace(v4Address) != "" {
		parsed := net.ParseIP(strings.TrimSpace(v4Address))
		if parsed == nil {
			return fmt.Errorf("bad tun2socks address %q", v4Address)
		}
		v4 = parsed
	}

	settings := tunSettings{protector: protector, writer: writer, mtu: mtu, v4: v4}
	t, manager, router, err := n.buildForwarder(settings, raw)
	if err != nil {
		return err
	}

	n.mu.Lock()
	if !n.running || n.tunGen != gen {
		n.mu.Unlock()
		t.stop()
		return errors.New("node stopped while tun2socks was starting")
	}
	n.tun = t
	n.exit = manager
	n.dns = router
	n.exitRaw = raw
	n.protector = protector
	n.writer = writer
	n.tunMTU = mtu
	n.tunV4 = v4
	n.mu.Unlock()

	n.logger.emit("info", "tun2socks started: mtu=%d address=%s ipv6=%v", mtu, v4, manager.carriesIPv6())
	return nil
}

// buildForwarder assembles the exit manager, the DNS router and the forwarding
// stack for one configuration. The node lock is not held while the stack is
// built, because the constructor starts goroutines.
func (n *Node) buildForwarder(settings tunSettings, rawExit string) (*tun2socks, *exitManager, *dnsRouter, error) {
	n.mu.Lock()
	inner := n.inner
	n.mu.Unlock()

	direct := newDirectDialer(settings.protector, tun2socksDialTimeout)
	manager, err := newExitManager(rawExit, inner, direct, n.logger)
	if err != nil {
		return nil, nil, nil, err
	}
	router := newDNSRouter(manager, inner, direct, n.logger)
	t, err := newTun2Socks(settings.mtu, settings.v4, settings.writer, manager, router, n.logger)
	if err != nil {
		return nil, nil, nil, err
	}
	return t, manager, router, nil
}

// SetExitConfig applies a new exit configuration. When the forwarder is
// running it is rebuilt with the new profile list, so a failover order change
// takes effect immediately; existing forwarded connections are reset and the
// apps reconnect.
func (n *Node) SetExitConfig(exitConfigJSON string) error {
	if _, err := parseExitConfig(exitConfigJSON); err != nil {
		return err
	}

	n.mu.Lock()
	previous := n.tun
	running := n.running
	settings := tunSettings{
		protector: n.protector,
		writer:    n.writer,
		mtu:       n.tunMTU,
		v4:        n.tunV4,
	}
	n.exitRaw = exitConfigJSON
	n.tun = nil
	n.exit = nil
	n.dns = nil
	n.tunGen++
	gen := n.tunGen
	n.mu.Unlock()

	if previous == nil || !running {
		return nil
	}
	previous.stop()

	t, manager, router, err := n.buildForwarder(settings, exitConfigJSON)
	if err != nil {
		n.logger.emit("warn", "could not rebuild tun2socks: %v", err)
		return err
	}

	n.mu.Lock()
	if !n.running || n.tunGen != gen {
		n.mu.Unlock()
		t.stop()
		return errors.New("the forwarder was disabled while the exit configuration was applied")
	}
	n.tun = t
	n.exit = manager
	n.dns = router
	n.mu.Unlock()
	n.logger.emit("info", "tun2socks restarted with a new exit configuration (ipv6=%v)", manager.carriesIPv6())
	return nil
}

// GetExitStatusJSON returns the current exit state, the profile health and the
// failover list as JSON.
func (n *Node) GetExitStatusJSON() string {
	n.mu.Lock()
	manager := n.exit
	n.mu.Unlock()
	if manager == nil {
		return `{"enabled":false,"state":"off","profiles":[]}`
	}
	return manager.statusJSON()
}

// CheckExitProfiles asks every exit profile's status API whether this node is
// allowed. The requests go through Yggdrasil, so a successful check also proves
// that the exit is reachable. The call blocks for up to timeoutMs.
func (n *Node) CheckExitProfiles(timeoutMs int) string {
	n.mu.Lock()
	manager := n.exit
	n.mu.Unlock()
	if manager == nil {
		return `{"enabled":false,"state":"off","profiles":[]}`
	}
	if timeoutMs < 1000 {
		timeoutMs = 8000
	}
	if timeoutMs > 30000 {
		timeoutMs = 30000
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	return manager.checkAll(ctx)
}

// RegisterExit redeems an invite token on one exit profile. Registration needs
// a live tunnel: the exit authenticates the source address of the request, and
// that address only exists while the node is connected.
func (n *Node) RegisterExit(profileID string, invite string, deviceName string, appVersion string) string {
	n.mu.Lock()
	manager := n.exit
	address := n.address
	publicKey := n.pubkey
	running := n.running
	n.mu.Unlock()
	if !running || manager == nil {
		return `{"ok":false,"error":"vpn_not_running"}`
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	result := manager.register(ctx, profileID, invite, address, publicKey, deviceName, appVersion)
	b, err := json.Marshal(result)
	if err != nil {
		return `{"ok":false,"error":"encode_failed"}`
	}
	return string(b)
}

// GetExitDNSAddress returns the address the tunnel hands to Android as its
// resolver while an exit node is enabled.
func (n *Node) GetExitDNSAddress() string {
	return dnsVIP
}

// DisableTun2Socks stops the forwarding stack. Safe to call when it is not
// running.
func (n *Node) DisableTun2Socks() {
	n.mu.Lock()
	t := n.tun
	n.tun = nil
	n.exit = nil
	n.dns = nil
	n.tunGen++
	n.mu.Unlock()
	if t != nil {
		t.stop()
		n.logger.emit("info", "tun2socks stopped")
	}
}

// SendToStack hands one packet read from the tunnel to the userspace stack.
// Packets addressed into Yggdrasil never come here: they go to Send.
func (n *Node) SendToStack(packet []byte, length int) error {
	if length < 0 || length > len(packet) {
		return fmt.Errorf("bad packet length %d", length)
	}
	if length == 0 {
		return nil
	}
	n.mu.Lock()
	t := n.tun
	n.mu.Unlock()
	if t == nil {
		return errors.New("tun2socks is not running")
	}
	return t.inject(packet[:length])
}

// AddPeer adds a persistent peer.
func (n *Node) AddPeer(uri string) error {
	n.mu.Lock()
	c := n.core
	running := n.running
	n.mu.Unlock()
	if !running || c == nil {
		return errors.New("node is not running")
	}
	return addPeer(c, uri)
}

// RemovePeer drops a persistent peer and disconnects it.
func (n *Node) RemovePeer(uri string) error {
	n.mu.Lock()
	c := n.core
	running := n.running
	n.mu.Unlock()
	if !running || c == nil {
		return errors.New("node is not running")
	}
	u, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return fmt.Errorf("bad peer URI: %w", err)
	}
	return c.RemovePeer(u, "")
}

// SetPeers makes the running peer list match the given JSON array exactly.
// Peers that are no longer wanted are removed, new ones are added.
func (n *Node) SetPeers(urisJSON string) error {
	var wanted []string
	if err := json.Unmarshal([]byte(urisJSON), &wanted); err != nil {
		return fmt.Errorf("bad peer list: %w", err)
	}

	n.mu.Lock()
	c := n.core
	running := n.running
	n.mu.Unlock()
	if !running || c == nil {
		return errors.New("node is not running")
	}

	want := make(map[string]struct{}, len(wanted))
	for _, uri := range wanted {
		u := strings.TrimSpace(uri)
		if u != "" {
			want[u] = struct{}{}
		}
	}

	var errs []string
	for _, p := range c.GetPeers() {
		if _, keep := want[p.URI]; keep {
			continue
		}
		if u, err := url.Parse(p.URI); err == nil {
			if err := c.RemovePeer(u, ""); err != nil {
				errs = append(errs, fmt.Sprintf("remove %s: %v", p.URI, err))
			}
		}
	}

	have := make(map[string]struct{})
	for _, p := range c.GetPeers() {
		have[p.URI] = struct{}{}
	}
	for uri := range want {
		if _, ok := have[uri]; ok {
			continue
		}
		if err := addPeer(c, uri); err != nil {
			errs = append(errs, fmt.Sprintf("add %s: %v", uri, err))
		}
	}

	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// RetryPeersNow makes every configured peer dial again immediately.
func (n *Node) RetryPeersNow() {
	n.mu.Lock()
	c := n.core
	running := n.running
	n.mu.Unlock()
	if running && c != nil {
		c.RetryPeersNow()
	}
}

// GetPeersJSON returns the current peer states as a JSON array.
func (n *Node) GetPeersJSON() string {
	n.mu.Lock()
	c := n.core
	running := n.running
	n.mu.Unlock()
	if !running || c == nil {
		return "[]"
	}

	peers := c.GetPeers()
	out := make([]PeerStatus, 0, len(peers))
	for _, p := range peers {
		st := PeerStatus{
			URI:           p.URI,
			Up:            p.Up,
			Inbound:       p.Inbound,
			RXBytes:       p.RXBytes,
			TXBytes:       p.TXBytes,
			LatencyMs:     float64(p.Latency.Microseconds()) / 1000.0,
			Cost:          p.Cost,
			UptimeSeconds: p.Uptime.Seconds(),
		}
		if len(p.Key) == ed25519.PublicKeySize {
			st.Key = hex.EncodeToString(p.Key)
			if a := address.AddrForKey(p.Key); a != nil {
				st.IP = net.IP(a[:]).String()
			}
		}
		if p.LastError != nil {
			st.LastError = p.LastError.Error()
		}
		if !p.LastErrorTime.IsZero() {
			st.LastErrorUnix = p.LastErrorTime.Unix()
		}
		out = append(out, st)
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

// GetAddress returns the node IPv6 address.
func (n *Node) GetAddress() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.address
}

// GetSubnet returns the routed /64 subnet of the node.
func (n *Node) GetSubnet() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.subnet
}

// GetPublicKey returns the node public key in hex.
func (n *Node) GetPublicKey() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.pubkey
}

// GetMTU returns the MTU the node was started with.
func (n *Node) GetMTU() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.mtu
}

// GetVersion returns the Yggdrasil build version. The upstream package only
// knows the version when the binary is built from a git checkout, which is not
// the case for a gomobile library, so the pinned version is used as a fallback.
func GetVersion() string {
	if v := version.BuildVersion(); v != "" && v != "unknown" {
		return v
	}
	return yggVersion
}

// ProbeResult is one row of a probe round.
type ProbeResult struct {
	URI       string  `json:"uri"`
	Up        bool    `json:"up"`
	LatencyMs float64 `json:"latencyMs"`
	Key       string  `json:"key"`
	IP        string  `json:"ip"`
	Error     string  `json:"error"`
	ElapsedMs int64   `json:"elapsedMs"`
}

// ProbePeers dials every URI in the JSON array with a temporary node and reports
// which ones completed the Yggdrasil handshake and how long the protocol took to
// answer. The caller runs this in rounds of five and tops the list up.
//
// timeoutMs bounds the whole round. The temporary node is always stopped before
// the call returns.
func ProbePeers(urisJSON string, timeoutMs int, logger Logger) string {
	var uris []string
	if err := json.Unmarshal([]byte(urisJSON), &uris); err != nil {
		b, _ := json.Marshal([]ProbeResult{{Error: "bad probe list: " + err.Error()}})
		return string(b)
	}
	if len(uris) == 0 {
		return "[]"
	}
	if timeoutMs < 1000 {
		timeoutMs = 1000
	}
	if timeoutMs > 30000 {
		timeoutMs = 30000
	}

	gl := &goLogger{}
	gl.setTarget(logger)
	gl.emit("info", "probing %d peer(s), timeout %d ms", len(uris), timeoutMs)

	nc := config.GenerateConfig()
	nc.IfName = "none"
	nc.Listen = []string{}
	nc.AdminListen = "none"
	nc.MulticastInterfaces = nil
	nc.Peers = nil

	c, err := core.New(nc.Certificate, gl, core.PeerFilter(func(ip net.IP) bool {
		return !yggRange.Contains(ip)
	}))
	if err != nil {
		b, _ := json.Marshal([]ProbeResult{{Error: "could not start the probe node: " + err.Error()}})
		return string(b)
	}
	defer c.Stop()

	started := time.Now()
	attempted := make([]string, 0, len(uris))
	for _, uri := range uris {
		u := strings.TrimSpace(uri)
		if u == "" {
			continue
		}
		parsed, perr := url.Parse(u)
		if perr != nil || parsed.Host == "" {
			continue
		}
		if ip := net.ParseIP(parsed.Hostname()); ip != nil && yggRange.Contains(ip) {
			continue
		}
		if err := c.CallPeer(parsed, ""); err != nil {
			gl.emit("warn", "probe %q could not be started: %v", u, err)
			continue
		}
		attempted = append(attempted, u)
	}

	deadline := time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)
	best := make(map[string]PeerStatus, len(attempted))
	for {
		for _, p := range c.GetPeers() {
			prev, seen := best[p.URI]
			cur := PeerStatus{
				URI:       p.URI,
				Up:        p.Up,
				LatencyMs: float64(p.Latency.Microseconds()) / 1000.0,
			}
			if len(p.Key) == ed25519.PublicKeySize {
				cur.Key = hex.EncodeToString(p.Key)
				if a := address.AddrForKey(p.Key); a != nil {
					cur.IP = net.IP(a[:]).String()
				}
			}
			if p.LastError != nil {
				cur.LastError = p.LastError.Error()
			}
			if !seen || (cur.Up && !prev.Up) || (cur.Up && cur.LatencyMs > 0 && prev.LatencyMs == 0) {
				best[p.URI] = cur
			}
		}

		done := true
		for _, uri := range attempted {
			st, ok := best[uri]
			if !ok || !st.Up || st.LatencyMs <= 0 {
				done = false
				break
			}
		}
		if done || time.Now().After(deadline) {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}

	elapsed := time.Since(started).Milliseconds()
	out := make([]ProbeResult, 0, len(attempted))
	for _, uri := range attempted {
		st := best[uri]
		r := ProbeResult{
			URI:       uri,
			Up:        st.Up && st.LatencyMs > 0,
			LatencyMs: st.LatencyMs,
			Key:       st.Key,
			IP:        st.IP,
			Error:     st.LastError,
			ElapsedMs: elapsed,
		}
		if r.Up {
			r.Error = ""
		} else if r.Error == "" {
			r.Error = "no handshake within the timeout"
		}
		out = append(out, r)
	}

	gl.emit("info", "probe round finished in %d ms", elapsed)
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}
