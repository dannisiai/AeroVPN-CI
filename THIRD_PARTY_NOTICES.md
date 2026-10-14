# Third-Party Notices (Upstream Attribution)

This project is a commercial client shell. All tunneling, protocol,
encryption, TUN, DNS and routing logic is provided by upstream open source:

- `SagerNet/sing-box` (GPL-3.0) — universal proxy platform core.
  Used as unmodified official binaries via `sing-box run/check` and via
  `gomobile bind ./experimental/libbox` producing `libbox.aar` /
  `Libbox.xcframework`. Source: https://github.com/SagerNet/sing-box
  Build tooling is upstream's own: `github.com/sagernet/gomobile` (upstream fork,
  pinned in `core/upstream.env`) with the upstream build tags.
  The macOS CLI is built from the unmodified pinned upstream v1.14.3 source
  with Go 1.27.1, CGO disabled and the project feature tags (QUIC, WireGuard,
  uTLS, Clash API, gvisor). Both architectures target macOS 13 or later.
  `scripts/build_macos_core.py` verifies the source commit, build metadata and
  `core/macos_build.json` checksums, then writes the documented Mach-O fat wrapper
  without modifying either executable slice. This is a project source build,
  not a repackaged official release binary; Naive/USBIP extensions are omitted.
- `SagerNet/sing-box-for-android` (GPL-3.0) — reference `VpnService`
  implementation pattern for Android `Builder/protect()` flow.
  AndroidDefaultNetworkMonitor.kt and AndroidLocalResolver.kt adapt the default
  network selection and DNS callback contract from commit
  bc73504fcb858400a939140ad785ed92f4c9f429 (DefaultNetworkListener.kt,
  DefaultNetworkMonitor.kt, LocalResolver.kt). Blocking adapters use a latch in
  place of upstream coroutines, preserving cancellation and completion semantics.
- `SagerNet/sing-box-for-apple` (GPL-3.0) — reference `NEPacketTunnelProvider`
  pattern for iOS/macOS `NetworkExtension` integration, including the
  `includeAllNetworks` + on-demand kill switch behaviour.
- `SagerNet/sing-box-for-desktop` and the `experimental/boxdd` privileged
  daemon (GPL-3.0) — reference desktop client / LocalSystem service pattern
  (named-pipe gRPC + per-peer process authentication). The Windows helper in
  this repo is an independent Go implementation that uses loopback HTTP IPC.
- `WireGuard® / wintun.dll` — upstream Windows TUN driver binary.

License obligations:

- `sing-box` and its clients are GPL-3.0. Binary redistribution
  (`sing-box.exe`, `libbox.aar`, `Libbox.xcframework`) requires offering
  corresponding source (upstream tag `v1.14.3`; the pinned version, tags and
  gomobile fork live in `core/upstream.env`).
- Do NOT rename or imply association with upstream without consent
  (see upstream LICENSE addendum: "no derivative work may use the name
  or imply association with this application without prior consent").
- Commercial control-plane, Flutter UI, Go IPC daemon glue and backend
  scheduling code in this repo are separate files; where they link
  GPL binaries (mobile static binding), the combined mobile artifact
  must still comply with GPL-3.0 for distribution.

Pinned upstream: `v1.14.3`, build tags
`with_quic,with_wireguard,with_utls,with_clash_api,with_gvisor`.
(`with_ech` was removed by upstream — its presence makes the build fail on
purpose; `with_quic` is required by hysteria2, which is the control plane's
default node protocol.)

libbox API note: upstream sing-box removed the `NewService` entry point in
`v1.13.0`. Mobile clients must call `Setup`/`setup` first and then use
`CommandServer`/`NewCommandServer` + `StartOrReloadService`. This repo's Android
and Apple hosts target that v1.13+ interface, and the build pipeline verifies the
produced artifacts really expose it (`scripts/verify_upstream_artifact.py`).
