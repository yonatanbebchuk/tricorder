import SwiftUI

/// The site plan as the app shows it: the orthomosaic with the 1 m grid, contour lines, the surveyed footprint, the
/// traced walls, the dimensioned boundary and the measurements drawn over it, all placed in metres from overlay.json.
/// The whole plan rotates: by default the longest boundary side is horizontal; any side can be aligned, or drag the dial.
struct SitePlanView: View {
    let record: AssetRecord
    let overlay: PlanOverlay

    @State private var showGrid = true
    @State private var showContours = false
    @State private var showFootprint = false
    @State private var showMeasurements = true
    @State private var showLinework = true
    @State private var showDimensions = true
    @State private var cleanDrawing = true
    @State private var rotation: Double = 0
    @State private var rotationSet = false

    private var boundary: PlanOverlay.Polygon? { overlay.polygons?.first }
    private var centre: (Double, Double) { (overlay.xMin + overlay.widthM / 2, overlay.yMax - overlay.heightM / 2) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let s = fitScale(in: geo.size)
                ZStack {
                    Canvas { ctx, size in
                        let c = centre
                        let rot = -rotation * .pi / 180
                        func pt(_ x: Double, _ y: Double) -> CGPoint {
                            let dx = x - c.0, dy = y - c.1
                            let rx = dx * cos(rot) - dy * sin(rot), ry = dx * sin(rot) + dy * cos(rot)
                            return CGPoint(x: size.width / 2 + rx * s, y: size.height / 2 - ry * s)
                        }
                        func stroke(_ pts: [[Double]], close: Bool, color: Color, width: CGFloat, dash: [CGFloat] = []) {
                            guard pts.count > 1 else { return }
                            var p = Path(); p.move(to: pt(pts[0][0], pts[0][1]))
                            for q in pts.dropFirst() { p.addLine(to: pt(q[0], q[1])) }
                            if close { p.closeSubpath() }
                            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .miter, dash: dash))
                        }
                        if !cleanDrawing, let img = ctx.resolveSymbol(id: "ortho") {
                            // draw the orthomosaic rotated about the plan centre
                            let w = overlay.widthM * s, h = overlay.heightM * s
                            var t = ctx
                            t.translateBy(x: size.width / 2, y: size.height / 2)
                            t.rotate(by: .radians(-rot))
                            t.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                        }
                        if showGrid {
                            let x1 = overlay.xMin + overlay.widthM, y0 = overlay.yMax - overlay.heightM
                            for gx in stride(from: overlay.xMin.rounded(.up), to: x1, by: 1) {
                                let major = gx.truncatingRemainder(dividingBy: 5) == 0
                                stroke([[gx, y0], [gx, overlay.yMax]], close: false, color: .primary.opacity(major ? 0.3 : 0.12), width: major ? 0.8 : 0.4)
                            }
                            for gy in stride(from: y0.rounded(.up), to: overlay.yMax, by: 1) {
                                let major = gy.truncatingRemainder(dividingBy: 5) == 0
                                stroke([[overlay.xMin, gy], [x1, gy]], close: false, color: .primary.opacity(major ? 0.3 : 0.12), width: major ? 0.8 : 0.4)
                            }
                        }
                        if showContours, !cleanDrawing {
                            for cnt in overlay.contours where cnt.points.count > 1 {
                                stroke(cnt.points, close: false, color: Color(red: 0.54, green: 0.35, blue: 0.17).opacity(cnt.index ? 0.9 : 0.5), width: cnt.index ? 1.1 : 0.5)
                            }
                        }
                        if showFootprint {
                            for poly in overlay.footprint where poly.count > 2 {
                                stroke(poly, close: true, color: Color(red: 0.16, green: 0.44, blue: 0.59), width: 1, dash: [5, 3])
                            }
                        }
                        if showLinework {
                            for seg in overlay.walls ?? [] where seg.count == 2 { stroke(seg, close: false, color: Theme.accent.opacity(0.85), width: 1.4) }
                            for (k, poly) in (overlay.polygons ?? []).enumerated() {
                                stroke(poly.points, close: true, color: .primary, width: k == 0 ? 2.4 : 1.2)
                                if showDimensions {
                                    let n = poly.points.count
                                    for i in 0..<n where poly.lengths[i] >= 0.5 {
                                        let a = poly.points[i], b = poly.points[(i + 1) % n]
                                        let dx = b[0] - a[0], dy = b[1] - a[1], len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                                        let nx = dy / len, ny = -dx / len            // outward for a counter-clockwise ring
                                        let off = k == 0 ? 0.55 : -0.35
                                        let mid = pt((a[0] + b[0]) / 2 + nx * off, (a[1] + b[1]) / 2 + ny * off)
                                        var ang = atan2(-(pt(b[0], b[1]).y - pt(a[0], a[1]).y), pt(b[0], b[1]).x - pt(a[0], a[1]).x)
                                        if ang > .pi / 2 || ang < -.pi / 2 { ang += .pi }
                                        var t = ctx
                                        t.translateBy(x: mid.x, y: mid.y)
                                        t.rotate(by: .radians(-ang))
                                        let label = Text(String(format: "%.2f", poly.lengths[i])).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary)
                                        let r = t.resolve(label)
                                        let sz = r.measure(in: CGSize(width: 200, height: 40))
                                        t.fill(Path(roundedRect: CGRect(x: -sz.width / 2 - 3, y: -sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2), cornerRadius: 3), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.9)))
                                        t.draw(r, at: .zero)
                                    }
                                }
                            }
                        }
                        if showMeasurements {
                            for m in overlay.measurements where m.a.count >= 2 && m.b.count >= 2 {
                                stroke([m.a, m.b], close: false, color: Theme.accent, width: 1.6)
                                for e in [m.a, m.b] { let c = pt(e[0], e[1]); ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(Theme.accent)) }
                                let mid = pt((m.a[0] + m.b[0]) / 2, (m.a[1] + m.b[1]) / 2)
                                ctx.draw(Text(String(format: "%.2f m", m.meters)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent), at: CGPoint(x: mid.x, y: mid.y - 10))
                            }
                        }
                        // north arrow, rotated with the plan
                        let nTip = pt(overlay.xMin + overlay.widthM + 1.0, overlay.yMax + 0.5)
                        let nTail = pt(overlay.xMin + overlay.widthM + 1.0, overlay.yMax - 1.5)
                        var np = Path(); np.move(to: nTail); np.addLine(to: nTip)
                        ctx.stroke(np, with: .color(.primary), lineWidth: 1.2)
                        ctx.draw(Text("N").font(.system(size: 11, weight: .bold)), at: CGPoint(x: nTip.x, y: nTip.y - 9))
                    } symbols: {
                        if let img = record.planImage {
                            FileImage(url: img, maxPixel: 3000).tag("ortho")
                        }
                    }
                }
                .clipped()
            }
            .frame(maxWidth: .infinity, minHeight: 620, maxHeight: 820)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack(spacing: 12) {
                Toggle("Line drawing", isOn: $cleanDrawing).help("Hide the orthomosaic and contours")
                Divider().frame(height: 14)
                Toggle("Grid", isOn: $showGrid)
                Toggle("Contours", isOn: $showContours).disabled(cleanDrawing)
                Toggle("Walls", isOn: $showLinework)
                Toggle("Dimensions", isOn: $showDimensions).disabled(boundary == nil)
                Toggle("Footprint", isOn: $showFootprint)
                Toggle("Measurements", isOn: $showMeasurements)
                Spacer()
                Text(String(format: "%.1f × %.1f m", overlay.widthM, overlay.heightM) + (boundary.map { String(format: " · boundary %.0f m², %d sides", $0.area, $0.points.count) } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            HStack(spacing: 12) {
                Text("Rotate").font(.caption)
                Slider(value: $rotation, in: -180...180, step: 0.5).frame(width: 260)
                Text(String(format: "%.1f°", rotation)).font(Theme.mono).frame(width: 52, alignment: .trailing)
                Button("Longest side") { rotation = overlay.alignDeg ?? 0 }.font(.caption)
                Button("North up") { rotation = 0 }.font(.caption)
                if let b = boundary {
                    Menu("Align to side…") {
                        ForEach(0..<b.points.count, id: \.self) { i in
                            let a = b.points[i], c = b.points[(i + 1) % b.points.count]
                            Button(String(format: "side %d · %.2f m", i + 1, b.lengths[i])) { rotation = atan2(c[1] - a[1], c[0] - a[0]) * 180 / .pi }
                        }
                    }
                    .font(.caption).frame(width: 150)
                }
            }
        }
        .onAppear { if !rotationSet { rotation = overlay.alignDeg ?? 0; rotationSet = true } }
    }

    /// Points per metre so the rotated plan fits the view.
    private func fitScale(in size: CGSize) -> CGFloat {
        let rot = rotation * .pi / 180
        let w = abs(overlay.widthM * cos(rot)) + abs(overlay.heightM * sin(rot))
        let h = abs(overlay.widthM * sin(rot)) + abs(overlay.heightM * cos(rot))
        return min((size.width - 40) / max(w, 1), (size.height - 40) / max(h, 1))
    }
}
