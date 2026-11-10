# Handoff

Fork of kesku/duo-workspace (`monsterlag/duo-workspace`, remote `upstream` = kesku), reshaped into a Mac-only remote desktop for the iPhone Duo. Replaces the voxl web fork (`../voxl`, branch `zoom`) for the owner's Mac. Work lives on branch `duo-native` (local; nothing pushed yet).

## What duo-native adds over upstream
- **Stream:** 60 fps capture/encode; per-frame acks (`identifiedVideoFrame` / `videoFrameAck`, feature-gated by `supportsFrameAcks`); delay-based bitrate control and in-flight pacing ported from voxl's `RateCtl`/`flow_ok` (`Sources/DuoCore/Video/StreamRateController.swift`); on-demand keyframes; newest dropped picture re-encoded so a static screen never stays stale. Host logs stats once a second: `log show --info --predicate 'subsystem == "DuoWorkspace"'`.
- **Touch:** local pinch zoom/pan 1–6× (`Apps/iOS/LocalZoom.swift`), voxl's scroll-vs-pinch rule (40 pt spread change), two-finger gestures from the letterbox, pointer mapping through the zoom, two-finger double-tap to fit; zoom survives the keyboard and fold layout flips.
- **Duo only:** iPhone target only, new Macs default to Use as Display, invitations default to the Mac's Tailscale IPv4.

## Build and run
- `DEVELOPER_DIR=/Applications/Xcode-27.3.0-Beta.app/Contents/Developer Scripts/build.sh` (27.2 also works). Signing state in `.secrets/` — keep it.
- The built host carries the restricted HID entitlement and won't launch without SIP off. Re-sign without it before launching: `python3 Scripts/local_signing.py sign --state-dir .secrets --app <DuoWorkspaceHost.app>`. Native touch is then unavailable (needs macOS 27.3 + entitlement or SIP off — owner's call).
- Same-Mac simulator testing: the Mac can't reach its own Tailscale IP; pair with "Use a different address" = LAN IP. iPhone Duo simulator: 27A14996-CC39-47F1-9CC0-94458B1B08B9.

## Verified 2026-11-07 (iPhone Duo simulator, LAN loopback)
Full suite green (51 driver, 52 package, 100 client tests). Live: pairing, ~50–55 fps sent (capture-bound), local pinch zoom sends no input, zoom kept with keyboard up, Tailscale address in invitations.

## Upstream sync 2026-11-10 (merged into `duo-native` and pushed)
- Merged kesku/duo-workspace `main` up to dd86d48 (12 commits: native bottom-edge gestures, mic/video resume fix, fullscreen workspace, Dock hiding + Settings window, Apple Development host signing via `.secrets/AppleDevelopment.xcconfig`). One conflict (PointerSurface.swift), kept both sides. `Scripts/build.sh` verifies with plain `codesign` because we team-sign.
- tembo/voxl up to b00f3b8 (19 commits) reviewed. Ported: sRGB capture + colour tags (eba3b7c). Already had: same-spot double-tap (9d00407; ours 350 ms/24 pt, no triple-tap chain), host cursor shown (3051e8a). Not applicable: x264 CRF fix (79), X11 resize, `--tls`, web/docs/bench.
- New: host setting **Start sharing when opened** (`startSharingOnLaunch`, default off; ON on this Mac since 2026-11-10).
- Verified: full suite green (63 driver-side, 53 package, 111 client tests); installed host relaunched with no keychain/TCC prompt after two rebuilds; auto-shared with the screen locked; Duo simulator streamed the lock screen ~30 fps, encoder log clean.
- Upstream's Apple Development signing path can carry the HID Virtual Device (development) capability, i.e. native touch without disabling SIP. Using it means a new host bundle ID (new keychain + privacy grants once) and still needs macOS 27.3.
- Simulator note: the paired sim app is `local.duoworkspace.client`; build the client with `PRODUCT_BUNDLE_IDENTIFIER=local.duoworkspace.client` to keep its pairing (the default `com.macmax.duodesk` build is a different, unpaired app).

## Open
- Not tested on a slow or lossy link (needs Network Link Conditioner or a real phone on cellular); rate control is only proven by unit tests and a reviewer's simulation.
- Encoder uses Apple low-latency rate control since 9af65b6 (High profile, IDR then P frames; falls back to the standard encoder).
- Sign every host build with `Scripts/sign-host-team.sh` (Developer ID, team 6W6FT9SXBU), NOT `local_signing.py`: the local certificate changes the keychain partition (cdhash) on each rebuild, so macOS re-asks for the login password every build. With the team ID the keychain and Screen Recording/Accessibility grants survive rebuilds.
- **Installed host: `/Applications/DuoWorkspaceHost.app`** (team-signed, Screen Recording + Accessibility granted, verified 2026-11-09). Update it by building the DuoWorkspaceHost scheme, quitting the host, `ditto <DerivedData>/Build/Products/Debug/DuoWorkspaceHost.app /Applications/DuoWorkspaceHost.app`, relaunching. Delete the build-folder copy afterwards: extra copies with the same bundle ID confused System Settings into toggling a stale copy.
- Acks that arrive while the host awaits a slow input handler (native-touch lift, up to 0.5 s) are timestamped late.
- No real-device install yet (needs the owner's developer team: TestFlight or Xcode).

## TestFlight (2026-11-07)

- App Store Connect app **6832027461**, listing name "Duo Desk - duodesk" ("Duo Desk" was taken; home-screen name is Duo Desk). Bundle `com.macmax.duodesk`, team 6W6FT9SXBU, profile "Duo Desk App Store" (Apple Distribution cert 78CQJ8C2D4).
- Internal group **Owner Testing** `ee0b4478-4d21-485c-91d7-7f6bb5ca4762` (owner's developer account). No external group, no beta review, no public release.
- Build **1** (1.0): VALID, IN_BETA_TESTING, in Owner Testing, What to Test = `Scripts/testflight/what-to-test.txt`. Built with released Xcode 27.2 (beta SDK builds can be rejected).
- Build **2** (1.0, 2026-11-10): upstream merge + sRGB host fix; VALID, IN_BETA_TESTING, in Owner Testing, notes uploaded. Upload id 0a004ae5-2e6d-4f31-b075-33b11cad7082.
- Next build: `Scripts/testflight/release.sh 3`, then `asc builds add-groups --app 6832027461 --latest --group ee0b4478-…` and `asc builds test-notes create …`. Use a number above the latest in App Store Connect.
- asc gotcha: in zsh never name a shell variable `GID` (reserved integer).
