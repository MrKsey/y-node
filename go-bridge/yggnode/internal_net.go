package yggnode

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// The app process sits outside the VPN: Android excludes it so the node itself
// can dial peers and the app never depends on its own tunnel. That also means a
// plain socket of the app cannot reach a Yggdrasil address. The pieces below
// give the node a small userspace stack of its own, so it can open DNS and HTTP
// connections *through* Yggdrasil for the UI (DNS health, the web directory).
//
// The stack is multiplexed with the tunnel by port: its connections are bound
// to a reserved local port range that the kernel never hands out for outgoing
// connections, and Recv routes packets for those ports here instead of to the
// TUN.
const (
	internalNIC tcpip.NICID = 4

	internalPortBase  = 61000
	internalPortCount = 900

	internalQueue = 64

	// internalFragmentTTL is how long a fragment id stays associated with the
	// internal stack. The fragments of one datagram arrive within milliseconds;
	// the window only has to outlive a slow reassembly.
	internalFragmentTTL = 30 * time.Second

	// internalFragmentLimit bounds the fragment table so a flood of foreign
	// fragments cannot grow it without limit.
	internalFragmentLimit = 256
)

type internalNet struct {
	stack *stack.Stack
	link  *channel.Endpoint
	write func([]byte) error
	log   *goLogger

	addr tcpip.Address

	cancel context.CancelFunc
	done   chan struct{}
	once   sync.Once

	mu       sync.Mutex
	nextPort uint16

	fragMu sync.Mutex
	frags  map[uint32]time.Time
}

func newInternalNet(
	mtu int,
	address string,
	write func([]byte) error,
	log *goLogger,
) (*internalNet, error) {
	ip := net.ParseIP(strings.TrimSpace(address))
	if ip == nil || ip.To4() != nil {
		return nil, fmt.Errorf("internal stack needs an IPv6 address, got %q", address)
	}
	if mtu < 1280 {
		mtu = 1280
	}

	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})

	link := channel.New(internalQueue, uint32(mtu), "")
	if err := s.CreateNIC(internalNIC, link); err != nil {
		return nil, fmt.Errorf("internal NIC: %v", err)
	}
	addr := tcpip.AddrFromSlice(ip.To16())
	err := s.AddProtocolAddress(
		internalNIC,
		tcpip.ProtocolAddress{
			Protocol: ipv6.ProtocolNumber,
			AddressWithPrefix: tcpip.AddressWithPrefix{
				Address:   addr,
				PrefixLen: 128,
			},
		},
		stack.AddressProperties{},
	)
	if err != nil {
		return nil, fmt.Errorf("internal address %s: %v", address, err)
	}
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv6EmptySubnet, NIC: internalNIC},
	})

	ctx, cancel := context.WithCancel(context.Background())
	t := &internalNet{
		stack:    s,
		link:     link,
		write:    write,
		log:      log,
		addr:     addr,
		cancel:   cancel,
		done:     make(chan struct{}),
		nextPort: internalPortBase + 1,
	}
	go t.pumpOutbound(ctx)
	return t, nil
}

// pumpOutbound hands every packet of the internal stack to the node. The stack
// only ever dials Yggdrasil addresses, so no other route is needed.
func (t *internalNet) pumpOutbound(ctx context.Context) {
	defer close(t.done)
	for {
		pkt := t.link.ReadContext(ctx)
		if pkt == nil {
			return
		}
		view := pkt.ToView()
		if view != nil {
			if err := t.write(view.AsSlice()); err != nil {
				t.log.emit("debug", "internal net: send failed: %v", err)
			}
		}
		pkt.DecRef()
	}
}

// owns reports whether the packet belongs to a connection of this stack: IPv6,
// TCP or UDP, addressed to the node, with a destination port from the reserved
// range.
//
// A datagram larger than the Yggdrasil MTU arrives fragmented, and only the
// first fragment carries the transport header. The id of a fragment that
// belongs to an owned port is remembered, so the remaining fragments of the
// same datagram follow it into the stack instead of the TUN.
func (t *internalNet) owns(packet []byte) bool {
	if len(packet) < 40 || packet[0]>>4 != 6 {
		return false
	}
	if !tcpip.AddrFromSlice(packet[24:40]).Equal(t.addr) {
		return false
	}
	next := packet[6]
	offset := 40
	for depth := 0; depth < 8; depth++ {
		switch next {
		case 0, 43, 60: // hop-by-hop, routing, destination options
			if offset+2 > len(packet) {
				return false
			}
			length := (int(packet[offset+1]) + 1) * 8
			next, offset = packet[offset], offset+length
			if offset > len(packet) {
				return false
			}
		case 51: // authentication header
			if offset+2 > len(packet) {
				return false
			}
			length := (int(packet[offset+1]) + 2) * 4
			next, offset = packet[offset], offset+length
			if offset > len(packet) {
				return false
			}
		case 44: // fragment header
			if offset+8 > len(packet) {
				return false
			}
			upper := packet[offset]
			fragmentOffset := binary.BigEndian.Uint16(packet[offset+2:offset+4]) >> 3
			id := binary.BigEndian.Uint32(packet[offset+4 : offset+8])
			offset += 8
			if fragmentOffset != 0 {
				return t.ownedFragment(id)
			}
			if upper != 6 && upper != 17 {
				return false
			}
			if offset+4 > len(packet) {
				return false
			}
			if !t.portOwned(binary.BigEndian.Uint16(packet[offset+2 : offset+4])) {
				return false
			}
			t.rememberFragment(id)
			return true
		default:
			if next != 6 && next != 17 || offset+4 > len(packet) {
				return false
			}
			return t.portOwned(binary.BigEndian.Uint16(packet[offset+2 : offset+4]))
		}
	}
	return false
}

func (t *internalNet) portOwned(port uint16) bool {
	return port >= internalPortBase && port < internalPortBase+internalPortCount
}

func (t *internalNet) rememberFragment(id uint32) {
	now := time.Now()
	t.fragMu.Lock()
	if t.frags == nil {
		t.frags = make(map[uint32]time.Time)
	}
	if len(t.frags) >= internalFragmentLimit {
		for key, expires := range t.frags {
			if now.After(expires) {
				delete(t.frags, key)
			}
		}
		for key := range t.frags {
			if len(t.frags) < internalFragmentLimit {
				break
			}
			delete(t.frags, key)
		}
	}
	t.frags[id] = now.Add(internalFragmentTTL)
	t.fragMu.Unlock()
}

func (t *internalNet) ownedFragment(id uint32) bool {
	now := time.Now()
	t.fragMu.Lock()
	defer t.fragMu.Unlock()
	expires, ok := t.frags[id]
	if !ok {
		return false
	}
	if now.After(expires) {
		delete(t.frags, id)
		return false
	}
	return true
}

// inject hands one packet read from the node to the stack.
func (t *internalNet) inject(packet []byte) {
	if len(packet) < 40 {
		return
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(append([]byte(nil), packet...)),
	})
	defer pkt.DecRef()
	t.link.InjectInbound(ipv6.ProtocolNumber, pkt)
}

// dialContext opens a connection into Yggdrasil. Used by the HTTP client and by
// the DNS check.
func (t *internalNet) dialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	ip := net.ParseIP(host)
	if ip == nil || ip.To4() != nil {
		return nil, fmt.Errorf("not an IPv6 destination: %q", host)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port <= 0 || port > 65535 {
		return nil, fmt.Errorf("bad port %q", portStr)
	}
	remote := tcpip.FullAddress{
		NIC:  internalNIC,
		Addr: tcpip.AddrFromSlice(ip.To16()),
		Port: uint16(port),
	}

	// A port can be taken by a previous connection that is still closing; try a
	// handful before giving up.
	var lastErr error
	for attempt := 0; attempt < 8; attempt++ {
		local := tcpip.FullAddress{
			NIC:  internalNIC,
			Addr: t.addr,
			Port: t.takePort(),
		}
		switch network {
		case "tcp", "tcp6":
			conn, derr := gonet.DialTCPWithBind(ctx, t.stack, local, remote, ipv6.ProtocolNumber)
			if derr == nil {
				return conn, nil
			}
			lastErr = derr
		case "udp", "udp6":
			conn, derr := gonet.DialUDP(t.stack, &local, &remote, ipv6.ProtocolNumber)
			if derr == nil {
				return conn, nil
			}
			lastErr = derr
		default:
			return nil, fmt.Errorf("unsupported network %q", network)
		}
	}
	if lastErr == nil {
		lastErr = errors.New("no local port available")
	}
	return nil, lastErr
}

func (t *internalNet) takePort() uint16 {
	t.mu.Lock()
	defer t.mu.Unlock()
	port := t.nextPort
	t.nextPort++
	if t.nextPort >= internalPortBase+internalPortCount {
		t.nextPort = internalPortBase + 1
	}
	return port
}

func (t *internalNet) stop() {
	t.once.Do(func() {
		if t.cancel != nil {
			t.cancel()
		}
		t.stack.Close()
		select {
		case <-t.done:
		case <-time.After(2 * time.Second):
		}
	})
}

// ---------------------------------------------------------------------------
// DNS check
// ---------------------------------------------------------------------------

type dnsCheck struct {
	Server  string  `json:"server"`
	OK      bool    `json:"ok"`
	Ms      float64 `json:"ms"`
	Via     string  `json:"via"`
	Rcode   int     `json:"rcode"`
	Error   string  `json:"error"`
	Name    string  `json:"name"`
	Address string  `json:"address"`
}

// checkDNSNames are the in-network names every resolver is asked about. A
// single name is not enough: a zone can lose one record while the server keeps
// working, and a resolver that answers for any of them is fine for the tunnel.
var checkDNSNames = []string{
	"rutor.ygg",
	"rutracker.ygg",
	"howto.ygg",
	"sites.ygg",
}

// CheckDNS asks every server in the JSON array to resolve real in-network names
// through the node and reports the address and the round-trip time. A plain
// socket test would only prove the port is open; a name lookup proves the server
// actually resolves.
func (n *Node) CheckDNS(serversJSON string, timeoutMs int) string {
	var servers []string
	if err := json.Unmarshal([]byte(serversJSON), &servers); err != nil {
		return `[{"error":"bad server list"}]`
	}
	if timeoutMs < 500 {
		timeoutMs = 3000
	}
	if timeoutMs > 15000 {
		timeoutMs = 15000
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond

	out := make([]dnsCheck, 0, len(servers))
	for _, server := range servers {
		server = strings.TrimSpace(server)
		if server == "" {
			continue
		}
		out = append(out, n.checkOneDNS(server, timeout))
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(b)
}

func (n *Node) checkOneDNS(server string, timeout time.Duration) dnsCheck {
	result := dnsCheck{Server: server, Rcode: -1, Name: checkDNSNames[0]}
	inner := n.internal()
	if inner == nil {
		result.Error = "the node is not running"
		return result
	}

names:
	for _, name := range checkDNSNames {
		result.Name = name
		query := dnsQuery(0x5947, name, 28) // AAAA
		for _, via := range []string{"udp", "tcp"} {
			started := time.Now()
			reply, err := queryDNS(inner, via, server, query, timeout)
			if err != nil {
				// The server does not answer at all: another name will not help.
				result.Error = err.Error()
				break names
			}
			if len(reply) < 12 || binary.BigEndian.Uint16(reply[0:2]) != 0x5947 {
				result.Error = "bad DNS reply"
				continue
			}
			flags := binary.BigEndian.Uint16(reply[2:4])
			if flags&0x8000 == 0 {
				result.Error = "not a DNS response"
				continue
			}
			rcode := int(flags & 0x000F)
			result.Rcode = rcode
			if rcode != 0 {
				result.Error = rcodeText(rcode)
				if rcode == 3 {
					// The resolver works, this particular name is gone.
					continue names
				}
				continue
			}
			address, answers := parseDNSAnswer(reply)
			if answers == 0 || address == "" {
				result.Error = "no AAAA record for " + name
				continue names
			}
			result.OK = true
			result.Via = via
			result.Address = address
			result.Ms = float64(time.Since(started).Microseconds()) / 1000.0
			result.Error = ""
			return result
		}
	}
	if result.Error == "" {
		result.Error = "no response"
	}
	return result
}

func rcodeText(rcode int) string {
	switch rcode {
	case 1:
		return "server could not parse the query"
	case 2:
		return "server failure"
	case 3:
		return "name does not exist"
	case 4:
		return "query type not supported"
	case 5:
		return "query refused"
	default:
		return fmt.Sprintf("DNS error %d", rcode)
	}
}

// dnsQuery builds an AAAA query for [name] with the given transaction id.
func dnsQuery(id uint16, name string, qtype uint16) []byte {
	msg := make([]byte, 12, 12+len(name)+6)
	binary.BigEndian.PutUint16(msg[0:2], id)
	binary.BigEndian.PutUint16(msg[2:4], 0x0100) // recursion desired
	binary.BigEndian.PutUint16(msg[4:6], 1)      // one question
	for _, label := range strings.Split(strings.Trim(name, "."), ".") {
		if label == "" || len(label) > 63 {
			continue
		}
		msg = append(msg, byte(len(label)))
		msg = append(msg, label...)
	}
	msg = append(msg, 0)
	msg = binary.BigEndian.AppendUint16(msg, qtype)
	msg = binary.BigEndian.AppendUint16(msg, 1) // IN
	return msg
}

// parseDNSAnswer returns the first AAAA address of the answer section and the
// number of resource records it walked. Only the address matters: it proves the
// resolver produced a usable answer, not just an empty NOERROR.
func parseDNSAnswer(msg []byte) (string, int) {
	if len(msg) < 12 {
		return "", 0
	}
	questions := int(binary.BigEndian.Uint16(msg[4:6]))
	records := int(binary.BigEndian.Uint16(msg[6:8]))

	offset := 12
	for i := 0; i < questions; i++ {
		next, ok := skipDNSName(msg, offset)
		if !ok || next+4 > len(msg) {
			return "", 0
		}
		offset = next + 4
	}

	answers := 0
	for i := 0; i < records; i++ {
		next, ok := skipDNSName(msg, offset)
		if !ok || next+10 > len(msg) {
			break
		}
		kind := binary.BigEndian.Uint16(msg[next : next+2])
		length := int(binary.BigEndian.Uint16(msg[next+8 : next+10]))
		start := next + 10
		if start+length > len(msg) {
			break
		}
		answers++
		if kind == 28 && length == 16 {
			return net.IP(msg[start : start+16]).String(), answers
		}
		offset = start + length
	}
	return "", answers
}

// skipDNSName walks a possibly compressed name and returns the offset just past
// it.
func skipDNSName(msg []byte, offset int) (int, bool) {
	for {
		if offset >= len(msg) {
			return 0, false
		}
		length := int(msg[offset])
		switch {
		case length == 0:
			return offset + 1, true
		case length&0xC0 == 0xC0:
			if offset+2 > len(msg) {
				return 0, false
			}
			return offset + 2, true
		case length&0xC0 != 0:
			return 0, false
		default:
			offset += 1 + length
		}
	}
}

func queryDNS(inner *internalNet, via, server string, query []byte, timeout time.Duration) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	conn, err := inner.dialContext(ctx, via, dnsEndpoint(server))
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	if via == "tcp" {
		payload := make([]byte, 2+len(query))
		binary.BigEndian.PutUint16(payload[0:2], uint16(len(query)))
		copy(payload[2:], query)
		if _, err := conn.Write(payload); err != nil {
			return nil, err
		}
		var size [2]byte
		if _, err := io.ReadFull(conn, size[:]); err != nil {
			return nil, err
		}
		length := int(binary.BigEndian.Uint16(size[:]))
		if length < 12 || length > 65535 {
			return nil, errors.New("bad DNS length")
		}
		reply := make([]byte, length)
		if _, err := io.ReadFull(conn, reply); err != nil {
			return nil, err
		}
		return reply, nil
	}

	if _, err := conn.Write(query); err != nil {
		return nil, err
	}
	reply := make([]byte, 1500)
	read, err := conn.Read(reply)
	if err != nil {
		return nil, err
	}
	return reply[:read], nil
}

// ---------------------------------------------------------------------------
// Page fetch
// ---------------------------------------------------------------------------

type fetchResult struct {
	Status int    `json:"status"`
	Body   string `json:"body"`
	Error  string `json:"error"`
}

// FetchURL reads one Yggdrasil page through the node. It exists for the web
// directory in the address book: the app cannot open the page itself, and the
// browser can only show it to the user, not to the app.
func (n *Node) FetchURL(rawURL string, timeoutMs int) string {
	fail := func(message string) string {
		b, _ := json.Marshal(fetchResult{Error: message})
		return string(b)
	}

	parsed, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || parsed.Host == "" {
		return fail("bad URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return fail("only http and https are supported")
	}
	if ip := net.ParseIP(parsed.Hostname()); ip == nil || !yggRange.Contains(ip) {
		return fail("the address is outside Yggdrasil")
	}

	inner := n.internal()
	if inner == nil {
		return fail("the node is not running")
	}
	if timeoutMs < 1000 {
		timeoutMs = 20000
	}
	if timeoutMs > 60000 {
		timeoutMs = 60000
	}

	client := &http.Client{
		Timeout: time.Duration(timeoutMs) * time.Millisecond,
		Transport: &http.Transport{
			DialContext:         inner.dialContext,
			DisableKeepAlives:   true,
			ForceAttemptHTTP2:   false,
			TLSHandshakeTimeout: time.Duration(timeoutMs) * time.Millisecond,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			return nil
		},
	}
	defer client.CloseIdleConnections()

	response, err := client.Get(parsed.String())
	if err != nil {
		return fail(err.Error())
	}
	defer response.Body.Close()

	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return fail(err.Error())
	}
	out := fetchResult{Status: response.StatusCode, Body: string(body)}
	b, err := json.Marshal(out)
	if err != nil {
		return fail("could not encode the response")
	}
	return string(b)
}
