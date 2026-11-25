// Tests for the warpbox wrapper. They exercise the exported gomobile API
// only (Setup / Start / Stop / Status / CheckConfig) against a real
// sing-box instance — the same calls the Kotlin side will make.
//
// What these tests can prove on a dev machine: the WARP config parses
// and constructs, the box starts, the mixed proxy listens, and the
// proxy fails closed when the tunnel is down. They CANNOT prove the
// handshake itself: no local handshake test exists in this tree — the
// local-peer handshake test was removed because this VM's sandbox
// forbids outbound UDP, even to loopback, so it cannot run here. The
// handshake is proven on Matt's phone only (CI + phone test), not here.
//
// The WARP peer values below are Cloudflare's public, shared WARP
// endpoint (same peer key every WARP client uses); the private key is
// generated fresh in-test with crypto/rand and never leaves the test.
package warpbox_test

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
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
// The config carries the explicit DNS section (1.6.19): a UDP server
// at 1.1.1.1 with no detour (its queries go out directly on the
// system network, never through the tunnel), with dns.final pointing
// at it — without `final` the router falls back to the dead `local`
// transport and endpoint resolution stays broken. When
// logPath is non-empty the config also carries log.output pointing
// there, so sing-box's own logs land in a file (the Dart side tails
// it into the debug-log export).
func warpConfig(t *testing.T, proxyPort int, logPath string) string {
	t.Helper()
	var priv [32]byte
	if _, err := rand.Read(priv[:]); err != nil {
		t.Fatalf("rand: %v", err)
	}
	privB64 := base64.StdEncoding.EncodeToString(priv[:])
	reserved := derivedReserved(t, testClientID)
	logOutput := ""
	if logPath != "" {
		logOutput = fmt.Sprintf(`, "output": %q`, logPath)
	}
	return fmt.Sprintf(`{
  "log": {"level": "warn"%s},
  "inbounds": [
    {"type": "mixed", "tag": "proxy-in", "listen": "127.0.0.1", "listen_port": %d}
  ],
  "dns": {
    "servers": [
      {"type": "udp", "tag": "dns-direct", "server": "1.1.1.1", "server_port": 53}
    ],
    "final": "dns-direct"
  },
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
}`, logOutput, proxyPort, privB64, warpEndpoint, warpPeerKey, reserved[0], reserved[1], reserved[2])
}

func TestCheckConfigWarpAccepts(t *testing.T) {
	if err := warpbox.CheckConfig(warpConfig(t, 18081, "")); err != nil {
		t.Fatalf("CheckConfig(warp) = %v, want nil", err)
	}
}

// dnsOf parses a sing-box config and returns its dns section.
func dnsOf(t *testing.T, configJSON string) map[string]any {
	t.Helper()
	var parsed struct {
		DNS map[string]any `json:"dns"`
	}
	if err := json.Unmarshal([]byte(configJSON), &parsed); err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if parsed.DNS == nil {
		t.Fatal("config has no dns section")
	}
	return parsed.DNS
}

// TestWarpConfigHasExplicitDNS (1.6.19): the config must carry an
// explicit DNS section — a UDP server at 1.1.1.1 with no detour —
// AND dns.final pointing at that server.
// Without `final`, the router falls back to the dead `local`
// transport when no rule matches, and endpoint resolution stays
// exactly where 1.6.18 had it: broken. On the 1.6.18 base this test
// FAILS — the fixture has no dns section at all.
func TestWarpConfigHasExplicitDNS(t *testing.T) {
	dns := dnsOf(t, warpConfig(t, 18081, ""))
	servers, ok := dns["servers"].([]any)
	if !ok || len(servers) != 1 {
		t.Fatalf("dns.servers = %v, want exactly one server", dns["servers"])
	}
	server, ok := servers[0].(map[string]any)
	if !ok {
		t.Fatalf("dns.servers[0] = %T, want an object", servers[0])
	}
	if server["type"] != "udp" {
		t.Fatalf("dns server type = %v, want udp", server["type"])
	}
	if server["tag"] != "dns-direct" {
		t.Fatalf("dns server tag = %v, want dns-direct", server["tag"])
	}
	if server["server"] != "1.1.1.1" {
		t.Fatalf("dns server = %v, want 1.1.1.1", server["server"])
	}
	if server["server_port"] != float64(53) {
		t.Fatalf("dns server_port = %v, want 53", server["server_port"])
	}
	// The server carries NO detour: without one, the DNS transport
	// dials 1.1.1.1 directly on the system network — never through
	// the tunnel (the tunnel needs DNS to start, so routing DNS
	// through it would deadlock the handshake) and never through
	// the route table. A `detour: "direct"` is NOT the way to say
	// that: sing-box rejects a detour to an empty direct outbound
	// at box.Start ("detour to an empty direct outbound makes no
	// sense"), and the auto-created direct outbound is empty.
	if _, hasDetour := server["detour"]; hasDetour {
		t.Fatalf("dns server has a detour = %v, want none (see comment)", server["detour"])
	}
	if dns["final"] != "dns-direct" {
		t.Fatalf("dns.final = %v, want dns-direct", dns["final"])
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
	got := reservedOf(t, warpConfig(t, 18081, ""))
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

// masqueConfig builds a MASQUE tunnel config for the given local proxy
// port, with freshly generated throwaway ECDSA P-256 keypairs: one for
// the local private key (SEC1 DER, what the fork's masque outbound
// parses with x509.ParseECPrivateKey) and one for the endpoint public
// key (SPKI DER, what it parses with x509.ParsePKIXPublicKey for
// pinning). The server is a literal IP, so no DNS is needed for it.
// The values only need to parse — no live Cloudflare dial is possible
// in this sandbox, and the handshake is proven on Matt's phone only.
// The config carries the same explicit DNS section as the WireGuard
// config (the userspace stack resolves proxied hostnames through it).
func masqueConfig(t *testing.T, proxyPort int, logPath string, vhttp string) string {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate P-256 key: %v", err)
	}
	privDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		t.Fatalf("marshal SEC1 private key: %v", err)
	}
	privB64 := base64.StdEncoding.EncodeToString(privDER)
	endpoint, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate endpoint key: %v", err)
	}
	pubDER, err := x509.MarshalPKIXPublicKey(&endpoint.PublicKey)
	if err != nil {
		t.Fatalf("marshal SPKI public key: %v", err)
	}
	pubB64 := base64.StdEncoding.EncodeToString(pubDER)
	logOutput := ""
	if logPath != "" {
		logOutput = fmt.Sprintf(`, "output": %q`, logPath)
	}
	return fmt.Sprintf(`{
  "log": {"level": "warn"%s},
  "inbounds": [
    {"type": "mixed", "tag": "proxy-in", "listen": "127.0.0.1", "listen_port": %d}
  ],
  "dns": {
    "servers": [
      {"type": "udp", "tag": "dns-direct", "server": "1.1.1.1", "server_port": 53}
    ],
    "final": "dns-direct"
  },
  "outbounds": [
    {
      "type": "masque", "tag": "warp",
      "server": "162.159.198.2", "server_port": 443,
      "profile": "cloudflare", "vhttp": %q,
      "private_key": %q, "public_key": %q,
      "ip": "172.16.0.2/32", "ipv6": "2606:4700:110:8000::2/128",
      "mtu": 1280
    }
  ],
  "route": {"rules": [{"outbound": "warp"}]}
}`, logOutput, proxyPort, vhttp, privB64, pubB64)
}

// TestCheckConfigMasqueAccepts (1.6.21): a MASQUE config must parse
// and construct — the masque outbound type is registered only when
// the AAR is built with the `with_quic` tag (fork: include/quic.go).
// On the upstream base this test FAILS with "unknown outbound type:
// masque" — the fork (sing-box-lx v1.14.4-lx.36) is what provides it.
func TestCheckConfigMasqueAccepts(t *testing.T) {
	for _, vhttp := range []string{"auto", "h3", "h2"} {
		if err := warpbox.CheckConfig(masqueConfig(t, 18081, "", vhttp)); err != nil {
			t.Fatalf("CheckConfig(masque vhttp=%s) = %v, want nil", vhttp, err)
		}
	}
}

// TestCheckConfigMasqueRejectsBadKeys (1.6.21): the fork validates the
// masque key material fail-fast at load (cloudflare profile without
// parseable private_key/public_key) — a bad key must fail CheckConfig,
// not start a tunnel that can never authenticate.
func TestCheckConfigMasqueRejectsBadKeys(t *testing.T) {
	bad := masqueConfig(t, 18081, "", "auto")
	bad = strings.Replace(bad, `"private_key": "`, `"private_key": "!!!not-base64!!!`, 1)
	if err := warpbox.CheckConfig(bad); err == nil {
		t.Fatal("CheckConfig(masque bad private_key) = nil, want an error")
	}
	badPub := masqueConfig(t, 18081, "", "auto")
	badPub = strings.Replace(badPub, `"public_key": "`, `"public_key": "!!!not-base64!!!`, 1)
	if err := warpbox.CheckConfig(badPub); err == nil {
		t.Fatal("CheckConfig(masque bad public_key) = nil, want an error")
	}
}

// TestStartMasqueAndFailClosed (1.6.21): the box starts with a MASQUE
// outbound and the proxy fails closed when the tunnel cannot connect.
// The server is 127.0.0.1 with vhttp h2 (TCP only — the auto mode's
// h3 leg needs outbound UDP, which this sandbox forbids even to
// loopback): the TCP dial is refused, so a request through the proxy
// must error or 5xx — it must never come back as a successful direct
// fetch. Same shape as TestStartStopAndFailClosed, on the MASQUE path.
func TestStartMasqueAndFailClosed(t *testing.T) {
	base := t.TempDir()
	if err := warpbox.Setup(base, base+"/work", base+"/tmp"); err != nil {
		t.Fatalf("Setup = %v", err)
	}
	logPath := filepath.Join(base, "singbox.log")
	const port = 18085
	config := strings.Replace(
		masqueConfig(t, port, logPath, "h2"),
		`"server": "162.159.198.2"`,
		`"server": "127.0.0.1"`,
		1,
	)
	if err := warpbox.Start(config); err != nil {
		t.Fatalf("Start(masque) = %v, want nil", err)
	}
	defer func() {
		if err := warpbox.Stop(); err != nil {
			t.Errorf("Stop = %v", err)
		}
	}()
	if got := warpbox.Status(); got != "on" {
		t.Fatalf("Status() = %q, want %q", got, "on")
	}
	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", port))
	client := &http.Client{
		Transport: &http.Transport{Proxy: http.ProxyURL(proxyURL)},
		Timeout:   20 * time.Second,
	}
	resp, err := client.Get("http://example.com/")
	if err == nil {
		_ = resp.Body.Close()
		if resp.StatusCode >= 200 && resp.StatusCode < 400 {
			t.Fatalf("GET via proxy = %s, want an error or a 5xx (fail-closed)", resp.Status)
		}
		t.Logf("GET via proxy = %s (fail-closed)", resp.Status)
	} else {
		t.Logf("proxy request failed as expected (fail-closed): %v", err)
	}
	if err := warpbox.Stop(); err != nil {
		t.Fatalf("Stop = %v", err)
	}
	if got := warpbox.Status(); got != "off" {
		t.Fatalf("Status() after Stop = %q, want %q", got, "off")
	}
}

func TestStartStopAndFailClosed(t *testing.T) {
	base := t.TempDir()
	if err := warpbox.Setup(base, base+"/work", base+"/tmp"); err != nil {
		t.Fatalf("Setup = %v", err)
	}
	// 1.6.19: the config points sing-box's own logs at this file
	// (log.output); the failed request below must leave its DNS
	// failure in it, so the next phone debug log can show WHY.
	logPath := filepath.Join(base, "singbox.log")
	const port = 18083
	if err := warpbox.Start(warpConfig(t, port, logPath)); err != nil {
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
		// A 5xx from the proxy is fail-closed too: sing-box's HTTP
		// inbound answers a dial failure with an empty 502 (the same
		// empty 502 the phone log shows), not a fetch. Only a 2xx/3xx
		// would mean the proxy forwarded direct.
		if resp.StatusCode >= 200 && resp.StatusCode < 400 {
			t.Fatalf("GET via proxy = %s, want an error or a 5xx (fail-closed); a success here would mean the proxy forwarded direct", resp.Status)
		}
		t.Logf("GET via proxy = %s (fail-closed: the proxy answered with an error status, not a fetch)", resp.Status)
	} else if !strings.Contains(err.Error(), "proxy") && !strings.Contains(err.Error(), "EOF") && !strings.Contains(err.Error(), "connection") && !strings.Contains(err.Error(), "timeout") {
		t.Logf("proxy request failed as expected (fail-closed): %v", err)
	} else {
		t.Logf("proxy request failed as expected (fail-closed): %v", err)
	}

	// 1.6.19: the failed request had to resolve example.com through
	// the explicit DNS server (UDP to 1.1.1.1, blocked in this
	// sandbox), so sing-box must have logged the lookup failure at
	// Error level into the log file. Poll briefly — the log write is
	// asynchronous — then assert the failure is in the file.
	found := false
	for i := 0; i < 50 && !found; i++ {
		if data, readErr := os.ReadFile(logPath); readErr == nil {
			found = strings.Contains(string(data), "example.com")
		}
		if !found {
			time.Sleep(100 * time.Millisecond)
		}
	}
	if !found {
		t.Fatalf("sing-box log %s does not mention example.com after the failed request (want the DNS lookup failure in the log)", logPath)
	}

	// Starting again replaces the running tunnel instead of erroring.
	if err := warpbox.Start(warpConfig(t, port, logPath)); err != nil {
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

// TestStartCreatesLogDir (1.6.20): the log file's parent directory
// must not need to exist beforehand. On the 1.6.19 phone the config
// pointed log.output at <app_flutter>/warpbox/singbox.log while Setup
// only created <files>/warpbox — nobody created the log dir, so
// box.Start failed on every port with `no such file or directory`
// (the 1.6.19 phone log, build 2245). The 1.6.19 test above passed
// only because it put the log file directly under the (existing)
// temp dir — that is the hole that let this through.
//
// This test models the phone: a fresh base dir, Setup creating only
// work/ and tmp/, and a config whose log.output sits under a warpbox/
// dir nobody made. Start must succeed and the log file must exist
// afterwards. On the 1.6.19 base this test FAILS with the phone's
// error; the fix is the wrapper creating the log dir before sing-box
// opens it (plus the Dart side creating its own dir before start).
// No test setup here may pre-create the warpbox/ dir.
func TestStartCreatesLogDir(t *testing.T) {
	base := t.TempDir()
	if err := warpbox.Setup(base, base+"/work", base+"/tmp"); err != nil {
		t.Fatalf("Setup = %v", err)
	}
	// The phone's shape: the log lives under a warpbox/ dir that
	// Setup did NOT create (Setup only makes work/ and tmp/).
	logPath := filepath.Join(base, "warpbox", "singbox.log")
	if _, err := os.Stat(filepath.Dir(logPath)); !os.IsNotExist(err) {
		t.Fatalf("precondition: log dir %s should not exist yet", filepath.Dir(logPath))
	}
	const port = 18084
	if err := warpbox.Start(warpConfig(t, port, logPath)); err != nil {
		t.Fatalf("Start = %v, want nil (fresh log dir)", err)
	}
	defer func() {
		if err := warpbox.Stop(); err != nil {
			t.Errorf("Stop = %v", err)
		}
	}()
	if got := warpbox.Status(); got != "on" {
		t.Fatalf("Status() = %q, want %q", got, "on")
	}
	if _, err := os.Stat(logPath); err != nil {
		t.Fatalf("log file %s was not created: %v", logPath, err)
	}
}
