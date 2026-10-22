import Foundation

/// SSH and rsync to the compute Mac.  One multiplexed SSH connection per host (ControlMaster) keeps every call cheap
/// over the tailnet; rsync pulls the mirror and pushes the few files the app writes.
enum Remote {
    static let ssh = "/usr/bin/ssh"
    static let rsync = "/usr/bin/rsync"
    /// Homebrew is not on the PATH of a non-login SSH shell; the pipeline needs colmap, ffmpeg and friends from it.
    static let remotePath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// What the mirror leaves on the other Mac: raw clouds, meshes, COLMAP databases, Blender scenes and the videos.
    /// Everything the app's pages show (manifests, logs, previews, USDZ previews, plan deliverables, frames) comes over.
    static let mirrorExcludes = ["*.MOV", "*.mov", "*.mp4", "*.m4v", "*.mkv", "*.avi", "dense/", "sparse/", "database.db",
                                 "*.ply", "*.obj", "*.mtl", "*.mvs", "*.blend", "*.blend1", "*_map_Kd.jpg", "photos/", "*-[0-9A-F]*.log"]

    static func sshOptions(_ h: RemoteHost) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "LogLevel=ERROR",
         "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/tricorder-ssh-%C", "-o", "ControlPersist=600"]
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Run a shell command on the host; stdout+stderr, throws with the tail on a non-zero exit.
    static func shell(_ h: RemoteHost, _ command: String) async throws -> String {
        try await exec(ssh, sshOptions(h) + [h.address, command])
    }

    /// `python -m tricorder.pipeline <args>` in the host's checkout.
    static func pipeline(_ h: RemoteHost, _ args: [String]) async throws -> String {
        let cmd = "cd \(quote(h.path)) && export PATH=\(remotePath) && exec .venv/bin/python -m tricorder.pipeline " + args.map(quote).joined(separator: " ")
        return try await shell(h, cmd)
    }

    /// Bring the host's work/environments into the mirror.  `--update` never overwrites a file this app wrote more
    /// recently than the host's copy (a name, a note, marks awaiting their push); `--delete` drops what the host deleted.
    static func pull(_ h: RemoteHost) async throws {
        let dst = h.mirror.appending(path: "work/environments")
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        var args = ["-au", "--delete", "--partial", "--timeout=120", "-e", ([ssh] + sshOptions(h)).joined(separator: " ")]
        for x in mirrorExcludes { args += ["--exclude", x] }
        args += ["\(h.address):\(h.path)/work/environments/", dst.path + "/"]
        _ = try await exec(rsync, args)
    }

    /// Push one file the app changed (a manifest) back to the host, same relative path.
    static func push(_ h: RemoteHost, file: URL) async throws {
        let base = h.mirror.path + "/"
        guard file.path.hasPrefix(base) else { throw PipelineError("\(file.lastPathComponent) is not in the mirror") }
        let rel = String(file.path.dropFirst(base.count))
        _ = try await exec(rsync, ["-a", "-e", ([ssh] + sshOptions(h)).joined(separator: " "), file.path, "\(h.address):\(h.path)/\(rel)"])
    }

    /// Copy a video (or a folder of photos) into the host's data/ inbox; returns the path relative to the checkout.
    /// `progress` gets 0...1 as rsync reports it.
    static func upload(_ h: RemoteHost, _ src: URL, into folder: String? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let sub = folder.map { "data/\($0)/" } ?? "data/"
        _ = try await shell(h, "mkdir -p \(quote(h.path + "/" + sub))")
        let args = ["-a", "--partial", "--progress", "-e", ([ssh] + sshOptions(h)).joined(separator: " "), src.path, "\(h.address):\(h.path)/\(sub)"]
        _ = try await exec(rsync, args) { chunk in
            guard let progress, let m = chunk.matches(of: /(\d+)%/).last, let pct = Double(m.1) else { return }
            progress(pct / 100)
        }
        return sub + src.lastPathComponent
    }

    /// The host's data/ inbox.
    /// The JSON a pipeline command printed, ignoring anything ssh itself wrote around it.
    static func json(_ out: String) -> Data {
        Data((out.split(separator: "\n").last { $0.hasPrefix("{") || $0.hasPrefix("[") } ?? "").utf8)
    }

    static func inbox(_ h: RemoteHost) async throws -> [VideoFile] {
        struct Row: Decodable { let path: String; let size: Int; let modified: Double }
        let out = try await pipeline(h, ["inbox"])
        let rows = try JSONDecoder().decode([Row].self, from: json(out))
        return rows.map { VideoFile(url: URL(filePath: h.path + "/" + $0.path), size: $0.size, modified: Date(timeIntervalSince1970: $0.modified), remote: true) }
    }

    static func health(_ h: RemoteHost) async throws -> Health {
        struct Row: Decodable { let colmap: Bool; let openmvs: Bool; let blender: Bool; let python: Bool; let revision: String?; let `protocol`: Int? }
        let out = try await pipeline(h, ["health"])
        let r = try JSONDecoder().decode(Row.self, from: json(out))
        return Health(colmap: r.colmap, openmvs: r.openmvs, blender: r.blender, python: r.python, reachable: true,
                      revision: r.revision ?? "", protocolVersion: r.protocol ?? 1)
    }

    /// Bring the host's checkout up to date from its git remote (fast-forward only), the way you would by hand.
    static func update(_ h: RemoteHost) async throws -> String {
        try await shell(h, "cd \(quote(h.path)) && export PATH=\(remotePath) && git pull --ff-only 2>&1 | tail -3 && git rev-parse --short HEAD")
    }

    // MARK: processes

    /// Run a local executable, collecting output; `onOutput` sees chunks as they arrive (rsync --progress).
    static func exec(_ tool: String, _ args: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            p.environment = Pipeline.environment()
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            var data = Data()
            let fh = pipe.fileHandleForReading
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                onOutput?(String(decoding: chunk, as: UTF8.self))
            }
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            guard p.terminationStatus == 0 else {
                let tail = out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).suffix(6).joined(separator: "\n")
                throw PipelineError(tail.isEmpty ? "\(URL(filePath: tool).lastPathComponent) exited with code \(p.terminationStatus)" : tail)
            }
            return out
        }.value
    }
}
