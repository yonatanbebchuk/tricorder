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

enum RecordingKind: String, CaseIterable, Identifiable {
    case video, measurements
    var id: String { rawValue }
    var label: String { self == .video ? "Video" : "Measurements" }
}

struct NewRecordingSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let envId: String
    var initialVideo: URL?
    var measurements = false

    @State private var kind: RecordingKind = .video
    @State private var items: [MeasurementItem] = []
    @State private var north: MeasurementNorth?
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
        if kind == .measurements {
            measurementsBody
        } else {
            videoBody
        }
    }

    private var kindPicker: some View {
        Picker("Kind", selection: $kind) { ForEach(RecordingKind.allCases) { Text($0.label).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
    }

    private var measurementsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Add measurements").font(Theme.display(26))
                    Spacer()
                    kindPicker
                }
                Text("Things you taped on site, marked on the frames of a video of \(ws.environment(envId)?.env.name ?? "the environment"). Any layout can use them, on any model built from that footage.")
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name, prompt: Text("Tape, Saturday")).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            .padding(24)
            ScrollView {
                if let env = ws.environment(envId) {
                    MeasurementsEditor(env: env, items: $items, north: $north).padding(.horizontal, 24)
                }
            }
            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Saving…" : "Save Recording") { createMeasurements() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty || busy)
            }
            .padding(20)
        }
        .frame(width: 1080, height: 900)
    }

    private func createMeasurements() {
        busy = true
        Task {
            let ok = await ws.createMeasurementRecording(env: envId, name: name.isEmpty ? "Measurements" : name, items: items, north: north)
            busy = false
            if ok { dismiss() }
        }
    }

    private var videoBody: some View {
        SheetFrame(title: "Add recording", lead: "One filmed walk of \(ws.environment(envId)?.env.name ?? "the environment"). The video is copied into the environment; frames are extracted once.",
                   width: 680, height: 820) {
            Section { kindPicker }
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
        .onAppear { if measurements { kind = .measurements } }
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
    @State private var chosenMeasurements: Set<String> = []
    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var busy = false

    init(request: NewRunRequest) {
        self.request = request
        _kind = State(initialValue: request.kind)
        _inputId = State(initialValue: request.inputId)
    }

    private var env: EnvironmentRecord? { ws.environment(request.envId) }
    private var scans: [AssetRecord] { env?.assets.filter { $0.asset.kind == .model3d }.reversed() ?? [] }

    var body: some View {
        SheetFrame(title: "New run", lead: "An environment scan turns a recording into a 3D model; a layout turns a measured 3D model into a site plan. Each run publishes one new asset; earlier assets stay in the history.",
                   width: 640, height: 640) {
            Section("What to make") {
                Picker("Kind", selection: $kind) {
                    ForEach(RunKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if kind == .scan {
                    Picker("Recording", selection: $inputId) {
                        Text("—").tag(String?.none)
                        ForEach(env?.videoRecordings ?? []) { r in
                            Text("\(r.rec.name) · \(Format.videoLine(r.rec.source))").tag(String?.some(r.rec.id))
                        }
                    }
                } else {
                    Picker("3D model", selection: $inputId) {
                        Text("—").tag(String?.none)
                        ForEach(scans) { a in
                            Text("\(a.asset.name) · \(Format.when(a.asset.createdAt))").tag(String?.some(a.asset.id))
                        }
                    }
                    let measurements = env?.measurementRecordings ?? []
                    if measurements.isEmpty {
                        Text("No measurement recordings in this environment. Scale will be estimated from the camera height (phone at chest height, about ±10 %) and the plan marked as estimated. Add a measurements recording for a true-scale plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(measurements) { m in
                            Toggle(isOn: Binding(get: { chosenMeasurements.contains(m.rec.id) },
                                                 set: { on in if on { chosenMeasurements.insert(m.rec.id) } else { chosenMeasurements.remove(m.rec.id) } })) {
                                Text("\(m.rec.name) · \(m.rec.items.count) measurement\(m.rec.items.count == 1 ? "" : "s")" + (m.rec.north != nil ? " · north" : ""))
                            }
                        }
                        if chosenMeasurements.isEmpty {
                            Text("None chosen: scale will be estimated from the camera height (about ±10 %).").font(.caption).foregroundStyle(Theme.warn)
                        }
                    }
                }
            }
            Section("Settings") {
                if kind == .scan { ReconstructSettingsForm(settings: $settings) } else { LayoutSettingsForm(settings: $settings) }
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
            if k == .scan { inputId = env?.videoRecordings.first?.rec.id } else { inputId = scans.first?.asset.id }
        }
        .task {
            if inputId == nil { inputId = kind == .scan ? env?.videoRecordings.first?.rec.id : scans.first?.asset.id }
            chosenMeasurements = Set((env?.measurementRecordings ?? []).map(\.rec.id))
        }
    }

    private func start() {
        guard let inputId else { return }
        busy = true
        Task {
            let ok = await ws.createRun(env: request.envId, kind: kind, inputId: inputId, recordings: kind == .layout ? Array(chosenMeasurements).sorted() : [],
                                        settings: settings, label: label)
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
