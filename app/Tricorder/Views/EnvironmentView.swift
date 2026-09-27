import SwiftUI

/// The environment page: what it currently is (assets), how it got there (runs), and what was sensed (recordings).
struct EnvironmentView: View {
    @Environment(Workspace.self) private var ws
    let record: EnvironmentRecord

    @State private var name: String
    @State private var notes: String
    @FocusState private var nameFocused: Bool
    @State private var confirmDelete = false

    init(record: EnvironmentRecord) {
        self.record = record
        _name = State(initialValue: record.env.name)
        _notes = State(initialValue: record.env.notes)
    }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(record.env.name)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add Recording", systemImage: "video.badge.plus") { ws.requestNewRecording(env: record.id) }
                    Button("New Run", systemImage: "play.fill") { ws.requestNewRun(env: record.id) }
                        .disabled(record.recordings.isEmpty)
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        Button("Rename…") { nameFocused = true }
                        Divider()
                        Button("Delete Environment…", role: .destructive) { confirmDelete = true }.disabled(record.isBusy)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete “\(record.env.name)” with all its recordings, runs and assets?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteEnvironment(record) } }
            } message: {
                Text("The environment folder is moved to the Trash.")
            }
            .onChange(of: record.env.name) { _, new in if !nameFocused { name = new } }
            .onChange(of: nameFocused) { _, f in if !f { commitName() } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
                ws.requestNewRecording(env: record.id, video: u)
                return true
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            currentAssets
            runs
            recordings
            notesCard
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Environment name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.display(32))
                    .focused($nameFocused)
                    .onSubmit { commitName(); nameFocused = false }
                    .help("Click to rename")
                Image(systemName: "pencil").font(.callout).foregroundStyle(.tertiary)
                Spacer()
                if record.isBusy { ProgressView().controlSize(.small) }
            }
            Text("created \(Format.when(record.env.createdAt)) · \(record.recordings.count) recordings · \(record.runs.count) runs · \(record.assets.count) assets")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func commitName() {
        Task { await ws.rename(record, to: name) }
    }

    private var currentAssets: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Current assets", subtitle: "the newest of each kind") {
                Button("All assets", systemImage: "shippingbox") { ws.select(.assets(record.id)) }.buttonStyle(.borderless)
            }
            if record.currentAssets.isEmpty {
                Card("") {
                    Text(record.recordings.isEmpty ? "No assets yet. Add a recording of the site, then reconstruct it."
                                                    : "No assets yet. Reconstruct a recording to get the first 3D scan.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if record.recordings.isEmpty {
                            Button("Add Recording…", systemImage: "video.badge.plus") { ws.requestNewRecording(env: record.id) }.buttonStyle(.glassProminent)
                        } else {
                            Button("Reconstruct…", systemImage: "play.fill") { ws.requestNewRun(env: record.id) }.buttonStyle(.glassProminent)
                        }
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(record.currentAssets) { a in AssetShowcase(env: record, record: a) }
                }
            }
        }
    }

    private var runs: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Runs", subtitle: "every processing job, newest first, each linked to the asset it made") {
                Button("New Run…", systemImage: "play.fill") { ws.requestNewRun(env: record.id) }.buttonStyle(.borderless).disabled(record.recordings.isEmpty)
            }
            Card("") { RunsTable(env: record, runs: record.runs.reversed()) }
        }
    }

    private var recordings: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Recordings", subtitle: "the raw data that was sensed") {
                Button("Add Recording…", systemImage: "video.badge.plus") { ws.requestNewRecording(env: record.id) }.buttonStyle(.borderless)
            }
            Card("") { RecordingRows(env: record, recordings: record.recordings) }
        }
    }

    private var notesCard: some View {
        Card("Notes") {
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(notes != record.env.notes ? "Save Notes" : "Saved") { Task { await ws.saveNotes(environment: record, notes) } }
                    .disabled(notes == record.env.notes)
            }
        }
        .onChange(of: record.env.notes) { old, new in if notes == old { notes = new } }
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.display(22))
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            Spacer()
            trailing
        }
    }
}

/// A large card for a current asset: the 3D viewer for scans, the plan image for plans.
struct AssetShowcase: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: AssetRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if record.asset.kind == .scan3d, let preview = record.preview {
                    ModelViewer(url: preview)
                } else if let img = record.planImage {
                    FileImage(url: img, maxPixel: 1600).padding(10)
                } else {
                    Rectangle().fill(.quaternary).overlay { Text("no rendering yet").foregroundStyle(.secondary) }
                }
            }
            .frame(height: 360)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipped()
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: record.asset.kind.symbol).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.asset.name).font(.headline)
                    Text(Format.assetTiles(record.asset).map { "\($0.0) \($0.1)" }.joined(separator: " · ") + " · \(Format.when(record.asset.createdAt))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Open", systemImage: "arrow.right") { ws.open(.asset(env.id, record.asset.id)) }.buttonStyle(.glass)
            }
            .padding(14)
        }
        .frame(maxWidth: 620)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
    }
}

/// Runs as a table; a click opens the run, the output column opens its asset.
struct RunsTable: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let runs: [RunRecord]
    @State private var selected: RunRecord.ID?

    var body: some View {
        if runs.isEmpty {
            Text("No runs yet.").foregroundStyle(.secondary)
        } else {
            Table(runs, selection: $selected) {
                TableColumn("Run") { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.run.id).fontWeight(.semibold)
                        if !r.run.label.isEmpty { Text(r.run.label).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .width(min: 50, ideal: 90)
                TableColumn("Kind") { r in Text(r.run.kind.label) }.width(min: 110, ideal: 130)
                TableColumn("Input") { r in Text(env.inputName(of: r.run)).lineLimit(1) }.width(min: 120, ideal: 170)
                TableColumn("Status") { r in
                    HStack(spacing: 6) {
                        StatusPill(status: r.run.status)
                        StageDots(run: r.run)
                        if r.isRunning { ProgressView().controlSize(.mini) }
                    }
                }
                .width(min: 120, ideal: 150)
                TableColumn("Output") { r in
                    if let a = r.run.outputAsset {
                        Button(env.asset(a)?.asset.name ?? a) { ws.open(.asset(env.id, a)) }.buttonStyle(.link)
                    } else {
                        Text("–").foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 160)
                TableColumn("Settings") { r in Text(Format.settingsLine(r.run)).font(Theme.mono).foregroundStyle(.secondary).lineLimit(1) }
                TableColumn("Created") { r in Text(Format.when(r.run.createdAt)).foregroundStyle(.secondary) }.width(min: 100, ideal: 120)
            }
            .frame(height: CGFloat(runs.count) * 44 + 34)
            .onChange(of: selected) { _, id in
                if let id, let r = runs.first(where: { $0.id == id }) { ws.open(.run(env.id, r.run.id)); selected = nil }
            }
        }
    }
}

/// Recordings as rows with a frame thumbnail; a click opens the recording.
struct RecordingRows: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let recordings: [RecordingRecord]

    var body: some View {
        if recordings.isEmpty {
            Text("No recordings yet. Film a slow walk of the site and drop the video here.").foregroundStyle(.secondary)
        } else {
            ForEach(recordings) { r in
                Button { ws.open(.recording(env.id, r.rec.id)) } label: {
                    HStack(spacing: 14) {
                        Group {
                            if let t = r.thumbnail {
                                FileImage(url: t, maxPixel: 400).aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(.quaternary).overlay { Image(systemName: "video").foregroundStyle(.secondary) }
                            }
                        }
                        .frame(width: 96, height: 64).clipShape(RoundedRectangle(cornerRadius: 6)).clipped()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.rec.name).font(.headline)
                            Text("\(r.rec.source.fileName) · \(Format.videoLine(r.rec.source))").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                StatusPill(status: r.rec.frames.status, compact: true)
                                Text(Format.stageMetrics("frames", r.rec.frames.metrics)).font(.caption).foregroundStyle(.secondary)
                                Text("· used by \(env.runsUsing(recording: r.rec.id).count) run\(env.runsUsing(recording: r.rec.id).count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text(Format.when(r.rec.createdAt)).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if r.id != recordings.last?.id { Divider() }
            }
        }
    }
}
