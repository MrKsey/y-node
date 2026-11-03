package yggnode

import (
	"encoding/binary"
	"net"
	"testing"

	"gvisor.dev/gvisor/pkg/tcpip"
)

// ipv6Packet builds the header of one IPv6 packet with the given next header
// and transport bytes.
func ipv6Packet(next byte, src, dst net.IP, transport []byte) []byte {
	packet := make([]byte, 40, 40+len(transport))
	packet[0] = 0x60
	binary.BigEndian.PutUint16(packet[4:6], uint16(len(transport)))
	packet[6] = next
	packet[7] = 64
	copy(packet[8:24], src.To16())
	copy(packet[24:40], dst.To16())
	return append(packet, transport...)
}

// udpHeader returns a UDP header with the given destination port.
func udpHeader(port uint16) []byte {
	header := make([]byte, 8)
	binary.BigEndian.PutUint16(header[0:2], 5555)
	binary.BigEndian.PutUint16(header[2:4], port)
	return header
}

func TestInternalNetOwnsPlainPackets(t *testing.T) {
	node := net.ParseIP("200::1")
	other := net.ParseIP("200::2")
	internal := &internalNet{addr: tcpip.AddrFromSlice(node.To16())}

	if !internal.owns(ipv6Packet(17, other, node, udpHeader(internalPortBase+5))) {
		t.Fatal("a datagram to a reserved port was not recognised")
	}
	if internal.owns(ipv6Packet(17, other, node, udpHeader(53))) {
		t.Fatal("a datagram to port 53 was taken for an internal one")
	}
	if internal.owns(ipv6Packet(6, other, other, udpHeader(internalPortBase+5))) {
		t.Fatal("a packet to another address was taken for an internal one")
	}
	if internal.owns(ipv6Packet(58, other, node, udpHeader(internalPortBase+5))) {
		t.Fatal("an ICMPv6 packet was taken for an internal one")
	}
}

func TestInternalNetOwnsFragments(t *testing.T) {
	node := net.ParseIP("200::1")
	other := net.ParseIP("200::2")
	internal := &internalNet{addr: tcpip.AddrFromSlice(node.To16())}

	fragment := func(offset uint16, id uint32, more bool, transport []byte) []byte {
		header := make([]byte, 8)
		header[0] = 17
		flags := offset << 3
		if more {
			flags |= 1
		}
		binary.BigEndian.PutUint16(header[2:4], flags)
		binary.BigEndian.PutUint32(header[4:8], id)
		return ipv6Packet(44, other, node, append(header, transport...))
	}

	first := fragment(0, 0x11223344, true, udpHeader(internalPortBase+7))
	if !internal.owns(first) {
		t.Fatal("the first fragment of an internal datagram was not recognised")
	}
	if !internal.owns(fragment(185, 0x11223344, false, make([]byte, 8))) {
		t.Fatal("a later fragment of an internal datagram was not recognised")
	}
	if internal.owns(fragment(185, 0x55667788, false, make([]byte, 8))) {
		t.Fatal("a fragment of a foreign datagram was taken for an internal one")
	}
	if internal.owns(fragment(0, 0x99AABBCC, true, udpHeader(53))) {
		t.Fatal("the first fragment of a datagram to port 53 was taken for an internal one")
	}
}
