package yggnode

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"time"
)

// The self-check of IPv6 through the exit node. A phone without an IPv6 uplink
// cannot reach a global IPv6 destination on its own, so a success proves the
// exit really carries the traffic. Both stages use the same paths the apps use:
// TCP goes through a SOCKS5 CONNECT with ATYP=4, UDP through the relay of the
// active association.
const (
	// ipv6ProbeAddress is a Cloudflare anycast address. Its certificate carries
	// the address as an IP SAN, so TLS passes without a name lookup — the exit
	// path only accepts addresses and a name would be resolved on the phone.
	ipv6ProbeAddress = "2606:4700:4700::1111"

	// ipv6ProbeName is asked for an AAAA record over UDP. The answer itself is
	// not used: the query proves the relay carries IPv6 datagrams both ways.
	ipv6ProbeName = "cloudflare.com"

	ipv6ProbeTLSPort = 443
	ipv6ProbeDNSPort = 53

	// ipv6TraceURL is the trace page of the public-IP balloon, over IPv6. Its
	// `ip=` line is the address the exit uses for IPv6.
	ipv6TraceURL = "https://[" + ipv6ProbeAddress + "]/cdn-cgi/trace"

	ipv6ProbeTimeoutMin = 3000
	ipv6ProbeTimeoutMax = 25000
)

// ipv6ProbeStage is one half of the check.
type ipv6ProbeStage struct {
	OK      bool    `json:"ok"`
	Skipped bool    `json:"skipped,omitempty"`
	Latency float64 `json:"latencyMs"`
	Target  string  `json:"target,omitempty"`
	// Address is the IPv6 address the exit used for the TCP stage.
	Address string `json:"address,omitempty"`
	Error   string `json:"error,omitempty"`
}

// ipv6ProbeResult is the JSON the UI shows after the check.
type ipv6ProbeResult struct {
	OK bool `json:"ok"`
	// State is `ok`, `off`, `tcp_failed` or `udp_failed`.
	State string `json:"state"`
	// Profile is the exit that carried the TCP stage, when one answered.
	Profile    string         `json:"profile,omitempty"`
	TCP        ipv6ProbeStage `json:"tcp"`
	UDP        ipv6ProbeStage `json:"udp"`
	DurationMs int64          `json:"durationMs"`
	Error      string         `json:"error,omitempty"`
}

// TestExitIPv6 checks IPv6 through the active exit: an HTTPS request to a
// literal IPv6 address (TCP, ATYP=4) and an AAAA query over the UDP relay.
// Neither stage falls back to a direct connection, so a success means the
// traffic really left through the exit.
//
// The call blocks for up to timeoutMs and returns JSON shaped as
// ipv6ProbeResult.
func (n *Node) TestExitIPv6(timeoutMs int) string {
	n.mu.Lock()
	manager := n.exit
	running := n.running
	n.mu.Unlock()

	if !running || manager == nil || !manager.enabled() {
		return encodeIPv6Probe(ipv6ProbeResult{
			State: "off",
			Error: "the exit node is not enabled",
		})
	}

	if timeoutMs < ipv6ProbeTimeoutMin {
		timeoutMs = ipv6ProbeTimeoutMin
	}
	if timeoutMs > ipv6ProbeTimeoutMax {
		timeoutMs = ipv6ProbeTimeoutMax
	}

	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()

	result := ipv6ProbeResult{State: "ok"}
	stage, profile, err := manager.probeIPv6TCP(ctx)
	result.TCP = stage
	result.Profile = profile
	if err != nil {
		result.TCP.Error = describeIPv6Error(err)
		result.State = "tcp_failed"
		result.Error = result.TCP.Error
		result.UDP = ipv6ProbeStage{
			Skipped: true,
			Target:  net.JoinHostPort(ipv6ProbeAddress, strconv.Itoa(ipv6ProbeDNSPort)),
			Error:   "skipped: TCP over IPv6 did not work",
		}
		result.DurationMs = time.Since(started).Milliseconds()
		return encodeIPv6Probe(result)
	}

	if manager.config().udpEnabled() {
		udpStage, uerr := manager.probeIPv6UDP(ctx)
		result.UDP = udpStage
		if uerr != nil {
			result.UDP.Error = describeIPv6Error(uerr)
			result.State = "udp_failed"
			result.Error = result.UDP.Error
		}
	} else {
		// IPv6 over TCP already works; the UDP half is a bonus, not a
		// requirement, so the check does not fail when the user turned UDP off.
		result.UDP = ipv6ProbeStage{
			Skipped: true,
			Target:  net.JoinHostPort(ipv6ProbeAddress, strconv.Itoa(ipv6ProbeDNSPort)),
			Error:   "skipped: UDP through the exit is off",
		}
	}
	if result.Profile == "" {
		result.Profile = manager.udpStatus().ProfileName
	}
	result.OK = result.State == "ok"
	result.DurationMs = time.Since(started).Milliseconds()
	return encodeIPv6Probe(result)
}

func encodeIPv6Probe(result ipv6ProbeResult) string {
	raw, err := json.Marshal(result)
	if err != nil {
		return `{"ok":false,"state":"error","error":"encode_failed"}`
	}
	return string(raw)
}

// probeIPv6TCP opens a TLS connection to the literal IPv6 address through one
// exit profile and reads the trace page. Profiles are tried in order, but a
// failure never falls back to a direct connection: that would hide a broken
// exit and could pass on a phone with an IPv6 uplink of its own.
func (m *exitManager) probeIPv6TCP(ctx context.Context) (ipv6ProbeStage, string, error) {
	ip := net.ParseIP(ipv6ProbeAddress)
	stage := ipv6ProbeStage{Target: net.JoinHostPort(ipv6ProbeAddress, strconv.Itoa(ipv6ProbeTLSPort))}
	var lastErr error
	for _, profile := range m.ordered() {
		if ctx.Err() != nil {
			break
		}
		if m.isDenied(profile.ID) {
			continue
		}
		started := time.Now()
		conn, err := m.dialViaProfile(ctx, profile, ip, ipv6ProbeTLSPort)
		if err != nil {
			lastErr = err
			m.log.emit("debug", "IPv6 check: exit %s: %v", profile.Name, err)
			continue
		}
		timeout := probeTimeout(ctx)
		_ = conn.SetDeadline(time.Now().Add(timeout))
		body, err := fetchTrace(fixedDialer{conn: conn}.DialContext, ipv6TraceURL, timeout)
		_ = conn.Close()
		if err != nil {
			lastErr = err
			m.log.emit("debug", "IPv6 check: exit %s: %v", profile.Name, err)
			continue
		}
		address, err := parseIPv6Trace(body)
		if err != nil {
			lastErr = err
			m.log.emit("debug", "IPv6 check: exit %s: %v", profile.Name, err)
			continue
		}
		stage.OK = true
		stage.Latency = float64(time.Since(started).Microseconds()) / 1000.0
		stage.Address = address
		return stage, profile.Name, nil
	}
	if lastErr == nil {
		lastErr = errors.New("no exit node is available")
	}
	return stage, "", lastErr
}

// probeIPv6UDP asks the IPv6 resolver for an AAAA record through the UDP relay
// of the exit. The relay pins the source and checks the destination policy on
// the server, so a success proves the datagram really went through it.
func (m *exitManager) probeIPv6UDP(ctx context.Context) (ipv6ProbeStage, error) {
	stage := ipv6ProbeStage{Target: net.JoinHostPort(ipv6ProbeAddress, strconv.Itoa(ipv6ProbeDNSPort))}
	var id [2]byte
	if _, err := rand.Read(id[:]); err != nil {
		return stage, err
	}
	transaction := binary.BigEndian.Uint16(id[:])
	query := buildDNSQueryAAAA(transaction, ipv6ProbeName)

	started := time.Now()
	response, err := queryDNSDatagram(ctx, func(ctx context.Context, _, address string) (net.Conn, error) {
		return m.dialUDP(ctx, "udp6", address)
	}, stage.Target, query)
	if err != nil {
		return stage, err
	}
	stage.Latency = float64(time.Since(started).Microseconds()) / 1000.0
	if firstDNSAAAA(response, transaction) == nil {
		return stage, fmt.Errorf("the exit resolver returned no AAAA record for %s", ipv6ProbeName)
	}
	stage.OK = true
	return stage, nil
}

// parseIPv6Trace reads the `ip=` line and requires an IPv6 address. An IPv4
// answer would mean the request somehow left over IPv4, which must not be
// reported as a working IPv6 path.
func parseIPv6Trace(body string) (string, error) {
	address, err := parsePublicIP(body)
	if err != nil {
		return "", err
	}
	ip := net.ParseIP(address)
	if ip == nil || ip.To4() != nil {
		return "", fmt.Errorf("the exit reported an IPv4 address %q", address)
	}
	return address, nil
}

// fixedDialer hands one already connected socket to net/http. The probe dials
// the exit itself, so the transport must not open another connection.
type fixedDialer struct {
	conn net.Conn
}

func (d fixedDialer) DialContext(context.Context, string, string) (net.Conn, error) {
	return d.conn, nil
}

// probeTimeout is the time left until the deadline of the check.
func probeTimeout(ctx context.Context) time.Duration {
	if deadline, ok := ctx.Deadline(); ok {
		if left := time.Until(deadline); left > 0 {
			return left
		}
		return time.Millisecond
	}
	return 8 * time.Second
}

// describeIPv6Error turns a failure into something a user can act on.
func describeIPv6Error(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "no answer within the timeout"
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "no answer within the timeout"
	}
	return err.Error()
}
