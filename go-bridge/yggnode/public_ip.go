package yggnode

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// publicIPURL answers with the address the service sees. A literal address is
// used on purpose: the exit path cannot resolve host names (a name would fall
// back to a direct dial), and the certificate of Cloudflare's resolver carries
// the IP SAN, so the TLS check still passes without SNI.
const publicIPURL = "https://1.1.1.1/cdn-cgi/trace"

// publicIPResult is the JSON shape the UI reads.
type publicIPResult struct {
	OK    bool    `json:"ok"`
	IP    string  `json:"ip,omitempty"`
	Via   string  `json:"via"`
	Ms    float64 `json:"ms"`
	Error string  `json:"error,omitempty"`
}

// PublicIP reports the address a remote service sees for this device. via
// "exit" goes through the active exit node, so the answer is the address the
// websites see while their traffic is carried by the exit; via "direct" uses a
// protected socket that stays on the real network. The call blocks for up to
// timeoutMs and never panics: a failure is an error code in the JSON.
func (n *Node) PublicIP(via string, timeoutMs int) string {
	if timeoutMs < 2000 {
		timeoutMs = 8000
	}
	if timeoutMs > 20000 {
		timeoutMs = 20000
	}
	timeout := time.Duration(timeoutMs) * time.Millisecond
	result := publicIPResult{Via: via}

	dial, err := n.publicIPDialer(via, timeout)
	if err != nil {
		result.Error = err.Error()
		return encodePublicIP(result)
	}
	started := time.Now()
	address, err := fetchPublicIP(dial, timeout)
	if err != nil {
		n.logger.emit("debug", "public IP check via %s: %v", via, err)
		result.Error = publicIPErrorCode(err)
		return encodePublicIP(result)
	}
	result.OK = true
	result.IP = address
	result.Ms = float64(time.Since(started).Microseconds()) / 1000.0
	return encodePublicIP(result)
}

// publicIPDialer picks the path the check takes. "direct" is the same protected
// dialer the exit manager uses for its own sockets: Android would otherwise
// route it back into the tunnel.
func (n *Node) publicIPDialer(via string, timeout time.Duration) (func(context.Context, string, string) (net.Conn, error), error) {
	switch via {
	case "exit":
		n.mu.Lock()
		manager := n.exit
		n.mu.Unlock()
		if manager == nil || !manager.enabled() {
			return nil, errors.New("exit_off")
		}
		return manager.DialContext, nil
	case "", "direct":
		n.mu.Lock()
		protector := n.protector
		n.mu.Unlock()
		return newDirectDialer(protector, timeout).DialContext, nil
	default:
		return nil, errors.New("bad_mode")
	}
}

func encodePublicIP(result publicIPResult) string {
	raw, err := json.Marshal(result)
	if err != nil {
		return `{"ok":false,"via":"","error":"encode_failed"}`
	}
	return string(raw)
}

// publicIPErrorCode turns a technical failure into the short code the UI
// translates. The details go to the connection log.
func publicIPErrorCode(err error) string {
	var netErr net.Error
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &netErr) && netErr.Timeout():
		return "timeout"
	default:
		return "failed"
	}
}

func fetchPublicIP(dial func(context.Context, string, string) (net.Conn, error), timeout time.Duration) (string, error) {
	body, err := fetchTrace(dial, publicIPURL, timeout)
	if err != nil {
		return "", err
	}
	return parsePublicIP(body)
}

// fetchTrace downloads one page with a dial function supplied by the caller.
// The URL is passed in because the IPv6 check reads the same trace page over a
// literal IPv6 address.
func fetchTrace(dial func(context.Context, string, string) (net.Conn, error), url string, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	client := &http.Client{
		Timeout: timeout,
		Transport: &http.Transport{
			DialContext:         dial,
			DisableKeepAlives:   true,
			ForceAttemptHTTP2:   false,
			TLSHandshakeTimeout: timeout,
		},
	}
	defer client.CloseIdleConnections()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "Y-Node")
	response, err := client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("status %s", response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 8<<10))
	if err != nil {
		return "", err
	}
	return string(body), nil
}

// parsePublicIP reads the `ip=` line of the Cloudflare trace page.
func parsePublicIP(body string) (string, error) {
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "ip=") {
			continue
		}
		address := strings.TrimSpace(strings.TrimPrefix(line, "ip="))
		if net.ParseIP(address) == nil {
			return "", fmt.Errorf("bad address %q", address)
		}
		return address, nil
	}
	return "", errors.New("no_ip")
}
