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

## Open
- Not tested on a slow or lossy link (needs Network Link Conditioner or a real phone on cellular); rate control is only proven by unit tests and a reviewer's simulation.
- Encoder uses Apple low-latency rate control since 9af65b6 (High profile, IDR then P frames; falls back to the standard encoder). Every rebuilt host build re-prompts for keychain access to `DuoWorkspace.Identity.v2` (needs the owner's password); fix = keychain ACL tied to the signing certificate, not the build.
- Acks that arrive while the host awaits a slow input handler (native-touch lift, up to 0.5 s) are timestamped late.
- No real-device install yet (needs the owner's developer team: TestFlight or Xcode).

## TestFlight (2026-11-07)

- App Store Connect app **6832027461**, listing name "Duo Desk - duodesk" ("Duo Desk" was taken; home-screen name is Duo Desk). Bundle `com.macmax.duodesk`, team 6W6FT9SXBU, profile "Duo Desk App Store" (Apple Distribution cert 78CQJ8C2D4).
- Internal group **Owner Testing** `ee0b4478-4d21-485c-91d7-7f6bb5ca4762` (owner's developer account). No external group, no beta review, no public release.
- Build **1** (1.0): VALID, IN_BETA_TESTING, in Owner Testing, What to Test = `Scripts/testflight/what-to-test.txt`. Built with released Xcode 27.2 (beta SDK builds can be rejected).
- Next build: `Scripts/testflight/release.sh 2`, then `asc builds add-groups --app 6832027461 --latest --group ee0b4478-…` and `asc builds test-notes create …`. Use a number above the latest in App Store Connect.
- asc gotcha: in zsh never name a shell variable `GID` (reserved integer).
