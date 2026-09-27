import SwiftUI

/// The COLMAP / OpenMVS knobs of a reconstruction.
struct ReconstructSettingsForm: View {
    @Binding var settings: RunSettings

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
        Picker("3D preview detail", selection: $settings.previewFaces) {
            Text("150k faces").tag(150_000)
            Text("300k faces").tag(300_000)
            Text("600k faces").tag(600_000)
        }
    }
}

/// The plan render knobs.
struct PlanSettingsForm: View {
    @Binding var settings: RunSettings

    var body: some View {
        Picker("Plan resolution", selection: $settings.pxPerM) {
            Text("25 px per metre").tag(25)
            Text("50 px per metre").tag(50)
            Text("100 px per metre").tag(100)
        }
        Picker("3D preview detail", selection: $settings.previewFaces) {
            Text("150k faces").tag(150_000)
            Text("300k faces").tag(300_000)
            Text("600k faces").tag(600_000)
        }
    }
}

struct FrameSettingsForm: View {
    @Binding var fps: Double
    @Binding var maxFrames: Int
    @Binding var hdr: String

    var body: some View {
        TextField("Frames per second", value: $fps, format: .number)
        TextField("Max frames", value: $maxFrames, format: .number)
        Picker("HDR", selection: $hdr) {
            Text("auto-detect").tag("auto")
            Text("none").tag("none")
            Text("HLG").tag("hlg")
            Text("PQ").tag("pq")
        }
        Text("Rule of thumb: 400 frames for a 3 to 5 minute walk, 600 for 7 minutes. More frames = better coverage, much longer COLMAP.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
