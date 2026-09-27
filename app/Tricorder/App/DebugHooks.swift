import AppKit
import SwiftUI

/// Development-only hooks, all driven by environment variables so a normal launch is unaffected:
///   TRICORDER_SELECT=<env>[/recordings|/runs|/assets|/recording/<id>|/run/<id>|/asset/<id>]   navigate once loaded
///   TRICORDER_SMOKE=1                run `pipeline list` through the app's Process wrapper and print the result
///   TRICORDER_RENDER=<file.png>      after ~3 s, render the current page with ImageRenderer (AppKit-backed parts stay blank)
///   TRICORDER_QUIT=1                 quit after the render
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment

    @MainActor
    static func run(_ ws: Workspace) {
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

    @MainActor
    static func render(_ ws: Workspace, to url: URL) {
        var page = AnyView(HomeView().pageContent)
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
