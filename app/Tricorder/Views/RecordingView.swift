import SwiftUI

struct RecordingView: View {
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
                    Button("Reconstruct", systemImage: "play.fill") { ws.requestNewRun(env: env.id, kind: .reconstruct, inputId: rec.id) }
                        .help("Start a 3D reconstruction on this recording")
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        Button("Open Video") { ws.openFile(videoURL) }
                        Divider()
                        Button("Delete Recording…", role: .destructive) { confirmDelete = true }
                            .disabled(!runs.isEmpty || record.isBusy)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete recording “\(rec.name)”?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteRecording(record) } }
            } message: {
                Text("The video copy and its extracted frames are moved to the Trash.")
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
                    Button("Reconstruct…", systemImage: "play.fill") { ws.requestNewRun(env: env.id, kind: .reconstruct, inputId: rec.id) }.buttonStyle(.borderless)
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
                    Text(rec.source.fileName).foregroundStyle(.secondary)
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
