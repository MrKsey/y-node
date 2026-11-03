package yggnode

import (
	"encoding/binary"
	"encoding/json"
	"net"
	"testing"
)

// dnsAAAAAnswer builds one AAAA answer with the given transaction id and
// address.
func dnsAAAAAnswer(id uint16, name string, ip net.IP) []byte {
	msg := buildDNSQueryAAAA(id, name)
	binary.BigEndian.PutUint16(msg[2:4], 0x8180)
	binary.BigEndian.PutUint16(msg[6:8], 1)
	msg = append(msg, 0xC0, 0x0C)                // pointer to the question
	msg = binary.BigEndian.AppendUint16(msg, 28) // AAAA
	msg = binary.BigEndian.AppendUint16(msg, 1)  // IN
	msg = binary.BigEndian.AppendUint32(msg, 60)
	msg = binary.BigEndian.AppendUint16(msg, 16)
	return append(msg, ip.To16()...)
}

func TestBuildDNSQueryAAAA(t *testing.T) {
	query := buildDNSQueryAAAA(0x2468, "cloudflare.com")
	if len(query) < 12 {
		t.Fatalf("query is too short: %d", len(query))
	}
	if got := binary.BigEndian.Uint16(query[0:2]); got != 0x2468 {
		t.Fatalf("id = %#x", got)
	}
	name, qtype, ok := dnsQuestion(query)
	if !ok || name != "cloudflare.com" || qtype != dnsTypeAAAA {
		t.Fatalf("question = %q type %d ok %v", name, qtype, ok)
	}
}

func TestFirstDNSAAAA(t *testing.T) {
	want := net.ParseIP("2606:4700:4700::1111")
	msg := dnsAAAAAnswer(0x5151, "cloudflare.com", want)
	if got := firstDNSAAAA(msg, 0x5151); !got.Equal(want) {
		t.Fatalf("address = %v, want %v", got, want)
	}
	if got := firstDNSAAAA(msg, 0x9999); got != nil {
		t.Fatalf("a mismatched transaction id must be ignored, got %v", got)
	}
	// An A record is not an AAAA record: the two helpers must not accept each
	// other's answers.
	a := dnsAnswer(0x5151, "cloudflare.com", net.ParseIP("104.18.26.14"))
	if got := firstDNSAAAA(a, 0x5151); got != nil {
		t.Fatalf("an A answer was taken for an AAAA one: %v", got)
	}
	if got := firstDNSAddress(msg, 0x5151); got != nil {
		t.Fatalf("an AAAA answer was taken for an A record: %v", got)
	}
	// A truncated answer must not panic or produce an address.
	if got := firstDNSAAAA(msg[:len(msg)-4], 0x5151); got != nil {
		t.Fatalf("a truncated answer produced %v", got)
	}
}

func TestParseIPv6Trace(t *testing.T) {
	got, err := parseIPv6Trace("fl=1\nip=2a01:ecc0:5000:329::2\nts=1\n")
	if err != nil {
		t.Fatal(err)
	}
	if got != "2a01:ecc0:5000:329::2" {
		t.Fatalf("address = %q", got)
	}
	if _, err := parseIPv6Trace("ip=160.20.158.195\n"); err == nil {
		t.Fatal("an IPv4 answer must not pass the IPv6 check")
	}
	if _, err := parseIPv6Trace("<html>blocked</html>"); err == nil {
		t.Fatal("a page without ip= must fail")
	}
}

func TestTestExitIPv6ReportsNoExit(t *testing.T) {
	node := NewNode()
	result := decodeIPv6Probe(t, node.TestExitIPv6(5000))
	if result.State != "off" {
		t.Fatalf("state = %q, want off", result.State)
	}
	if result.OK {
		t.Fatal("the check must not pass without an exit")
	}
}

func TestTestExitIPv6ReportsDisabledExit(t *testing.T) {
	raw := `{"enabled":false,"profiles":[{"id":"p","name":"P","address":"200::1","socksPort":1080,"apiPort":1080}]}`
	manager, err := newExitManager(raw, nil, nil, &goLogger{})
	if err != nil {
		t.Fatal(err)
	}
	node := NewNode()
	node.running = true
	node.exit = manager

	result := decodeIPv6Probe(t, node.TestExitIPv6(5000))
	if result.State != "off" {
		t.Fatalf("state = %q, want off", result.State)
	}
}

func decodeIPv6Probe(t *testing.T, raw string) ipv6ProbeResult {
	t.Helper()
	var result ipv6ProbeResult
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("bad probe JSON %q: %v", raw, err)
	}
	return result
}
