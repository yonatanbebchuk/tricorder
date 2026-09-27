import SwiftUI

/// Tape-measure prompts: distances between two picked points, the ground check, the north bearing.
/// Answers go straight to measure/answers.json, the same file solve_scale.py reads.
struct MeasurePanel: View {
    @Environment(Workspace.self) private var ws
    let scan: ScanRecord
    let record: RunRecord

    var body: some View {
        if let p = record.prompts {
            let answers = record.answers
            let shown = Self.shown(p, answers)
            let answered = p.distances.filter { (answers[$0.id]?.value ?? 0) > 0 }.count
            let busy = record.isRunning
            Card("Measure") {
                Text("Take a tape or laser measure to the site. For each pair find the red and blue points (left: where in the frame; right: zoom), measure the straight-line distance between them and enter it in metres. Long spans matter more than many. Skip anything you can't identify or that has moved; another prompt takes its place.")
                    .foregroundStyle(.secondary)
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, prompt in
                    DistancePromptCard(index: i + 1, prompt: prompt, record: record)
                }
                if let g = p.prompts.first(where: { $0.type == "ground" }) { GroundPromptCard(prompt: g, record: record) }
                if let n = p.prompts.first(where: { $0.type == "north" }) { NorthPromptCard(prompt: n, record: record) }
                HStack {
                    Text("\(answered) of \(p.count) measurements entered" + (answered == 0 ? " · at least one is needed" : ""))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(busy ? "Working…" : record.transform != nil ? "Recompute Scale & Re-render Plan" : "Compute Scale & Render Plan") {
                        Task { await ws.startPlan(record) }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(answered == 0 || busy || !record.hasTexturedMesh)
                    .help(record.hasTexturedMesh ? "solve_scale.py + Blender render" : "No textured mesh yet")
                }
                .padding(.top, 6)
            }
        }
    }

    /// The first `count` distance prompts, plus one replacement for each skipped one (same rule as the web UI).
    static func shown(_ p: PromptSet, _ answers: [String: Answer]) -> [Prompt] {
        let dist = p.distances
        var shown: [Prompt] = []
        var extra = 0
        for x in dist {
            if shown.count >= p.count { break }
            shown.append(x)
            if answers[x.id]?.skipped == true { extra += 1 }
        }
        for x in dist {
            if shown.count >= p.count + extra { break }
            if !shown.contains(where: { $0.id == x.id }) { shown.append(x) }
        }
        return shown
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
    let record: RunRecord
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
    let record: RunRecord

    @State private var text = ""
    @FocusState private var focused: Bool

    private var answer: Answer? { record.answers[prompt.id] }
    private var skipped: Bool { answer?.skipped == true }
    private var answered: Bool { (answer?.value ?? 0) > 0 }

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
                        Button("Un-skip") { save(nil) }
                    } else {
                        Button("Can’t measure this") { save(Answer(skipped: true)) }
                    }
                }
            }
        }
        .onAppear { text = answer?.value.map { Format.number($0) } ?? "" }
        .onChange(of: answer?.value) { _, v in text = v.map { Format.number($0) } ?? "" }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private var structural: String { prompt.a?.structural == true && prompt.b?.structural == true ? "structural corners" : "" }
    private var units: String {
        guard let d = prompt.modelDist else { return "" }
        var s = "(\(String(format: "%.2f", d)) model units"
        if let t = record.transform { s += " ≈ \(String(format: "%.2f", d * t.scale)) m" }
        return s + ")"
    }

    private func commit() {
        let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0
        let current = answer?.value ?? 0
        if v > 0, v != current { save(Answer(value: v)) }
        else if v <= 0, current > 0 { save(nil) }
    }

    private func save(_ a: Answer?) {
        Task { await ws.saveAnswer(record, promptId: prompt.id, answer: a) }
    }
}

struct GroundPromptCard: View {
    @Environment(Workspace.self) private var ws
    let prompt: Prompt
    let record: RunRecord

    private var confirmed: Bool? { record.answers["g1"]?.confirmed }

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
        Task { await ws.saveAnswer(record, promptId: "g1", answer: Answer(confirmed: v)) }
    }
}

struct NorthPromptCard: View {
    @Environment(Workspace.self) private var ws
    let prompt: Prompt
    let record: RunRecord

    @State private var text = ""
    @FocusState private var focused: Bool

    private var bearing: Double? { record.answers["n1"]?.bearing }

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
        Task { await ws.saveAnswer(record, promptId: "n1", answer: v.map { Answer(bearing: $0) }) }
    }
}
