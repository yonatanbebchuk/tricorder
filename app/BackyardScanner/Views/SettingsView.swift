import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Folder") {
                    Text(ws.root?.path ?? "not set").textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change…") { choose() }
                    if let r = ws.root { Button("Show in Finder") { ws.reveal(r) } }
                }
            }
            Section("Tools") {
                row("COLMAP", ws.health.colmap, "brew install colmap")
                row("OpenMVS", ws.health.openmvs, "./setup.sh builds it into tools/")
                row("Blender", ws.health.blender, Pipeline.blender.path)
                row("Python env", ws.health.python, ".venv/bin/python")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func row(_ name: String, _ ok: Bool, _ hint: String) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Theme.ok : Theme.bad)
                Text(ok ? "found" : hint).foregroundStyle(.secondary)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { ws.setRoot(url) }
    }
}
