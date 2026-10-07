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
    var outputs: [AssetFile] = []      // what the stage left behind (paths relative to the run dir)
    var preview: String?               // a small picture of the result, relative to the run dir

    init() {}

    enum CodingKeys: String, CodingKey {
        case status, metrics, error, log, outputs, preview
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
        outputs = try c.decodeIfPresent([AssetFile].self, forKey: .outputs) ?? []
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
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
    var count: Int?                    // photos recording: how many stills
    var model: String?                 // marks recording: the 3D model the marks were drawn on
    var frame: String?                 // marks recording: that model's coordinate frame
    var generated: Bool?               // marks recording: an inventory an identify run published
    var generatedBy: String?           // that run
    var metrics: [String: JSONValue]?  // its metrics

    enum CodingKeys: String, CodingKey {
        case path, original, size, width, height, fps, frames, hdr, error, count, model, frame, generated, metrics
        case durationS = "duration_s", colorTransfer = "color_transfer", generatedBy = "generated_by"
    }

    init() {}

    /// A measurements recording has an empty source: every field is optional here.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        original = try c.decodeIfPresent(String.self, forKey: .original)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        durationS = try c.decodeIfPresent(Double.self, forKey: .durationS)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps)
        frames = try c.decodeIfPresent(Int.self, forKey: .frames)
        colorTransfer = try c.decodeIfPresent(String.self, forKey: .colorTransfer)
        hdr = try c.decodeIfPresent(String.self, forKey: .hdr)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        count = try c.decodeIfPresent(Int.self, forKey: .count)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        generated = try c.decodeIfPresent(JSONValue.self, forKey: .generated)?.bool
        generatedBy = try c.decodeIfPresent(String.self, forKey: .generatedBy)
        metrics = try c.decodeIfPresent([String: JSONValue].self, forKey: .metrics)
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

/// One thing you taped on site: two pixels on a frame of a video recording, and the metres between them; or, with
/// source "mesh", two points clicked on a 3D model (in that model's own coordinate frame).
struct MeasurementItem: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var recording: String = ""     // the video recording the frame belongs to (pixel items)
    var frame: String = ""         // image file name, e.g. f002240.jpg (pixel items)
    var a: [Double] = []           // pixel (u, v) on the original frame
    var b: [Double] = []
    var meters: Double
    var note: String?
    var imageSize: [Int]?
    var at: String?
    var source: String?            // nil / "snapshot" for pixels, "mesh" for points on the model
    var model: String?             // mesh items: the 3D model asset the points were clicked on
    var a3d: [Double]?             // mesh items: the two points, model frame
    var b3d: [Double]?

    var isMesh: Bool { source == "mesh" }

    enum CodingKeys: String, CodingKey { case id, recording, frame, a, b, meters, note, at, source, model, a3d, b3d, imageSize = "image_size" }

    init(id: String, recording: String, frame: String, a: [Double], b: [Double], meters: Double, note: String? = nil, imageSize: [Int]? = nil, at: String? = nil) {
        self.id = id; self.recording = recording; self.frame = frame; self.a = a; self.b = b; self.meters = meters
        self.note = note; self.imageSize = imageSize; self.at = at
    }

    init(id: String, model: String, a3d: [Double], b3d: [Double], meters: Double, note: String? = nil, at: String? = nil) {
        self.id = id; self.meters = meters; self.note = note; self.at = at
        self.source = "mesh"; self.model = model; self.a3d = a3d; self.b3d = b3d
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        recording = try c.decodeIfPresent(String.self, forKey: .recording) ?? ""
        frame = try c.decodeIfPresent(String.self, forKey: .frame) ?? ""
        a = try c.decodeIfPresent([Double].self, forKey: .a) ?? []
        b = try c.decodeIfPresent([Double].self, forKey: .b) ?? []
        meters = try c.decodeIfPresent(Double.self, forKey: .meters) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note)
        imageSize = try c.decodeIfPresent([Int].self, forKey: .imageSize)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        a3d = try c.decodeIfPresent([Double].self, forKey: .a3d)
        b3d = try c.decodeIfPresent([Double].self, forKey: .b3d)
    }
}

/// One mark drawn on a 3D model: a point, line or polygon of 3D points in the model's frame, with a class.
/// role "element" says what is there (wall, fence, window, door, stairs, area, tree, bush, object); role "edit" says what
/// to change ("remove" an entity or a region, "patch" a region with a text prompt).
struct MarkItem: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var role: String = "element"
    var cls: String = "object"
    var shape: String = "polygon"   // point | line | polygon
    var points: [[Double]] = []
    var name: String?
    var note: String?
    var material: String?
    var text: String?
    var entity: String?             // the inventory entity this mark stands for (accepted or corrected), if any
    var source: String = "human"    // human | accepted
    var reject: Bool?               // an element mark that drops its entity from the plan
    var heightM: Double?
    var at: String?
    var confidence: Double?         // generated items: how sure the identify run was
    var areaM2: Double?             // generated items: approximate footprint
    var frames: Int?                // generated items: how many frames saw it
    var color: String?

    enum CodingKeys: String, CodingKey {
        case id, role, cls, shape, points, name, note, material, text, entity, source, reject, at, confidence, frames, color
        case heightM = "height_m", areaM2 = "area_m2"
    }

    init(id: String, role: String, cls: String, shape: String, points: [[Double]], name: String? = nil, note: String? = nil, material: String? = nil,
         text: String? = nil, entity: String? = nil, source: String = "human", reject: Bool? = nil, heightM: Double? = nil, at: String? = nil) {
        self.id = id; self.role = role; self.cls = cls; self.shape = shape; self.points = points; self.name = name; self.note = note
        self.material = material; self.text = text; self.entity = entity; self.source = source; self.reject = reject; self.heightM = heightM; self.at = at
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "element"
        cls = try c.decodeIfPresent(String.self, forKey: .cls) ?? "object"
        shape = try c.decodeIfPresent(String.self, forKey: .shape) ?? "polygon"
        points = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        name = try c.decodeIfPresent(String.self, forKey: .name)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        material = try c.decodeIfPresent(String.self, forKey: .material)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        entity = try c.decodeIfPresent(String.self, forKey: .entity)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "human"
        reject = try c.decodeIfPresent(Bool.self, forKey: .reject)
        heightM = try c.decodeIfPresent(Double.self, forKey: .heightM)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        areaM2 = try c.decodeIfPresent(Double.self, forKey: .areaM2)
        frames = try c.decodeIfPresent(Int.self, forKey: .frames)
        color = try c.decodeIfPresent(String.self, forKey: .color)
    }

    var isGenerated: Bool { source == "generated" }
    var displayName: String { name ?? cls }

    static let elementClasses = ["wall", "fence", "window", "door", "stairs", "area", "tree", "bush", "object"]
    static let editClasses = ["remove", "patch"]
    static let materials = ["grass", "brick", "concrete", "sand", "gravel", "deck", "garden", "soil", "tiles", "stone", "asphalt", "other"]
    var isEdit: Bool { role == "edit" }
}

struct MeasurementNorth: Codable, Sendable, Hashable {
    var recording: String
    var frame: String
    var bearing: Double
}

struct Recording: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var envId: String
    var name: String
    var createdAt: String
    var kind: String               // video | photos | measurements | marks
    var source: VideoInfo
    var frames: Stage
    var frameSettings: FrameSettings
    var notes: String
    var thumbnail: String?
    var items: [MeasurementItem]   // measurements
    var marks: [MarkItem]          // marks
    var north: MeasurementNorth?

    var isMeasurements: Bool { kind == "measurements" }
    var isMarks: Bool { kind == "marks" }
    /// An inventory: marks an identify run generated (every item stands for an entity).
    var isGenerated: Bool { isMarks && source.generated == true }
    var isPhotos: Bool { kind == "photos" }
    /// Footage: something with frames (a video or photos), as opposed to measurements or marks.
    var isFootage: Bool { !isMeasurements && !isMarks }
    var inputKind: InputKind { InputKind(rawValue: kind) ?? .video }
    /// Marks: the model they were drawn on, and its coordinate frame.
    var markModel: String? { source.model }
    var markFrame: String? { source.frame ?? source.model }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, source, frames, notes, thumbnail, items, north
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
        if kind == "marks" {
            items = []
            marks = try c.decodeIfPresent([MarkItem].self, forKey: .items) ?? []
        } else {
            items = try c.decodeIfPresent([MeasurementItem].self, forKey: .items) ?? []
            marks = []
        }
        north = try c.decodeIfPresent(MeasurementNorth.self, forKey: .north)
    }
}

// MARK: - run

/// What a run's input slot can hold: a recording kind or an asset kind (the raw values match the manifests).
enum InputKind: String, Sendable, Hashable, CaseIterable {
    case video, photos, measurements, marks, model3d, sitePlan = "site_plan"

    var label: String {
        switch self {
        case .video: "Video"; case .photos: "Photos"; case .measurements: "Measurements"; case .marks: "Marks"
        case .model3d: "3D Model"; case .sitePlan: "Site Plan"
        }
    }
    var symbol: String {
        switch self {
        case .video: "video"; case .photos: "photo.on.rectangle"; case .measurements: "ruler"; case .marks: "pencil.and.outline"
        case .model3d: "cube.transparent"; case .sitePlan: "map"
        }
    }
    var isAsset: Bool { self == .model3d || self == .sitePlan }
}

/// One input of a run kind: which key of `Run.inputs` it fills, what it accepts, how many.
struct InputSlot: Hashable, Sendable, Identifiable {
    let key: String
    let label: String
    let accepts: [InputKind]
    let min: Int
    let max: Int
    var id: String { key }
    var isRequired: Bool { min > 0 }
    var isSingle: Bool { max == 1 }
    func accepts(_ k: InputKind) -> Bool { accepts.contains(k) }
}

/// Mirrors RUN_KINDS in tricorder/models.py: a recipe with input slots, stages and one output asset kind.
enum RunKind: String, Decodable, Sendable, Hashable, CaseIterable {
    case scan, extend, identify, layout, edit

    var label: String {
        switch self { case .scan: "Environment scan"; case .extend: "Extend scan"; case .identify: "Identify"; case .layout: "Layout"; case .edit: "Edit" }
    }
    var verb: String {
        switch self { case .scan: "Scan"; case .extend: "Extend"; case .identify: "Identify"; case .layout: "Lay out"; case .edit: "Edit" }
    }
    var blurb: String {
        switch self {
        case .scan: "A filmed walk becomes a textured 3D model: COLMAP poses, OpenMVS dense cloud, mesh, texture."
        case .extend: "New videos or photos are registered into an existing model's cameras; everything is re-optimised and re-meshed."
        case .identify: "What is where: every region of the frames is segmented, named by a vision-language model, lifted onto the mesh and clustered into named entities with footprints. Publishes a generated marks recording, the inventory."
        case .layout: "A 3D model plus tape measurements becomes a site plan: true scale, orthomosaic, wall lines, DXF and PDF. Marks, yours and the generated inventory, put every named element on the plan."
        case .edit: "Remove marked entities or regions from the model and complete the ground where they stood; patch marked holes. A new 3D model in the same frame."
        }
    }
    var symbol: String {
        switch self { case .scan: "cube.transparent"; case .extend: "plus.viewfinder"; case .identify: "tag"; case .layout: "map"; case .edit: "scissors" }
    }
    /// What the run consumes: an asset of this kind (extend, identify, layout, edit), or nothing but recordings.
    var inputAssetKind: AssetKind? { self == .scan ? nil : .model3d }
    /// The asset a run publishes; identify publishes a recording instead (a generated marks recording).
    var outputKind: AssetKind? {
        switch self { case .scan, .extend, .edit: .model3d; case .identify: nil; case .layout: .sitePlan }
    }
    /// What the run's output is, as something a later run's slot can take.
    var outputInputKind: InputKind { outputKind?.inputKind ?? .marks }
    var outputLabel: String { outputKind?.label ?? "Inventory" }
    var outputSymbol: String { outputKind?.symbol ?? "tag" }
    var stages: [String] {
        switch self {
        case .scan: ["sfm", "dense", "landmarks", "preview"]
        case .extend: ["register", "dense", "landmarks", "preview"]
        case .identify: ["segment", "name", "lift", "entities", "review", "preview"]
        case .layout: ["solve", "ortho", "trace", "annotate", "draw", "preview"]
        case .edit: ["select", "cut", "complete", "preview"]
        }
    }
    var slots: [InputSlot] {
        switch self {
        case .scan: [InputSlot(key: "recording", label: "Video", accepts: [.video], min: 1, max: 1)]
        case .extend: [InputSlot(key: "asset", label: "3D model", accepts: [.model3d], min: 1, max: 1),
                       InputSlot(key: "recordings", label: "New footage", accepts: [.video, .photos], min: 1, max: 8)]
        case .identify: [InputSlot(key: "asset", label: "3D model", accepts: [.model3d], min: 1, max: 1),
                         InputSlot(key: "prior", label: "Prior inventory", accepts: [.marks], min: 0, max: 1)]
        case .layout: [InputSlot(key: "asset", label: "3D model", accepts: [.model3d], min: 1, max: 1),
                       InputSlot(key: "recordings", label: "Measurements", accepts: [.measurements], min: 0, max: 8),
                       InputSlot(key: "marks", label: "Marks", accepts: [.marks], min: 0, max: 12)]
        case .edit: [InputSlot(key: "asset", label: "3D model", accepts: [.model3d], min: 1, max: 1),
                     InputSlot(key: "marks", label: "Marks", accepts: [.marks], min: 1, max: 12)]
        }
    }
    /// Rough stage durations for the progress bar when the environment has no history yet (seconds).
    static let typicalSeconds: [String: Double] = [
        "frames": 120, "sfm": 1800, "register": 900, "dense": 7200, "landmarks": 120, "preview": 30,
        "solve": 25, "ortho": 6, "trace": 10, "annotate": 4, "draw": 12,
        "segment": 600, "name": 1500, "lift": 60, "entities": 40, "review": 400,
        "select": 30, "cut": 240, "complete": 300,
    ]
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
    var wallJumpM: Double = 0.5
    var edgeJumpM: Double = 0.08
    var minEdgeM: Double = 1.2
    var previewFaces: Int = 300_000
    var vlm: String = "qwen-local"         // identify: qwen-local | claude | none
    var sam: String = "facebook/sam-vit-base"
    var every: Int = 10
    var framesCap: Int = 60
    var review: Int = 1
    var boundary: String = "walls"         // layout: walls | footprint

    init() {}

    enum CodingKeys: String, CodingKey {
        case features, matcher, matching, relaxed, measures, vlm, sam, every, review, boundary
        case resLevel = "res_level", maxFaces = "max_faces", pxPerM = "px_per_m", contourM = "contour_m", sheetScale = "sheet_scale"
        case wallJumpM = "wall_jump_m", edgeJumpM = "edge_jump_m", minEdgeM = "min_edge_m", previewFaces = "preview_faces", framesCap = "frames_cap"
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
        wallJumpM = try c.decodeIfPresent(Double.self, forKey: .wallJumpM) ?? 0.5
        edgeJumpM = try c.decodeIfPresent(Double.self, forKey: .edgeJumpM) ?? 0.08
        minEdgeM = try c.decodeIfPresent(Double.self, forKey: .minEdgeM) ?? 1.2
        previewFaces = try c.decodeIfPresent(Int.self, forKey: .previewFaces) ?? 300_000
        vlm = try c.decodeIfPresent(String.self, forKey: .vlm) ?? "qwen-local"
        sam = try c.decodeIfPresent(String.self, forKey: .sam) ?? "facebook/sam-vit-base"
        every = try c.decodeIfPresent(Int.self, forKey: .every) ?? 10
        framesCap = try c.decodeIfPresent(Int.self, forKey: .framesCap) ?? 60
        review = try c.decodeIfPresent(Int.self, forKey: .review) ?? 1
        boundary = try c.decodeIfPresent(String.self, forKey: .boundary) ?? "walls"
    }
}

struct Run: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var envId: String
    var kind: RunKind
    var inputs: [String: JSONValue]
    var createdAt: String
    var settings: RunSettings
    var status: Status
    var pid: Int?
    var startedAt: String?
    var finishedAt: String?
    var stages: [String: Stage]
    var outputAsset: String?
    var label: String
    var after: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, inputs, settings, status, pid, stages, label, after
        case envId = "env_id", createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at"
        case outputAsset = "output_asset"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        envId = try c.decodeIfPresent(String.self, forKey: .envId) ?? ""
        kind = try c.decode(RunKind.self, forKey: .kind)
        inputs = try c.decodeIfPresent([String: JSONValue].self, forKey: .inputs) ?? [:]
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
        after = try c.decodeIfPresent(String.self, forKey: .after)
    }

    func stage(_ key: String) -> Stage { stages[key] ?? Stage() }
    var inputRecordingId: String? { inputs["recording"]?.string }
    /// The 3D model this run consumes; nil while it still names another run's output ("@r5").
    var inputAssetId: String? { inputs["asset"]?.string.flatMap { $0.hasPrefix("@") ? nil : $0 } }
    /// Every asset this run consumes, by slot key, resolved ones only.
    var inputAssetIds: [String: String] {
        var out: [String: String] = [:]
        for slot in kind.slots where slot.accepts.contains(where: \.isAsset) {
            if let v = inputs[slot.key]?.string, !v.hasPrefix("@") { out[slot.key] = v }
        }
        return out
    }
    /// The runs whose outputs this run waits for (a chained run): every "@r5" in an asset slot, plus `after`.
    var waitsForAll: [String] {
        var ids: [String] = []
        for slot in kind.slots where slot.accepts.contains(where: \.isAsset) {
            if let v = inputs[slot.key]?.string, v.hasPrefix("@") { let id = String(v.dropFirst()); if !ids.contains(id) { ids.append(id) } }
        }
        if let after, !ids.contains(after) { ids.append(after) }
        return ids
    }
    /// The first run this run waits for, if any.
    var waitsFor: String? { waitsForAll.first }
    var isQueued: Bool { status == .queued }
    /// Every recording this run consumed: the video of a scan, the measurement and marks recordings of a layout,
    /// the prior inventory of an identify (chained "@run" references excluded).
    var inputRecordingIds: [String] {
        var ids: [String] = []
        if let r = inputRecordingId { ids.append(r) }
        for key in ["recordings", "marks"] {
            if case .array(let a)? = inputs[key] { ids += a.compactMap(\.string).filter { !$0.hasPrefix("@") } }
        }
        if let p = inputs["prior"]?.string, !p.hasPrefix("@") { ids.append(p) }
        return ids
    }
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
    var inputKind: InputKind {
        switch self { case .model3d: .model3d; case .sitePlan: .sitePlan }
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
    var derivedFrom: String?
    var sources: [[String: JSONValue]]
    var frame: String?                 // the model whose coordinate frame this asset shares
    var removedEntities: [String]

    enum CodingKeys: String, CodingKey {
        case id, kind, name, files, metrics, notes, sources, frame
        case envId = "env_id", runId = "run_id", createdAt = "created_at", derivedFrom = "derived_from", removedEntities = "removed_entities"
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
        derivedFrom = try c.decodeIfPresent(String.self, forKey: .derivedFrom)
        sources = try c.decodeIfPresent([[String: JSONValue]].self, forKey: .sources) ?? []
        frame = try c.decodeIfPresent(String.self, forKey: .frame)
        removedEntities = try c.decodeIfPresent([String].self, forKey: .removedEntities) ?? []
    }
    /// The coordinate frame of a model (itself for a scan or extend, the parent's for an edit).
    var frameId: String { frame ?? id }
}

// MARK: - elements on a plan

/// A named element on a site plan (overlay.json / elements.json), in plan metres.
struct PlanElement: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var cls: String
    var name: String
    var material: String?
    var shape: String
    var points: [[Double]]
    var z: [Double]?
    var lengthM: Double?
    var areaM2: Double?
    var heightM: Double?
    var source: String
    var entity: String?
    var confidence: Double?
    var color: String?
    var description: String?
    var note: String?
    var minor: Bool?                   // a small or unsure generated entity: listed, not drawn large

    enum CodingKeys: String, CodingKey {
        case id, cls, name, material, shape, points, z, source, entity, confidence, color, description, note, minor
        case lengthM = "length_m", areaM2 = "area_m2", heightM = "height_m"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        cls = try c.decodeIfPresent(String.self, forKey: .cls) ?? "object"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? cls
        material = try c.decodeIfPresent(String.self, forKey: .material)
        shape = try c.decodeIfPresent(String.self, forKey: .shape) ?? "polygon"
        points = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        z = try c.decodeIfPresent([Double].self, forKey: .z)
        lengthM = try c.decodeIfPresent(Double.self, forKey: .lengthM)
        areaM2 = try c.decodeIfPresent(Double.self, forKey: .areaM2)
        heightM = try c.decodeIfPresent(Double.self, forKey: .heightM)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "inventory"
        entity = try c.decodeIfPresent(String.self, forKey: .entity)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        minor = try c.decodeIfPresent(Bool.self, forKey: .minor)
    }
}

/// transform_preview.json / transform.json: only the matrix matters to the viewer (model frame → levelled frame).
struct LevelTransform: Decodable, Sendable, Hashable {
    var matrix: [[Double]]
    var scale: Double?
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
    struct Polygon: Decodable, Sendable, Hashable { var points: [[Double]]; var lengths: [Double]; var area: Double }
    struct Edge: Decodable, Sendable, Hashable { var a: [Double]; var b: [Double]; var cls: String; var length: Double }
    struct Opening: Decodable, Sendable, Hashable, Identifiable {
        var cls: String; var name: String; var edge: Int; var a: [Double]; var b: [Double]; var width: Double; var swing: Int
        var id: String { "\(cls)-\(edge)-\(a)" }
    }
    /// A traced boundary with its edges classified (wall / fence / unknown) and the openings snapped onto it.
    struct Boundary: Decodable, Sendable, Hashable {
        var points: [[Double]]; var lengths: [Double]; var area: Double; var edges: [Edge]; var openings: [Opening]
        var edgeClasses: [String: Double]
        enum CodingKeys: String, CodingKey { case points, lengths, area, edges, openings, edgeClasses = "edge_classes" }
    }
    struct PolyPart: Decodable, Sendable, Hashable { var exterior: [[Double]]; var holes: [[[Double]]] }
    struct LandUse: Decodable, Sendable, Hashable, Identifiable {
        var material: String; var name: String; var source: String; var element: String?; var color: String?; var areaM2: Double; var polygons: [PolyPart]
        var id: String { "\(material)-\(element ?? name)" }
        enum CodingKeys: String, CodingKey { case material, name, source, element, color, polygons, areaM2 = "area_m2" }
    }
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
    var walls: [[[Double]]]?
    var edges: [[[Double]]]?
    var polygons: [Polygon]?
    var axisDeg: Double?
    var alignDeg: Double?
    var elements: [PlanElement]?
    var quantities: [String: JSONValue]?
    var boundarySource: String?
    var boundaries: [String: Boundary]?
    var landuse: [LandUse]?
    var wallsAll: [[[Double]]]?

    /// The boundary the drawing is built on (walls first, else the footprint).
    func boundary(_ source: String?) -> Boundary? {
        guard let b = boundaries, !b.isEmpty else { return nil }
        return b[source ?? boundarySource ?? "walls"] ?? b[boundarySource ?? "walls"] ?? b.values.first
    }

    enum CodingKeys: String, CodingKey {
        case contours, footprint, measurements, walls, edges, polygons, elements, quantities, boundaries, landuse
        case axisDeg = "axis_deg", alignDeg = "align_deg", boundarySource = "boundary_source", wallsAll = "walls_all"
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
    var estimated: Bool?
    var spreadPct: Double?
    var residuals: [Residual] = []

    enum CodingKeys: String, CodingKey { case scale, ground, north, warning, estimated, residuals, spreadPct = "spread_pct" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = try c.decode(Double.self, forKey: .scale)
        ground = try c.decodeIfPresent(JSONValue.self, forKey: .ground)
        north = try c.decodeIfPresent(JSONValue.self, forKey: .north)
        warning = try c.decodeIfPresent(JSONValue.self, forKey: .warning)?.bool
        estimated = try c.decodeIfPresent(JSONValue.self, forKey: .estimated)?.bool
        spreadPct = try c.decodeIfPresent(Double.self, forKey: .spreadPct)
        residuals = try c.decodeIfPresent([Residual].self, forKey: .residuals) ?? []
    }
}
