import XCTest
@testable import GolfMonitor

/// Launch fitting, flight model and swing phases.
final class AnalysisTests: XCTestCase {
    // MARK: Launch fit

    private func blobs(from address: CGPoint, velocity: CGVector, impact: Double, frames: ClosedRange<Int>,
                       fps: Double = 240) -> [LaunchMeasurer.Blob] {
        frames.map { k in
            let t = impact + Double(k) / fps
            return LaunchMeasurer.Blob(t: t, center: CGPoint(x: address.x + velocity.dx * (t - impact),
                                                             y: address.y + velocity.dy * (t - impact)), area: 200)
        }
    }

    func testFitRecoversVelocityThroughDistractors() throws {
        let address = CGPoint(x: 400, y: 900)
        let v = CGVector(dx: 14_000, dy: -4_000)
        var all = blobs(from: address, velocity: v, impact: 1.0, frames: 1...4)
        // A static glint and a slow club highlight.
        for k in 0...6 {
            let t = 1.0 + Double(k) / 240
            all.append(LaunchMeasurer.Blob(t: t, center: CGPoint(x: 200, y: 300), area: 300))
            all.append(LaunchMeasurer.Blob(t: t, center: CGPoint(x: 380 + Double(k) * 6, y: 880), area: 400))
        }
        let fit = try XCTUnwrap(LaunchMeasurer.fit(blobs: all, address: address, impactTime: 1.0,
                                                   diameterPx: 20, fps: 240))
        XCTAssertEqual(fit.inliers.count, 4)
        XCTAssertEqual(fit.velocity.dx, v.dx, accuracy: 50)
        XCTAssertEqual(fit.velocity.dy, v.dy, accuracy: 50)
    }

    func testFitToleratesImpactTimeOffByAFrame() throws {
        let address = CGPoint(x: 400, y: 900)
        let v = CGVector(dx: -12_000, dy: -6_000)
        let all = blobs(from: address, velocity: v, impact: 1.0, frames: 1...3)
        let fit = try XCTUnwrap(LaunchMeasurer.fit(blobs: all, address: address, impactTime: 1.0 + 1.0 / 240,
                                                   diameterPx: 20, fps: 240))
        XCTAssertEqual(fit.velocity.dx, v.dx, accuracy: 50, "left-flying ball too")
    }

    func testFitRejectsSlowOrUnrelatedMotion() {
        let address = CGPoint(x: 400, y: 900)
        let slow = blobs(from: address, velocity: CGVector(dx: 1_500, dy: 0), impact: 1, frames: 1...5)
        XCTAssertNil(LaunchMeasurer.fit(blobs: slow, address: address, impactTime: 1, diameterPx: 20, fps: 240))
        let elsewhere = blobs(from: CGPoint(x: 100, y: 200), velocity: CGVector(dx: 14_000, dy: 0), impact: 1, frames: 1...4)
        XCTAssertNil(LaunchMeasurer.fit(blobs: elsewhere, address: address, impactTime: 1, diameterPx: 20, fps: 240),
                     "a fast thing that didn't come from the ball isn't the ball")
    }

    func testMovingBlobsDropsStaticOnes() {
        let still = (0..<3).map { LaunchMeasurer.Blob(t: Double($0) / 240, center: CGPoint(x: 10, y: 10), area: 100) }
        let mover = (0..<3).map { LaunchMeasurer.Blob(t: Double($0) / 240, center: CGPoint(x: 100 + Double($0) * 60, y: 50), area: 100) }
        let kept = LaunchMeasurer.movingBlobs(still + mover, diameterPx: 20)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept.allSatisfy { $0.center.y == 50 })
    }

    func testLaunchOnRealSwingFixture() async throws {
        let url = try XCTUnwrap(MLPipelineTests.fixtureURL("faceon_driver"))
        let launch = try await LaunchMeasurer.measure(videoURL: url, impactTimeHint: 1.27,
                                                      ballCenter: CGPoint(x: 385, y: 865), ballDiameterPx: 18.1,
                                                      pixelsPerMeter: 18.1 / Calibration.golfBallDiameterMeters)
        XCTAssertGreaterThanOrEqual(launch.points.count, 4, "address + ≥3 tracked frames")
        XCTAssertEqual(launch.impactTime, 1.245, accuracy: 0.012)
        XCTAssertTrue((15...35).contains(launch.launchAngleDeg), "launch \(launch.launchAngleDeg)")
        XCTAssertTrue((60...95).contains(launch.speedMps * 2.23694), "speed \(launch.speedMps * 2.23694) mph")
        XCTAssertGreaterThan(launch.velocityPx.dx, 0, "ball flies to the right in this clip")
    }

    // MARK: Flight model

    func testFlightModelMatchesReferenceCarries() {
        let driver = FlightModel.simulate(ballSpeedMps: 157 / 2.23694, launchAngleDeg: 12, spinRpm: Club.driver.typicalSpinRpm)
        XCTAssertEqual(driver.carryMeters * 1.09361, 235, accuracy: 25)
        let nine = FlightModel.simulate(ballSpeedMps: 101 / 2.23694, launchAngleDeg: 20, spinRpm: Club.iron9.typicalSpinRpm)
        XCTAssertEqual(nine.carryMeters * 1.09361, 150, accuracy: 18)
        XCTAssertGreaterThan(driver.apexMeters, 15)
        XCTAssertTrue((25...60).contains(driver.descentAngleDeg))
        XCTAssertEqual(driver.samples.last?.y, 0)
    }

    func testFlightModelCarryGrowsWithSpeed() {
        let carries = [60.0, 80, 100, 120].map {
            FlightModel.simulate(ballSpeedMps: $0 / 2.23694, launchAngleDeg: 14, spinRpm: 3000).carryMeters
        }
        XCTAssertEqual(carries, carries.sorted())
    }

    func testMetricsEstimateClubSpeedFromTypicalSmash() {
        let (m, _) = FlightModel.metrics(ballSpeedMps: 60, launchAngleDeg: 13, club: .driver)
        XCTAssertEqual(m.ballSpeedMph, 134.2, accuracy: 0.2)
        XCTAssertEqual(m.clubSpeedMph, m.ballSpeedMph / 1.44, accuracy: 0.2)
        XCTAssertEqual(m.smashFactor, 0, "smash isn't claimed when club speed is estimated")
    }

    // MARK: Phases

    /// Lead wrist: still until 1.0, rises to the top at 1.9, back down at impact 2.2.
    private func swingPoses() -> [PoseSample] {
        stride(from: 0.0, through: 3.0, by: 1.0 / 30).map { t -> PoseSample in
            let y: Double
            if t < 1.0 { y = 0.6 } else if t < 1.9 { y = 0.6 - 0.35 * (t - 1.0) / 0.9 } else if t < 2.2 {
                y = 0.25 + 0.35 * (t - 1.9) / 0.3
            } else { y = 0.6 - 0.3 * min(1, (t - 2.2) / 0.5) }
            return PoseSample(t: t, points: [.leftWrist: (CGPoint(x: 0.5, y: y), 0.9)])
        }
    }

    func testPhasesAnchoredOnImpactGiveTourLikeTempo() throws {
        let phases = SwingPhaseDetector.phases(from: swingPoses(), handedness: .right, impactTime: 2.2)
        XCTAssertEqual(phases.map(\.phase), SwingPhase.allCases)
        XCTAssertEqual(try XCTUnwrap(phases.first { $0.phase == .top }).t, 1.9, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(phases.first { $0.phase == .address }).t, 1.0, accuracy: 0.07)
        let tempo = try XCTUnwrap(SwingPhaseDetector.tempoMetrics(from: phases).first { $0.id == "tempo.ratio" })
        XCTAssertEqual(tempo.value, 3.0, accuracy: 0.3)
        XCTAssertEqual(tempo.rating, .tour)
    }

    func testPhasesUseTrailWristForLeftHanders() {
        let lefty = swingPoses().map { pose -> PoseSample in
            PoseSample(t: pose.t, points: [.rightWrist: (pose.point(.leftWrist)!, 0.9)])
        }
        XCTAssertEqual(SwingPhaseDetector.phases(from: lefty, handedness: .left, impactTime: 2.2).count, 8)
    }

    func testNoPhasesWithoutASwing() {
        let still = (0..<60).map { PoseSample(t: Double($0) / 30, points: [.leftWrist: (CGPoint(x: 0.5, y: 0.6), 0.9)]) }
        XCTAssertTrue(SwingPhaseDetector.phases(from: still, handedness: .right, impactTime: 1.5).isEmpty)
    }

    func testPoseMetricsMeasure2DPostureAndMovement() throws {
        let address = PoseSample(t: 0, points: [
            .nose: (CGPoint(x: 0.50, y: 0.15), 0.9),
            .leftShoulder: (CGPoint(x: 0.45, y: 0.30), 0.9),
            .rightShoulder: (CGPoint(x: 0.55, y: 0.30), 0.9),
            .leftHip: (CGPoint(x: 0.46, y: 0.60), 0.9),
            .rightHip: (CGPoint(x: 0.54, y: 0.60), 0.9),
            .leftKnee: (CGPoint(x: 0.43, y: 0.75), 0.9),
            .rightKnee: (CGPoint(x: 0.57, y: 0.75), 0.9),
            .leftAnkle: (CGPoint(x: 0.40, y: 0.90), 0.9),
            .rightAnkle: (CGPoint(x: 0.60, y: 0.90), 0.9),
        ])
        let shifted = PoseSample(t: 0.5, points: [
            .nose: (CGPoint(x: 0.57, y: 0.15), 0.9),
            .leftShoulder: (CGPoint(x: 0.52, y: 0.30), 0.9),
            .rightShoulder: (CGPoint(x: 0.62, y: 0.30), 0.9),
            .leftHip: (CGPoint(x: 0.53, y: 0.60), 0.9),
            .rightHip: (CGPoint(x: 0.61, y: 0.60), 0.9),
        ])

        let metrics = PoseMetrics.metrics(from: [address, shifted])
        XCTAssertEqual(metrics.first { $0.id == "pose.torsoLean2D" }?.value ?? -1, 0, accuracy: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.first { $0.id == "pose.headMovement" }).value, 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.first { $0.id == "pose.hipSway" }).value, 0)
        XCTAssertGreaterThan(try XCTUnwrap(metrics.first { $0.id == "pose.kneeFlex2D" }).value, 0)
        XCTAssertTrue(metrics.allSatisfy { $0.rating == .unrated })

        let tips = PoseMetrics.tips(from: metrics)
        XCTAssertEqual(tips.count, 4)
        XCTAssertTrue(tips.contains { $0.id == "pose.headMovement" && $0.suggestion.contains("Compare") })
        XCTAssertTrue(tips.contains { $0.id == "pose.hipSway" && $0.suggestion.contains("weight transfer") })
    }

    func testSwingFeedbackOnlyGradesTempoAndKeepsPostureNeutral() {
        XCTAssertEqual(SwingFeedback.tempoLabel(3), "ON REF")
        XCTAssertEqual(SwingFeedback.tempoLabel(2.5), "NEAR REF")
        XCTAssertEqual(SwingFeedback.tempoLabel(2.2), "NEAR REF")
        XCTAssertEqual(SwingFeedback.tempoLabel(3.9), "NEAR REF")
        XCTAssertEqual(SwingFeedback.tempoLabel(4.2), "CHECK")
        XCTAssertEqual(SwingFeedback.tempoLabel(0), "UNRATED")
        XCTAssertEqual(SwingFeedback.tempoLabel(.nan), "UNRATED")
        XCTAssertEqual(SwingFeedback.tempoLabel(.infinity), "UNRATED")

        let tempo = SwingMetric(id: "tempo.ratio", name: "Tempo", value: 4.2, unit: ":1")
        let posture = SwingMetric(id: "pose.hipSway", name: "Hip sway", value: 9, unit: "% torso")
        let summary = SwingFeedback.summary(metrics: [tempo, posture], poseCount: 20)
        XCTAssertTrue(summary.focus.contains("outside"))
        XCTAssertTrue(summary.positive.contains("20 frames"))
        XCTAssertEqual(summary.focusRating, .needsWork)
        XCTAssertEqual(summary.positiveRating, .unrated)

        let nearTempo = SwingMetric(id: "tempo.ratio", name: "Tempo", value: 2.5, unit: ":1")
        let nearSummary = SwingFeedback.summary(metrics: [nearTempo, posture], poseCount: 0)
        XCTAssertTrue(nearSummary.focus.contains("hip sway"))
        XCTAssertTrue(nearSummary.positive.contains("broader"))
        XCTAssertEqual(nearSummary.focusRating, .unrated)
        XCTAssertEqual(nearSummary.positiveRating, .good)

        let savedTempoSummary = SwingFeedback.summary(metrics: [], poseCount: 0, tempoRatio: 3)
        XCTAssertEqual(savedTempoSummary.positiveRating, .tour)
    }

    func testTempoTrendHistogramAndTargetPercentage() throws {
        let ratios = [1.9, 2.2, 2.69, 2.7, 3.0, 3.3, 3.31, 3.9, 4.1, 0, .nan, .infinity]
        let bins = TempoTrend.histogram(ratios)

        XCTAssertEqual(bins.map(\.count), [1, 2, 3, 2, 1])
        XCTAssertEqual(bins.filter(\.isTarget).map(\.label), ["2.7–3.3"])
        XCTAssertEqual(try XCTUnwrap(TempoTrend.onTargetPercentage(ratios)), 3.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(TempoTrend.onTargetPercentage([0, .nan, .infinity]))
    }

    func testSessionTrendOrdersShotsAndOmitsUnmeasuredValues() throws {
        let sessionID = UUID()
        let shots = [
            Shot(date: Date(timeIntervalSince1970: 30), club: .iron7, ballSpeedMph: 0,
                 clubSpeedMph: 0, launchAngleDeg: 0, carryYards: 0, apexYards: 0,
                 hangTimeS: 0, smashFactor: 0, tempoRatio: 0, offlineYards: 0, sessionID: sessionID),
            Shot(date: Date(timeIntervalSince1970: 20), club: .iron7, ballSpeedMph: 110,
                 clubSpeedMph: 0, launchAngleDeg: 15, carryYards: 0, apexYards: 0,
                 hangTimeS: 0, smashFactor: 0, tempoRatio: 3, offlineYards: 0, sessionID: sessionID),
            Shot(date: Date(timeIntervalSince1970: 10), club: .iron7, ballSpeedMph: 100,
                 clubSpeedMph: 0, launchAngleDeg: 14, carryYards: 0, apexYards: 0,
                 hangTimeS: 0, smashFactor: 0, tempoRatio: 2.8, offlineYards: 0, sessionID: sessionID),
            Shot(date: Date(timeIntervalSince1970: 5), club: .iron7, ballSpeedMph: 200,
                 clubSpeedMph: 0, launchAngleDeg: 20, carryYards: 0, apexYards: 0,
                 hangTimeS: 0, smashFactor: 0, tempoRatio: 4, offlineYards: 0),
        ]

        let points = SessionTrend.points(shots: shots, sessionID: sessionID, metric: .ballSpeed)
        XCTAssertEqual(points.map(\.shotNumber), [1, 2])
        XCTAssertEqual(points.map(\.value), [100, 110])
        XCTAssertEqual(SessionTrend.points(shots: shots, sessionID: UUID(), metric: .tempo).count, 0)
    }
}
