package yggnode

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

// newAPITestManager wires an exit manager to a local HTTP server, so the token
// handling can be tested without a live Yggdrasil address.
func newAPITestManager(t *testing.T, profile ExitProfile, handler http.Handler) *exitManager {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	return &exitManager{
		cfg: exitConfig{
			Enabled:  true,
			Profiles: []ExitProfile{profile},
			ActiveID: profile.ID,
		},
		log:    &goLogger{},
		health: map[string]*profileHealth{profile.ID: {State: exitStateUnknown}},
		tokens: map[string]string{},
		dialAPI: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var dialer net.Dialer
			return dialer.DialContext(ctx, "tcp", server.Listener.Addr().String())
		},
	}
}

func writeAPITestJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func TestCheckProfileSendsBearerToken(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081, Token: "secret"}
	var seen string
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = r.Header.Get("Authorization")
		writeAPITestJSON(w, map[string]any{
			"ok": true, "allowlisted": true, "authenticated": true, "auth": "required",
			"exitName": "exit", "connections": 3, "refused": 1,
			"maxConnsPerClient": 128, "udpAssociations": 1, "maxUdpAssociations": 64,
		})
	}))

	if err := manager.checkProfile(context.Background(), profile); err != nil {
		t.Fatalf("checkProfile: %v", err)
	}
	if seen != "Bearer secret" {
		t.Fatalf("Authorization = %q, want the bearer token", seen)
	}
	status := manager.status()
	if len(status.Profiles) != 1 {
		t.Fatalf("profiles = %+v", status.Profiles)
	}
	item := status.Profiles[0]
	if !item.Authenticated || item.Connections != 3 || item.Refused != 1 {
		t.Fatalf("profile status = %+v", item)
	}
	if item.MaxConns != 128 || item.MaxUDPAssociations != 64 {
		t.Fatalf("limits = %d/%d", item.MaxConns, item.MaxUDPAssociations)
	}
}

func TestCheckProfileFetchesTokenWhenRequired(t *testing.T) {
	const token = "fresh-token"
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081}
	var issued atomic.Int32
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/token":
			issued.Add(1)
			writeAPITestJSON(w, map[string]any{"ok": true, "token": token, "exitName": "exit"})
		case "/v1/status":
			if r.Header.Get("Authorization") == "Bearer "+token {
				writeAPITestJSON(w, map[string]any{
					"ok": true, "allowlisted": true, "authenticated": true,
					"auth": "required", "exitName": "exit", "connections": 7,
					"maxConnsPerClient": 128,
				})
				return
			}
			// The real exit publishes only these three fields without a token.
			writeAPITestJSON(w, map[string]any{
				"ok": true, "authenticated": false, "auth": "required",
			})
		default:
			http.NotFound(w, r)
		}
	}))

	if err := manager.checkProfile(context.Background(), profile); err != nil {
		t.Fatalf("checkProfile: %v", err)
	}
	if issued.Load() != 1 {
		t.Fatalf("token requests = %d, want 1", issued.Load())
	}
	item := manager.status().Profiles[0]
	if !item.Authenticated {
		t.Fatal("the profile is not authenticated after fetching a token")
	}
	if item.Connections != 7 {
		t.Fatalf("connections = %d, want 7 (the retry must be authenticated)", item.Connections)
	}
	if item.Token != token {
		t.Fatalf("status token = %q, want the learned one", item.Token)
	}
	if manager.profileToken(profile) != token {
		t.Fatal("the token was not remembered")
	}
}

// A stale token must be replaced too: the exit rotates it when the app is
// reinstalled, and the old profile then only sees the minimal status.
func TestCheckProfileReplacesStaleToken(t *testing.T) {
	const token = "rotated-token"
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081, Token: "old"}
	var issued atomic.Int32
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/token":
			issued.Add(1)
			writeAPITestJSON(w, map[string]any{"ok": true, "token": token})
		case "/v1/status":
			if r.Header.Get("Authorization") == "Bearer "+token {
				writeAPITestJSON(w, map[string]any{
					"ok": true, "allowlisted": true, "authenticated": true,
					"auth": "required", "connections": 2,
				})
				return
			}
			writeAPITestJSON(w, map[string]any{
				"ok": true, "authenticated": false, "auth": "required",
			})
		}
	}))

	if err := manager.checkProfile(context.Background(), profile); err != nil {
		t.Fatalf("checkProfile: %v", err)
	}
	if issued.Load() != 1 {
		t.Fatalf("token requests = %d, want 1", issued.Load())
	}
	item := manager.status().Profiles[0]
	if !item.Authenticated || item.Connections != 2 || item.Token != token {
		t.Fatalf("profile status = %+v", item)
	}
}

// A pre-1.3 exit has no auth fields and always sends the full status. The
// bridge must not read the missing mode as a refusal and start asking for a
// token that does not exist there.
func TestCheckProfilePre13StatusIsAuthenticated(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081}
	var tokenRequests atomic.Int32
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/token" {
			tokenRequests.Add(1)
			http.NotFound(w, r)
			return
		}
		writeAPITestJSON(w, map[string]any{
			"ok": true, "allowlisted": true, "exitName": "exit",
			"connections": 5, "maxConnsPerClient": 128,
		})
	}))

	if err := manager.checkProfile(context.Background(), profile); err != nil {
		t.Fatalf("checkProfile: %v", err)
	}
	if tokenRequests.Load() != 0 {
		t.Fatalf("a pre-1.3 exit was asked for a token %d time(s)", tokenRequests.Load())
	}
	item := manager.status().Profiles[0]
	if !item.Authenticated || item.Connections != 5 {
		t.Fatalf("profile status = %+v", item)
	}
}

// A node outside the allowlist cannot get a token. The exit answers 403
// not_allowed, and the profile must be marked denied instead of "online with
// limited API": the traffic would be refused anyway.
func TestCheckProfileDeniedWhenTokenRefused(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081}
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/token" {
			w.WriteHeader(http.StatusForbidden)
			writeAPITestJSON(w, map[string]any{"ok": false, "error": "not_allowed"})
			return
		}
		writeAPITestJSON(w, map[string]any{
			"ok": true, "authenticated": false, "auth": "required",
		})
	}))

	err := manager.checkProfile(context.Background(), profile)
	if err == nil {
		t.Fatal("checkProfile succeeded for a node the exit refuses")
	}
	item := manager.status().Profiles[0]
	if item.State != exitStateDenied {
		t.Fatalf("state = %q, want denied", item.State)
	}
}

func TestRegisterStoresIssuedToken(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081}
	var seen string
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/register" {
			http.NotFound(w, r)
			return
		}
		// Drain the body: a handler that answers before reading it makes the
		// server reset the connection while the client is still writing.
		_, _ = io.Copy(io.Discard, r.Body)
		seen = r.Header.Get("Authorization")
		writeAPITestJSON(w, map[string]any{
			"ok": true, "allowlisted": true, "registered": true,
			"exitName": "exit", "token": "registration-token",
		})
	}))

	result := manager.register(context.Background(), profile.ID, "invite", "", "", "phone", "1.3.0")
	if result.Error != "" {
		t.Fatalf("register: %+v", result)
	}
	if result.Token != "registration-token" {
		t.Fatalf("result token = %q", result.Token)
	}
	if seen != "" {
		t.Fatalf("registration sent an Authorization header: %q", seen)
	}
	if manager.profileToken(profile) != "registration-token" {
		t.Fatal("the registration token was not remembered")
	}
	if item := manager.status().Profiles[0]; item.Token != "registration-token" || !item.Authenticated {
		t.Fatalf("profile status = %+v", item)
	}
}

func TestParseExitConfigKeepsToken(t *testing.T) {
	cfg, err := parseExitConfig(`{"enabled":true,"profiles":[
		{"address":"200::1","socksPort":1080,"apiPort":1081,"token":"abc"}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Profiles[0].Token != "abc" {
		t.Fatalf("token = %q", cfg.Profiles[0].Token)
	}
}

// A fetched token must win over the stored one on the next poll. Issuing a new
// token revokes the previous one, so falling back to the stored copy made the
// bridge fetch a token on every check: the exit answered with the minimal
// status and the card said "API access is limited" forever.
func TestCheckProfileReusesFetchedToken(t *testing.T) {
	const token = "fresh-token"
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081, Token: "revoked"}
	var issued atomic.Int32
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/token":
			issued.Add(1)
			writeAPITestJSON(w, map[string]any{"ok": true, "token": token})
		case "/v1/status":
			if r.Header.Get("Authorization") == "Bearer "+token {
				writeAPITestJSON(w, map[string]any{
					"ok": true, "allowlisted": true, "authenticated": true,
					"auth": "required", "connections": 4,
				})
				return
			}
			writeAPITestJSON(w, map[string]any{
				"ok": true, "authenticated": false, "auth": "required",
			})
		}
	}))

	for i := 0; i < 3; i++ {
		if err := manager.checkProfile(context.Background(), profile); err != nil {
			t.Fatalf("checkProfile %d: %v", i, err)
		}
	}
	if issued.Load() != 1 {
		t.Fatalf("token requests = %d, want 1: the learned token was not reused", issued.Load())
	}
	item := manager.status().Profiles[0]
	if !item.Authenticated || item.Connections != 4 {
		t.Fatalf("profile status = %+v", item)
	}
}

// A 429 on /v1/token must stop the loop instead of retrying on every poll.
func TestFetchTokenBacksOffAfterRateLimit(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081}
	var issued atomic.Int32
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/token":
			issued.Add(1)
			w.WriteHeader(http.StatusTooManyRequests)
			writeAPITestJSON(w, map[string]any{"ok": false, "error": "rate_limited"})
		case "/v1/status":
			writeAPITestJSON(w, map[string]any{
				"ok": true, "authenticated": false, "auth": "required",
			})
		}
	}))

	for i := 0; i < 3; i++ {
		_ = manager.checkProfile(context.Background(), profile)
	}
	if issued.Load() != 1 {
		t.Fatalf("token requests = %d, want 1: the backoff was ignored", issued.Load())
	}
}

// The token is published once and only while the profile does not have it:
// the status is polled every second, so a permanent copy would be noise.
func TestStatusPublishesLearnedTokenOnlyWhenMissing(t *testing.T) {
	profile := ExitProfile{ID: "e", Name: "exit", Address: "200::1", APIPort: 1081, Token: "stored"}
	manager := newAPITestManager(t, profile, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeAPITestJSON(w, map[string]any{
			"ok": true, "allowlisted": true, "authenticated": true, "auth": "required",
		})
	}))
	manager.rememberToken(profile.ID, "stored")
	if item := manager.status().Profiles[0]; item.Token != "" {
		t.Fatalf("a token the profile already has was published: %q", item.Token)
	}
}
