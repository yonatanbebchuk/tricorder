import Foundation

struct PipelineError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Talks to tricorder/pipeline.py: creating environments, recordings and runs, launching detached executions,
/// cancelling.  The Python side stays the single owner of the manifests; the app never writes run status itself.
enum Pipeline {
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

    /// `python -m tricorder.pipeline <args>`, returning stdout+stderr; throws with the last lines on failure.
    static func run(root: URL, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = python(root)
            p.arguments = ["-m", "tricorder.pipeline"] + args
            p.currentDirectoryURL = root
            p.environment = environment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                let tail = out.split(separator: "\n").suffix(6).joined(separator: "\n")
                throw PipelineError(tail.isEmpty ? "pipeline exited with code \(p.terminationStatus)" : tail)
            }
            return out
        }.value
    }

    private static func settingsArgs(_ s: RunSettings, label: String) -> [String] {
        ["--res-level", "\(s.resLevel)", "--features", s.features, "--matcher", s.matcher, "--matching", s.matching,
         "--measures", "\(s.measures)", "--max-faces", "\(s.maxFaces)", "--px-per-m", "\(s.pxPerM)", "--contour", "\(s.contourM)", "--sheet-scale", "\(s.sheetScale)",
         "--preview-faces", "\(s.previewFaces)", "--label", label]
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

    static func createEnvironment(root: URL, name: String) async throws -> String {
        guard let id = ids(try await run(root: root, ["new-env", name]))["env"] else { throw PipelineError("no environment id returned") }
        return id
    }

    static func createRecording(root: URL, envId: String, video: URL, name: String, frames: FrameSettings) async throws -> String {
        let out = try await run(root: root, ["new-recording", envId, video.path, "--name", name] + frameArgs(frames))
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    static func createMeasurements(root: URL, envId: String, name: String) async throws -> String {
        let out = try await run(root: root, ["new-measurements", envId, "--name", name])
        guard let id = ids(out)["recording"] else { throw PipelineError("no recording id returned") }
        return id
    }

    /// Create a run and start it detached. `recordings` are the measurement recordings of a layout.
    static func createRun(root: URL, envId: String, kind: RunKind, inputId: String, recordings: [String] = [], settings: RunSettings, label: String) async throws -> String {
        var input = kind == .scan ? ["--recording", inputId] : ["--asset", inputId]
        if kind == .layout, !recordings.isEmpty { input += ["--recordings"] + recordings }
        let out = try await run(root: root, ["new-run", envId, kind.rawValue] + input + settingsArgs(settings, label: label))
        guard let id = ids(out)["run"] else { throw PipelineError("no run id returned") }
        try await start(root: root, envId: envId, runId: id)
        return id
    }

    static func start(root: URL, envId: String, runId: String) async throws {
        _ = try await run(root: root, ["launch", "run", envId, runId])
    }

    /// SIGTERM the run's process group; pipeline.py turns that into a clean "cancelled".
    static func cancel(pid: Int) {
        let pgid = getpgid(pid_t(pid))
        if pgid > 0 { killpg(pgid, SIGTERM) } else { kill(pid_t(pid), SIGTERM) }
    }

    // MARK: data/ inbox

    static func videos(root: URL) -> [VideoFile] {
        let fm = FileManager.default
        let dir = ManifestStore.dataDir(root)
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

    static func health(root: URL) -> Health {
        let fm = FileManager.default
        let path = environment()["PATH"]?.split(separator: ":").map(String.init) ?? []
        return Health(
            colmap: path.contains { fm.isExecutableFile(atPath: "\($0)/colmap") },
            openmvs: fm.isExecutableFile(atPath: root.appending(path: "tools/openmvs-install/bin/OpenMVS/DensifyPointCloud").path),
            blender: fm.isExecutableFile(atPath: blender.path),
            python: fm.isExecutableFile(atPath: python(root).path))
    }
}
