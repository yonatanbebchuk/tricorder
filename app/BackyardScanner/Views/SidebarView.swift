import SwiftUI

struct SidebarView: View {
    @Environment(Workspace.self) private var ws
    @Binding var selection: Selection?
    @State private var collapsed: Set<String> = []

    var body: some View {
        List(selection: $selection) {
            ForEach(ws.scans) { rec in
                ScanRow(record: rec, collapsed: collapsed.contains(rec.id)) { toggle(rec.id) }
                    .tag(Selection.scan(rec.id))
                if !collapsed.contains(rec.id) {
                    ForEach(rec.runs) { r in
                        RunRow(record: r).tag(Selection.run(rec.id, r.run.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Scans")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Scan", systemImage: "plus") { ws.requestNewScan() }.help("New scan (⌘N)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack { HealthBar(health: ws.health); Spacer() }.padding(10)
        }
        .overlay {
            if ws.scans.isEmpty {
                ContentUnavailableView {
                    Label("No scans yet", systemImage: "video")
                } description: {
                    Text("Drop an iPhone video here, or press ⌘N.")
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ManifestStore.videoExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
            ws.requestNewScan(video: u)
            return true
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
}

struct ScanRow: View {
    let record: ScanRecord
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(collapsed ? .zero : .degrees(90))
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(record.runs.isEmpty ? 0 : 1)

            Group {
                if let t = record.thumbnail {
                    FileImage(url: t, maxPixel: 200)
                } else {
                    Rectangle().fill(.quaternary).overlay { Image(systemName: "video").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .frame(width: 48, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.scan.name).fontWeight(.medium).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.scan.frames.status == .running {
                ProgressView().controlSize(.mini)
            } else {
                HStack(spacing: 3) {
                    ForEach(record.runs) { r in Circle().fill(r.run.status.color).frame(width: 6, height: 6) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var meta: String {
        var p = [Format.when(record.scan.createdAt)]
        if let d = record.scan.video.durationS, d > 0 { p.append(Format.duration(d)) }
        if record.scan.video.isHDR { p.append("HDR") }
        return p.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct RunRow: View {
    let record: RunRecord

    var body: some View {
        HStack(spacing: 8) {
            Text(record.run.id).fontWeight(.semibold).frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.run.label.isEmpty ? Format.settingsLine(record.run.settings) : record.run.label).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.isRunning { ProgressView().controlSize(.mini) }
            StatusPill(status: record.run.status, compact: true)
        }
        .padding(.leading, 24)
        .padding(.vertical, 2)
    }

    private var summary: String {
        let sfm = Format.stageMetrics("sfm", record.run.stage("sfm").metrics)
        let plan = Format.stageMetrics("plan", record.run.stage("plan").metrics)
        if !plan.isEmpty { return plan }
        if !sfm.isEmpty { return sfm }
        if record.prompts != nil { return "awaiting measurements" }
        return Format.when(record.run.createdAt)
    }
}
