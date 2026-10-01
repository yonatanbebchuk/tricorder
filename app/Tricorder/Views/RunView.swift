import SwiftUI

/// One step of a run's pipeline as the page shows it: the frames stage of each footage recording first, then the
/// run's own stages. Carries where its log, preview and outputs live.
struct PipelineStep: Identifiable, Hashable {
    let key: String                 // "frames:rec1" | "sfm" | …
    let name: String                // the stage name inside its owner's manifest
    let label: String
    let blurb: String
    let stage: Stage
    let baseDir: URL                // the run dir, or the recording dir for a frames step
    let expected: Double            // seconds, for the progress bar
    var fallbackPreview: URL? = nil // a picture to show when the stage wrote none (a recording's thumbnail)
    var id: String { key }
    var logURL: URL { baseDir.appending(path: stage.log ?? "logs/\(name).log") }
    var previewURL: URL? {
        guard stage.status == .done else { return nil }
        if let p = stage.preview, let u = ManifestStore.existing(baseDir.appending(path: p)) { return u }
        return fallbackPreview.flatMap { ManifestStore.existing($0) }
    }
    /// How far along this step is, 0…1. A running step advances with the clock against its expected duration.
    func fraction(now: Date) -> Double {
        switch stage.status {
        case .done: return 1
        case .running:
            guard let a = Format.parse(stage.startedAt) else { return 0.05 }
            return min(0.96, max(0.04, now.timeIntervalSince(a) / max(expected, 1)))
        case .failed, .cancelled, .interrupted:
            guard let d = stage.duration else { return 0.3 }
            return min(0.9, max(0.1, d / max(expected, 1)))
        default: return 0
        }
    }
}

struct RunView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RunRecord

    @State private var selected = ""
    @State private var showLog = false
    @State private var follow = true
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var run: Run { record.run }
    private var running: Bool { record.isRunning }
    private var inputAsset: AssetRecord? { run.inputAssetId.flatMap { env.asset($0) } }
    private var inputRecordings: [RecordingRecord] { run.inputRecordingIds.compactMap { env.recording($0) } }
    private var outputAsset: AssetRecord? { run.outputAsset.flatMap { env.asset($0) } }
    private var parentRun: RunRecord? { run.waitsFor.flatMap { env.run($0) } }
    private var dependants: [RunRecord] { env.runsWaiting(on: run.id) }

    private var steps: [PipelineStep] {
        var s: [PipelineStep] = []
        for r in inputRecordings where r.rec.isFootage {
            s.append(PipelineStep(key: "frames:\(r.rec.id)", name: "frames", label: inputRecordings.filter(\.rec.isFootage).count > 1 ? "Frames · \(r.rec.name)" : "Frames",
                                  blurb: ManifestStore.stageBlurbs["frames"] ?? "", stage: r.rec.frames, baseDir: r.dir, expected: expected("frames"),
                                  fallbackPreview: r.thumbnail))
        }
        for k in run.kind.stages {
            s.append(PipelineStep(key: k, name: k, label: ManifestStore.stageLabels[k] ?? k, blurb: ManifestStore.stageBlurbs[k] ?? "",
                                  stage: run.stage(k), baseDir: record.dir, expected: expected(k),
                                  fallbackPreview: k == "preview" ? record.dir.appending(path: "thumb.jpg") : nil))
        }
        return s
    }
    private func expected(_ stage: String) -> Double {
        env.typicalDuration(of: stage, kind: run.kind) ?? RunKind.typicalSeconds[stage] ?? 60
    }
    private var current: PipelineStep? { steps.first { $0.key == selected } ?? steps.first }

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
            .onAppear { if selected.isEmpty { selected = defaultSelection } }
            .onChange(of: run.status) { _, _ in if !running { selected = defaultSelection } }
            .background {
                Button("") { showLog.toggle() }.keyboardShortcut("l").hidden()   // ⌘L shows or hides the log
            }
    }

    /// The step that is running, else the last one that did anything, else the first.
    private var defaultSelection: String {
        steps.first { $0.stage.status == .running }?.key ?? steps.last { $0.stage.status != .pending }?.key ?? steps.first?.key ?? ""
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            ForEach(Format.warnings(recording: inputRecordings.first?.rec, run: run), id: \.self) { WarningBanner(text: $0) }
            if run.isQueued, let p = parentRun {
                WarningBanner(text: "Queued: this run starts by itself when run \(p.run.id) (\(p.run.kind.label), \(p.run.status.rawValue)) publishes its \(p.run.kind.outputKind.label.lowercased()).")
            }
            rail
            cards
            if let step = current { StageDetail(env: env, record: record, step: step, showLog: $showLog, follow: $follow) }
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
            Text([Format.settingsLine(run), Format.duration(totalDuration)].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.mono).foregroundStyle(.secondary)
        }
    }

    private var totalDuration: Double? {
        guard let a = Format.parse(run.startedAt) else { return nil }
        let b = Format.parse(run.finishedAt) ?? (running ? Date() : nil)
        return b.map { $0.timeIntervalSince(a) }
    }

    // MARK: the pipeline: inputs → stages (a progress bar with a milestone per stage) → output

    private var rail: some View {
        Card("") {
            TimelineView(.periodic(from: .now, by: running ? 1 : 3600)) { ctx in
                PipelineRail(steps: steps, now: ctx.date, running: running, selected: $selected,
                             height: max(96, 30 + 32 * CGFloat(inputCount))) {
                    inputsNode
                } trailing: {
                    outputNode
                }
            }
            if parentRun != nil || !dependants.isEmpty {
                Divider()
                HStack(spacing: 14) {
                    if let p = parentRun {
                        chainLink(symbol: "arrow.turn.down.right", text: "after \(p.run.kind.label.lowercased()) \(p.run.id)", status: p.run.status) { ws.open(.run(env.id, p.run.id)) }
                    }
                    ForEach(dependants) { d in
                        chainLink(symbol: "arrow.turn.right.down", text: "then \(d.run.kind.label.lowercased()) \(d.run.id)", status: d.run.status) { ws.open(.run(env.id, d.run.id)) }
                    }
                    Spacer()
                }
            }
        }
    }

    private func chainLink(symbol: String, text: String, status: Status, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(text)
                StatusPill(status: status, compact: true)
            }
        }
        .buttonStyle(.link).font(.callout)
    }

    private var inputCount: Int { (inputAsset != nil || (parentRun != nil && run.inputAssetId == nil) ? 1 : 0) + inputRecordings.count }

    private var inputsNode: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inputs").font(.caption).foregroundStyle(.secondary)
            if let p = parentRun, run.inputAssetId == nil {
                inputChip(symbol: run.kind.outputKind.symbol, name: "model from \(p.run.id)", faded: true) { ws.open(.run(env.id, p.run.id)) }
            }
            if let a = inputAsset {
                inputChip(symbol: a.asset.kind.symbol, name: a.asset.name, faded: false) { ws.open(.asset(env.id, a.asset.id)) }
            }
            ForEach(inputRecordings) { r in
                inputChip(symbol: r.rec.inputKind.symbol, name: r.rec.name, faded: false) { ws.open(.recording(env.id, r.rec.id)) }
            }
        }
    }

    private var outputNode: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Output").font(.caption).foregroundStyle(.secondary)
            if let a = outputAsset {
                inputChip(symbol: a.asset.kind.symbol, name: a.asset.name, faded: false) { ws.open(.asset(env.id, a.asset.id)) }
            } else {
                inputChip(symbol: run.kind.outputKind.symbol, name: running ? "\(run.kind.outputKind.label) · working…" : "\(run.kind.outputKind.label) · not published", faded: true, action: nil)
            }
        }
    }

    private func inputChip(symbol: String, name: String, faded: Bool, action: (() -> Void)?) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 16)
            Text(name).lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .frame(maxWidth: 170, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .opacity(faded ? 0.6 : 1)
        return Group {
            if let action { Button(action: action) { label }.buttonStyle(.plain) } else { label }
        }
    }

    // MARK: one card per stage: preview, status, metrics

    private var cards: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(steps) { step in
                    StageCard(step: step, selected: step.key == selected) { selected = step.key }
                }
            }
            .padding(2)
        }
        .scrollIndicators(.hidden)
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(showLog ? "Hide Log" : "Show Log", systemImage: "text.alignleft") { showLog.toggle() }.help("Show the selected stage's log (⌘L)")
            if running {
                Button("Cancel", systemImage: "stop.fill") { confirmCancel = true }.help("Stop the pipeline")
            } else if run.isQueued && parentRun != nil {
                Button("Run Now", systemImage: "play.fill") { Task { await ws.startRun(record) } }
                    .help("Try to start now (it still needs the run it waits for to have published)")
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

/// The bar: one segment per step, its width in proportion to how long the step usually takes, a milestone at every
/// boundary. Done segments are filled, the running one fills with the clock and shimmers, pending ones are empty.
struct PipelineRail<Leading: View, Trailing: View>: View {
    let steps: [PipelineStep]
    let now: Date
    let running: Bool
    @Binding var selected: String
    var endWidth: CGFloat = 170
    var height: CGFloat = 96
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    private let minSegment: CGFloat = 72
    private let milestoneWidth: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            // the bar gets what is left after the two end nodes and the milestones; segments share it by expected time
            let avail = max(geo.size.width - 2 * endWidth - 24 - CGFloat(steps.count + 1) * milestoneWidth, CGFloat(steps.count) * minSegment)
            let total = max(steps.reduce(0) { $0 + $1.expected }, 1)
            let raw = steps.map { max(minSegment, avail * CGFloat($0.expected / total)) }
            let scale = min(1, avail / max(raw.reduce(0, +), 1))
            HStack(alignment: .center, spacing: 0) {
                leading.frame(width: endWidth, alignment: .leading)
                Spacer(minLength: 12)
                milestone(status: .done, index: 0, isStart: true)
                ForEach(Array(steps.enumerated()), id: \.element.key) { i, step in
                    segment(step, width: raw[i] * scale)
                    milestone(status: step.stage.status, index: i + 1, isStart: false)
                }
                Spacer(minLength: 12)
                trailing.frame(width: endWidth, alignment: .trailing)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: height)
    }

    private func segment(_ step: PipelineStep, width: CGFloat) -> some View {
        let f = step.fraction(now: now)
        let color = step.stage.status.color
        return Button { selected = step.key } label: {
            VStack(spacing: 5) {
                Text(step.label)
                    .font(.caption.weight(step.key == selected ? .semibold : .regular))
                    .foregroundStyle(step.stage.status == .pending ? .secondary : .primary)
                    .lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6)).frame(height: 8)
                    Capsule().fill(color).frame(width: max(0, (width - 8) * f), height: 8)
                        .overlay(alignment: .leading) {
                            if step.stage.status == .running {
                                Shimmer(width: (width - 8) * f)
                            }
                        }
                        .clipShape(Capsule())
                        .animation(.linear(duration: 1), value: f)
                }
                .frame(width: max(0, width - 8))
                Text(timing(step, f)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timing(_ step: PipelineStep, _ f: Double) -> String {
        switch step.stage.status {
        case .done: return Format.duration(step.stage.duration)
        case .running:
            let left = max(0, step.expected - (Format.parse(step.stage.startedAt).map { now.timeIntervalSince($0) } ?? 0))
            return left < 5 ? "any moment now" : "about \(Format.duration(left)) left"
        case .pending: return "~\(Format.duration(step.expected))"
        default: return step.stage.status.rawValue
        }
    }

    private func milestone(status: Status, index: Int, isStart: Bool) -> some View {
        ZStack {
            Circle().fill(Color(nsColor: .controlBackgroundColor)).frame(width: 18, height: 18)
            Circle().strokeBorder(status == .pending ? Color.secondary.opacity(0.4) : status.color, lineWidth: 2).frame(width: 18, height: 18)
            switch status {
            case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(status.color)
            case .running: Circle().fill(status.color).frame(width: 8, height: 8)
            case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(status.color)
            default: Text(isStart ? "" : "\(index)").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .offset(y: -1)
    }
}

/// A soft highlight sliding along the filled part of a running segment.
private struct Shimmer: View {
    let width: CGFloat
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 60, height: 8)
                .offset(x: -60 + (width + 60) * t)
        }
        .frame(width: max(0, width), height: 8, alignment: .leading)
        .clipped()
    }
}

/// A stage as a card: what came out of it (its preview), its state and the numbers it reported.
struct StageCard: View {
    let step: PipelineStep
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let p = step.previewURL {
                        FileImage(url: p, maxPixel: 600).aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.4)).overlay {
                            Image(systemName: placeholderSymbol).font(.title2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: 208, height: 120).clipped()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(step.label).font(.headline).lineLimit(1)
                        Spacer()
                        StatusPill(status: step.stage.status, compact: true)
                    }
                    Text([Format.clock(step.stage.startedAt), Format.duration(step.stage.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Format.stageMetrics(step.name, step.stage.metrics)).font(.caption).lineLimit(2).frame(minHeight: 28, alignment: .top)
                    if !step.stage.outputs.isEmpty {
                        Text("\(step.stage.outputs.count) file\(step.stage.outputs.count == 1 ? "" : "s") · \(Format.size(step.stage.outputs.reduce(0) { $0 + $1.size }))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(10)
            }
            .frame(width: 208)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placeholderSymbol: String {
        switch step.stage.status {
        case .running: "hourglass"
        case .pending: "circle.dashed"
        case .failed: "exclamationmark.triangle"
        default: step.name == "preview" ? "cube.transparent" : "photo"
        }
    }
}

/// The selected stage in full: a large preview (the 3D viewer for the preview stage), what it does, its numbers,
/// the files it produced (open, reveal) and, on demand, its log.
struct StageDetail: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RunRecord
    let step: PipelineStep
    @Binding var showLog: Bool
    @Binding var follow: Bool

    private var live: Bool { step.stage.status == .running }

    var body: some View {
        Card("") {
            HStack(alignment: .top, spacing: 22) {
                preview
                    .frame(width: 520, height: 330)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(step.label).font(Theme.display(22))
                        StatusPill(status: step.stage.status)
                        Spacer()
                        Text([Format.clock(step.stage.startedAt), Format.duration(step.stage.duration)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(Theme.mono).foregroundStyle(.secondary)
                    }
                    Text(step.blurb).foregroundStyle(.secondary)
                    if !step.stage.metrics.isEmpty {
                        Text(Format.stageMetrics(step.name, step.stage.metrics)).font(.callout)
                    }
                    if let e = step.stage.error, step.stage.status != .done { Text(e).font(.callout).foregroundStyle(Theme.bad).textSelection(.enabled) }
                    if !step.stage.outputs.isEmpty {
                        Text("Files").font(.headline).padding(.top, 4)
                        ForEach(step.stage.outputs) { f in
                            let url = step.baseDir.appending(path: f.path)
                            HStack(spacing: 8) {
                                Button(f.label.isEmpty ? f.path : f.label) { ws.openFile(url) }.buttonStyle(.link).lineLimit(1)
                                if !f.label.isEmpty { Text(f.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                                Spacer()
                                Text(Format.size(f.size)).font(Theme.mono).foregroundStyle(.secondary)
                                Button("Reveal in Finder", systemImage: "folder") { ws.reveal(url) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reveal in Finder")
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Spacer()
                        Button(showLog ? "Hide Log" : "Show Log", systemImage: showLog ? "chevron.up" : "chevron.down") { showLog.toggle() }
                            .buttonStyle(.glass).help("⌘L")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showLog {
                LogView(title: step.label, url: step.logURL, live: live, follow: $follow, height: 320)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if step.name == "preview", step.stage.status == .done, let u = ManifestStore.existing(record.dir.appending(path: "preview.usdz")) {
            ModelViewer(url: u)
        } else if let p = step.previewURL {
            FileImage(url: p, maxPixel: 1400).padding(6)
        } else {
            VStack(spacing: 8) {
                Image(systemName: step.stage.status == .running ? "hourglass" : "photo").font(.largeTitle).foregroundStyle(.tertiary)
                Text(step.stage.status == .running ? "working…" : step.stage.status == .pending ? "not started" : "no preview for this stage")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
