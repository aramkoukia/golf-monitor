# GolfMonitor

A launch monitor and swing analyzer that runs entirely on your iPhone, with an
Apple Watch remote. Put the phone on a tripod, press record (on the phone or
the watch), set up, take practice swings, hit the ball, press stop. GolfMonitor
finds the real strike, measures it, and shows the numbers on both screens.

- **One-button routine.** A single continuous recording covers everything.
  Practice swings are detected and ignored. The shot is the swing during which
  the teed ball disappears.
- **No separate ball-detection step.** The bundled ball detector runs in the
  background, locks onto the ball (green brackets in the viewfinder) and uses
  its measured size to calibrate distances automatically.
- **Apple Watch remote.** It shows a live camera preview, starts and stops the
  recording, and shows the result (carry, ball speed, launch) with haptics for
  each state. When the watch starts a recording, the phone switches to the
  Range screen and shows that it is recording.
- **Save to Photos (optional).** Profile › Photos can save each analyzed shot
  clip, and optionally the full recording, to your photo library.
- **Fully on-device.** Core ML, Vision and AVFoundation only. No account, no
  server, no network calls, no third-party packages.

## Run it

1. Open `GolfMonitor.xcodeproj` in Xcode 26.
2. In **Signing & Capabilities**, choose your team for the **GolfMonitor** and
   **GolfMonitorWatch** targets. If you change bundle IDs, keep the watch ID as
   `<phone id>.watchkitapp` and update `WKCompanionAppBundleIdentifier` in
   `GolfMonitorWatch/Info.plist` to match.
3. Select the **GolfMonitor** scheme and your iPhone, then Run. The watch app is
   embedded in the iPhone app (`GolfMonitor.app/Watch/`) and installs on the
   paired watch automatically. Check the iPhone **Watch** app › Available Apps
   if it doesn't appear. To debug the watch UI, run the **GolfMonitorWatch**
   scheme on the watch.

Requires iOS 18+ (every iPhone that runs it records 240 fps) and watchOS 10+.

**Simulator:** the iPhone Simulator has no camera, so a virtual camera loops a
bundled CC0 range session (setup → practice swing → strike) and "recording"
feeds that session through the real pipeline. Launch arguments for hands-free
checks:

```
-gm.skipOnboarding -gm.autostart 6     # record 6 s, stop, analyze, reveal
-gm.reset -gm.demo -gm.tab library     # demo library
```

On the watch: `-gm.autostart 7` presses Start and then Stop over
WatchConnectivity, and `-gm.mockState result` shows a canned screen
(DEBUG builds only).

## At the range

```
   TARGET ───────────────────────────►   ball flies across the frame

             ●  ball (teed or on the mat)
        2–3 m
   ┌─┐
   │▯│  phone on a tripod, side-on (face-on to you), lens at ball height
   └┬┘
```

- Face-on (camera looking at your chest) measures **ball speed, launch angle,
  carry, apex, hang time and descent**, plus tempo. Down-the-line gives swing
  analysis (tempo, phases) only.
- Keep the ball in view with ~2 m of open space in front of it. A fast shutter
  (Profile › Shutter, 1/2000 by default) freezes the ball; switch to Auto in
  dim light.
- Wait for the green brackets on the ball, then press record. Take your time:
  practice swings are fine. Hit, then press stop (or let the recording limit
  stop it).

## How it works

```
camera (240 fps, 420f) ─┬─▶ HEVC recording (temp file)
                        ├─▶ SceneMonitor @30 Hz ── motion energy + ball presence
                        │       └─ GolfDetector (Core ML) locks stationary balls ~2×/s
                        └─▶ WatchPreviewStreamer ── 4 fps JPEG ─▶ Apple Watch
stop ─▶ ShotFinder: swings = motion bursts; shot = swing where a locked ball vanished
     ─▶ ClipExporter: cut [impact − 2.4 s, impact + 1.4 s] (no re-encode)
     ─▶ SwingAnalyzer: LaunchMeasurer (ball speed & launch) → FlightModel (carry…)
                       + body pose (Vision) → swing phases & tempo
     ─▶ ShotStore (clip, analysis.json, thumbnail) ─▶ Photos (optional) ─▶ reveal + watch
```

| Number | How | Trust |
|---|---|---|
| Ball speed | Line fit (RANSAC) through the ball's positions in the frames after impact; pixels → metres from the ball's measured diameter (42.67 mm) | ● measured |
| Launch angle | Elevation of the same fitted velocity (side view = vertical plane) | ● measured |
| Carry, apex, hang time, descent | Drag + Magnus flight model with the club's *typical* spin | ◐ estimate, roughly ±10 % |
| Club speed | Ball speed ÷ the club's typical smash factor | ◐ estimate |
| Tempo | Takeaway → top → impact, from body pose and the measured impact frame | ● measured |
| Spin, side angle | Not measurable from one side-on camera | — |

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Model training:
[ml/README.md](ml/README.md).

## Tests

77 unit and integration tests, including the full pipeline on 240 fps CC0
fixtures (`GolfMonitorTests/Fixtures`, among them a synthetic session with a
practice swing followed by the real strike).

```
⌘U in Xcode, or:
xcodebuild test -project GolfMonitor.xcodeproj -scheme GolfMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
scripts/run-tests.sh            # same tests, injected straight into the app
                                # (for machines where xcodebuild's test runner can't connect)
```

## Limitations

- One phone camera can't see spin or left/right direction, so carry uses
  typical spin for the club and there is no offline number.
- Ball tracking needs the ball in frame for at least 2–3 frames after impact
  (240 fps, good light, fast shutter). If it fails, the shot is still saved
  with swing analysis and the reason is shown.
- The camera only runs while GolfMonitor is open on the iPhone. iOS doesn't let
  a watch bring an app to the foreground. Keep the app open on the tripod
  (the screen stays awake while the camera is live).
- Bundled detector models derive from Ultralytics YOLO (AGPL-3.0), so the app
  must stay open source.
