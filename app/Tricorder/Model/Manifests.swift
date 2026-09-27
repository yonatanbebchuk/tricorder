import Foundation

// Mirrors of the JSON manifests written by tricorder/models.py.  The app only ever *reads* these through Codable;
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
    var original: String?
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
        case path, original, size, width, height, fps, frames, hdr, error
        case durationS = "duration_s", colorTransfer = "color_transfer"
    }

    var isHDR: Bool { let h = hdr ?? "none"; return h != "none" && !h.isEmpty }
    /// The name the user knows the footage by (the file they imported), else the stored copy.
    var fileName: String { ((original ?? path) as NSString).lastPathComponent }
}

// MARK: - environment

struct EnvironmentInfo: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var createdAt: String
    var notes: String

    enum CodingKeys: String, CodingKey { case id, name, notes, createdAt = "created_at" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

// MARK: - recording

struct Recording: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var envId: String
    var name: String
    var createdAt: String
    var kind: String
    var source: VideoInfo
    var frames: Stage
    var frameSettings: FrameSettings
    var notes: String
    var thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, source, frames, notes, thumbnail
        case envId = "env_id", createdAt = "created_at", frameSettings = "frame_settings"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        envId = try c.decodeIfPresent(String.self, forKey: .envId) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "video"
        source = try c.decodeIfPresent(VideoInfo.self, forKey: .source) ?? VideoInfo()
        frames = try c.decodeIfPresent(Stage.self, forKey: .frames) ?? Stage()
        frameSettings = try c.decodeIfPresent(FrameSettings.self, forKey: .frameSettings) ?? FrameSettings()
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
    }
}

// MARK: - run

enum RunKind: String, Decodable, Sendable, Hashable, CaseIterable {
    case scan, layout

    var label: String {
        switch self { case .scan: "Environment scan"; case .layout: "Layout" }
    }
    var verb: String {
        switch self { case .scan: "Scan"; case .layout: "Lay out" }
    }
    /// What the run consumes: a recording, or an asset of this kind.
    var inputAssetKind: AssetKind? { self == .layout ? .model3d : nil }
    var outputKind: AssetKind {
        switch self { case .scan: .model3d; case .layout: .sitePlan }
    }
    var stages: [String] {
        switch self { case .scan: ["sfm", "dense", "landmarks", "preview"]; case .layout: ["solve", "ortho", "draw", "preview"] }
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
    var pxPerM: Int = 50
    var contourM: Double = 0.25
    var sheetScale: Int = 100
    var previewFaces: Int = 300_000

    init() {}

    enum CodingKeys: String, CodingKey {
        case features, matcher, matching, relaxed, measures
        case resLevel = "res_level", maxFaces = "max_faces", pxPerM = "px_per_m", contourM = "contour_m", sheetScale = "sheet_scale"
        case previewFaces = "preview_faces"
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
        pxPerM = try c.decodeIfPresent(Int.self, forKey: .pxPerM) ?? 50
        contourM = try c.decodeIfPresent(Double.self, forKey: .contourM) ?? 0.25
        sheetScale = try c.decodeIfPresent(Int.self, forKey: .sheetScale) ?? 100
        previewFaces = try c.decodeIfPresent(Int.self, forKey: .previewFaces) ?? 300_000
    }
}

struct Run: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var envId: String
    var kind: RunKind
    var inputs: [String: String]
    var createdAt: String
    var settings: RunSettings
    var status: Status
    var pid: Int?
    var startedAt: String?
    var finishedAt: String?
    var stages: [String: Stage]
    var outputAsset: String?
    var label: String

    enum CodingKeys: String, CodingKey {
        case id, kind, inputs, settings, status, pid, stages, label
        case envId = "env_id", createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at"
        case outputAsset = "output_asset"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        envId = try c.decodeIfPresent(String.self, forKey: .envId) ?? ""
        kind = try c.decode(RunKind.self, forKey: .kind)
        inputs = try c.decodeIfPresent([String: String].self, forKey: .inputs) ?? [:]
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        settings = try c.decodeIfPresent(RunSettings.self, forKey: .settings) ?? RunSettings()
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .queued
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        stages = try c.decodeIfPresent([String: Stage].self, forKey: .stages) ?? [:]
        for k in kind.stages where stages[k] == nil { stages[k] = Stage() }
        outputAsset = try c.decodeIfPresent(String.self, forKey: .outputAsset)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    func stage(_ key: String) -> Stage { stages[key] ?? Stage() }
    /// The recording (reconstruct) or asset (plan) id this run consumed.
    var inputId: String { inputs["recording"] ?? inputs["asset"] ?? "" }
    var inputRecordingId: String? { inputs["recording"] }
    var inputAssetId: String? { inputs["asset"] }
}

// MARK: - asset

enum AssetKind: String, Decodable, Sendable, Hashable, CaseIterable {
    case model3d, sitePlan = "site_plan"

    var label: String {
        switch self { case .model3d: "3D Model"; case .sitePlan: "Site Plan" }
    }
    var symbol: String {
        switch self { case .model3d: "cube.transparent"; case .sitePlan: "map" }
    }
}

struct AssetFile: Decodable, Sendable, Hashable, Identifiable {
    var path: String
    var label: String
    var size: Int
    var id: String { path }
}

struct Asset: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var envId: String
    var kind: AssetKind
    var name: String
    var runId: String
    var createdAt: String
    var files: [AssetFile]
    var metrics: [String: JSONValue]
    var notes: String

    enum CodingKeys: String, CodingKey {
        case id, kind, name, files, metrics, notes
        case envId = "env_id", runId = "run_id", createdAt = "created_at"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        envId = try c.decodeIfPresent(String.self, forKey: .envId) ?? ""
        kind = try c.decode(AssetKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        runId = try c.decodeIfPresent(String.self, forKey: .runId) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        files = try c.decodeIfPresent([AssetFile].self, forKey: .files) ?? []
        metrics = try c.decodeIfPresent([String: JSONValue].self, forKey: .metrics) ?? [:]
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

// MARK: - measure/prompts.json, answers.json, transform.json

struct PromptPoint: Decodable, Sendable, Hashable {
    var pid: Int?
    var structural: Bool?
    var xyz: [Double]?
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
    var forward: [Double]?

    enum CodingKeys: String, CodingKey {
        case id, type, kind, rank, a, b, points, text, frame, context, forward
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

// MARK: measure/constraints.json — every way of measuring ends up here, points in the model's frame

struct DistanceConstraint: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var source: String              // prompt | viewer | snapshot
    var promptId: String?
    var a: [Double]
    var b: [Double]
    var meters: Double
    var note: String?
    var at: String?

    enum CodingKeys: String, CodingKey { case id, source, a, b, meters, note, at, promptId = "prompt_id" }

    var modelDistance: Double {
        guard a.count >= 3, b.count >= 3 else { return 0 }
        return ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])).squareRoot()
    }
}

struct LevelConstraint: Codable, Sendable, Hashable {
    var source: String
    var confirmed: Bool
    var points: [[Double]]
}

struct NorthConstraint: Codable, Sendable, Hashable {
    var source: String
    var frame: String?
    var forward: [Double]?
    var bearing: Double
}

struct Constraints: Codable, Sendable, Hashable {
    var distances: [DistanceConstraint] = []
    var skippedPrompts: [String] = []
    var level: LevelConstraint? = nil
    var north: NorthConstraint? = nil

    init() {}

    enum CodingKeys: String, CodingKey { case distances, level, north, skippedPrompts = "skipped_prompts" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distances = try c.decodeIfPresent([DistanceConstraint].self, forKey: .distances) ?? []
        skippedPrompts = try c.decodeIfPresent([String].self, forKey: .skippedPrompts) ?? []
        level = try c.decodeIfPresent(LevelConstraint.self, forKey: .level)
        north = try c.decodeIfPresent(NorthConstraint.self, forKey: .north)
    }

    func distance(forPrompt id: String) -> DistanceConstraint? { distances.first { $0.promptId == id } }
    func isSkipped(_ id: String) -> Bool { skippedPrompts.contains(id) }
}

/// overlay.json on a site plan: what the app draws over the orthomosaic, all in metres.
struct PlanOverlay: Decodable, Sendable, Hashable {
    struct Contour: Decodable, Sendable, Hashable { var level: Double; var index: Bool; var points: [[Double]] }
    struct Measurement: Decodable, Sendable, Hashable { var id: String; var source: String; var meters: Double; var a: [Double]; var b: [Double] }
    var pxPerM: Double
    var xMin: Double
    var yMax: Double
    var widthPx: Int
    var heightPx: Int
    var widthM: Double
    var heightM: Double
    var contourInterval: Double?
    var sheetScale: Int?
    var contours: [Contour]
    var footprint: [[[Double]]]
    var measurements: [Measurement]

    enum CodingKeys: String, CodingKey {
        case contours, footprint, measurements
        case pxPerM = "px_per_m", xMin = "x_min", yMax = "y_max", widthPx = "width_px", heightPx = "height_px"
        case widthM = "width_m", heightM = "height_m", contourInterval = "contour_interval", sheetScale = "sheet_scale"
    }
}

struct Residual: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var kind: String
    var source: String?
    var meters: Double
    var residualCm: Double

    enum CodingKeys: String, CodingKey { case id, kind, source, meters, residualCm = "residual_cm" }
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
