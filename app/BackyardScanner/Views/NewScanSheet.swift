import SwiftUI
import UniformTypeIdentifiers

struct NewScanSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    var initialVideo: URL?

    @State private var videos: [VideoFile] = []
    @State private var source: URL?
    @State private var name = ""
    @State private var fps = 2.0
    @State private var maxFrames = 400
    @State private var hdr = "auto"
    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var importing = false
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New scan").font(Theme.display(26))
                Text("A scan is one video. Frames are extracted once; the first run starts right away.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Form {
                Section("Video") {
                    DropZone(selected: source, onDrop: choose) { importing = true }
                    Picker("Already in data/", selection: $source) {
                        Text("—").tag(URL?.none)
                        ForEach(videos) { v in
                            Text("\(v.url.lastPathComponent)  (\(Format.size(v.size)))\(v.used ? " · already scanned" : "")").tag(URL?.some(v.url))
                        }
                    }
                    TextField("Scan name", text: $name, prompt: Text("Backyard, noon"))
                }
                Section("Frames") {
                    TextField("Frames per second", value: $fps, format: .number)
                    TextField("Max frames", value: $maxFrames, format: .number)
                    Picker("HDR", selection: $hdr) {
                        Text("auto-detect").tag("auto")
                        Text("none").tag("none")
                        Text("HLG").tag("hlg")
                        Text("PQ").tag("pq")
                    }
                    Text("Rule of thumb: 400 frames for a 3 to 5 minute walk, 600 for 7 minutes. More frames = better coverage, much longer COLMAP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("First run") {
                    RunSettingsForm(settings: $settings, label: $label)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Creating…" : "Create Scan & Start") { create() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || busy)
            }
            .padding(20)
        }
        .frame(width: 680, height: 780)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie]) { result in
            if case .success(let url) = result { choose(url) }
        }
        .task {
            videos = ws.videosInData()
            if let v = initialVideo {
                choose(v)
            } else if source == nil, let first = videos.first(where: { !$0.used }) ?? videos.first {
                choose(first.url)
            }
        }
        .onChange(of: source) { _, new in if let new, name.isEmpty { name = Self.suggestedName(new) } }
    }

    private func choose(_ url: URL) {
        source = url
        if name.isEmpty { name = Self.suggestedName(url) }
    }

    static func suggestedName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.replacing(/[_-]+/, with: " ")
    }

    private func create() {
        guard var video = source else { return }
        busy = true
        message = "creating…"
        Task {
            if !ws.isInData(video) {
                message = "copying into data/…"
                do { video = try await ws.importVideo(video) } catch {
                    message = error.localizedDescription
                    busy = false
                    return
                }
            }
            let ok = await ws.createScan(video: video, name: name.isEmpty ? Self.suggestedName(video) : name,
                                         frames: FrameSettings(fps: fps, maxFrames: maxFrames, hdr: hdr),
                                         settings: settings, label: label)
            busy = false
            if ok { dismiss() } else { message = "" }
        }
    }
}

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
            guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            onDrop(u)
            return true
        } isTargeted: { over = $0 }
    }
}
