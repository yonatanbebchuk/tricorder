import SwiftUI

/// The COLMAP / OpenMVS knobs, shared by the new-scan and new-run sheets.
struct RunSettingsForm: View {
    @Binding var settings: RunSettings
    @Binding var label: String

    var body: some View {
        Picker("Features", selection: $settings.features) {
            Text("SIFT (fast, ~30 min / 300 frames)").tag("SIFT")
            Text("ALIKED (learned; blank walls)").tag("ALIKED")
        }
        Picker("Matcher", selection: $settings.matcher) {
            Text("brute force").tag("BRUTEFORCE")
            Text("LightGlue (learned, hours)").tag("LIGHTGLUE")
        }
        Picker("Pairs", selection: $settings.matching) {
            Text("vocab tree").tag("vocab")
            Text("sequential").tag("sequential")
            Text("exhaustive").tag("exhaustive")
        }
        Picker("Dense level", selection: $settings.resLevel) {
            Text("1 (half res, slow)").tag(1)
            Text("2 (quarter)").tag(2)
            Text("3 (eighth, fast)").tag(3)
        }
        Picker("Measurements to ask for", selection: $settings.measures) {
            ForEach([3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
        }
        TextField("Label", text: $label, prompt: Text("optional, e.g. learned features"))
    }
}

struct NewRunSheet: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.dismiss) private var dismiss
    let scan: ScanRecord

    @State private var settings = RunSettings()
    @State private var label = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New run").font(Theme.display(26))
                Text("On \(scan.scan.name). Frames are reused; COLMAP, OpenMVS and the landmarks run again with these settings.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            Form { RunSettingsForm(settings: $settings, label: $label) }
                .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Starting…" : "Start Run") {
                    busy = true
                    Task {
                        let ok = await ws.createRun(scanId: scan.id, settings: settings, label: label)
                        busy = false
                        if ok { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
            }
            .padding(20)
        }
        .frame(width: 560, height: 470)
    }
}
