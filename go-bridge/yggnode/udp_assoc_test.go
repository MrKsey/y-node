package yggnode

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

func TestUDPRelayDatagramRoundTrip(t *testing.T) {
	payload := []byte{0xde, 0xad, 0xbe, 0xef}
	for _, raw := range []string{"1.2.3.4", "2606:4700:4700::1111"} {
		ip := net.ParseIP(raw)
		packet := buildUDPRelayDatagram(ip, 443, payload)
		header := 10
		if ip.To4() == nil {
			header = 22
		}
		if len(packet)-len(payload) != header {
			t.Fatalf("%s: unexpected header size %d", raw, len(packet)-len(payload))
		}
		gotIP, gotPort, gotPayload, ok := parseUDPRelayDatagram(packet)
		if !ok {
			t.Fatalf("%s: the header did not parse", raw)
		}
		if !gotIP.Equal(ip) || gotPort != 443 || string(gotPayload) != string(payload) {
			t.Fatalf("%s: round trip = %s:%d/%x", raw, gotIP, gotPort, gotPayload)
		}
	}
}

func TestUDPRelayDatagramRejectsFragments(t *testing.T) {
	packet := buildUDPRelayDatagram(net.ParseIP("1.2.3.4"), 53, []byte("dns"))
	packet[2] = 1
	if _, _, _, ok := parseUDPRelayDatagram(packet); ok {
		t.Fatal("a fragmented datagram was accepted")
	}
}

func TestUDPRelayDatagramRejectsDomain(t *testing.T) {
	packet := []byte{0, 0, 0, socksAtypDomain, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0, 53, 'x'}
	if _, _, _, ok := parseUDPRelayDatagram(packet); ok {
		t.Fatal("a domain address was accepted")
	}
}

func TestSocks5UDPAssociate(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	go fakeUDPAssociateServer(server)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	relay, err := socks5UDPAssociate(ctx, client)
	if err != nil {
		t.Fatalf("socks5UDPAssociate: %v", err)
	}
	if !relay.IP.Equal(net.ParseIP("200::1")) || relay.Port != 51234 {
		t.Fatalf("relay = %v", relay)
	}
}

func TestSocks5UDPAssociateRefused(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	go fakeUDPAssociateServerCode(server, socksReplyCommandNotSupp)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err := socks5UDPAssociate(ctx, client)
	var reply *socksReplyError
	if !errors.As(err, &reply) || reply.Code != socksReplyCommandNotSupp {
		t.Fatalf("error = %v, want a refused SOCKS reply", err)
	}
}

func TestUDPAssociationDeliversToMatchingFlow(t *testing.T) {
	manager := &exitManager{log: &goLogger{}}
	relay := newFakePacketConn()
	association := newSocksUDPAssociation(manager, ExitProfile{ID: "e", Name: "e"}, newFakeStreamConn(), relay, &goLogger{})
	association.start()
	defer association.close(nil)

	flowA, err := association.openFlow(net.ParseIP("1.1.1.1"), 53)
	if err != nil {
		t.Fatalf("openFlow: %v", err)
	}
	defer flowA.Close()
	flowB, err := association.openFlow(net.ParseIP("8.8.8.8"), 53)
	if err != nil {
		t.Fatalf("openFlow: %v", err)
	}
	defer flowB.Close()

	relay.push(buildUDPRelayDatagram(net.ParseIP("1.1.1.1"), 53, []byte("answer-a")))

	buf := make([]byte, 128)
	_ = flowA.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := flowA.Read(buf)
	if err != nil || string(buf[:n]) != "answer-a" {
		t.Fatalf("flow A read = %q, %v", buf[:n], err)
	}
	_ = flowB.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
	if _, err := flowB.Read(buf); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("flow B got the datagram of flow A: %v", err)
	}

	if _, err := flowA.Write([]byte("question")); err != nil {
		t.Fatalf("flow A write: %v", err)
	}
	packet := relay.written()
	ip, port, payload, ok := parseUDPRelayDatagram(packet)
	if !ok || !ip.Equal(net.ParseIP("1.1.1.1")) || port != 53 || string(payload) != "question" {
		t.Fatalf("encapsulated datagram = %x", packet)
	}
}

func TestUDPAssociationCloseFailsFlows(t *testing.T) {
	manager := &exitManager{log: &goLogger{}}
	association := newSocksUDPAssociation(manager, ExitProfile{ID: "e"}, newFakeStreamConn(), newFakePacketConn(), &goLogger{})
	association.start()

	flow, err := association.openFlow(net.ParseIP("9.9.9.9"), 443)
	if err != nil {
		t.Fatalf("openFlow: %v", err)
	}
	association.close(errors.New("test"))

	buf := make([]byte, 16)
	if _, err := flow.Read(buf); !errors.Is(err, net.ErrClosed) {
		t.Fatalf("a flow of a closed association read = %v", err)
	}
	if _, err := association.openFlow(net.ParseIP("9.9.9.9"), 443); err == nil {
		t.Fatal("a closed association accepted a new flow")
	}
}

// TestUDPAssociationIdleCloseIsNotAnError covers the two-minute idle timeout of
// the exit: it closes the control connection, which used to surface on the card
// as "UDP relay failed" even though the next datagram simply opened a new one.
func TestUDPAssociationIdleCloseIsNotAnError(t *testing.T) {
	on := true
	manager := &exitManager{
		cfg: exitConfig{
			Enabled:  true,
			Profiles: []ExitProfile{{ID: "e", Name: "e", Address: "200::1", SocksPort: 1080}},
			UDP:      &on,
		},
		log:    &goLogger{},
		health: map[string]*profileHealth{"e": {State: exitStateOnline}},
	}
	control := newFakeStreamConn()
	association := newSocksUDPAssociation(manager, ExitProfile{ID: "e", Name: "e"}, control, newFakePacketConn(), &goLogger{})
	manager.udp = association
	association.start()

	// The exit drops an idle association: the control connection sees EOF.
	if err := control.Close(); err != nil {
		t.Fatalf("close control: %v", err)
	}
	waitForNoAssociation(t, manager)

	if manager.udpErr != "" {
		t.Fatalf("an idle close was reported as an error: %q", manager.udpErr)
	}
	if state := manager.status().UDP.State; state != "idle" {
		t.Fatalf("udp state after an idle close = %q, want idle", state)
	}
}

// TestUDPAssociationControlErrorIsReported keeps a real failure visible: a reset
// control connection is not the idle timeout and the card has to say so.
func TestUDPAssociationControlErrorIsReported(t *testing.T) {
	on := true
	manager := &exitManager{
		cfg: exitConfig{
			Enabled:  true,
			Profiles: []ExitProfile{{ID: "e", Name: "e", Address: "200::1", SocksPort: 1080}},
			UDP:      &on,
		},
		log:    &goLogger{},
		health: map[string]*profileHealth{"e": {State: exitStateOnline}},
	}
	control := newFakeStreamConn()
	control.readErr = errors.New("connection reset by peer")
	association := newSocksUDPAssociation(manager, ExitProfile{ID: "e", Name: "e"}, control, newFakePacketConn(), &goLogger{})
	manager.udp = association
	association.start()

	if err := control.Close(); err != nil {
		t.Fatalf("close control: %v", err)
	}
	waitForNoAssociation(t, manager)

	if manager.udpErr == "" {
		t.Fatal("a reset control connection was not reported")
	}
	if state := manager.status().UDP.State; state != "error" {
		t.Fatalf("udp state after a reset = %q, want error", state)
	}
}

// TestUDPAssociationExpiresAfterSilence covers the phone that slept through the
// exit idle timeout: no FIN ever arrived, the control connection still looks
// open, and every datagram would go into a relay the exit has forgotten. The
// client drops such an association by itself so the next datagram dials a
// fresh one.
func TestUDPAssociationExpiresAfterSilence(t *testing.T) {
	manager := &exitManager{log: &goLogger{}}
	association := newSocksUDPAssociation(manager, ExitProfile{ID: "e", Name: "e"}, newFakeStreamConn(), newFakePacketConn(), &goLogger{})
	association.start()
	defer association.close(nil)

	if association.expired() {
		t.Fatal("a fresh association was reported as expired")
	}
	if _, err := association.openFlow(net.ParseIP("1.1.1.1"), 53); err != nil {
		t.Fatalf("openFlow: %v", err)
	}
	if association.expired() {
		t.Fatal("a flow made the association look expired")
	}

	// Rewind the clock instead of waiting for the real idle timeout.
	association.lastActivity.Store(time.Now().Add(-2 * udpAssociationIdle).UnixNano())
	if !association.expired() {
		t.Fatal("a silent association was not expired")
	}

	// A stream of datagrams that never gets an answer is the second sign.
	association.touch()
	if association.expired() {
		t.Fatal("an association with fresh traffic was reported as expired")
	}
	association.datagramsOut.Add(1)
	association.lastIn.Store(time.Now().Add(-2 * udpAssociationIdle).UnixNano())
	if !association.expired() {
		t.Fatal("an unanswered association was not expired")
	}
}

func waitForNoAssociation(t *testing.T, manager *exitManager) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		manager.udpMu.Lock()
		gone := manager.udp == nil
		manager.udpMu.Unlock()
		if gone {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the association was not dropped")
}

// TestUDPSkipsDirectWhenExitIsOn is the leak test: with an exit enabled the
// datagram must never fall back to the phone's own network, whatever the exit
// does.
func TestUDPSkipsDirectWhenExitIsOn(t *testing.T) {
	direct := &recordingDialer{}
	manager := &exitManager{
		cfg: exitConfig{
			Enabled:  true,
			Profiles: []ExitProfile{{ID: "e", Name: "e", Address: "200::1", SocksPort: 1080}},
		},
		direct: direct,
		log:    &goLogger{},
		health: map[string]*profileHealth{"e": {State: exitStateUnknown}},
	}

	// UDP turned off by the user: the datagram is dropped, not dialed directly.
	off := false
	manager.cfg.UDP = &off
	if _, err := manager.DialContext(context.Background(), "udp", "1.1.1.1:443"); !errors.Is(err, errUDPDisabled) {
		t.Fatalf("disabled UDP error = %v", err)
	}
	if direct.calls() != 0 {
		t.Fatal("a disabled exit UDP path dialed the real network")
	}

	// UDP enabled but the exit cannot be reached: still no direct connection.
	on := true
	manager.cfg.UDP = &on
	if _, err := manager.DialContext(context.Background(), "udp", "1.1.1.1:443"); err == nil {
		t.Fatal("an unreachable exit produced a working UDP flow")
	}
	if direct.calls() != 0 {
		t.Fatal("an unreachable exit UDP path dialed the real network")
	}

	// Private destinations stay local even with the exit on.
	local := &recordingDialer{}
	manager.direct = local
	if _, err := manager.DialContext(context.Background(), "udp", "192.168.1.1:53"); err == nil {
		t.Fatal("the recording dialer should have been used")
	}
	if local.calls() != 1 {
		t.Fatal("a private UDP destination did not stay on the local network")
	}
}

func TestUDPEnabledDefaultsOn(t *testing.T) {
	cfg, err := parseExitConfig(`{"enabled":true,"profiles":[{"address":"200::1","socksPort":1080,"apiPort":1081}]}`)
	if err != nil {
		t.Fatalf("parseExitConfig: %v", err)
	}
	if !cfg.udpEnabled() {
		t.Fatal("UDP should be on when the config has no field")
	}
	cfg, err = parseExitConfig(`{"enabled":true,"udp":false,"profiles":[{"address":"200::1","socksPort":1080,"apiPort":1081}]}`)
	if err != nil {
		t.Fatalf("parseExitConfig: %v", err)
	}
	if cfg.udpEnabled() {
		t.Fatal("an explicit false was ignored")
	}
}

func TestExitStatusReportsUDP(t *testing.T) {
	on := true
	manager := &exitManager{
		cfg: exitConfig{
			Enabled:  true,
			Profiles: []ExitProfile{{ID: "e", Name: "e", Address: "200::1", SocksPort: 1080}},
			UDP:      &on,
		},
		log:    &goLogger{},
		health: map[string]*profileHealth{"e": {State: exitStateOnline}},
	}
	status := manager.status()
	if !status.UDP.Enabled || status.UDP.State != "idle" {
		t.Fatalf("udp status = %+v", status.UDP)
	}
	manager.cfg.UDP = nil
	manager.cfg.Enabled = false
	status = manager.status()
	if status.UDP.Enabled || status.UDP.State != "off" {
		t.Fatalf("udp status with the exit off = %+v", status.UDP)
	}
}

func TestQueryDNSDatagramSkipsForeignAnswers(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	go func() {
		defer server.Close()
		query := make([]byte, 64)
		n, err := server.Read(query)
		if err != nil {
			return
		}
		foreign := append([]byte(nil), query[:n]...)
		foreign[0], foreign[1] = 0x11, 0x22
		_, _ = server.Write(foreign)
		own := append([]byte(nil), query[:n]...)
		_, _ = server.Write(own)
	}()

	query := make([]byte, 12)
	query[0], query[1] = 0xAB, 0xCD
	query[4], query[5] = 0, 1
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	response, err := queryDNSDatagram(ctx, func(context.Context, string, string) (net.Conn, error) {
		return client, nil
	}, "1.1.1.1:53", query)
	if err != nil {
		t.Fatalf("queryDNSDatagram: %v", err)
	}
	if response[0] != 0xAB || response[1] != 0xCD {
		t.Fatalf("a foreign answer was returned: %x", response[:2])
	}
}

func fakeUDPAssociateServer(conn net.Conn) {
	fakeUDPAssociateServerCode(conn, socksReplySuccess)
}

func fakeUDPAssociateServerCode(conn net.Conn, code byte) {
	defer conn.Close()
	greeting := make([]byte, 3)
	if _, err := io.ReadFull(conn, greeting); err != nil {
		return
	}
	_, _ = conn.Write([]byte{5, 0})
	request := make([]byte, 10)
	if _, err := io.ReadFull(conn, request); err != nil {
		return
	}
	if request[1] != socksCmdUDPAssociate {
		return
	}
	if code != socksReplySuccess {
		_, _ = conn.Write([]byte{5, code, 0, 1, 0, 0, 0, 0, 0, 0})
		return
	}
	reply := []byte{5, 0, 0, 4}
	reply = append(reply, net.ParseIP("200::1").To16()...)
	reply = append(reply, 0xC8, 0x22) // 51234
	_, _ = conn.Write(reply)
	// Keep the control connection open for the test.
	_, _ = io.Copy(io.Discard, conn)
}

// recordingDialer fails every dial and counts the attempts.
type recordingDialer struct {
	mu    sync.Mutex
	count int
}

func (d *recordingDialer) DialContext(context.Context, string, string) (net.Conn, error) {
	d.mu.Lock()
	d.count++
	d.mu.Unlock()
	return nil, errors.New("the real network must not be used")
}

func (d *recordingDialer) calls() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.count
}

// fakePacketConn is a datagram socket in memory.
type fakePacketConn struct {
	in     chan []byte
	mu     sync.Mutex
	out    [][]byte
	closed chan struct{}
	once   sync.Once
}

func newFakePacketConn() *fakePacketConn {
	return &fakePacketConn{in: make(chan []byte, 8), closed: make(chan struct{})}
}

func (c *fakePacketConn) push(packet []byte) { c.in <- append([]byte(nil), packet...) }

func (c *fakePacketConn) Read(p []byte) (int, error) {
	select {
	case packet := <-c.in:
		return copy(p, packet), nil
	case <-c.closed:
		return 0, net.ErrClosed
	}
}

func (c *fakePacketConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	c.out = append(c.out, append([]byte(nil), p...))
	c.mu.Unlock()
	return len(p), nil
}

func (c *fakePacketConn) written() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.out) == 0 {
		return nil
	}
	return c.out[len(c.out)-1]
}

func (c *fakePacketConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

func (c *fakePacketConn) LocalAddr() net.Addr {
	return &net.UDPAddr{IP: net.ParseIP("200::1"), Port: 61001}
}

func (c *fakePacketConn) RemoteAddr() net.Addr {
	return &net.UDPAddr{IP: net.ParseIP("200::2"), Port: 40000}
}

func (c *fakePacketConn) SetDeadline(time.Time) error      { return nil }
func (c *fakePacketConn) SetReadDeadline(time.Time) error  { return nil }
func (c *fakePacketConn) SetWriteDeadline(time.Time) error { return nil }

// fakeStreamConn is the control connection of a fake association.
type fakeStreamConn struct {
	closed  chan struct{}
	once    sync.Once
	readErr error
}

func newFakeStreamConn() *fakeStreamConn {
	return &fakeStreamConn{closed: make(chan struct{})}
}

func (c *fakeStreamConn) Read([]byte) (int, error) {
	<-c.closed
	if c.readErr != nil {
		return 0, c.readErr
	}
	return 0, io.EOF
}

func (c *fakeStreamConn) Write(p []byte) (int, error) { return len(p), nil }

func (c *fakeStreamConn) Close() error {
	c.once.Do(func() { close(c.closed) })
	return nil
}

func (c *fakeStreamConn) LocalAddr() net.Addr              { return &net.TCPAddr{} }
func (c *fakeStreamConn) RemoteAddr() net.Addr             { return &net.TCPAddr{} }
func (c *fakeStreamConn) SetDeadline(time.Time) error      { return nil }
func (c *fakeStreamConn) SetReadDeadline(time.Time) error  { return nil }
func (c *fakeStreamConn) SetWriteDeadline(time.Time) error { return nil }
