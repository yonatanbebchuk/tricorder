import Foundation

/// Reads the manifests under work/environments and does the few small writes the UI needs.  Everything here is
/// synchronous and off the main actor; Workspace wraps it in detached tasks.
enum ManifestStore {
    static let stageLabels: [String: String] = [
        "frames": "Frames", "sfm": "COLMAP", "register": "Register", "dense": "OpenMVS", "landmarks": "Landmarks", "preview": "Preview",
        "solve": "Scale & level", "ortho": "Orthomosaic", "trace": "Linework", "draw": "Drawing",
    ]
    /// One line on what each stage does, for the pipeline view.
    static let stageBlurbs: [String: String] = [
        "frames": "the sharpest frame per window, HDR tone-mapped",
        "sfm": "features, matching, camera poses, sparse cloud",
        "register": "new frames posed into the model, full bundle adjustment",
        "dense": "dense cloud, mesh, cleanup, texture",
        "landmarks": "levelled preview plan, measurement prompts",
        "preview": "300k-face USDZ for the viewer",
        "solve": "measurements → scale, level, north; metric cloud",
        "ortho": "top-down render at true scale",
        "trace": "vertical surfaces → walls; dimensioned boundary",
        "draw": "DEM, contours, DXF, PDF sheet",
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "dng", "tif", "tiff"]

    static func environmentsDir(_ root: URL) -> URL { root.appending(path: "work/environments") }
    static func dataDir(_ root: URL) -> URL { root.appending(path: "data") }

    // MARK: reading

    static func loadAll(root: URL) -> [EnvironmentRecord] {
        let fm = FileManager.default
        let dir = environmentsDir(root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [EnvironmentRecord] = []
        for name in names {
            let edir = dir.appending(path: name)
            guard let env = try? decode(EnvironmentInfo.self, edir.appending(path: "environment.json")) else { continue }

            var recordings: [RecordingRecord] = []
            for r in children(of: edir.appending(path: "recordings")) {
                guard let rec = try? decode(Recording.self, r.appending(path: "recording.json")) else { continue }
                recordings.append(RecordingRecord(rec: rec, dir: r, thumbnail: rec.thumbnail.flatMap { existing(r.appending(path: $0)) }))
            }
            recordings.sort { number($0.rec.id) < number($1.rec.id) }

            var runs: [RunRecord] = []
            for r in children(of: edir.appending(path: "runs")) {
                guard var run = try? decode(Run.self, r.appending(path: "run.json")) else { continue }
                let alive = reconcile(&run, dir: r)
                runs.append(RunRecord(run: run, dir: r, alive: alive))
            }
            runs.sort { number($0.run.id) < number($1.run.id) }

            var assets: [AssetRecord] = []
            for a in children(of: edir.appending(path: "assets")) {
                guard let asset = try? decode(Asset.self, a.appending(path: "asset.json")) else { continue }
                assets.append(AssetRecord(
                    asset: asset, dir: a,
                    thumbnail: existing(a.appending(path: "thumb.jpg")),
                    preview: existing(a.appending(path: "preview.usdz")),
                    prompts: try? decode(PromptSet.self, a.appending(path: "measure/prompts.json")),
                    constraints: loadConstraints(a),
                    transform: try? decode(Transform.self, a.appending(path: "transform.json")),
                    overlay: try? decode(PlanOverlay.self, a.appending(path: "overlay.json"))))
            }
            assets.sort { $0.asset.createdAt < $1.asset.createdAt }

            out.append(EnvironmentRecord(env: env, dir: edir, recordings: recordings, runs: runs, assets: assets))
        }
        return out.sorted { $0.env.createdAt > $1.env.createdAt }
    }

    private static func children(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { dir.appending(path: $0) }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func existing(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }

    /// Trailing number of an id like r12 / rec3 / scan3d-2.
    static func number(_ id: String) -> Int {
        Int(String(id.reversed().prefix { $0.isNumber }.reversed())) ?? 0
    }

    static func loadConstraints(_ assetDir: URL) -> Constraints {
        (try? decode(Constraints.self, assetDir.appending(path: "measure/constraints.json"))) ?? Constraints()
    }

    /// Whether the run's process is still alive.  A run marked running whose process is gone is marked
    /// interrupted on disk so the next launch can resume it.
    static func reconcile(_ run: inout Run, dir: URL) -> Bool {
        guard run.status == .running else { return false }
        if let pid = run.pid, isAlive(pid) { return true }
        run.status = .interrupted
        run.pid = nil
        let stamp = Format.now()
        for k in run.stages.keys where run.stages[k]?.status == .running {
            run.stages[k]?.status = .interrupted
            run.stages[k]?.finishedAt = stamp
            run.stages[k]?.error = "process died"
        }
        try? patchJSON(at: dir.appending(path: "run.json")) { obj in
            obj["status"] = "interrupted"
            obj["pid"] = NSNull()
            if var stages = obj["stages"] as? [String: Any] {
                for (k, v) in stages {
                    if var st = v as? [String: Any], st["status"] as? String == "running" {
                        st["status"] = "interrupted"; st["finished_at"] = stamp; st["error"] = "process died"
                        stages[k] = st
                    }
                }
                obj["stages"] = stages
            }
        }
        return false
    }

    static func isAlive(_ pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Last `maxBytes` of a log, normalised so COLMAP's carriage-return progress lines read as lines.
    static func readTail(_ url: URL, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ("", false) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let truncated = size > UInt64(maxBytes)
        let start = truncated ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if truncated, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return (text, truncated)
    }

    // MARK: writing

    /// Read → mutate → atomic replace, keeping keys the app doesn't model.
    static func patchJSON(at url: URL, _ mutate: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PipelineError("\(url.lastPathComponent) is not a JSON object")
        }
        mutate(&obj)
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        let tmp = url.appendingPathExtension("tmp")
        try out.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Read → mutate → write the asset's measurements.
    static func updateConstraints(assetDir: URL, _ mutate: (inout Constraints) -> Void) throws {
        let file = assetDir.appending(path: "measure/constraints.json")
        var c = loadConstraints(assetDir)
        mutate(&c)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(c).write(to: file, options: .atomic)
    }

    /// Write a measurement recording's items and north bearing back into its manifest.
    static func saveMeasurements(recordingDir: URL, items: [MeasurementItem], north: MeasurementNorth?) throws {
        let enc = JSONEncoder()
        let itemsObj = try JSONSerialization.jsonObject(with: enc.encode(items))
        let northObj: Any = try north.map { try JSONSerialization.jsonObject(with: enc.encode($0)) } ?? NSNull()
        try patchJSON(at: recordingDir.appending(path: "recording.json")) { obj in
            obj["items"] = itemsObj
            obj["north"] = northObj
        }
    }

    /// The frames of a video recording, in walk order.
    static func frames(of recordingDir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: recordingDir.appending(path: "images").path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".jpg") }
            .sorted()
    }

    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
