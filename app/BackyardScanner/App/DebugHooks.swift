import AppKit
import SwiftUI

/// Development-only hooks, all driven by environment variables so a normal launch is unaffected:
///   BACKYARD_SELECT=<scan>[/<run>]   select that scan or run once the manifests are loaded
///   BACKYARD_SMOKE=1                 run `pipeline list` through the app's Process wrapper and print the result
///   BACKYARD_RENDER=<file.png>       after ~3 s, render the selected page with ImageRenderer (AppKit-backed parts stay blank)
///   BACKYARD_QUIT=1                  quit after the render
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment

    @MainActor
    static func run(_ ws: Workspace) {
        if let sel = env["BACKYARD_SELECT"] {
            Task {
                await ws.refresh()
                let parts = sel.split(separator: "/").map(String.init)
                ws.selection = parts.count == 2 ? .run(parts[0], parts[1]) : .scan(sel)
            }
        }
        if env["BACKYARD_SMOKE"] != nil, let root = ws.root {
            Task {
                do { FileHandle.standardError.write(Data("smoke ok:\n\(try await Pipeline.run(root: root, ["list"]))".utf8)) }
                catch { FileHandle.standardError.write(Data("smoke failed: \(error)\n".utf8)) }
            }
        }
        if let path = env["BACKYARD_RENDER"] {
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                render(ws, to: URL(filePath: path))
                if env["BACKYARD_QUIT"] != nil { NSApp.terminate(nil) }
            }
        }
    }

    @MainActor
    static func render(_ ws: Workspace, to url: URL) {
        let page: AnyView
        switch ws.selection {
        case .scan(let id):
            guard let s = ws.scan(id) else { return }
            page = AnyView(ScanView(record: s).pageContent)
        case .run(let sid, let rid):
            guard let s = ws.scan(sid), let r = s.run(rid) else { return }
            page = AnyView(RunView(scan: s, record: r).pageContent)
        case nil:
            page = AnyView(WelcomeView())
        }
        let renderer = ImageRenderer(content: page.environment(ws).tint(Theme.accent).frame(width: 1100).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        if let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
