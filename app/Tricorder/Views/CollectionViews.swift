import SwiftUI

struct RecordingsView: View {
    @Environment(Workspace.self) private var ws
    let record: EnvironmentRecord

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Recordings")
            .navigationSubtitle(record.env.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Recording", systemImage: "video.badge.plus") { ws.requestNewRecording(env: record.id) }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
                ws.requestNewRecording(env: record.id, video: u)
                return true
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Recordings", env: record, lead: "Raw data: each recording is one filmed walk. Frames are extracted once and shared by every run on it.")
            Card("") { RecordingRows(env: record, recordings: record.recordings) }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }
}

struct RunsView: View {
    @Environment(Workspace.self) private var ws
    let record: EnvironmentRecord

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Runs")
            .navigationSubtitle(record.env.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Run", systemImage: "play.fill") { ws.requestNewRun(env: record.id) }.disabled(record.recordings.isEmpty)
                }
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Runs", env: record, lead: "Processing jobs. An environment scan turns a recording into a 3D model; a layout turns a measured 3D model into a site plan. Each run publishes one asset.")
            Card("") { RunsTable(env: record, runs: record.runs.reversed()) }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }
}

struct AssetsView: View {
    @Environment(Workspace.self) private var ws
    let record: EnvironmentRecord

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("Assets")
            .navigationSubtitle(record.env.name)
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(title: "Assets", env: record, lead: "What the runs produced. The newest of each kind is current; everything older is kept as history.")
            if record.assets.isEmpty {
                Card("") { Text("No assets yet.").foregroundStyle(.secondary) }
            }
            if !record.currentAssets.isEmpty {
                SectionTitle(title: "Current") { EmptyView() }
                HStack(alignment: .top, spacing: 18) {
                    ForEach(record.currentAssets) { a in AssetShowcase(env: record, record: a) }
                }
            }
            if !record.historicalAssets.isEmpty {
                SectionTitle(title: "History", subtitle: "superseded by a newer asset of the same kind") { EmptyView() }
                Card("") { AssetRows(env: record, assets: record.historicalAssets) }
            }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }
}

struct PageHeader: View {
    let title: String
    let env: EnvironmentRecord
    let lead: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.display(32))
                Text(env.env.name).font(Theme.display(22)).foregroundStyle(Theme.accent).italic()
            }
            Text(lead).foregroundStyle(.secondary).frame(maxWidth: 720, alignment: .leading)
        }
    }
}

/// Compact asset rows (history lists, derived plans).
struct AssetRows: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let assets: [AssetRecord]

    var body: some View {
        ForEach(assets) { a in
            Button { ws.open(.asset(env.id, a.asset.id)) } label: {
                HStack(spacing: 14) {
                    Group {
                        if let t = a.thumbnail {
                            FileImage(url: t, maxPixel: 400).aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary).overlay { Image(systemName: a.asset.kind.symbol).foregroundStyle(.secondary) }
                        }
                    }
                    .frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 6)).clipped()
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(a.asset.name).font(.headline)
                            Text(a.asset.kind.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(Format.assetTiles(a.asset).map { "\($0.0) \($0.1)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        Text("from run \(a.asset.runId)" + (env.run(a.asset.runId).map { " · \(env.inputName(of: $0.run))" } ?? "")).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(Format.when(a.asset.createdAt)).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if a.id != assets.last?.id { Divider() }
        }
    }
}
