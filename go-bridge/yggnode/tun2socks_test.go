package yggnode

import (
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// packetSink collects the packets the stack writes back into the tunnel.
type packetSink struct {
	mu      sync.Mutex
	packets [][]byte
	wake    chan struct{}
}

func newPacketSink() *packetSink {
	return &packetSink{wake: make(chan struct{}, 1)}
}

func (s *packetSink) WritePacket(packet []byte) bool {
	s.mu.Lock()
	s.packets = append(s.packets, append([]byte(nil), packet...))
	s.mu.Unlock()
	select {
	case s.wake <- struct{}{}:
	default:
	}
	return true
}

// wait returns the first packet that satisfies match, waiting up to timeout.
func (s *packetSink) wait(timeout time.Duration, match func([]byte) bool) []byte {
	deadline := time.Now().Add(timeout)
	for {
		s.mu.Lock()
		for _, packet := range s.packets {
			if match(packet) {
				s.mu.Unlock()
				return packet
			}
		}
		s.mu.Unlock()
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil
		}
		select {
		case <-s.wake:
		case <-time.After(remaining):
		}
	}
}

// stubDialer records upstream dials and hands back one end of an in-memory
// pipe. It implements ipv6Carrier, which is what the forwarding stack asks
// before it accepts a global IPv6 destination.
type stubDialer struct {
	ipv6 bool

	mu    sync.Mutex
	calls []dialCall
	conns []net.Conn
	wake  chan dialCall
}

type dialCall struct {
	network string
	address string
}

func newStubDialer(ipv6 bool) *stubDialer {
	return &stubDialer{ipv6: ipv6, wake: make(chan dialCall, 4)}
}

func (d *stubDialer) carriesIPv6() bool { return d.ipv6 }

func (d *stubDialer) DialContext(_ context.Context, network, address string) (net.Conn, error) {
	client, server := net.Pipe()
	call := dialCall{network: network, address: address}
	d.mu.Lock()
	d.calls = append(d.calls, call)
	d.conns = append(d.conns, client, server)
	d.mu.Unlock()
	d.wake <- call
	return client, nil
}

func (d *stubDialer) waitCall(timeout time.Duration) (dialCall, bool) {
	select {
	case call := <-d.wake:
		return call, true
	case <-time.After(timeout):
		return dialCall{}, false
	}
}

func (d *stubDialer) callCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.calls)
}

func (d *stubDialer) closeAll() {
	d.mu.Lock()
	conns := d.conns
	d.conns = nil
	d.mu.Unlock()
	for _, conn := range conns {
		_ = conn.Close()
	}
}

// peer returns the server end of the most recent dial.
func (d *stubDialer) peer() net.Conn {
	d.mu.Lock()
	defer d.mu.Unlock()
	if len(d.conns) < 2 {
		return nil
	}
	return d.conns[len(d.conns)-1]
}

func TestIsGlobalIPv6(t *testing.T) {
	tests := []struct {
		address string
		want    bool
	}{
		{"2606:4700:4700::1111", true},
		{"2a01:ecc0:5000:329::2", true},
		{"200::1", false},
		{"fc00::1", false},
		{"fd12:3456::1", false},
		{"fe80::1", false},
		{"::1", false},
		{"ff02::1", false},
		{"2001:db8::1", false},
		{"2001:2::1", false},
		{"3fff::1", false},
	}
	for _, test := range tests {
		ip := net.ParseIP(test.address)
		if ip == nil {
			t.Fatalf("bad test address %q", test.address)
		}
		if got := isGlobalIPv6(ip); got != test.want {
			t.Errorf("isGlobalIPv6(%s) = %v, want %v", test.address, got, test.want)
		}
	}
	if isGlobalIPv6(net.ParseIP("1.1.1.1")) {
		t.Error("an IPv4 address was taken for a global IPv6 one")
	}
}

// The IPv6 decision is asked from the carrier for every packet, so an exit
// that reports a broken provider disables the path without a tunnel restart,
// and a recovered one restores it.
func TestTun2SocksIPv6FollowsCarrier(t *testing.T) {
	writer := newPacketSink()
	dialer := newStubDialer(true)
	stack, err := newTun2Socks(1280, nil, writer, dialer, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.stop()

	destination := tcpip.AddrFromSlice(net.ParseIP("2606:4700:4700::1111"))
	if !stack.canForward(destination) {
		t.Fatal("a global IPv6 destination was refused with a working carrier")
	}
	dialer.ipv6 = false
	if stack.canForward(destination) {
		t.Fatal("IPv6 was still forwarded after the carrier stopped carrying it")
	}
	dialer.ipv6 = true
	if !stack.canForward(destination) {
		t.Fatal("IPv6 was not restored after the carrier recovered")
	}
}

func TestForwardTCPIPv6ThroughExit(t *testing.T) {
	writer := newPacketSink()
	dialer := newStubDialer(true)
	stack, err := newTun2Socks(1280, nil, writer, dialer, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.stop()
	defer dialer.closeAll()

	const (
		destination = "2606:4700:4700::1111"
		clientPort  = 40000
	)
	app := net.ParseIP("200::1")
	server := net.ParseIP(destination)
	packet := tcpv6Packet(app, server, clientPort, 443, header.TCPFlagSyn)
	if err := stack.inject(packet); err != nil {
		t.Fatal(err)
	}

	// The stack must answer the SYN with a SYN-ACK addressed to the app.
	reply := writer.wait(2*time.Second, func(raw []byte) bool {
		if len(raw) < 60 || raw[0]>>4 != 6 {
			return false
		}
		ip := header.IPv6(raw)
		if ip.NextHeader() != uint8(header.TCPProtocolNumber) {
			return false
		}
		tcp := header.TCP(ip.Payload())
		return tcp.Flags()&header.TCPFlagSyn != 0 && tcp.Flags()&header.TCPFlagAck != 0
	})
	if reply == nil {
		t.Fatal("no SYN-ACK was written back into the tunnel")
	}
	ip := header.IPv6(reply)
	source := ip.SourceAddress()
	destinationAddr := ip.DestinationAddress()
	if !net.IP(source.AsSlice()).Equal(server) {
		t.Fatalf("SYN-ACK source = %s", net.IP(source.AsSlice()))
	}
	if !net.IP(destinationAddr.AsSlice()).Equal(app) {
		t.Fatalf("SYN-ACK destination = %s", net.IP(destinationAddr.AsSlice()))
	}

	// The forwarder only dials after the three-way handshake, so the app has to
	// acknowledge the SYN-ACK.
	synAck := header.TCP(ip.Payload())
	ack := tcpv6Segment(app, server, clientPort, 443, 2, synAck.SequenceNumber()+1, header.TCPFlagAck)
	if err := stack.inject(ack); err != nil {
		t.Fatal(err)
	}

	call, ok := dialer.waitCall(2 * time.Second)
	if !ok {
		t.Fatal("the stack did not dial the IPv6 destination")
	}
	if call.network != "tcp" || call.address != "["+destination+"]:443" {
		t.Fatalf("dial = %s %s", call.network, call.address)
	}
}

func TestForwardTCPIPv6WithoutExitIsReset(t *testing.T) {
	writer := newPacketSink()
	dialer := newStubDialer(false)
	stack, err := newTun2Socks(1280, nil, writer, dialer, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.stop()
	defer dialer.closeAll()

	packet := tcpv6Packet(net.ParseIP("200::1"), net.ParseIP("2606:4700:4700::1111"), 40000, 443, header.TCPFlagSyn)
	if err := stack.inject(packet); err != nil {
		t.Fatal(err)
	}

	reply := writer.wait(2*time.Second, func(raw []byte) bool {
		if len(raw) < 60 || raw[0]>>4 != 6 {
			return false
		}
		ip := header.IPv6(raw)
		if ip.NextHeader() != uint8(header.TCPProtocolNumber) {
			return false
		}
		return header.TCP(ip.Payload()).Flags()&header.TCPFlagRst != 0
	})
	if reply == nil {
		t.Fatal("IPv6 without an exit was not reset")
	}
	if dialer.callCount() != 0 {
		t.Fatalf("IPv6 without an exit caused %d dial(s)", dialer.callCount())
	}
}

func TestForwardUDPIPv6ThroughExit(t *testing.T) {
	writer := newPacketSink()
	dialer := newStubDialer(true)
	stack, err := newTun2Socks(1280, nil, writer, dialer, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.stop()
	defer dialer.closeAll()

	const destination = "2606:4700:4700::1111"
	packet := udpv6Packet(net.ParseIP("200::1"), net.ParseIP(destination), 40000, 443, []byte("quic"))
	if err := stack.inject(packet); err != nil {
		t.Fatal(err)
	}

	call, ok := dialer.waitCall(2 * time.Second)
	if !ok {
		t.Fatal("the stack did not dial the IPv6 UDP destination")
	}
	if call.network != "udp" || call.address != "["+destination+"]:443" {
		t.Fatalf("dial = %s %s", call.network, call.address)
	}

	peer := dialer.peer()
	if peer == nil {
		t.Fatal("no upstream connection to answer on")
	}
	if _, err := peer.Write([]byte("answer")); err != nil {
		t.Fatal(err)
	}

	reply := writer.wait(2*time.Second, func(raw []byte) bool {
		if len(raw) < 48 || raw[0]>>4 != 6 {
			return false
		}
		ip := header.IPv6(raw)
		if ip.NextHeader() != uint8(header.UDPProtocolNumber) {
			return false
		}
		return string(header.UDP(ip.Payload()).Payload()) == "answer"
	})
	if reply == nil {
		t.Fatal("the UDP answer was not written back into the tunnel")
	}
	ip := header.IPv6(reply)
	source := ip.SourceAddress()
	if !net.IP(source.AsSlice()).Equal(net.ParseIP(destination)) {
		t.Fatalf("answer source = %s", net.IP(source.AsSlice()))
	}
}

func TestForwardUDPIPv6WithoutExitIsDropped(t *testing.T) {
	writer := newPacketSink()
	dialer := newStubDialer(false)
	stack, err := newTun2Socks(1280, nil, writer, dialer, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	defer stack.stop()
	defer dialer.closeAll()

	packet := udpv6Packet(net.ParseIP("200::1"), net.ParseIP("2606:4700:4700::1111"), 40000, 443, []byte("quic"))
	if err := stack.inject(packet); err != nil {
		t.Fatal(err)
	}

	time.Sleep(200 * time.Millisecond)
	if dialer.callCount() != 0 {
		t.Fatalf("IPv6 UDP without an exit caused %d dial(s)", dialer.callCount())
	}
	if len(writer.packets) != 0 {
		t.Fatalf("IPv6 UDP without an exit produced %d packet(s)", len(writer.packets))
	}
}

// tcpv6Packet builds one IPv6/TCP segment with a valid checksum.
func tcpv6Packet(src, dst net.IP, srcPort, dstPort uint16, flags header.TCPFlags) []byte {
	return tcpv6Segment(src, dst, srcPort, dstPort, 1, 0, flags)
}

func tcpv6Segment(src, dst net.IP, srcPort, dstPort uint16, seq, ack uint32, flags header.TCPFlags) []byte {
	segment := header.TCP(make([]byte, header.TCPMinimumSize))
	segment.SetSourcePort(srcPort)
	segment.SetDestinationPort(dstPort)
	segment.SetSequenceNumber(seq)
	segment.SetAckNumber(ack)
	segment.SetFlags(uint8(flags))
	segment.SetWindowSize(65535)
	segment.SetDataOffset(uint8(header.TCPMinimumSize))
	srcAddr := tcpip.AddrFromSlice(src.To16())
	dstAddr := tcpip.AddrFromSlice(dst.To16())
	xsum := header.PseudoHeaderChecksum(header.TCPProtocolNumber, srcAddr, dstAddr, uint16(len(segment)))
	segment.SetChecksum(^segment.CalculateChecksum(xsum))
	return ipv6Packet(uint8(header.TCPProtocolNumber), src, dst, segment)
}

// udpv6Packet builds one IPv6/UDP datagram with a valid checksum.
func udpv6Packet(src, dst net.IP, srcPort, dstPort uint16, payload []byte) []byte {
	datagram := header.UDP(make([]byte, header.UDPMinimumSize+len(payload)))
	datagram.SetSourcePort(srcPort)
	datagram.SetDestinationPort(dstPort)
	datagram.SetLength(uint16(len(datagram)))
	copy(datagram[header.UDPMinimumSize:], payload)
	srcAddr := tcpip.AddrFromSlice(src.To16())
	dstAddr := tcpip.AddrFromSlice(dst.To16())
	xsum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcAddr, dstAddr, uint16(len(datagram)))
	datagram.SetChecksum(^datagram.CalculateChecksum(xsum))
	return ipv6Packet(uint8(header.UDPProtocolNumber), src, dst, datagram)
}
