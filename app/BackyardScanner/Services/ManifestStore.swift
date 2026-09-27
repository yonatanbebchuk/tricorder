import Foundation

/// Reads the manifests under work/scans and does the few small writes the UI needs.  Everything here is synchronous
/// and off the main actor; Workspace wraps it in detached tasks.
enum ManifestStore {
    static let stageOrder = ["frames", "sfm", "dense", "landmarks", "plan"]
    static let stageLabels: [String: String] = [
        "frames": "1 · Frames", "sfm": "2 · COLMAP", "dense": "3 · OpenMVS", "landmarks": "4 · Landmarks", "plan": "5 · Plan",
    ]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi"]

    static func scansDir(_ root: URL) -> URL { root.appending(path: "work/scans") }
    static func dataDir(_ root: URL) -> URL { root.appending(path: "data") }

    // MARK: reading

    static func loadAll(root: URL) -> [ScanRecord] {
        let fm = FileManager.default
        let dir = scansDir(root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [ScanRecord] = []
        for name in names {
            let sdir = dir.appending(path: name)
            guard let scan = try? decode(Scan.self, sdir.appending(path: "scan.json")) else { continue }
            let runsDir = sdir.appending(path: "runs")
            var runs: [RunRecord] = []
            for rname in (try? fm.contentsOfDirectory(atPath: runsDir.path)) ?? [] {
                let rdir = runsDir.appending(path: rname)
                guard var run = try? decode(Run.self, rdir.appending(path: "run.json")) else { continue }
                let alive = reconcile(&run, dir: rdir)
                runs.append(RunRecord(
                    run: run, dir: rdir, artifacts: artifacts(in: rdir),
                    thumbnail: existing(rdir.appending(path: "thumb.jpg")),
                    prompts: try? decode(PromptSet.self, rdir.appending(path: "measure/prompts.json")),
                    answers: loadAnswers(rdir),
                    transform: try? decode(Transform.self, rdir.appending(path: "transform.json")),
                    alive: alive))
            }
            runs.sort { runNumber($0.run.id) < runNumber($1.run.id) }
            out.append(ScanRecord(scan: scan, dir: sdir, runs: runs,
                                  thumbnail: scan.thumbnail.flatMap { existing(sdir.appending(path: $0)) }))
        }
        return out.sorted { $0.scan.createdAt > $1.scan.createdAt }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    static func existing(_ url: URL) -> URL? { FileManager.default.fileExists(atPath: url.path) ? url : nil }

    static func runNumber(_ id: String) -> Int { Int(id.dropFirst()) ?? 0 }

    static func artifacts(in dir: URL) -> [Artifact] {
        let fm = FileManager.default
        return Artifact.catalog.compactMap { item in
            let p = dir.appending(path: item.path)
            guard let attrs = try? fm.attributesOfItem(atPath: p.path) else { return nil }
            return Artifact(path: item.path, label: item.label, stage: item.stage,
                            size: (attrs[.size] as? Int) ?? 0, modified: (attrs[.modificationDate] as? Date) ?? .distantPast)
        }
    }

    static func loadAnswers(_ runDir: URL) -> [String: Answer] {
        (try? decode([String: Answer].self, runDir.appending(path: "measure/answers.json"))) ?? [:]
    }

    /// Whether the run's process is still alive.  A run marked running whose process is gone is marked
    /// interrupted on disk, exactly like the web server's reconcile step did.
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

    static func saveAnswer(runDir: URL, promptId: String, answer: Answer?) throws {
        let file = runDir.appending(path: "measure/answers.json")
        var all = loadAnswers(runDir)
        if var a = answer, !a.isEmpty {
            a.at = Format.now()
            all[promptId] = a
        } else {
            all.removeValue(forKey: promptId)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: file, options: .atomic)
    }

    static func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
