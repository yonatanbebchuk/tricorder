import Foundation

struct PipelineError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Talks to scanner/pipeline.py: creating scans and runs, launching detached executions, cancelling.
/// The Python side stays the single owner of the manifests; the app never writes run status itself.
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

    /// `python -m scanner.pipeline <args>`, returning stdout+stderr; throws with the last lines on failure.
    static func run(root: URL, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = python(root)
            p.arguments = ["-m", "scanner.pipeline"] + args
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
         "--measures", "\(s.measures)", "--max-faces", "\(s.maxFaces)", "--label", label]
    }

    private static func parseIds(_ out: String) throws -> (scan: String, run: String) {
        guard let m = out.firstMatch(of: /scan (\S+)\s+run (\S+)/) else { throw PipelineError("could not parse pipeline output:\n\(out)") }
        return (String(m.1), String(m.2))
    }

    /// Create a scan (and its first run) and start it detached.
    static func createScan(root: URL, video: URL, name: String, frames: FrameSettings, settings: RunSettings, label: String) async throws -> (scan: String, run: String) {
        let args = ["new", video.path, "--name", name, "--fps", "\(frames.fps)", "--max-frames", "\(frames.maxFrames)", "--hdr", frames.hdr]
            + settingsArgs(settings, label: label)
        let ids = try parseIds(try await run(root: root, args))
        try await start(root: root, scanId: ids.scan, runId: ids.run)
        return ids
    }

    static func createRun(root: URL, scanId: String, settings: RunSettings, label: String) async throws -> (scan: String, run: String) {
        let ids = try parseIds(try await run(root: root, ["new-run", scanId] + settingsArgs(settings, label: label)))
        try await start(root: root, scanId: ids.scan, runId: ids.run)
        return ids
    }

    static func start(root: URL, scanId: String, runId: String) async throws {
        _ = try await run(root: root, ["launch", "run", scanId, runId])
    }

    static func plan(root: URL, scanId: String, runId: String, pxPerM: Int) async throws {
        _ = try await run(root: root, ["launch", "plan", scanId, runId, "--px-per-m", "\(pxPerM)"])
    }

    /// SIGTERM the run's process group; pipeline.py turns that into a clean "cancelled".
    static func cancel(pid: Int) {
        let pgid = getpgid(pid_t(pid))
        if pgid > 0 { killpg(pgid, SIGTERM) } else { kill(pid_t(pid), SIGTERM) }
    }

    // MARK: videos in data/

    static func videos(root: URL, scans: [ScanRecord]) -> [VideoFile] {
        let fm = FileManager.default
        let dir = ManifestStore.dataDir(root)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let used = Set(scans.map { resolve(root: root, $0.scan.video.path).standardizedFileURL.path })
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return items
            .filter { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }
            .map { u in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return VideoFile(url: u, size: v?.fileSize ?? 0, modified: v?.contentModificationDate ?? .distantPast,
                                 used: used.contains(u.standardizedFileURL.path))
            }
            .sorted { $0.modified > $1.modified }
    }

    static func resolve(root: URL, _ path: String) -> URL {
        path.hasPrefix("/") ? URL(filePath: path) : root.appending(path: path)
    }

    static func isInData(root: URL, _ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == ManifestStore.dataDir(root).standardizedFileURL.path
    }

    /// Copy a video into data/ (an APFS clone when on the same volume, so it is instant).
    static func importVideo(root: URL, from url: URL) throws -> URL {
        let fm = FileManager.default
        let dir = ManifestStore.dataDir(root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = url.lastPathComponent.replacing(/[^A-Za-z0-9._-]/, with: "_")
        var dest = dir.appending(path: safe)
        if fm.fileExists(atPath: dest.path) {
            let stem = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            dest = dir.appending(path: "\(stem)_\(Int(Date().timeIntervalSince1970)).\(ext)")
        }
        try fm.copyItem(at: url, to: dest)
        return dest
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
