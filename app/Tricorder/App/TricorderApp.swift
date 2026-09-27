import SwiftUI

@main
struct TricorderApp: App {
    @State private var workspace = Workspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(workspace)
                .tint(Theme.accent)
                .frame(minWidth: 1000, minHeight: 660)
                .onAppear { DebugHooks.run(workspace) }
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Environment…") { workspace.requestNewEnvironment() }
                    .keyboardShortcut("n")
                Button("Add Recording…") { if let e = workspace.selectedEnvironment { workspace.requestNewRecording(env: e.id) } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(workspace.selectedEnvironment == nil)
                Button("New Run…") { if let e = workspace.selectedEnvironment { workspace.requestNewRun(env: e.id) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(workspace.selectedEnvironment == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Home") { workspace.goHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
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
