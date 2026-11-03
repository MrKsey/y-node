package yggnode

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/quic-go/quic-go"
)

// The self-check of the UDP relay. The exit node carries UDP only when its
// SOCKS5 listener accepts UDP ASSOCIATE, the relay socket can reach the
// destination and the answer comes back through the same association. A user
// cannot see any of that from the traffic counters, so the app runs two real
// requests instead: a DNS query through the exit and a QUIC handshake.
const (
	// udpProbeName is resolved through the exit and then used as the QUIC
	// server name. Cloudflare answers over h3 on every anycast address.
	udpProbeName = "cloudflare.com"

	udpProbeQUICPort = "443"
	udpProbeDNSPort  = "53"

	udpProbeTimeoutMin = 3000
	udpProbeTimeoutMax = 25000
)

// udpProbeStage is one half of the check.
type udpProbeStage struct {
	OK        bool    `json:"ok"`
	LatencyMs float64 `json:"latencyMs"`
	Target    string  `json:"target,omitempty"`
	Server    string  `json:"server,omitempty"`
	Version   string  `json:"version,omitempty"`
	Error     string  `json:"error,omitempty"`
}

// udpProbeResult is the JSON the UI shows after the check.
type udpProbeResult struct {
	OK    bool   `json:"ok"`
	State string `json:"state"`
	// Profile is the exit that carried the probe, when one answered.
	Profile string        `json:"profile,omitempty"`
	UDP     udpProbeStage `json:"udp"`
	QUIC    udpProbeStage `json:"quic"`
	// DatagramsIn/Out are the traffic deltas of the check itself: they prove
	// the datagrams really went through the exit and not around it.
	DatagramsIn  uint64 `json:"datagramsIn"`
	DatagramsOut uint64 `json:"datagramsOut"`
	DurationMs   int64  `json:"durationMs"`
	Error        string `json:"error,omitempty"`
}

// TestExitUDP checks the UDP relay of the active exit: it resolves a public
// name with a DNS query carried by the exit, then performs a QUIC handshake to
// the resolved address. Both steps go through the same SOCKS5 association the
// apps use, so a success proves DNS and QUIC work end to end.
//
// The call blocks for up to timeoutMs and returns JSON shaped as udpProbeResult.
func (n *Node) TestExitUDP(timeoutMs int) string {
	n.mu.Lock()
	manager := n.exit
	running := n.running
	n.mu.Unlock()

	if !running || manager == nil {
		return encodeUDPProbe(udpProbeResult{
			State: "off",
			Error: "the exit node is not enabled",
		})
	}
	cfg := manager.config()
	if !cfg.Enabled || len(cfg.Profiles) == 0 {
		return encodeUDPProbe(udpProbeResult{
			State: "off",
			Error: "the exit node is not enabled",
		})
	}
	if !cfg.udpEnabled() {
		return encodeUDPProbe(udpProbeResult{
			State: "disabled",
			Error: "UDP through the exit node is turned off",
		})
	}

	if timeoutMs < udpProbeTimeoutMin {
		timeoutMs = udpProbeTimeoutMin
	}
	if timeoutMs > udpProbeTimeoutMax {
		timeoutMs = udpProbeTimeoutMax
	}

	started := time.Now()
	inBefore, outBefore := manager.udpIn.Load(), manager.udpOut.Load()

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	result := udpProbeResult{State: "ok"}
	result.UDP, result.QUIC = manager.probeUDP(ctx, cfg.DNS)

	result.DatagramsIn = manager.udpIn.Load() - inBefore
	result.DatagramsOut = manager.udpOut.Load() - outBefore
	result.DurationMs = time.Since(started).Milliseconds()
	if status := manager.udpStatus(); status.ProfileName != "" {
		result.Profile = status.ProfileName
	}

	switch {
	case result.UDP.OK && result.QUIC.OK:
		result.OK = true
		result.State = "ok"
	case !result.UDP.OK:
		result.State = "udp_failed"
		result.Error = result.UDP.Error
	default:
		result.State = "quic_failed"
		result.Error = result.QUIC.Error
	}
	return encodeUDPProbe(result)
}

func encodeUDPProbe(result udpProbeResult) string {
	raw, err := json.Marshal(result)
	if err != nil {
		return `{"ok":false,"state":"error","error":"encode_failed"}`
	}
	return string(raw)
}

// probeUDP runs the two stages. The QUIC stage needs an address, so it only
// runs when the DNS stage produced one.
func (m *exitManager) probeUDP(ctx context.Context, servers []string) (udpProbeStage, udpProbeStage) {
	var udpStage, quicStage udpProbeStage
	if len(servers) == 0 {
		servers = []string{"1.1.1.1"}
	}

	var address net.IP
	var lastErr error
	for _, server := range servers {
		if ctx.Err() != nil {
			break
		}
		stageCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
		ip, latency, err := m.probeDNS(stageCtx, server)
		cancel()
		if err != nil {
			lastErr = err
			m.log.emit("debug", "udp check: DNS %s: %v", server, err)
			continue
		}
		udpStage = udpProbeStage{
			OK:        true,
			LatencyMs: latency,
			Target:    udpProbeName,
			Server:    net.JoinHostPort(server, udpProbeDNSPort),
		}
		address = ip
		break
	}
	if !udpStage.OK {
		udpStage.Target = udpProbeName
		udpStage.Error = describeUDPError(lastErr)
		if lastErr == nil {
			udpStage.Error = "the check timed out"
		}
		quicStage.Error = "skipped: the DNS stage did not produce an address"
		return udpStage, quicStage
	}

	quicCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
	defer cancel()
	version, latency, err := m.probeQUIC(quicCtx, address)
	quicStage.Target = net.JoinHostPort(address.String(), udpProbeQUICPort)
	if err != nil {
		quicStage.Error = describeUDPError(err)
		m.log.emit("debug", "udp check: QUIC %s: %v", address, err)
		return udpStage, quicStage
	}
	quicStage.OK = true
	quicStage.LatencyMs = latency
	quicStage.Version = version
	return udpStage, quicStage
}

// describeUDPError turns the errors of the relay into something a user can act
// on. The exit drops the control connection without a SOCKS5 reply when its
// connection limit is reached, so an EOF before the greeting is reported as a
// possible limit rather than a mysterious empty answer.
func describeUDPError(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "no answer within the timeout"
	}
	if errors.Is(err, errUDPDisabled) {
		return "UDP through the exit node is turned off"
	}
	if errors.Is(err, errExitDropped) {
		return "the exit dropped the connection before the SOCKS5 greeting (connection limit?)"
	}
	return err.Error()
}

// probeDNS resolves udpProbeName through the exit and returns the first A
// record. The answer is checked against the transaction id, because a shared
// relay can deliver the answer of another query.
func (m *exitManager) probeDNS(ctx context.Context, server string) (net.IP, float64, error) {
	var id [2]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, 0, err
	}
	query := buildDNSQueryA(binary.BigEndian.Uint16(id[:]), udpProbeName)
	address := net.JoinHostPort(server, udpProbeDNSPort)

	started := time.Now()
	response, err := queryDNSDatagram(ctx, func(ctx context.Context, _, address string) (net.Conn, error) {
		return m.dialUDP(ctx, "udp", address)
	}, address, query)
	if err != nil {
		return nil, 0, err
	}
	latency := float64(time.Since(started).Microseconds()) / 1000.0

	ip := firstDNSAddress(response, binary.BigEndian.Uint16(id[:]))
	if ip == nil {
		return nil, 0, fmt.Errorf("the exit resolver returned no address for %s", udpProbeName)
	}
	return ip, latency, nil
}

// probeQUIC performs a real QUIC handshake with the resolved address. The
// datagrams travel through the same UDP association the apps use.
func (m *exitManager) probeQUIC(ctx context.Context, ip net.IP) (string, float64, error) {
	remote := &net.UDPAddr{IP: ip, Port: 443}
	flow, err := m.dialUDP(ctx, "udp", remote.String())
	if err != nil {
		return "", 0, err
	}
	packetConn := &flowPacketConn{conn: flow}

	transport := &quic.Transport{Conn: packetConn}
	defer transport.Close()
	defer packetConn.Close()

	tlsConfig := &tls.Config{
		ServerName: udpProbeName,
		NextProtos: []string{"h3"},
		MinVersion: tls.VersionTLS13,
	}
	quicConfig := &quic.Config{
		HandshakeIdleTimeout: 6 * time.Second,
		MaxIdleTimeout:       6 * time.Second,
	}

	started := time.Now()
	conn, err := transport.Dial(ctx, remote, tlsConfig, quicConfig)
	if err != nil {
		return "", 0, err
	}
	latency := float64(time.Since(started).Microseconds()) / 1000.0
	version := conn.ConnectionState().Version.String()
	_ = conn.CloseWithError(0, "probe done")
	return version, latency, nil
}

// flowPacketConn adapts one connected udpFlowConn to net.PacketConn, which is
// what quic-go expects. The flow has a single destination, so the address of
// every write is ignored.
type flowPacketConn struct {
	conn net.Conn
}

var _ net.PacketConn = (*flowPacketConn)(nil)

func (c *flowPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, err := c.conn.Read(p)
	if err != nil {
		return n, nil, err
	}
	return n, c.conn.RemoteAddr(), nil
}

func (c *flowPacketConn) WriteTo(p []byte, _ net.Addr) (int, error) {
	return c.conn.Write(p)
}

func (c *flowPacketConn) Close() error                       { return c.conn.Close() }
func (c *flowPacketConn) LocalAddr() net.Addr                { return c.conn.LocalAddr() }
func (c *flowPacketConn) SetDeadline(t time.Time) error      { return c.conn.SetDeadline(t) }
func (c *flowPacketConn) SetReadDeadline(t time.Time) error  { return c.conn.SetReadDeadline(t) }
func (c *flowPacketConn) SetWriteDeadline(t time.Time) error { return c.conn.SetWriteDeadline(t) }

// buildDNSQueryA encodes one recursive A query.
func buildDNSQueryA(id uint16, name string) []byte {
	return buildDNSQuery(id, name, dnsTypeA)
}

// buildDNSQueryAAAA encodes one recursive AAAA query.
func buildDNSQueryAAAA(id uint16, name string) []byte {
	return buildDNSQuery(id, name, dnsTypeAAAA)
}

// buildDNSQuery encodes one recursive query of the given record type.
func buildDNSQuery(id uint16, name string, recordType uint16) []byte {
	query := make([]byte, 12, 12+len(name)+6)
	binary.BigEndian.PutUint16(query[0:2], id)
	binary.BigEndian.PutUint16(query[2:4], 0x0100) // recursion desired
	binary.BigEndian.PutUint16(query[4:6], 1)      // one question
	for _, label := range strings.Split(strings.TrimSuffix(name, "."), ".") {
		if label == "" || len(label) > 63 {
			continue
		}
		query = append(query, byte(len(label)))
		query = append(query, label...)
	}
	query = append(query, 0) // root label
	query = binary.BigEndian.AppendUint16(query, recordType)
	query = binary.BigEndian.AppendUint16(query, 1)
	return query
}

const (
	dnsTypeA    = 1
	dnsTypeAAAA = 28
)

// firstDNSAddress returns the first A record of an answer with the expected
// transaction id, or nil.
func firstDNSAddress(msg []byte, id uint16) net.IP {
	return firstDNSRecord(msg, id, dnsTypeA, 4)
}

// firstDNSAAAA returns the first AAAA record of an answer with the expected
// transaction id, or nil.
func firstDNSAAAA(msg []byte, id uint16) net.IP {
	return firstDNSRecord(msg, id, dnsTypeAAAA, 16)
}

// firstDNSRecord returns the first record of the wanted type and data length.
func firstDNSRecord(msg []byte, id, recordType uint16, length int) net.IP {
	if len(msg) < 12 || binary.BigEndian.Uint16(msg[0:2]) != id {
		return nil
	}
	flags := binary.BigEndian.Uint16(msg[2:4])
	if flags&0x8000 == 0 || int(flags&0x000F) != 0 {
		return nil
	}
	questions := int(binary.BigEndian.Uint16(msg[4:6]))
	answers := int(binary.BigEndian.Uint16(msg[6:8]))
	offset := 12
	for i := 0; i < questions; i++ {
		next, ok := skipDNSName(msg, offset)
		if !ok || next+4 > len(msg) {
			return nil
		}
		offset = next + 4
	}
	for i := 0; i < answers; i++ {
		next, ok := skipDNSName(msg, offset)
		if !ok || next+10 > len(msg) {
			return nil
		}
		answerType := binary.BigEndian.Uint16(msg[next : next+2])
		answerLength := int(binary.BigEndian.Uint16(msg[next+8 : next+10]))
		data := next + 10
		if data+answerLength > len(msg) {
			return nil
		}
		if answerType == recordType && answerLength == length {
			return net.IP(append([]byte(nil), msg[data:data+length]...))
		}
		offset = data + answerLength
	}
	return nil
}
