import Foundation

// MARK: - Supporting enums

/// Where the tripod is relative to the golfer.
/// - faceOn: camera perpendicular to the target line, looking at the golfer's
///   chest. Ball flight crosses the frame, so ball speed and launch angle are
///   measurable; sway, head movement and weight shift are visible.
/// - downTheLine: camera behind the hands looking at the target. Swing plane,
///   spine angle, early extension and start direction are visible; ball speed
///   is not measurable (the ball flies away from the lens).
enum CameraView: String, Codable, CaseIterable, Identifiable {
    case faceOn
    case downTheLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .faceOn: return "Face-On"
        case .downTheLine: return "Down the Line"
        }
    }

    var shortTitle: String {
        switch self {
        case .faceOn: return "FO"
        case .downTheLine: return "DTL"
        }
    }
}

enum Handedness: String, Codable, CaseIterable, Identifiable {
    case right
    case left

    var id: String { rawValue }
    var title: String { self == .right ? "Right-handed" : "Left-handed" }
}

/// How a shot entered the library.
enum ShotSource: String, Codable {
    /// Recorded with the in-app camera.
    case live
    /// Imported from the photo library / Files.
    case imported
    /// Bundled sample content or generated demo data.
    case demo
}

/// Practice-game context the shot was hit under, if any.
struct PracticeContext: Codable, Hashable {
    var gameID: String
    var targetCarryYards: Double?
    var points: Int?
}

// MARK: - Shot

/// One measured shot. Canonical stored units: mph for speeds, yards for
/// distances, seconds for times. Display converts via SettingsStore.
///
/// Persisted in Documents/shots.json. v1 files only contain the fields up to
/// `notes`; everything after is optional on decode so old libraries load.
struct Shot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var club: Club
    var ballSpeedMph: Double
    var clubSpeedMph: Double
    var launchAngleDeg: Double
    var carryYards: Double
    var apexYards: Double
    var hangTimeS: Double
    var smashFactor: Double
    /// Backswing:downswing expressed as X:1 (e.g. 3.0). 0 = unknown.
    var tempoRatio: Double
    /// Lateral miss at carry distance, + = right of target. Side-view estimate.
    var offlineYards: Double
    /// Always nil from the camera: a phone cannot measure spin.
    var spinRpmEstimate: Double? = nil
    var notes: String = ""

    // MARK: v2 fields

    var sessionID: UUID? = nil
    var cameraView: CameraView = .faceOn
    var source: ShotSource = .live
    /// Carry plus an estimated roll-out (flight-model estimate).
    var totalYards: Double? = nil
    /// Angle the ball lands at (flight-model estimate).
    var descentAngleDeg: Double? = nil
    var backswingTimeS: Double? = nil
    var downswingTimeS: Double? = nil
    /// 0–100 overall swing score from pose metrics vs tour ranges.
    var swingScore: Int? = nil
    /// 0–1 confidence in the ball track that produced the launch numbers.
    var trackingQuality: Double? = nil
    /// True when a clip + analysis live in ShotStore's media folder.
    var hasMedia: Bool = false
    var isFavorite: Bool = false
    var tags: [String] = []
    var practice: PracticeContext? = nil
    /// Compact copy of the analysis' swing metrics (SwingMetric.id → value)
    /// so Insights can chart trends without loading every analysis.json.
    var metricSummary: [String: Double] = [:]
    /// Seconds from clip start to impact, when known.
    var impactTimeInClip: Double? = nil

    init(id: UUID = UUID(), date: Date = Date(), club: Club,
         ballSpeedMph: Double, clubSpeedMph: Double, launchAngleDeg: Double,
         carryYards: Double, apexYards: Double, hangTimeS: Double,
         smashFactor: Double, tempoRatio: Double, offlineYards: Double,
         spinRpmEstimate: Double? = nil, notes: String = "",
         sessionID: UUID? = nil, cameraView: CameraView = .faceOn,
         source: ShotSource = .live, totalYards: Double? = nil,
         descentAngleDeg: Double? = nil, backswingTimeS: Double? = nil,
         downswingTimeS: Double? = nil, swingScore: Int? = nil,
         trackingQuality: Double? = nil, hasMedia: Bool = false,
         isFavorite: Bool = false, tags: [String] = [],
         practice: PracticeContext? = nil, metricSummary: [String: Double] = [:],
         impactTimeInClip: Double? = nil) {
        self.id = id
        self.date = date
        self.club = club
        self.ballSpeedMph = ballSpeedMph
        self.clubSpeedMph = clubSpeedMph
        self.launchAngleDeg = launchAngleDeg
        self.carryYards = carryYards
        self.apexYards = apexYards
        self.hangTimeS = hangTimeS
        self.smashFactor = smashFactor
        self.tempoRatio = tempoRatio
        self.offlineYards = offlineYards
        self.spinRpmEstimate = spinRpmEstimate
        self.notes = notes
        self.sessionID = sessionID
        self.cameraView = cameraView
        self.source = source
        self.totalYards = totalYards
        self.descentAngleDeg = descentAngleDeg
        self.backswingTimeS = backswingTimeS
        self.downswingTimeS = downswingTimeS
        self.swingScore = swingScore
        self.trackingQuality = trackingQuality
        self.hasMedia = hasMedia
        self.isFavorite = isFavorite
        self.tags = tags
        self.practice = practice
        self.metricSummary = metricSummary
        self.impactTimeInClip = impactTimeInClip
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, club, ballSpeedMph, clubSpeedMph, launchAngleDeg, carryYards,
             apexYards, hangTimeS, smashFactor, tempoRatio, offlineYards,
             spinRpmEstimate, notes, sessionID, cameraView, source, totalYards,
             descentAngleDeg, backswingTimeS, downswingTimeS, swingScore,
             trackingQuality, hasMedia, isFavorite, tags, practice, metricSummary,
             impactTimeInClip
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        club = try c.decode(Club.self, forKey: .club)
        ballSpeedMph = try c.decodeIfPresent(Double.self, forKey: .ballSpeedMph) ?? 0
        clubSpeedMph = try c.decodeIfPresent(Double.self, forKey: .clubSpeedMph) ?? 0
        launchAngleDeg = try c.decodeIfPresent(Double.self, forKey: .launchAngleDeg) ?? 0
        carryYards = try c.decodeIfPresent(Double.self, forKey: .carryYards) ?? 0
        apexYards = try c.decodeIfPresent(Double.self, forKey: .apexYards) ?? 0
        hangTimeS = try c.decodeIfPresent(Double.self, forKey: .hangTimeS) ?? 0
        smashFactor = try c.decodeIfPresent(Double.self, forKey: .smashFactor) ?? 0
        tempoRatio = try c.decodeIfPresent(Double.self, forKey: .tempoRatio) ?? 0
        offlineYards = try c.decodeIfPresent(Double.self, forKey: .offlineYards) ?? 0
        spinRpmEstimate = try c.decodeIfPresent(Double.self, forKey: .spinRpmEstimate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        cameraView = try c.decodeIfPresent(CameraView.self, forKey: .cameraView) ?? .faceOn
        source = try c.decodeIfPresent(ShotSource.self, forKey: .source) ?? .live
        totalYards = try c.decodeIfPresent(Double.self, forKey: .totalYards)
        descentAngleDeg = try c.decodeIfPresent(Double.self, forKey: .descentAngleDeg)
        backswingTimeS = try c.decodeIfPresent(Double.self, forKey: .backswingTimeS)
        downswingTimeS = try c.decodeIfPresent(Double.self, forKey: .downswingTimeS)
        swingScore = try c.decodeIfPresent(Int.self, forKey: .swingScore)
        trackingQuality = try c.decodeIfPresent(Double.self, forKey: .trackingQuality)
        hasMedia = try c.decodeIfPresent(Bool.self, forKey: .hasMedia) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        practice = try c.decodeIfPresent(PracticeContext.self, forKey: .practice)
        metricSummary = try c.decodeIfPresent([String: Double].self, forKey: .metricSummary) ?? [:]
        impactTimeInClip = try c.decodeIfPresent(Double.self, forKey: .impactTimeInClip)
    }

    /// Whether launch numbers exist (down-the-line shots and swing-only clips
    /// have no ball speed).
    var hasLaunchData: Bool { ballSpeedMph > 0 }
}

// MARK: - Session

/// A practice session: a block of shots hit together. Shots reference it by
/// `sessionID`; metadata lives in Documents/sessions.json.
struct PracticeSession: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: Date = Date()
    var end: Date? = nil
    var title: String = ""
    var cameraView: CameraView = .faceOn
    /// Practice game played during the session, if any (PracticeGame.id).
    var gameID: String? = nil
    var notes: String = ""
}
