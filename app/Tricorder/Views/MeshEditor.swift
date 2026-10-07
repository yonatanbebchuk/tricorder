import SceneKit
import SwiftUI
import simd

/// The full-view mesh editor: the model fills the page; a click lands a dot on the surface, dots join into lines or close
/// into polygons, a class names them. Entities from the model's inventory are drawn as proposals you can accept, reject or
/// remove; two clicks plus the taped metres make a measurement; `remove` and `patch` marks drive the edit run.
/// Points are stored in the model's own frame: the preview USDZ was exported with the levelled transform and Blender's
/// axis conversion, so a SceneKit world point p is levelled (p.x, -p.z, p.y) and model = inverse(levelled) · that.
struct MeshEditorView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: AssetRecord
    var initialRecording: String? = nil

    /// What a right-click offers, where it happened.
    struct Action: Identifiable {
        let id = UUID()
        let point: SIMD3<Double>      // model frame
        let screen: CGPoint
        let hit: Bool                 // on the mesh, or in a hole (projected onto the ground plane)
        let entity: MarkItem?
        let editMark: MarkItem?
    }

    enum Tool: String, CaseIterable, Identifiable {
        case select, element, edit, measure
        var id: String { rawValue }
        var label: String { switch self { case .select: "Select"; case .element: "Mark"; case .edit: "Edit"; case .measure: "Measure" } }
        var symbol: String { switch self { case .select: "cursorarrow"; case .element: "pencil.and.outline"; case .edit: "scissors"; case .measure: "ruler" } }
    }

    @State private var tool: Tool = .select
    @State private var cls = "area"
    @State private var editCls = "remove"
    @State private var material = "grass"
    @State private var shape = "polygon"
    @State private var name = ""
    @State private var note = ""
    @State private var text = ""
    @State private var meters = ""
    @State private var current: [SIMD3<Double>] = []          // the points being placed, model frame
    @State private var marks: [MarkItem] = []
    @State private var marksRecordingId: String?
    @State private var measureRecordingId: String?
    @State private var selectedEntity: String?
    @State private var selectedMark: String?
    @State private var showEntities = true
    @State private var showMarks = true
    @State private var status = ""
    @State private var resetToken = 0
    @State private var action: Action?
    @State private var startingEdit = false

    private var inventory: RecordingRecord? { env.inventory(for: record) }
    /// The entities the inventory proposes, as marks items (each stands for one entity).
    private var entities: [MarkItem] { inventory?.rec.marks ?? [] }
    private var humanRecordings: [RecordingRecord] { env.humanMarks(for: record) }
    private var levelled: simd_double4x4 {
        guard let m = record.levelled, m.count == 4 else { return matrix_identity_double4x4 }
        return simd_double4x4(rows: m.map { SIMD4<Double>($0[0], $0[1], $0[2], $0[3]) })
    }
    private var marksRecording: RecordingRecord? { marksRecordingId.flatMap { env.recording($0) } }
    private var entityStates: [String: String] {           // entity id -> accepted | rejected | removed
        var d: [String: String] = [:]
        for m in marks {
            guard let e = m.entity else { continue }
            if m.isEdit && m.cls == "remove" { d[e] = "removed" } else if m.reject == true { d[e] = "rejected" } else if d[e] == nil { d[e] = "accepted" }
        }
        return d
    }

    var body: some View {
        HStack(spacing: 0) {
            viewer
            Divider()
            panel.frame(width: 320)
        }
        .navigationTitle("\(record.asset.name) · full view")
        .navigationSubtitle(status.isEmpty ? "click the mesh to place a point · drag to orbit · scroll to zoom · ⌥ drag to pan" : status)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { t in Label(t.label, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tool) { _, _ in current = [] }
                Toggle("Entities", systemImage: "tag", isOn: $showEntities).disabled(entities.isEmpty)
                Toggle("Marks", systemImage: "pencil.and.outline", isOn: $showMarks)
                Button("Recenter", systemImage: "scope") { resetToken += 1 }
            }
        }
        .task(id: record.id) { adoptExistingMarks() }
    }

    private func entityId(_ e: MarkItem) -> String { e.entity ?? e.id }

    // MARK: the 3D view with overlays

    private var viewer: some View {
        ZStack(alignment: .bottomLeading) {
            if let preview = record.preview {
                EditableModelView(url: preview, overlays: overlays, resetToken: resetToken, onPick: { world in picked(world) },
                                  onContext: { world, screen, hit in contextClicked(world, at: screen, hit: hit) })
                if let a = action { actionCard(a) }
            } else {
                ContentUnavailableView("No 3D preview for this model", systemImage: "cube.transparent", description: Text("Run its scan again to export one."))
            }
            if !current.isEmpty || tool != .select {
                HStack(spacing: 10) {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                    if !current.isEmpty {
                        Button("Undo Point") { _ = current.popLast() }.font(.caption)
                        if tool != .measure {
                            Button(shape == "polygon" ? "Close Polygon" : shape == "line" ? "Finish Line" : "Place", systemImage: "checkmark") { finishMark() }
                                .font(.caption).buttonStyle(.glassProminent).disabled(current.count < minPoints)
                        }
                        Button("Cancel") { current = [] }.font(.caption)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6).glassEffect().padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var minPoints: Int { shape == "polygon" ? 3 : shape == "line" ? 2 : 1 }

    // MARK: right-click: what to do here

    private func contextClicked(_ world: SIMD3<Float>, at screen: CGPoint, hit: Bool) {
        let p = toModel(world)
        let e = hit ? entityAt(p) : nil
        let em = editMarkAt(p)
        action = Action(point: p, screen: screen, hit: hit, entity: e, editMark: em)
    }

    /// A person's edit polygon containing the point.
    private func editMarkAt(_ p: SIMD3<Double>) -> MarkItem? {
        let q = levelledXY(p)
        return marks.first { m in
            guard m.isEdit, m.points.count >= 3 else { return false }
            return Self.inside(q, m.points.compactMap { $0.count >= 3 ? levelledXY(SIMD3<Double>($0[0], $0[1], $0[2])) : nil })
        }
    }

    private func actionCard(_ a: Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = a.entity {
                Text(e.displayName).font(.headline)
                Text([e.cls, e.material, e.areaM2.map { String(format: "%.1f m²", $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Button("Remove", systemImage: "scissors") { removeEntity(e); action = nil }
                Button("Remove & Run Edit", systemImage: "play.fill") { removeEntity(e); action = nil; runEdit() }
                Button("Accept", systemImage: "checkmark") { acceptEntity(e); action = nil }
                Button("Reject", systemImage: "xmark") { acceptEntity(e, reject: true); action = nil }
            } else if let m = a.editMark {
                Text(m.displayName).font(.headline)
                Text("\(m.cls) mark").font(.caption).foregroundStyle(.secondary)
                Button("Run Edit Now", systemImage: "play.fill") { action = nil; runEdit() }
                Button("Delete Mark", systemImage: "trash") { delete(m); action = nil }
            } else {
                Text(a.hit ? "Ground here" : "Hole here").font(.headline)
                Text(a.hit ? "Nothing identified at this point." : "No mesh under the click; the point is on the ground plane.").font(.caption).foregroundStyle(.secondary)
                Button("Patch Here", systemImage: "bandage") { patchHere(a.point); action = nil }
                    .help("The edit run finds the hole around this point and fills it on the surrounding ground")
                Button("Patch Here & Run Edit", systemImage: "play.fill") { patchHere(a.point); action = nil; runEdit() }
                Button("Outline a Region to Remove…", systemImage: "scissors") { tool = .edit; editCls = "remove"; current = [a.point]; action = nil }
            }
            Divider()
            Button("Cancel") { action = nil }
        }
        .buttonStyle(.borderless)
        .padding(10)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .position(x: a.screen.x + 125, y: a.screen.y + 90)
    }

    private func patchHere(_ p: SIMD3<Double>) {
        let item = MarkItem(id: "p\(Int(Date().timeIntervalSince1970))", role: "edit", cls: "patch", shape: "point", points: [[p.x, p.y, p.z]],
                            name: "patch here", text: text.isEmpty ? nil : text, at: Format.now())
        Task { await save(marks + [item]) }
    }

    /// An edit run on this model with every marks recording on its frame (your marks and the inventory).
    private func runEdit() {
        guard !startingEdit else { return }
        startingEdit = true
        Task {
            // the save that preceded this may still be in flight: let it land first
            try? await Task.sleep(for: .milliseconds(400))
            await ws.refresh()
            var ids = env.humanMarks(for: record).map(\.rec.id)
            if let own = marksRecordingId, !ids.contains(own) { ids.append(own) }
            if let inv = ws.environment(env.id)?.inventory(for: record) { ids.append(inv.rec.id) }
            let step = RunStep(kind: .edit, inputs: ["asset": [record.asset.id], "marks": ids], settings: RunSettings(), label: "from full view")
            _ = await ws.createRuns(env: env.id, steps: [step])
            startingEdit = false
        }
    }

    private var hint: String {
        switch tool {
        case .select: return selectedEntity.map { "entity \($0) selected" } ?? "click an entity outline to select it"
        case .element: return "\(cls)\(cls == "area" ? " · \(material)" : "") · \(shape) · \(current.count) point\(current.count == 1 ? "" : "s")"
        case .edit: return "\(editCls) · outline the region · \(current.count) point\(current.count == 1 ? "" : "s")"
        case .measure: return current.isEmpty ? "click point A on the mesh" : current.count == 1 ? "now click point B" : "type the metres you taped between A and B"
        }
    }

    /// Everything drawn over the mesh: entity outlines (proposals), saved marks, the points being placed.
    private var overlays: [Overlay] {
        var out: [Overlay] = []
        let states = entityStates
        if showEntities {
            for e in entities where states[entityId(e)] != "rejected" && states[entityId(e)] != "removed" {
                let pts = e.points.compactMap { $0.count >= 3 ? SIMD3<Double>($0[0], $0[1], $0[2]) : nil }
                guard !pts.isEmpty else { continue }
                let on = entityId(e) == selectedEntity
                out.append(Overlay(id: "e:\(entityId(e))", points: pts.map(toScene), closed: e.shape == "polygon",
                                   color: Overlay.color(e.color ?? Overlay.palette(e.cls, e.material)),
                                   alpha: on ? 1 : (states[entityId(e)] == "accepted" ? 0.9 : 0.55), dots: on, lift: 0.015, label: e.displayName))
            }
        }
        if showMarks {
            for m in marks where m.entity == nil || m.isEdit {
                let pts = m.points.compactMap { $0.count >= 3 ? SIMD3<Double>($0[0], $0[1], $0[2]) : nil }
                guard !pts.isEmpty else { continue }
                let color = m.isEdit ? (m.cls == "remove" ? Overlay.color("#b9452c") : Overlay.color("#4a90c8")) : Overlay.color(Overlay.palette(m.cls, m.material))
                out.append(Overlay(id: "m:\(m.id)", points: pts.map(toScene), closed: m.shape == "polygon" && pts.count >= 3, color: color,
                                   alpha: m.id == selectedMark ? 1 : 0.9, dots: true, lift: 0.03, label: m.displayName))
            }
        }
        if !current.isEmpty {
            out.append(Overlay(id: "current", points: current.map(toScene), closed: false, color: NSColor(Theme.accent), alpha: 1, dots: true, lift: 0.04, label: nil))
        }
        return out
    }

    // MARK: coordinates

    private func toModel(_ world: SIMD3<Float>) -> SIMD3<Double> {
        let lev = SIMD4<Double>(Double(world.x), Double(-world.z), Double(world.y), 1)
        let m = levelled.inverse * lev
        return SIMD3<Double>(m.x, m.y, m.z)
    }

    private func toScene(_ model: SIMD3<Double>) -> SIMD3<Float> {
        let l = levelled * SIMD4<Double>(model.x, model.y, model.z, 1)
        return SIMD3<Float>(Float(l.x), Float(l.z), Float(-l.y))
    }

    private func levelledXY(_ model: SIMD3<Double>) -> SIMD2<Double> {
        let l = levelled * SIMD4<Double>(model.x, model.y, model.z, 1)
        return SIMD2<Double>(l.x, l.y)
    }

    // MARK: picking

    private func picked(_ world: SIMD3<Float>) {
        let p = toModel(world)
        switch tool {
        case .select:
            selectedEntity = entityAt(p).map(entityId)
            if let e = selectedEntity { status = "selected \(e)" }
        case .element, .edit:
            if shape == "point" && tool == .element { current = [p]; finishMark() } else { current.append(p) }
        case .measure:
            if current.count >= 2 { current = [p] } else { current.append(p) }
        }
    }

    /// The smallest entity whose footprint (levelled XY) contains the point.
    private func entityAt(_ p: SIMD3<Double>) -> MarkItem? {
        let q = levelledXY(p)
        let states = entityStates
        var best: (MarkItem, Double)?
        for e in entities where states[entityId(e)] != "rejected" && states[entityId(e)] != "removed" {
            let ring = e.points.compactMap { $0.count >= 3 ? levelledXY(SIMD3<Double>($0[0], $0[1], $0[2])) : nil }
            guard ring.count >= 2 else { continue }
            let hit: Bool
            let area: Double
            if e.shape == "polygon", ring.count >= 3 {
                hit = Self.inside(q, ring); area = abs(Self.area(ring))
            } else {
                hit = Self.distance(q, segment: ring) < 0.25; area = 0.05
            }
            if hit, best == nil || area < best!.1 { best = (e, area) }
        }
        return best?.0
    }

    static func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            if (poly[i].y > p.y) != (poly[j].y > p.y), p.x < (poly[j].x - poly[i].x) * (p.y - poly[i].y) / (poly[j].y - poly[i].y) + poly[i].x { c.toggle() }
            j = i
        }
        return c
    }
    static func area(_ poly: [SIMD2<Double>]) -> Double {
        var a = 0.0
        for i in 0..<poly.count { let j = (i + 1) % poly.count; a += poly[i].x * poly[j].y - poly[j].x * poly[i].y }
        return a / 2
    }
    static func distance(_ p: SIMD2<Double>, segment: [SIMD2<Double>]) -> Double {
        var best = Double.infinity
        for i in 0..<(segment.count - 1) {
            let a = segment[i], b = segment[i + 1], ab = b - a
            let t = max(0, min(1, simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-12)))
            best = min(best, simd_length(p - (a + ab * t)))
        }
        return best
    }

    // MARK: marks

    private func finishMark() {
        guard current.count >= minPoints else { return }
        let isEdit = tool == .edit
        let item = MarkItem(id: "k\(Int(Date().timeIntervalSince1970))", role: isEdit ? "edit" : "element", cls: isEdit ? editCls : cls,
                            shape: isEdit ? "polygon" : shape, points: current.map { [$0.x, $0.y, $0.z] },
                            name: name.isEmpty ? nil : name, note: note.isEmpty ? nil : note,
                            material: (!isEdit && cls == "area") ? material : nil, text: isEdit && editCls == "patch" ? text : nil,
                            at: Format.now())
        current = []
        name = ""
        Task { await save(marks + [item]) }
    }

    private func acceptEntity(_ e: MarkItem, reject: Bool = false) {
        let eid = entityId(e)
        let item = MarkItem(id: "a-\(eid)", role: "element", cls: MarkItem.elementClasses.contains(e.cls) ? e.cls : "object", shape: e.shape,
                            points: e.points, name: e.name, material: e.material, entity: eid, source: "accepted", reject: reject ? true : nil, at: Format.now())
        Task { await save(marks.filter { $0.entity != eid || $0.isEdit } + [item]) }
    }

    private func removeEntity(_ e: MarkItem) {
        let eid = entityId(e)
        let item = MarkItem(id: "r-\(eid)", role: "edit", cls: "remove", shape: e.shape, points: e.points, name: e.name, entity: eid, at: Format.now())
        Task { await save(marks.filter { !($0.entity == eid && $0.isEdit) } + [item]) }
    }

    private func delete(_ m: MarkItem) { Task { await save(marks.filter { $0.id != m.id }) } }

    private func save(_ items: [MarkItem]) async {
        marks = items
        if let r = marksRecording {
            await ws.saveMarks(r, items: items)
        } else if let id = await ws.createMarksRecording(env: env.id, name: "Marks on \(record.asset.name)", model: record.asset.id, items: items, open: false) {
            marksRecordingId = id
        }
        status = "\(items.count) mark\(items.count == 1 ? "" : "s") saved"
    }

    /// Continue the given marks recording, else the newest of your own on this model's frame, if there is one.
    private func adoptExistingMarks() {
        if marksRecordingId == nil, let wanted = initialRecording, let r = env.recording(wanted), r.isMarks, !r.isGenerated {
            marksRecordingId = r.rec.id
        }
        if marksRecordingId == nil, let r = humanRecordings.last {
            marksRecordingId = r.rec.id
        }
        marks = marksRecording?.rec.marks ?? []
    }

    private func switchRecording(to id: String?) {
        marksRecordingId = id
        marks = id.flatMap { env.recording($0) }?.rec.marks ?? []
        selectedMark = nil
    }

    // MARK: measurements

    private func addMeasurement() {
        guard current.count == 2, let m = Double(meters.replacingOccurrences(of: ",", with: ".")), m > 0 else { return }
        let item = MeasurementItem(id: "m\(Int(Date().timeIntervalSince1970))", model: record.asset.id, a3d: [current[0].x, current[0].y, current[0].z],
                                   b3d: [current[1].x, current[1].y, current[1].z], meters: m, note: note.isEmpty ? nil : note, at: Format.now())
        current = []
        meters = ""
        Task {
            if let id = measureRecordingId, let r = env.recording(id) {
                await ws.saveMeasurements(r, items: r.rec.items + [item], north: r.rec.north)
            } else if let r = env.measurementRecordings.last {
                measureRecordingId = r.rec.id
                await ws.saveMeasurements(r, items: r.rec.items + [item], north: r.rec.north)
            } else {
                _ = await ws.createMeasurementRecording(env: env.id, name: "Mesh measurements", items: [item], north: nil)
                measureRecordingId = env.measurementRecordings.last?.rec.id
            }
            status = "measurement saved"
        }
    }

    // MARK: the side panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolBox
                Divider()
                if !entities.isEmpty { entityList }
                Divider()
                markList
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder private var toolBox: some View {
        switch tool {
        case .select:
            VStack(alignment: .leading, spacing: 8) {
                Text("Select").font(.headline)
                Text("Click inside an entity's outline to select it, then accept it as a mark, correct it, reject it, or mark it for removal.")
                    .font(.caption).foregroundStyle(.secondary)
                if let id = selectedEntity, let e = entities.first(where: { entityId($0) == id }) { entityCard(e) }
            }
        case .element:
            VStack(alignment: .leading, spacing: 8) {
                Text("Mark an element").font(.headline)
                Picker("Class", selection: $cls) { ForEach(MarkItem.elementClasses, id: \.self) { Text($0).tag($0) } }
                if cls == "area" { Picker("Material", selection: $material) { ForEach(MarkItem.materials, id: \.self) { Text($0).tag($0) } } }
                Picker("Shape", selection: $shape) { Text("polygon").tag("polygon"); Text("line").tag("line"); Text("point").tag("point") }.pickerStyle(.segmented)
                TextField("Name", text: $name, prompt: Text(cls == "area" ? "sand pit" : cls == "fence" ? "back fence" : "name"))
                TextField("Note", text: $note, prompt: Text("optional"))
                Text("Click the mesh for each corner. Walls and fences are lines along their base; areas and stairs are polygons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .edit:
            VStack(alignment: .leading, spacing: 8) {
                Text("Mark an edit").font(.headline)
                Picker("Edit", selection: $editCls) { Text("remove").tag("remove"); Text("patch").tag("patch") }.pickerStyle(.segmented)
                TextField("Name", text: $name, prompt: Text(editCls == "remove" ? "the bike" : "lawn hole"))
                if editCls == "patch" { TextField("What belongs there", text: $text, prompt: Text("lawn")) }
                Text(editCls == "remove" ? "Outline the thing roughly; the edit run grows the selection to the whole object underneath. To remove a known entity, select it instead."
                                         : "Outline the hole; the edit run fills it on the surrounding ground and textures it from the neighbours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .measure:
            VStack(alignment: .leading, spacing: 8) {
                Text("Measure on the mesh").font(.headline)
                HStack {
                    TextField("metres", text: $meters).frame(width: 90).onSubmit(addMeasurement)
                    Text("m").foregroundStyle(.secondary)
                    Button("Add", systemImage: "plus") { addMeasurement() }.buttonStyle(.glassProminent)
                        .disabled(current.count < 2 || (Double(meters.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
                }
                TextField("Note", text: $note, prompt: Text("patio edge"))
                Text("Two clicks on the mesh and the taped metres. Saved into \(measureRecordingId.flatMap { env.recording($0)?.rec.name } ?? env.measurementRecordings.last?.rec.name ?? "a new measurements recording"); every layout on this model uses it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func entityCard(_ e: MarkItem) -> some View {
        let state = entityStates[entityId(e)]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(Overlay.swiftColor(e.color ?? Overlay.palette(e.cls, e.material))).frame(width: 10, height: 10)
                Text(e.displayName).font(.headline)
                Spacer()
                if let st = state { Text(st).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
            }
            Text([e.cls, e.material, e.areaM2.map { String(format: "%.1f m²", $0) }, e.heightM.map { String(format: "h %.2f m", $0) },
                  e.confidence.map { String(format: "%.0f %% sure", $0 * 100) }, e.frames.map { "\($0) frame\($0 == 1 ? "" : "s")" }].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let d = e.note, !d.isEmpty { Text(d).font(.caption) }
            HStack {
                Button("Accept", systemImage: "checkmark") { acceptEntity(e) }.disabled(state == "accepted")
                Button("Reject", systemImage: "xmark") { acceptEntity(e, reject: true) }.disabled(state == "rejected")
                Button("Remove…", systemImage: "scissors") { removeEntity(e) }.disabled(state == "removed").help("Mark it for the edit run to cut out")
            }
            .buttonStyle(.glass).controlSize(.small)
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var entityList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Inventory").font(.headline)
                Text("\(entities.count) · \(inventory?.rec.name ?? "")").font(.caption).foregroundStyle(.secondary)
            }
            let states = entityStates
            ForEach(entities) { e in
                Button {
                    selectedEntity = entityId(e)
                    tool = .select
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Overlay.swiftColor(e.color ?? Overlay.palette(e.cls, e.material))).frame(width: 8, height: 8)
                        Text(e.displayName).lineLimit(1)
                        Text(e.cls).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if let st = states[entityId(e)] {
                            Image(systemName: st == "accepted" ? "checkmark.circle.fill" : st == "rejected" ? "xmark.circle" : "scissors")
                                .foregroundStyle(st == "accepted" ? Theme.ok : .secondary).font(.caption)
                        }
                        if let a = e.areaM2 { Text(String(format: "%.1f m²", a)).font(Theme.mono).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(entityId(e) == selectedEntity ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var markList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Marks").font(.headline)
                Menu {
                    ForEach(humanRecordings) { r in
                        Button(r.rec.id == marksRecordingId ? "✓ \(r.rec.name)" : r.rec.name) { switchRecording(to: r.rec.id) }
                    }
                    Divider()
                    Button("New Marks Recording") { switchRecording(to: nil) }
                } label: {
                    Text(marksRecording.map { "\($0.rec.name) · \(marks.count)" } ?? "new recording").font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if let r = marksRecording { Button("Open") { ws.open(.recording(env.id, r.rec.id)) }.buttonStyle(.link).font(.caption) }
            }
            if marks.isEmpty { Text(marksRecording == nil ? "A new marks recording is created with your first mark." : "Accepted entities, drawn elements and edits end up here, saved as you go.").font(.caption).foregroundStyle(.secondary) }
            if marks.contains(where: \.isEdit) {
                Button(startingEdit ? "Starting…" : "Run Edit with These Marks", systemImage: "play.fill") { runEdit() }
                    .buttonStyle(.glassProminent).controlSize(.small).disabled(startingEdit)
            }
            ForEach(marks) { m in
                HStack(spacing: 8) {
                    Image(systemName: m.isEdit ? (m.cls == "remove" ? "scissors" : "bandage") : m.reject == true ? "xmark.circle" : "pencil.and.outline")
                        .foregroundStyle(m.isEdit ? Theme.bad : Theme.accent).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.displayName).lineLimit(1)
                        Text([m.role, m.cls, m.material, m.entity.map { "entity \($0)" }, m.reject == true ? "rejected" : nil, "\(m.points.count) pts"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete", systemImage: "trash") { delete(m) }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture { selectedMark = m.id }
                .background(m.id == selectedMark ? Theme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - overlays and the clickable SceneKit view

/// One thing drawn over the mesh: a polyline (closed or not) with optional dots, in SceneKit world coordinates.
struct Overlay: Hashable, Identifiable {
    let id: String
    let points: [SIMD3<Float>]
    let closed: Bool
    let color: NSColor
    let alpha: CGFloat
    let dots: Bool
    let lift: Float
    let label: String?

    static let palette: [String: String] = ["grass": "#6fa24a", "brick": "#b24c3c", "sand": "#dec07a", "gravel": "#9a9a96", "concrete": "#bdbdb8",
                                            "deck": "#a06e46", "garden": "#7a5637", "soil": "#7a5637", "tiles": "#c9b7a0", "stone": "#8f8a80",
                                            "asphalt": "#555555", "other": "#aaaaaa", "wall": "#3c3c3c", "fence": "#8c6a3c", "window": "#4a90c8",
                                            "door": "#c98a2a", "stairs": "#6d5aa8", "tree": "#2f6b3a", "bush": "#4f8f4a", "object": "#d97757"]
    static func palette(_ cls: String, _ material: String?) -> String {
        cls == "area" ? (palette[material ?? "other"] ?? "#aaaaaa") : (palette[cls] ?? "#d97757")
    }
    static func color(_ hex: String) -> NSColor {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        let v = UInt32(h, radix: 16) ?? 0xd97757
        return NSColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    static func swiftColor(_ hex: String) -> Color { Color(nsColor: color(hex)) }

    /// The overlays for a set of marks on a model, given the matrix its preview was exported with (model → levelled).
    /// Generated items (an inventory) are drawn thinner and unlabelled; a person's marks carry their names; edits are red or blue.
    static func overlays(marks: [MarkItem], levelled: [[Double]]?, generated: Bool, prefix: String) -> [Overlay] {
        var L = matrix_identity_double4x4
        if let m = levelled, m.count == 4 { L = simd_double4x4(rows: m.map { SIMD4<Double>($0[0], $0[1], $0[2], $0[3]) }) }
        func scene(_ p: [Double]) -> SIMD3<Float> {
            let l = L * SIMD4<Double>(p[0], p[1], p[2], 1)
            return SIMD3<Float>(Float(l.x), Float(l.z), Float(-l.y))
        }
        var out: [Overlay] = []
        for m in marks {
            let pts = m.points.filter { $0.count >= 3 }
            guard !pts.isEmpty else { continue }
            let color = m.isEdit ? Overlay.color(m.cls == "remove" ? "#b9452c" : "#4a90c8") : Overlay.color(m.color ?? Overlay.palette(m.cls, m.material))
            out.append(Overlay(id: "\(prefix)\(m.id)", points: pts.map(scene), closed: m.shape == "polygon" && pts.count >= 3, color: color,
                               alpha: generated ? 0.75 : 0.95, dots: !generated && pts.count < 3, lift: generated ? 0.015 : 0.03,
                               label: generated ? nil : (m.reject == true ? "✗ " + m.displayName : m.displayName)))
        }
        return out
    }
}

/// The orbitable viewer with a click that lands on the mesh and an overlay layer rebuilt when the overlays change.
struct EditableModelView: NSViewRepresentable {
    let url: URL
    let overlays: [Overlay]
    var resetToken = 0
    var interactive = true
    let onPick: (SIMD3<Float>) -> Void
    /// A right-click: the world point (on the mesh, else on the ground plane y = 0), where on screen (SwiftUI coordinates,
    /// origin top-left), and whether the mesh was hit.
    var onContext: ((SIMD3<Float>, CGPoint, Bool) -> Void)? = nil

    @MainActor final class Coordinator: NSObject {
        var onPick: (SIMD3<Float>) -> Void
        var onContext: ((SIMD3<Float>, CGPoint, Bool) -> Void)?
        var overlayNode = SCNNode()
        var overlayHash = 0
        var home: SCNMatrix4?
        var token = 0
        var loadedKey = ""
        init(onPick: @escaping (SIMD3<Float>) -> Void) { self.onPick = onPick }

        private func hit(_ v: SCNView, _ p: CGPoint) -> SIMD3<Float>? {
            let hits = v.hitTest(p, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                                              .categoryBitMask: NSNumber(value: 1), .ignoreHiddenNodes: true])
            guard let h = hits.first else { return nil }
            let w = h.worldCoordinates
            return SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z))
        }

        /// Where the click ray meets the ground plane (levelled z = 0 is SceneKit y = 0).
        private func ground(_ v: SCNView, _ p: CGPoint) -> SIMD3<Float>? {
            let a = v.unprojectPoint(SCNVector3(p.x, p.y, 0)), b = v.unprojectPoint(SCNVector3(p.x, p.y, 1))
            let d = SIMD3<Float>(Float(b.x - a.x), Float(b.y - a.y), Float(b.z - a.z))
            guard abs(d.y) > 1e-6 else { return nil }
            let t = -Float(a.y) / d.y
            guard t > 0 else { return nil }
            return SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z)) + d * t
        }

        @objc func click(_ g: NSClickGestureRecognizer) {
            guard let v = g.view as? SCNView, let w = hit(v, g.location(in: v)) else { return }
            onPick(w)
        }

        @objc func rightClick(_ g: NSClickGestureRecognizer) {
            guard let v = g.view as? SCNView, let onContext else { return }
            let p = g.location(in: v)
            let screen = CGPoint(x: p.x, y: v.bounds.height - p.y)
            if let w = hit(v, p) { onContext(w, screen, true) } else if let w = ground(v, p) { onContext(w, screen, false) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling2X
        v.backgroundColor = .clear
        v.rendersContinuously = false
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        if interactive {
            let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.click(_:)))
            click.numberOfClicksRequired = 1
            v.addGestureRecognizer(click)
            let right = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.rightClick(_:)))
            right.buttonMask = 0x2
            v.addGestureRecognizer(right)
        }
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onContext = onContext
        let key = SceneCache.key(url)
        if context.coordinator.loadedKey != key {
            context.coordinator.loadedKey = key
            Task { @MainActor in
                guard let scene = await SceneCache.scene(for: url) else { return }
                scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { node.categoryBitMask = 1 } }
                v.scene = scene
                v.pointOfView = scene.rootNode.childNode(withName: "PreviewCamera", recursively: false)
                context.coordinator.home = v.pointOfView?.transform
                context.coordinator.overlayNode.removeFromParentNode()
                context.coordinator.overlayNode = SCNNode()
                context.coordinator.overlayNode.name = "overlay"
                context.coordinator.overlayNode.categoryBitMask = 2
                scene.rootNode.addChildNode(context.coordinator.overlayNode)
                context.coordinator.overlayHash = 0
                rebuildOverlays(v, context)
            }
        } else {
            rebuildOverlays(v, context)
        }
        if context.coordinator.token != resetToken, let home = context.coordinator.home, let cam = v.pointOfView {
            context.coordinator.token = resetToken
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0.5; cam.transform = home; SCNTransaction.commit()
        }
    }

    private func rebuildOverlays(_ v: SCNView, _ context: Context) {
        var hasher = Hasher()
        hasher.combine(overlays)
        let h = hasher.finalize()
        guard h != context.coordinator.overlayHash, v.scene != nil else { return }
        context.coordinator.overlayHash = h
        let root = context.coordinator.overlayNode
        root.childNodes.forEach { $0.removeFromParentNode() }
        let extent = (v.scene?.rootNode.boundingSphere.radius).map { Float($0) } ?? 10
        let dotRadius = CGFloat(max(0.02, extent * 0.004))
        for o in overlays {
            let pts = o.points.map { SCNVector3($0.x, $0.y + o.lift, $0.z) }
            guard !pts.isEmpty else { continue }
            if pts.count >= 2 {
                var idx: [Int32] = []
                for i in 0..<(pts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
                if o.closed && pts.count >= 3 { idx += [Int32(pts.count - 1), 0] }
                let src = SCNGeometrySource(vertices: pts)
                let el = SCNGeometryElement(indices: idx, primitiveType: .line)
                let g = SCNGeometry(sources: [src], elements: [el])
                let m = SCNMaterial()
                m.diffuse.contents = o.color.withAlphaComponent(o.alpha)
                m.emission.contents = o.color.withAlphaComponent(o.alpha)
                m.lightingModel = .constant
                m.readsFromDepthBuffer = false
                g.materials = [m]
                let n = SCNNode(geometry: g)
                n.categoryBitMask = 2
                n.renderingOrder = 10
                root.addChildNode(n)
            }
            if o.dots || pts.count == 1 {
                for p in pts {
                    let s = SCNSphere(radius: dotRadius)
                    let m = SCNMaterial()
                    m.diffuse.contents = o.color
                    m.emission.contents = o.color.withAlphaComponent(0.6)
                    m.lightingModel = .constant
                    m.readsFromDepthBuffer = false
                    s.materials = [m]
                    let n = SCNNode(geometry: s)
                    n.position = p
                    n.categoryBitMask = 2
                    n.renderingOrder = 11
                    root.addChildNode(n)
                }
            }
            if let label = o.label, pts.count >= 1, o.alpha >= 0.9 {
                let t = SCNText(string: label, extrusionDepth: 0)
                t.font = NSFont.systemFont(ofSize: 1, weight: .medium)
                t.flatness = 0.3
                let m = SCNMaterial()
                m.diffuse.contents = o.color
                m.emission.contents = o.color
                m.lightingModel = .constant
                m.readsFromDepthBuffer = false
                t.materials = [m]
                let n = SCNNode(geometry: t)
                let c = pts.reduce(SCNVector3Zero) { SCNVector3($0.x + $1.x, $0.y + $1.y, $0.z + $1.z) }
                n.position = SCNVector3(c.x / CGFloat(pts.count), c.y / CGFloat(pts.count) + 0.1, c.z / CGFloat(pts.count))
                let sc = CGFloat(max(0.08, extent * 0.012))
                n.scale = SCNVector3(sc, sc, sc)
                n.constraints = [SCNBillboardConstraint()]
                n.categoryBitMask = 2
                n.renderingOrder = 12
                root.addChildNode(n)
            }
        }
    }

    static func dismantleNSView(_ v: SCNView, coordinator: Coordinator) { v.scene = nil }
}
