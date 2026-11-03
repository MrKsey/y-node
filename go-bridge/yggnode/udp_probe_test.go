package yggnode

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"testing"
)

// dnsAnswer builds one A answer with the given transaction id and address.
func dnsAnswer(id uint16, name string, ip net.IP) []byte {
	msg := buildDNSQueryA(id, name)
	// Turn the query into a response: QR set, one answer.
	binary.BigEndian.PutUint16(msg[2:4], 0x8180)
	binary.BigEndian.PutUint16(msg[6:8], 1)
	// The answer name is a pointer to the question at offset 12.
	msg = append(msg, 0xC0, 0x0C)
	msg = binary.BigEndian.AppendUint16(msg, 1) // A
	msg = binary.BigEndian.AppendUint16(msg, 1) // IN
	msg = binary.BigEndian.AppendUint32(msg, 60)
	msg = binary.BigEndian.AppendUint16(msg, 4)
	return append(msg, ip.To4()...)
}

func TestBuildDNSQueryA(t *testing.T) {
	query := buildDNSQueryA(0x1234, "example.com")
	if len(query) < 12 {
		t.Fatalf("query is too short: %d", len(query))
	}
	if got := binary.BigEndian.Uint16(query[0:2]); got != 0x1234 {
		t.Fatalf("id = %#x", got)
	}
	if got := binary.BigEndian.Uint16(query[4:6]); got != 1 {
		t.Fatalf("question count = %d", got)
	}
	name, qtype, ok := dnsQuestion(query)
	if !ok || name != "example.com" || qtype != 1 {
		t.Fatalf("question = %q type %d ok %v", name, qtype, ok)
	}
}

func TestFirstDNSAddress(t *testing.T) {
	want := net.ParseIP("104.18.26.14")
	msg := dnsAnswer(0x4242, "cloudflare.com", want)
	if got := firstDNSAddress(msg, 0x4242); !got.Equal(want) {
		t.Fatalf("address = %v, want %v", got, want)
	}
	if got := firstDNSAddress(msg, 0x1111); got != nil {
		t.Fatalf("a mismatched transaction id must be ignored, got %v", got)
	}
	// A truncated answer must not panic or produce an address.
	if got := firstDNSAddress(msg[:len(msg)-2], 0x4242); got != nil {
		t.Fatalf("a truncated answer produced %v", got)
	}
}

func TestDescribeUDPError(t *testing.T) {
	cases := []struct {
		err  error
		want string
	}{
		{nil, ""},
		{errExitDropped, "the exit dropped the connection before the SOCKS5 greeting (connection limit?)"},
		{errUDPDisabled, "UDP through the exit node is turned off"},
		{io.EOF, "EOF"},
	}
	for _, tc := range cases {
		if got := describeUDPError(tc.err); got != tc.want {
			t.Fatalf("describeUDPError(%v) = %q, want %q", tc.err, got, tc.want)
		}
	}
	if got := describeUDPError(errors.Join(errExitDropped, io.EOF)); got != cases[1].want {
		t.Fatalf("a wrapped drop = %q", got)
	}
}

func TestTestExitUDPReportsDisabled(t *testing.T) {
	raw := `{"enabled":true,"profiles":[{"id":"p","name":"P","address":"200::1","socksPort":1080,"apiPort":1080}],"udp":false}`
	manager, err := newExitManager(raw, nil, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	node := NewNode()
	node.running = true
	node.exit = manager

	result := decodeUDPProbe(t, node.TestExitUDP(5000))
	if result.State != "disabled" {
		t.Fatalf("state = %q, want disabled", result.State)
	}
	if result.OK {
		t.Fatal("the check must not pass when UDP is off")
	}
}

func TestTestExitUDPReportsNoExit(t *testing.T) {
	node := NewNode()
	result := decodeUDPProbe(t, node.TestExitUDP(5000))
	if result.State != "off" {
		t.Fatalf("state = %q, want off", result.State)
	}
}

func decodeUDPProbe(t *testing.T, raw string) udpProbeResult {
	t.Helper()
	var result udpProbeResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("bad probe JSON %q: %v", raw, err)
	}
	return result
}
