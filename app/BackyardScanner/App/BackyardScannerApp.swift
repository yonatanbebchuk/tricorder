import SwiftUI

@main
struct BackyardScannerApp: App {
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .tint(Theme.accent)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { DebugHooks.run(workspace) }
        }
        .defaultSize(width: 1360, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Scan…") { workspace.requestNewScan() }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await workspace.refresh() } }
                    .keyboardShortcut("r")
                Button("Show Project in Finder") { if let r = workspace.root { workspace.reveal(r) } }
            }
        }

        Settings {
            SettingsView()
                .environment(workspace)
                .tint(Theme.accent)
        }
    }
}
