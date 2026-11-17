# TripperMaps: design

## 1. What the dash actually is (from real-world projects)

The Tripper Dash is **not** Bluetooth video. It hosts its own Wi-Fi access point and decodes a
plain **H.264 RTP stream**:

| Fact | Source |
|---|---|
| Dash at `192.168.1.1`, SSID `RE_XXXX_XXXXXX`, no internet | TripperDash++ README |
| Control "K1G" on UDP: phone → 2000, phone binds 2002; RSA handshake, then 1 Hz heartbeat | TripperDash++, better-dash |
| Video: H.264 RTP → UDP 5000, FU-A fragmentation | TripperDash++, better-dash |
| Stream frame 526×300; visible glass = circle centre (262,263) r≈264 | TripperDash++ `docs/dash-visible-area.md` (PR #176) |
| Stock RE app: ~4 fps, ~200 kbps, stream dies when phone locks | TripperDash++ README |
| **Dash decoder blinks above ~12 fps** → frames must be evenly paced, never bursty | TripperDash++ PR #150 |
| better-dash suggests 300–450 kbps @ 12 fps; payload 1000–1200 B on lossy Wi-Fi | better-dash README |
| After connect the dash can say "connected" ~28 s before it accepts control: retry quietly | TripperDash++ v1.0.3 notes |

## 2. The Apple Maps problem, and the solution

Apple only lets `MKMapSnapshotter` render **while the app is in the foreground**; a snapshot
started in the background is delayed until you come back. `MKMapView` and the GPU are also
unavailable to a locked phone. TripperDash++ avoids this by drawing OSM tiles on the CPU.

TripperMaps keeps **Apple Maps** with a two-stage pipeline:

```
FOREGROUND (once per route, ~30–90 s)          BACKGROUND (whole ride, phone locked)
MKDirections route                              CoreLocation 1 Hz fix
  → TilePlanner: corridor of z16 + z15 tiles      → MotionSmoother (dead-reckon to frame time)
  → MKMapSnapshotter 512×512, muted, no POIs       → FrameCompositor (CPU CoreGraphics, IOSurface)
  → RAM (NSCache) + disk PNG cache                  → VideoToolbox H.264 (hardware)
                                                    → RTP/FU-A → UDP 5000 → Tripper Dash
```

- Tiles use the same Web-Mercator grid as `MKMapPoint`. z16 ≈ 1.1 m/px is used in town and
  z15 ≈ 2.3 m/px on highways, chosen by speed.
- The corridor is ordered from the start of the ride. Streaming begins after the first 60 tiles, and the rest
  keep rendering while the screen is on.
- **Every unlock tops up the cache** around your current position. If you leave the corridor while locked,
  the compositor falls back to the parent (z15) tile, then to a plain background with the route line.
- Dark and light are separate Apple renders (`UITraitCollection`), so you get true Apple dark-mode styling.
- The disk cache makes repeat routes start instantly.

**Licence caveat:** Apple's developer agreement limits storing MapKit content. A small, personal,
self-expiring cache is the pragmatic choice for your own bike. Read the MapKit terms before you distribute this.

## 3. Smoothness / FPS

1. **Even motion matters more than raw fps.** GPS updates at 1 Hz. Without prediction, 10 fps
   is one jump followed by nine identical frames. `MotionSmoother` dead-reckons position along
   GPS course × speed to the exact frame time and eases out corrections (big jumps over 80 m snap).
2. **Strict pacing.** Frames are scheduled on an absolute-deadline grid. An overrun skips slots and
   never bursts (bursts make the decoder blink).
3. **Tiers:** Turbo 12 fps (charging, phone cool, opt-in), Smooth 10 fps (default), Eco 6 fps
   (Low Power Mode / hot / <20 % battery), Parked 1 fps.
4. **Bitrate follows fps** (650/550/400/200 kbps) with a hard 1.5× per-second cap. Heading-up rotation
   changes the whole frame and is the most expensive thing to encode, so heading changes are smoothed too.
5. Tune on the bike. TripperDash++ itself settled on 4–6 fps at 512 kbps for overlay text
   legibility, so if text smears at 10–12 fps, raise the bitrate before you lower the fps.

## 4. Battery budget (where the power goes, and what we do about it)

| Cost | Mitigation |
|---|---|
| Screen | Not used: the phone is locked in your pocket or on the mount |
| Map rendering | Apple renders each tile once (foreground); per-frame work is a ~526×300 CPU blit of cached tiles |
| Video encode | Apple's hardware media engine, Baseline profile, real-time mode |
| Identical frames | `needsRedraw` skips render+encode when the picture moved < 0.35 px; 1 keep-alive frame/s |
| GPS | Nav accuracy only while moving; drops to ~10 m accuracy when parked; no compass/magnetometer |
| Radio | One UDP socket per plane, packets batched per frame, 1 s heartbeat timer with leeway (coalesced wakeups) |
| Memory/disk I/O | 48-tile RAM cache (about 48 MB); PNG decode happens once per tile |
| Thermal / Low Power Mode | The governor drops to Eco automatically |

The cheapest option overall is the dash's **turn-by-turn-only** mode, which needs no video
(RE's own FAQ recommends it to save battery). Add it as a fallback toggle once K1G is ported.

## 5. Building without a Mac

- `project.yml` → XcodeGen generates the Xcode project on a GitHub `macos-15` runner.
- `xcodebuild … CODE_SIGNING_ALLOWED=NO` produces an unsigned `.app`, which is zipped as `Payload/` into an `.ipa`.
- On Windows, Sideloadly re-signs it with your Apple ID and installs it over USB.
- Free Apple ID: 7-day expiry, no Hotspot entitlement (so you join the bike's Wi-Fi manually).
  Background location, Local Network and VideoToolbox all work with free signing.

## 6. Recommended path to a working ride

1. Push the project and get the CI build green (fix any compile nits).
2. **Port K1G**: implement `K1GCodec` from better-dash (Python, byte-level reference) or
   TripperDash++ (Swift). Use TripperDash++'s `tools/fake_dash` Docker emulator on your
   Windows PC (Docker Desktop) to test the plumbing before you go to the bike.
3. First bike test at Smooth 10 fps, stationary, then a slow ride.
4. Phase 2: native turn glyph TLVs from `MKRoute.steps`, a Live Activity with the next turn, voice prompts,
   and a turn-by-turn-only mode.

Licences: TripperDash++ is PolyForm Noncommercial (free for your own bike; selling needs the
author's permission). Check better-dash's LICENSE before copying code.

## 7. Real-world projects referenced

- **TripperDash++** (iOS, Swift): https://github.com/kolaCZek/TripperDashPlusPlus. A full iOS
  replacement app with OSM tiles, background streaming, Live Activity and the fake_dash emulator.
- **better-dash** (Python): https://github.com/kolaCZek/better-dash. The K1G protocol reference
  and RTP streamer; runs on Mac, Linux and Raspberry Pi.
- **Recon Dash** (Android, Kotlin): https://github.com/MinotaurG/recon-dash. A CarPlay-style
  companion over K1G with MapLibre and on-device Valhalla routing; validated on Himalayan 450 firmware 11.63.
- **REDLINE**: a write-up on reverse-engineering a motorcycle's Bluetooth protocol
  (https://dev.to/mrwick/i-reverse-engineered-my-motorcycles-bluetooth-protocol-to-put-google-maps-on-the-dashboard-256j).
  Useful method: log every assumption alongside its evidence.
- Apple: `MKMapSnapshotter` foreground-only rendering
  (https://developer.apple.com/documentation/mapkit/mkmapsnapshotter/start(completionhandler:)).
- Sideloading from Windows: Sideloadly, SideStore, and Dadoum/Sideloader (open source, cross-platform).
