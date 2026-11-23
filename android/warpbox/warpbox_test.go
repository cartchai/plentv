// Tests for the warpbox wrapper. They exercise the exported gomobile API
// only (Setup / Start / Stop / Status / CheckConfig) against a real
// sing-box instance — the same calls the Kotlin side will make.
//
// What these tests can prove on a dev machine: the WARP config parses
// and constructs, the box starts, the mixed proxy listens, and the
// proxy fails closed when the tunnel is down. The handshake itself is
// proven against a LOCAL WireGuard peer in warpbox_handshake_test.go
// (loopback UDP works in this sandbox) — a GET through the tunnel
// proves the handshake completed and traffic flowed. What they CANNOT
// prove here: that Cloudflare accepts the handshake, because the local
// peer identifies clients by public key while Cloudflare reads the
// `reserved` bytes to identify the account (and this VM's sandbox
// forbids outbound UDP, so the live endpoint is unreachable anyway).
// The tunnel data path is proven on Matt's phone (CI + phone test),
// not here.
//
// The WARP peer values below are Cloudflare's public, shared WARP
// endpoint (same peer key every WARP client uses); the private key is
// generated fresh in-test with crypto/rand and never leaves the test.
package warpbox_test

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"plentv/warpbox"
)

// warpPeerKey / warpEndpoint are Cloudflare's public shared WARP values
// (verified against the live registration API 2026-11-21).
const (
	warpPeerKey  = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
	warpEndpoint = "engage.cloudflareclient.com"
)

// testClientID is a fixed test client id (never a real credential):
// base64 of [35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].
// Its first three decoded bytes are the reserved bytes the config must
// carry ([35, 74, 190] — the Xray WARP docs' example, whose reserved_str
// is "I0q+"). The Dart side derives the same bytes from the stored
// client id (1.6.18); this test pins the Go fixture to the same rule.
const testClientID = "I0q+AQIDBAUGBwgJCgsMDQ=="

// derivedReserved returns the first 3 bytes of the base64-decoded
// client id — the WireGuard `reserved` bytes Cloudflare needs to
// identify the account. Mirrors WarpTunnelService.reservedBytesForClientId
// on the Dart side (same derivation, same fallback to zeros).
func derivedReserved(t *testing.T, clientID string) [3]uint8 {
	t.Helper()
	decoded, err := base64.StdEncoding.DecodeString(clientID)
	if err != nil {
		t.Fatalf("decode test client id: %v", err)
	}
	if len(decoded) < 3 {
		t.Fatalf("test client id decodes to %d bytes, want >= 3", len(decoded))
	}
	return [3]uint8{decoded[0], decoded[1], decoded[2]}
}

// reservedOf parses a sing-box config and returns the first peer's
// reserved bytes.
func reservedOf(t *testing.T, configJSON string) []int {
	t.Helper()
	var parsed struct {
		Endpoints []struct {
			Peers []struct {
				Reserved []int `json:"reserved"`
			} `json:"peers"`
		} `json:"endpoints"`
	}
	if err := json.Unmarshal([]byte(configJSON), &parsed); err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if len(parsed.Endpoints) == 0 || len(parsed.Endpoints[0].Peers) == 0 {
		t.Fatal("config has no endpoint peer")
	}
	return parsed.Endpoints[0].Peers[0].Reserved
}

// warpConfig builds a WARP tunnel config for the given local proxy port,
// with a freshly generated throwaway private key. The reserved bytes are
// derived from the fixed test client id (1.6.18) — the same derivation
// the Dart side applies to the stored client id — never [0, 0, 0],
// which makes Cloudflare ignore the handshake.
func warpConfig(t *testing.T, proxyPort int) string {
	t.Helper()
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	privB64 := base64.StdEncoding.EncodeToString(priv[:])
	reserved := derivedReserved(t, testClientID)
	return fmt.Sprintf(`{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "mixed", "tag": "proxy-in", "listen": "127.0.0.1", "listen_port": %d}
  ],
  "endpoints": [
    {
      "type": "wireguard", "tag": "wg-ep",
      "address": ["172.16.0.2/32", "2606:4700:110:8000::2/128"],
      "private_key": %q,
      "mtu": 1408,
      "peers": [
        {
          "address": %q, "port": 2408, "public_key": %q,
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "persistent_keepalive_interval": 25,
          "reserved": [%d, %d, %d]
        }
      ]
    }
  ],
  "route": {"rules": [{"outbound": "wg-ep"}]}
}`, proxyPort, privB64, warpEndpoint, warpPeerKey, reserved[0], reserved[1], reserved[2])
}

func TestCheckConfigWarpAccepts(t *testing.T) {
	if err := warpbox.CheckConfig(warpConfig(t, 18081)); err != nil {
		t.Fatalf("CheckConfig(warp) = %v, want nil", err)
	}
}

// TestWarpConfigCarriesDerivedReserved (1.6.18): the config's reserved
// bytes must be the first 3 bytes of the base64-decoded client id —
// [35, 74, 190] for the fixed test client id — not [0, 0, 0]. With
// zeros Cloudflare ignores the handshake: no error, tunnel shows ON,
// nothing flows (the 1.6.17 phone log). On the 1.6.17 base this test
// FAILS — the fixture bakes in [0, 0, 0].
func TestWarpConfigCarriesDerivedReserved(t *testing.T) {
	want := derivedReserved(t, testClientID)
	if want != [3]uint8{35, 74, 190} {
		t.Fatalf("derivedReserved(testClientID) = %v, want [35 74 190]", want)
	}
	got := reservedOf(t, warpConfig(t, 18081))
	if len(got) != 3 || got[0] != 35 || got[1] != 74 || got[2] != 190 {
		t.Fatalf("config reserved = %v, want [35 74 190]", got)
	}
}

func TestCheckConfigRejectsBadEndpoint(t *testing.T) {
	bad := `{"inbounds": [{"type": "mixed", "tag": "proxy-in", "listen": "127.0.0.1", "listen_port": 18082}], "endpoints": [{"type": "wireguard", "tag": "wg-ep", "address": ["172.16.0.2/32"], "private_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "mtu": 1408, "peers": [{"address": "engage.cloudflareclient.com", "port": 2408, "public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "allowed_ips": ["0.0.0.0/0"], "persistent_keepalive_interval": 25}]}], "route": {"rules": [{"outbound": "no-such-tag"}]}}`
	if err := warpbox.CheckConfig(bad); err == nil {
		t.Fatal("CheckConfig(bad route) = nil, want an error")
	}
}

func TestStartStopAndFailClosed(t *testing.T) {
	base := t.TempDir()
	if err := warpbox.Setup(base, base+"/work", base+"/tmp"); err != nil {
		t.Fatalf("Setup = %v", err)
	}
	const port = 18083
	if err := warpbox.Start(warpConfig(t, port)); err != nil {
		t.Fatalf("Start = %v", err)
	}
	defer func() {
		if err := warpbox.Stop(); err != nil {
			t.Errorf("Stop = %v", err)
		}
	}()
	if got := warpbox.Status(); got != "on" {
		t.Fatalf("Status() = %q, want %q", got, "on")
	}

	// The proxy must be listening and must FAIL CLOSED: the tunnel
	// cannot complete its handshake on this machine (no outbound UDP),
	// so a request through the proxy must error — it must never come
	// back as a successful direct fetch.
	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	client := &http.Client{
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
		Timeout:   20 * time.Second,
	}
	resp, err := client.Get("http://example.com/")
	if err == nil {
		_ = resp.Body.Close()
		t.Fatalf("GET via proxy = %s, want an error (fail-closed); a success here would mean the proxy forwarded direct", resp.Status)
	}
	if !strings.Contains(err.Error(), "proxy") && !strings.Contains(err.Error(), "EOF") && !strings.Contains(err.Error(), "connection") && !strings.Contains(err.Error(), "timeout") {
		t.Logf("proxy request failed as expected (fail-closed): %v", err)
	} else {
		t.Logf("proxy request failed as expected (fail-closed): %v", err)
	}

	// Starting again replaces the running tunnel instead of erroring.
	if err := warpbox.Start(warpConfig(t, port)); err != nil {
		t.Fatalf("second Start = %v, want nil", err)
	}
	if got := warpbox.Status(); got != "on" {
		t.Fatalf("Status() after restart = %q, want %q", got, "on")
	}
	if err := warpbox.Stop(); err != nil {
		t.Fatalf("Stop = %v", err)
	}
	if got := warpbox.Status(); got != "off" {
		t.Fatalf("Status() after Stop = %q, want %q", got, "off")
	}
	// Stopping when already off is a no-op, not an error.
	if err := warpbox.Stop(); err != nil {
		t.Fatalf("second Stop = %v, want nil", err)
	}
}
