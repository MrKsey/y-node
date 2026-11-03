package yggnode

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParsePublicIP(t *testing.T) {
	body := "fl=1255f34\nh=1.1.1.1\nip=160.20.158.195\nts=1793533997.000\nloc=FI\n"
	got, err := parsePublicIP(body)
	if err != nil {
		t.Fatal(err)
	}
	if got != "160.20.158.195" {
		t.Fatalf("address = %q, want 160.20.158.195", got)
	}
}

func TestParsePublicIPKeepsIPv6(t *testing.T) {
	got, err := parsePublicIP("ip=2a02:8109:9c3f:ac00:1::1\n")
	if err != nil {
		t.Fatal(err)
	}
	if got != "2a02:8109:9c3f:ac00:1::1" {
		t.Fatalf("address = %q", got)
	}
}

func TestParsePublicIPRejectsGarbage(t *testing.T) {
	if _, err := parsePublicIP("<html>blocked</html>"); err == nil {
		t.Fatal("a page without ip= must fail")
	}
	if _, err := parsePublicIP("ip=not-an-address\n"); err == nil {
		t.Fatal("a bad address must fail")
	}
}

func TestPublicIPWithoutExit(t *testing.T) {
	node := NewNode()
	var result publicIPResult
	if err := json.Unmarshal([]byte(node.PublicIP("exit", 2000)), &result); err != nil {
		t.Fatal(err)
	}
	if result.OK || result.Error != "exit_off" || result.Via != "exit" {
		t.Fatalf("unexpected result %+v", result)
	}
}

func TestPublicIPRejectsUnknownMode(t *testing.T) {
	node := NewNode()
	raw := node.PublicIP("carrier-pigeon", 2000)
	if !strings.Contains(raw, `"error":"bad_mode"`) {
		t.Fatalf("unexpected result %s", raw)
	}
}
