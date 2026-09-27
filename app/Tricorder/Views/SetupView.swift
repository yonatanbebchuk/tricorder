import AppKit
import SwiftUI

/// Shown until the app knows where the backyard-scanner checkout (python env, scripts, work/) lives.
struct SetupView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(Text("Tricorder").italic().foregroundStyle(Theme.accent))").font(Theme.display(38))
            Text("Point the app at your tricorder checkout: the folder with tricorder/, scripts/, work/ and the .venv that ./setup.sh created. The app reads the environment manifests there and runs the pipeline through that Python environment.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560, alignment: .leading)
            Button("Choose Project Folder…", systemImage: "folder") { choose() }
                .buttonStyle(.glassProminent)
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
