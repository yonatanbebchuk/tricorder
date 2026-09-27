import SwiftUI

struct ContentView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        @Bindable var ws = ws
        Group {
            if ws.root == nil {
                SetupView()
            } else {
                NavigationSplitView {
                    SidebarView(selection: $ws.selection)
                        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
                } detail: {
                    detail
                }
            }
        }
        .sheet(isPresented: $ws.showNewScan) {
            NewScanSheet(initialVideo: ws.pendingVideo)
        }
        .alert("Something went wrong", isPresented: Binding(get: { ws.lastError != nil }, set: { if !$0 { ws.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(ws.lastError ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch ws.selection {
        case .scan(let id):
            if let s = ws.scan(id) { ScanView(record: s).id(s.id) } else { missing }
        case .run(let sid, let rid):
            if let s = ws.scan(sid), let r = s.run(rid) { RunView(scan: s, record: r).id(r.id) } else { missing }
        case nil:
            WelcomeView()
        }
    }

    private var missing: some View {
        ContentUnavailableView("Gone", systemImage: "questionmark.folder", description: Text("That scan or run is no longer on disk."))
    }
}

struct WelcomeView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Video in, \(Text("backyard").italic().foregroundStyle(Theme.accent)) out.").font(Theme.display(38))
            Text("Each scan is one filmed walk. Runs are pipeline executions on that footage; the frames are shared, everything else is per run.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            HStack(spacing: 12) {
                Button("New Scan", systemImage: "plus") { ws.requestNewScan() }
                    .buttonStyle(.glassProminent)
                if let first = ws.scans.first {
                    Button("Open \(first.scan.name)", systemImage: "arrow.right") { ws.selection = .scan(first.id) }
                        .buttonStyle(.glass)
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            ws.requestNewScan(video: u)
            return true
        }
    }
}
