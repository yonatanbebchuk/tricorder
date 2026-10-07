import SwiftUI
import simd

struct AssetView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: AssetRecord

    @State private var confirmDelete = false
    @State private var showInventory = true
    @State private var showMarks = true

    private var asset: Asset { record.asset }
    private var producer: RunRecord? { env.run(asset.runId) }
    private var isCurrent: Bool { env.currentAssets.contains { $0.id == record.id } }
    private var supersededBy: AssetRecord? { isCurrent ? nil : env.currentAssets.first { $0.asset.kind == asset.kind } }
    private var derivedPlans: [AssetRecord] {
        env.runsUsing(asset: asset.id).compactMap { $0.run.outputAsset }.compactMap { env.asset($0) }.sorted { $0.asset.createdAt > $1.asset.createdAt }
    }
    private var planRunning: Bool { env.runsUsing(asset: asset.id).contains { $0.isRunning && $0.run.kind == .layout } }
    private var sourceScan: AssetRecord? { producer?.run.inputAssetId.flatMap { env.asset($0) } }
    private var inventory: RecordingRecord? { asset.kind == .model3d ? env.inventory(for: record) : nil }
    private var marksHere: [RecordingRecord] { asset.kind == .model3d ? env.humanMarks(for: record) : [] }
    private var hasEdits: Bool { marksHere.contains { $0.rec.marks.contains(where: \.isEdit) } }
    private var identifyRunning: Bool { env.runsUsing(asset: asset.id).contains { $0.isRunning && $0.run.kind == .identify } }
    private var dependents: (recordings: [RecordingRecord], assets: [AssetRecord]) { env.dependents(ofAsset: asset.id) }
    private var levelled: simd_double4x4 {
        guard let m = record.levelled, m.count == 4 else { return matrix_identity_double4x4 }
        return simd_double4x4(rows: m.map { SIMD4<Double>($0[0], $0[1], $0[2], $0[3]) })
    }
    /// The inventory's entities and your marks drawn over the model, in the viewer.
    private var viewerOverlays: [Overlay] {
        var out: [Overlay] = []
        func scene(_ p: [Double]) -> SIMD3<Float> {
            let l = levelled * SIMD4<Double>(p[0], p[1], p[2], 1)
            return SIMD3<Float>(Float(l.x), Float(l.z), Float(-l.y))
        }
        let rejected = Set(marksHere.flatMap { $0.rec.marks }.filter { $0.reject == true || ($0.isEdit && $0.cls == "remove") }.compactMap(\.entity))
        if showInventory, let inv = inventory {
            for e in inv.rec.marks where !rejected.contains(e.entity ?? e.id) {
                let pts = e.points.filter { $0.count >= 3 }
                guard !pts.isEmpty else { continue }
                out.append(Overlay(id: "e:\(e.id)", points: pts.map(scene), closed: e.shape == "polygon", color: Overlay.color(e.color ?? Overlay.palette(e.cls, e.material)),
                                   alpha: 0.75, dots: false, lift: 0.015, label: nil))
            }
        }
        if showMarks {
            for r in marksHere {
                for m in r.rec.marks where m.entity == nil || m.isEdit {
                    let pts = m.points.filter { $0.count >= 3 }
                    guard !pts.isEmpty else { continue }
                    let color = m.isEdit ? Overlay.color(m.cls == "remove" ? "#b9452c" : "#4a90c8") : Overlay.color(Overlay.palette(m.cls, m.material))
                    out.append(Overlay(id: "m:\(r.rec.id)/\(m.id)", points: pts.map(scene), closed: m.shape == "polygon" && pts.count >= 3, color: color, alpha: 0.95,
                                       dots: pts.count < 3, lift: 0.03, label: m.displayName))
                }
            }
        }
        return out
    }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(asset.name)
            .navigationSubtitle("\(asset.kind.label) · from run \(asset.runId)")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if asset.kind == .model3d {
                        Button("Full View", systemImage: "arrow.up.left.and.arrow.down.right") { ws.open(.editor(env.id, asset.id, nil)) }
                            .disabled(record.preview == nil)
                            .help("The mesh fills the page: mark walls, areas and objects, measure, mark edits")
                        Button("Mark Up", systemImage: "pencil.and.outline") { newMarks() }
                            .disabled(record.preview == nil)
                            .help("A new marks recording on this model, opened in Full View")
                        Button("Identify", systemImage: "tag") { ws.requestNewRun(env: env.id, kind: .identify, inputId: asset.id) }
                            .disabled(identifyRunning)
                            .help("Segment the frames, name every region with a vision-language model, lift onto the mesh: an inventory of what is where")
                        Button("Edit", systemImage: "scissors") { ws.requestNewRun(env: env.id, kind: .edit, inputId: asset.id) }
                            .disabled(!hasEdits)
                            .help(hasEdits ? "Cut out what the edit marks name and complete the ground" : "Mark something for removal in Full View first")
                        Button("Lay Out Site Plan", systemImage: "map") { ws.requestNewRun(env: env.id, kind: .layout, inputId: asset.id) }
                            .disabled(planRunning)
                            .help("Choose the measurement recordings, then solve scale, level and north; orthomosaic, contours, DXF and PDF")
                    }
                    if asset.kind == .sitePlan {
                        if record.has("site_plan.dxf") { Button("Open DXF", systemImage: "pencil.and.ruler") { ws.openFile(record.url("site_plan.dxf")) }.help("Open the CAD drawing (QCAD, AutoCAD, …)") }
                        if record.has("site_plan.pdf") { Button("Open PDF", systemImage: "doc.richtext") { ws.openFile(record.url("site_plan.pdf")) }.help("Open the sheet") }
                    }
                    Button("Show in Finder", systemImage: "folder") { ws.reveal(record.dir) }
                    Menu {
                        if let r = producer { Button("Open Run \(r.run.id)") { ws.open(.run(env.id, r.run.id)) } }
                        Divider()
                        Button("Delete Asset…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete \(asset.name)?", isPresented: $confirmDelete) {
                Button(dependents.recordings.isEmpty && dependents.assets.isEmpty ? "Move to Trash" : "Delete All", role: .destructive) { Task { await ws.deleteAsset(record) } }
            } message: {
                Text("The asset folder is moved to the Trash; the runs that made or used it stay. " + Workspace.cascadeText(recordings: dependents.recordings, assets: dependents.assets))
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if asset.kind == .sitePlan, let o = record.overlay { SitePlanView(record: record, overlay: o) } else { viewer }
            tiles
            if asset.kind == .model3d {
                inventoryCard
                planAction
                if !derivedPlans.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Site plans from this model") { EmptyView() }
                        Card("") { AssetRows(env: env, assets: derivedPlans) }
                    }
                }
            }
            if asset.kind == .sitePlan {
                if let t = record.transform { ScaleResultView(transform: t) }
                if record.preview != nil {
                    DisclosureGroup("3D model at true scale, levelled and north-up") {
                        ModelViewer(url: record.preview!).frame(height: 460).frame(maxWidth: .infinity)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    }
                    .font(.callout)
                }
            }
            FilesCard(record: record)
        }
        .padding(28)
        .frame(maxWidth: 1240, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: asset.kind.symbol).foregroundStyle(Theme.accent).font(.title2)
                Text(asset.name).font(Theme.display(30))
                if isCurrent {
                    Text("current").font(.caption).fontWeight(.medium).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.ok.opacity(0.15), in: Capsule()).foregroundStyle(Theme.ok)
                } else if let s = supersededBy {
                    Button("superseded by \(s.asset.name)") { ws.open(.asset(env.id, s.asset.id)) }.buttonStyle(.link).font(.caption)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text("\(asset.kind.label) · \(Format.when(asset.createdAt)) · made by").foregroundStyle(.secondary)
                if let p = producer {
                    Button("run \(p.run.id)") { ws.open(.run(env.id, p.run.id)) }.buttonStyle(.link)
                    Text("from \(env.inputName(of: p.run))").foregroundStyle(.secondary)
                    if let s = sourceScan { Button("(open scan)") { ws.open(.asset(env.id, s.asset.id)) }.buttonStyle(.link) }
                } else {
                    Text("run \(asset.runId) (deleted)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var viewer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let preview = record.preview, asset.kind == .model3d {
                    ZStack(alignment: .bottomTrailing) {
                        EditableModelView(url: preview, overlays: viewerOverlays, interactive: false, onPick: { _ in })
                        HStack(spacing: 10) {
                            Text("drag to orbit · scroll to zoom · ⌥ drag to pan").font(.caption2).foregroundStyle(.secondary)
                            if inventory != nil { Toggle("Inventory", isOn: $showInventory).toggleStyle(.checkbox).font(.caption) }
                            if !marksHere.isEmpty { Toggle("Marks", isOn: $showMarks).toggleStyle(.checkbox).font(.caption) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).glassEffect().padding(8)
                    }
                    .frame(height: 520)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
                } else if let preview = record.preview {
                    ModelViewer(url: preview)
                        .frame(height: 520)
                        .frame(maxWidth: .infinity)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator))
                } else if let img = record.planImage {
                    FileImage(url: img, maxPixel: 2600)
                        .frame(maxHeight: 640)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                        .onTapGesture { ws.openFile(img) }
                }
            }
            if record.preview == nil, record.hasTexturedMesh {
                Text("No 3D preview exported for this asset yet. Run \(asset.runId) again to export one (finished stages are kept).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if asset.kind == .model3d, record.preview != nil, let img = record.planImage {
                DisclosureGroup("Preview plan (levelled, unscaled)") {
                    FileImage(url: img, maxPixel: 2600).frame(maxHeight: 520).clipShape(RoundedRectangle(cornerRadius: 8)).onTapGesture { ws.openFile(img) }
                }
                .font(.callout)
            }
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach(Array(Format.assetTiles(asset).enumerated()), id: \.offset) { _, t in MetricTile(value: t.0, label: t.1) }
        }
    }

    private func newMarks() {
        Task {
            if let id = await ws.createMarksRecording(env: env.id, name: "Marks on \(asset.name)", model: asset.id, items: [], open: false) {
                ws.open(.editor(env.id, asset.id, id))
            }
        }
    }

    private var inventoryCard: some View {
        Card("") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What is where").font(.headline)
                    if let inv = inventory {
                        Text("\(inv.rec.marks.count) entities in \(inv.rec.name): " + inv.rec.marks.prefix(8).map(\.displayName).joined(separator: ", ") + (inv.rec.marks.count > 8 ? ", …" : "")
                             + ". Open Full View to accept, correct or remove them; \(marksHere.reduce(0) { $0 + $1.rec.marks.count }) marks of yours so far in \(marksHere.count) recording\(marksHere.count == 1 ? "" : "s").")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(identifyRunning ? "Identifying…" : "No inventory yet. Identify segments the frames, names every region with a vision-language model and lifts the names onto the mesh, so the grill, the fence and the lawn become things you can accept, correct, remove or lay out.")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let inv = inventory { Button("Open Inventory", systemImage: "tag") { ws.open(.recording(env.id, inv.rec.id)) }.buttonStyle(.glass) }
                Button("Full View", systemImage: "arrow.up.left.and.arrow.down.right") { ws.open(.editor(env.id, asset.id, nil)) }.buttonStyle(.glass).disabled(record.preview == nil)
                Button(identifyRunning ? "Identifying…" : inventory == nil ? "Identify…" : "Identify Again…", systemImage: "tag") {
                    ws.requestNewRun(env: env.id, kind: .identify, inputId: asset.id)
                }
                .buttonStyle(.glassProminent).disabled(identifyRunning)
            }
        }
    }

    private var planAction: some View {
        let measurements = env.measurementRecordings
        let count = measurements.reduce(0) { $0 + $1.rec.items.count }
        return Card("") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Layout").font(.headline)
                    Text(measurements.isEmpty
                         ? "A layout turns this model into a site plan. Add a measurements recording first (two points on a frame plus the taped metres) for true scale; without one the scale is estimated from the camera height (about ±10 %)."
                         : "\(count) tape measurement\(count == 1 ? "" : "s") in \(measurements.count) recording\(measurements.count == 1 ? "" : "s") available. A layout publishes a new site-plan asset; earlier plans stay in the history.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if measurements.isEmpty {
                    Button("Add Measurements…", systemImage: "ruler") { ws.requestNewRecording(env: env.id, measurements: true) }.buttonStyle(.glass)
                }
                Button(planRunning ? "Working…" : derivedPlans.isEmpty ? "Lay Out Site Plan…" : "Lay Out Again…", systemImage: "map") {
                    ws.requestNewRun(env: env.id, kind: .layout, inputId: asset.id)
                }
                .buttonStyle(.glassProminent)
                .disabled(planRunning || !record.hasTexturedMesh)
            }
        }
    }
}

struct ScaleResultView: View {
    let transform: Transform

    var body: some View {
        Card("Scale, level, north") {
            Text("scale \(String(format: "%.4f", transform.scale)) m per model unit · level from \(transform.ground?.description ?? "–") · north: \(transform.north?.description ?? "–")")
                .foregroundStyle(.secondary)
            if transform.estimated == true {
                WarningBanner(text: "Scale was ESTIMATED from the camera height (no measurement recording was used): expect about ±10 %. Add a measurements recording and lay out again for true scale.")
            } else if transform.warning == true {
                WarningBanner(text: "Measurements disagree by more than 3%; re-check them and lay out again.")
            }
            if !transform.residuals.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    ForEach(transform.residuals) { r in
                        GridRow {
                            HStack(spacing: 6) { Text("\(r.id) \(r.kind)"); if let src = r.source { SourceBadge(source: src) } }
                            Text(String(format: "%.2f m", r.meters)).font(Theme.mono)
                            Text(String(format: "%@%.1f cm vs mean", r.residualCm >= 0 ? "+" : "", r.residualCm))
                                .font(Theme.mono)
                                .foregroundStyle(abs(r.residualCm) > 5 ? Theme.bad : .primary)
                        }
                    }
                }
            }
        }
    }
}

struct FilesCard: View {
    @Environment(Workspace.self) private var ws
    let record: AssetRecord

    var body: some View {
        Card("Files") {
            if record.asset.files.isEmpty { Text("nothing yet").foregroundStyle(.secondary) }
            ForEach(record.asset.files.filter { !$0.label.isEmpty }) { f in
                let url = record.url(f.path)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Button(f.label) { ws.openFile(url) }.buttonStyle(.link)
                        Text(f.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.size(f.size)).font(Theme.mono).foregroundStyle(.secondary)
                    Button("Reveal in Finder", systemImage: "folder") { ws.reveal(url) }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reveal in Finder")
                }
                .padding(.vertical, 3)
                Divider()
            }
            let others = record.asset.files.filter { $0.label.isEmpty }
            if !others.isEmpty {
                Text("+ \(others.count) more files (\(Format.size(others.reduce(0) { $0 + $1.size })))").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
