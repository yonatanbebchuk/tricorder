import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(Workspace.self) private var ws
    @State private var updating = false
    @State private var updateVerdict = ""

    var body: some View {
        Form {
            ComputeSection()
            Section(ws.remote == nil ? "Tools" : "Tools on \(ws.remote!.label)") {
                if ws.remote != nil {
                    row("Reachable", ws.health.reachable, "SSH did not answer: is Tailscale on, on both ends?")
                    LabeledContent("Checkout") {
                        HStack(spacing: 8) {
                            Text(ws.health.revision.isEmpty ? "unknown revision" : "at \(ws.health.revision)" + (ws.remoteNeedsUpdate ? ", older than this app expects" : ""))
                                .foregroundStyle(ws.remoteNeedsUpdate ? Theme.bad : .secondary)
                            Button(updating ? "Updating…" : "Update from GitHub") { update() }.disabled(updating || !ws.health.reachable)
                        }
                    }
                    if !updateVerdict.isEmpty { Text(updateVerdict).font(.caption).foregroundStyle(.secondary) }
                }
                row("COLMAP", ws.health.colmap, "brew install colmap")
                row("OpenMVS", ws.health.openmvs, "./setup.sh builds it into tools/")
                row("Blender", ws.health.blender, Pipeline.blender.path)
                row("Python env", ws.health.python, ".venv/bin/python")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private func update() {
        updating = true
        Task {
            updateVerdict = await ws.updateRemote()
            updating = false
        }
    }

    private func row(_ name: String, _ ok: Bool, _ hint: String) -> some View {
        LabeledContent(name) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? Theme.ok : Theme.bad)
                Text(ok ? "found" : hint).foregroundStyle(.secondary)
            }
        }
    }
}

/// Where the pipeline runs: this Mac's checkout, or another Mac over SSH (its record is mirrored here).
struct ComputeSection: View {
    @Environment(Workspace.self) private var ws

    enum Mode: String, CaseIterable, Identifiable { case local, remote; var id: String { rawValue } }
    @State private var mode: Mode = .local
    @State private var host = ""
    @State private var user = NSUserName()
    @State private var path = "/Users/\(NSUserName())/Projects/tricorder"
    @State private var testing = false
    @State private var verdict = ""

    var body: some View {
        Section("Compute") {
            Picker("Run the pipeline on", selection: $mode) {
                Text("This Mac").tag(Mode.local)
                Text("Another Mac over SSH").tag(Mode.remote)
            }
            .pickerStyle(.segmented)
            switch mode {
            case .local:
                LabeledContent("Checkout") {
                    Text(ws.remote == nil ? (ws.root?.path ?? "not set") : "not set").textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder…") { chooseLocal() }
                    if ws.remote == nil, let r = ws.root { Button("Show in Finder") { ws.reveal(r) } }
                }
            case .remote:
                TextField("Host", text: $host, prompt: Text("macmini, or macmini.tail0ceb9f.ts.net"))
                TextField("User", text: $user)
                TextField("Checkout on that Mac", text: $path)
                HStack {
                    Button(testing ? "Testing…" : "Test") { test() }.disabled(host.isEmpty || testing)
                    Button("Use This Mac") { ws.setRemote(current) }.buttonStyle(.borderedProminent).disabled(host.isEmpty)
                    if let m = ws.remote?.mirror, ws.remote != nil { Button("Show Mirror") { ws.reveal(m) } }
                }
                if !verdict.isEmpty { Text(verdict).font(.caption).foregroundStyle(.secondary) }
                Text("Runs are launched detached on that Mac and keep going when this app or this Mac sleeps. The app keeps a mirror of its environments here: manifests, logs, previews, site-plan files and frames; the dense clouds, meshes, COLMAP databases and videos stay there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { load() }
        .onChange(of: ws.compute) { load() }
    }

    private var current: RemoteHost { RemoteHost(host: host.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces), path: path.trimmingCharacters(in: .whitespaces)) }

    private func load() {
        if let h = ws.remote {
            mode = .remote; host = h.host; user = h.user; path = h.path
        } else {
            mode = .local
        }
    }

    private func test() {
        testing = true
        verdict = ""
        Task {
            verdict = await ws.testRemote(current)
            testing = false
        }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { ws.setRoot(url) }
    }
}
