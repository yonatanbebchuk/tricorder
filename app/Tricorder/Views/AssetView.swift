import SwiftUI

struct AssetView: View {
    @Environment(Workspace.self) private var ws
    let env: EnvironmentRecord
    let record: AssetRecord

    @State private var confirmDelete = false
    @State private var startingPlan = false

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
                    if asset.kind == .scan3d {
                        Button("Make Site Plan", systemImage: "map") { makePlan() }
                            .disabled(record.answeredCount == 0 || planRunning || startingPlan)
                            .help(record.answeredCount == 0 ? "Enter at least one measurement first" : "Solve scale, level and north; render the plan")
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

    private func makePlan() {
        startingPlan = true
        Task {
            var s = RunSettings()
            if let p = producer { s = p.run.settings }
            _ = await ws.createRun(env: env.id, kind: .plan, inputId: asset.id, settings: s, label: "")
            startingPlan = false
        }
    }

    var pageContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            viewer
            tiles
            if asset.kind == .scan3d {
                if record.prompts != nil { MeasurePanel(record: record) }
                planAction
                if !derivedPlans.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Site plans from this scan") { EmptyView() }
                        Card("") { AssetRows(env: env, assets: derivedPlans) }
                    }
                }
            }
            if asset.kind == .plan2d, let t = record.transform { ScaleResultView(transform: t) }
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
            if asset.kind == .plan2d, let img = record.planImage, record.preview != nil {
                FileImage(url: img, maxPixel: 2600)
                    .frame(maxHeight: 640)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .onTapGesture { ws.openFile(img) }
                Text("Site plan at true scale (1 m grid). Click to open in Preview; trace it in QCAD, or open plan.blend.").font(.caption).foregroundStyle(.secondary)
            } else if asset.kind == .scan3d, record.preview != nil, let img = record.planImage {
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
        Card("") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Site plan").font(.headline)
                    Text(record.answeredCount == 0
                         ? "Enter at least one tape measurement above, then make the site plan: scale, level and north are solved from your answers and a true-scale plan is rendered."
                         : "\(record.answeredCount) of \(record.prompts?.count ?? 0) measurements entered. Making a plan publishes a new site-plan asset; earlier plans stay in the history.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(planRunning || startingPlan ? "Working…" : derivedPlans.isEmpty ? "Make Site Plan" : "Make Site Plan Again", systemImage: "map") { makePlan() }
                    .buttonStyle(.glassProminent)
                    .disabled(record.answeredCount == 0 || planRunning || startingPlan || !record.hasTexturedMesh)
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
            if transform.warning == true {
                WarningBanner(text: "Measurements disagree by more than 3%; re-check them and make the plan again.")
            }
            if !transform.residuals.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                    ForEach(transform.residuals) { r in
                        GridRow {
                            Text("\(r.id) \(r.kind)")
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
