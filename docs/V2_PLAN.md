# GolfMonitor v2 — Revamp Plan

GolfMonitor v2 turns an iPhone on a tripod into a camera-only launch monitor
**and** swing analyzer with a broadcast-grade UI. **Everything runs on the
phone: no server, no account, no cloud.** All ML is on-device (Core ML /
Vision); data lives in the app's Documents folder.

This document is the shared contract for the parallel workstreams. Read it
fully before writing code.

---

## 1. Design language — "Night Flight"

A floodlit driving range at 9 pm, seen from the TV truck. OLED-black canvas,
deep floodlit turf, one white-hot **Plasma** tracer as the only hero colour,
broadcast lower-thirds and F1 timing conventions for data.

Tokens live in `GolfMonitor/DesignSystem/Theme.swift`; components in
`DesignSystem/Components.swift` and `DesignSystem/Glass.swift`. **Never
hard-code colours, fonts or spacing** — extend the design system instead
(put new reusable components in a new file in your own feature folder, or in
`DesignSystem/<YourWorkstream>Components.swift`).

| Token | Use |
|---|---|
| `Palette.void` | App canvas (never pure black) |
| `Palette.carbon` / `.graphite` | SOLID content surfaces (tiles, cards, rows, charts) |
| `Palette.steel` | Hairlines, chart grid, inactive tracks |
| `Palette.turfNight` / `.turfLit` | Mesh backgrounds, flight-slab ground |
| `Palette.floodlight` / `.mist` / `.dim` | Text primary / secondary / disabled |
| `Palette.plasma` | Brand = your ball: tracer glow, Record, the ONE primary CTA per screen |
| `Palette.tracerCore` | White-hot tracer core, impact flashes (never text) |
| `Palette.ion` | Good / ready / ball locked / session best (F1 green) |
| `Palette.apexViolet` | All-time personal best (F1 purple) — always with crown/star icon + label |
| `Palette.caution` | Warnings only (tracking glitch, low light, rough-guide metrics, "needs work") |
| `Palette.signalRed` | Errors / destructive only, with icon + label |
| `chartYou` / `chartReference` / `chartCompare` / `clubRamp` | Swift Charts series |

Rules:
- **Two layers.** Content layer = solid Carbon/Graphite (`.contentCard()`).
  Control layer floating over video = Liquid Glass (`.glassCard()`,
  `.glassCapsule()`, `GlassGroup`) — iOS 26 `glassEffect`, iOS 18 material
  fallback. No glass on glass. Tint glass only for the primary action.
- **Numbers**: SF Pro Compressed/Condensed heavy (`Theme.Font.mega/hero/metric`),
  `.monospacedDigit()` + `.contentTransition(.numericText(value:))` when they
  animate. Units on the baseline, uppercase (`152 YDS`). Labels: `CapsLabel`
  (SF Pro Expanded caps). Timecodes/frame counters: `Theme.Font.mono`
  ("F142 · 0.592 s · 240 fps").
- **Honest Numbers**: every metric shows a `ProvenanceGlyph`:
  ● measured (ball speed, launch angle, tempo timing), ◐ modeled with "~"
  (carry, apex, hang time, club speed, total), ○ rough guide in amber
  (offline from face-on), ⊘ not measurable (spin).
- **F1 timing colours**: Floodlight = normal, Ion = session best, Apex Violet =
  all-time PB.
- **Motion**: fast UI (`Theme.Motion.snappy`), cinematic hero (≤ 1.6 s,
  skippable). Stillness while recording (no shaders/particles/haptics during
  capture). Respect Reduce Motion (counters jump, tracer fades in).
- Signature elements: Plasma Tracer (blurred glow + gradient body + white-hot
  core + comet head, `.plusLighter`; measured part solid, modeled part
  dashed/faded), "Lights Out" countdown (five Plasma start lights, all snap
  off = swing), broadcast lower-third (Carbon slab, Plasma accent bar skewed
  12°), Smash Gauge (240° tachometer arc 1.20–1.55, needle overshoot),
  Floodlight Mesh background (`FloodlightBackground`), Trajectory Wall.
- iOS 26 polish (always `#available`-guarded): `glassEffectID` morphs,
  `.tabBarMinimizeBehavior(.onScrollDown)`, `tabViewBottomAccessory`,
  `ToolbarSpacer`, `backgroundExtensionEffect`. iOS 18: `navigationTransition(.zoom)`,
  `MeshGradient`, `scrollTransition`, `sensoryFeedback`.
- Native only: SwiftUI, Swift Charts, AVFoundation, Vision, Core ML,
  Core Motion, Accelerate. **No third-party packages.**
- Accessibility: VoiceOver labels on every control and metric, Dynamic Type
  for body text, 44 pt hit targets, colour never the only signal.

Full research behind this direction: `~/hobby-projects/golf-ml/research/gm-research-ui_design.json`.

---

## 2. Architecture

```
GolfMonitor/
  App/               GolfMonitorApp, RootView (tab shell), AppRouter, RangeSessionContext
  DesignSystem/      Theme, Glass, Components
  Core/Models/       Club, Shot (+PracticeSession), SwingAnalysis, Calibration, ProReference
  Core/Persistence/  ShotStore (shots.json + ShotMedia/<id>/{clip.mov, analysis.json, thumb.jpg}), SettingsStore
  Core/ML/           ImagePreprocessor (letterbox), ObjectDetector (YOLO NMS/raw, ROI tiling),
                     PoseEstimator (Vision on device / YOLO11n-pose Core ML in Simulator), ModelCatalog
  Core/Analysis/     SwingAnalyzer (API contract), TrackingEngine (GolfDetector-assisted ball tracking + v1 blob continuity/club tracking), MetricsCalculator
  Core/Capture/      CameraManager (v1)
  Core/Demo/         DebugLaunch (launch args), DemoData (synthetic history + bundled CC0 clips)
  Features/<Area>/   one folder per feature area (Range, Library, Insights, Studio, Practice, Profile, Onboarding)
  Features/Shared/   CameraPreviewView, ShareSheet, BallMarkerView, TracerRenderer, MetricGuideView, ProCompareView
  Features/Legacy/   v1 tabs — each is deleted by the workstream that replaces it
  Resources/MLModels Precompiled .mlmodelc (Xcode's CoreML build step can't run here; see ml/)
  Resources/Demo     CC0 demo swing clips (240 fps)
GolfMonitorTests/    XCTest target (hosted by the app). Fixtures/ = CC0 swing clips
ml/                  Training/export scripts for the bundled models
```

The Xcode project uses **file-system synchronized groups**: any file you add
under `GolfMonitor/` or `GolfMonitorTests/` is compiled automatically. **Do not
edit `project.pbxproj`.** Never add `.mlpackage` files under `GolfMonitor/`
(they'd trigger Xcode's sandboxed CoreML compiler, which fails in this
environment); ship compiled `.mlmodelc` folders instead.

### Current integrated path

The Range tab now sends recorded clips through `SwingAnalyzer`, then saves the
clip, analysis JSON, and poster frame with the shot in `ShotStore`. The current
analyzer is still an interim implementation: ball/club paths use the v1 blob
tracker, with periodic GolfDetector detections for ball initialization and
reacquisition; body pose uses the available pose estimator, and swing phases
use wrist-position heuristics. Its pipeline label is surfaced in the shot
result. Capture rate is passed through from the camera.

Calibration uses the new `ObjectDetector` first, preferring the trained
`GolfBallDetector.mlpackage` (registered as `GolfDetector`) and otherwise
trying the generic COCO sports-ball class. `GolferPose.mlmodelc` is also
bundled; SwingNet is not. Recorded-clip club tracking and frame-to-frame ball
continuity still use the interim v1 tracker; swing-event recognition is not
yet using SwingNet.

Insights, Practice, and Swing Studio are usable first passes: Insights charts
measured carry and club averages; Practice offers a five-shot 150-yard carry
challenge; Studio plays saved clips, seeks heuristic phase markers, and shows
the stored analysis. These are not yet the full P0 product scope below.

### Key contracts (already in the code — keep them source-compatible)

- `ShotStore` (EnvironmentObject): `shots`, `sessions`, `activeSessionID`,
  `addShot(_:clipURL:analysis:thumbnail:)` (moves the clip into the media
  folder), `update`, `toggleFavorite`, `delete(ids:)`, `clipURL(for:)`,
  `thumbnail(for:)`, `analysis(for:)`, `saveAnalysis(_:for:)`,
  `mediaDirectory(for:)` (put per-shot extras like `annotations.json` here),
  `startSession/endSession`, `averages/bests(for:)`, `csvString()`, `jsonBackup()`.
- `SettingsStore` (EnvironmentObject): units, handedness, cameraView,
  captureTrigger, shutterMode, voiceReadout, hapticsEnabled, countdownSeconds,
  clipSeconds, playerName, hasCompletedOnboarding; `speedValue/distanceValue`
  conversion helpers. Workstream-specific preferences: use `@AppStorage("golfmonitor.<name>")`
  (document the key in your file).
- `AppRouter` (EnvironmentObject): `tab`, `openStudio(_:compareWith:)`,
  `startPractice(_ context: RangeSessionContext)`, `endPractice()`, `rangeContext`.
- `SwingAnalyzer().analyze(AnalysisRequest, progress:) async throws -> AnalysisOutput`;
  `Shot.make(from:request:source:date:)`; `BallLocator.locate(in: CMSampleBuffer)`.
- `SwingAnalysis` (analysis.json): normalized `ballTrack`, `ballAddress`,
  `impactTime`, `flight` (metres), `clubTrack`, `poses` (`PoseSample`, 19
  `BodyJoint`s), `phases` (8 GolfDB `SwingPhase`s), `metrics` (`SwingMetric`
  with `tourRange` + `rating`), `insights` (`SwingInsight`).
- `Shot.metricSummary[metricID]` mirrors the analysis metrics for charts.

Metric IDs (stable, shared by Analysis/Studio/Insights):
`tempo.ratio`, `tempo.backswing`, `tempo.downswing`, `head.sway.top`,
`head.sway.impact`, `head.lift.impact`, `pelvis.sway.top`, `pelvis.sway.impact`,
`sway.gap.impact`, `shoulder.tilt.address`, `shoulder.tilt.impact`,
`spine.sidetilt.impact`, `spine.forward.address`, `spine.forward.change`,
`pelvis.thrust.impact`, `elbow.lead.top`, `knee.flex.address`,
`shaft.lean.impact`, `club.speed`, `attack.angle`, `swing.score`.

### Debug launch arguments (for simulator screenshots)

```
xcrun simctl launch <udid> com.example.golfmonitor -gm.reset -gm.demo -gm.skipOnboarding -gm.tab insights
```
`-gm.demo` seeds ~290 synthetic shots + 2 analyzed CC0 clips (clip analysis
runs in the background; give it ~30–60 s in Debug), `-gm.studio first` opens
the newest media shot in the Studio, `-gm.screen <name>` is a feature deep
link — each workstream adds and documents its own `-gm.screen` values in its
feature root view (read `DebugLaunch.screen`).

The Simulator has **no camera** and **no Vision body pose** (the YOLO11n-pose
Core ML fallback runs there instead). Core ML models do run (CPU).

---

## 3. Workstreams & file ownership

Each workstream works in its own git worktree/branch and **only creates or
edits files it owns**. Shared files (`Core/Models/*`, `Core/Persistence/*`,
`DesignSystem/*`, `App/AppRouter.swift`, `App/RangeSessionContext.swift`,
`Info.plist`) are read-only for you: if you truly need a change there, add an
`extension` in a file you own, or describe the change in your final report.

| # | Workstream | Owns |
|---|---|---|
| W1 | Range & Capture | `Core/Capture/**`, `Core/Services/**`, `Features/Range/**`, `Features/Shared/CameraPreviewView.swift`, `Features/Shared/BallMarkerView.swift`, deletes `Features/Legacy/SessionView.swift`, tests `GolfMonitorTests/Range*`, `Capture*` |
| W2 | Analysis Engine & ML integration | `Core/Analysis/**`, `Core/ML/**`, `Core/Reference/**`, `Resources/MLModels/SwingNet*.mlmodelc`, `ml/scripts/swingnet*`, tests `GolfMonitorTests/Analysis*`, `MLPipelineTests.swift`, `VisionProbeTests.swift` |
| W3 | Swing Studio & Export | `Features/Studio/**`, `Core/Export/**`, `Features/Shared/ShareSheet.swift`, `Features/Shared/TracerRenderer.swift`, tests `GolfMonitorTests/Studio*`, `Export*` |
| W4 | Library & Insights | `Features/Library/**`, `Features/Insights/**`, `Core/Analytics/**`, `Features/Shared/MetricGuideView.swift`, `Features/Shared/ProCompareView.swift`, deletes `Features/Legacy/ShotHistoryView.swift`, tests `GolfMonitorTests/Library*`, `Insights*`, `Analytics*` |
| W5 | Practice, Profile, Onboarding, Shell | `App/GolfMonitorApp.swift`, `App/RootView.swift`, `Features/Practice/**`, `Features/Profile/**`, `Features/Onboarding/**`, `Core/Practice/**`, `Core/Coach/**`, `Core/Intents/**`, `Core/Demo/**`, `Assets.xcassets/**`, deletes `Features/Legacy/CalibrationView.swift`, tests `GolfMonitorTests/Practice*`, `Shell*`, `Coach*` |

Cross-workstream calls go only through the contracts above. If you need
something another workstream will build (e.g. W3 needs a metric W2
computes), code against the contract/metric ID and degrade gracefully when
it's absent.

---

## 4. Feature scope (gap analysis result)

Priorities: P0 = must ship, P1 = should ship. Research: `~/hobby-projects/golf-ml/research/*.json`.

### W1 Range & Capture
- P0 Measurement-grade capture: physical wide camera; best 240 fps format
  (prefer 1920×1080, then 1280×720, then 120 fps), `420f` buffers (never
  BGRA), HEVC `AVAssetWriter` with expected source frame rate 240, correct
  orientation; HDR/low-light boost/auto frame rate/stabilization off.
- P0 Fast shutter from `SettingsStore.shutterMode` (custom exposure, ISO
  compensated and clamped to the format; fall back gracefully in low light
  and tell the user), focus lock on the ball, white-balance lock while armed,
  camera intrinsics (focal length px) when supported, idle timer off,
  `systemPressureState` handling (step down to 120 fps), interruption handling.
- P0 Hands-free **Auto** capture: arm → record → impact detected by an audio
  transient (AVCaptureAudioDataOutput, vDSP high-pass + 1 ms energy envelope +
  adaptive threshold + refractory) **and/or** the ball leaving its ROI →
  post-roll 0.8 s → keep window [impact − 2.0 s, impact + 1.0 s] → analyze →
  reveal → auto re-arm. Also **Timer** mode (F1 "Lights Out" 5-light
  countdown + fixed clip) and **Manual** (tap to start/stop). Hardware
  triggers via `onCameraCaptureEvent` (volume buttons / AirPods stem / Camera
  Control). Pass `impactTimeHint`, `deviceRollDeg`, `focalLengthPx`,
  `exposureDurationS` to the analyzer.
- P0 Ready / ball-in-zone indicator: live ball lock at ~4–6 Hz on preview
  frames (ObjectDetector / BallLocator on a downscaled ROI), reticle turns
  Ion + chime when locked, re-locks when the ball moves; one-tap calibration
  (px/m from the 42.67 mm ball, distance from intrinsics/FOV).
- P0 Setup assistant: CoreMotion bubble level (green within ±0.5°), framing
  guides per camera view, light check (shutter/ISO feasibility), distance
  readout; iOS 26 lens-smudge check (optional).
- P0 HUD (≤ 3 glass clusters): club chip (Menu), camera-view toggle, format
  badge (fps · resolution · shutter); status capsule READY/ARMED/REC/ANALYZING
  morphing via `glassEffectID`; big Plasma record/arm button (slow
  "breathing" when armed); mode picker; session bar (shots · best · avg);
  last-shot mini card (tap → Studio).
- P0 Shot reveal: Plasma tracer animation over the impact frame (measured
  solid + modeled dashed, optionally pulling back to a side "flight slab"
  using `analysis.flight`), hero count-up, metric tiles cascade with
  provenance, Smash Gauge, session-best/PB highlights, quick club fix,
  Save/Discard/Open in Studio. Swing-only/DTL shots show swing metrics
  (tempo, swing score, top insight) instead of launch numbers.
- P0 Voice readout (AVSpeechSynthesizer; route-aware audio session; which
  metrics are spoken is a setting) + audio cues (start-light ticks,
  lights-out tone, capture chime — synthesized PCM, no assets).
- P0 Practice context: render `router.rangeContext` banner (title, subtitle,
  current target), call `onShot` after each saved shot, show/speak the
  feedback, "End game" → `onFinish` + `router.endPractice()`.
- P0 Simulator mode: no camera → loop a bundled demo clip as a virtual
  preview and offer "Simulate shot" (runs the real pipeline on a bundled
  clip). Deep links: `-gm.screen range.reveal`, `range.setup`, `range.armed`.

### W2 Analysis Engine & ML
- P0 Single-pass decode (AVAssetReader 420f, PTS timing, preferredTransform),
  fast luma ops (Accelerate/vImage on the Y plane), progress + cancellation.
- P0 Ball: address-frame localization with `BundledModel.golfDetector`
  (class names matched by label: `golf_ball`/`ball`, `golf_club`/`club`,
  `club_head`/`head`) on native-resolution tiles/ROI, fallback COCO
  sports-ball then brightness blob; sub-pixel diameter for calibration;
  impact = ball-patch departure (cross-check `impactTimeHint`); post-impact
  tracking = detector on predicted ROIs + two-sided frame differencing +
  RANSAC physics fit (x linear, y with gravity) + launch-angle voting;
  `trackingQuality`; fill `ballAddress`, `ballTrack`, `impactTime`.
- P0 Club head: detector club/head classes when present; fallback
  pose-wrist-guided motion search; smoothing spline; club speed at impact;
  attack angle & shaft lean (face-on); fill `clubTrack`.
- P0 Pose via `PoseEstimatorFactory` every 4th frame plus dense around top &
  impact, golfer ROI, One-Euro smoothing, gravity-roll correction.
- P0 Swing events: convert **SwingNet** (GolfDB, CC BY-NC 4.0; weights at
  `~/hobby-projects/golf-ml/third-party/swingnet/swingnet_1800.pth.tar` —
  verify with `pickletools` it only references tensors/OrderedDict, then load
  ONLY with `torch.load(weights_only=True)`) into `SwingNetEncoder.mlmodelc`
  (160×160 image → 1280-d) + `SwingNetSequence.mlmodelc` ([1,64,1280] →
  [1,64,9]) using the export venv `~/hobby-projects/golf-ml/.venv-export`
  (numpy<2, torch 2.7, coremltools 8.3; compile with `xcrun coremlcompiler`);
  run on golfer crops subsampled to ~30 fps, then refine each event at 240 fps
  with pose/club/ball rules; rule-based fallback when the model is missing.
- P0 View-gated swing metrics with tour ranges (`Core/Reference/`, numbers
  from `gm-research-ml_swing_pose.json` → `pro_reference_metrics`), ratings,
  0–100 swing score, rule-based insights with evidence + one drill each.
- P0 Flight model v2: RK4 (2 ms), Cd/Cl polynomials in spin parameter
  (Ferguson, McNally & McPhee 2022), spin decay; descent angle, roll/total
  estimate; fill `analysis.flight`; regression tests vs tour numbers.
- P0 Fill every field `Shot.make` needs (totalYards, descentAngleDeg,
  trackingQuality, swingScore, metricSummary…).
- Dev club/head model: copy `~/hobby-projects/golf-ml/dev-models/GolfDetectorDev.mlmodelc`
  into `GolfMonitor/Resources/MLModels/` of your worktree for local testing.
  It is git-ignored — **never commit it** (unclear licence). The trained
  `GolfDetector.mlmodelc` (classes golf_ball, golf_club, club_head) will be
  dropped in later by the lead; code must work with either.

### W3 Swing Studio & Export
- P0 Player: AVPlayer + `AVSynchronizedLayer`/SwiftUI overlays, rates 1×,
  ½, ¼, ⅛, 1⁄16, frame stepping (`step(byCount:)`), scrubber with the 8 phase
  markers, P-position filmstrip, frame counter in mono, impact-zoom loop.
- P0 Overlays (toggleable): pose skeleton (glowing), club-head path coloured
  by phase (backswing vs downswing), ball tracer (fitted, measured solid +
  modeled dashed), auto reference lines at address (head box, spine line,
  shaft plane for DTL).
- P0 Metrics panel: tour-range bars (`RangeBar`), provenance, ratings,
  insights with drills; launch numbers when present.
- P0 Telestration: line, angle (with live degrees), circle, freehand;
  colours; undo; persisted per shot in `annotations.json` (mediaDirectory).
- P0 Compare: side-by-side and overlay (onion skin) synced by phase markers;
  pick another shot (default: your best same-club swing) or the bundled
  model swing.
- P0 Export: video with burned-in Plasma tracer, optional skeleton and a
  broadcast lower-third data card (AVAssetExportSession +
  AVVideoCompositionCoreAnimationTool; 9:16 and 16:9; slow-mo impact
  segment via `scaleTimeRange`) → share sheet / save to Photos (add-only);
  4:5 Shot Card image (ImageRenderer).
- Deep links: `-gm.studio first`, `-gm.screen studio.compare`, `studio.draw`, `studio.export`.

### W4 Library & Insights
- P0 Library: session-grouped timeline, grid/list toggle with video
  thumbnails, filters (club, camera view, favourites, source), search
  (notes/tags), PB (Apex Violet) and session-best (Ion) markers, swipe
  favourite/delete, multi-select, zoom transition into the Studio
  (`router.openStudio`), swing-only shots handled gracefully.
- P0 Session summary sheet: shots, per-club averages, bests, consistency,
  "next focus" (from insights).
- P0 Import Slo-mo from Photos (PhotosPicker → club + camera view →
  SwingAnalyzer → save as `.imported`).
- P0 Insights (Swift Charts): gapping (median carry + IQR per club vs tour),
  carry dispersion (1-D strip/box; 2-D carry × offline labelled "rough
  guide"), trends with `chartXSelection` (ball/club speed, smash, tempo,
  swing score), Trajectory Wall (median flight arcs per club), consistency
  scores, PB timeline, practice calendar heatmap, My Bag stock yardages,
  "vs Tour" cards. Metric guide + pro compare.
- Deep links: `-gm.screen library.grid`, `library.session`, `insights.gapping`, `insights.trends`.

### W5 Practice, Profile, Onboarding, Shell
- P0 Practice games (logic in `Core/Practice/`, UI in `Features/Practice/`):
  Target Challenge (random spoken targets, ring scoring vs carry with
  tolerance ≈ measurement error), Combine (fixed distance ladder, score
  0–100), Speed Training (max-effort sets, club speed, no ball needed),
  Tempo Trainer (3:1 audio metronome presets 18/6, 21/7, 24/8, 27/9 frames at
  30 fps), Bag Mapping (N shots per club → stock yardages), Ladder. Each
  starts the Range via `router.startPractice(RangeSessionContext(...))`.
- P0 Goals, streaks, achievements, PR celebrations (local).
- P0 Profile & settings: player (name, handedness, height), bag editor,
  units, camera defaults, shutter, capture trigger, voice metrics, haptics,
  conditions (`golfmonitor.airTempC`, `golfmonitor.altitudeM` for the flight
  model), data (CSV/JSON export, storage usage, prune clips, delete all,
  load demo data), About & licences (Open Images CC BY, Wikimedia CC0 clip,
  Ultralytics AGPL-3.0 models, SwingNet/GolfDB CC BY-NC 4.0).
- P0 Onboarding: 4 animated Night Flight pages + quick setup (handedness,
  units, camera view) + permission priming (camera, mic, photos).
- P0 Shell: tab bar polish (iOS 26 minimize behaviour, live-session
  bottom accessory guarded by `#available(iOS 26.1, *)`), app icon (1024 px,
  Plasma tracer arc + ball on Void/Turf, generated programmatically),
  AccentColor asset, keep `DebugLaunch` handling.
- P1 On-device coach summary: Apple Foundation Models (iOS 26, guarded by
  availability) phrasing ONLY numbers you pass in; template fallback.
- P1 App Intents / App Shortcuts (in-app, no extension): "Start range
  session", "Last shot".

---

## 5. Definition of done (every workstream)

1. `xcodebuild … build` succeeds with **zero errors and no new warnings**
   in your files; `xcodebuild test` passes (your new tests included).
2. Unit tests for all non-UI logic you add.
3. Visual verification: launch on your assigned simulator with debug
   arguments, take screenshots (`xcrun simctl io <udid> screenshot`), LOOK at
   them (Read the PNG) and iterate until they look like a premium,
   bad-ass sports app in the Night Flight style. Check light text contrast,
   clipping, safe areas, both portrait and (for Range/Studio) landscape.
4. No server calls, no third-party packages, no analytics.
5. Commit on your branch with a clear message. Final report: what you built,
   files, screenshots paths, known gaps, any contract changes you need.

Build/test commands (run from your worktree root):
```
xcodebuild -project GolfMonitor.xcodeproj -scheme GolfMonitor \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath /tmp/gm-dd-<ws> build CODE_SIGNING_ALLOWED=NO > /tmp/gm-<ws>-build.log 2>&1
xcodebuild test … (same flags) > /tmp/gm-<ws>-test.log 2>&1
xcrun simctl install <UDID> /tmp/gm-dd-<ws>/Build/Products/Debug-iphonesimulator/GolfMonitor.app
xcrun simctl launch <UDID> com.example.golfmonitor -gm.demo -gm.skipOnboarding -gm.tab <tab>
```
Always redirect build output to a log and grep it (`error:`, `warning:`,
`BUILD`); logs are huge.
