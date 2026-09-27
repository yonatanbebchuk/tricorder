import SwiftUI

struct ScanView: View {
    @Environment(Workspace.self) private var ws
    let record: ScanRecord

    @State private var notes: String
    @State private var tableSelection: RunRecord.ID?
    @State private var showNewRun = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""

    init(record: ScanRecord) {
        self.record = record
        _notes = State(initialValue: record.scan.notes)
    }

    private var scan: Scan { record.scan }
    private var f: [String: JSONValue] { scan.frames.metrics }

    var body: some View {
        ScrollView { pageContent }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(scan.name)
        .navigationSubtitle(Format.videoLine(scan.video))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Run", systemImage: "play.fill") { showNewRun = true }
                    .help("Run the pipeline again on this footage with different settings")
                Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                Menu {
                    Button("Rename…") { newName = scan.name; renaming = true }
                    Divider()
                    Button("Delete Scan…", role: .destructive) { confirmDelete = true }.disabled(record.isBusy)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showNewRun) { NewRunSheet(scan: record) }
        .alert("Rename scan", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { Task { await ws.rename(record, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(scan.name)” and all its runs?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { Task { await ws.deleteScan(record) } }
        } message: {
            Text("The scan folder, including extracted frames and every run, is moved to the Trash.")
        }
        .onChange(of: record.scan.notes) { _, new in if !notesDirty { notes = new } }
    }

    private var notesDirty: Bool { notes != record.scan.notes }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            runsCard
            notesCard
        }
        .padding(28)
        .frame(maxWidth: 1180, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 22) {
            Group {
                if let t = record.thumbnail {
                    FileImage(url: t, maxPixel: 800)
                } else {
                    Rectangle().fill(.quaternary).overlay {
                        Text(scan.frames.status == .running ? "extracting frames…" : "no frames yet").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 300, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(scan.name).font(Theme.display(30))
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.video.fileName).foregroundStyle(.secondary)
                    Text(Format.videoLine(scan.video)).foregroundStyle(.secondary)
                    Text("created \(Format.when(scan.createdAt))").foregroundStyle(.secondary)
                }
                .font(.callout)
                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.int("images").map(String.init) ?? "–").font(Theme.display(24))
                        HStack(spacing: 5) {
                            Text("frames").font(.caption).foregroundStyle(.secondary)
                            StatusPill(status: scan.frames.status, compact: true)
                        }
                    }
                    MetricTile(value: f.double("sharpness_median").map { String(Int($0.rounded())) } ?? "–", label: "sharpness median")
                    MetricTile(value: Format.number(scan.frameSettings.fps), label: "fps · max \(scan.frameSettings.maxFrames)")
                }
                .padding(.top, 4)
            }
        }
    }

    private var runsCard: some View {
        Card("Runs") {
            if record.runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            } else {
                Table(record.runs, selection: $tableSelection) {
                    TableColumn("Run") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.run.id).fontWeight(.semibold)
                            if !r.run.label.isEmpty { Text(r.run.label).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 50, ideal: 110)
                    TableColumn("Settings") { r in Text(Format.settingsLine(r.run.settings)).font(Theme.mono) }
                        .width(min: 180, ideal: 260)
                    TableColumn("Status") { r in
                        HStack(spacing: 6) { StatusPill(status: r.run.status); StageDots(run: r.run) }
                    }
                    .width(min: 110, ideal: 130)
                    TableColumn("COLMAP") { r in Text(orDash(Format.stageMetrics("sfm", r.run.stage("sfm").metrics))) }
                    TableColumn("Dense") { r in Text(orDash(Format.stageMetrics("dense", r.run.stage("dense").metrics))) }
                    TableColumn("Plan") { r in
                        let m = Format.stageMetrics("plan", r.run.stage("plan").metrics)
                        if !m.isEmpty { Text(m) } else if r.prompts != nil { Text("awaiting measurements").foregroundStyle(.secondary) } else { Text("–") }
                    }
                    TableColumn("Created") { r in Text(Format.when(r.run.createdAt)).foregroundStyle(.secondary) }
                        .width(min: 100, ideal: 120)
                }
                .frame(height: CGFloat(record.runs.count) * 44 + 34)
                .onChange(of: tableSelection) { _, id in
                    if let id, let r = record.runs.first(where: { $0.id == id }) { ws.selection = .run(record.id, r.run.id) }
                }
            }
            HStack {
                Button("New run on this footage…", systemImage: "play.fill") { showNewRun = true }.buttonStyle(.glassProminent)
                Text("Frames are reused. A second run is how you compare SIFT against ALIKED + LightGlue on the same walk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var notesCard: some View {
        Card("Notes") {
            TextEditor(text: $notes)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(notesDirty ? "Save Notes" : "Saved") { Task { await ws.saveNotes(record, notes) } }
                    .disabled(!notesDirty)
                    .keyboardShortcut("s")
            }
        }
    }

    private func orDash(_ s: String) -> String { s.isEmpty ? "–" : s }
}
