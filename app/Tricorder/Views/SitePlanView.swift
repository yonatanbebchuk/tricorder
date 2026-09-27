import SwiftUI

/// The site plan as the app shows it: the orthomosaic with the 1 m grid, contour lines, the surveyed footprint and
/// the measurements drawn over it, all placed in metres from overlay.json. The DXF and PDF carry the same content.
struct SitePlanView: View {
    let record: AssetRecord
    let overlay: PlanOverlay

    @State private var showGrid = true
    @State private var showContours = true
    @State private var showFootprint = false
    @State private var showMeasurements = true
    @State private var showLinework = true
    @State private var cleanDrawing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let rect = fitRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if let img = record.planImage, !cleanDrawing {
                        FileImage(url: img, maxPixel: 3000)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                    Canvas { ctx, _ in
                        let sx = rect.width / overlay.widthM, sy = rect.height / overlay.heightM
                        func pt(_ x: Double, _ y: Double) -> CGPoint {
                            CGPoint(x: rect.minX + (x - overlay.xMin) * sx, y: rect.minY + (overlay.yMax - y) * sy)
                        }
                        if showGrid {
                            let x1 = overlay.xMin + overlay.widthM, y0 = overlay.yMax - overlay.heightM
                            for gx in stride(from: overlay.xMin.rounded(.up), to: x1, by: 1) {
                                let major = gx.truncatingRemainder(dividingBy: 5) == 0
                                var p = Path(); p.move(to: pt(gx, y0)); p.addLine(to: pt(gx, overlay.yMax))
                                ctx.stroke(p, with: .color(.primary.opacity(major ? 0.35 : 0.15)), lineWidth: major ? 0.8 : 0.4)
                                if major { ctx.draw(Text(String(format: "%.0f", gx)).font(.system(size: 9)).foregroundStyle(.secondary), at: pt(gx, overlay.yMax).applying(.init(translationX: 0, y: -7))) }
                            }
                            for gy in stride(from: y0.rounded(.up), to: overlay.yMax, by: 1) {
                                let major = gy.truncatingRemainder(dividingBy: 5) == 0
                                var p = Path(); p.move(to: pt(overlay.xMin, gy)); p.addLine(to: pt(x1, gy))
                                ctx.stroke(p, with: .color(.primary.opacity(major ? 0.35 : 0.15)), lineWidth: major ? 0.8 : 0.4)
                                if major { ctx.draw(Text(String(format: "%.0f", gy)).font(.system(size: 9)).foregroundStyle(.secondary), at: pt(x1, gy).applying(.init(translationX: 9, y: 0))) }
                            }
                        }
                        if showContours, !cleanDrawing {
                            for c in overlay.contours where c.points.count > 1 {
                                var p = Path()
                                p.move(to: pt(c.points[0][0], c.points[0][1]))
                                for q in c.points.dropFirst() { p.addLine(to: pt(q[0], q[1])) }
                                ctx.stroke(p, with: .color(Color(red: 0.54, green: 0.35, blue: 0.17).opacity(c.index ? 0.9 : 0.55)), lineWidth: c.index ? 1.2 : 0.6)
                                if c.index, c.points.count > 30 {
                                    let m = c.points[c.points.count / 2]
                                    ctx.draw(Text(String(format: "%.2f", c.level)).font(.system(size: 8)).foregroundStyle(Color(red: 0.54, green: 0.35, blue: 0.17)), at: pt(m[0], m[1]))
                                }
                            }
                        }
                        if showFootprint {
                            for poly in overlay.footprint where poly.count > 2 {
                                var p = Path()
                                p.move(to: pt(poly[0][0], poly[0][1]))
                                for q in poly.dropFirst() { p.addLine(to: pt(q[0], q[1])) }
                                p.closeSubpath()
                                ctx.stroke(p, with: .color(Color(red: 0.16, green: 0.44, blue: 0.59)), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                            }
                        }
                        if showLinework {
                            for seg in overlay.edges ?? [] where seg.count == 2 {
                                var p = Path(); p.move(to: pt(seg[0][0], seg[0][1])); p.addLine(to: pt(seg[1][0], seg[1][1]))
                                ctx.stroke(p, with: .color(.primary.opacity(0.55)), lineWidth: 0.8)
                            }
                            for seg in overlay.walls ?? [] where seg.count == 2 {
                                var p = Path(); p.move(to: pt(seg[0][0], seg[0][1])); p.addLine(to: pt(seg[1][0], seg[1][1]))
                                ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: cleanDrawing ? 2.2 : 1.8, lineCap: .round))
                            }
                        }
                        if showMeasurements {
                            for m in overlay.measurements where m.a.count >= 2 && m.b.count >= 2 {
                                let a = pt(m.a[0], m.a[1]), b = pt(m.b[0], m.b[1])
                                var p = Path(); p.move(to: a); p.addLine(to: b)
                                ctx.stroke(p, with: .color(Theme.accent), lineWidth: 1.6)
                                for e in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: e.x - 3, y: e.y - 3, width: 6, height: 6)), with: .color(Theme.accent)) }
                                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 9)
                                ctx.draw(Text(String(format: "%.2f m", m.meters)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent), at: mid)
                            }
                        }
                    }
                }
            }
            .aspectRatio(CGFloat(overlay.widthPx) / CGFloat(max(overlay.heightPx, 1)), contentMode: .fit)
            .frame(maxHeight: 760)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack(spacing: 14) {
                Toggle("Line drawing", isOn: $cleanDrawing).help("Hide the orthomosaic and contours: just the traced walls, fences and edges")
                Divider().frame(height: 14)
                Toggle("Grid", isOn: $showGrid)
                Toggle("Contours" + (overlay.contourInterval.map { " (\(Format.number($0)) m)" } ?? ""), isOn: $showContours).disabled(cleanDrawing)
                Toggle("Linework", isOn: $showLinework).disabled((overlay.walls ?? []).isEmpty && (overlay.edges ?? []).isEmpty)
                Toggle("Footprint", isOn: $showFootprint)
                Toggle("Measurements", isOn: $showMeasurements)
                Spacer()
                Text(String(format: "%.1f × %.1f m · %.0f px/m", overlay.widthM, overlay.heightM, overlay.pxPerM) + (overlay.sheetScale.map { " · sheet 1:\($0)" } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
        }
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let aspect = CGFloat(overlay.widthPx) / CGFloat(max(overlay.heightPx, 1))
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
