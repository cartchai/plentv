// Package warpbox is a minimal gomobile binding around sing-box, built for
// PlenTV's in-app VPN (1.6.15): it runs one sing-box instance with a
// "mixed" (HTTP proxy) inbound on 127.0.0.1 and a WireGuard endpoint as
// the only outbound path — no TUN, no VpnService, no system proxy, no
// notification. Only the app's own HTTP clients are pointed at the local
// proxy; everything else on the phone is untouched.
//
// This is deliberately NOT the full libbox API (experimental/libbox):
// that package drives the whole SFA app through a gRPC command server.
// PlenTV needs four calls — Setup, Start, Stop, Status — and a config
// check, so the wrapper is ~150 lines on top of sing-box's own box
// engine (box.New / Start / Close) with a stub platform interface (see
// platform_stub.go, adapted from libbox's CheckConfig stub).
//
// Build (CI builds the AAR; see android-release.yml — the NDK lives on
// the runner, not in this repo):
//
//	gomobile bind -target android/arm64,android/armv7,android/amd64 \
//	  -tags with_wireguard,with_gvisor -o libbox.aar .
//
// The `with_wireguard` tag is what compiles the WireGuard endpoint in
// (include/wireguard.go); `with_gvisor` compiles in gVisor's userspace
// TCP/IP stack, which is the device the endpoint runs on when the
// config leaves `system` off (the default): the tunnel's packets are
// routed through the gVisor netstack entirely in-process — no TUN, no
// kernel WireGuard, no root. Without `with_gvisor` the endpoint fails
// to construct ("gVisor is not included in this build"). No other
// tags: the config uses only the mixed inbound (always compiled in)
// and the WireGuard endpoint.
//
// License: sing-box is GPL-3.0-or-later, same license family as PlenTV;
// this wrapper is part of PlenTV under the same license.
package warpbox

import (
	"context"
	"os"
	"path/filepath"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/common/json"
	"github.com/sagernet/sing/service"
	"github.com/sagernet/sing/service/filemanager"
)

var (
	mu           sync.Mutex
	sBasePath    string
	sWorkingPath string
	sTempPath    string
	currentBox   *box.Box
)

// Setup stores the paths sing-box works under. Call once, before Start,
// with the app's private directories (base = filesDir, working = a
// subdir for sing-box state, temp = cacheDir). It only creates the
// directories; it starts nothing.
func Setup(basePath, workingPath, tempPath string) error {
	mu.Lock()
	defer mu.Unlock()
	sBasePath = basePath
	sWorkingPath = workingPath
	sTempPath = tempPath
	if err := os.MkdirAll(sWorkingPath, 0o777); err != nil {
		return err
	}
	return os.MkdirAll(sTempPath, 0o777)
}

// Start parses configJSON and starts the tunnel. The config must carry
// exactly the shape PlenTV generates: one mixed inbound listening on
// 127.0.0.1 (the local proxy), one WireGuard endpoint (WARP, or later
// an Oracle peer), and a route rule sending everything to the endpoint.
// Starting while a tunnel is up stops the old one first. On any failure
// the box is closed and the error is returned — a failed start never
// leaves a half-running tunnel behind, and it never falls back to a
// direct connection (fail-closed is the caller's job: it must not retry
// the request direct while the tunnel is on).
func Start(configJSON string) error {
	mu.Lock()
	defer mu.Unlock()
	if currentBox != nil {
		_ = currentBox.Close()
		currentBox = nil
	}
	// 1.6.20: guarantee the log file's parent directory exists
	// before sing-box opens it (see ensureLogDir).
	ensureLogDir(configJSON)
	instance, err := newBox(configJSON)
	if err != nil {
		return err
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return err
	}
	currentBox = instance
	return nil
}

// ensureLogDir creates the parent directory of the config's
// log.output path (when present), so sing-box can open its log file.
// Go's O_CREATE creates the file, not parent dirs — and the Dart
// side and the Kotlin side name different folders (app_flutter vs
// files), so the log dir may not exist even though Setup created the
// work dir (the 1.6.19 phone log: box.Start failed on every port
// with `no such file or directory`). Best-effort: the Dart side
// already omits log.output when it cannot create the dir, so this is
// belt-and-braces for any other caller — the wrapper must not depend
// on the caller having created the dir. A failure here is ignored
// and sing-box reports the real error itself.
func ensureLogDir(configJSON string) {
	var cfg struct {
		Log struct {
			Output string `json:"output"`
		} `json:"log"`
	}
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return
	}
	if cfg.Log.Output == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(cfg.Log.Output), 0o777)
}

// Stop closes the running tunnel, if any. Safe to call when off.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if currentBox == nil {
		return nil
	}
	instance := currentBox
	currentBox = nil
	return instance.Close()
}

// Status reports the tunnel state for the Settings UI: "on" while a box
// is running, "off" otherwise. A failed Start returns its error to the
// caller instead of lingering in a half state, so there is no "failed"
// status here — the Dart side records the failure reason.
func Status() string {
	mu.Lock()
	defer mu.Unlock()
	if currentBox != nil {
		return "on"
	}
	return "off"
}

// CheckConfig validates a config without starting anything: parse +
// construct + close. Used by tests and by the app before a first start
// with a new peer config.
func CheckConfig(configJSON string) error {
	instance, err := newBox(configJSON)
	if err != nil {
		return err
	}
	return instance.Close()
}

// newBox parses configJSON against the sing-box registries and builds
// (but does not start) a box instance.
func newBox(configJSON string) (*box.Box, error) {
	ctx := baseContext()
	options, err := json.UnmarshalExtendedContext[option.Options](ctx, []byte(configJSON))
	if err != nil {
		return nil, err
	}
	return box.New(box.Options{
		Context: ctx,
		Options: options,
	})
}

// baseContext mirrors libbox's baseContext (experimental/libbox/config.go):
// the registries the box needs, a filemanager rooted at the Setup paths,
// and the stub platform interface (proxy-only configs never open a TUN,
// so every platform call is a no-op — see platform_stub.go).
func baseContext() context.Context {
	ctx := context.Background()
	ctx = filemanager.WithDefault(ctx, sWorkingPath, sTempPath, os.Getuid(), os.Getgid())
	ctx = service.ContextWith[adapter.PlatformInterface](ctx, &platformStub{})
	return box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry(), include.CertificateProviderRegistry())
}
