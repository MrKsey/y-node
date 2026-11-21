package yggnode

import (
	"context"
	"encoding/binary"
	"testing"
	"time"
)

// answerOK turns a query into a successful response with no records: the race
// only has to see a usable answer, the address itself is not part of the test.
func answerOK(query []byte) []byte {
	response := append([]byte(nil), query...)
	flags := binary.BigEndian.Uint16(response[2:4])
	flags |= 0x8000
	flags |= 0x0080
	flags &^= 0x000F
	binary.BigEndian.PutUint16(response[2:4], flags)
	return response
}

// A dead resolver must not hold back the answer of a live one: the group is
// raced and the first usable answer wins.
func TestRaceResolversTakesTheFirstUsableAnswer(t *testing.T) {
	query := dnsQuery(0x1234, "example.ygg", dnsTypeAAAA)
	slow := "200::1"
	fast := "200::2"
	log := &goLogger{}
	started := time.Now()
	got := raceResolvers(context.Background(), []string{slow, fast}, query,
		func(_ context.Context, server string, query []byte) ([]byte, error) {
			if server == slow {
				time.Sleep(300 * time.Millisecond)
				return servfail(query), nil
			}
			return answerOK(query), nil
		}, log, "test")
	if dnsRcode(got) != 0 {
		t.Fatalf("race returned %s", dnsRcodeText(got))
	}
	if elapsed := time.Since(started); elapsed > 250*time.Millisecond {
		t.Fatalf("the slow resolver delayed the answer: %s", elapsed)
	}
}

// A SERVFAIL describes the moment, not the name: it must never be cached for
// the TTL of the answer section.
func TestDNSErrorAnswerIsNotCached(t *testing.T) {
	query := dnsQuery(0x2222, "example.ygg", dnsTypeAAAA)
	if ttl := dnsTTL(servfail(query)); ttl != 0 {
		t.Fatalf("an error answer is cached for %s", ttl)
	}
	if dnsUsable(servfail(query)) {
		t.Fatal("an error answer counts as usable")
	}
}

// The question is checked before an answer is accepted: a shared exit relay can
// deliver the answer of another in-flight lookup.
func TestSameDNSQuestionRejectsAnotherQuestion(t *testing.T) {
	query := dnsQuery(0x3333, "example.ygg", dnsTypeAAAA)
	other := dnsQuery(0x3333, "other.ygg", dnsTypeAAAA)
	if sameDNSQuestion(query, other) {
		t.Fatal("an answer for another name was accepted")
	}
	if !sameDNSQuestion(query, answerOK(query)) {
		t.Fatal("a matching answer was rejected")
	}
}

// servfail keeps the id of the query so the client can match it.
func TestServfailKeepsTheID(t *testing.T) {
	query := dnsQuery(0x4444, "example.ygg", dnsTypeAAAA)
	answer := servfail(query)
	if binary.BigEndian.Uint16(answer[0:2]) != 0x4444 {
		t.Fatalf("id = %x", answer[0:2])
	}
	if dnsRcode(answer) != 2 {
		t.Fatalf("rcode = %d", dnsRcode(answer))
	}
}
