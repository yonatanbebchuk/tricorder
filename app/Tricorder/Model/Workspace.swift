import AppKit
import Foundation
import Observation

/// The app's single source of truth: where the pipeline runs (this checkout, or a Mac on the tailnet), every
/// environment read from disk, tool health, navigation state, and the actions the views can take.  Reads happen off
/// the main actor; state is published on it.
///
/// With a remote host the record lives there: the app keeps a mirror of its work/environments (pulled with rsync on
/// every poll, after the host reconciles dead runs), sends commands over SSH, and pushes back the few files it writes.
@MainActor @Observable
final class Workspace {
    private(set) var compute: Compute?
    private(set) var environments: [EnvironmentRecord] = []
    private(set) var health = Health()
    private(set) var lastRefresh: Date?
    private(set) var lastPull: Date?
    private(set) var inbox: [VideoFile] = []
    /// What a transfer to the remote host is doing right now ("uploading the video · 42 %"), for the sheets.
    private(set) var transferStatus: String?

    // navigation
    var selection: Selection?
    var path: [Route] = []

    // sheets
    var showNewEnvironment = false
    var newRecordingFor: EnvRef?
    var newRecordingMeasurements = false
    var newRunRequest: NewRunRequest?
    var pendingVideo: URL?
    var lastError: String?

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var pulling = false

    static let rootKey = Compute.rootKey

    init() {
        if let c = Compute.load() ?? Self.discoverLocal().map(Compute.local) { adopt(c) }
    }

    var root: URL? { compute?.root }
    var remote: RemoteHost? { compute?.remote }
    private var target: Pipeline.Target? { compute.map(Pipeline.Target.init) }

    // MARK: project root / compute device

    static func isValidRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appending(path: "tricorder/pipeline.py").path)
            && fm.fileExists(atPath: url.appending(path: ".venv/bin/python").path)
    }

    /// The checkout the app was built inside (make app), else ~/Projects/tricorder.
    static func discoverLocal() -> URL? {
        var candidates: [URL] = []
        var u = Bundle.main.bundleURL
        for _ in 0..<8 { u = u.deletingLastPathComponent(); candidates.append(u) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appending(path: "Projects/tricorder"))
        candidates.append(home.appending(path: "Projects/backyard-scanner"))
        return candidates.first(where: isValidRoot)
    }

    @discardableResult
    func setRoot(_ url: URL) -> Bool {
        guard Self.isValidRoot(url) else {
            lastError = "That folder doesn't look like the tricorder checkout: it needs tricorder/pipeline.py and .venv/bin/python (run ./setup.sh first)."
            return false
        }
        let c = Compute.local(url)
        c.save()
        adopt(c)
        return true
    }

    /// Use another Mac: everything runs there over SSH, this app shows a mirror of its record.
    func setRemote(_ host: RemoteHost) {
        let c = Compute.remote(host)
        c.save()
        adopt(c)
    }

    /// Reach the host and read its tool health; a sentence for the settings' Test button.
    func testRemote(_ host: RemoteHost) async -> String {
        do {
            let out = try await Remote.pipeline(host, ["health"])
            struct Row: Decodable { let colmap: Bool; let openmvs: Bool; let blender: Bool; let host: String }
            let r = try JSONDecoder().decode(Row.self, from: Remote.json(out))
            let missing = [("COLMAP", r.colmap), ("OpenMVS", r.openmvs), ("Blender", r.blender)].filter { !$0.1 }.map(\.0)
            return "\(r.host) answers" + (missing.isEmpty ? ", every tool is there." : "; missing: \(missing.joined(separator: ", ")).")
        } catch {
            return "Not reachable: \(error.localizedDescription)"
        }
    }

    private func adopt(_ c: Compute) {
        compute = c
        selection = nil
        path = []
        environments = []
        pollTask?.cancel()
        let dir = ManifestStore.environmentsDir(c.root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(paths: [dir.path]) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        Task { await refresh() }                              // what the mirror / checkout already holds, at once
        pollTask = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                guard let self else { return }
                if n % 10 == 0 { await self.checkHealth() }
                await self.pull()
                await self.refresh()
                n += 1
                let busy = self.anyRunning
                try? await Task.sleep(for: .seconds(self.remote == nil ? (busy ? 3 : 20) : (busy ? 5 : 30)))
            }
        }
    }

    // MARK: reading

    func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { await refresh() }
        }
    }

    func refresh() async {
        guard let root else { return }
        let local = remote == nil
        let loaded = await Task.detached(priority: .userInitiated) { ManifestStore.loadAll(root: root, reconcile: local) }.value
        environments = loaded
        lastRefresh = .now
    }

    /// Remote only: let the host mark its dead runs, then bring its record into the mirror.  Unreachable hosts
    /// show in the health bar, not as an alert on every poll.
    func pull() async {
        guard let h = remote, !pulling else { return }
        pulling = true
        defer { pulling = false }
        _ = try? await Remote.pipeline(h, ["reconcile"])      // best effort: an older checkout there has no such command
        do {
            try await Remote.pull(h)
            lastPull = .now
            health.reachable = true
        } catch {
            health.reachable = false
        }
    }

    /// Tool health; on a remote host only when it answers (reachability itself is what the pull says).
    func checkHealth() async {
        guard let t = target else { return }
        if let h = remote {
            if let fresh = try? await Remote.health(h) { health = fresh }
        } else {
            health = await Pipeline.health(t)
        }
    }

    /// The remote checkout is older than what this app sends it.
    var remoteNeedsUpdate: Bool { remote != nil && health.reachable && health.protocolVersion < Pipeline.protocolVersion }

    /// `git pull` in the remote checkout, then read its health again; a sentence for the settings.
    func updateRemote() async -> String {
        guard let h = remote else { return "" }
        do {
            let out = try await Remote.update(h)
            await checkHealth()
            return "Updated: " + out.split(separator: "\n").joined(separator: " · ")
        } catch {
            return "Update failed: \(error.localizedDescription)"
        }
    }

    /// Pull now, then refresh: after a command, so the page the command made exists in the mirror.
    private func sync() async {
        await pull()
        await refresh()
    }

    var anyRunning: Bool { environments.contains { $0.isBusy } }
    func environment(_ id: String) -> EnvironmentRecord? { environments.first { $0.id == id } }
    var selectedEnvironment: EnvironmentRecord? { selection.flatMap { environment($0.envId) } }

    func refreshInbox() async {
        guard let t = target else { return }
        inbox = await Pipeline.videos(t)
    }

    // MARK: navigation

    func goHome() {
        selection = nil
        path = []
    }

    func select(_ s: Selection) {
        selection = s
        path = []
    }

    func open(_ route: Route) {
        let env: String
        switch route {
        case .recording(let e, _), .run(let e, _), .asset(let e, _), .editor(let e, _, _): env = e
        }
        if selection?.envId != env {
            selection = .environment(env)
            path = [route]
        } else if path.last != route {
            path.append(route)
        }
    }

    func requestNewEnvironment(video: URL? = nil) {
        pendingVideo = video
        showNewEnvironment = true
    }

    func requestNewRecording(env: String, video: URL? = nil, measurements: Bool = false) {
        pendingVideo = video
        newRecordingMeasurements = measurements
        newRecordingFor = EnvRef(id: env)
    }

    func requestNewRun(env: String, kind: RunKind = .scan, inputId: String? = nil) {
        newRunRequest = NewRunRequest(envId: env, kind: kind, inputId: inputId)
    }

    // MARK: actions

    private func attempt(_ what: String, _ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true }
        catch { lastError = "\(what): \(error.localizedDescription)"; return false }
    }

    /// Progress of an upload to the host, for the sheet that started it.
    private func transfer(_ what: String) -> @Sendable (Double) -> Void {
        { [weak self] pct in Task { @MainActor in self?.transferStatus = "\(what) · \(Int(pct * 100)) %" } }
    }

    func createEnvironment(name: String) async -> String? {
        guard let t = target else { return nil }
        var created: String?
        _ = await attempt("Creating the environment failed") {
            created = try await Pipeline.createEnvironment(t, name: name)
            await sync()
            if let created { select(.environment(created)) }
        }
        return created
    }

    /// Add a recording; optionally start a reconstruction on it right away.
    func createRecording(env: String, video: URL, name: String, frames: FrameSettings, reconstruct: RunSettings?, label: String) async -> Bool {
        guard let t = target else { return false }
        defer { transferStatus = nil }
        return await attempt("Adding the recording failed") {
            let rec = try await Pipeline.createRecording(t, envId: env, video: video, name: name, frames: frames, progress: transfer("uploading the video"))
            if let settings = reconstruct {
                let run = try await Pipeline.createRun(t, envId: env, kind: .scan, inputId: rec, settings: settings, label: label)
                await sync()
                open(.run(env, run))
            } else {
                await sync()
                open(.recording(env, rec))
            }
        }
    }

    /// A measurement recording with its items; opens it when done.
    func createMeasurementRecording(env: String, name: String, items: [MeasurementItem], north: MeasurementNorth?) async -> Bool {
        guard let t = target else { return false }
        return await attempt("Saving the measurements failed") {
            let rec = try await Pipeline.createMeasurements(t, envId: env, name: name)
            await sync()
            let dir = ManifestStore.environmentsDir(t.root).appending(path: "\(env)/recordings/\(rec)")
            try await Task.detached { try ManifestStore.saveMeasurements(recordingDir: dir, items: items, north: north) }.value
            try await wrote(dir.appending(path: "recording.json"))
            await refresh()
            open(.recording(env, rec))
        }
    }

    /// A marks recording on a model, with its first items; opens it when done (or stays, when `open` is false).
    @discardableResult
    func createMarksRecording(env: String, name: String, model: String, items: [MarkItem], open openIt: Bool = true) async -> String? {
        guard let t = target else { return nil }
        var created: String?
        _ = await attempt("Saving the marks failed") {
            let rec = try await Pipeline.createMarks(t, envId: env, name: name, model: model)
            await sync()
            let dir = ManifestStore.environmentsDir(t.root).appending(path: "\(env)/recordings/\(rec)")
            try await Task.detached { try ManifestStore.saveMarks(recordingDir: dir, items: items) }.value
            try await wrote(dir.appending(path: "recording.json"))
            await refresh()
            created = rec
            if openIt { open(.recording(env, rec)) }
        }
        return created
    }

    func saveMarks(_ r: RecordingRecord, items: [MarkItem]) async {
        let dir = r.dir
        _ = await attempt("Saving the marks failed") {
            try await Task.detached { try ManifestStore.saveMarks(recordingDir: dir, items: items) }.value
            try await wrote(dir.appending(path: "recording.json"))
            await refresh()
        }
    }

    func saveMeasurements(_ r: RecordingRecord, items: [MeasurementItem], north: MeasurementNorth?) async {
        let dir = r.dir
        _ = await attempt("Saving the measurements failed") {
            try await Task.detached { try ManifestStore.saveMeasurements(recordingDir: dir, items: items, north: north) }.value
            try await wrote(dir.appending(path: "recording.json"))
            await refresh()
        }
    }

    func createRun(env: String, kind: RunKind, inputId: String, recordings: [String] = [], settings: RunSettings, label: String) async -> Bool {
        guard let t = target else { return false }
        return await attempt("Starting the run failed") {
            let run = try await Pipeline.createRun(t, envId: env, kind: kind, inputId: inputId, recordings: recordings, settings: settings, label: label)
            await sync()
            open(.run(env, run))
        }
    }

    /// A recipe: one run, or a chain where later steps take earlier runs' assets ("@r5") and are launched by them.
    /// The first run starts now; the page of the first run opens.
    func createRuns(env: String, steps: [RunStep]) async -> Bool {
        guard let t = target, !steps.isEmpty else { return false }
        return await attempt("Starting the run failed") {
            var ids: [String] = []
            for var step in steps {
                for (slot, stepIndex) in step.refs where stepIndex < ids.count {
                    step.inputs[slot] = ["@\(ids[stepIndex])"]
                }
                if let last = step.refs.values.max(), last < ids.count { step.after = ids[last] }
                let id = try await Pipeline.createRun(t, envId: env, step: step, start: ids.isEmpty)
                ids.append(id)
            }
            await sync()
            if let first = ids.first { open(.run(env, first)) }
        }
    }

    func createPhotosRecording(env: String, files: [URL], name: String) async -> Bool {
        guard let t = target else { return false }
        defer { transferStatus = nil }
        return await attempt("Adding the photos failed") {
            let rec = try await Pipeline.createPhotosRecording(t, envId: env, files: files, name: name, progress: transfer("uploading the photos"))
            await sync()
            open(.recording(env, rec))
        }
    }

    func startRun(_ r: RunRecord) async {
        guard let t = target else { return }
        _ = await attempt("Starting the run failed") {
            try await Pipeline.start(t, envId: r.run.envId, runId: r.run.id)
            try? await Task.sleep(for: .milliseconds(600))
            await sync()
        }
    }

    func cancelRun(_ r: RunRecord) async {
        guard let t = target else { return }
        _ = await attempt("Cancelling the run failed") {
            try await Pipeline.cancel(t, envId: r.run.envId, runId: r.run.id, pid: r.run.pid)
            try? await Task.sleep(for: .milliseconds(600))
            await sync()
        }
    }

    /// A file the app changed in the record: on a remote host, push it back now.
    private func wrote(_ file: URL) async throws {
        if let h = remote { try await Remote.push(h, file: file) }
    }

    private func trash(_ what: String, _ dir: URL, envId: String, kind: String? = nil, itemId: String? = nil, then: () -> Void) async {
        guard let t = target else { return }
        _ = await attempt(what) {
            try await Pipeline.trash(t, dir: dir, envId: envId, kind: kind, itemId: itemId)
            then()
            await refresh()
        }
    }

    func deleteRun(_ r: RunRecord) async {
        await trash("Deleting the run failed", r.dir, envId: r.run.envId, kind: "runs", itemId: r.run.id) {
            if path.last == .run(r.run.envId, r.run.id) { path.removeLast() }
        }
    }

    /// Delete a recording and everything that depends on it (measurements marked on a video's frames).
    func deleteRecording(_ r: RecordingRecord) async {
        guard let env = environment(r.rec.envId) else { return }
        let deps = env.dependents(ofRecording: r.rec.id)
        for d in deps.recordings {
            await trash("Deleting \(d.rec.name) failed", d.dir, envId: env.id, kind: "recordings", itemId: d.rec.id) {}
        }
        await trash("Deleting the recording failed", r.dir, envId: env.id, kind: "recordings", itemId: r.rec.id) {
            if case .recording(_, let id)? = path.last, id == r.rec.id || deps.recordings.contains(where: { $0.rec.id == id }) { path.removeLast() }
        }
    }

    /// Delete an asset and everything that depends on it (marks and inventories on a model, mesh measurements, edited models).
    func deleteAsset(_ a: AssetRecord) async {
        guard let env = environment(a.asset.envId) else { return }
        let deps = env.dependents(ofAsset: a.asset.id)
        for d in deps.recordings {
            await trash("Deleting \(d.rec.name) failed", d.dir, envId: env.id, kind: "recordings", itemId: d.rec.id) {}
        }
        for d in deps.assets {
            await trash("Deleting \(d.asset.name) failed", d.dir, envId: env.id, kind: "assets", itemId: d.asset.id) {}
        }
        await trash("Deleting the asset failed", a.dir, envId: env.id, kind: "assets", itemId: a.asset.id) {
            switch path.last {
            case .asset(_, let id)? where id == a.asset.id || deps.assets.contains(where: { $0.asset.id == id }): path.removeLast()
            case .editor(_, let id, _)? where id == a.asset.id || deps.assets.contains(where: { $0.asset.id == id }): path.removeLast()
            case .recording(_, let id)? where deps.recordings.contains(where: { $0.rec.id == id }): path.removeLast()
            default: break
            }
        }
    }

    /// One sentence for a delete confirmation: what else goes.
    static func cascadeText(recordings: [RecordingRecord], assets: [AssetRecord]) -> String {
        let names = recordings.map(\.rec.name) + assets.map(\.asset.name)
        guard !names.isEmpty else { return "" }
        return "This also deletes what depends on it: " + names.joined(separator: ", ") + ". Continue?"
    }

    func deleteEnvironment(_ e: EnvironmentRecord) async {
        await trash("Deleting the environment failed", e.dir, envId: e.id) { if selection?.envId == e.id { goHome() } }
    }

    func rename(_ e: EnvironmentRecord, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != e.env.name else { return }
        let file = e.dir.appending(path: "environment.json")
        _ = await attempt("Renaming failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["name"] = trimmed } }.value
            try await wrote(file)
            await refresh()
        }
    }

    func saveNotes(environment e: EnvironmentRecord, _ notes: String) async {
        let file = e.dir.appending(path: "environment.json")
        _ = await attempt("Saving notes failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["notes"] = notes } }.value
            try await wrote(file)
            await refresh()
        }
    }

    func saveNotes(recording r: RecordingRecord, _ notes: String) async {
        let file = r.dir.appending(path: "recording.json")
        _ = await attempt("Saving notes failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["notes"] = notes } }.value
            try await wrote(file)
            await refresh()
        }
    }

    func updateConstraints(_ a: AssetRecord, _ mutate: @escaping @Sendable (inout Constraints) -> Void) async {
        let dir = a.dir
        _ = await attempt("Saving the measurement failed") {
            try await Task.detached { try ManifestStore.updateConstraints(assetDir: dir, mutate) }.value
            try await wrote(dir.appending(path: "measure/constraints.json"))
            await refresh()
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile(_ url: URL) { NSWorkspace.shared.open(url) }
}
