import Foundation

/// What the views render: a manifest plus everything the app derives from its folder.

struct RecordingRecord: Identifiable, Hashable, Sendable {
    var rec: Recording
    var dir: URL
    var thumbnail: URL?

    var id: String { "\(rec.envId)/\(rec.id)" }
    var isBusy: Bool { rec.frames.status == .running }
    var isMeasurements: Bool { rec.isMeasurements }
    var isMarks: Bool { rec.isMarks }
    var isGenerated: Bool { rec.isGenerated }
    var imagesDir: URL { dir.appending(path: "images") }
    /// A generated inventory's labelled map.
    var mapImage: URL? { ManifestStore.existing(dir.appending(path: "inventory_map.png")) }
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
    var levelled: [[Double]]?      // 3D model / site plan: the matrix the preview USDZ was exported with (model → levelled)

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
    var isModel: Bool { asset.kind == .model3d }
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
    var marksRecordings: [RecordingRecord] { recordings.filter { $0.isMarks } }
    /// Marks drawn on a model's coordinate frame (an edit keeps its parent's frame, so its marks still apply).
    func marksRecordings(for model: AssetRecord) -> [RecordingRecord] {
        marksRecordings.filter { $0.rec.markFrame == model.asset.frameId || $0.rec.markModel == model.asset.id }
    }
    /// A person's marks on a model's frame (not the generated inventories).
    func humanMarks(for model: AssetRecord) -> [RecordingRecord] { marksRecordings(for: model).filter { !$0.isGenerated } }
    var models: [AssetRecord] { assets.filter { $0.asset.kind == .model3d } }
    /// Generated inventories, newest last.
    var inventories: [RecordingRecord] { marksRecordings.filter(\.isGenerated) }
    /// The newest inventory made on a model's frame.
    func inventory(for model: AssetRecord) -> RecordingRecord? {
        inventories.filter { $0.rec.markFrame == model.asset.frameId || $0.rec.markModel == model.asset.id }
            .max { ManifestStore.number($0.rec.id) < ManifestStore.number($1.rec.id) }
    }
    /// The entities the newest inventory proposes on a model.
    func proposals(for model: AssetRecord) -> [MarkItem] { inventory(for: model)?.rec.marks ?? [] }
    func runsUsing(asset id: String) -> [RunRecord] { runs.filter { $0.run.inputAssetIds.values.contains(id) } }

    // MARK: dependencies between recordings and assets

    /// What else goes when a recording goes: measurement recordings marked on a video's frames.
    func dependents(ofRecording id: String) -> (recordings: [RecordingRecord], assets: [AssetRecord]) {
        guard let r = recording(id) else { return ([], []) }
        var recs: [RecordingRecord] = []
        if r.rec.isFootage {
            recs = measurementRecordings.filter { m in m.rec.items.contains { !$0.isMesh && $0.recording == id } }
        }
        return (recs, [])
    }

    /// What else goes when an asset goes: marks and inventories drawn on a model, measurements clicked on its mesh,
    /// and models edited out of it (same frame), recursively.
    func dependents(ofAsset id: String) -> (recordings: [RecordingRecord], assets: [AssetRecord]) {
        guard let a = asset(id) else { return ([], []) }
        var recs: [RecordingRecord] = []
        var more: [AssetRecord] = []
        if a.asset.kind == .model3d {
            recs += marksRecordings.filter { $0.rec.markModel == id || $0.rec.markFrame == id }
            recs += measurementRecordings.filter { m in m.rec.items.contains { $0.isMesh && $0.model == id } }
            more += assets.filter { $0.asset.kind == .model3d && $0.asset.derivedFrom == id }
        }
        var allRecs = recs
        var allAssets = more
        for m in more {
            let d = dependents(ofAsset: m.asset.id)
            allRecs += d.recordings.filter { r in !allRecs.contains { $0.id == r.id } }
            allAssets += d.assets.filter { x in !allAssets.contains { $0.id == x.id } }
        }
        return (allRecs, allAssets)
    }
    /// Chained runs that wait for this run's output.
    func runsWaiting(on runId: String) -> [RunRecord] { runs.filter { $0.run.waitsForAll.contains(runId) } }
    /// The asset (if any) a run consumed, for labels and links.
    func inputName(of run: Run) -> String {
        if let r = run.inputRecordingId { return recording(r)?.rec.name ?? r }
        if let w = run.waitsFor, run.inputAssetId == nil { return "the model from run \(w)" }
        if let a = run.inputAssetId {
            let base = asset(a)?.asset.name ?? a
            let m = run.inputRecordingIds
            switch run.kind {
            case .extend: return base + " + \(m.count) new recording\(m.count == 1 ? "" : "s")"
            case .identify: return base + (run.inputs["prior"]?.string.map { " + prior \(recording($0)?.rec.name ?? $0)" } ?? "")
            case .edit: return base + " + \(m.count) marks recording\(m.count == 1 ? "" : "s")"
            case .layout:
                var parts = [base]
                let meas = m.filter { recording($0)?.isMeasurements ?? false }.count
                let marks = m.filter { recording($0)?.isMarks ?? false }
                parts.append(meas == 0 ? "scale estimated" : "\(meas) measurement\(meas == 1 ? "" : "s")")
                let human = marks.filter { !(recording($0)?.isGenerated ?? false) }.count
                if human > 0 { parts.append("\(human) marks") }
                if marks.count > human { parts.append("inventory") }
                return parts.joined(separator: " + ")
            case .scan: return base
            }
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
    var remote = false          // already in the compute Mac's data/ inbox (url is a path there)
    var id: String { url.path }
}

struct Health: Hashable, Sendable {
    var colmap = false
    var openmvs = false
    var blender = false
    var python = false
    var reachable = true        // false: the remote host did not answer
    var revision = ""           // the checkout's git revision
    var protocolVersion = 0     // the pipeline's PROTOCOL; the app needs Pipeline.protocolVersion
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
    case editor(String, String, String?)   // the full-view mesh editor on a 3D model asset, optionally into a given marks recording
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
