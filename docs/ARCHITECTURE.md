# GolfMonitor architecture

Everything runs on the devices: the iPhone captures, analyzes and stores; the
Apple Watch is a remote. No server, no account, no third-party packages.

## Targets and folders

```
GolfMonitor/                 iOS app (iOS 18+)
  App/                       GolfMonitorApp, AppServices (wiring), RootView, AppRouter
  Core/Capture/              CameraController, DeviceCaptureBackend (AVFoundation),
                             SimulatedCaptureBackend, VideoFileRecorder
  Core/Session/              SceneMonitor, BallLocator, ShotFinder, SceneScanner,
                             SessionProcessor, PhotoLibrarySaver, value types
  Core/Analysis/             SwingAnalyzer, LaunchMeasurer, FlightModel, SwingPhaseDetector
  Core/Remote/               PhoneRemoteServer (WatchConnectivity), WatchPreviewStreamer
  Core/ML/                   ObjectDetector (YOLO decode), PoseEstimator, ModelCatalog
  Core/Models, Persistence   Shot, SwingAnalysis, ShotStore (JSON + media folders), SettingsStore
  Features/Range/            RangeSessionController (state machine) + Range UI
  Features/…                 Library, Studio, Insights, Practice, Profile, Onboarding
  Resources/MLModels         precompiled .mlmodelc (GolfDetector, GolferPose, COCODetector)
GolfMonitorWatch/            watchOS app (single target, watchOS 10+), embedded in the iOS app
Shared/Remote/               wire protocol + watch screen model, compiled into BOTH apps
GolfMonitorTests/            unit + integration tests (fixtures: CC0 240 fps clips)
scripts/run-tests.sh         run the tests by injecting the bundle into the app
```

The project uses file-system synchronized groups: new files in these folders
are compiled into their target automatically. `Shared/` is a member of both
the iOS and watchOS targets.

## The range session

`RangeSessionController` is the single state machine for the phone UI and the
watch:

```
idle ──start──▶ recording ──stop / time limit / app backgrounded──▶ processing ──▶ review
  ▲                 │ cancel                                          │ error     │
  └─────────────────┴──────────────────────── failed ◀────────────────┘  dismiss ─┘
```

`AppServices` owns the camera for the app's whole lifetime, not a screen.
That way a watch command works whatever tab the phone is showing (the phone
then switches to the Range tab). The camera runs while the app is in the
foreground and the Range tab is open, a watch is connected, or a recording is
in progress.

## Finding the shot (`Core/Session`)

`SceneMonitor` sees every camera frame and analyzes ~30 a second:

- **Motion energy:** mean absolute luma change on a 40×40 grid. Swings show
  up as short, strong bursts.
- **Ball locks:** GolfDetector runs on a copy of the frame about twice a
  second. A candidate at the same spot in 3 consecutive passes is a
  stationary ball. Its bright-disk diameter is re-measured for calibration.
- **Presence:** each locked ball's central disk is compared with its reference
  patch. A ball missing for 1 s is "gone". If it reappears it was only hidden
  (the golfer or the club) and is restored.

`ShotFinder` (pure, unit-tested) turns the timeline into swings and shots.

- **Swings** are bursts of smoothed motion above a bar. The still level is
  the 10th percentile of the recording's motion, and the noise is the spread
  of its quietest 30%. The bar sits 0.006–0.010 above the still level, capped
  below the 0.012 rise a swing needs, so a recording that is mostly movement
  can't hide its own swing.
- A burst longer than 4 s (walk up → set up → swing with no pause) is
  **split at its deepest dip**, if that dip falls to 60 % of the lower peak
  beside it.
- **Motion at the phone** isn't a swing. That means a burst already going on
  within 0.25 s of the recording's start, or of its end when stop was
  pressed on the phone (or the app was left). These bursts are split off
  where possible and otherwise dropped, unless a ball was struck in them.
- A **shot** is the earliest disappearance during a swing. Several balls
  vanishing at once means the camera moved, so those are ignored. Impact is
  pinned to where the patch jumps to its final level. A ball that left during
  motion that didn't qualify as a swing (too long, too short) still makes a
  shot. A disappearance with no motion at all does not.
- With no strike, the last swing is kept as a swing-only analysis. With no
  swing at all, the recording fails with "No swing was found".

## Measuring it (`Core/Analysis`)

`LaunchMeasurer` reads only ~0.4 s around impact:

1. Takes a reference frame just before impact and pins the impact frame from
   the ball patch.
2. Finds new bright, ball-shaped blobs in each frame after impact: bright now,
   but dark both in the reference and in the previous frame.
3. Drops blobs that don't move, then fits the trajectory with RANSAC over
   blob pairs. The line must trace back through the address point.

The least-squares velocity gives ball speed (scaled by the 42.67 mm ball
diameter) and launch angle; implausible results are rejected with a reason.
`FlightModel` integrates drag + Magnus lift with typical spin for carry, apex,
hang time and descent. `SwingPhaseDetector` anchors the eight swing positions
and tempo on the measured impact time.

## Watch link (`Core/Remote`, `Shared/Remote`, `GolfMonitorWatch`)

- **watch → phone:** `sendMessage` with a `RemoteRequest`. The phone replies
  with a `RemoteReply` that includes the full `RemoteState`. Stale requests
  are dropped (TTL), and retried ones aren't run twice (`RemoteRequestLedger`).
- **phone → watch:** every state change goes out by `sendMessage` (when
  reachable) and `updateApplicationContext` (always), ordered by
  epoch + revision. The recording time is sent as elapsed seconds, so clock
  skew doesn't matter.
- **Preview:** ~4 fps, ≤300 px JPEG via `sendMessageData`, one frame in
  flight, only while the watch renews a 6 s lease, so a dropped wrist stops
  costing phone CPU.

Commands are never queued with `transferUserInfo`: a "start" that arrives late
would be worse than a clear "iPhone not reachable".
