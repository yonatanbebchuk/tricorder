import SwiftUI

/// Tape-measure prompts (spans between picked points, the ground check, the north bearing) and the list of every
/// measurement entered so far. Everything is written to the 3D model's measure/constraints.json, the file the
/// layout run's scale solver reads; points travel with each constraint so the solver never needs the prompts.
struct MeasurePanel: View {
    @Environment(Workspace.self) private var ws
    let record: AssetRecord

    var body: some View {
        if let p = record.prompts {
            let c = record.constraints
            let shown = Self.shown(p, c)
            Card("Measure") {
                Text("Take a tape or laser measure to the site. For each pair find the red and blue points (left: where in the frame; right: zoom), measure the straight-line distance between them and enter it in metres. Long spans matter more than many. Skip anything you can't identify or that has moved; another prompt takes its place.")
                    .foregroundStyle(.secondary)
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, prompt in
                    DistancePromptCard(index: i + 1, prompt: prompt, record: record)
                }
                if let g = p.prompts.first(where: { $0.type == "ground" }) { GroundPromptCard(prompt: g, record: record) }
                if let n = p.prompts.first(where: { $0.type == "north" }) { NorthPromptCard(prompt: n, record: record) }
                MeasurementList(record: record)
            }
        }
    }

    /// The first `count` distance prompts, plus one replacement for each skipped one.
    static func shown(_ p: PromptSet, _ c: Constraints) -> [Prompt] {
        let dist = p.distances
        var shown: [Prompt] = []
        var extra = 0
        for x in dist {
            if shown.count >= p.count { break }
            shown.append(x)
            if c.isSkipped(x.id) { extra += 1 }
        }
        for x in dist {
            if shown.count >= p.count + extra { break }
            if !shown.contains(where: { $0.id == x.id }) { shown.append(x) }
        }
        return shown
    }
}

/// Every constraint on the model, whatever its source, with its residual against the mean scale.
struct MeasurementList: View {
    @Environment(Workspace.self) private var ws
    let record: AssetRecord

    private var c: Constraints { record.constraints }
    private var meanScale: Double? {
        let f = c.distances.compactMap { $0.modelDistance > 0 ? $0.meters / $0.modelDistance : nil }
        return f.isEmpty ? nil : f.reduce(0, +) / Double(f.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Measurements").font(.headline)
                Text(c.distances.isEmpty ? "none yet · at least one is needed for a layout" : "\(c.distances.count) entered" + (c.distances.count > 1 ? " · residuals against their mean scale" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(c.distances) { d in
                HStack(spacing: 10) {
                    Text(d.id).font(Theme.mono).frame(width: 60, alignment: .leading)
                    SourceBadge(source: d.source)
                    Text(String(format: "%.2f m", d.meters)).fontWeight(.medium)
                    Text(String(format: "%.2f model units", d.modelDistance)).font(.caption).foregroundStyle(.secondary)
                    if let s = meanScale, c.distances.count > 1, d.modelDistance > 0 {
                        let res = (d.meters / d.modelDistance / s - 1) * d.meters * 100
                        Text(String(format: "%@%.1f cm", res >= 0 ? "+" : "", res)).font(Theme.mono).foregroundStyle(abs(res) > 5 ? Theme.bad : .secondary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle") { remove(d) }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Image(systemName: c.level?.confirmed == true ? "checkmark.circle.fill" : "circle").foregroundStyle(c.level?.confirmed == true ? Theme.ok : .secondary)
                    Text(c.level == nil ? "level: automatic" : c.level!.confirmed ? "level: 3 confirmed ground points" : "level: automatic (points rejected)")
                }
                HStack(spacing: 5) {
                    Image(systemName: c.north != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(c.north != nil ? Theme.ok : .secondary)
                    Text(c.north.map { "north: bearing \(Format.number($0.bearing, digits: 1))°" } ?? "north: not set (plan keeps the model's orientation)")
                }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func remove(_ d: DistanceConstraint) {
        Task { await ws.updateConstraints(record) { $0.distances.removeAll { $0.id == d.id } } }
    }
}

struct SourceBadge: View {
    let source: String
    var body: some View {
        Text(source).font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(.quaternary, in: Capsule()).foregroundStyle(.secondary)
    }
}

private struct PromptFrame<Content: View>: View {
    let answered: Bool
    let skipped: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((answered ? Theme.ok.opacity(0.07) : Color.clear), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(answered ? Theme.ok.opacity(0.5) : Color(nsColor: .separatorColor)))
            .opacity(skipped ? 0.55 : 1)
    }
}

private struct PromptTitle: View {
    var index: Int? = nil
    let kind: String
    var detail: String = ""
    var caption: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let index { Text("\(index) ·").font(Theme.display(17)) }
            Text(kind).font(Theme.display(17)).italic().foregroundStyle(Theme.accent)
            if !detail.isEmpty { Text("· \(detail)").font(.callout) }
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Context frame (where in the picture) next to the zoomed crop.
struct PointFigure: View {
    let point: PromptPoint?
    let caption: String
    let record: AssetRecord
    var height: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FileImage(url: point?.context.map(record.url), maxPixel: 900).frame(height: height)
                    .help(point?.frame.map { "frame \($0)" } ?? "")
                FileImage(url: point?.crop.map(record.url), maxPixel: 900).frame(height: height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DistancePromptCard: View {
    @Environment(Workspace.self) private var ws
    let index: Int
    let prompt: Prompt
    let record: AssetRecord

    @State private var text = ""
    @FocusState private var focused: Bool

    private var constraint: DistanceConstraint? { record.constraints.distance(forPrompt: prompt.id) }
    private var skipped: Bool { record.constraints.isSkipped(prompt.id) }
    private var answered: Bool { constraint != nil }

    var body: some View {
        PromptFrame(answered: answered, skipped: skipped) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PromptTitle(index: index, kind: prompt.kindLabel,
                                caption: [structural, units].filter { !$0.isEmpty }.joined(separator: "  "))
                    Spacer()
                    if answered { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                }
                HStack(alignment: .top, spacing: 14) {
                    PointFigure(point: prompt.a, caption: "A · red", record: record)
                    PointFigure(point: prompt.b, caption: "B · blue", record: record)
                }
                HStack(spacing: 8) {
                    TextField("metres", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .focused($focused)
                        .disabled(skipped)
                        .onSubmit(commit)
                    Text("m").foregroundStyle(.secondary)
                    if skipped {
                        Button("Un-skip") { update { $0.skippedPrompts.removeAll { $0 == prompt.id } } }
                    } else {
                        Button("Can’t measure this") {
                            update { c in c.skippedPrompts.append(prompt.id); c.distances.removeAll { $0.promptId == prompt.id } }
                        }
                    }
                }
            }
        }
        .onAppear { text = constraint.map { Format.number($0.meters) } ?? "" }
        .onChange(of: constraint?.meters) { _, v in text = v.map { Format.number($0) } ?? "" }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private var structural: String { prompt.a?.structural == true && prompt.b?.structural == true ? "structural corners" : "" }
    private var units: String {
        guard let d = prompt.modelDist else { return "" }
        return "(\(String(format: "%.2f", d)) model units)"
    }

    private func commit() {
        let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        let current = constraint?.meters ?? 0
        guard v != current else { return }
        guard let a = prompt.a?.xyz, let b = prompt.b?.xyz else { return }
        let id = prompt.id
        update { c in
            c.distances.removeAll { $0.promptId == id }
            if v > 0 {
                c.distances.append(DistanceConstraint(id: "m-\(id)", source: "prompt", promptId: id, a: a, b: b, meters: v, note: nil, at: Format.now()))
                c.skippedPrompts.removeAll { $0 == id }
            }
        }
    }

    private func update(_ mutate: @escaping @Sendable (inout Constraints) -> Void) {
        Task { await ws.updateConstraints(record, mutate) }
    }
}

struct GroundPromptCard: View {
    @Environment(Workspace.self) private var ws
    let prompt: Prompt
    let record: AssetRecord

    private var confirmed: Bool? { record.constraints.level?.confirmed }

    var body: some View {
        PromptFrame(answered: confirmed == true, skipped: false) {
            VStack(alignment: .leading, spacing: 10) {
                PromptTitle(kind: "level", detail: prompt.text ?? "")
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array((prompt.points ?? []).enumerated()), id: \.offset) { i, pt in
                        PointFigure(point: pt, caption: "ground point \(i + 1)", record: record, height: 180)
                    }
                }
                HStack(spacing: 8) {
                    Button("Yes, all on the ground") { save(true) }
                        .buttonStyle(.borderedProminent).tint(confirmed == true ? Theme.accent : .gray)
                    Button("No (automatic levelling)") { save(false) }
                        .buttonStyle(.borderedProminent).tint(confirmed == false ? Theme.accent : .gray)
                }
            }
        }
    }

    private func save(_ v: Bool) {
        let pts = (prompt.points ?? []).compactMap(\.xyz)
        Task { await ws.updateConstraints(record) { $0.level = LevelConstraint(source: "prompt", confirmed: v, points: pts) } }
    }
}

struct NorthPromptCard: View {
    @Environment(Workspace.self) private var ws
    let prompt: Prompt
    let record: AssetRecord

    @State private var text = ""
    @FocusState private var focused: Bool

    private var bearing: Double? { record.constraints.north?.bearing }

    var body: some View {
        PromptFrame(answered: bearing != nil, skipped: false) {
            VStack(alignment: .leading, spacing: 10) {
                PromptTitle(kind: "north", detail: prompt.text ?? "")
                VStack(alignment: .leading, spacing: 4) {
                    FileImage(url: prompt.context.map(record.url), maxPixel: 1200).frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(prompt.frame.map { "frame \($0)" } ?? "").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    TextField("bearing °", text: $text)
                        .textFieldStyle(.roundedBorder).frame(width: 110)
                        .focused($focused).onSubmit(commit)
                    Text("degrees, 0 = north, 90 = east").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { text = bearing.map { Format.number($0, digits: 1) } ?? "" }
        .onChange(of: bearing) { _, v in text = v.map { Format.number($0, digits: 1) } ?? "" }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        if v == bearing { return }
        let frame = prompt.frame, forward = prompt.forward
        Task { await ws.updateConstraints(record) { $0.north = v.map { NorthConstraint(source: "prompt", frame: frame, forward: forward, bearing: $0) } } }
    }
}
