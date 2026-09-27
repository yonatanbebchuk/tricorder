import SwiftUI

/// Add tape measurements: browse the frames of a video recording, click two points on one, type the metres.
/// Items are pixels on original frames; the layout run turns them into 3D constraints on whichever model it uses.
struct MeasurementsEditor: View {
    let env: EnvironmentRecord
    @Binding var items: [MeasurementItem]
    @Binding var north: MeasurementNorth?

    @State private var sourceId: String?
    @State private var frames: [String] = []
    @State private var selectedFrame: String?
    @State private var pointA: CGPoint?
    @State private var pointB: CGPoint?
    @State private var imageSize: CGSize = .zero
    @State private var meters = ""
    @State private var note = ""
    @State private var bearingText = ""

    private var videos: [RecordingRecord] { env.videoRecordings }
    private var source: RecordingRecord? { sourceId.flatMap { id in videos.first { $0.rec.id == id } } }
    private var frameURL: URL? { selectedFrame.flatMap { source?.imagesDir.appending(path: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if videos.isEmpty {
                Text("This environment has no video recording yet; measurements are marked on a video's frames.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Video", selection: $sourceId) {
                        ForEach(videos) { v in Text("\(v.rec.name) · \(Format.videoLine(v.rec.source))").tag(String?.some(v.rec.id)) }
                    }
                    .frame(maxWidth: 420)
                    Text(frames.isEmpty ? "no frames extracted yet (scan it first)" : "\(frames.count) frames · click one, then click two points on it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                FrameStrip(frames: frames, dir: source?.imagesDir, selected: $selectedFrame)
                if let url = frameURL {
                    PointPicker(url: url, a: $pointA, b: $pointB, imageSize: $imageSize)
                        .frame(height: 440)
                    HStack(spacing: 10) {
                        Text(pointA == nil ? "Click point A" : pointB == nil ? "Now click point B" : "Line A–B on \(selectedFrame ?? "")")
                            .foregroundStyle(.secondary)
                        TextField("metres", text: $meters).textFieldStyle(.roundedBorder).frame(width: 90).onSubmit(add)
                        Text("m").foregroundStyle(.secondary)
                        TextField("note", text: $note, prompt: Text("e.g. patio edge, fence post to house corner")).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        Button("Add Measurement", systemImage: "plus") { add() }
                            .buttonStyle(.glassProminent)
                            .disabled(pointA == nil || pointB == nil || (Double(meters.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                        Button("Clear Points") { pointA = nil; pointB = nil }.disabled(pointA == nil)
                        Spacer()
                        TextField("bearing °", text: $bearingText).textFieldStyle(.roundedBorder).frame(width: 80).onSubmit(setNorth)
                        Button("Set North Here") { setNorth() }.help("Compass bearing you read standing where this frame was shot, facing the same way")
                            .disabled(Double(bearingText) == nil)
                    }
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Measurements").font(.headline)
                Text(items.isEmpty ? "none yet" : "\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let n = north {
                    Text("north: \(Format.number(n.bearing, digits: 1))° at \(n.frame)").font(.caption).foregroundStyle(.secondary)
                    Button("Clear North") { north = nil }.buttonStyle(.borderless).font(.caption)
                }
            }
            ForEach(items) { item in
                HStack(spacing: 12) {
                    ItemPreview(item: item, dir: env.recording(item.recording)?.imagesDir)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.2f m", item.meters)).font(.headline)
                        Text("\(item.frame) · \(env.recording(item.recording)?.rec.name ?? item.recording)").font(.caption).foregroundStyle(.secondary)
                        if let n = item.note, !n.isEmpty { Text(n).font(.caption) }
                    }
                    Spacer()
                    Button("Show") { selectedFrame = item.frame; sourceId = item.recording; pointA = CGPoint(x: item.a[0], y: item.a[1]); pointB = CGPoint(x: item.b[0], y: item.b[1]) }
                        .buttonStyle(.borderless)
                    Button("Remove", systemImage: "xmark.circle") { items.removeAll { $0.id == item.id } }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { if sourceId == nil { sourceId = videos.first?.rec.id } }
        .task(id: sourceId) {
            frames = []
            guard let dir = source?.imagesDir else { return }
            frames = await Task.detached { ManifestStore.frames(of: dir.deletingLastPathComponent()) }.value
            if selectedFrame == nil || !frames.contains(selectedFrame!) { selectedFrame = frames.count > 2 ? frames[frames.count / 3] : frames.first }
        }
        .onChange(of: selectedFrame) { _, _ in pointA = nil; pointB = nil }
    }

    private func add() {
        guard let a = pointA, let b = pointB, let f = selectedFrame, let src = sourceId,
              let m = Double(meters.replacingOccurrences(of: ",", with: ".")), m > 0 else { return }
        let n = (items.map { Int($0.id.dropFirst()) ?? 0 }.max() ?? 0) + 1
        items.append(MeasurementItem(id: "m\(n)", recording: src, frame: f, a: [a.x.rounded(), a.y.rounded()], b: [b.x.rounded(), b.y.rounded()],
                                     meters: m, note: note.isEmpty ? nil : note, imageSize: [Int(imageSize.width), Int(imageSize.height)], at: Format.now()))
        pointA = nil; pointB = nil; meters = ""; note = ""
    }

    private func setNorth() {
        guard let f = selectedFrame, let src = sourceId, let b = Double(bearingText) else { return }
        north = MeasurementNorth(recording: src, frame: f, bearing: b)
    }
}

/// Horizontal strip of frame thumbnails with a slider to scrub through the walk.
struct FrameStrip: View {
    let frames: [String]
    let dir: URL?
    @Binding var selected: String?
    @State private var index: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(frames, id: \.self) { f in
                            FileImage(url: dir?.appending(path: f), maxPixel: 200)
                                .frame(width: 66, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(f == selected ? Theme.accent : .clear, lineWidth: 2))
                                .onTapGesture { selected = f }
                                .id(f)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 118)
                .onChange(of: selected) { _, f in
                    if let f, let i = frames.firstIndex(of: f) { index = Double(i); withAnimation { proxy.scrollTo(f, anchor: .center) } }
                }
            }
            if frames.count > 1 {
                HStack {
                    Slider(value: $index, in: 0...Double(frames.count - 1), step: 1) { _ in selected = frames[Int(index)] }
                    Text(selected ?? "").font(Theme.mono).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                }
            }
        }
    }
}

/// The frame at full size; two clicks place A (red) and B (blue), stored in original pixels.
struct PointPicker: View {
    let url: URL
    @Binding var a: CGPoint?
    @Binding var b: CGPoint?
    @Binding var imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = fitRect(in: geo.size)
            let size = imageSize, pa = a, pb = b
            ZStack(alignment: .topLeading) {
                FileImage(url: url, maxPixel: 2400)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                Canvas { ctx, _ in
                    guard size != .zero else { return }
                    func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x / size.width * rect.width, y: rect.minY + p.y / size.height * rect.height) }
                    if let pa, let pb {
                        var path = Path(); path.move(to: pt(pa)); path.addLine(to: pt(pb))
                        ctx.stroke(path, with: .color(Theme.accent), lineWidth: 2)
                    }
                    for (p, color, label) in [(pa, Color.red, "A"), (pb, Color.blue, "B")] {
                        guard let p else { continue }
                        let c = pt(p)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(color), lineWidth: 2)
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(color))
                        ctx.draw(Text(label).font(.system(size: 12, weight: .bold)).foregroundStyle(color), at: CGPoint(x: c.x + 12, y: c.y - 10))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 1, coordinateSpace: .local) { loc in
                guard imageSize != .zero, rect.contains(loc) else { return }
                let px = CGPoint(x: (loc.x - rect.minX) / rect.width * imageSize.width, y: (loc.y - rect.minY) / rect.height * imageSize.height)
                if a == nil { a = px } else if b == nil { b = px } else { a = px; b = nil }
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .task(id: url) { imageSize = await Task.detached { ImageInfo.pixelSize(url) }.value ?? .zero }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        let aspect = imageSize.width / imageSize.height
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// A measurement item as its frame thumbnail with the line drawn on it.
struct ItemPreview: View {
    let item: MeasurementItem
    let dir: URL?
    var height: CGFloat = 96

    var body: some View {
        let w = CGFloat(item.imageSize?.first ?? 2160), h = CGFloat(item.imageSize?.last ?? 3840)
        let width = height * w / h
        ZStack(alignment: .topLeading) {
            FileImage(url: dir?.appending(path: item.frame), maxPixel: 300).frame(width: width, height: height)
            Canvas { ctx, _ in
                guard item.a.count >= 2, item.b.count >= 2 else { return }
                let a = CGPoint(x: item.a[0] / w * width, y: item.a[1] / h * height), b = CGPoint(x: item.b[0] / w * width, y: item.b[1] / h * height)
                var p = Path(); p.move(to: a); p.addLine(to: b)
                ctx.stroke(p, with: .color(Theme.accent), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - 3, y: a.y - 3, width: 6, height: 6)), with: .color(.red))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 3, y: b.y - 3, width: 6, height: 6)), with: .color(.blue))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
