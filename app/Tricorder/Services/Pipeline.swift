import Foundation

/// One run of a recipe: its kind, the ids in each input slot, settings; `refs` names the recipe steps whose outputs fill
/// the remaining asset slots (resolved to "@<run id>" when the chain is created), `after` chains it onto another run.
struct RunStep: Sendable, Hashable {
    var kind: RunKind
    var inputs: [String: [String]]
    var settings: RunSettings
    var label: String
    var refs: [String: Int] = [:]
    var after: String? = nil
}

struct PipelineError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Talks to tricorder/pipeline.py: creating environments, recordings and runs, launching detached executions,
/// cancelling.  The Python side stays the single owner of the manifests; the app never writes run status itself
/// (it marks a dead local run interrupted, which the pipeline's own `reconcile` does on a remote Mac).
///
/// Every call takes a `Target`: the local checkout (the command runs through its .venv), or a remote host (the same
/// command over SSH in that Mac's checkout; videos are uploaded first).
enum Pipeline {
    struct Target: Sendable, Hashable {
        let root: URL               // the checkout, or the remote host's mirror
        let remote: RemoteHost?
        init(_ c: Compute) { root = c.root; remote = c.remote }
    }

    /// The pipeline PROTOCOL this app was written against; a remote checkout reporting less needs a `git pull`.
    static let protocolVersion = 2

    static let blender = URL(filePath: ProcessInfo.processInfo.environment["BLENDER"] ?? "/Applications/Blender.app/Contents/MacOS/Blender")

    static func python(_ root: URL) -> URL { root.appending(path: ".venv/bin/python") }

    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + current.filter { !extra.contains($0) }).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// `python -m tricorder.pipeline <args>`, here or over SSH, returning stdout+stderr; throws with the last lines on failure.
    static func run(_ t: Target, _ args: [String]) async throws -> String {
        if let h = t.remote { return try await Remote.pipeline(h, args) }
        return try await Remote.exec(python(t.root).path, ["-m", "tricorder.pipeline"] + args)
    }

    private static func settingsArgs(_ s: RunSettings, label: String) -> [String] {
        ["--res-level", "\(s.resLevel)", "--features", s.features, "--matcher", s.matcher, "--matching", s.matching,
         "--measures", "\(s.measures)", "--max-faces", "\(s.maxFaces)", "--px-per-m", "\(s.pxPerM)", "--contour", "\(s.contourM)", "--sheet-scale", "\(s.sheetScale)", "--wall", "\(s.wallJumpM)", "--edge", "\(s.edgeJumpM)", "--min-edge", "\(s.minEdgeM)",
         "--preview-faces", "\(s.previewFaces)", "--vlm", s.vlm, "--sam", s.sam, "--every", "\(s.every)", "--frames-cap", "\(s.framesCap)",
         "--review", "\(s.review)", "--boundary", s.boundary, "--label", label]
    }

    private static func frameArgs(_ f: FrameSettings) -> [String] {
        ["--fps", "\(f.fps)", "--max-frames", "\(f.maxFrames)", "--hdr", f.hdr]
    }

    /// "env X  recording Y  run Z" → the ids the command printed.
    private static func ids(_ out: String) -> [String: String] {
        var d: [String: String] = [:]
        for m in out.matches(of: /(env|recording|run) (\S+)/) { d[String(m.1)] = String(m.2) }
        return d
    }

    /// A file path the pipeline can read: local as is; remote, the video is uploaded into the host's data/ inbox
    /// first unless it is already there (picked from the remote inbox).
    private static func remotePath(_ t: Target, _ file: URL, into folder: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard let h = t.remote else { return file.path }
        if file.path.hasPrefix(h.path + "/data/") { return String(file.path.dropFirst(h.path.count + 1)) }
        return try await Remote.upload(h, file, into: folder, progress: progress)
    }

    static func createEnvironment(_ t: Target, name: String) async throws -> String {
        guard let id = ids(try await run(t, ["new-env", name]))["env"] else { throw PipelineError("no environment id returned") }
        return id
    }

    static func createRecording(_ t: Target, envId: String, video: URL, name: String, frames: FrameSettings,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let path = try await remotePath(t, video, progress: progress)
        let out = try await run(t, ["new-recording", envId, path, "--name", name] + frameArgs(frames))
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    static func createMeasurements(_ t: Target, envId: String, name: String) async throws -> String {
        let out = try await run(t, ["new-measurements", envId, "--name", name])
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    static func createMarks(_ t: Target, envId: String, name: String, model: String) async throws -> String {
        let out = try await run(t, ["new-marks", envId, "--model", model, "--name", name])
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    /// Create a run and start it detached. `recordings` are the measurement recordings of a layout.
    static func createRun(_ t: Target, envId: String, kind: RunKind, inputId: String, recordings: [String] = [], settings: RunSettings, label: String) async throws -> String {
        let key = kind == .scan ? "recording" : "asset"
        return try await createRun(t, envId: envId,
                                   step: RunStep(kind: kind, inputs: [key: [inputId], "recordings": recordings], settings: settings, label: label))
    }

    /// Create a run from a recipe step (inputs by slot key); start it unless it is chained onto a run still working.
    static func createRun(_ t: Target, envId: String, step: RunStep, start: Bool = true) async throws -> String {
        var args = ["new-run", envId, step.kind.rawValue]
        for slot in step.kind.slots {
            let ids = step.inputs[slot.key] ?? []
            guard !ids.isEmpty else { continue }
            args += slot.isSingle ? ["--\(slot.key)", ids[0]] : ["--\(slot.key)"] + ids
        }
        if let a = step.after { args += ["--after", a] }
        let out = try await run(t, args + settingsArgs(step.settings, label: step.label))
        guard let id = ids(out)["run"] else { throw PipelineError("no run id returned") }
        if start { try await self.start(t, envId: envId, runId: id) }
        return id
    }

    static func createPhotosRecording(_ t: Target, envId: String, files: [URL], name: String,
                                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        var paths: [String] = []
        if t.remote != nil {
            let folder = name.replacing(/[^A-Za-z0-9._-]+/, with: "-") + "-photos"
            for (i, f) in files.enumerated() {
                let n = Double(i), total = Double(files.count)
                _ = try await remotePath(t, f, into: folder) { progress?((n + $0) / total) }
            }
            paths = ["data/\(folder)"]                       // the folder: the pipeline reads a photos recording from it
        } else {
            paths = files.map(\.path)
        }
        let out = try await run(t, ["new-recording", envId] + paths + ["--name", name])
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    /// Start a run detached (own session, under caffeinate) where the pipeline lives; the call returns at once.
    static func start(_ t: Target, envId: String, runId: String) async throws {
        _ = try await run(t, ["launch", "run", envId, runId])
    }

    /// SIGTERM the run's process group; pipeline.py turns that into a clean "cancelled".
    static func cancel(_ t: Target, envId: String, runId: String, pid: Int?) async throws {
        if t.remote != nil {
            _ = try await run(t, ["cancel", envId, runId])
        } else if let pid {
            let pgid = getpgid(pid_t(pid))
            if pgid > 0 { killpg(pgid, SIGTERM) } else { kill(pid_t(pid), SIGTERM) }
        }
    }

    /// Remove an environment or one of its items: to the Trash here, to work/trash/ on a remote host.
    static func trash(_ t: Target, dir: URL, envId: String, kind: String? = nil, itemId: String? = nil) async throws {
        if t.remote != nil {
            _ = try await run(t, ["trash", envId] + (kind.map { [$0, itemId ?? ""] } ?? []))
            try? FileManager.default.removeItem(at: dir)          // the mirror copy; the next pull would drop it anyway
        } else {
            try await Task.detached { try ManifestStore.trash(dir) }.value
        }
    }

    // MARK: data/ inbox

    static func videos(_ t: Target) async -> [VideoFile] {
        if let h = t.remote { return (try? await Remote.inbox(h)) ?? [] }
        let fm = FileManager.default
        let dir = ManifestStore.dataDir(t.root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return items
            .filter { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return VideoFile(url: u, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    // MARK: health

    static func health(_ t: Target) async -> Health {
        if let h = t.remote { return (try? await Remote.health(h)) ?? Health(reachable: false) }
        let fm = FileManager.default
        let path = environment()["PATH"]?.split(separator: ":").map(String.init) ?? []
        let rev = (try? await Remote.exec("/usr/bin/git", ["-C", t.root.path, "rev-parse", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Health(
            colmap: path.contains { fm.isExecutableFile(atPath: "\($0)/colmap") },
            openmvs: fm.isExecutableFile(atPath: t.root.appending(path: "tools/openmvs-install/bin/OpenMVS/DensifyPointCloud").path),
            blender: fm.isExecutableFile(atPath: blender.path),
            python: fm.isExecutableFile(atPath: python(t.root).path),
            revision: rev, protocolVersion: protocolVersion)
    }
}
