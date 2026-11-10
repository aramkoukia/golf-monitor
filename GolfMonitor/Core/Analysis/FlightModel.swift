import Foundation

/// Launch numbers for one shot. Canonical units: mph, yards, degrees, seconds.
struct ShotMetrics: Equatable {
    var ballSpeedMph: Double
    /// Estimated from ball speed and the club's typical smash factor (a
    /// phone can't time the club head reliably); 0 = unknown.
    var clubSpeedMph: Double
    var launchAngleDeg: Double
    var carryYards: Double
    var apexYards: Double
    var hangTimeS: Double
    var descentAngleDeg: Double
    /// Ball speed ÷ club speed when both were measured; 0 = not measured.
    var smashFactor: Double = 0
    var tempoRatio: Double = 0
    /// Not measurable from a face-on camera; 0.
    var offlineYards: Double = 0
}

/// Ball flight from launch conditions: RK2 integration with quadratic drag
/// and Magnus lift using the club's *typical* backspin (a camera can't
/// measure spin). Tuned so 157 mph / 12° driver ≈ 235 yd carry and
/// 101 mph / 20° 9-iron ≈ 150 yd. Treat carry as a ±10 % estimate.
enum FlightModel {
    struct Result: Equatable {
        var carryMeters: Double
        var apexMeters: Double
        var hangTime: Double
        var descentAngleDeg: Double
        /// Side-view path in metres, every ~50 ms.
        var samples: [FlightSample]
    }

    static func simulate(ballSpeedMps v0: Double, launchAngleDeg: Double, spinRpm: Double) -> Result {
        let g = 9.81, mass = 0.04593, rho = 1.225, radius = 0.021335
        let area = Double.pi * radius * radius
        let omega = spinRpm * 2 * .pi / 60
        let launch = max(-5, min(60, launchAngleDeg)) * .pi / 180

        var vx = v0 * cos(launch), vy = v0 * sin(launch)
        var x = 0.0, y = 0.0, t = 0.0, apex = 0.0
        var samples = [FlightSample(t: 0, x: 0, y: 0)]
        var nextSample = 0.05
        let dt = 0.002

        func acceleration(_ vx: Double, _ vy: Double) -> (Double, Double) {
            let v = max(hypot(vx, vy), 0.01)
            let spinParameter = omega * radius / v
            let cl = min(0.55 * sqrt(max(spinParameter, 0)), 0.26)
            let cd = 0.27 + 0.25 * max(0, (30 - v) / 30)
            let k = 0.5 * rho * v * v * area / mass
            let ax = -k * cd * vx / v - k * cl * vy / v
            let ay = -g - k * cd * vy / v + k * cl * vx / v
            return (ax, ay)
        }

        while t < 15, hypot(vx, vy) > 0.5 {
            let (ax1, ay1) = acceleration(vx, vy)
            let mvx = vx + ax1 * dt / 2, mvy = vy + ay1 * dt / 2
            let (ax2, ay2) = acceleration(mvx, mvy)
            x += mvx * dt
            y += mvy * dt
            vx += ax2 * dt
            vy += ay2 * dt
            t += dt
            apex = max(apex, y)
            if t >= nextSample {
                samples.append(FlightSample(t: t, x: x, y: max(0, y)))
                nextSample += 0.05
            }
            if y < 0, t > 0.05 { break }
        }
        let descent = atan2(-vy, max(abs(vx), 0.01)) * 180 / .pi
        samples.append(FlightSample(t: t, x: max(0, x), y: 0))
        return Result(carryMeters: max(0, x), apexMeters: apex, hangTime: t,
                      descentAngleDeg: max(0, descent), samples: samples)
    }

    /// Full metrics from a measured ball speed / launch angle.
    static func metrics(ballSpeedMps: Double, launchAngleDeg: Double, club: Club) -> (ShotMetrics, Result) {
        let flight = simulate(ballSpeedMps: ballSpeedMps, launchAngleDeg: launchAngleDeg, spinRpm: club.typicalSpinRpm)
        let ballMph = ballSpeedMps * 2.23694
        let smash = typicalSmash(for: club)
        let metrics = ShotMetrics(ballSpeedMph: ballMph, clubSpeedMph: ballMph / smash,
                                  launchAngleDeg: launchAngleDeg, carryYards: flight.carryMeters * 1.09361,
                                  apexYards: flight.apexMeters * 1.09361, hangTimeS: flight.hangTime,
                                  descentAngleDeg: flight.descentAngleDeg)
        return (metrics, flight)
    }

    /// Typical amateur smash factor (tour average − 0.04).
    static func typicalSmash(for club: Club) -> Double {
        if let pro = ProReference.stats(for: club) { return pro.smashFactor - 0.04 }
        return 1.18
    }
}
