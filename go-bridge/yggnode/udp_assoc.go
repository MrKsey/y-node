package yggnode

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

// The client half of the RFC 1928 UDP relay.
//
// One SOCKS5 UDP association carries every datagram of one exit profile: the
// TCP control connection that opened it and the UDP socket the exit named in
// its reply. Datagrams for different destinations share that socket, so each
// forwarded flow registers itself under its destination address and the read
// loop hands every answer to the flows waiting for that address.

const (
	// udpFlowBuffer is the largest datagram the relay can carry: the SOCKS5
	// header plus the payload must fit into one UDP datagram.
	udpFlowBuffer = 65535

	// udpFlowQueue is the number of datagrams buffered for one flow. A QUIC
	// session can burst, but a flow whose reader is stuck must not stall the
	// whole association.
	udpFlowQueue = 64

	// udpAssociationIdle ends a relay that carried no datagram for this long.
	// It stays below the exit default (two minutes) on purpose: a phone that
	// was asleep never sees the exit close the control connection, and the next
	// datagram would go into a relay the exit has already forgotten. Letting go
	// first makes that datagram open a fresh association.
	udpAssociationIdle = 45 * time.Second
)

var (
	// errUDPDisabled is returned instead of a direct connection when the user
	// turned UDP through the exit off. Callers drop the datagram: falling back
	// to the phone's own network would leak it around the exit.
	errUDPDisabled = errors.New("UDP through the exit node is disabled")

	// errUDPNoAssociation means the exit could not be reached for UDP.
	errUDPNoAssociation = errors.New("no exit node carries UDP right now")

	// errExitStopped is returned after the forwarding stack was torn down.
	errExitStopped = errors.New("the forwarding stack is stopped")
)

// socksUDPAssociation is one live UDP association with an exit node.
type socksUDPAssociation struct {
	manager *exitManager
	profile ExitProfile
	control net.Conn
	relay   net.Conn
	log     *goLogger

	mu     sync.Mutex
	flows  map[string][]*udpFlowConn
	closed bool
	reason error

	// writeMu serializes the writes of every flow into the shared socket.
	writeMu sync.Mutex

	datagramsIn  atomic.Uint64
	datagramsOut atomic.Uint64
	bytesIn      atomic.Uint64
	bytesOut     atomic.Uint64

	// lastActivity is the unix-nano time of the last datagram in either
	// direction. A silent association is dropped before the exit drops it.
	lastActivity atomic.Int64

	// lastIn is the time of the last datagram the exit sent back. Writes into
	// a dead relay succeed locally, so a stream of unanswered datagrams is the
	// sign that the exit has forgotten the association.
	lastIn atomic.Int64

	done      chan struct{}
	closeOnce sync.Once
}

func newSocksUDPAssociation(
	manager *exitManager,
	profile ExitProfile,
	control net.Conn,
	relay net.Conn,
	log *goLogger,
) *socksUDPAssociation {
	association := &socksUDPAssociation{
		manager: manager,
		profile: profile,
		control: control,
		relay:   relay,
		log:     log,
		flows:   make(map[string][]*udpFlowConn),
		done:    make(chan struct{}),
	}
	association.touch()
	association.lastIn.Store(time.Now().UnixNano())
	return association
}

// start launches the loops that keep the association alive: the relay reader,
// the watcher of the control connection and the idle timer.
func (a *socksUDPAssociation) start() {
	go a.readLoop()
	go a.watchControl()
	go a.idleWatch()
}

// touch records that the association carried a datagram just now.
func (a *socksUDPAssociation) touch() {
	a.lastActivity.Store(time.Now().UnixNano())
}

// idleFor reports how long the association has been silent.
func (a *socksUDPAssociation) idleFor() time.Duration {
	last := a.lastActivity.Load()
	if last == 0 {
		return 0
	}
	return time.Since(time.Unix(0, last))
}

// expired reports whether the association looks dead. The exit forgets an
// association that stayed silent past its own idle timeout, and a phone that
// was asleep never saw the close. A stream of datagrams that never gets an
// answer is the second sign: writes into a forgotten relay succeed locally.
func (a *socksUDPAssociation) expired() bool {
	if a.idleFor() >= udpAssociationIdle {
		return true
	}
	return a.datagramsOut.Load() > 0 &&
		time.Since(time.Unix(0, a.lastIn.Load())) >= udpAssociationIdle
}

// idleWatch drops the association once it stayed silent long enough. It also
// releases the sockets of a phone that was suspended, where no FIN ever
// arrived to end the control connection.
func (a *socksUDPAssociation) idleWatch() {
	ticker := time.NewTicker(udpAssociationIdle / 3)
	defer ticker.Stop()
	for {
		select {
		case <-a.done:
			return
		case <-ticker.C:
			if a.expired() {
				a.close(nil)
				return
			}
		}
	}
}

func (a *socksUDPAssociation) isAlive() bool {
	select {
	case <-a.done:
		return false
	default:
		return true
	}
}

// readLoop dispatches the datagrams the exit sends back to the flows that wait
// for the matching destination.
func (a *socksUDPAssociation) readLoop() {
	buf := make([]byte, udpFlowBuffer)
	for {
		n, err := a.relay.Read(buf)
		if err != nil {
			a.close(fmt.Errorf("the UDP relay socket failed: %w", err))
			return
		}
		if n < 4 {
			continue
		}
		ip, port, payload, ok := parseUDPRelayDatagram(buf[:n])
		if !ok || len(payload) == 0 {
			continue
		}
		a.datagramsIn.Add(1)
		a.bytesIn.Add(uint64(len(payload)))
		a.lastIn.Store(time.Now().UnixNano())
		a.touch()
		a.manager.noteUDPTraffic(1, 0, uint64(len(payload)), 0)

		// Every flow registered for the destination gets its own copy of the
		// datagram: two sockets of the same app may talk to one server, and a
		// flow that is not interested drops it itself.
		delivered := append([]byte(nil), payload...)
		key := joinUDPKey(ip, port)
		a.mu.Lock()
		flows := append([]*udpFlowConn(nil), a.flows[key]...)
		a.mu.Unlock()
		for _, flow := range flows {
			flow.deliver(delivered)
		}
	}
}

// watchControl ends the association as soon as the exit closes the control
// connection. The exit never writes on it, so a read that returns means the
// relay socket is gone or the idle timeout expired.
func (a *socksUDPAssociation) watchControl() {
	buf := make([]byte, 256)
	for {
		n, err := a.control.Read(buf)
		if err != nil {
			// An orderly close is the idle timeout of the exit or its restart:
			// the next datagram opens a fresh association, so the card must not
			// report a failure. Anything else is a real error.
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				a.close(nil)
			} else {
				a.close(fmt.Errorf("the exit closed the UDP association: %w", err))
			}
			return
		}
		if n == 0 {
			continue
		}
	}
}

func (a *socksUDPAssociation) openFlow(ip net.IP, port int) (*udpFlowConn, error) {
	flow := &udpFlowConn{
		assoc: a,
		ip:    append(net.IP(nil), ip...),
		port:  port,
		key:   joinUDPKey(ip, port),
		in:    make(chan []byte, udpFlowQueue),
		done:  make(chan struct{}),
		wake:  make(chan struct{}),
	}
	a.mu.Lock()
	if a.closed {
		reason := a.reason
		a.mu.Unlock()
		if reason == nil {
			reason = net.ErrClosed
		}
		return nil, reason
	}
	a.flows[flow.key] = append(a.flows[flow.key], flow)
	a.mu.Unlock()
	a.touch()
	return flow, nil
}

func (a *socksUDPAssociation) removeFlow(flow *udpFlowConn) {
	a.mu.Lock()
	flows := a.flows[flow.key]
	for i, item := range flows {
		if item == flow {
			flows = append(flows[:i], flows[i+1:]...)
			break
		}
	}
	if len(flows) == 0 {
		delete(a.flows, flow.key)
	} else {
		a.flows[flow.key] = flows
	}
	a.mu.Unlock()
}

// writeDatagram sends one already framed datagram to the relay socket.
func (a *socksUDPAssociation) writeDatagram(packet []byte) error {
	a.writeMu.Lock()
	defer a.writeMu.Unlock()
	if _, err := a.relay.Write(packet); err != nil {
		return err
	}
	a.touch()
	return nil
}

// close releases the sockets and fails every flow of the association.
func (a *socksUDPAssociation) close(reason error) {
	a.closeOnce.Do(func() {
		a.mu.Lock()
		a.closed = true
		a.reason = reason
		flows := make([]*udpFlowConn, 0, len(a.flows))
		for _, list := range a.flows {
			flows = append(flows, list...)
		}
		a.flows = make(map[string][]*udpFlowConn)
		a.mu.Unlock()

		_ = a.control.Close()
		_ = a.relay.Close()
		close(a.done)
		for _, flow := range flows {
			_ = flow.Close()
		}
		a.manager.dropUDPAssociation(a, reason)
		if reason != nil {
			a.log.emit("debug", "exit %s: UDP association closed: %v", a.profile.Name, reason)
		} else {
			a.log.emit("debug", "exit %s: UDP association ended", a.profile.Name)
		}
	})
}

// stats returns the counters of this association for the log.
func (a *socksUDPAssociation) stats() (in, out, bytesIn, bytesOut uint64) {
	return a.datagramsIn.Load(), a.datagramsOut.Load(), a.bytesIn.Load(), a.bytesOut.Load()
}

// udpFlowConn is one forwarded UDP flow: it looks like a connected datagram
// socket to the tun2socks relay, but every write becomes one RFC 1928 datagram
// on the shared association.
type udpFlowConn struct {
	assoc *socksUDPAssociation
	ip    net.IP
	port  int
	key   string

	in        chan []byte
	done      chan struct{}
	closeOnce sync.Once

	mu            sync.Mutex
	readDeadline  time.Time
	writeDeadline time.Time
	wake          chan struct{}
}

func (c *udpFlowConn) Read(p []byte) (int, error) {
	for {
		c.mu.Lock()
		deadline := c.readDeadline
		wake := c.wake
		c.mu.Unlock()

		var timer *time.Timer
		var timeout <-chan time.Time
		if !deadline.IsZero() {
			remaining := time.Until(deadline)
			if remaining <= 0 {
				return 0, os.ErrDeadlineExceeded
			}
			timer = time.NewTimer(remaining)
			timeout = timer.C
		}

		select {
		case data := <-c.in:
			stopTimer(timer)
			// A datagram larger than the caller's buffer is truncated, which is
			// what a real datagram socket does as well.
			return copy(p, data), nil
		case <-c.done:
			stopTimer(timer)
			return 0, net.ErrClosed
		case <-timeout:
			return 0, os.ErrDeadlineExceeded
		case <-wake:
			stopTimer(timer)
		}
	}
}

func (c *udpFlowConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if len(p) > udpFlowBuffer-socksUDPHeaderMax {
		return 0, fmt.Errorf("datagram of %d bytes is too large for the UDP relay", len(p))
	}
	c.mu.Lock()
	deadline := c.writeDeadline
	c.mu.Unlock()
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return 0, os.ErrDeadlineExceeded
	}
	select {
	case <-c.done:
		return 0, net.ErrClosed
	default:
	}
	packet := buildUDPRelayDatagram(c.ip, c.port, p)
	if err := c.assoc.writeDatagram(packet); err != nil {
		return 0, err
	}
	c.assoc.datagramsOut.Add(1)
	c.assoc.bytesOut.Add(uint64(len(p)))
	c.assoc.manager.noteUDPTraffic(0, 1, 0, uint64(len(p)))
	return len(p), nil
}

// deliver queues one datagram for the reader. A full queue drops the oldest
// datagram instead of blocking the association: a slow flow must not stop the
// traffic of the others.
func (c *udpFlowConn) deliver(payload []byte) {
	select {
	case <-c.done:
		return
	default:
	}
	select {
	case c.in <- payload:
		return
	default:
	}
	select {
	case <-c.in:
	default:
	}
	select {
	case c.in <- payload:
	default:
	}
}

func (c *udpFlowConn) Close() error {
	c.closeOnce.Do(func() {
		close(c.done)
		c.assoc.removeFlow(c)
	})
	return nil
}

func (c *udpFlowConn) LocalAddr() net.Addr { return c.assoc.relay.LocalAddr() }

func (c *udpFlowConn) RemoteAddr() net.Addr {
	return &net.UDPAddr{IP: c.ip, Port: c.port}
}

func (c *udpFlowConn) SetDeadline(t time.Time) error {
	_ = c.SetReadDeadline(t)
	return c.SetWriteDeadline(t)
}

func (c *udpFlowConn) SetReadDeadline(t time.Time) error {
	c.mu.Lock()
	c.readDeadline = t
	// Waking the blocked reader makes it re-read the new deadline at once.
	if c.wake != nil {
		close(c.wake)
	}
	c.wake = make(chan struct{})
	c.mu.Unlock()
	return nil
}

func (c *udpFlowConn) SetWriteDeadline(t time.Time) error {
	c.mu.Lock()
	c.writeDeadline = t
	c.mu.Unlock()
	return nil
}

func stopTimer(timer *time.Timer) {
	if timer != nil {
		timer.Stop()
	}
}

func joinUDPKey(ip net.IP, port int) string {
	return net.JoinHostPort(ip.String(), fmt.Sprintf("%d", port))
}

// parseUDPRelayDatagram parses the RFC 1928 UDP header of one answer. A
// fragment is refused: the exit never sends one, and reassembling would mean
// buffering datagrams nobody asked for.
func parseUDPRelayDatagram(packet []byte) (ip net.IP, port int, payload []byte, ok bool) {
	if len(packet) < 4 || packet[0] != 0 || packet[1] != 0 || packet[2] != 0 {
		return nil, 0, nil, false
	}
	offset := 4
	switch packet[3] {
	case socksAtypIPv4:
		if len(packet) < offset+4+2 {
			return nil, 0, nil, false
		}
		ip = net.IP(append([]byte(nil), packet[offset:offset+4]...))
		offset += 4
	case socksAtypIPv6:
		if len(packet) < offset+16+2 {
			return nil, 0, nil, false
		}
		ip = net.IP(append([]byte(nil), packet[offset:offset+16]...))
		offset += 16
	default:
		return nil, 0, nil, false
	}
	port = int(binary.BigEndian.Uint16(packet[offset : offset+2]))
	offset += 2
	return ip, port, packet[offset:], true
}

// buildUDPRelayDatagram wraps one payload into the RFC 1928 UDP header.
func buildUDPRelayDatagram(ip net.IP, port int, payload []byte) []byte {
	var packet []byte
	if v4 := ip.To4(); v4 != nil {
		packet = make([]byte, 0, 10+len(payload))
		packet = append(packet, 0, 0, 0, socksAtypIPv4)
		packet = append(packet, v4...)
	} else {
		packet = make([]byte, 0, 22+len(payload))
		packet = append(packet, 0, 0, 0, socksAtypIPv6)
		packet = append(packet, ip.To16()...)
	}
	packet = binary.BigEndian.AppendUint16(packet, uint16(port))
	return append(packet, payload...)
}
