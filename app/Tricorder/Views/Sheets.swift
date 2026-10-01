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
    case video, photos, measurements
    var id: String { rawValue }
    var label: String { switch self { case .video: "Video"; case .photos: "Photos"; case .measurements: "Measurements" } }
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
    @State private var importingPhotos = false
    @State private var photos: [URL] = []
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        switch kind {
        case .measurements: measurementsBody
        case .photos: photosBody
        case .video: videoBody
        }
    }

    private var photosBody: some View {
        SheetFrame(title: "Add photos", lead: "Still photos of \(ws.environment(envId)?.env.name ?? "the environment"): close-ups, a corner the walk missed. An extend scan registers them into an existing 3D model.",
                   width: 680, height: 560) {
            Section { kindPicker }
            Section("Photos") {
                VStack(spacing: 4) {
                    if photos.isEmpty {
                        Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(.secondary)
                        Text("Drop photos or a folder here, or click to choose").fontWeight(.medium)
                        Text("HEIC / JPEG from the iPhone").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(Theme.accent)
                        Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")").fontWeight(.medium)
                        Text(photos.first?.deletingLastPathComponent().path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 96).padding(12)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .contentShape(Rectangle())
                .onTapGesture { importingPhotos = true }
                .dropDestination(for: URL.self) { urls, _ in addPhotos(urls) } isTargeted: { _ in }
                if !photos.isEmpty { Button("Clear") { photos = [] } }
                TextField("Recording name", text: $name, prompt: Text("Close-ups of the shed"))
            }
        } footer: {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(busy ? "Adding…" : "Add Photos") { createPhotos() }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(photos.isEmpty || busy)
        }
        .fileImporter(isPresented: $importingPhotos, allowedContentTypes: [.image, .folder], allowsMultipleSelection: true) { r in
            if case .success(let u) = r { _ = addPhotos(u) }
        }
    }

    private func addPhotos(_ urls: [URL]) -> Bool {
        var found: [URL] = []
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                found += items.filter { ManifestStore.imageExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                if name.isEmpty { name = u.lastPathComponent }
            } else if ManifestStore.imageExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            }
        }
        guard !found.isEmpty else { return false }
        photos += found.filter { !photos.contains($0) }
        return true
    }

    private func createPhotos() {
        busy = true
        message = "copying the photos…"
        Task {
            let ok = await ws.createPhotosRecording(env: envId, files: photos, name: name.isEmpty ? "\(photos.count) photos" : name)
            busy = false
            if ok { dismiss() } else { message = "" }
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
