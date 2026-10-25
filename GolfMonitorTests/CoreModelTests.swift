import XCTest
import UIKit
@testable import GolfMonitor

final class CoreModelTests: XCTestCase {

    /// A shots.json written by v1 of the app must still load.
    func testDecodesV1ShotJSON() throws {
        let v1 = """
        [{"id":"6B1E6E8A-3C54-4E0B-9C61-7C8F8D6B7A10","date":700000000,"club":"7 Iron",
          "ballSpeedMph":118.2,"clubSpeedMph":86.1,"launchAngleDeg":17.4,"carryYards":161.5,
          "apexYards":29.0,"hangTimeS":6.1,"smashFactor":1.37,"tempoRatio":3.1,"offlineYards":-2.5,
          "notes":"flushed"}]
        """
        let shots = try JSONDecoder().decode([Shot].self, from: Data(v1.utf8))
        XCTAssertEqual(shots.count, 1)
        let s = shots[0]
        XCTAssertEqual(s.club, .iron7)
        XCTAssertEqual(s.ballSpeedMph, 118.2, accuracy: 1e-9)
        XCTAssertEqual(s.notes, "flushed")
        XCTAssertEqual(s.cameraView, .faceOn)
        XCTAssertEqual(s.source, .live)
        XCTAssertFalse(s.hasMedia)
        XCTAssertNil(s.sessionID)
        XCTAssertTrue(s.tags.isEmpty)
    }

    func testShotRoundTripKeepsV2Fields() throws {
        var shot = Shot(club: .driver, ballSpeedMph: 150, clubSpeedMph: 102, launchAngleDeg: 12,
                        carryYards: 240, apexYards: 30, hangTimeS: 6.5, smashFactor: 1.47,
                        tempoRatio: 3.0, offlineYards: 4)
        shot.cameraView = .downTheLine
        shot.swingScore = 81
        shot.tags = ["range", "new driver"]
        shot.practice = PracticeContext(gameID: "combine", targetCarryYards: 150, points: 7)
        let decoded = try JSONDecoder().decode(Shot.self, from: JSONEncoder().encode(shot))
        XCTAssertEqual(decoded, shot)
    }

    func testStoreMediaLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ShotStore(rootDirectory: root)
        let session = store.startSession(cameraView: .faceOn)
        let clip = root.appendingPathComponent("tmp.mov")
        try Data("fake".utf8).write(to: clip)
        let analysis = SwingAnalysis(fps: 240, frameWidth: 720, frameHeight: 1280, duration: 2,
                                     cameraView: .faceOn, handedness: .right)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
        let saved = store.addShot(Shot(club: .iron7, ballSpeedMph: 120, clubSpeedMph: 88, launchAngleDeg: 16,
                                       carryYards: 165, apexYards: 30, hangTimeS: 6, smashFactor: 1.36,
                                       tempoRatio: 3, offlineYards: 0),
                                  clipURL: clip, analysis: analysis, thumbnail: thumb)
        XCTAssertTrue(saved.hasMedia)
        XCTAssertEqual(saved.sessionID, session.id)
        XCTAssertNotNil(store.clipURL(for: saved.id))
        XCTAssertNotNil(store.thumbnailURL(for: saved.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.path), "clip should be moved, not copied")

        // Reload from disk.
        let reloaded = ShotStore(rootDirectory: root)
        XCTAssertEqual(reloaded.shots.first?.id, saved.id)
        XCTAssertEqual(reloaded.analysis(for: saved.id)?.fps, 240)
        XCTAssertEqual(reloaded.sessions.first?.id, session.id)

        reloaded.delete(ids: [saved.id])
        XCTAssertNil(reloaded.clipURL(for: saved.id))
        XCTAssertTrue(reloaded.shots.isEmpty)
    }

    func testPoseSampleFlatteningAndLookup() {
        let pose = PoseSample(t: 0.5, points: [.leftWrist: (CGPoint(x: 0.25, y: 0.75), 0.9)])
        XCTAssertEqual(pose.joints.count, BodyJoint.allCases.count * 3)
        XCTAssertEqual(pose.point(.leftWrist)?.x ?? 0, 0.25, accuracy: 1e-6)
        XCTAssertNil(pose.point(.rightWrist))
        var a = SwingAnalysis(fps: 240, frameWidth: 1, frameHeight: 1, duration: 1, cameraView: .faceOn, handedness: .right)
        a.poses = [0.0, 0.1, 0.2, 0.3].map { PoseSample(t: $0, joints: []) }
        XCTAssertEqual(a.pose(at: 0.26)?.t, 0.3)
        XCTAssertEqual(a.pose(at: 0.14)?.t, 0.1)
        XCTAssertEqual(a.pose(at: -1)?.t, 0.0)
        XCTAssertEqual(a.pose(at: 9)?.t, 0.3)
    }
}
