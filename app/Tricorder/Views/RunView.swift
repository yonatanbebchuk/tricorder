import SwiftUI

struct RunView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RunRecord

    @State private var stage = ""
    @State private var follow = true
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var run: Run { record.run }
    private var inputRecording: RecordingRecord? { run.inputRecordingId.flatMap { env.recording($0) } }
    private var inputAsset: AssetRecord? { run.inputAssetId.flatMap { env.asset($0) } }
    private var outputAsset: AssetRecord? { run.outputAsset.flatMap { env.asset($0) } }

    private var stages: [(key: String, stage: Stage)] {
        var s: [(String, Stage)] = []
        if run.kind == .reconstruct, let r = inputRecording { s.append(("frames", r.rec.frames)) }
        s += run.kind.stages.map { ($0, run.stage($0)) }
        return s
    }
    private var running: Bool { record.isRunning }
    private var logURL: URL {
        if stage == "frames", let r = inputRecording { return r.dir.appending(path: "logs/frames.log") }
        return record.dir.appending(path: "logs/\(stage).log")
    }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("\(run.kind.label) · \(run.id)")
            .navigationSubtitle(Format.settingsLine(run))
            .toolbar { toolbarItems }
            .confirmationDialog("Cancel this run?", isPresented: $confirmCancel) {
                Button("Cancel Run", role: .destructive) { ws.cancelRun(record) }
            } message: {
                Text("The stage in progress stops; finished stages are kept.")
            }
            .confirmationDialog("Delete run \(run.id) and its working files?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteRun(record) } }
            } message: {
                Text(run.outputAsset != nil ? "The asset it published stays." : "")
            }
            .onAppear {
                if stage.isEmpty { stage = stages.last { $0.stage.status != .pending }?.key ?? stages.first?.key ?? "" }
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            flow
            ForEach(Format.warnings(recording: inputRecording?.rec, run: run), id: \.self) { WarningBanner(text: $0) }
            StagesStrip(stages: stages, selected: $stage)
            LogView(title: ManifestStore.stageLabels[stage] ?? stage, url: logURL, live: running, follow: $follow)
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(run.kind.label).font(Theme.display(30))
            Text("· \(run.id)").font(Theme.display(30)).foregroundStyle(Theme.accent)
            StatusPill(status: run.status)
            if !run.label.isEmpty { Text(run.label).foregroundStyle(.secondary) }
            Spacer()
            Text(Format.settingsLine(run)).font(Theme.mono).foregroundStyle(.secondary)
        }
    }

    /// input → run → output, each end a link.
    private var flow: some View {
        Card("") {
            HStack(spacing: 14) {
                flowNode(symbol: run.kind == .reconstruct ? "video" : "cube.transparent", title: run.kind == .reconstruct ? "Recording" : "3D scan",
                         name: env.inputName(of: run)) {
                    if let r = inputRecording { ws.open(.recording(env.id, r.rec.id)) }
                    else if let a = inputAsset { ws.open(.asset(env.id, a.asset.id)) }
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    Text(run.kind.label).font(.headline)
                    Text("created \(Format.when(run.createdAt))" + (run.startedAt != nil ? " · started \(Format.clock(run.startedAt))" : "")
                         + (Format.duration(totalDuration).isEmpty ? "" : " · \(Format.duration(totalDuration))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                if let a = outputAsset {
                    flowNode(symbol: a.asset.kind.symbol, title: a.asset.kind.label, name: a.asset.name) { ws.open(.asset(env.id, a.asset.id)) }
                } else {
                    flowNode(symbol: run.kind.outputKind.symbol, title: run.kind.outputKind.label, name: running ? "in progress…" : "not published", action: nil)
                }
            }
        }
    }

    private var totalDuration: Double? {
        guard let a = Format.parse(run.startedAt) else { return nil }
        let b = Format.parse(run.finishedAt) ?? (running ? Date() : nil)
        return b.map { $0.timeIntervalSince(a) }
    }

    private func flowNode(symbol: String, title: String, name: String, action: (() -> Void)?) -> some View {
        Group {
            if let action {
                Button(action: action) { flowLabel(symbol, title, name) }.buttonStyle(.plain)
            } else {
                flowLabel(symbol, title, name).opacity(0.6)
            }
        }
        .padding(12)
        .frame(minWidth: 220, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func flowLabel(_ symbol: String, _ title: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(name).font(.headline).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if running {
                Button("Cancel", systemImage: "stop.fill") { confirmCancel = true }.help("Stop the pipeline")
            } else {
                Button("Run Again", systemImage: "play.fill") { Task { await ws.startRun(record) } }
                    .help("Execute again; finished stages are kept, the asset is re-published")
            }
            Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
            Menu {
                Button("Delete Run…", role: .destructive) { confirmDelete = true }.disabled(running)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Stage chips in one glass container; the selected one picks the log below.
struct StagesStrip: View {
    let stages: [(key: String, stage: Stage)]
    @Binding var selected: String

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(stages.enumerated()), id: \.element.key) { i, item in
                    let sel = item.key == selected
                    Button { selected = item.key } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(i + 1) · \(ManifestStore.stageLabels[item.key] ?? item.key)").font(.headline)
                                Spacer()
                                StatusPill(status: item.stage.status, compact: true)
                            }
                            Text([Format.clock(item.stage.startedAt), Format.duration(item.stage.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(Format.stageMetrics(item.key, item.stage.metrics)).font(.caption).lineLimit(2)
                            if item.stage.status == .failed, let e = item.stage.error {
                                Text(e).font(.caption2).foregroundStyle(Theme.bad).lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(sel ? .regular.tint(Theme.accent.opacity(0.3)).interactive() : .regular.interactive(),
                                 in: .rect(cornerRadius: 14))
                }
            }
        }
    }
}
