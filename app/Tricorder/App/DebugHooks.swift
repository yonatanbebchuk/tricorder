import AppKit
import ScreenCaptureKit
import SwiftUI

/// Development-only hooks, all driven by environment variables so a normal launch is unaffected:
///   TRICORDER_SELECT=<env>[/recordings|/runs|/assets|/recording/<id>|/run/<id>|/asset/<id>]   navigate once loaded
///   TRICORDER_SMOKE=1                run `pipeline list` through the app's Process wrapper and print the result
///   TRICORDER_RENDER=<file.png>      after ~3 s, render the current page with ImageRenderer (AppKit-backed parts stay blank)
///   TRICORDER_WINDOW=1440x900        size the main window (for consistent screenshots)
///   TRICORDER_SCREENSHOT=<file.png>  after ~4 s, a real screenshot of the window via ScreenCaptureKit (needs the
///                                    Screen Recording permission for Tricorder; macOS asks once)
///   TRICORDER_DEMO=<dir>             walk home → environment → asset → run → recording → assets, one screenshot each
///   TRICORDER_DEMO_ENV=<env>         the environment the demo walks (default: the first one)
///   TRICORDER_QUIT=1                 quit after the render / screenshot / demo
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment

    @MainActor
    static func run(_ ws: Workspace) {
        if let size = env["TRICORDER_WINDOW"], let m = size.firstMatch(of: /(\d+)x(\d+)/) {
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                    w.setContentSize(NSSize(width: Int(m.1) ?? 1400, height: Int(m.2) ?? 900))
                    w.center()
                    NSApp.activate()
                    w.makeKeyAndOrderFront(nil)
                }
            }
        }
        if let path = env["TRICORDER_SCREENSHOT"] {
            Task {
                try? await Task.sleep(for: .seconds(4))
                await screenshot(to: URL(filePath: path))
                if env["TRICORDER_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
        if let dir = env["TRICORDER_DEMO"] {
            Task { await demo(ws, into: URL(filePath: dir)) }
        }
        if let sel = env["TRICORDER_SELECT"] {
            Task {
                await ws.refresh()
                let p = sel.split(separator: "/").map(String.init)
                switch p.count {
                case 1: ws.select(.environment(p[0]))
                case 2:
                    switch p[1] {
                    case "recordings": ws.select(.recordings(p[0]))
                    case "runs": ws.select(.runs(p[0]))
                    case "assets": ws.select(.assets(p[0]))
                    default: ws.select(.environment(p[0]))
                    }
                case 3:
                    switch p[1] {
                    case "recording": ws.open(.recording(p[0], p[2]))
                    case "run": ws.open(.run(p[0], p[2]))
                    case "asset": ws.open(.asset(p[0], p[2]))
                    default: break
                    }
                default: break
                }
            }
        }
        if env["TRICORDER_SMOKE"] != nil, let root = ws.root {
            Task {
                do { FileHandle.standardError.write(Data("smoke ok:\n\(try await Pipeline.run(root: root, ["list"]))".utf8)) }
                catch { FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8)) }
            }
        }
        if let path = env["TRICORDER_RENDER"] {
            Task {
                try? await Task.sleep(for: .seconds(4))
                render(ws, to: URL(filePath: path))
                if env["TRICORDER_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
    }

    /// A real capture of the app's window, materials and SceneKit included.
    @MainActor
    static func screenshot(to url: URL) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        NSApp.activate(ignoringOtherApps: true)      // launched from a shell: the plain activate() is ignored
        window.orderFrontRegardless()
        window.makeKey()
        try? await Task.sleep(for: .milliseconds(700))
        if !CGPreflightScreenCaptureAccess() {
            // Ad-hoc signatures change with every build, so macOS forgets the grant: ask again (opens System Settings).
            FileHandle.standardError.write(Data("screenshot: Screen Recording permission missing for this build; requesting\n".utf8))
            _ = CGRequestScreenCaptureAccess()
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
            guard let w = mine.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) ?? mine.first else {
                FileHandle.standardError.write(Data("screenshot: window not shareable (\(content.windows.count) windows visible, \(mine.count) mine)\n".utf8)); return
            }
            let cfg = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try png.write(to: url) }
        } catch {
            FileHandle.standardError.write(Data("screenshot failed: \(error)\n".utf8))
        }
    }

    /// Screenshots of a walk through one environment, numbered for a demo GIF.
    @MainActor
    static func demo(_ ws: Workspace, into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        await ws.refresh()
        guard let e = env["TRICORDER_DEMO_ENV"].flatMap({ ws.environment($0) }) ?? ws.environments.first else { return }
        var n = 0
        func shot(_ name: String, after: Double) async {
            try? await Task.sleep(for: .seconds(after))
            n += 1
            await screenshot(to: dir.appending(path: String(format: "%02d-%@.png", n, name)))
        }
        ws.goHome()
        await shot("home", after: 2)
        ws.select(.environment(e.id))
        await shot("environment", after: 4)
        if let a = e.currentAssets.first(where: { $0.asset.kind == .scan3d }) ?? e.assets.last {
            ws.open(.asset(e.id, a.asset.id))
            await shot("asset", after: 4)
        }
        if let r = e.runs.last {
            ws.open(.run(e.id, r.run.id))
            await shot("run", after: 3)
        }
        if let r = e.recordings.first {
            ws.open(.recording(e.id, r.rec.id))
            await shot("recording", after: 3)
        }
        ws.select(.assets(e.id))
        await shot("assets", after: 4)
        if env["TRICORDER_QUIT"] != nil { NSApp.terminate(nil) }
    }

    @MainActor
    static func render(_ ws: Workspace, to url: URL) {
        var page = AnyView(HomePage())
        if let route = ws.path.last {
            switch route {
            case .recording(let e, let id):
                if let env = ws.environment(e), let r = env.recording(id) { page = AnyView(RecordingView(env: env, record: r).pageContent) }
            case .run(let e, let id):
                if let env = ws.environment(e), let r = env.run(id) { page = AnyView(RunView(env: env, record: r).pageContent) }
            case .asset(let e, let id):
                if let env = ws.environment(e), let a = env.asset(id) { page = AnyView(AssetView(env: env, record: a).pageContent) }
            }
        } else if let sel = ws.selection, let env = ws.environment(sel.envId) {
            switch sel {
            case .environment: page = AnyView(EnvironmentView(record: env).pageContent)
            case .recordings: page = AnyView(RecordingsView(record: env).pageContent)
            case .runs: page = AnyView(RunsView(record: env).pageContent)
            case .assets: page = AnyView(AssetsView(record: env).pageContent)
            }
        }
        let renderer = ImageRenderer(content: page.environment(ws).tint(Theme.accent).frame(width: 1100).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        if let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
