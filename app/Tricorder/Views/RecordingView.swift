import SwiftUI

struct RecordingView: View {
    let env: EnvironmentRecord
    let record: RecordingRecord

    var body: some View {
        if record.isMeasurements { MeasurementsRecordingView(env: env, record: record) }
        else if record.isMarks { MarksRecordingView(env: env, record: record) }
        else { VideoRecordingView(env: env, record: record) }
    }

    var pageContent: some View {
        Group {
            if record.isMeasurements { MeasurementsRecordingView(env: env, record: record).pageContent }
            else if record.isMarks { MarksRecordingView(env: env, record: record).pageContent }
            else { VideoRecordingView(env: env, record: record).pageContent }
        }
    }
}

/// A marks recording: what was drawn on the model, by role; the full view is where they are made.
struct MarksRecordingView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RecordingRecord
    @State private var confirmDelete = false

    private var marks: [MarkItem] { record.rec.marks }
    private var model: AssetRecord? { record.rec.markModel.flatMap { env.asset($0) } }
    private var runs: [RunRecord] { env.runsUsing(recording: record.rec.id).reversed() }
    private var edits: [MarkItem] { marks.filter(\.isEdit) }
    private var elements: [MarkItem] { marks.filter { !$0.isEdit } }
    private var generated: Bool { record.isGenerated }
    private var producer: RunRecord? { record.rec.source.generatedBy.flatMap { env.run($0) } }
    @State private var selectedEntity: MarkItem.ID?

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(record.rec.name)
            .navigationSubtitle(generated ? "inventory · \(marks.count) entities on \(model?.asset.name ?? record.rec.markModel ?? "?")"
                                          : "\(marks.count) mark\(marks.count == 1 ? "" : "s") on \(model?.asset.name ?? record.rec.markModel ?? "?")")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if let m = model {
                        Button("Full View", systemImage: "arrow.up.left.and.arrow.down.right") { ws.open(.editor(env.id, m.asset.id, generated ? nil : record.rec.id)) }
                            .help(generated ? "Accept, correct or remove these entities on the mesh" : "Continue marking on the mesh")
                    }
                    Button("Lay Out", systemImage: "map") { ws.requestNewRun(env: env.id, kind: .layout, inputId: record.rec.id) }
                        .disabled(elements.isEmpty).help("A site plan with these elements")
                    if !generated {
                        Button("Edit", systemImage: "scissors") { ws.requestNewRun(env: env.id, kind: .edit, inputId: record.rec.id) }
                            .disabled(edits.isEmpty).help("Cut out what the edit marks name")
                    }
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        if let p = producer { Button("Open Run \(p.run.id)") { ws.open(.run(env.id, p.run.id)) } }
                        Button("Delete Recording…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete “\(record.rec.name)”?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteRecording(record) } }
            } message: {
                Text("The recording is moved to the Trash; the \(runs.count) run\(runs.count == 1 ? "" : "s") that used it stay.")
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: generated ? "tag" : "pencil.and.outline").foregroundStyle(Theme.accent).font(.title2)
                    Text(record.rec.name).font(Theme.display(30))
                    Text(record.rec.id).font(Theme.mono).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text((generated ? "generated inventory · \(Format.when(record.rec.createdAt)) · made by" : "marks · \(Format.when(record.rec.createdAt)) · drawn on")).foregroundStyle(.secondary)
                    if generated, let p = producer { Button("run \(p.run.id)") { ws.open(.run(env.id, p.run.id)) }.buttonStyle(.link); Text("on").foregroundStyle(.secondary) }
                    if let m = model { Button(m.asset.name) { ws.open(.asset(env.id, m.asset.id)) }.buttonStyle(.link) } else { Text(record.rec.markModel ?? "?") }
                    Text("· frame \(record.rec.markFrame ?? "?") · used by \(runs.count) run\(runs.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if let m = model, let preview = m.preview {
                ZStack(alignment: .bottomTrailing) {
                    EditableModelView(url: preview, overlays: Overlay.overlays(marks: marks, levelled: m.levelled, generated: generated, prefix: "r:"),
                                      interactive: false, onPick: { _ in })
                    Text(generated ? "the inventory's entities on \(m.asset.name) · drag to orbit · scroll to zoom" : "only this recording's marks on \(m.asset.name) · drag to orbit · scroll to zoom")
                        .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4).glassEffect().padding(8)
                }
                .frame(height: 460)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
            }
            if generated {
                if let img = record.mapImage {
                    FileImage(url: img, maxPixel: 2600)
                        .frame(maxHeight: 560)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .onTapGesture { ws.openFile(img) }
                }
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Array(Format.inventoryTiles(record.rec).enumerated()), id: \.offset) { _, t in MetricTile(value: t.0, label: t.1) }
                }
                Card("") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Entities").font(.headline)
                        Text("\(marks.count) · sizes approximate until a layout sets the scale").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Table(marks, selection: $selectedEntity) {
                        TableColumn("") { e in Circle().fill(Overlay.swiftColor(e.color ?? Overlay.palette(e.cls, e.material))).frame(width: 10, height: 10) }.width(16)
                        TableColumn("Name") { e in Text(e.displayName).fontWeight(.medium) }.width(min: 120, ideal: 180)
                        TableColumn("Class") { e in Text(e.cls + (e.material.map { " · \($0)" } ?? "")) }.width(min: 90, ideal: 130)
                        TableColumn("Area") { e in Text(e.areaM2.map { String(format: "%.1f m²", $0) } ?? "–").font(Theme.mono) }.width(70)
                        TableColumn("Height") { e in Text(e.heightM.map { String(format: "%.2f m", $0) } ?? "–").font(Theme.mono) }.width(70)
                        TableColumn("Sure") { e in Text(e.confidence.map { String(format: "%.0f %%", $0 * 100) } ?? "–").font(Theme.mono) }.width(50)
                        TableColumn("Frames") { e in Text("\(e.frames ?? 0)").font(Theme.mono) }.width(50)
                        TableColumn("Description") { e in Text(e.note ?? "").foregroundStyle(.secondary).lineLimit(1) }
                    }
                    .frame(height: CGFloat(min(marks.count, 18)) * 28 + 34)
                }
            } else {
                Card("Elements · \(elements.count)") { markRows(elements, empty: "No element marks yet. In Full View, accept entities or outline walls, areas and objects.") }
                Card("Edits · \(edits.count)") { markRows(edits, empty: "No edit marks. In Full View, select an entity and choose Remove, or right-click a hole and choose Patch Here.") }
            }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Runs using these marks") { EmptyView() }
                    Card("") { RunsTable(env: env, runs: runs) }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }

    @ViewBuilder private func markRows(_ items: [MarkItem], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        } else {
            ForEach(items) { m in
                HStack(spacing: 12) {
                    Circle().fill(m.isEdit ? (m.cls == "remove" ? Theme.bad : Color(red: 0.29, green: 0.56, blue: 0.78)) : Overlay.swiftColor(Overlay.palette(m.cls, m.material)))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name ?? m.cls).font(.headline)
                        Text([m.cls, m.material, m.shape, "\(m.points.count) point\(m.points.count == 1 ? "" : "s")", m.entity.map { "entity \($0)" },
                              m.reject == true ? "rejected" : nil, m.source == "accepted" ? "accepted proposal" : nil, m.text.map { "“\($0)”" }, m.note]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.when(m.at)).font(.caption).foregroundStyle(.secondary)
                    Button("Remove", systemImage: "xmark.circle") { Task { await ws.saveMarks(record, items: marks.filter { $0.id != m.id }) } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                if m.id != items.last?.id { Divider() }
            }
        }
    }
}

/// A measurement recording: the taped lengths, editable in place.
struct MeasurementsRecordingView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RecordingRecord

    @State private var items: [MeasurementItem]
    @State private var north: MeasurementNorth?
    @State private var confirmDelete = false

    init(env: EnvironmentRecord, record: RecordingRecord) {
        self.env = env
        self.record = record
        _items = State(initialValue: record.rec.items)
        _north = State(initialValue: record.rec.north)
    }

    private var runs: [RunRecord] { env.runsUsing(recording: record.rec.id).reversed() }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(record.rec.name)
            .navigationSubtitle("\(items.count) measurement\(items.count == 1 ? "" : "s")")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Lay Out", systemImage: "map") { ws.requestNewRun(env: env.id, kind: .layout) }
                        .disabled(env.assets.filter { $0.asset.kind == .model3d }.isEmpty)
                        .help("Start a layout using these measurements")
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        Button("Delete Recording…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete “\(record.rec.name)”?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteRecording(record) } }
            } message: {
                Text("The recording is moved to the Trash; the \(runs.count) layout\(runs.count == 1 ? "" : "s") that used it stay.")
            }
            .onChange(of: items) { _, new in if new != record.rec.items { Task { await ws.saveMeasurements(record, items: new, north: north) } } }
            .onChange(of: north) { _, new in if new != record.rec.north { Task { await ws.saveMeasurements(record, items: items, north: new) } } }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "ruler").foregroundStyle(Theme.accent).font(.title2)
                    Text(record.rec.name).font(Theme.display(30))
                    Text(record.rec.id).font(Theme.mono).foregroundStyle(.secondary)
                }
                Text("measurements · \(Format.when(record.rec.createdAt)) · used by \(runs.count) layout\(runs.count == 1 ? "" : "s") · changes are saved as you make them")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Card("") { MeasurementsEditor(env: env, items: $items, north: $north) }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Layouts using these measurements") { EmptyView() }
                    Card("") { RunsTable(env: env, runs: runs) }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }
}

struct VideoRecordingView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: RecordingRecord

    @State private var notes: String
    @State private var follow = true
    @State private var confirmDelete = false

    init(env: EnvironmentRecord, record: RecordingRecord) {
        self.env = env
        self.record = record
        _notes = State(initialValue: record.rec.notes)
    }

    private var rec: Recording { record.rec }
    private var f: [String: JSONValue] { rec.frames.metrics }
    private var runs: [RunRecord] { env.runsUsing(recording: rec.id).reversed() }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(rec.name)
            .navigationSubtitle(Format.videoLine(rec.source))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(rec.isPhotos ? "Extend" : "Scan", systemImage: "play.fill") { ws.requestNewRun(env: env.id, kind: rec.isPhotos ? .extend : .scan, inputId: rec.id) }
                        .help(rec.isPhotos ? "Register these photos into a 3D model" : "Start an environment scan on this recording")
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        Button("Open Video") { ws.openFile(videoURL) }
                        Divider()
                        Button("Delete Recording…", role: .destructive) { confirmDelete = true }
                            .disabled(record.isBusy)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete recording “\(rec.name)”?", isPresented: $confirmDelete) {
                let deps = env.dependents(ofRecording: rec.id)
                Button(deps.recordings.isEmpty ? "Move to Trash" : "Delete All", role: .destructive) { Task { await ws.deleteRecording(record) } }
            } message: {
                let deps = env.dependents(ofRecording: rec.id)
                Text("The video copy and its extracted frames are moved to the Trash; the \(runs.count) run\(runs.count == 1 ? "" : "s") on it stay. "
                     + Workspace.cascadeText(recordings: deps.recordings, assets: deps.assets))
            }
    }

    private var videoURL: URL {
        let p = rec.source.path
        return p.hasPrefix("/") ? URL(filePath: p) : (ws.root ?? record.dir).appending(path: p)
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            Card("Frames") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    StatusPill(status: rec.frames.status)
                    Text([Format.clock(rec.frames.startedAt), Format.duration(rec.frames.duration), Format.stageMetrics("frames", f)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    if let e = rec.frames.error, rec.frames.status == .failed { Text(e).foregroundStyle(Theme.bad) }
                }
                if let sh = f.double("sharpness_median"), sh < 80 {
                    WarningBanner(text: "Frames are soft (sharpness median \(Int(sh.rounded())); above 150 is comfortable). Expect fewer registered frames.")
                }
                LogView(title: "Frames", url: record.dir.appending(path: "logs/frames.log"), live: record.isBusy, follow: $follow, height: 220)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Runs on this recording") {
                    Button(rec.isPhotos ? "Extend…" : "Scan…", systemImage: "play.fill") { ws.requestNewRun(env: env.id, kind: rec.isPhotos ? .extend : .scan, inputId: rec.id) }.buttonStyle(.borderless)
                }
                Card("") { RunsTable(env: env, runs: runs) }
            }
            Card("Notes") {
                TextEditor(text: $notes)
                    .font(.body).frame(minHeight: 70).scrollContentBackground(.hidden).padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button(notes != rec.notes ? "Save Notes" : "Saved") { Task { await ws.saveNotes(recording: record, notes) } }
                        .disabled(notes == rec.notes)
                }
            }
            .onChange(of: rec.notes) { old, new in if notes == old { notes = new } }
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            Group {
                if let t = record.thumbnail {
                    FileImage(url: t, maxPixel: 800).aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary).overlay {
                        Text(rec.frames.status == .running ? "extracting frames…" : "no frames yet").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 300, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(rec.name).font(Theme.display(30))
                    Text(rec.id).font(Theme.mono).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.isPhotos ? "photos folder" : rec.source.fileName).foregroundStyle(.secondary)
                    Text(Format.videoLine(rec.source) + (rec.source.size.map { " · \(Format.size($0))" } ?? "")).foregroundStyle(.secondary)
                    Text("recorded into \(env.env.name) · \(Format.when(rec.createdAt))").foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack(alignment: .top, spacing: 26) {
                    MetricTile(value: f.int("images").map(String.init) ?? "–", label: "frames")
                    MetricTile(value: f.double("sharpness_median").map { String(Int($0.rounded())) } ?? "–", label: "sharpness median")
                    MetricTile(value: Format.number(rec.frameSettings.fps), label: "fps · max \(rec.frameSettings.maxFrames)")
                    MetricTile(value: "\(runs.count)", label: "runs")
                }
                .padding(.top, 4)
            }
        }
    }
}
