import SceneKit
import SwiftUI

/// SCNScene is not Sendable; the box only carries it from the loader to the view that asked for it.
private struct SceneBox: @unchecked Sendable {
    let scene: SCNScene
}

/// Orbitable 3D view of a USDZ preview (the decimated, textured mesh the pipeline exports).
struct ModelViewer: View {
    let url: URL
    @State private var scene: SCNScene?
    @State private var failed = false

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
            } else {
                ProgressView("Loading 3D preview…").controlSize(.small)
            }
        }
        .task(id: url) {
            scene = nil; failed = false
            let u = url
            let box = await Task.detached(priority: .userInitiated) { () -> SceneBox? in
                guard let s = try? SCNScene(url: u, options: [.checkConsistency: false]) else { return nil }
                let ambient = SCNNode()
                ambient.light = SCNLight()
                ambient.light?.type = .ambient
                ambient.light?.intensity = 350
                s.rootNode.addChildNode(ambient)
                return SceneBox(scene: s)
            }.value
            if let box { scene = box.scene } else { failed = true }
        }
    }
}

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .clear
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
}
