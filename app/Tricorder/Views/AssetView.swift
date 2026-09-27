import SwiftUI

struct AssetView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: AssetRecord

    @State private var confirmDelete = false

    private var asset: Asset { record.asset }
    private var producer: RunRecord? { env.run(asset.runId) }
    private var isCurrent: Bool { env.currentAssets.contains { $0.id == record.id } }
    private var supersededBy: AssetRecord? { isCurrent ? nil : env.currentAssets.first { $0.asset.kind == asset.kind } }
    private var derivedPlans: [AssetRecord] {
        env.runsUsing(asset: asset.id).compactMap { $0.run.outputAsset }.compactMap { env.asset($0) }.sorted { $0.asset.createdAt > $1.asset.createdAt }
    }
    private var planRunning: Bool { env.runsUsing(asset: asset.id).contains { $0.isRunning } }
    private var sourceScan: AssetRecord? { producer?.run.inputAssetId.flatMap { env.asset($0) } }

    var body: some View {
        ScrollView { pageContent }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(asset.name)
            .navigationSubtitle("\(asset.kind.label) · from run \(asset.runId)")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if asset.kind == .model3d {
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
                            .disabled(!env.runsUsing(asset: asset.id).isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog("Delete \(asset.name)?", isPresented: $confirmDelete) {
                Button("Move to Trash", role: .destructive) { Task { await ws.deleteAsset(record) } }
            } message: {
                Text("The asset folder is moved to the Trash. The run that made it stays.")
            }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if asset.kind == .sitePlan, let o = record.overlay { SitePlanView(record: record, overlay: o) } else { viewer }
            tiles
            if asset.kind == .model3d {
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
                if let preview = record.preview {
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
