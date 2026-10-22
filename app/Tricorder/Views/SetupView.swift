import AppKit
import SwiftUI

/// Shown until the app knows where the pipeline runs: this Mac's Tricorder checkout (python env, scripts, work/), or
/// another Mac on the tailnet reached over SSH.
struct SetupView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(Text("Tricorder").italic().foregroundStyle(Theme.accent))").font(Theme.display(38))
            Text("Where does the pipeline run? On this Mac: point the app at your tricorder checkout, the folder with tricorder/, scripts/, work/ and the .venv that ./setup.sh created. On another Mac: name it and the app shows its environments here and sends it the work over SSH.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620, alignment: .leading)
            HStack(spacing: 12) {
                Button("Choose Project Folder…", systemImage: "folder") { choose() }
                    .buttonStyle(.glassProminent)
                Button("Use Another Mac…", systemImage: "network") { SettingsLink.open() }
                    .buttonStyle(.glass)
            }
            .padding(.top, 6)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Select the tricorder checkout"
        if panel.runModal() == .OK, let url = panel.url { ws.setRoot(url) }
    }
}

enum SettingsLink {
    /// Open the app's Settings window (the Compute section is on it).
    @MainActor static func open() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
