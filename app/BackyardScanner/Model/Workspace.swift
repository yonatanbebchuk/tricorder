import AppKit
import Foundation
import Observation

/// The app's single source of truth: the project root, every scan and run read from disk, tool health, and the
/// actions the views can take.  Reads happen off the main actor; state is published on it.
@MainActor @Observable
final class Workspace {
    private(set) var root: URL?
    private(set) var scans: [ScanRecord] = []
    private(set) var health = Health()
    private(set) var lastRefresh: Date?
    var selection: Selection?
    var showNewScan = false
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
        return fm.fileExists(atPath: url.appending(path: "scanner/pipeline.py").path)
            && fm.fileExists(atPath: url.appending(path: ".venv/bin/python").path)
    }

    /// Saved choice, else the checkout the app was built inside (make app), else ~/Projects/backyard-scanner.
    static func discoverRoot() -> URL? {
        var candidates: [URL] = []
        if let s = UserDefaults.standard.string(forKey: rootKey) { candidates.append(URL(filePath: s)) }
        var u = Bundle.main.bundleURL
        for _ in 0..<8 { u = u.deletingLastPathComponent(); candidates.append(u) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/backyard-scanner"))
        return candidates.first(where: isValidRoot)
    }

    @discardableResult
    func setRoot(_ url: URL) -> Bool {
        guard Self.isValidRoot(url) else {
            lastError = "That folder doesn't look like the backyard-scanner checkout: it needs scanner/pipeline.py and .venv/bin/python (run ./setup.sh first)."
            return false
        }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        adopt(url)
        return true
    }

    private func adopt(_ url: URL) {
        root = url
        selection = nil
        pollTask?.cancel()
        let scansDir = ManifestStore.scansDir(url)
        try? FileManager.default.createDirectory(at: scansDir, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(paths: [scansDir.path]) { [weak self] in
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
        scans = loaded
        health = Pipeline.health(root: root)
        lastRefresh = .now
    }

    var anyRunning: Bool { scans.contains { $0.isBusy } }
    func scan(_ id: String) -> ScanRecord? { scans.first { $0.id == id } }
    func run(_ scanId: String, _ runId: String) -> RunRecord? { scan(scanId)?.run(runId) }
    var selectedScan: ScanRecord? { selection.flatMap { scan($0.scanId) } }

    func videosInData() -> [VideoFile] {
        guard let root else { return [] }
        return Pipeline.videos(root: root, scans: scans)
    }

    func isInData(_ url: URL) -> Bool { root.map { Pipeline.isInData(root: $0, url) } ?? false }

    func requestNewScan(video: URL? = nil) {
        pendingVideo = video
        showNewScan = true
    }

    // MARK: actions

    private func attempt(_ what: String, _ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true }
        catch { lastError = "\(what): \(error.localizedDescription)"; return false }
    }

    func importVideo(_ url: URL) async throws -> URL {
        guard let root else { throw PipelineError("no project folder") }
        return try await Task.detached { try Pipeline.importVideo(root: root, from: url) }.value
    }

    func createScan(video: URL, name: String, frames: FrameSettings, settings: RunSettings, label: String) async -> Bool {
        guard let root else { return false }
        return await attempt("Creating the scan failed") {
            let ids = try await Pipeline.createScan(root: root, video: video, name: name, frames: frames, settings: settings, label: label)
            await refresh()
            selection = .run(ids.scan, ids.run)
        }
    }

    func createRun(scanId: String, settings: RunSettings, label: String) async -> Bool {
        guard let root else { return false }
        return await attempt("Starting the run failed") {
            let ids = try await Pipeline.createRun(root: root, scanId: scanId, settings: settings, label: label)
            await refresh()
            selection = .run(ids.scan, ids.run)
        }
    }

    func startRun(_ r: RunRecord) async {
        guard let root else { return }
        _ = await attempt("Starting the run failed") {
            try await Pipeline.start(root: root, scanId: r.run.scanId, runId: r.run.id)
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    func cancelRun(_ r: RunRecord) {
        if let pid = r.run.pid { Pipeline.cancel(pid: pid) }
        scheduleRefresh()
    }

    func startPlan(_ r: RunRecord, pxPerM: Int = 50) async {
        guard let root else { return }
        _ = await attempt("Starting the plan failed") {
            try await Pipeline.plan(root: root, scanId: r.run.scanId, runId: r.run.id, pxPerM: pxPerM)
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    func deleteRun(_ r: RunRecord) async {
        let dir = r.dir
        _ = await attempt("Deleting the run failed") {
            try await Task.detached { try ManifestStore.trash(dir) }.value
            if selection == .run(r.run.scanId, r.run.id) { selection = .scan(r.run.scanId) }
            await refresh()
        }
    }

    func deleteScan(_ s: ScanRecord) async {
        let dir = s.dir
        _ = await attempt("Deleting the scan failed") {
            try await Task.detached { try ManifestStore.trash(dir) }.value
            if selection?.scanId == s.id { selection = nil }
            await refresh()
        }
    }

    func rename(_ s: ScanRecord, to name: String) async {
        let file = s.dir.appending(path: "scan.json")
        _ = await attempt("Renaming failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["name"] = name } }.value
            await refresh()
        }
    }

    func saveNotes(_ s: ScanRecord, _ notes: String) async {
        let file = s.dir.appending(path: "scan.json")
        _ = await attempt("Saving notes failed") {
            try await Task.detached { try ManifestStore.patchJSON(at: file) { $0["notes"] = notes } }.value
            await refresh()
        }
    }

    func saveAnswer(_ r: RunRecord, promptId: String, answer: Answer?) async {
        let dir = r.dir
        _ = await attempt("Saving the measurement failed") {
            try await Task.detached { try ManifestStore.saveAnswer(runDir: dir, promptId: promptId, answer: answer) }.value
            await refresh()
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
