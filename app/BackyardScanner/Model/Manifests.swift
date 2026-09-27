import Foundation

// Mirrors of the JSON manifests written by scanner/models.py.  The app only ever *reads* these through Codable;
// the few fields it writes back (name, notes, status reconciliation, answers) go through ManifestStore.patchJSON so
// that unknown keys survive round trips.

enum Status: String, Decodable, Sendable, Hashable, CaseIterable {
    case pending, queued, running, done, failed, cancelled, skipped, interrupted, unknown

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Status(rawValue: raw) ?? .unknown
    }

    var isFinished: Bool { [.done, .failed, .cancelled, .interrupted].contains(self) }
}

struct Stage: Decodable, Sendable, Hashable {
    var status: Status = .pending
    var startedAt: String?
    var finishedAt: String?
    var metrics: [String: JSONValue] = [:]
    var error: String?
    var log: String?
    var durationS: Double?

    init() {}

    enum CodingKeys: String, CodingKey {
        case status, metrics, error, log
        case startedAt = "started_at", finishedAt = "finished_at", durationS = "duration_s"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        metrics = try c.decodeIfPresent([String: JSONValue].self, forKey: .metrics) ?? [:]
        error = try c.decodeIfPresent(String.self, forKey: .error)
        log = try c.decodeIfPresent(String.self, forKey: .log)
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS)
    }

    /// Seconds between start and finish; the manifest carries it, but migrated ones don't.
    var duration: Double? {
        if let durationS { return durationS }
        guard let a = Format.parse(startedAt), let b = Format.parse(finishedAt) else { return nil }
        return b.timeIntervalSince(a)
    }
}

struct FrameSettings: Decodable, Sendable, Hashable {
    var fps: Double = 2
    var maxFrames: Int = 400
    var hdr: String = "auto"

    init(fps: Double = 2, maxFrames: Int = 400, hdr: String = "auto") {
        self.fps = fps; self.maxFrames = maxFrames; self.hdr = hdr
    }

    enum CodingKeys: String, CodingKey { case fps, hdr, maxFrames = "max_frames" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 2
        maxFrames = try c.decodeIfPresent(Int.self, forKey: .maxFrames) ?? 400
        hdr = try c.decodeIfPresent(String.self, forKey: .hdr) ?? "auto"
    }
}

struct VideoInfo: Decodable, Sendable, Hashable {
    var path: String = ""
    var size: Int?
    var durationS: Double?
    var width: Int?
    var height: Int?
    var fps: Double?
    var frames: Int?
    var colorTransfer: String?
    var hdr: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case path, size, width, height, fps, frames, hdr, error
        case durationS = "duration_s", colorTransfer = "color_transfer"
    }

    var isHDR: Bool { let h = hdr ?? "none"; return h != "none" && !h.isEmpty }
    var fileName: String { (path as NSString).lastPathComponent }
}

struct Scan: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var createdAt: String
    var video: VideoInfo
    var frames: Stage = Stage()
    var frameSettings: FrameSettings = FrameSettings()
    var notes: String = ""
    var site: String?
    var thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id, name, video, frames, notes, site, thumbnail
        case createdAt = "created_at", frameSettings = "frame_settings"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        video = try c.decodeIfPresent(VideoInfo.self, forKey: .video) ?? VideoInfo()
        frames = try c.decodeIfPresent(Stage.self, forKey: .frames) ?? Stage()
        frameSettings = try c.decodeIfPresent(FrameSettings.self, forKey: .frameSettings) ?? FrameSettings()
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        site = try c.decodeIfPresent(String.self, forKey: .site)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}

struct RunSettings: Decodable, Sendable, Hashable {
    var resLevel: Int = 2
    var features: String = "SIFT"          // SIFT | ALIKED
    var matcher: String = "BRUTEFORCE"     // BRUTEFORCE | LIGHTGLUE
    var matching: String = "vocab"         // vocab | sequential | exhaustive
    var relaxed: Int = 1
    var measures: Int = 4
    var maxFaces: Int = 4_000_000

    init() {}

    enum CodingKeys: String, CodingKey {
        case features, matcher, matching, relaxed, measures
        case resLevel = "res_level", maxFaces = "max_faces"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resLevel = try c.decodeIfPresent(Int.self, forKey: .resLevel) ?? 2
        features = try c.decodeIfPresent(String.self, forKey: .features) ?? "SIFT"
        matcher = try c.decodeIfPresent(String.self, forKey: .matcher) ?? "BRUTEFORCE"
        matching = try c.decodeIfPresent(String.self, forKey: .matching) ?? "vocab"
        relaxed = try c.decodeIfPresent(Int.self, forKey: .relaxed) ?? 1
        measures = try c.decodeIfPresent(Int.self, forKey: .measures) ?? 4
        maxFaces = try c.decodeIfPresent(Int.self, forKey: .maxFaces) ?? 4_000_000
    }
}

struct Run: Decodable, Sendable, Hashable, Identifiable {
    static let stages = ["sfm", "dense", "landmarks", "plan"]

    var id: String
    var scanId: String
    var createdAt: String
    var settings: RunSettings = RunSettings()
    var status: Status = .queued
    var pid: Int?
    var startedAt: String?
    var finishedAt: String?
    var stages: [String: Stage] = [:]
    var planVersions: [[String: JSONValue]] = []
    var label: String = ""

    enum CodingKeys: String, CodingKey {
        case id, settings, status, pid, stages, label
        case scanId = "scan_id", createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at"
        case planVersions = "plan_versions"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scanId = try c.decodeIfPresent(String.self, forKey: .scanId) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        settings = try c.decodeIfPresent(RunSettings.self, forKey: .settings) ?? RunSettings()
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        stages = try c.decodeIfPresent([String: Stage].self, forKey: .stages) ?? [:]
        for k in Self.stages where stages[k] == nil { stages[k] = Stage() }
        planVersions = try c.decodeIfPresent([[String: JSONValue]].self, forKey: .planVersions) ?? []
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    func stage(_ key: String) -> Stage { stages[key] ?? Stage() }
}

// MARK: - measure/prompts.json, answers.json, transform.json

struct PromptPoint: Decodable, Sendable, Hashable {
    var pid: Int?
    var structural: Bool?
    var frame: String?
    var crop: String?
    var context: String?
}

struct Prompt: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var type: String            // distance | ground | north
    var kind: String?           // diagonal | vertical | edge
    var rank: Int?
    var modelDist: Double?
    var a: PromptPoint?
    var b: PromptPoint?
    var points: [PromptPoint]?
    var text: String?
    var frame: String?
    var context: String?

    enum CodingKeys: String, CodingKey {
        case id, type, kind, rank, a, b, points, text, frame, context
        case modelDist = "model_dist"
    }

    var kindLabel: String {
        switch kind { case "diagonal": "longest span"; case "vertical": "height"; case "edge": "span"; default: kind ?? type }
    }
}

struct PromptSet: Decodable, Sendable, Hashable {
    var count: Int
    var prompts: [Prompt]

    var distances: [Prompt] { prompts.filter { $0.type == "distance" } }
}

struct Answer: Codable, Sendable, Hashable {
    var value: Double? = nil
    var skipped: Bool? = nil
    var confirmed: Bool? = nil
    var bearing: Double? = nil
    var at: String? = nil

    var isEmpty: Bool { value == nil && skipped == nil && confirmed == nil && bearing == nil }
}

struct Residual: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: String
    var meters: Double
    var residualCm: Double

    enum CodingKeys: String, CodingKey { case id, kind, meters, residualCm = "residual_cm" }
}

struct Transform: Decodable, Sendable, Hashable {
    var scale: Double
    var ground: JSONValue?
    var north: JSONValue?
    var warning: Bool?
    var spreadPct: Double?
    var residuals: [Residual] = []

    enum CodingKeys: String, CodingKey { case scale, ground, north, warning, residuals, spreadPct = "spread_pct" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decode(Double.self, forKey: .scale)
        ground = try c.decodeIfPresent(JSONValue.self, forKey: .ground)
        north = try c.decodeIfPresent(JSONValue.self, forKey: .north)
        warning = try c.decodeIfPresent(JSONValue.self, forKey: .warning)?.bool
        spreadPct = try c.decodeIfPresent(Double.self, forKey: .spreadPct)
        residuals = try c.decodeIfPresent([Residual].self, forKey: .residuals) ?? []
    }
}
