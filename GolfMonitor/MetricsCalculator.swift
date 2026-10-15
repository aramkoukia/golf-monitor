import Foundation

// MARK: - Output

struct ShotMetrics {
    var ballSpeedMph: Double
    var clubSpeedMph: Double
    var launchAngleDeg: Double
    /// Estimated carry (see flight-model notes below).
    var carryYards: Double
    var apexYards: Double
    var hangTimeS: Double
    var smashFactor: Double
    /// Backswing:downswing as X:1. 0 = could not be measured.
    var tempoRatio: Double
    /// Lateral miss at carry distance (+ = right). Side-view approximation.
    var offlineYards: Double
    /// Always nil in v1 — a phone camera cannot resolve dimple rotation.
    var spinRpm: Double? = nil
}

enum MetricsError: Error, LocalizedError {
    case noBallFound
    case insufficientBallTrack
    case invalidCalibration
    case upsideDownTrack

    var errorDescription: String? {
        switch self {
        case .noBallFound:
            return "Couldn't find the ball. Make sure the ball is in frame, well lit, and the lens is clean — then recalibrate."
        case .insufficientBallTrack:
            return "The ball left the frame too quickly to measure. Move the phone back a little or widen the shot."
        case .invalidCalibration:
            return "Calibration looks invalid. Please run ball detection on the Session tab again."
        case .upsideDownTrack:
            return "The ball tracked downward, so this clip's frames are upside-down — likely a clip recorded before the camera orientation fix. Record a fresh clip; if a fresh clip does this too, that's a bug worth reporting."
        }
    }
}

// MARK: - Calculator

/// Turns tracked pixel trajectories into golf numbers.
///
/// - Ball speed: linear least-squares fit of the ball centroid over the first
///   few post-impact frames, scaled by pixelsPerMeter.
/// - Launch angle: elevation of that fitted velocity vector (side view, so the
///   image plane IS the vertical plane).
/// - Club speed: clubhead displacement over the last pre-impact samples.
/// - Carry/apex/hang: numerical integration of the trajectory with quadratic
///   aerodynamic drag plus Magnus lift. The lift term uses *typical* backspin
///   for the selected club (see Club.typicalSpinRpm) — this is an assumption,
///   not a measurement. Constants were tuned so a 157 mph / 12° driver carries
///   ≈ 235 yds and a 101 mph / 20° 9-iron ≈ 150 yds (within ~10% of TrackMan
///   averages). Treat carry as an estimate, not a radar number.
/// - Tempo: backswing frames (takeaway→top) vs downswing frames (top→impact).
/// - Offline: perpendicular deviation of the tracked ball path from its fitted
///   line, extrapolated to the carry distance. A pure side view cannot see
///   true azimuth (left/right), so this is a rough shape/deviation indicator.
enum MetricsCalculator {

    static func calculate(tracking: TrackingResult,
                          pixelsPerMeter: Double,
                          club: Club) throws -> ShotMetrics {
        guard pixelsPerMeter > 50, pixelsPerMeter < 20_000 else {
            throw MetricsError.invalidCalibration
        }
        guard tracking.ballFound, !tracking.ballPoints.isEmpty else {
            throw MetricsError.noBallFound
        }
        guard let impactIdx = tracking.impactBallIndex,
              impactIdx < tracking.ballPoints.count
        else { throw MetricsError.insufficientBallTrack }

        let ppm = pixelsPerMeter

        // --- Ball velocity from the first post-impact frames ---
        let postImpact = Array(tracking.ballPoints[impactIdx...])
        guard postImpact.count >= 4 else { throw MetricsError.insufficientBallTrack }
        let fitCount = min(8, postImpact.count)
        let fitPoints = Array(postImpact.prefix(fitCount))
        let (vxPx, vyPx) = linearVelocity(fitPoints)   // px/sec, y down
        let vx = abs(vxPx) / ppm                        // m/s (mirror left-handers)
        let vy = -vyPx / ppm                            // m/s, up positive
        let speedMps = hypot(vx, vy)
        let launchAngle = atan2(vy, vx) * 180.0 / Double.pi
        let ballSpeedMph = speedMps * 2.23694

        // A real shot leaves the clubface going up (or level, if topped).
        // A clearly negative launch means the tracked frames are upside-
        // down relative to the math — e.g. a clip recorded before the
        // camera-orientation fix. Refuse rather than report the fake
        // zeros the flight model would produce from a clamped launch.
        guard launchAngle > -3 else { throw MetricsError.upsideDownTrack }

        // --- Clubhead speed from the last pre-impact samples ---
        var clubSpeedMph = 0.0
        let clubTrail = tracking.clubPoints
        if clubTrail.count >= 2 {
            let tail = Array(clubTrail.suffix(3))
            let dt = tail.last!.time - tail.first!.time
            if dt > 0 {
                let distPx = hypot(tail.last!.x - tail.first!.x, tail.last!.y - tail.first!.y)
                clubSpeedMph = (distPx / ppm) / dt * 2.23694
            }
        }

        let smash = clubSpeedMph > 1 ? ballSpeedMph / clubSpeedMph : 0

        // --- Tempo ---
        var tempoRatio = 0.0
        if let takeaway = tracking.takeawayIndex,
           let top = tracking.topOfSwingIndex {
            // Convert club-trail indices to frame counts via timestamps.
            let t0 = clubTrail[max(0, takeaway)].time
            let t1 = clubTrail[min(top, clubTrail.count - 1)].time
            let impactTime = tracking.ballPoints[impactIdx].time
            let back = t1 - t0, down = impactTime - t1
            if back > 0, down > 0.005 { tempoRatio = back / down }
        }

        // --- Ballistic flight with drag + Magnus lift ---
        let flight = simulateCarry(v0: speedMps,
                                  launchAngleDeg: max(0, min(45, launchAngle)),
                                  spinRpm: club.typicalSpinRpm)

        // --- Offline: path deviation extrapolated to carry ---
        let offlineMeters = offlineDeviation(points: fitPoints, pixelsPerMeter: ppm,
                                             carryMeters: flight.carry)

        return ShotMetrics(
            ballSpeedMph: ballSpeedMph,
            clubSpeedMph: clubSpeedMph,
            launchAngleDeg: launchAngle,
            carryYards: flight.carry * 1.09361,
            apexYards: flight.apex * 1.09361,
            hangTimeS: flight.hangTime,
            smashFactor: smash,
            tempoRatio: tempoRatio,
            offlineYards: offlineMeters * 1.09361,
            spinRpm: nil
        )
    }

    // MARK: Linear least-squares velocity fit

    /// Returns (vx, vy) in units/sec via least squares on x(t) and y(t).
    private static func linearVelocity(_ points: [TrackedPoint]) -> (Double, Double) {
        let n = Double(points.count)
        var sumT = 0.0, sumT2 = 0.0, sumX = 0.0, sumTX = 0.0, sumY = 0.0, sumTY = 0.0
        for p in points {
            sumT += p.time; sumT2 += p.time * p.time
            sumX += p.x; sumTX += p.time * p.x
            sumY += p.y; sumTY += p.time * p.y
        }
        let denom = n * sumT2 - sumT * sumT
        guard abs(denom) > 1e-12 else { return (0, 0) }
        let vx = (n * sumTX - sumT * sumX) / denom
        let vy = (n * sumTY - sumT * sumY) / denom
        return (vx, vy)
    }

    // MARK: Flight model

    private struct FlightResult { var carry: Double; var apex: Double; var hangTime: Double }

    /// Numerical integration with quadratic drag and Magnus lift.
    /// Tuned constants — see the file-header notes in MetricsCalculator.
    private static func simulateCarry(v0: Double, launchAngleDeg: Double, spinRpm: Double) -> FlightResult {
        let g = 9.81
        let m = 0.04593            // kg, conforming ball
        let rho = 1.225            // kg/m^3
        let r = 0.021335           // m (42.67 mm diameter)
        let area = Double.pi * r * r
        let omega = spinRpm * 2.0 * Double.pi / 60.0

        let rad = launchAngleDeg * Double.pi / 180.0
        var vx = v0 * cos(rad), vy = v0 * sin(rad)
        var x = 0.0, y = 0.0, t = 0.0, apex = 0.0
        let dt = 0.004

        while t < 12 {
            let v = hypot(vx, vy)
            if v < 0.5 { break }
            // Spin parameter and lift coefficient (empirical fit for dimpled balls).
            let s = omega * r / v
            let cl = min(0.55 * sqrt(max(s, 0)), 0.26)
            // Drag coefficient rises as the ball slows (post drag-crisis).
            let cd = 0.27 + 0.25 * max(0.0, (30.0 - v) / 30.0)
            let fd = 0.5 * rho * v * v * area * cd
            let fl = 0.5 * rho * v * v * area * cl
            // Drag opposes velocity; Magnus lift is perpendicular (up for backspin).
            let ax = -(fd * vx / v) / m + (-(fl * vy / v)) / m
            let ay = -g - (fd * vy / v) / m + (fl * vx / v) / m
            vx += ax * dt
            vy += ay * dt
            x += vx * dt
            y += vy * dt
            t += dt
            apex = max(apex, y)
            if y < 0, t > 0.1 { break }
        }
        return FlightResult(carry: max(x, 0), apex: apex, hangTime: t)
    }

    // MARK: Offline deviation

    /// Perpendicular distance of the last tracked point from the fitted line,
    /// scaled from the tracked window out to the full carry distance.
    private static func offlineDeviation(points: [TrackedPoint],
                                         pixelsPerMeter: Double,
                                         carryMeters: Double) -> Double {
        guard points.count >= 3 else { return 0 }
        let (vx, vy) = linearVelocity(points)
        let speed = hypot(vx, vy)
        guard speed > 1 else { return 0 }
        // Unit normal to the direction of travel.
        let nx = -vy / speed, ny = vx / speed
        let p0 = points[0], plast = points.last!
        let devPx = abs((plast.x - p0.x) * nx + (plast.y - p0.y) * ny)
        let trackedDistPx = hypot(plast.x - p0.x, plast.y - p0.y)
        guard trackedDistPx > 1 else { return 0 }
        // Linear extrapolation to carry distance.
        let scale = (carryMeters * pixelsPerMeter) / trackedDistPx
        return (devPx / pixelsPerMeter) * min(scale, 8.0) * (ny >= 0 ? 1 : -1)
    }
}
