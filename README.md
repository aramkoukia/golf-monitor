# GolfMonitor

<p align="center">
  <img src="docs/screenshots/icon-ios.png" width="112" alt="GolfMonitor iPhone app icon">
  &nbsp;&nbsp;
  <img src="docs/screenshots/icon-watch.png" width="112" alt="GolfMonitor Apple Watch app icon">
</p>

A launch monitor and swing analyzer that runs entirely on your iPhone, with an
Apple Watch remote. Put the phone on a tripod, press record (on the phone or
the watch), set up, take practice swings, hit the ball, press stop. GolfMonitor
finds the real strike, measures it, and shows the numbers on both screens.

- **One-button routine.** A single continuous recording covers everything.
  Practice swings are detected and ignored. The shot is the swing during which
  the teed ball disappears. See [Recording a shot](#recording-a-shot).
- **No separate ball-detection step.** The bundled ball detector runs in the
  background, locks onto the ball (green brackets in the viewfinder) and uses
  its measured size to calibrate distances automatically.
- **Launch numbers and swing analysis.** Ball speed, launch angle, carry,
  apex, hang time and descent from a face-on camera, plus tempo and eight
  swing phases from body pose. See [What it measures](#what-it-measures).
- **Apple Watch remote.** Live camera preview, start/stop, club picker and the
  result on your wrist, with haptics for each state.
- **Swings library, Swing Studio, Insights, a Carry Challenge** and a
  tour comparison. See [Features](#features).
- **Fully on-device.** Core ML, Vision and AVFoundation only. No account, no
  server, no network calls, no third-party packages.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/splash.jpg" width="190" alt="Launch intro"><br><sub>Launch intro</sub></td>
    <td align="center"><img src="docs/screenshots/range-ready.jpg" width="190" alt="Range screen, ready to swing"><br><sub>Range · ready to swing</sub></td>
    <td align="center"><img src="docs/screenshots/result.jpg" width="190" alt="Result screen"><br><sub>Result · 1/8-speed replay</sub></td>
    <td align="center"><img src="docs/screenshots/studio.jpg" width="190" alt="Swing Studio"><br><sub>Swing Studio</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/swings.jpg" width="190" alt="Swings library"><br><sub>Swings library</sub></td>
    <td align="center"><img src="docs/screenshots/insights.jpg" width="190" alt="Insights"><br><sub>Insights</sub></td>
    <td align="center"><img src="docs/screenshots/practice.jpg" width="190" alt="Practice"><br><sub>Practice · Carry Challenge</sub></td>
    <td align="center"><img src="docs/screenshots/profile.jpg" width="190" alt="Profile settings"><br><sub>Profile</sub></td>
  </tr>
</table>

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/watch-ready.jpg" width="160" alt="Watch, ready to swing"><br><sub>Watch · ready to swing</sub></td>
    <td align="center"><img src="docs/screenshots/watch-recording.jpg" width="160" alt="Watch, recording"><br><sub>Watch · recording, ball locked</sub></td>
    <td align="center"><img src="docs/screenshots/watch-result.jpg" width="160" alt="Watch, result"><br><sub>Watch · result</sub></td>
  </tr>
</table>

<sub>iPhone Simulator with the bundled CC0 demo session and demo library (`-gm.demo`); watch screens use `-gm.mockState`.</sub>

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
-gm.noSplash                           # skip the launch intro
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
- Keep the whole swing in frame, from address to finish.

## Recording a shot

One recording covers the whole routine. You don't tell the app which swing
was the real one; it works that out after you press stop.

### The routine

**With the Apple Watch (best):**

1. Tee the ball and step back. Wait for **READY TO SWING** on the watch
   (it taps your wrist when the ball locks).
2. Stand at the ball and press **Start** on the watch.
3. Set up and **hold still for a second or two**.
4. Swing. Take practice swings first if you like, with a short pause between
   each.
5. Hold your finish or watch the ball, then press **Stop**.

**Phone only:**

1. Tee the ball and wait for the record button's ring to turn **green**
   ("Ready to swing").
2. Press **record**, walk to the ball and set up.
3. **Pause for a moment at address** so walking up and swinging don't run
   into each other.
4. Swing, then watch the ball for a second or two.
5. Walk back and press **stop**. The recording also stops on its own at the
   recording limit (Profile › Recording limit, 3 minutes by default), or if
   you leave the app.

The numbers then appear on the phone, are read out loud ("165 yards carry.
Ball speed 120.") and show up on the watch.

### Ready to swing

Before you press record, both screens show whether a recording started now
is likely to be caught and measured. On the phone it's the hint at the top
and the record button's ring, which turns green when ready and is readable
from the tee. On the watch it's the status pill and the line under the
button. It's advice only: you can always start.

| Phone / watch shows | Meaning | Fix |
|---|---|---|
| **Ready to swing** (green ring) | A ball is locked, it has room to fly, and there's enough light | Start |
| **Ready · swing only** (green ring) | Down the Line view: the swing will be analyzed, not the ball | Switch to Face-On for ball numbers |
| **No ball locked** | No ball has been seen sitting still yet | Tee a ball in view and step back for ~1.5 s |
| **Move ball** | Every locked ball is in the last quarter of the frame on the target side (the right for a right-hander, the left for a left-hander), so it would leave the frame before it's tracked | Aim the phone or move the ball so there's room in front of it |
| **Too dark** | The frame is very dark at the fixed fast shutter | Add light, or set Profile › Shutter to Auto |
| **Phone moved** | The phone moved after the ball locked, invalidating the distance calibration | Step back so the ball re-locks before you swing |

### What the app is looking for

| Step | What it detects | What it needs from you |
|---|---|---|
| Ball lock | A ball that sits still in the same spot for three detector passes, half a second apart | About **1.5 s** with the ball still and nobody standing over it. The lock carries over into the recording and survives you walking past it |
| Swing | A burst of movement **0.3–4 s** long. A pause separates one swing from the next | A moment of stillness before and after the swing. Walking up and swinging with no pause gets split at the slowest moment in between |
| You at the phone | Movement right at the start of the recording, and at the end when stop was pressed on the phone | Nothing. This is ignored, so walking to the ball and back never counts as a swing |
| Shot | The swing during which the locked ball disappears for good (gone for 0.6 s, or 0.2 s if the recording stops right after) | A ball locked **before** you take the club back |
| Practice swing | Every other swing (the ball stays put) | Nothing. Take as many as you like |

While recording, the strip at the bottom of the Range screen counts what has
been seen so far (**N SWINGS**, **SHOT ✓**). The watch shows the same:
"N swings seen · hit when ready", then "Shot detected — tap stop when you're
done." One recording can hold several shots (up to six are analyzed). Every
struck ball is saved as its own shot.

### If something goes wrong

| You see | It means | Try |
|---|---|---|
| "No swing was found in the recording…" | No swing-shaped movement at all, outside the walk to and from the phone | Keep the whole swing in frame. Pause briefly before and after the swing. Don't stop the recording mid-swing |
| "Swing analyzed" / "No ball strike found · swing saved" | A swing was found but no locked ball left during it, so you get tempo and phases only | Wait for the green brackets **before** swinging. If you tee the ball after pressing record, give it ~1.5 s to lock. Use face-on |
| "Strike found" / "Strike found — ball flight unclear" | The ball left, but it wasn't tracked in enough frames after impact | More light, a faster shutter, open space in front of the ball |
| "Down-the-line view analyzes the swing…" | Camera position is set to Down the Line | Switch to Face-On (FO) for ball numbers |

## What it measures

| Number | How | Trust |
|---|---|---|
| Ball speed | Line fit (RANSAC) through the ball's positions in the frames after impact; pixels → metres from the ball's measured diameter (42.67 mm) | ● measured |
| Launch angle | Elevation of the same fitted velocity (side view = vertical plane) | ● measured |
| Carry, apex, hang time, descent | Drag + Magnus flight model with the club's *typical* spin | ◐ estimate, roughly ±10 % |
| Club speed, smash | Ball speed ÷ the club's typical smash factor | ◐ estimate |
| Tempo, backswing, downswing | Takeaway → top → impact, from body pose and the measured impact frame | ● measured |
| Swing phases | Address, top, impact and finish from body pose (Apple Vision); takeaway, halfway back, delivery and release in between | ● / ◐ |
| Spin, side angle, offline | Not measurable from one side-on camera | — |

14 clubs, Driver to Lob Wedge, each with a typical loft and spin for the
flight model. The Range screen defaults to 7 Iron; the last club selected on
the Range screen, watch, or video import is remembered.

## Features

**Range** (main tab)
- **Ready to swing** indicator: a hint and a green record-button ring when a
  recording started now is likely to be measured (see
  [Ready to swing](#ready-to-swing)).
- Live viewfinder at 240 fps with a format badge (e.g. 240 FPS · 1080P), a
  status pill (LIVE / REC) and ball-lock brackets.
- **CLUB** picker and a Face-On / Down-the-Line toggle. Both lock while
  recording.
- Record button with a ring that fills toward the recording limit, a
  recording clock, and a red glow around the screen while recording.
- Routine strip (START → PRACTICE → HIT → STOP) with live swing and shot
  counts. When **Auto-stop on impact** is on and the crack is heard, the strip
  shows **IMPACT ✓ / STOPPING** and the recording ends hands-free ~2 s later.
- Analyzing screen with progress through "Finding your shot", "Measuring ball
  flight", "Reading your swing" and "Saving". Analysis can be cancelled, and
  it keeps running briefly if the phone locks.
- **Result screen:**
  - "New personal best" (per club, by carry), "Shot measured", "Strike found"
    or "Swing analyzed".
  - A 1/8-speed slow-motion loop of impact with the ball tracer drawn in
    sync.
  - Big carry number, ball speed and launch.
  - Tiles for club speed, apex, hang time, descent, tempo and backswing.
  - Chips for practice swings counted, strikes found and Saved to Photos.
  - **Next shot**, **Swing Studio** and **Discard** buttons.
- **Voice readout** of the result ("Speak results", on by default).

**Swings** (library)
- Every shot, newest first and grouped by day, with a thumbnail, club, carry,
  speed and launch, or tempo for swing-only shots.
- Import videos from Photos or Files. Choose the club, camera view and
  handedness; swings are analyzed on-device and added to the library.
- Filter by club. A summary strip shows shots, average carry, best and tempo.
- Swipe to favourite or delete. The long-press menu has **Open in Swing
  Studio** and **Compare with tour**.
- Export every shot as CSV (always in mph and yards).

**Swing Studio**
- The shot video with the ball path and an optional body-pose skeleton drawn
  over the moving video.
- 2D torso lean, knee bend, head movement and hip sway estimates when enough
  body landmarks are visible. These are image-plane observations, not 3D
  measurements or coaching diagnoses.
- "What to review" suggestions explain how to inspect those observations in
  the video; they do not label a pose good or bad.
- Each swing gets an on/near/check/unrated tempo grade. This is a timing
  reference only, not an overall swing-quality score; posture metrics remain
  neutral until validated.
- Metrics grid.
- Eight phase chips (Address, Takeaway, Halfway Back, Top, Delivery, Impact,
  Release, Finish). Tap one to jump to that estimated moment and see its full
  name and timestamp. The compact chip labels are app abbreviations; the phase
  sequence follows the commonly used GolfDB eight-event taxonomy, with
  intermediate phases estimated between detected events.
- Tempo, backswing and downswing, rated against tour tempo (~3:1).

**You vs PGA Tour**
- Carry, ball speed, club speed, smash, launch and apex next to tour averages
  for the same club (Driver to Pitching Wedge).

**Insights**
- Measured shots, average carry, average ball speed and best carry.
- A carry trend chart of the last 20 measured shots.
- Club gapping ladder with measured average ball speed and explicitly
  estimated carry, plus differences from the previous club shown.
- Within-session ball-speed, launch-angle or tempo trend by shot number for the
  most recent session with multiple measured shots. This is descriptive
  variation, not a fatigue diagnosis.
- Average carry by club.
- Tempo-ratio histogram and percentage of tracked swings in the 2.7–3.3:1
  target band. Tempo is estimated from detected swing phases.

**Practice**
- **Carry Challenge:** five shots aimed at 150 yds; each measured shot that
  lands within 15 yds scores 10 points. Start it from Practice; the Range
  screen shows the target until you tap **End**.
- Practice history: shots, points and last club.
- A tempo drill suggestion.

## Posture coach roadmap

The goal is useful swing feedback from an ordinary iPhone video without
claiming measurements the camera cannot support. Keep the distinction clear:
**observed** means visible in this view; **estimated** means inferred from
noisy 2D landmarks. Never turn a low-confidence estimate into a confident
fault diagnosis.

### Good candidates for phone-only development

These are observable in a single, steady view and can be useful when the
golfer is fully in frame. Ship them only with capture-quality checks and
validation across real users, phones, lighting and camera views.

1. **Capture guidance and pose confidence**
   - Guide the user to keep the whole body and club in frame, use a steady
     phone, and choose a supported face-on or down-the-line view.
   - Detect missing or frequently occluded joints, a golfer too small in frame,
     and unstable framing. Show a clear "can't measure this clip" state rather
     than filling gaps with invented values.
   - Show which landmarks support a metric and suppress it when confidence or
     visibility is insufficient.

2. **Phase timing and rhythm**
   - Improve and expose address, top and impact timing, backswing/downswing
     duration, tempo ratio, and variation across repeated swings.
   - Mark phases as estimated and let users correct a marker when detection is
     wrong. Report consistency only across clips with usable pose and timing.

3. **View-specific 2D movement**
   - Describe movement in image coordinates, normalized to visible body size:
     for example, head or hip center moving left/right in a face-on clip.
   - Show the measurement over the video and its time range, and compare swings
     only when camera view, framing and club are reasonably comparable.
   - Use neutral language such as "head position moved 6% of torso length
     toward image-right during the backswing," not "your head sway is wrong."
     Screen direction is not automatically target direction.

4. **Simple, transparent feedback**
   - Let users review a measurement, see the frames/landmarks behind it, and
     compare two swings side by side or phase by phase.
   - Offer optional drills only for repeatable observations, explain why a
     drill is suggested, and let users dismiss or correct the observation.
   - Track trends for the same golfer only after checking that capture setup
     and confidence are comparable.

### Not reliable from one ordinary phone view alone

Do not present these as measured facts or use them for automated pass/fail
coaching without a validated method and additional evidence:

- True 3D joint positions, exact joint angles, or depth from a single 2D view.
- Pelvis/shoulder rotation in degrees, separation ("X-factor"), or precise
  rotational sequence. A projected angle changes with camera placement and
  cannot resolve motion toward/away from the camera.
- Weight transfer, pressure under each foot, ground-reaction force, balance
  loading, or center-of-mass travel in real-world units. Visible sway is not a
  measurement of force or pressure.
- Clubface angle, attack angle, swing path, or hand/club path based only on
  body landmarks.
- Universal claims that one posture or movement pattern is correct for every
  golfer, or injury/medical diagnoses.

These may become research directions with multi-view video, calibrated depth
or external sensors, plus ground-truth validation. An iPhone's availability of
depth hardware on some models does not by itself make fast-swing biomechanics
accurate.

### Reliability gates before calling anything "coaching"

- Validate each metric against manually labeled video or a suitable reference
  system; publish its expected error and the camera views it supports.
- Test repeated recordings of the same swing/setup to measure repeatability,
  and test different bodies, clothing, handedness, lighting and backgrounds.
- Calibrate confidence so low-quality clips are rejected rather than shown
  with misleading precision. Keep estimates visually and verbally distinct
  from directly measured quantities.
- Start with descriptive feedback and comparison. Add normative ranges or
  prescriptive coaching only when evidence supports those ranges.

**Apple Watch**
- **Ready / Recording:**
  - The live camera preview (about 4 fps) fills the screen, with a red border
    while recording.
  - Status pill: READY TO SWING or what's missing before you start, then
    the recording time.
  - Big start/stop button with a ring for the recording limit.
- **Analyzing:** progress ring with the current step.
- **Result:**
  - Carry, ball speed, launch and smash, or the reason there's no ball data
    and your tempo.
  - The practice swing count and a **Next shot** button.
- **Club picker:** tap the club name in the toolbar.
- **Haptics** for start, stop, result, errors and the camera becoming ready.
- **Ball-lock tap:** a tap when a newly teed ball locks, before or during a
  recording. It comes once per ball: stepping over the ball and away again
  doesn't repeat it, and several balls locking together give one tap. While
  recording, a lock icon sits next to the timer.
- When the watch starts a recording, the phone switches to the Range screen.
  The GolfMonitor app must be open on the iPhone (see Limitations).

**Profile** (settings)

| Setting | Options | Default |
|---|---|---|
| Swing | Right-handed / Left-handed | Right-handed |
| Camera position | Face-On / Down the Line | Face-On |
| Shutter | Auto, 1/1000, 1/2000, 1/4000 | 1/2000 |
| Recording limit | 1, 2, 3, 5, 10 min | 3 min |
| Auto-stop on impact | on / off | on |
| Speak results | on / off | on |
| Haptics | on / off | on |
| Save shot videos to Photos | on / off | off |
| Also save the full recording | on / off | off |
| Speed | mph / km/h | mph |
| Distance | yards / meters | yards |

Profile also shows:
- **Apple Watch:** connection status.
- **Data:** shot count and video storage, **Export shots (CSV)** and **Delete
  all shots**.
- **Privacy & AI:** ball detector and body pose run on device, and the
  network is never used.

**Launch intro:** the launch screen opens straight into a ~2 s intro. The
lock brackets snap onto the ball and the shot's tracer flies across a
floodlit range, then it fades into the app. Tap to skip; Reduce Motion gets
a plain fade.

**First launch:** three onboarding pages cover tripod setup, the one-button
routine, and privacy, with handedness and the Save-to-Photos choice. After
that the app asks for camera access.

## GolfMonitor Roadmap

*Last updated: 2026-11-11. Replaces the "Ideas for v2" list in the README.*

### North star

After every range session, a golfer should be able to answer three questions:

1. **What did I actually do today?** (honest numbers, with confidence)
2. **Is it better than before, and is that change real or just noise?**
3. **What should I work on next?**

GolfMonitor is not trying to be a TrackMan. Several phone-only apps already
estimate ball speed, launch and carry. Our edge is the **honest progress loop**:
a launch monitor that tells you what it can and can't measure, then turns those
measurements into trends, goals and practice guidance.

### Principles

1. **Honest numbers.** Every metric is labeled measured, estimated or n/a, and
   every shot carries a confidence score.
2. **Trends beat absolutes.** Ball speed is good to roughly ±2–3 mph. Same
   phone, same setup, same player means *relative* change is trustworthy even
   when absolute values are not. Design the product around that.
3. **iPhone first.** Apple Watch and AirPods are optional extra sensors. No new
   hardware required.
4. **On-device and private by default.** Cloud sync is optional.
5. **Ship the progress loop before exotic sensing.** Insight features need data
   we already collect.

### What the phone measures well vs. poorly

| Reliable enough to trend | Useful with caveats | Do not promise |
|---|---|---|
| Ball speed, launch angle, tempo, smash factor trend | Club speed (noisy), carry (model estimate), offline (rough shape) | Spin, face angle, true club path, true azimuth (from side view) |

---

### Phase 0: Trust and foundations (~3–4 weeks)

Nothing in later phases is credible without durable data and numbers people
can trust.

**0.1 Durable data layer** (Effort: M)

- Move history from local JSON to SwiftData (fits the iOS 17 minimum) with a
  versioned schema and a one-time migration. Entities: Session, Shot, Club,
  Equipment, Goal, Note.
- Optional iCloud sync via CloudKit; JSON/CSV export and import stay.
- Done when: an app update never loses shots, and export then import
  round-trips exactly.

**0.2 Shot confidence and quality gates** (S–M)

- Compute a per-shot confidence from tracking residuals, frame count, blob-size
  consistency and smash-factor sanity bounds.
- Low-confidence shots are flagged with a reason and excluded from averages
  and trends by default (user can include them).
- Done when: a smash factor of 1.9 never reaches a trend chart silently.

**0.3 Audio-triggered capture** (M) — *auto-stop shipped*

- ✅ **Impact detection:** `ImpactDetector` (AVAudioEngine, 44.1 kHz input tap)
  listens during a recording and fires when it hears the sharp transient of a
  ball strike. A dynamic background level tracker rejects ambient noise; a
  50 ms duration gate ignores single-sample spikes. When impact is detected,
  the routine strip shows **IMPACT ✓ / STOPPING** and the recording auto-stops
  2 s later — enough for `ShotFinder`'s 1.4 s post-roll window. Toggleable via
  **Profile › Auto-stop on impact** (on by default). The mic is active only
  while recording; audio is never stored.
- Remaining: rolling pre-impact buffer (currently the camera rolls continuously
  from the moment the user presses record, so this is less critical than
  originally scoped).
- Done when: a 20-shot session needs zero taps after "Start".

**0.4 Setup assistant and bump detection** (S–M) — *bump detection shipped*

- ✅ **Bump detection:** `BumpDetector` (CoreMotion, 50 Hz accelerometer) starts
  watching when a ball locks and fires a `PHONE MOVED` warning on the Range
  screen and Watch if the phone moves before you swing. The accelerometer uses
  a low-pass gravity filter plus a 50 ms duration gate to avoid false triggers.
  Recording is never blocked — the warning is advisory, matching the app's
  "ready to swing" philosophy.
- Remaining: level and pitch check, live ball-size/distance gauge against the
  0.5–2.0 m window.
- Optional: on LiDAR iPhones, use ARKit depth to confirm distance to the ball.
- Done when: a moved tripod is caught before it corrupts a session.

**0.5 Golden-clip regression suite and validation harness** (M)

- Keep a library of recorded clips with reference values (from a radar or
  camera launch monitor, or a friend's unit) and run them in GolfMonitorTests
  on every change. Dev-only accuracy dashboard (error vs reference per metric).
- Done when: no tracker or model change ships without a before/after accuracy
  report.

**0.6 Repo and model hygiene** (S)

- Move `.pt` / `.mlpackage` binaries to Git LFS or release assets, remove
  `.DS_Store`, document what each bundled model (detector, seg, pose) is used
  for or remove the unused ones.
- Add in-app attribution for the Roboflow GolfBall dataset (CC BY 4.0).

---

### Phase 1: Progress engine (~6–8 weeks) — the core value

**1.1 Session report card** (M)

- After each session: best shot, averages, consistency, and **three
  plain-English insights** (for example "7-iron ball speed was steady within
  ±2 mph, but launch dropped 3° in the last 10 shots"), plus change vs your
  last five sessions.
- Rule-based first. Swift Charts for visuals.

**1.2 Progress dashboard with noise-aware trends** (M)

- Per club, per metric: rolling median with a variation band, personal bests,
  date filters.
- A **"real change?" indicator**: only call something an improvement when the
  shift exceeds measurement noise plus your normal shot-to-shot variation;
  otherwise show "no clear change yet".

**1.3 Consistency metrics and a Repeatability Score** (S–M)

- Standard deviation of ball speed, launch angle and tempo per club, combined
  into a transparent 0–100 Repeatability Score. This is the honest stand-in
  for dispersion, since a side view can't see true left/right.

**1.4 Warm-up and fatigue curve** (S)

- Shipped in part: Insights plots ball speed, launch angle or tempo against
  shot number within the most recent session with multiple measurements.
- Remaining: validate any quality-drop detection before suggesting fatigue or
  an ideal session length.

**1.5 Club gapping ladder and yardage card** (M)

- Shipped in part: Insights shows average measured ball speed and estimated
  carry by club, with adjacent-club differences and sample counts.
- Remaining: validate overlap/gap interpretation; export a yardage card as an
  image/PDF, then consider a widget and Watch complication.

**1.6 Goals and streaks** (S–M)

- User-set targets (driver ball speed, tempo band, smash factor, repeatability)
  with progress rings and a weekly practice streak. Only metric-backed
  milestones; no meaningless badges.

**1.7 Notes, tags and Experiments** (M)

- Tag sessions or shots with a swing thought, drill, new club or new ball.
  **Experiments** compare before vs after (or ball A vs ball B) using the same
  noise-aware logic as 1.2.

**1.8 Tempo trends** (S)

- Shipped in Insights: tempo-ratio histogram and percentage of tracked swings
  in the 2.7–3.3:1 target band. Values are estimated from detected swing
  phases.
- Remaining: user-adjustable target band and an audio metronome tempo trainer.

**1.9 Apple Health golf workouts** (S)

- Write each session as a golf workout via HealthKit for streaks and activity
  history.

---

### Phase 2: Better measurement (~8–12 weeks)

**2.1 Core ML ball tracking across frames** (L)

- Use the detector through the whole clip (existing v2 item). Retrain on GPU
  using images captured by the app at 0.5–2 m. Add a local "hard cases" folder
  to collect failures for labeling.
- Done when: tracking success rate and ball-speed error beat the blob tracker
  on the golden-clip suite.

**2.2 Clubhead tracking improvements** (M–L)

- Improve pre-impact clubhead tracking; evaluate an optional reflective marker
  on the clubhead. Cross-check against Apple Watch hand speed once Phase 3
  lands.

**2.3 Environment-aware flight model** (M)

- Add wind, temperature, altitude and ball type to the carry model (manual
  entry plus WeatherKit where available). Show carry as a **range**, not a
  single number.

**2.4 Personal calibration of estimates** (M)

- Let the user enter one known real carry (range markers or a friend's launch
  monitor) to tune the per-club spin assumption, so carry estimates improve
  for *their* swing.

**2.5 Wedge matrix** (S–M)

- Ball speed and estimated carry for partial swings (for example 50/75/100%)
  to build a wedge distance ladder. Highly useful and well within what the
  camera measures.

**2.6 Down-the-line mode** (L)

- Scope it as a **directional tendency** (launch direction and a clubhead-path
  trend), not precise path or face numbers. Ship as alternating sets (10 shots
  side-on, then 10 down-the-line) before attempting multi-device capture.

---

### Phase 3: Swing view (~8–10 weeks)

**3.1 Pose overlay and automatic key positions** (M–L)

- Detect address, takeaway, top, impact and finish using Apple's Vision body
  pose (benchmark against the YOLOv8-pose model already in the repo).
  Frame-by-frame scrubbing at key positions.

**3.2 Compare to past self** (M)

- Side-by-side or ghost overlay of today's swing vs your best swing or last
  session, synced at key positions, with the shot tracer drawn on video.

**3.3 Posture and motion trends** (L)

- From side view: spine-angle change, head drift, hip depth toward the ball
  (early-extension proxy), knee flex change. From face-on: sway/slide and
  shoulder tilt at the top.
- Always shown as **trend vs your own baseline** and labeled by camera angle,
  never as absolute degrees. Vision's 3D body pose (17 joints, iOS 17+) is an
  experimental option for rotation.

**3.4 Apple Watch as a sensor** (M–L)

- Use watchOS high-frequency motion data for tempo, backswing and downswing
  time, and hand speed. Show the last shot and tempo on the wrist with a
  haptic cue. Works without the tripod (warm-up swings, no-ball practice) and
  cross-checks camera tempo.

**3.5 Speed training mode** (M)

- Non-impact swing-speed sessions using Watch hand speed (and camera club
  speed when visible), logging overspeed sets and charting speed over weeks.

---

### Phase 4: Practice system (~8 weeks)

**4.1 Combines and skills tests** (M)

- Repeatable scored tests built only from metrics the phone measures: Speed
  Ladder (10 swings), Launch Window (hit a launch/ball-speed window 8 of 10),
  Tempo 10, Wedge Control (three ball-speed targets). Scores, history,
  personal bests.

**4.2 Live corridor drills** (M)

- Set a min–max for launch angle, ball speed or tempo and get instant green/red
  feedback with an audio cue. Track hit-rate per session.

**4.3 Auto-generated practice plans** (M)

- Pick the weakest or most inconsistent metric over recent sessions, propose
  a 20–30 minute plan with a target, track adherence, and send a weekly review.

**4.4 Sharing and coach mode** (M)

- PDF/image session report, share video with tracer overlay, CSV/JSON export;
  later read-only sharing for a coach via CloudKit.

**4.5 On-course glue** (M)

- Yardage-card widget and Watch complication from your measured distances.
  Optional 30-second "round lite" log (score, fairways, greens, putts) to show
  whether practice trends line up with scoring.

**4.6 Siri, Shortcuts and Action Button** (S)

- App Intents to start/stop a session by voice or the Action Button.

---

### Phase 5: Moonshots (validate before committing)

- **On-device AI coach** using Apple's Foundation Models on supported devices:
  plain-English summaries and Q&A over local data, with a deterministic
  fallback for other devices.
- **Head stability for putting and chipping** via AirPods motion
  (CMHeadphoneMotionManager), plus a camera putting module (ball speed and
  line).
- **Marker-based club delivery** (face angle, impact location): at least one
  competing app claims this with a reflective marker; validate accuracy on our
  golden-clip suite before building anything.
- **Opt-in anonymous community benchmarks** by handicap band.
- **Two-device simultaneous multi-angle capture** (heavy clock-sync problem;
  one competitor shows paired iPhone + iPad capture).

### Parked or dropped

- **Spin from a marked ball** (previous v2 idea): iPhone slow motion tops out
  around 240 fps and the README itself says 1000+ fps is needed. Revisit only
  if hardware or APIs change.
- **True azimuth, face angle and club path from side view only**: not
  observable.
- **Absolute carry accuracy claims**: stay as a ±10–15% estimate until
  personal calibration (2.4) proves otherwise.

### Suggested success metrics

- Shot tracking success rate on the golden-clip suite (target ≥ 90% of clean
  clips).
- Ball-speed error vs reference (target: median within ±3 mph).
- Time from opening the app to first captured shot (< 2 minutes).
- Share of sessions where the report card is opened; share of users with an
  active goal.
- 4-week retention of users who complete 3+ sessions.

### Risks and notes

- CloudKit, WeatherKit and Watch distribution likely need a paid Apple
  Developer account (the README's free-account flow expires every 7 days).
  Verify before committing to 0.1 sync and 2.3 weather.
- Rolling shutter, motion blur and bad framing cap accuracy; the confidence
  gates (0.2) and setup assistant (0.4) are the mitigation.
- Video lives in Photos and shot data stays on-device by default; keep it that
  way and state it plainly in the App Store privacy details.

### If you only do five things

1. Durable data layer (0.1)
2. Confidence gates (0.2) and audio-triggered capture (0.3)
3. Session report card (1.1) and noise-aware progress dashboard (1.2)
4. Consistency score (1.3) and goals (1.6)
5. Golden-clip regression suite (0.5), so every later accuracy improvement can
   be proven

## How it works

```
camera (240 fps, 420f) ─┬─▶ HEVC recording (temp file)
                        ├─▶ SceneMonitor @30 Hz ── motion energy + ball presence
                        │       └─ GolfDetector (Core ML) locks stationary balls ~2×/s
                        └─▶ WatchPreviewStreamer ── 4 fps JPEG ─▶ Apple Watch
stop ─▶ ShotFinder: swings = motion bursts (not at the phone); shot = swing where a locked ball vanished
     ─▶ ClipExporter: cut [impact − 2.4 s, impact + 1.4 s] (no re-encode)
     ─▶ SwingAnalyzer: LaunchMeasurer (ball speed & launch) → FlightModel (carry…)
                       + body pose (Vision) → swing phases & tempo
     ─▶ ShotStore (clip, analysis.json, thumbnail) ─▶ Photos (optional) ─▶ reveal + watch
```

The app icons (iPhone and watch) and the launch artwork are drawn in code. Run
`swift scripts/render-art.swift` to re-render them into the asset catalogs.

More detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Model training:
[ml/README.md](ml/README.md).

## Tests

102 unit and integration tests, including the full pipeline on 240 fps CC0
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
- A ball can only count as hit if it was locked before the swing. Swing
  within a second of teeing up and you get a swing-only analysis.
- Ball tracking needs the ball in frame for at least 2–3 frames after impact
  (240 fps, good light, fast shutter). If it fails, the shot is still saved
  with swing analysis and the reason is shown.
- The camera only runs while GolfMonitor is open on the iPhone. iOS doesn't let
  a watch bring an app to the foreground. Keep the app open on the tripod
  (the screen stays awake while the camera is live).
- The watch app has no background runtime. With your wrist down, watchOS
  can pause it. Haptics, including the ball-lock tap, are only felt while
  GolfMonitor is on the watch screen. A tap whose news is more than a few
  seconds old is skipped rather than played late.
- There is no import of existing videos yet: analysis runs on recordings
  made in the app.
- Bundled detector models derive from Ultralytics YOLO (AGPL-3.0), so the app
  must stay open source.
