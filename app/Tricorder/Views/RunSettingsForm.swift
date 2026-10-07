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

/// The layout knobs.
struct LayoutSettingsForm: View {
    @Binding var settings: RunSettings

    var body: some View {
        Picker("Orthomosaic resolution", selection: $settings.pxPerM) {
            Text("25 px per metre").tag(25)
            Text("50 px per metre").tag(50)
            Text("100 px per metre").tag(100)
        }
        Picker("Contour interval", selection: $settings.contourM) {
            Text("0.10 m").tag(0.1)
            Text("0.25 m").tag(0.25)
            Text("0.50 m").tag(0.5)
        }
        Picker("Sheet scale", selection: $settings.sheetScale) {
            Text("1:50").tag(50)
            Text("1:100").tag(100)
            Text("1:200").tag(200)
        }
        Picker("Walls and fences at least", selection: $settings.wallJumpM) {
            Text("0.3 m tall").tag(0.3)
            Text("0.5 m tall").tag(0.5)
            Text("0.8 m tall").tag(0.8)
        }
        Picker("Boundary from", selection: $settings.boundary) {
            Text("the perimeter walls (keeps stair grooves and window bays)").tag("walls")
            Text("the ground footprint (where walls are missing)").tag("footprint")
        }
        Picker("Absorb boundary jogs under", selection: $settings.minEdgeM) {
            Text("0.8 m").tag(0.8)
            Text("1.2 m").tag(1.2)
            Text("2.0 m").tag(2.0)
        }
        Picker("3D preview detail", selection: $settings.previewFaces) {
            Text("150k faces").tag(150_000)
            Text("300k faces").tag(300_000)
            Text("600k faces").tag(600_000)
        }
    }
}

/// The identify knobs: who names the regions, how many frames, whether to review.
struct IdentifySettingsForm: View {
    @Binding var settings: RunSettings

    var body: some View {
        Picker("Names the regions", selection: $settings.vlm) {
            Text("Qwen2.5-VL on this Mac (MLX, ~30 s per frame)").tag("qwen-local")
            Text("Claude (hosted; needs ANTHROPIC_API_KEY or ant auth login)").tag("claude")
            Text("none (segment only)").tag("none")
        }
        Picker("Frames", selection: $settings.every) {
            Text("every 6th registered frame").tag(6)
            Text("every 10th").tag(10)
            Text("every 15th").tag(15)
        }
        Picker("At most", selection: $settings.framesCap) {
            Text("30 frames").tag(30)
            Text("60 frames").tag(60)
            Text("100 frames").tag(100)
        }
        Picker("Segmenter", selection: $settings.sam) {
            Text("SAM ViT-B (fast)").tag("facebook/sam-vit-base")
            Text("SAM ViT-L").tag("facebook/sam-vit-large")
            Text("SAM ViT-H (best, slow)").tag("facebook/sam-vit-huge")
        }
        Toggle("Review each entity with the model afterwards", isOn: Binding(get: { settings.review == 1 }, set: { settings.review = $0 ? 1 : 0 }))
        Text("Naming is the slow part: a frame with 30 regions takes about half a minute locally, a few seconds hosted.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// The edit knobs.
struct EditSettingsForm: View {
    @Binding var settings: RunSettings

    var body: some View {
        Picker("3D preview detail", selection: $settings.previewFaces) {
            Text("150k faces").tag(150_000)
            Text("300k faces").tag(300_000)
            Text("600k faces").tag(600_000)
        }
        Text("Marked entities and regions are cut out of the mesh and the cloud as 4 cm voxels; the holes are filled on a ground plane fitted to the surroundings and textured from them.")
            .font(.caption).foregroundStyle(.secondary)
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
