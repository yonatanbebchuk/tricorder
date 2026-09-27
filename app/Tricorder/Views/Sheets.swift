import SwiftUI
import UniformTypeIdentifiers

private func isVideo(_ url: URL) -> Bool { ManifestStore.videoExtensions.contains(url.pathExtension.lowercased()) }

private func suggestedName(_ url: URL) -> String {
    url.deletingPathExtension().lastPathComponent.replacing(/[_-]+/, with: " ")
}

/// Sheet chrome: serif title, lead, grouped form, footer buttons.
private struct SheetFrame<Content: View, Footer: View>: View {
    let title: String
    let lead: String
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.display(26))
                Text(lead).foregroundStyle(.secondary)
            }
            .padding(24)
            Form { content }.formStyle(.grouped)
            HStack { footer }.padding(20)
        }
        .frame(width: width, height: height)
    }
}

// MARK: - new environment

struct NewEnvironmentSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    var initialVideo: URL?

    @State private var name = ""
    @State private var video: URL?
    @State private var fps = 2.0
    @State private var maxFrames = 400
    @State private var hdr = "auto"
    @State private var reconstruct = true
    @State private var settings = RunSettings()
    @State private var importing = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        SheetFrame(title: "New environment", lead: "A place you scan: a backyard, a room, a site. Add its first recording now or later.",
                   width: 680, height: video == nil ? 420 : 760) {
            Section("Environment") {
                TextField("Name", text: $name, prompt: Text("Backyard"))
            }
            Section("First recording (optional)") {
                DropZone(selected: video, onDrop: choose) { importing = true }
                if video != nil {
                    Button("Remove") { video = nil }
                }
            }
            if video != nil {
                Section("Frames") { FrameSettingsForm(fps: $fps, maxFrames: $maxFrames, hdr: $hdr) }
                Section {
                    Toggle("Start the 3D reconstruction right away", isOn: $reconstruct)
                    if reconstruct { ReconstructSettingsForm(settings: $settings) }
                }
            }
        } footer: {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(busy ? "Creating…" : "Create") { create() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { r in
            if case .success(let u) = r { choose(u) }
        }
        .task { if let v = initialVideo { choose(v) } }
    }

    private func choose(_ url: URL) {
        video = url
        if name.isEmpty { name = suggestedName(url) }
    }

    private func create() {
        busy = true
        message = "creating…"
        Task {
            guard let env = await ws.createEnvironment(name: name.trimmingCharacters(in: .whitespaces)) else { busy = false; message = ""; return }
            if let video {
                message = "adding the recording…"
                _ = await ws.createRecording(env: env, video: video, name: suggestedName(video),
                                             frames: FrameSettings(fps: fps, maxFrames: maxFrames, hdr: hdr),
                                             reconstruct: reconstruct ? settings : nil, label: "")
            }
            busy = false
            dismiss()
        }
    }
}

// MARK: - new recording

struct NewRecordingSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let envId: String
    var initialVideo: URL?

    @State private var inbox: [VideoFile] = []
    @State private var video: URL?
    @State private var name = ""
    @State private var fps = 2.0
    @State private var maxFrames = 400
    @State private var hdr = "auto"
    @State private var reconstruct = true
    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var importing = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        SheetFrame(title: "Add recording", lead: "One filmed walk of \(ws.environment(envId)?.env.name ?? "the environment"). The video is copied into the environment; frames are extracted once.",
                   width: 680, height: 780) {
            Section("Video") {
                DropZone(selected: video, onDrop: choose) { importing = true }
                if !inbox.isEmpty {
                    Picker("From data/", selection: $video) {
                        Text("—").tag(URL?.none)
                        ForEach(inbox) { v in Text("\(v.url.lastPathComponent)  (\(Format.size(v.size)))").tag(URL?.some(v.url)) }
                    }
                }
                TextField("Recording name", text: $name, prompt: Text("Walk at noon"))
            }
            Section("Frames") { FrameSettingsForm(fps: $fps, maxFrames: $maxFrames, hdr: $hdr) }
            Section {
                Toggle("Start the 3D reconstruction right away", isOn: $reconstruct)
                if reconstruct {
                    ReconstructSettingsForm(settings: $settings)
                    TextField("Run label", text: $label, prompt: Text("optional"))
                }
            }
        } footer: {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(busy ? "Adding…" : reconstruct ? "Add & Reconstruct" : "Add Recording") { create() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(video == nil || busy)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { r in
            if case .success(let u) = r { choose(u) }
        }
        .task {
            inbox = ws.videosInInbox()
            if let v = initialVideo { choose(v) }
        }
        .onChange(of: video) { _, new in if let new, name.isEmpty { name = suggestedName(new) } }
    }

    private func choose(_ url: URL) {
        video = url
        if name.isEmpty { name = suggestedName(url) }
    }

    private func create() {
        guard let video else { return }
        busy = true
        message = "copying the video and reading its metadata…"
        Task {
            let ok = await ws.createRecording(env: envId, video: video, name: name.isEmpty ? suggestedName(video) : name,
                                              frames: FrameSettings(fps: fps, maxFrames: maxFrames, hdr: hdr),
                                              reconstruct: reconstruct ? settings : nil, label: label)
            busy = false
            if ok { dismiss() } else { message = "" }
        }
    }
}

// MARK: - new run

struct NewRunSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let request: NewRunRequest

    @State private var kind: RunKind
    @State private var inputId: String?
    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var busy = false

    init(request: NewRunRequest) {
        self.request = request
        _kind = State(initialValue: request.kind)
        _inputId = State(initialValue: request.inputId)
    }

    private var env: EnvironmentRecord? { ws.environment(request.envId) }
    private var scans: [AssetRecord] { env?.assets.filter { $0.asset.kind == .scan3d }.reversed() ?? [] }

    var body: some View {
        SheetFrame(title: "New run", lead: "A run consumes a recording or an earlier asset and publishes one new asset. Earlier assets stay in the history.",
                   width: 640, height: 560) {
            Section("What to make") {
                Picker("Kind", selection: $kind) {
                    ForEach(RunKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if kind == .reconstruct {
                    Picker("Recording", selection: $inputId) {
                        Text("—").tag(String?.none)
                        ForEach(env?.recordings ?? []) { r in
                            Text("\(r.rec.name) · \(Format.videoLine(r.rec.source))").tag(String?.some(r.rec.id))
                        }
                    }
                } else {
                    Picker("3D scan", selection: $inputId) {
                        Text("—").tag(String?.none)
                        ForEach(scans) { a in
                            Text("\(a.asset.name) · \(a.answeredCount) measurement\(a.answeredCount == 1 ? "" : "s") · \(Format.when(a.asset.createdAt))").tag(String?.some(a.asset.id))
                        }
                    }
                    if let id = inputId, let a = env?.asset(id), a.answeredCount == 0 {
                        Text("This scan has no measurements yet; the plan run would fail. Open the scan and enter at least one.").font(.caption).foregroundStyle(Theme.bad)
                    }
                }
            }
            Section("Settings") {
                if kind == .reconstruct { ReconstructSettingsForm(settings: $settings) } else { PlanSettingsForm(settings: $settings) }
                TextField("Label", text: $label, prompt: Text("optional, e.g. learned features"))
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(busy ? "Starting…" : "Start Run") { start() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(inputId == nil || busy)
        }
        .onChange(of: kind) { _, k in
            if k == .reconstruct { inputId = env?.recordings.first?.rec.id } else { inputId = scans.first?.asset.id }
        }
        .task {
            if inputId == nil { inputId = kind == .reconstruct ? env?.recordings.first?.rec.id : scans.first?.asset.id }
        }
    }

    private func start() {
        guard let inputId else { return }
        busy = true
        Task {
            let ok = await ws.createRun(env: request.envId, kind: kind, inputId: inputId, settings: settings, label: label)
            busy = false
            if ok { dismiss() }
        }
    }
}

// MARK: - drop zone

struct DropZone: View {
    let selected: URL?
    let onDrop: (URL) -> Void
    let onChoose: () -> Void
    @State private var over = false

    var body: some View {
        VStack(spacing: 4) {
            if let selected {
                Image(systemName: "video.fill").font(.title2).foregroundStyle(Theme.accent)
                Text(selected.lastPathComponent).fontWeight(.medium)
                Text(selected.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(.secondary)
                Text("Drop a video here or click to choose").fontWeight(.medium)
                Text(".MOV / .mp4 from the iPhone").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .padding(12)
        .background(over ? Theme.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(over ? Theme.accent : Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: isVideo) else { return false }
            onDrop(u)
            return true
        } isTargeted: { over = $0 }
    }
}
