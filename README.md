# GolfMonitor

A budget iPhone launch monitor for the driving range. Mount your iPhone on a
tripod side-on to the hitting zone, record your swing in slow motion
(240 fps where supported), and get ball speed, launch angle, club speed,
smash factor, carry, tempo, and a shot tracer — like a poor man's TrackMan.

**Status: v1, honest prototype.** It measures what a single phone camera can
measure well, estimates the rest, and tells you which is which.

## Open in Xcode & run on your iPhone

1. Copy this folder to your Mac and double-click `GolfMonitor.xcodeproj`.
2. In the project editor, select the **GolfMonitor** target → **Signing & Capabilities**:
   - Set **Team** to your Apple ID (Xcode → Settings → Accounts to add it).
   - Change the **Bundle Identifier** from `com.example.golfmonitor` to something
     unique, e.g. `com.yourname.golfmonitor` (Apple requires a globally unique ID).
   - For Watch support, also set the same Team on **GolfMonitorWatch** and
     **GolfMonitorWatchExtension**. Give the Watch app a unique ID such as
     `com.yourname.golfmonitor.watchkitapp` and the extension an ID such as
     `com.yourname.golfmonitor.watchkitapp.watchkitextension`. Update the Watch
     app's **WKCompanionAppBundleIdentifier** to match the iPhone app ID and
     the extension's **WKAppBundleIdentifier** to match the Watch app ID.
3. Connect your iPhone via cable, select it as the run destination, and press **Run** (⌘R).

**Free Apple ID sideloading notes:** with a free (non-paid) Apple developer
account, Xcode will sign the app for 7 days — after that you re-run from Xcode
to refresh it. On the phone, first launch may require trusting the developer
certificate under Settings → General → VPN & Device Management. A paid
developer account ($99/yr) removes the 7-day limit.

Requirements: iPhone with a 240 fps slow-mo mode (iPhone 6s and later all
support 240 fps at 720p), iOS 17+.

## Setting up at the range

```
              TARGET LINE
  ──────────────────────────────────────►  (ball flies this way)

            ●  ball on tee/mat

  ─┬─
   │  tripod, phone in LANDSCAPE
   │  2.5–4 m from the ball
   │  lens at ball height
   │
  ═╧═  camera looks along this axis

  ◄──────── 90° ────────►
  phone ──── ball ──── target
```

- **Position:** tripod exactly 90° to your target line (pure side view),
  phone in **landscape**, and outside the golfer's swing and ball paths. The
  current detector accepts a phone-to-ball distance of **0.5–2.0 m**; don't
  put the phone anywhere it could be struck to meet that range.
- **Framing:** ball in the lower-center of frame with ~1–2 m of sky above it
  so the early ball flight stays in frame. Tap **Record Shot** once framed —
  the app locks focus/exposure so it doesn't hunt mid-swing.
- **Lighting:** works best in daylight or under bright range lights. The ball
  is detected as a bright-white blob — a scuffed yellow range ball in dim
  light will struggle. Keep the lens clean.
- **Background:** a clean sky or net behind the ball flight path tracks far
  better than trees or other golfers moving behind it.

## Ball detection (Session tab — repeat after moving the phone)

1. Keep the ball 0.5–2.0 m from the camera, framed clearly, with the phone
   safely outside the golfer's swing and ball paths.
2. Tap **Detect ball**. The app measures the ball diameter and computes the
   pixel→meter scale from the real ball diameter (42.67 mm). A successful
   detection saves calibration and unlocks **Record Shot**.
3. If detection fails, improve lighting and framing, then try again. Re-detect
   after moving the phone.

## How each metric is computed

- **Ball speed:** least-squares fit of the ball centroid over the first ~8
  post-impact frames → px/s → m/s via calibration → mph/km-h. This is the
  most trustworthy number in the app (typically within ±2–3 mph of radar
  when tracking is clean).
- **Launch angle:** elevation of that fitted velocity vector. In a true side
  view the image plane *is* the vertical plane, so this is direct.
- **Clubhead speed:** clubhead (largest moving blob pre-impact) displacement
  over the last frames before impact. Noisier than ball speed — the clubhead
  is dark and motion-blurred.
- **Smash factor:** ball speed ÷ club speed. Sanity range is ~1.45–1.52 for a
  driver; if yours reads 1.9, the club tracking glitched, not your swing.
- **Carry / apex / hang time:** numerical integration of the trajectory with
  quadratic aerodynamic drag + Magnus lift. Lift uses *typical* backspin for
  the selected club (e.g. ~2,600 rpm driver, ~6,800 rpm 7-iron) — an
  assumption, not a measurement. Constants tuned so 157 mph/12° → ~235 yds
  carry and 101 mph/20° → ~150 yds. Treat carry as a **±10–15% estimate**.
- **Tempo:** frames from takeaway start (first sustained club motion) to top
  of backswing (highest clubhead point) vs. top to impact, expressed as X:1
  (PGA Tour average ≈ 3:1).
- **Offline (L/R):** deviation of the tracked ball path from its fitted line,
  extrapolated to the carry distance. A pure side view **cannot see true
  azimuth** — this is a rough shape indicator, not a real left/right number.
- **Spin:** displayed as **n/a**. A phone at 240 fps cannot resolve dimple
  rotation. True spin needs a marked ball and 1000+ fps (or radar).

## Honest limitations vs. radar units (TrackMan / GCQuad)

| | GolfMonitor (this app) | TrackMan / GCQuad |
|---|---|---|
| Ball speed | ±2–3 mph when tracking is clean | ±0.5 mph |
| Launch angle | ±1–2° (side view) | ±0.2° |
| Spin rate | not measured | ±50 rpm |
| Carry | ±10–15% estimate (model) | ±1–2 yds (measured flight) |
| Offline L/R | rough indicator only | ±1 yd |
| Club path / face angle | not measured | measured |

Error sources: rolling shutter skew at 240 fps, motion blur on the ball and
clubhead, pixel quantization (at 3 m a 720p frame gives ~1–2 mph per pixel of
error), imperfect 90° camera alignment, and wind (the flight model assumes
still air).

## Project layout

```
GolfMonitor.xcodeproj/      hand-authored Xcode project (iOS 17+, Swift 5)
GolfMonitor/
  GolfMonitorApp.swift      @main entry, TabView (Session / History / Setup)
  Models.swift              Shot, Club, Calibration, SettingsStore, ShotStore, formatters
  CameraManager.swift       AVFoundation session, 240 fps format picker, AVAssetWriter clips
  TrackingEngine.swift      vImage blob tracking: ball (bright) + clubhead (motion)
  MetricsCalculator.swift   speeds, angles, smash, tempo, drag+Magnus carry model
  CalibrationView.swift     distance, side-view setup, ball-diameter auto-detect, units
  SessionView.swift         single-shot and multi-shot session capture, analysis and results
  ShotHistoryView.swift     per-club filter/averages, delete, CSV export via share sheet
  Info.plist                camera usage description, orientations
GolfMonitorWatchExtension/ Apple Watch Start/Stop remote for range sessions
```

## Deliberate simplifications (v1)

- **Side view only.** Down-the-line view (for azimuth/path) is not implemented.
- **Spin is n/a** by design; carry uses club-typical spin assumptions.
- **Session recording (experimental):** choose Session for a continuous recording
  of up to 5 minutes. Afterward, the app looks for motion events, extracts
  candidate swing clips, analyzes them, and saves the full video to Photos.
  Busy backgrounds and movement can cause missed or extra candidates; review
  the resulting shots. Each detected clip is also saved in the local shot library.
- **Apple Watch remote:** open the Range tab and detect the ball on the iPhone,
  then use the GolfMonitor Watch app's Start/Stop button from your paired watch.
  Keep the iPhone app open on Range and the phone/watch connected; start requires
  a live camera and a locked ball. Install the Watch companion app from the
  paired Watch app if it does not appear automatically. The Watch app remotely
  starts a session of the selected duration (up to five minutes).
- **Calibration uses the bundled golf-ball-specific YOLOv8n Core ML model only.**
  It was fine-tuned for one epoch on the Roboflow GolfBall v1 dataset (CC BY 4.0;
  [dataset](https://universe.roboflow.com/anna-gaming/golfball)). On the held-out
  dataset test split it scored 0.696 mAP@0.5 and 0.342 mAP@0.5:0.95. This is an
  initial CPU-training experiment, not a production-quality result; the model
  may not generalize to your camera, range, or ball size. Failures are shown
  instead of silently falling back to brightness detection.
- **Shot tracking is still brightness/blob-based** across the recorded frames;
  Core ML is not yet used to track the moving ball or calculate shot metrics.
- **History is local JSON**, no cloud sync.
- Left-handed golfers: ball direction is mirrored internally, so speeds and
  angles are still correct; the tracer just draws right-to-left.

## Ideas for v2

- Continue golf-ball model training on a GPU and validate it on images captured
  by the app at the intended 0.5–2 m range
- Use the detector for ball tracking throughout the recorded clip
- Down-the-line camera mode for club path, face angle, true offline
- Audio-triggered capture (impact sound starts the 2 s buffer)
- Marked-ball spin estimation with higher-frame-rate capture
