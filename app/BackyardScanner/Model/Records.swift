import Foundation

/// What the sidebar and detail views actually render: a manifest plus everything the app derives from the folder.

struct Artifact: Identifiable, Hashable, Sendable {
    let path: String
    let label: String
    let stage: String
    let size: Int
    let modified: Date
    var id: String { path }

    /// Same list as scanner/models.py ARTIFACTS.
    static let catalog: [(path: String, label: String, stage: String)] = [
        ("sparse_points.ply", "Sparse point cloud (COLMAP)", "sfm"),
        ("dense/scene_dense.ply", "Dense point cloud", "dense"),
        ("dense/scene_dense_mesh.ply", "Mesh, raw", "dense"),
        ("dense/scene_dense_mesh_clean.ply", "Mesh, cleaned + decimated", "dense"),
        ("dense/scene_dense_mesh_texture.obj", "Textured mesh (OBJ + MTL + JPG)", "dense"),
        ("preview_plan_grid.png", "Preview plan, unscaled, 1 m grid", "landmarks"),
        ("preview_plan.blend", "Preview Blender scene", "landmarks"),
        ("measure/prompts.json", "Measurement prompts", "landmarks"),
        ("plan_grid.png", "Site plan, true scale, 1 m grid", "plan"),
        ("plan.png", "Site plan, true scale, plain", "plan"),
        ("plan.blend", "Blender scene at true scale", "plan"),
        ("dense/scene_dense_metric.ply", "Dense cloud in metres", "plan"),
        ("transform.json", "Scale / level / north + residuals", "plan"),
    ]
}

struct RunRecord: Identifiable, Hashable, Sendable {
    var run: Run
    var dir: URL
    var artifacts: [Artifact]
    var thumbnail: URL?
    var prompts: PromptSet?
    var answers: [String: Answer]
    var transform: Transform?
    var alive: Bool

    var id: String { "\(run.scanId)/\(run.id)" }
    var isRunning: Bool { run.status == .running && alive }
    func url(_ relative: String) -> URL { dir.appending(path: relative) }
    func artifact(_ path: String) -> Artifact? { artifacts.first { $0.path == path } }
    var hasTexturedMesh: Bool { artifact("dense/scene_dense_mesh_texture.obj") != nil }
}

struct ScanRecord: Identifiable, Hashable, Sendable {
    var scan: Scan
    var dir: URL
    var runs: [RunRecord]
    var thumbnail: URL?

    var id: String { scan.id }
    var isBusy: Bool { scan.frames.status == .running || runs.contains { $0.isRunning } }
    func run(_ id: String) -> RunRecord? { runs.first { $0.run.id == id } }
}

struct VideoFile: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int
    let modified: Date
    let used: Bool
    var id: String { url.path }
}

struct Health: Hashable, Sendable {
    var colmap = false
    var openmvs = false
    var blender = false
    var python = false
}

enum Selection: Hashable, Sendable {
    case scan(String)
    case run(String, String)

    var scanId: String {
        switch self { case .scan(let s): s; case .run(let s, _): s }
    }
}
