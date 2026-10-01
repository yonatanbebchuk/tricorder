import Foundation

/// What the views render: a manifest plus everything the app derives from its folder.

struct RecordingRecord: Identifiable, Hashable, Sendable {
    var rec: Recording
    var dir: URL
    var thumbnail: URL?

    var id: String { "\(rec.envId)/\(rec.id)" }
    var isBusy: Bool { rec.frames.status == .running }
    var isMeasurements: Bool { rec.isMeasurements }
    var imagesDir: URL { dir.appending(path: "images") }
}

struct RunRecord: Identifiable, Hashable, Sendable {
    var run: Run
    var dir: URL
    var alive: Bool

    var id: String { "\(run.envId)/\(run.id)" }
    var isRunning: Bool { run.status == .running && alive }
    func previewURL(_ stage: String) -> URL? {
        guard let p = run.stage(stage).preview else { return nil }
        let u = dir.appending(path: p)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

struct AssetRecord: Identifiable, Hashable, Sendable {
    var asset: Asset
    var dir: URL
    var thumbnail: URL?
    var preview: URL?              // preview.usdz for the 3D viewer
    var prompts: PromptSet?        // 3D model: what to tape-measure
    var constraints: Constraints   // 3D model: the measurements entered so far
    var transform: Transform?      // site plan: scale / level / north
    var overlay: PlanOverlay?      // site plan: contours, footprint, measurements over the orthomosaic

    var id: String { "\(asset.envId)/\(asset.id)" }
    func url(_ relative: String) -> URL { dir.appending(path: relative) }
    func has(_ path: String) -> Bool { asset.files.contains { $0.path == path } }
    /// The best top-down picture of this asset.
    var planImage: URL? {
        if has("orthomosaic.png") { return url("orthomosaic.png") }
        if has("preview_plan_grid.png") { return url("preview_plan_grid.png") }
        return nil
    }
    var hasTexturedMesh: Bool { has("dense/scene_dense_mesh_texture.obj") }
}

struct EnvironmentRecord: Identifiable, Hashable, Sendable {
    var env: EnvironmentInfo
    var dir: URL
    var recordings: [RecordingRecord]
    var runs: [RunRecord]
    var assets: [AssetRecord]

    var id: String { env.id }
    var isBusy: Bool { recordings.contains { $0.isBusy } || runs.contains { $0.isRunning } }

    func recording(_ id: String) -> RecordingRecord? { recordings.first { $0.rec.id == id } }
    func run(_ id: String) -> RunRecord? { runs.first { $0.run.id == id } }
    func asset(_ id: String) -> AssetRecord? { assets.first { $0.asset.id == id } }

    /// The newest asset of each kind: what the environment currently *is*.
    var currentAssets: [AssetRecord] {
        AssetKind.allCases.compactMap { kind in assets.filter { $0.asset.kind == kind }.max(by: Self.older) }
    }
    var historicalAssets: [AssetRecord] {
        let current = Set(currentAssets.map(\.id))
        return assets.filter { !current.contains($0.id) }.sorted { Self.older($1, $0) }
    }
    /// Newest wins; equal timestamps (migrated data) fall back to the id number.
    static func older(_ a: AssetRecord, _ b: AssetRecord) -> Bool {
        a.asset.createdAt != b.asset.createdAt ? a.asset.createdAt < b.asset.createdAt
            : ManifestStore.number(a.asset.id) < ManifestStore.number(b.asset.id)
    }
    /// Picture for the sidebar and home cards: the current plan, else the current scan, else a recording frame.
    var thumbnail: URL? {
        currentAssets.first { $0.asset.kind == .sitePlan }?.thumbnail
            ?? currentAssets.first?.thumbnail
            ?? recordings.first?.thumbnail
    }
    func runsUsing(recording id: String) -> [RunRecord] { runs.filter { $0.run.inputRecordingIds.contains(id) } }
    var videoRecordings: [RecordingRecord] { recordings.filter { $0.rec.kind == "video" } }
    var photoRecordings: [RecordingRecord] { recordings.filter { $0.rec.isPhotos } }
    var footageRecordings: [RecordingRecord] { recordings.filter { $0.rec.isFootage } }
    var measurementRecordings: [RecordingRecord] { recordings.filter { $0.isMeasurements } }
    var models: [AssetRecord] { assets.filter { $0.asset.kind == .model3d } }
    func runsUsing(asset id: String) -> [RunRecord] { runs.filter { $0.run.inputAssetId == id } }
    /// Chained runs that wait for this run's output.
    func runsWaiting(on runId: String) -> [RunRecord] { runs.filter { $0.run.waitsFor == runId } }
    /// The asset (if any) a run consumed, for labels and links.
    func inputName(of run: Run) -> String {
        if let r = run.inputRecordingId { return recording(r)?.rec.name ?? r }
        if let w = run.waitsFor, run.inputAssetId == nil { return "the model from run \(w)" }
        if let a = run.inputAssetId {
            let base = asset(a)?.asset.name ?? a
            let m = run.inputRecordingIds
            if run.kind == .extend { return base + " + \(m.count) new recording\(m.count == 1 ? "" : "s")" }
            return m.isEmpty ? base + " (scale estimated)" : base + " + \(m.count) measurement\(m.count == 1 ? "" : "s")"
        }
        return "–"
    }
    /// Median duration of a stage over this environment's finished runs, for progress estimates.
    func typicalDuration(of stage: String, kind: RunKind) -> Double? {
        var d: [Double] = []
        if stage == "frames" { d = recordings.compactMap { $0.rec.frames.status == .done ? $0.rec.frames.duration : nil } }
        else { d = runs.filter { $0.run.kind == kind }.compactMap { r in let s = r.run.stage(stage); return s.status == .done ? s.duration : nil } }
        guard !d.isEmpty else { return nil }
        let s = d.sorted()
        return s[s.count / 2]
    }
}

struct VideoFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int
    let modified: Date
    var id: String { url.path }
}

struct Health: Hashable, Sendable {
    var colmap = false
    var openmvs = false
    var blender = false
    var python = false
}

/// Sidebar selection: an environment, or one of its three collections.
enum Selection: Hashable, Sendable {
    case environment(String)
    case recordings(String)
    case runs(String)
    case assets(String)

    var envId: String {
        switch self {
        case .environment(let e), .recordings(let e), .runs(let e), .assets(let e): e
        }
    }
}

/// Pushed detail pages inside the selected environment.
enum Route: Hashable, Sendable {
    case recording(String, String)
    case run(String, String)
    case asset(String, String)
}

/// Sheet requests carrying their context.
struct EnvRef: Identifiable, Hashable, Sendable {
    let id: String
}

struct NewRunRequest: Identifiable, Hashable, Sendable {
    let envId: String
    var kind: RunKind = .scan
    var inputId: String? = nil
    var id: String { "\(envId)/\(kind.rawValue)/\(inputId ?? "")" }
}

/// A draggable input for the run builder: "video:rec1", "model3d:model3d-1" …
struct InputRef: Hashable, Sendable, Identifiable {
    let kind: InputKind
    let id: String
    var token: String { "\(kind.rawValue):\(id)" }
    init(kind: InputKind, id: String) { self.kind = kind; self.id = id }
    init?(token: String) {
        guard let i = token.firstIndex(of: ":"), let k = InputKind(rawValue: String(token[..<i])) else { return nil }
        kind = k; id = String(token[token.index(after: i)...])
    }
}
