import SwiftUI
import UniformTypeIdentifiers

/// A recipe the builder offers: one run kind, or a chain of kinds where each later run takes the previous one's asset.
struct Recipe: Identifiable, Hashable {
    let steps: [RunKind]
    let label: String
    let blurb: String
    let symbol: String

    var id: String { steps.map(\.rawValue).joined(separator: "+") }
    var outputLabel: String { steps.last!.outputLabel }
    var outputSymbol: String { steps.last!.outputSymbol }

    static let all: [Recipe] = [
        Recipe(steps: [.scan], label: RunKind.scan.label, blurb: RunKind.scan.blurb, symbol: RunKind.scan.symbol),
        Recipe(steps: [.extend], label: RunKind.extend.label, blurb: RunKind.extend.blurb, symbol: RunKind.extend.symbol),
        Recipe(steps: [.identify], label: RunKind.identify.label, blurb: RunKind.identify.blurb, symbol: RunKind.identify.symbol),
        Recipe(steps: [.layout], label: RunKind.layout.label, blurb: RunKind.layout.blurb, symbol: RunKind.layout.symbol),
        Recipe(steps: [.edit], label: RunKind.edit.label, blurb: RunKind.edit.blurb, symbol: RunKind.edit.symbol),
        Recipe(steps: [.scan, .identify, .layout], label: "Site plan from video",
               blurb: "Scan, identify what is where, then lay out, in one go. Add measurements now for true scale, or later for a re-solve.", symbol: "video.badge.waveform"),
        Recipe(steps: [.edit, .identify, .layout], label: "Clean up",
               blurb: "Remove what you marked, carry the inventory onto the new model, lay it out again.", symbol: "sparkles"),
    ]
    static func single(_ k: RunKind) -> Recipe { all.first { $0.steps == [k] }! }

    /// The earlier step whose output fills this slot of step `i`, if any: the latest one producing a kind the slot accepts.
    /// A "prior inventory" slot is fed by an inventory made *before* the model it will be re-lifted onto, so for the
    /// clean-up chain the identify step's prior comes from the user, not from the chain.
    func feeder(step i: Int, slot: InputSlot) -> Int? {
        guard i > 0, slot.key != "prior" else { return nil }
        return (0..<i).reversed().first { slot.accepts.contains(steps[$0].outputInputKind) }
    }

    /// The slots to fill: every step's slots except those an earlier step feeds.
    var slots: [RecipeSlot] {
        var out: [RecipeSlot] = []
        for (i, k) in steps.enumerated() {
            for s in k.slots where feeder(step: i, slot: s) == nil {
                out.append(RecipeSlot(step: i, slot: s))
            }
        }
        return out
    }
}

struct RecipeSlot: Identifiable, Hashable {
    let step: Int
    let slot: InputSlot
    var id: String { "\(step).\(slot.key)" }
}

/// Build a run: pick a recipe, drag its inputs in from the bucket of what the environment has, start.
struct NewRunSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let request: NewRunRequest

    @State private var recipe: Recipe
    @State private var filled: [String: [InputRef]] = [:]
    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var showSettings = false
    @State private var busy = false

    init(request: NewRunRequest) {
        self.request = request
        _recipe = State(initialValue: Recipe.single(request.kind))
    }

    private var env: EnvironmentRecord? { ws.environment(request.envId) }

    private var complete: Bool {
        recipe.slots.allSatisfy { s in (filled[s.id]?.count ?? 0) >= s.slot.min }
    }
    private var missing: [RecipeSlot] { recipe.slots.filter { (filled[$0.id]?.count ?? 0) < $0.slot.min } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New run").font(Theme.display(26))
                Text("Pick what to make, then drag its inputs in from \(env?.env.name ?? "the environment"). Every run publishes one asset; earlier ones stay in the history.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            recipes.padding(.horizontal, 24)
            HStack(alignment: .top, spacing: 18) {
                bucket.frame(width: 300)
                VStack(alignment: .leading, spacing: 14) {
                    slotsView
                    RecipeRail(recipe: recipe, ready: complete)
                    DisclosureGroup(isExpanded: $showSettings) {
                        Form {
                            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { _, k in
                                Section(k.label) {
                                    switch k {
                                    case .layout: LayoutSettingsForm(settings: $settings)
                                    case .identify: IdentifySettingsForm(settings: $settings)
                                    case .edit: EditSettingsForm(settings: $settings)
                                    case .scan, .extend: ReconstructSettingsForm(settings: $settings)
                                    }
                                }
                            }
                            TextField("Label", text: $label, prompt: Text("optional, e.g. learned features"))
                        }
                        .formStyle(.grouped)
                        .frame(height: recipe.steps.count > 1 ? 360 : 250)
                    } label: {
                        Text("Settings · \(Format.settingsLine(kind: recipe.steps.first!, settings))").font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            HStack {
                Text(complete ? "Ready." : "Still needed: " + missing.map { $0.slot.label.lowercased() }.joined(separator: ", ") + ".")
                    .font(.caption).foregroundStyle(complete ? Theme.ok : .secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Starting…" : "Start Run") { start() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!complete || busy)
            }
            .padding(20)
        }
        .frame(width: 1000, height: showSettings ? 860 : 680)
        .task { prefill() }
        .onChange(of: recipe) { _, _ in prune() }
    }

    // MARK: recipes

    private var recipes: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 215, maximum: 320), spacing: 10)], alignment: .leading, spacing: 10) {
            ForEach(Recipe.all) { r in
                let on = r == recipe
                Button { recipe = r } label: {
                    HStack(spacing: 10) {
                        Image(systemName: r.symbol).font(.title3).foregroundStyle(on ? Theme.accent : .secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.headline).lineLimit(1)
                            Text(r.steps.map(\.verb).joined(separator: " → ") + " → \(r.outputLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(on ? Theme.accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.accent : Color(nsColor: .separatorColor), lineWidth: on ? 1.5 : 1))
            }
        }
    }

    // MARK: the bucket: everything in the environment that a run can take

    private var bucket: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inputs available").font(.headline)
            Text("Drag onto a slot, or click to place.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let env {
                        if !env.recordings.isEmpty { Text("Recordings").font(.caption).foregroundStyle(.secondary).padding(.top, 4) }
                        ForEach(env.recordings) { r in
                            let ref = InputRef(kind: r.rec.inputKind, id: r.rec.id)
                            InputChip(ref: ref, name: r.rec.name, detail: detail(r), thumbnail: r.thumbnail,
                                      usable: canPlace(ref) != nil, placed: isPlaced(ref)) { place(ref) }
                        }
                        if !env.assets.isEmpty { Text("Assets").font(.caption).foregroundStyle(.secondary).padding(.top, 8) }
                        ForEach(env.assets.reversed()) { a in
                            let ref = InputRef(kind: a.asset.kind.inputKind, id: a.asset.id)
                            InputChip(ref: ref, name: a.asset.name, detail: Format.when(a.asset.createdAt), thumbnail: a.thumbnail,
                                      usable: canPlace(ref) != nil, placed: isPlaced(ref)) { place(ref) }
                        }
                        if env.recordings.isEmpty && env.assets.isEmpty {
                            Text("Nothing yet. Add a recording first.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detail(_ r: RecordingRecord) -> String {
        if r.isMeasurements { return "\(r.rec.items.count) measurement\(r.rec.items.count == 1 ? "" : "s")" + (r.rec.north != nil ? " · north" : "") }
        if r.isMarks {
            if r.isGenerated { return "inventory · \(r.rec.marks.count) entities · on \(r.rec.markModel ?? "?")" }
            let edits = r.rec.marks.filter(\.isEdit).count
            return "\(r.rec.marks.count) mark\(r.rec.marks.count == 1 ? "" : "s")" + (edits > 0 ? " · \(edits) edit\(edits == 1 ? "" : "s")" : "") + " · on \(r.rec.markModel ?? "?")"
        }
        return Format.videoLine(r.rec.source) + (r.rec.frames.status == .done ? "" : " · frames \(r.rec.frames.status.rawValue)")
    }

    // MARK: slots

    private var slotsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recipe.blurb).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(recipe.slots) { s in
                    SlotView(slot: s, refs: filled[s.id] ?? [], names: names, stepLabel: recipe.steps.count > 1 ? recipe.steps[s.step].label : nil,
                             onDrop: { tokens in drop(tokens, into: s) },
                             onRemove: { ref in filled[s.id]?.removeAll { $0 == ref } })
                }
            }
        }
    }

    private func names(_ ref: InputRef) -> String {
        guard let env else { return ref.id }
        return ref.kind.isAsset ? (env.asset(ref.id)?.asset.name ?? ref.id) : (env.recording(ref.id)?.rec.name ?? ref.id)
    }

    private func canPlace(_ ref: InputRef) -> RecipeSlot? {
        recipe.slots.first { s in s.slot.accepts(ref.kind) && (filled[s.id]?.count ?? 0) < s.slot.max && !(filled[s.id]?.contains(ref) ?? false) }
            ?? recipe.slots.first { s in s.slot.accepts(ref.kind) && s.slot.isSingle }
    }
    private func isPlaced(_ ref: InputRef) -> Bool { filled.values.contains { $0.contains(ref) } }

    private func place(_ ref: InputRef) {
        guard let s = canPlace(ref) else { return }
        insert(ref, into: s)
    }

    private func insert(_ ref: InputRef, into s: RecipeSlot) {
        guard s.slot.accepts(ref.kind) else { return }
        var list = filled[s.id] ?? []
        if list.contains(ref) { return }
        if s.slot.isSingle { list = [ref] } else if list.count < s.slot.max { list.append(ref) } else { return }
        filled[s.id] = list
    }

    private func drop(_ tokens: [String], into s: RecipeSlot) -> Bool {
        let refs = tokens.compactMap(InputRef.init(token:)).filter { s.slot.accepts($0.kind) }
        guard !refs.isEmpty else { return false }
        for r in refs { insert(r, into: s) }
        return true
    }

    /// Sensible starting point: the request's input, else the newest thing that fits each required slot; every
    /// measurement recording for a layout; the marks and inventory made on the chosen model.
    private func prefill() {
        guard let env else { return }
        filled = [:]
        if let id = request.inputId {
            let kind: InputKind = env.asset(id).map { $0.asset.kind.inputKind } ?? (env.recording(id)?.rec.inputKind ?? .video)
            place(InputRef(kind: kind, id: id))
        }
        fillGaps(env)
    }

    /// The model a recipe works on (its first 3D-model slot), if chosen.
    private var chosenModel: AssetRecord? {
        guard let env else { return nil }
        for s in recipe.slots where s.slot.accepts(.model3d) {
            if let ref = filled[s.id]?.first { return env.asset(ref.id) }
        }
        return nil
    }

    private func fillGaps(_ env: EnvironmentRecord) {
        for s in recipe.slots where s.slot.isRequired && (filled[s.id] ?? []).isEmpty {
            if s.slot.accepts(.model3d), let a = env.models.last { insert(InputRef(kind: .model3d, id: a.asset.id), into: s) }
            else if s.slot.accepts(.video), let r = env.videoRecordings.last { insert(InputRef(kind: .video, id: r.rec.id), into: s) }
        }
        let model = chosenModel
        for s in recipe.slots where (filled[s.id] ?? []).isEmpty {
            if s.slot.accepts(.measurements) { for m in env.measurementRecordings { insert(InputRef(kind: .measurements, id: m.rec.id), into: s) } }
            guard s.slot.accepts(.marks), let model else { continue }
            if s.slot.key == "prior" {
                // a lone identify re-lifts a prior inventory only when the model is an edit of one that has an inventory
                if model.asset.derivedFrom != nil, let inv = env.inventory(for: model) { insert(InputRef(kind: .marks, id: inv.rec.id), into: s) }
            } else {
                // every marks recording on this model's frame: your marks and the newest generated inventory
                for m in env.humanMarks(for: model) { insert(InputRef(kind: .marks, id: m.rec.id), into: s) }
                if let inv = env.inventory(for: model) { insert(InputRef(kind: .marks, id: inv.rec.id), into: s) }
            }
        }
    }

    /// After switching recipe: keep what still fits, drop the rest, then fill the gaps.
    private func prune() {
        let old = filled.values.flatMap { $0 }
        filled = [:]
        for ref in old { place(ref) }
        if let env { fillGaps(env) }
    }

    private func start() {
        busy = true
        var steps: [RunStep] = []
        for (i, k) in recipe.steps.enumerated() {
            var inputs: [String: [String]] = [:]
            var refs: [String: Int] = [:]
            for s in k.slots {
                if let j = recipe.feeder(step: i, slot: s) { refs[s.key] = j }
                else if let rs = recipe.slots.first(where: { $0.step == i && $0.slot.key == s.key }) { inputs[s.key] = (filled[rs.id] ?? []).map(\.id) }
            }
            steps.append(RunStep(kind: k, inputs: inputs, settings: settings, label: label, refs: refs))
        }
        Task {
            let ok = await ws.createRuns(env: request.envId, steps: steps)
            busy = false
            if ok { dismiss() }
        }
    }
}

/// A thing in the bucket: draggable, clickable, dimmed when the recipe has no slot for it.
struct InputChip: View {
    let ref: InputRef
    let name: String
    let detail: String
    let thumbnail: URL?
    let usable: Bool
    let placed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let t = thumbnail { FileImage(url: t, maxPixel: 200).aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(.quaternary).overlay { Image(systemName: ref.kind.symbol).foregroundStyle(.secondary) } }
                }
                .frame(width: 44, height: 30).clipShape(RoundedRectangle(cornerRadius: 5)).clipped()
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1)
                        Text(ref.kind.label.lowercased()).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if placed { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                else if usable { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
            }
            .padding(6)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            .contentShape(Rectangle())
            .opacity(usable || placed ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .draggable(ref.token)
        .help(usable ? "Drag onto a slot, or click to place it" : placed ? "Placed" : "This recipe has no slot for a \(ref.kind.label.lowercased())")
    }
}

/// A drop target of the recipe: dashed while empty, showing what it takes; filled with chips once given inputs.
struct SlotView: View {
    let slot: RecipeSlot
    let refs: [InputRef]
    let names: (InputRef) -> String
    let stepLabel: String?
    let onDrop: ([String]) -> Bool
    let onRemove: (InputRef) -> Void
    @State private var over = false

    private var satisfied: Bool { refs.count >= slot.slot.min }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: slot.slot.accepts.first?.symbol ?? "tray").foregroundStyle(satisfied ? Theme.accent : .secondary)
                Text(slot.slot.label).font(.headline)
                if !slot.slot.isRequired { Text("optional").font(.caption2).foregroundStyle(.secondary) }
                if let stepLabel { Spacer(); Text(stepLabel).font(.caption2).foregroundStyle(.tertiary) }
            }
            if refs.isEmpty {
                Text("drop " + slot.slot.accepts.map { $0.label.lowercased() }.joined(separator: " or ") + (slot.slot.isSingle ? "" : " (up to \(slot.slot.max))"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                ForEach(refs) { r in
                    HStack(spacing: 6) {
                        Image(systemName: r.kind.symbol).foregroundStyle(Theme.accent).frame(width: 14)
                        Text(names(r)).font(.callout).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "xmark.circle.fill") { onRemove(r) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                if !slot.slot.isSingle && refs.count < slot.slot.max {
                    Text("drop more").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .top)
        .background(over ? Theme.accent.opacity(0.08) : (satisfied ? Theme.accent.opacity(0.04) : Color.clear), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(over ? Theme.accent : satisfied ? Theme.accent.opacity(0.6) : Color(nsColor: .separatorColor),
                          style: StrokeStyle(lineWidth: over ? 2 : 1.2, dash: satisfied ? [] : [6, 4])))
        .dropDestination(for: String.self) { tokens, _ in onDrop(tokens) } isTargeted: { over = $0 }
    }
}

/// The recipe's stages as a rail: grey until every required slot is filled, then in colour, ending in the asset.
struct RecipeRail: View {
    let recipe: Recipe
    let ready: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, k in
                if i > 0 {
                    node(symbol: recipe.steps[i - 1].outputSymbol, text: recipe.steps[i - 1].outputLabel, strong: true)
                    connector
                }
                ForEach(Array(k.stages.enumerated()), id: \.offset) { j, s in
                    if j > 0 { connector }
                    node(symbol: nil, text: ManifestStore.stageLabels[s] ?? s, strong: false)
                }
                connector
            }
            node(symbol: recipe.outputSymbol, text: recipe.outputLabel, strong: true)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(ready ? 1 : 0.45)
        .saturation(ready ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: ready)
    }

    private var connector: some View {
        Rectangle().fill(ready ? Theme.accent.opacity(0.6) : Color.secondary.opacity(0.4)).frame(height: 2).frame(maxWidth: .infinity)
    }

    private func node(symbol: String?, text: String, strong: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(strong ? Theme.accent.opacity(ready ? 0.9 : 0.5) : Color(nsColor: .controlBackgroundColor)).frame(width: strong ? 26 : 14, height: strong ? 26 : 14)
                Circle().strokeBorder(Theme.accent, lineWidth: strong ? 0 : 2).frame(width: 14, height: 14)
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white) }
            }
            Text(text).font(.caption2).foregroundStyle(strong ? .primary : .secondary).lineLimit(1).fixedSize()
        }
    }
}
