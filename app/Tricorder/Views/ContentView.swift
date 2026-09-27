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
                    SidebarView(selection: Binding(get: { ws.selection }, set: { s in if let s { ws.select(s) } else { ws.goHome() } }))
                        .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
                } detail: {
                    NavigationStack(path: $ws.path) {
                        rootDetail
                            .navigationDestination(for: Route.self) { route in routeView(route) }
                    }
                }
            }
        }
        .sheet(isPresented: $ws.showNewEnvironment) { NewEnvironmentSheet(initialVideo: ws.pendingVideo) }
        .sheet(item: $ws.newRecordingFor) { ref in NewRecordingSheet(envId: ref.id, initialVideo: ws.pendingVideo) }
        .sheet(item: $ws.newRunRequest) { req in NewRunSheet(request: req) }
        .alert("Something went wrong", isPresented: Binding(get: { ws.lastError != nil }, set: { if !$0 { ws.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(ws.lastError ?? "")
        }
    }

    @ViewBuilder private var rootDetail: some View {
        switch ws.selection {
        case nil:
            HomeView()
        case .environment(let id):
            if let e = ws.environment(id) { EnvironmentView(record: e).id(e.id) } else { missing }
        case .recordings(let id):
            if let e = ws.environment(id) { RecordingsView(record: e).id(e.id) } else { missing }
        case .runs(let id):
            if let e = ws.environment(id) { RunsView(record: e).id(e.id) } else { missing }
        case .assets(let id):
            if let e = ws.environment(id) { AssetsView(record: e).id(e.id) } else { missing }
        }
    }

    @ViewBuilder private func routeView(_ route: Route) -> some View {
        switch route {
        case .recording(let e, let id):
            if let env = ws.environment(e), let r = env.recording(id) { RecordingView(env: env, record: r).id(r.id) } else { missing }
        case .run(let e, let id):
            if let env = ws.environment(e), let r = env.run(id) { RunView(env: env, record: r).id(r.id) } else { missing }
        case .asset(let e, let id):
            if let env = ws.environment(e), let a = env.asset(id) { AssetView(env: env, record: a).id(a.id) } else { missing }
        }
    }

    private var missing: some View {
        ContentUnavailableView("Gone", systemImage: "questionmark.folder", description: Text("That item is no longer on disk."))
    }
}

/// The home page: every environment as a card.
struct HomeView: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        ScrollView { HomePage() }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("Tricorder")
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            ws.requestNewEnvironment(video: u)
            return true
        }
    }

}

/// The home page content; a separate view so it can be rendered on its own.
struct HomePage: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                Text("Record it, \(Text("reconstruct").italic().foregroundStyle(Theme.accent)) it, plan it.").font(Theme.display(38))
                Text("An environment is a place you scan. Its recordings are the raw footage, runs turn them into assets, and every asset stays in the history.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 640, alignment: .leading)
                Button("New Environment", systemImage: "plus") { ws.requestNewEnvironment() }
                    .buttonStyle(.glassProminent)
                if ws.environments.isEmpty {
                    Text("Nothing here yet. Drop an iPhone video anywhere in this window to start.").foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 360), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(ws.environments) { env in EnvironmentCard(record: env) }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(36)
            .frame(maxWidth: 1300, alignment: .leading)
    }
}

struct EnvironmentCard: View {
    @Environment(Workspace.self) private var ws
    let record: EnvironmentRecord

    var body: some View {
        Button { ws.select(.environment(record.id)) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let t = record.thumbnail {
                        FileImage(url: t, maxPixel: 900).aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary).overlay { Image(systemName: "viewfinder").font(.largeTitle).foregroundStyle(.tertiary) }
                    }
                }
                .frame(height: 170)
                .clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(record.env.name).font(Theme.display(20)).lineLimit(1)
                        Spacer()
                        if record.isBusy { ProgressView().controlSize(.small) }
                    }
                    Text("\(record.recordings.count) recording\(record.recordings.count == 1 ? "" : "s") · \(record.runs.count) run\(record.runs.count == 1 ? "" : "s") · \(record.assets.count) asset\(record.assets.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    if let a = record.currentAssets.last {
                        Text("latest: \(a.asset.name) · \(Format.when(a.asset.createdAt))").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(14)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
