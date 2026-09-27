import AppKit
import Foundation
import Observation

/// The app's single source of truth: the project root, every environment read from disk, tool health, navigation
/// state, and the actions the views can take.  Reads happen off the main actor; state is published on it.
@MainActor @Observable
final class Workspace {
    private(set) var root: URL?
    private(set) var environments: [EnvironmentRecord] = []
    private(set) var health = Health()
    private(set) var lastRefresh: Date?

    // navigation
    var selection: Selection?
    var path: [Route] = []

    // sheets
    var showNewEnvironment = false
    var newRecordingFor: EnvRef?
    var newRunRequest: NewRunRequest?
    var pendingVideo: URL?
    var lastError: String?

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    static let rootKey = "projectRoot"

    init() {
        if let r = Self.discoverRoot() { adopt(r) }
    }

    // MARK: project root

    static func isValidRoot(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appending(path: "tricorder/pipeline.py").path)
            && fm.fileExists(atPath: url.appending(path: ".venv/bin/python").path)
    }

    /// Saved choice, else the checkout the app was built inside (make app), else ~/Projects/tricorder.
    static func discoverRoot() -> URL? {
        var candidates: [URL] = []
        if let s = UserDefaults.standard.string(forKey: rootKey) { candidates.append(URL(filePath: s)) }
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
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        adopt(url)
        return true
    }

    private func adopt(_ url: URL) {
        root = url
        selection = nil
        path = []
        pollTask?.cancel()
        let dir = ManifestStore.environmentsDir(url)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(paths: [dir.path]) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        health = Pipeline.health(root: url)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let busy = self?.anyRunning ?? false
                try? await Task.sleep(for: .seconds(busy ? 3 : 20))
                await self?.refresh()
            }
        }
        Task { await refresh() }
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
        let loaded = await Task.detached(priority: .userInitiated) { ManifestStore.loadAll(root: root) }.value
        environments = loaded
        health = Pipeline.health(root: root)
        lastRefresh = .now
    }

    var anyRunning: Bool { environments.contains { $0.isBusy } }
    func environment(_ id: String) -> EnvironmentRecord? { environments.first { $0.id == id } }
    var selectedEnvironment: EnvironmentRecord? { selection.flatMap { environment($0.envId) } }

    func videosInInbox() -> [VideoFile] { root.map { Pipeline.videos(root: $0) } ?? [] }

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
        case .recording(let e, _), .run(let e, _), .asset(let e, _): env = e
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

    func requestNewRecording(env: String, video: URL? = nil) {
        pendingVideo = video
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

    func createEnvironment(name: String) async -> String? {
        guard let root else { return nil }
        var created: String?
        _ = await attempt("Creating the environment failed") {
            created = try await Pipeline.createEnvironment(root: root, name: name)
            await refresh()
            if let created { select(.environment(created)) }
        }
        return created
    }

    /// Add a recording; optionally start a reconstruction on it right away.
    func createRecording(env: String, video: URL, name: String, frames: FrameSettings, reconstruct: RunSettings?, label: String) async -> Bool {
        guard let root else { return false }
        return await attempt("Adding the recording failed") {
            let rec = try await Pipeline.createRecording(root: root, envId: env, video: video, name: name, frames: frames)
            if let settings = reconstruct {
                let run = try await Pipeline.createRun(root: root, envId: env, kind: .scan, inputId: rec, settings: settings, label: label)
                await refresh()
                open(.run(env, run))
            } else {
                await refresh()
                open(.recording(env, rec))
            }
        }
    }

    func createRun(env: String, kind: RunKind, inputId: String, settings: RunSettings, label: String) async -> Bool {
        guard let root else { return false }
        return await attempt("Starting the run failed") {
            let run = try await Pipeline.createRun(root: root, envId: env, kind: kind, inputId: inputId, settings: settings, label: label)
            await refresh()
            open(.run(env, run))
        }
    }

    func startRun(_ r: RunRecord) async {
        guard let root else { return }
        _ = await attempt("Starting the run failed") {
            try await Pipeline.start(root: root, envId: r.run.envId, runId: r.run.id)
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    func cancelRun(_ r: RunRecord) {
        if let pid = r.run.pid { Pipeline.cancel(pid: pid) }
        scheduleRefresh()
    }

    private func trash(_ what: String, _ dir: URL, then: () -> Void) async {
        _ = await attempt(what) {
            try await Task.detached { try ManifestStore.trash(dir) }.value
            then()
            await refresh()
        }
    }

    func deleteRun(_ r: RunRecord) async {
        await trash("Deleting the run failed", r.dir) { if path.last == .run(r.run.envId, r.run.id) { path.removeLast() } }
    }

    func deleteRecording(_ r: RecordingRecord) async {
        await trash("Deleting the recording failed", r.dir) { if path.last == .recording(r.rec.envId, r.rec.id) { path.removeLast() } }
    }

    func deleteAsset(_ a: AssetRecord) async {
        await trash("Deleting the asset failed", a.dir) { if path.last == .asset(a.asset.envId, a.asset.id) { path.removeLast() } }
    }

    func deleteEnvironment(_ e: EnvironmentRecord) async {
        await trash("Deleting the environment failed", e.dir) { if selection?.envId == e.id { goHome() } }
    }

    func rename(_ e: EnvironmentRecord, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != e.env.name else { return }
        let file = e.dir.appending(path: "environment.json")
        _ = await attempt("Renaming failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["name"] = trimmed } }.value
            await refresh()
        }
    }

    func saveNotes(environment e: EnvironmentRecord, _ notes: String) async {
        let file = e.dir.appending(path: "environment.json")
        _ = await attempt("Saving notes failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["notes"] = notes } }.value
            await refresh()
        }
    }

    func saveNotes(recording r: RecordingRecord, _ notes: String) async {
        let file = r.dir.appending(path: "recording.json")
        _ = await attempt("Saving notes failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["notes"] = notes } }.value
            await refresh()
        }
    }

    func updateConstraints(_ a: AssetRecord, _ mutate: @escaping @Sendable (inout Constraints) -> Void) async {
        let dir = a.dir
        _ = await attempt("Saving the measurement failed") {
            try await Task.detached { try ManifestStore.updateConstraints(assetDir: dir, mutate) }.value
            await refresh()
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openFile(_ url: URL) { NSWorkspace.shared.open(url) }
}
