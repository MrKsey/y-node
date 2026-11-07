package yggnode

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
)

// Protector binds a socket to the underlying network. Android implements it
// with VpnService.protect: without it the socket of a forwarded connection
// would be routed back into the tunnel and the tunnel would eat its own tail.
type Protector interface {
	Protect(fd int) bool
}

// PacketWriter hands one fully formed IP packet back to the tunnel.
type PacketWriter interface {
	WritePacket(packet []byte) bool
}

const (
	// tun2socksNIC is a NIC id of its own: the Yggdrasil data path does not go
	// through the netstack at all, so the two never share an interface.
	tun2socksNIC tcpip.NICID = 2

	// tun2socksQueue is the number of outbound packets buffered between the
	// netstack and the writer thread.
	tun2socksQueue = 256

	// tun2socksDialTimeout bounds a single upstream connect.
	tun2socksDialTimeout = 15 * time.Second

	// tun2socksUDPIdle drops a forwarded UDP flow that stayed silent for this
	// long, so a session does not leak one socket per DNS name.
	tun2socksUDPIdle = 60 * time.Second
)

// tun2socks is a userspace TCP/IP stack between the tunnel and the real
// network. Android 12 binds the apps of an allow list to the VPN network and
// refuses to fall back to the underlying network for address families the VPN
// does not route, so their ordinary internet traffic dies the moment the VPN
// carries no IPv4. Routing IPv4 into the tunnel and forwarding it here keeps
// those apps online without giving up the per-app split.
type tun2socks struct {
	stack  *stack.Stack
	link   *channel.Endpoint
	writer PacketWriter
	dialer upstreamDialer
	dns    *dnsRouter
	log    *goLogger

	// carrier is the upstream when it can carry global IPv6, nil otherwise.
	// The question is asked for every IPv6 packet instead of once at start:
	// the exit may report that its provider stopped routing IPv6, and the
	// tunnel must stop sending such packets without a restart.
	carrier ipv6Carrier

	cancel context.CancelFunc
	done   chan struct{}
	once   sync.Once
}

// ipv6Carrier is implemented by an upstream that can carry global IPv6. The
// exit node connects to IPv6 destinations from its own host, so the phone needs
// no IPv6 uplink for them.
type ipv6Carrier interface {
	carriesIPv6() bool
}

// globalIPv6Ranges is the global unicast space an exit node is willing to
// reach. Everything else — Yggdrasil (200::/7), unique local, link-local,
// loopback, multicast — must never leave the phone.
var globalIPv6Ranges = mustCIDRs("2000::/3")

// reservedIPv6Ranges are special-purpose prefixes inside the global space that
// are not ordinary internet destinations.
var reservedIPv6Ranges = mustCIDRs(
	"2001:2::/48",   // benchmarking (RFC 5180)
	"2001:10::/28",  // ORCHID (RFC 4843)
	"2001:20::/28",  // ORCHIDv2 (RFC 7343)
	"2001:db8::/32", // documentation (RFC 3849)
	"3fff::/20",     // documentation (RFC 9637)
)

// newTun2Socks builds a stack that accepts every packet the tunnel delivers and
// dials the real destination through the configured upstream: a protected
// socket, or a SOCKS5 connection through an exit node.
func newTun2Socks(
	mtu int,
	v4 net.IP,
	writer PacketWriter,
	dialer upstreamDialer,
	dns *dnsRouter,
	log *goLogger,
) (*tun2socks, error) {
	if writer == nil {
		return nil, errors.New("tun2socks needs a packet writer")
	}
	if dialer == nil {
		return nil, errors.New("tun2socks needs an upstream dialer")
	}
	if mtu < 576 {
		mtu = 1280
	}

	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})

	link := channel.New(tun2socksQueue, uint32(mtu), "")
	if err := s.CreateNIC(tun2socksNIC, link); err != nil {
		return nil, fmt.Errorf("netstack NIC: %v", err)
	}
	// The apps dial arbitrary addresses, so the NIC must accept packets that are
	// not addressed to it and answer from the address the app chose.
	if err := s.SetPromiscuousMode(tun2socksNIC, true); err != nil {
		return nil, fmt.Errorf("netstack promiscuous mode: %v", err)
	}
	if err := s.SetSpoofing(tun2socksNIC, true); err != nil {
		return nil, fmt.Errorf("netstack spoofing: %v", err)
	}

	if v4 = v4.To4(); v4 != nil {
		err := s.AddProtocolAddress(
			tun2socksNIC,
			tcpip.ProtocolAddress{
				Protocol: ipv4.ProtocolNumber,
				AddressWithPrefix: tcpip.AddressWithPrefix{
					Address:   tcpip.AddrFromSlice(v4),
					PrefixLen: 32,
				},
			},
			stack.AddressProperties{},
		)
		if err != nil {
			return nil, fmt.Errorf("netstack address %s: %v", v4, err)
		}
	}
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: tun2socksNIC},
		{Destination: header.IPv6EmptySubnet, NIC: tun2socksNIC},
	})

	t := &tun2socks{
		stack:  s,
		link:   link,
		writer: writer,
		dialer: dialer,
		dns:    dns,
		log:    log,
		done:   make(chan struct{}),
	}
	if carrier, ok := dialer.(ipv6Carrier); ok {
		t.carrier = carrier
	}

	tcpForwarder := tcp.NewForwarder(s, 0, tun2socksQueue, func(r *tcp.ForwarderRequest) {
		go t.forwardTCP(r)
	})
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcpForwarder.HandlePacket)

	udpForwarder := udp.NewForwarder(s, func(r *udp.ForwarderRequest) {
		go t.forwardUDP(r)
	})
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udpForwarder.HandlePacket)

	ctx, cancel := context.WithCancel(context.Background())
	t.cancel = cancel
	go t.pumpOutbound(ctx)

	return t, nil
}

// pumpOutbound copies the packets the stack wants to send into the tunnel.
func (t *tun2socks) pumpOutbound(ctx context.Context) {
	defer close(t.done)
	for {
		pkt := t.link.ReadContext(ctx)
		if pkt == nil {
			return
		}
		view := pkt.ToView()
		if view != nil {
			// The writer copies the bytes into the tun descriptor before the
			// buffer is released, so no lifetime is shared with the stack.
			t.writer.WritePacket(view.AsSlice())
		}
		pkt.DecRef()
	}
}

// inject hands one packet read from the tunnel to the stack.
func (t *tun2socks) inject(packet []byte) error {
	if len(packet) < 20 {
		return errors.New("packet is too short")
	}
	proto := ipv4.ProtocolNumber
	switch packet[0] >> 4 {
	case 4:
	case 6:
		proto = ipv6.ProtocolNumber
	default:
		return fmt.Errorf("unexpected IP version %d", packet[0]>>4)
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(packet),
	})
	defer pkt.DecRef()
	t.link.InjectInbound(proto, pkt)
	return nil
}

// forwardTCP accepts one forwarded connection and relays it to the real host.
func (t *tun2socks) forwardTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	if !t.canForward(id.LocalAddress) {
		// IPv6 without an exit: the tunnel has no IPv6 uplink of its own, so the
		// connect could only time out. Resetting at once lets the browser fall
		// back to IPv4 immediately instead of hanging on the AAAA address.
		r.Complete(true)
		return
	}
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	if err != nil {
		// The stack could not build an endpoint for the request: reset it so the
		// app fails fast instead of waiting for a timeout.
		r.Complete(true)
		return
	}
	r.Complete(false)

	ep.SocketOptions().SetKeepAlive(true)
	local := gonet.NewTCPConn(&wq, ep)
	defer local.Close()

	destination := tcpipAddrToIP(id.LocalAddress)
	if isDNSVIP(destination) && id.LocalPort == dnsVIPPort {
		t.forwardDNSTCP(local)
		return
	}

	target := net.JoinHostPort(id.LocalAddress.String(), strconv.Itoa(int(id.LocalPort)))
	ctx, cancel := context.WithTimeout(context.Background(), tun2socksDialTimeout)
	defer cancel()
	upstream, derr := t.dialer.DialContext(ctx, "tcp", target)
	if derr != nil {
		t.log.emit("debug", "tun2socks: tcp %s: %v", target, derr)
		return
	}
	defer upstream.Close()

	relay(local, upstream)
}

// forwardUDP relays one forwarded UDP flow, which is how DNS and QUIC leave.
func (t *tun2socks) forwardUDP(r *udp.ForwarderRequest) {
	id := r.ID()
	if !t.canForward(id.LocalAddress) {
		// No IPv6 uplink: dropping the datagram is what makes the client give up
		// on QUIC over IPv6 and retry over IPv4.
		return
	}
	var wq waiter.Queue
	ep, err := r.CreateEndpoint(&wq)
	if err != nil {
		return
	}
	local := gonet.NewUDPConn(&wq, ep)
	defer local.Close()

	destination := tcpipAddrToIP(id.LocalAddress)
	if isDNSVIP(destination) && id.LocalPort == dnsVIPPort {
		t.forwardDNSUDP(local)
		return
	}

	target := net.JoinHostPort(id.LocalAddress.String(), strconv.Itoa(int(id.LocalPort)))
	ctx, cancel := context.WithTimeout(context.Background(), tun2socksDialTimeout)
	defer cancel()
	upstream, derr := t.dialer.DialContext(ctx, "udp", target)
	if derr != nil {
		// A public datagram with an exit enabled is either carried by it or
		// dropped: the direct socket is only used when the exit is off, and the
		// exit manager enforces that. QUIC then retries over TCP.
		t.log.emit("debug", "tun2socks: udp %s: %v", target, derr)
		return
	}
	defer upstream.Close()

	relayIdle(local, upstream, tun2socksUDPIdle)
}

func tcpipAddrToIP(addr tcpip.Address) net.IP {
	return net.IP(addr.AsSlice())
}

// forwardDNSTCP answers DNS-over-TCP queries addressed to the tunnel resolver.
func (t *tun2socks) forwardDNSTCP(local net.Conn) {
	if t.dns == nil {
		return
	}
	for {
		_ = local.SetReadDeadline(time.Now().Add(30 * time.Second))
		var size [2]byte
		if _, err := io.ReadFull(local, size[:]); err != nil {
			return
		}
		length := int(binary.BigEndian.Uint16(size[:]))
		if length < 12 || length > 4096 {
			return
		}
		query := make([]byte, length)
		if _, err := io.ReadFull(local, query); err != nil {
			return
		}
		response := t.dns.handle(query)
		if len(response) == 0 {
			return
		}
		frame := make([]byte, 2+len(response))
		binary.BigEndian.PutUint16(frame[0:2], uint16(len(response)))
		copy(frame[2:], response)
		_ = local.SetWriteDeadline(time.Now().Add(30 * time.Second))
		if _, err := local.Write(frame); err != nil {
			return
		}
	}
}

// forwardDNSUDP answers one datagram at a time. The UDP endpoint is connected
// to the app that sent the query, so a plain Write sends the answer back.
func (t *tun2socks) forwardDNSUDP(local *gonet.UDPConn) {
	if t.dns == nil {
		return
	}
	buf := make([]byte, 4096)
	for {
		_ = local.SetReadDeadline(time.Now().Add(30 * time.Second))
		n, err := local.Read(buf)
		if err != nil {
			return
		}
		if n < 12 {
			continue
		}
		query := append([]byte(nil), buf[:n]...)
		response := t.dns.handle(query)
		if len(response) == 0 {
			continue
		}
		_ = local.SetWriteDeadline(time.Now().Add(30 * time.Second))
		if _, err := local.Write(response); err != nil {
			return
		}
	}
}

// canForward reports whether a destination may leave through the upstream. IPv4
// is always forwarded: that is the whole point of the stack. A global IPv6
// address is forwarded only when an exit node carries it; Yggdrasil addresses
// never come here because the Kotlin data path sends them to the node.
func (t *tun2socks) canForward(addr tcpip.Address) bool {
	if addr.Len() == 4 {
		return true
	}
	if t.carrier == nil || !t.carrier.carriesIPv6() {
		return false
	}
	return isGlobalIPv6(tcpipAddrToIP(addr))
}

// isGlobalIPv6 reports whether an IPv6 address is an ordinary internet
// destination. The check is an allow list, so an address family that is not
// explicitly global (Yggdrasil, ULA, link-local, multicast) can never be sent
// around the exit.
func isGlobalIPv6(ip net.IP) bool {
	v6 := ip.To16()
	if v6 == nil || ip.To4() != nil {
		return false
	}
	global := false
	for _, network := range globalIPv6Ranges {
		if network.Contains(v6) {
			global = true
			break
		}
	}
	if !global {
		return false
	}
	for _, network := range reservedIPv6Ranges {
		if network.Contains(v6) {
			return false
		}
	}
	return true
}

// relay copies in both directions until either side closes.
func relay(a, b net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(a, b)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(b, a)
		done <- struct{}{}
	}()
	<-done
}

// relayIdle is relay with a silence timeout, used for UDP flows that have no
// close of their own.
func relayIdle(a, b net.Conn, idle time.Duration) {
	done := make(chan struct{}, 2)
	pump := func(dst, src net.Conn) {
		buf := make([]byte, 64*1024)
		for {
			_ = src.SetReadDeadline(time.Now().Add(idle))
			n, err := src.Read(buf)
			if n > 0 {
				if _, werr := dst.Write(buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		done <- struct{}{}
	}
	go pump(a, b)
	go pump(b, a)
	<-done
}

// stop releases the stack and the goroutines.
func (t *tun2socks) stop() {
	t.once.Do(func() {
		if t.cancel != nil {
			t.cancel()
		}
		// The UDP association holds a control connection and a relay socket of
		// its own; they must not outlive the stack that used them.
		if manager, ok := t.dialer.(*exitManager); ok {
			manager.close()
		}
		// Closing the stack unblocks a pending ReadContext.
		t.stack.Close()
		select {
		case <-t.done:
		case <-time.After(2 * time.Second):
		}
	})
}
