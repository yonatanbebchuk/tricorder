import Foundation

enum Format {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// The pipeline's timestamp format (local time, no zone).
    static func now() -> String { stamp.string(from: Date()) }
    static func parse(_ t: String?) -> Date? { t.flatMap { stamp.date(from: $0) } }

    static func size(_ b: Int) -> String {
        let d = Double(b)
        if d > 1e9 { return String(format: "%.2f GB", d / 1e9) }
        if d > 1e6 { return String(format: "%.1f MB", d / 1e6) }
        if d > 1e3 { return String(format: "%.0f KB", d / 1e3) }
        return "\(b) B"
    }

    static func duration(_ s: Double?) -> String {
        guard let s else { return "" }
        if s < 90 { return "\(Int(s.rounded())) s" }
        if s < 5400 { return "\(Int((s / 60).rounded())) min" }
        return String(format: "%.1f h", s / 3600)
    }

    /// "2026-09-12 11:36"
    static func when(_ t: String?) -> String {
        guard let t, !t.isEmpty else { return "" }
        return String(t.replacingOccurrences(of: "T", with: " ").prefix(16))
    }

    /// "11:36"
    static func clock(_ t: String?) -> String {
        guard let t, t.count >= 16 else { return "" }
        let start = t.index(t.startIndex, offsetBy: 11)
        return String(t[start..<t.index(start, offsetBy: 5)])
    }

    static func number(_ v: Double, digits: Int = 2) -> String {
        var s = String(format: "%.\(digits)f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    static func stageMetrics(_ name: String, _ m: [String: JSONValue]) -> String {
        var p: [String] = []
        switch name {
        case "frames":
            if let n = m.int("images") { p.append("\(n) frames") }
            if let s = m.double("sharpness_median") { p.append("sharpness \(Int(s.rounded()))") }
        case "sfm":
            if let r = m.int("registered") { p.append("\(r)" + (m.int("images").map { " / \($0)" } ?? "") + " registered") }
            if let s = m.int("submodels"), s > 0 { p.append("\(s) model\(s > 1 ? "s" : "")") }
            if let e = m.double("reproj_px") { p.append(String(format: "%.2f px", e)) }
        case "dense":
            if let d = m.double("dense_points"), d > 0 { p.append(String(format: "%.1fM pts", d / 1e6)) }
            if let f = m.double("faces"), f > 0 { p.append(String(format: "%.1fM faces", f / 1e6)) }
        case "landmarks":
            if let n = m.int("prompts") { p.append("\(n) prompts") }
            if let s = m.int("structural"), s > 0 { p.append("\(s) structural") }
        case "solve":
            if let s = m.double("scale") { p.append(String(format: "scale %.4f", s)) }
            if let n = m.int("measurements") { p.append("\(n) meas.") }
            if let r = m.double("max_residual_cm") { p.append(String(format: "±%.1f cm", r)) }
        case "ortho":
            if let w = m.double("width_m"), let h = m.double("height_m") { p.append(String(format: "%.0f × %.0f m", w, h)) }
            if let px = m.double("px_per_m") { p.append(String(format: "%.0f px/m", px)) }
        case "draw":
            if let c = m.int("contours") { p.append("\(c) contours") }
            if let s = m.int("sheet_scale") { p.append("1:\(s)") }
        case "preview":
            if let f = m.double("faces"), f > 0 { p.append(String(format: "%.0fk faces", f / 1e3)) }
            if let s = m.int("size"), s > 0 { p.append(size(s)) }
        default: break
        }
        return p.joined(separator: " · ")
    }

    static func settingsLine(_ run: Run) -> String {
        let s = run.settings
        switch run.kind {
        case .scan: return "\(s.features)+\(s.matcher == "LIGHTGLUE" ? "LightGlue" : "BF") · \(s.matching) · dense L\(s.resLevel) · \(s.measures) meas."
        case .layout: return "\(s.pxPerM) px/m · contours \(number(s.contourM)) m · 1:\(s.sheetScale)"
        }
    }

    /// Asset metrics as short tiles: (value, label).
    static func assetTiles(_ a: Asset) -> [(String, String)] {
        let m = a.metrics
        var t: [(String, String)] = []
        switch a.kind {
        case .model3d:
            if let r = m.int("registered") { t.append(("\(r)" + (m.int("images").map { " / \($0)" } ?? ""), "frames registered")) }
            if let d = m.double("dense_points"), d > 0 { t.append((String(format: "%.1fM", d / 1e6), "dense points")) }
            if let f = m.double("faces"), f > 0 { t.append((String(format: "%.1fM", f / 1e6), "mesh faces")) }
            if let p = m.int("prompts") { t.append(("\(p)", "measurement prompts")) }
        case .sitePlan:
            if let s = m.double("scale") { t.append((String(format: "%.4f", s), "m per model unit")) }
            if let n = m.int("measurements") { t.append(("\(n)", "measurements")) }
            if let r = m.double("max_residual_cm") { t.append((String(format: "±%.1f cm", r), "worst residual")) }
            if let c = m.int("contours") { t.append(("\(c)", "contour lines")) }
            if let s = m.int("sheet_scale") { t.append(("1:\(s)", "sheet scale")) }
        }
        return t
    }

    static func videoLine(_ v: VideoInfo) -> String {
        var p: [String] = []
        if let d = v.durationS, d > 0 { p.append(duration(d)) }
        if let w = v.width, let h = v.height { p.append("\(w)×\(h)") }
        if let f = v.fps, f > 0 { p.append("\(Int(f.rounded())) fps") }
        if v.isHDR { p.append((v.hdr ?? "").uppercased() + " HDR") }
        return p.joined(separator: " · ")
    }

    static func warnings(recording: Recording?, run: Run) -> [String] {
        var w: [String] = []
        let f = recording?.frames.metrics ?? [:], s = run.stage("sfm").metrics
        if let images = f.int("images"), let reg = s.int("registered"), images > 0, Double(reg) < 0.6 * Double(images) {
            let sub = s.int("submodels") ?? 0
            w.append("Only \(reg) of \(images) frames registered" + (sub > 1 ? " and COLMAP split the walk into \(sub) pieces" : "")
                     + ". Blank surfaces, blur or fast turns; try the ALIKED + LightGlue run.")
        }
        if let sh = f.double("sharpness_median"), sh < 80 {
            w.append("Frames are soft (sharpness median \(Int(sh.rounded())); above 150 is comfortable).")
        }
        for k in run.kind.stages {
            let st = run.stage(k)
            if let e = st.error, st.status == .failed {
                w.append(k == "preview" ? "3D preview export failed: \(e). The asset was still published; run again to retry."
                                        : "\(ManifestStore.stageLabels[k] ?? k) failed: \(e). Open its log.")
            }
        }
        if run.status == .cancelled { w.append("Run was cancelled.") }
        if run.status == .interrupted { w.append("The pipeline process died (Mac slept or was restarted?). Run again; finished stages are kept.") }
        return w
    }
}
