import Foundation
import UIKit

/// Local-only shot library (no server, no cloud).
///
/// Layout inside `rootDirectory` (the app's Documents folder by default):
///   shots.json                 — [Shot], newest first (v1-compatible)
///   sessions.json              — [PracticeSession]
///   ShotMedia/<shot-id>/clip.mov       — the recorded swing clip
///   ShotMedia/<shot-id>/analysis.json  — SwingAnalysis
///   ShotMedia/<shot-id>/thumb.jpg      — poster frame for lists
///
/// All methods must be called on the main thread (it is an ObservableObject
/// driving SwiftUI); file I/O is small and synchronous except clip moves.
final class ShotStore: ObservableObject {
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var sessions: [PracticeSession] = []
    /// The session new shots are attached to, if one is running.
    @Published private(set) var activeSessionID: UUID?

    let rootDirectory: URL
    private var analysisCache: [UUID: SwingAnalysis] = [:]

    private var shotsURL: URL { rootDirectory.appendingPathComponent("shots.json") }
    private var sessionsURL: URL { rootDirectory.appendingPathComponent("sessions.json") }
    var mediaRoot: URL { rootDirectory.appendingPathComponent("ShotMedia", isDirectory: true) }

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        load()
    }

    // MARK: Shots

    /// Adds a shot with no media (v1 API).
    func addShot(_ shot: Shot) {
        var s = shot
        if s.sessionID == nil { s.sessionID = activeSessionID }
        shots.insert(s, at: 0)
        save()
    }

    /// Adds a shot and moves its clip / analysis / thumbnail into the media
    /// folder. The clip at `clipURL` is MOVED (it is usually a temp file).
    @discardableResult
    func addShot(_ shot: Shot, clipURL: URL?, analysis: SwingAnalysis?, thumbnail: UIImage?) -> Shot {
        var s = shot
        if s.sessionID == nil { s.sessionID = activeSessionID }
        let dir = mediaDirectory(for: s.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let clipURL {
            let dst = dir.appendingPathComponent("clip.mov")
            try? FileManager.default.removeItem(at: dst)
            do {
                try FileManager.default.moveItem(at: clipURL, to: dst)
            } catch {
                try? FileManager.default.copyItem(at: clipURL, to: dst)
            }
            s.hasMedia = FileManager.default.fileExists(atPath: dst.path)
        }
        if let analysis { saveAnalysis(analysis, for: s.id) }
        if let thumbnail, let data = thumbnail.jpegData(compressionQuality: 0.8) {
            try? data.write(to: dir.appendingPathComponent("thumb.jpg"), options: .atomic)
        }
        shots.insert(s, at: 0)
        save()
        return s
    }

    func update(_ shot: Shot) {
        guard let i = shots.firstIndex(where: { $0.id == shot.id }) else { return }
        shots[i] = shot
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = shots.firstIndex(where: { $0.id == id }) else { return }
        shots[i].isFavorite.toggle()
        save()
    }

    func delete(at offsets: IndexSet) {
        let ids = offsets.map { shots[$0].id }
        delete(ids: ids)
    }

    func delete(ids: [UUID]) {
        let set = Set(ids)
        for id in set {
            try? FileManager.default.removeItem(at: mediaDirectory(for: id))
            analysisCache[id] = nil
        }
        shots.removeAll { set.contains($0.id) }
        save()
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: mediaRoot)
        analysisCache.removeAll()
        shots.removeAll()
        sessions.removeAll()
        activeSessionID = nil
        save()
        saveSessions()
    }

    func shot(id: UUID) -> Shot? { shots.first { $0.id == id } }

    func shots(for club: Club?) -> [Shot] {
        guard let club else { return shots }
        return shots.filter { $0.club == club }
    }

    func shots(inSession id: UUID) -> [Shot] {
        shots.filter { $0.sessionID == id }
    }

    // MARK: Media

    func mediaDirectory(for id: UUID) -> URL {
        mediaRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func clipURL(for id: UUID) -> URL? {
        let url = mediaDirectory(for: id).appendingPathComponent("clip.mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailURL(for id: UUID) -> URL? {
        let url = mediaDirectory(for: id).appendingPathComponent("thumb.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnail(for id: UUID) -> UIImage? {
        thumbnailURL(for: id).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    func analysis(for id: UUID) -> SwingAnalysis? {
        if let cached = analysisCache[id] { return cached }
        let url = mediaDirectory(for: id).appendingPathComponent("analysis.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(SwingAnalysis.self, from: data)
        else { return nil }
        analysisCache[id] = decoded
        return decoded
    }

    func saveAnalysis(_ analysis: SwingAnalysis, for id: UUID) {
        let dir = mediaDirectory(for: id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: dir.appendingPathComponent("analysis.json"), options: .atomic)
        }
        analysisCache[id] = analysis
    }

    // MARK: Sessions

    @discardableResult
    func startSession(cameraView: CameraView, gameID: String? = nil, title: String = "") -> PracticeSession {
        if let active = activeSessionID { endSession(active) }
        let session = PracticeSession(start: Date(), title: title, cameraView: cameraView, gameID: gameID)
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        saveSessions()
        return session
    }

    func endSession(_ id: UUID) {
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].end == nil {
            sessions[i].end = Date()
        }
        if activeSessionID == id { activeSessionID = nil }
        saveSessions()
    }

    func session(id: UUID) -> PracticeSession? { sessions.first { $0.id == id } }

    func updateSession(_ session: PracticeSession) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i] = session
        saveSessions()
    }

    // MARK: Stats (per club)

    struct ClubAverages {
        var count: Int = 0
        var ballSpeedMph: Double = 0
        var clubSpeedMph: Double = 0
        var carryYards: Double = 0
        var launchAngleDeg: Double = 0
        var smashFactor: Double = 0
        var apexYards: Double = 0
        var hangTimeS: Double = 0
        var tempoRatio: Double = 0
        var offlineYards: Double = 0
    }

    /// Averages over shots that have launch data. Zero-valued club speed,
    /// smash and tempo mean "not tracked" and are excluded per metric.
    func averages(for club: Club) -> ClubAverages {
        let list = shots(for: club).filter(\.hasLaunchData)
        guard !list.isEmpty else { return ClubAverages() }
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        return ClubAverages(
            count: list.count,
            ballSpeedMph: mean(list.map(\.ballSpeedMph)),
            clubSpeedMph: mean(list.map(\.clubSpeedMph).filter { $0 > 0 }),
            carryYards: mean(list.map(\.carryYards)),
            launchAngleDeg: mean(list.map(\.launchAngleDeg)),
            smashFactor: mean(list.map(\.smashFactor).filter { $0 > 0 }),
            apexYards: mean(list.map(\.apexYards)),
            hangTimeS: mean(list.map(\.hangTimeS)),
            tempoRatio: mean(list.map(\.tempoRatio).filter { $0 > 0 }),
            offlineYards: mean(list.map(\.offlineYards))
        )
    }

    struct ClubBests {
        var count: Int = 0
        var carryYards: Double = 0
        var ballSpeedMph: Double = 0
        var clubSpeedMph: Double = 0
        var smashFactor: Double = 0
        /// Smallest absolute offline — closest to the target line.
        var offlineAbsYards: Double = 0
    }

    /// Personal bests for a club. Only metrics where "best" is unambiguous.
    func bests(for club: Club) -> ClubBests {
        let list = shots(for: club).filter(\.hasLaunchData)
        guard !list.isEmpty else { return ClubBests() }
        return ClubBests(
            count: list.count,
            carryYards: list.map(\.carryYards).max() ?? 0,
            ballSpeedMph: list.map(\.ballSpeedMph).max() ?? 0,
            clubSpeedMph: list.map(\.clubSpeedMph).max() ?? 0,
            smashFactor: list.map(\.smashFactor).max() ?? 0,
            offlineAbsYards: list.map { abs($0.offlineYards) }.min() ?? 0
        )
    }

    // MARK: Export

    /// CSV for export via share sheet.
    func csvString() -> String {
        var lines = ["date,club,camera_view,ball_speed_mph,club_speed_mph,launch_angle_deg,carry_yds,total_yds,apex_yds,hang_time_s,smash_factor,tempo_ratio,backswing_s,downswing_s,offline_yds,swing_score,favorite,notes"]
        let df = ISO8601DateFormatter()
        func f(_ v: Double?, _ digits: Int = 1) -> String {
            guard let v, v.isFinite else { return "" }
            return String(format: "%.\(digits)f", v)
        }
        for s in shots {
            let notes = s.notes.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append([
                df.string(from: s.date), s.club.rawValue, s.cameraView.rawValue,
                f(s.ballSpeedMph), f(s.clubSpeedMph), f(s.launchAngleDeg), f(s.carryYards),
                f(s.totalYards), f(s.apexYards), f(s.hangTimeS, 2), f(s.smashFactor, 2),
                f(s.tempoRatio, 2), f(s.backswingTimeS, 3), f(s.downswingTimeS, 3),
                f(s.offlineYards), s.swingScore.map(String.init) ?? "",
                s.isFavorite ? "1" : "0", "\"\(notes)\"",
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Full JSON backup of shots + sessions (media not included).
    func jsonBackup() -> Data? {
        struct Backup: Codable { var shots: [Shot]; var sessions: [PracticeSession] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Backup(shots: shots, sessions: sessions))
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(shots) {
            try? data.write(to: shotsURL, options: .atomic)
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: shotsURL),
           let decoded = try? JSONDecoder().decode([Shot].self, from: data) {
            shots = decoded.sorted { $0.date > $1.date }
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? JSONDecoder().decode([PracticeSession].self, from: data) {
            sessions = decoded.sorted { $0.start > $1.start }
            // A session left open by a previous launch is closed, not resumed.
            for i in sessions.indices where sessions[i].end == nil {
                sessions[i].end = shots(inSession: sessions[i].id).first?.date ?? sessions[i].start
            }
        }
    }
}
