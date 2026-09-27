import SwiftUI

struct SidebarView: View {
    @Environment(Workspace.self) private var ws
    @Binding var selection: Selection?
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(ws.environments) { env in
                EnvironmentRow(record: env, collapsed: collapsed.contains(env.id)) { toggle(env.id) }
                    .tag(Selection.environment(env.id))
                if !collapsed.contains(env.id) {
                    SubRow(title: "Recordings", symbol: "video", count: env.recordings.count, busy: env.recordings.contains { $0.isBusy })
                        .tag(Selection.recordings(env.id))
                    SubRow(title: "Runs", symbol: "gearshape.2", count: env.runs.count, busy: env.runs.contains { $0.isRunning })
                        .tag(Selection.runs(env.id))
                    SubRow(title: "Assets", symbol: "shippingbox", count: env.assets.count, busy: false)
                        .tag(Selection.assets(env.id))
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Environments")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "house") { ws.goHome() }.help("Home (⌘⇧H)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Environment", systemImage: "plus") { ws.requestNewEnvironment() }.help("New environment (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack { HealthBar(health: ws.health); Spacer() }.padding(10)
        }
        .overlay {
            if ws.environments.isEmpty {
                ContentUnavailableView {
                    Label("No environments", systemImage: "viewfinder")
                } description: {
                    Text("Drop an iPhone video here, or press ⌘N.")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            ws.requestNewEnvironment(video: u)
            return true
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

struct EnvironmentRow: View {
    let record: EnvironmentRecord
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(collapsed ? .zero : .degrees(90))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            Group {
                if let t = record.thumbnail {
                    FileImage(url: t, maxPixel: 200).aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).overlay { Image(systemName: "viewfinder").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 48, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.env.name).fontWeight(.medium).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.isBusy { ProgressView().controlSize(.mini) }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        if let a = record.currentAssets.last { return "\(a.asset.kind.label) · \(Format.when(a.asset.createdAt))" }
        if let r = record.recordings.first { return "\(r.rec.name) · frames \(r.rec.frames.status.rawValue)" }
        return Format.when(record.env.createdAt)
    }
}

struct SubRow: View {
    let title: String
    let symbol: String
    let count: Int
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(title)
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .padding(.leading, 24)
        .padding(.vertical, 1)
    }
}
