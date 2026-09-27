import SceneKit
import SwiftUI

/// SCNScene is not Sendable; the box only carries it from the loader to the main actor.
private struct SceneBox: @unchecked Sendable {
    let scene: SCNScene
}

/// One decoded scene per file, shared by every viewer that shows it.  Loading a preview decodes its textures
/// (tens of MB each) and uploads them to the GPU; doing that once per page visit is what makes a viewer heavy.
@MainActor
enum SceneCache {
    static let maxPreviewBytes = 400 << 20
    private static var scenes: [String: SCNScene] = [:]
    private static var loading: [String: Task<SceneBox?, Never>] = [:]

    static func key(_ url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)@\(mtime)"
    }

    static func scene(for url: URL) async -> SCNScene? {
        let k = key(url)
        if let s = scenes[k] { return s }
        if loading[k] == nil {
            loading[k] = Task.detached(priority: .userInitiated) { () -> SceneBox? in
                guard let s = try? SCNScene(url: url, options: [.checkConsistency: false]) else { return nil }
                let ambient = SCNNode()
                ambient.light = SCNLight()
                ambient.light?.type = .ambient
                ambient.light?.intensity = 350
                s.rootNode.addChildNode(ambient)
                return SceneBox(scene: s)
            }
        }
        let box = await loading[k]?.value
        loading[k] = nil
        if let box {
            if scenes.count >= 3, let oldest = scenes.keys.first { scenes[oldest] = nil }   // a few previews at most in memory
            scenes[k] = box.scene
            return box.scene
        }
        return nil
    }
}

/// Orbitable 3D view of a USDZ preview (the decimated, textured mesh the pipeline exports).
struct ModelViewer: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var failed = false
    @State private var tooBig = false
    @State private var wanted = false

    private var size: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let scene {
                SceneKitView(scene: scene)
                Text("drag to orbit · scroll to zoom · ⌥ drag to pan")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .glassEffect()
                    .padding(8)
            } else if failed {
                ContentUnavailableView("Preview didn’t load", systemImage: "cube.transparent", description: Text(url.lastPathComponent))
            } else if tooBig && !wanted {
                ContentUnavailableView {
                    Label("Large preview (\(Format.size(size)))", systemImage: "cube.transparent")
                } description: {
                    Text("Loading it takes a lot of memory. Re-run the preview stage for a lighter one, or load it anyway.")
                } actions: {
                    Button("Load Anyway") { wanted = true }
                    Button("Open in Preview") { NSWorkspace.shared.open(url) }
                }
            } else {
                ProgressView("Loading 3D preview…").controlSize(.small)
            }
        }
        .task(id: SceneCache.key(url) + (wanted ? "!" : "")) {
            scene = nil; failed = false
            tooBig = size > SceneCache.maxPreviewBytes
            if tooBig && !wanted { return }
            if let s = await SceneCache.scene(for: url) { scene = s } else { failed = true }
        }
    }
}

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling2X
        v.backgroundColor = .clear
        v.rendersContinuously = false
        v.preferredFramesPerSecond = 60
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        if v.scene !== scene {
            v.scene = scene
            v.pointOfView = nil     // let SceneKit frame the model with its default camera
        }
    }

    static func dismantleNSView(_ v: SCNView, coordinator: ()) {
        v.scene = nil               // drop the GPU resources of a page that went away
    }
}
