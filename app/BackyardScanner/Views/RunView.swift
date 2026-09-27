import SwiftUI

struct RunView: View {
    @Environment(Workspace.self) private var ws
    let scan: ScanRecord
    let record: RunRecord

    @State private var stage = ""
    @State private var follow = true
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var stages: [(key: String, stage: Stage)] {
        ManifestStore.stageOrder.map { ($0, $0 == "frames" ? scan.scan.frames : record.run.stage($0)) }
    }
    private var running: Bool { record.isRunning }
    private var logURL: URL {
        stage == "frames" ? scan.dir.appending(path: "logs/frames.log") : record.dir.appending(path: "logs/\(stage).log")
    }

    var body: some View {
        ScrollView { pageContent }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("\(scan.scan.name) · \(record.run.id)")
        .navigationSubtitle(Format.settingsLine(record.run.settings))
        .toolbar { toolbarItems }
        .confirmationDialog("Cancel this run?", isPresented: $confirmCancel) {
            Button("Cancel Run", role: .destructive) { ws.cancelRun(record) }
        } message: {
            Text("The stage in progress stops; finished stages are kept.")
        }
        .confirmationDialog("Delete run \(record.run.id) and its files?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { Task { await ws.deleteRun(record) } }
        }
        .onAppear {
            if stage.isEmpty { stage = stages.last { $0.stage.status != .pending }?.key ?? "frames" }
        }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ForEach(Format.warnings(scan: scan.scan, run: record.run), id: \.self) { WarningBanner(text: $0) }
            StagesStrip(stages: stages, selected: $stage)
            LogView(title: ManifestStore.stageLabels[stage] ?? stage, url: logURL, live: running, follow: $follow)
            if record.prompts != nil { MeasurePanel(scan: scan, record: record) }
            if let t = record.transform { ScaleResultView(record: record, transform: t) }
            OutputsView(record: record)
        }
        .padding(28)
        .frame(maxWidth: 1180, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(scan.scan.name).font(Theme.display(30))
            Text("· \(record.run.id)").font(Theme.display(30)).foregroundStyle(Theme.accent)
            StatusPill(status: record.run.status)
            if !record.run.label.isEmpty { Text(record.run.label).foregroundStyle(.secondary) }
            Spacer()
            Text(Format.settingsLine(record.run.settings)).font(Theme.mono).foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if running {
                Button("Cancel", systemImage: "stop.fill") { confirmCancel = true }.help("Stop the pipeline")
            } else {
                Button("Run Again", systemImage: "play.fill") { Task { await ws.startRun(record) } }
                    .help("Execute again; finished stages are kept")
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

/// Five stage chips in one glass container; the selected one picks the log below.
struct StagesStrip: View {
    let stages: [(key: String, stage: Stage)]
    @Binding var selected: String

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(stages, id: \.key) { item in
                    let sel = item.key == selected
                    Button { selected = item.key } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ManifestStore.stageLabels[item.key] ?? item.key).font(.headline)
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

struct ScaleResultView: View {
    @Environment(Workspace.self) private var ws
    let record: RunRecord
    let transform: Transform

    var body: some View {
        Card("Scale result") {
            Text("scale \(String(format: "%.4f", transform.scale)) m per model unit · level from \(transform.ground?.description ?? "–") · north: \(transform.north?.description ?? "–")")
                .foregroundStyle(.secondary)
            if transform.warning == true {
                WarningBanner(text: "Measurements disagree by more than 3%; re-check them.")
            }
            if !transform.residuals.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    ForEach(transform.residuals) { r in
                        GridRow {
                            Text("\(r.id) \(r.kind)")
                            Text(String(format: "%.2f m", r.meters)).font(Theme.mono)
                            Text(String(format: "%@%.1f cm vs mean", r.residualCm >= 0 ? "+" : "", r.residualCm))
                                .font(Theme.mono)
                                .foregroundStyle(abs(r.residualCm) > 5 ? Theme.bad : .primary)
                        }
                    }
                }
            }
            if let plan = record.artifact("plan_grid.png") {
                let url = record.url(plan.path)
                FileImage(url: url, maxPixel: 2600)
                    .frame(maxHeight: 760)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .onTapGesture { ws.open(url) }
                    .help("Open in Preview")
                Text("Site plan at true scale (1 m grid). Trace it in QCAD, or open plan.blend.").font(.caption).foregroundStyle(.secondary)
            }
            if record.run.planVersions.count > 1, let last = record.run.planVersions.last {
                Text("\(record.run.planVersions.count) plan versions; latest \(Format.when(last["at"]?.string))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct OutputsView: View {
    @Environment(Workspace.self) private var ws
    let record: RunRecord

    var body: some View {
        Card("Outputs") {
            if record.artifacts.isEmpty {
                Text("nothing yet").foregroundStyle(.secondary)
            }
            ForEach(record.artifacts) { a in
                let url = record.url(a.path)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Button(a.label) { ws.open(url) }.buttonStyle(.link)
                        Text(a.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.size(a.size)).font(Theme.mono).foregroundStyle(.secondary)
                    Button("Reveal in Finder", systemImage: "folder") { ws.reveal(url) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.vertical, 3)
                Divider()
            }
            if record.artifact("plan_grid.png") == nil, let preview = record.artifact("preview_plan_grid.png") {
                FileImage(url: record.url(preview.path), maxPixel: 2600)
                    .frame(maxHeight: 700)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .onTapGesture { ws.open(record.url(preview.path)) }
                Text("Preview plan: levelled but unscaled. Answer the measurement prompts for real metres.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
