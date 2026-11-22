# warpbox — the in-app VPN engine (PlenTV 1.6.15)

A minimal [gomobile](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)
binding around [sing-box](https://github.com/SagerNet/sing-box) v1.14.4.
It runs one sing-box instance inside the app with:

- a `mixed` inbound (HTTP proxy) listening on `127.0.0.1:<port>`, and
- a WireGuard endpoint (Cloudflare WARP — or later an Oracle peer) as
  the only outbound path.

No TUN, no `VpnService`, no system proxy, no notification: only PlenTV's
own HTTP clients are pointed at the local proxy. The tunnel is
opt-in (Settings → Advanced → "VPN (WARP)", default OFF) and
fail-closed — if the proxy is down, requests fail instead of going direct.

## API (gomobile-compatible: strings and errors only)

| Call | Meaning |
| --- | --- |
| `Setup(basePath, workingPath, tempPath)` | Store the paths sing-box works under; call once, before `Start`. |
| `Start(configJSON)` | Parse the JSON config and start the tunnel. Stops a running tunnel first; on failure closes everything and returns the error. |
| `Stop()` | Close the running tunnel, if any. |
| `Status()` | `"on"` while a tunnel runs, `"off"` otherwise. |
| `CheckConfig(configJSON)` | Validate a config without starting anything. |

The config JSON is built by the Dart side (`WarpTunnelService`):
one mixed inbound, one WireGuard endpoint, one route rule sending
everything to the endpoint. See `lib/services/iptv/warp_tunnel_service.dart`
in the app tree.

## Building the AAR (CI does this)

```sh
# from android/warpbox/
go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init   # needs ANDROID_HOME / ANDROID_NDK_HOME on the runner
gomobile bind -target android/arm64,android/armv7,android/amd64 \
  -tags with_wireguard,with_gvisor -o libbox.aar .
```

The `with_wireguard` tag is what compiles the WireGuard endpoint in
(`include/wireguard.go`); `with_gvisor` compiles in gVisor's userspace
TCP/IP stack, which is the device the endpoint runs on when the config
leaves `system` off (the default): the tunnel's packets are routed
through the gVisor netstack entirely in-process — no TUN, no kernel
WireGuard, no root. Without `with_gvisor` the endpoint fails to
construct ("gVisor is not included in this build"). No other tags: the
mixed inbound is always compiled in. The AAR is built fresh in
CI for every release and is NOT committed — `android/app/libs/` is
empty in git and `build.gradle.kts` only links it when the file exists.

## Why not the full libbox?

`experimental/libbox` drives the whole sing-box-for-android app through
a gRPC command server (`Setup` / `CommandServer` / `NewService`). PlenTV
needs four calls and a config check, so this wrapper is ~150 lines on
top of sing-box's own `box` engine (`box.New` / `Start` / `Close`) plus
a stub platform interface (adapted from libbox's `CheckConfig` stub) —
same core, far less code, nothing to maintain but the config shape.

## License

sing-box is GPL-3.0-or-later, same license family as PlenTV. This
wrapper is part of PlenTV under the same license. The `platformStub`
is adapted from sing-box's `experimental/libbox/config.go`.
