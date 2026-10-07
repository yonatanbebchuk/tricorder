import SwiftUI

/// The site plan as the app shows it: the orthomosaic with the 1 m grid, contour lines, the surveyed footprint, the
/// boundary (from the perimeter walls, edge by edge as wall, fence or unknown, with windows and doors on it), the interior
/// walls, the dimensions and the measurements, all placed in metres from overlay.json. Two modes: **Outline** (the line
/// drawing) and **Land use** (the yard partitioned into what the ground is, from your marks and the inventory).
/// The whole plan rotates: by default the longest boundary side is horizontal; any side can be aligned, or drag the dial.
struct SitePlanView: View {
    let record: AssetRecord
    let overlay: PlanOverlay

    /// Outer: the boundary alone, dimensioned. Inner: the same, plus the partition of the ground (your areas) as the same
    /// black line, each side dimensioned. One line drawing, as an architect would read it.
    enum Mode: String, CaseIterable, Identifiable {
        case outer, inner
        var id: String { rawValue }
        var label: String { self == .outer ? "Outer" : "Inner" }
    }

    @State private var mode: Mode = ProcessInfo.processInfo.environment["TRICORDER_PLAN_MODE"] == "inner" ? .inner : .outer
    @State private var showTraced = false
    @State private var boundarySource: String = "walls"
    @State private var showGrid = true
    @State private var showContours = false
    @State private var showFootprint = false
    @State private var showMeasurements = true
    @State private var showLinework = true
    @State private var showDimensions = true
    @State private var showElements = false
    @State private var showOpenings = true
    @State private var cleanDrawing = true
    @State private var rotation: Double = 0
    @State private var rotationSet = false

    private var structured: PlanOverlay.Boundary? { overlay.boundary(boundarySource) }
    /// The boundary polygon the drawing is built on: the chosen traced one, else the first polygon of the linework.
    private var boundary: PlanOverlay.Polygon? {
        if let b = structured { return PlanOverlay.Polygon(points: b.points, lengths: b.lengths, area: b.area) }
        return overlay.polygons?.first
    }
    private var otherPolygons: [PlanOverlay.Polygon] { Array((overlay.polygons ?? []).dropFirst()) }
    private var centre: (Double, Double) { (overlay.xMin + overlay.widthM / 2, overlay.yMax - overlay.heightM / 2) }
    private var hasBothBoundaries: Bool { (overlay.boundaries?.count ?? 0) >= 2 }
    private var landuse: [PlanOverlay.LandUse] { overlay.landuse ?? [] }

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
                        func path(_ pts: [[Double]], close: Bool) -> Path {
                            var p = Path()
                            guard let f = pts.first else { return p }
                            p.move(to: pt(f[0], f[1]))
                            for q in pts.dropFirst() { p.addLine(to: pt(q[0], q[1])) }
                            if close { p.closeSubpath() }
                            return p
                        }
                        func stroke(_ pts: [[Double]], close: Bool, color: Color, width: CGFloat, dash: [CGFloat] = []) {
                            guard pts.count > 1 else { return }
                            ctx.stroke(path(pts, close: close), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .miter, dash: dash))
                        }
                        func label(_ text: Text, at p: CGPoint, angle: Double = 0) {
                            var t = ctx
                            t.translateBy(x: p.x, y: p.y)
                            t.rotate(by: .radians(-angle))
                            let r = t.resolve(text)
                            let sz = r.measure(in: CGSize(width: 240, height: 60))
                            t.fill(Path(roundedRect: CGRect(x: -sz.width / 2 - 3, y: -sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2), cornerRadius: 3),
                                   with: .color(Color(nsColor: .textBackgroundColor).opacity(0.9)))
                            t.draw(r, at: .zero)
                        }
                        if !cleanDrawing, let img = ctx.resolveSymbol(id: "ortho") {
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
                        // inner: the partition of the ground as the same black line, each side that is not the boundary dimensioned
                        if mode == .inner {
                            let ring = boundary?.points ?? []
                            func onBoundary(_ a: [Double], _ b: [Double]) -> Bool {
                                guard ring.count >= 2 else { return false }
                                func d(_ p: [Double]) -> Double {
                                    var best = Double.infinity
                                    for i in 0..<ring.count {
                                        let q0 = ring[i], q1 = ring[(i + 1) % ring.count]
                                        let vx = q1[0] - q0[0], vy = q1[1] - q0[1]
                                        let t = max(0, min(1, ((p[0] - q0[0]) * vx + (p[1] - q0[1]) * vy) / max(vx * vx + vy * vy, 1e-12)))
                                        let dx = p[0] - (q0[0] + vx * t), dy = p[1] - (q0[1] + vy * t)
                                        best = min(best, (dx * dx + dy * dy).squareRoot())
                                    }
                                    return best
                                }
                                return d(a) < 0.12 && d(b) < 0.12 && d([(a[0] + b[0]) / 2, (a[1] + b[1]) / 2]) < 0.12
                            }
                            for lu in landuse where lu.material != "unassigned" {
                                for part in lu.polygons where part.exterior.count >= 3 {
                                    let ext = part.exterior
                                    let n = ext.count
                                    for i in 0..<n {
                                        let a = ext[i], b = ext[(i + 1) % n]
                                        if onBoundary(a, b) { continue }
                                        stroke([a, b], close: false, color: .primary, width: 1.3)
                                        let dx = b[0] - a[0], dy = b[1] - a[1], len = (dx * dx + dy * dy).squareRoot()
                                        if showDimensions, len >= 0.5 {
                                            // the label sits inside the area: on the side of the edge where the polygon's centre is
                                            let cx = ext.map { $0[0] }.reduce(0, +) / Double(n), cy = ext.map { $0[1] }.reduce(0, +) / Double(n)
                                            var nx = -dy / len, ny = dx / len
                                            if (cx - a[0]) * nx + (cy - a[1]) * ny < 0 { nx = -nx; ny = -ny }
                                            let mid = pt((a[0] + b[0]) / 2 + nx * 0.4, (a[1] + b[1]) / 2 + ny * 0.4)
                                            var ang = atan2(-(pt(b[0], b[1]).y - pt(a[0], a[1]).y), pt(b[0], b[1]).x - pt(a[0], a[1]).x)
                                            if ang > .pi / 2 || ang < -.pi / 2 { ang += .pi }
                                            label(Text(String(format: "%.2f", len)).font(.system(size: 9, weight: .medium)).foregroundStyle(.primary), at: mid, angle: ang)
                                        }
                                    }
                                    for h in part.holes where h.count >= 3 { stroke(h, close: true, color: .primary, width: 1.3) }
                                    if lu.areaM2 >= 1 {
                                        let cx = ext.map { $0[0] }.reduce(0, +) / Double(n), cy = ext.map { $0[1] }.reduce(0, +) / Double(n)
                                        label(Text("\(lu.name.uppercased())  \(String(format: "%.1f m²", lu.areaM2))").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.primary), at: pt(cx, cy))
                                    }
                                }
                            }
                        }
                        // the boundary: edge by edge when the layout classified them
                        if showLinework {
                            if let b = structured {
                                for e in b.edges {
                                    switch e.cls {
                                    case "wall": stroke([e.a, e.b], close: false, color: .primary, width: 3.2)
                                    case "fence":
                                        stroke([e.a, e.b], close: false, color: .primary, width: 1.2)
                                        let dx = e.b[0] - e.a[0], dy = e.b[1] - e.a[1], len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                                        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
                                        for t in stride(from: 0.25, to: len, by: 0.5) {
                                            let px = e.a[0] + ux * t, py = e.a[1] + uy * t
                                            stroke([[px - nx * 0.12, py - ny * 0.12], [px + nx * 0.12, py + ny * 0.12]], close: false, color: .primary, width: 0.9)
                                        }
                                    default: stroke([e.a, e.b], close: false, color: .primary, width: 1.8, dash: [7, 3])
                                    }
                                }
                                if showOpenings {
                                    for op in b.openings {
                                        let dx = op.b[0] - op.a[0], dy = op.b[1] - op.a[1], len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                                        let nx = -dy / len * Double(op.swing), ny = dx / len * Double(op.swing)
                                        stroke([op.a, op.b], close: false, color: Color(nsColor: .textBackgroundColor), width: op.cls == "window" ? 3.4 : 4)
                                        if op.cls == "window" {
                                            for off in [-0.08, 0.08] {
                                                stroke([[op.a[0] + nx * off, op.a[1] + ny * off], [op.b[0] + nx * off, op.b[1] + ny * off]], close: false, color: Color(red: 0.29, green: 0.56, blue: 0.78), width: 1.2)
                                            }
                                        } else {
                                            let leaf = [op.a[0] + nx * len, op.a[1] + ny * len]
                                            stroke([op.a, leaf], close: false, color: Color(red: 0.79, green: 0.54, blue: 0.16), width: 1.2)
                                            var arc = Path()
                                            let a0 = atan2(ny, nx), a1 = atan2(dy / len, dx / len)
                                            var steps: [[Double]] = []
                                            for k in 0...16 {
                                                var ang = a0 + (a1 - a0) * Double(k) / 16
                                                if abs(a1 - a0) > .pi { ang = a0 + ((a1 - a0) - (a1 > a0 ? 2 * .pi : -2 * .pi)) * Double(k) / 16 }
                                                steps.append([op.a[0] + len * cos(ang), op.a[1] + len * sin(ang)])
                                            }
                                            arc = path(steps, close: false)
                                            ctx.stroke(arc, with: .color(Color(red: 0.79, green: 0.54, blue: 0.16)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                                        }
                                        if mode == .outer {   // the inner drawing keeps its labels for the partition
                                            label(Text(op.name).font(.system(size: 8.5)).foregroundStyle(.secondary), at: pt((op.a[0] + op.b[0]) / 2 + nx * 0.35, (op.a[1] + op.b[1]) / 2 + ny * 0.35))
                                        }
                                    }
                                }
                            } else if let bp = boundary {
                                stroke(bp.points, close: true, color: .primary, width: 2.4)
                            }
                            for poly in otherPolygons { stroke(poly.points, close: true, color: .primary, width: 1.2) }
                            if showTraced {
                                for seg in overlay.wallsAll ?? overlay.walls ?? [] where seg.count == 2 { stroke(seg, close: false, color: Theme.accent.opacity(0.85), width: 1.4) }
                            }
                            if showDimensions, let poly = boundary {
                                let n = poly.points.count
                                for i in 0..<n where i < poly.lengths.count && poly.lengths[i] >= 0.5 {
                                    let a = poly.points[i], b = poly.points[(i + 1) % n]
                                    let dx = b[0] - a[0], dy = b[1] - a[1], len = max((dx * dx + dy * dy).squareRoot(), 1e-9)
                                    let nx = dy / len, ny = -dx / len
                                    let mid = pt((a[0] + b[0]) / 2 + nx * 0.55, (a[1] + b[1]) / 2 + ny * 0.55)
                                    var ang = atan2(-(pt(b[0], b[1]).y - pt(a[0], a[1]).y), pt(b[0], b[1]).x - pt(a[0], a[1]).x)
                                    if ang > .pi / 2 || ang < -.pi / 2 { ang += .pi }
                                    label(Text(String(format: "%.2f", poly.lengths[i])).font(.system(size: 10, weight: .semibold)).foregroundStyle(.primary), at: mid, angle: ang)
                                }
                            }
                        }
                        // named elements: the inventory's only when asked; your area marks are the inner partition, your other
                        // marks (trees, objects) are drawn as outlines in the inner drawing
                        for el in overlay.elements ?? [] where !el.points.isEmpty && el.minor != true && el.cls != "area"
                            && ((el.source == "mark" && mode == .inner) || showElements) {
                            do {
                                let col = Overlay.swiftColor(el.color ?? "#d97757")
                                if el.shape == "polygon", el.points.count >= 3 {
                                    if el.source != "mark" { ctx.fill(path(el.points, close: true), with: .color(col.opacity(0.22))) }
                                    stroke(el.points, close: true, color: el.source == "mark" ? .primary : col, width: 1.1)
                                } else if el.points.count >= 2 {
                                    stroke(el.points, close: false, color: col, width: el.cls == "wall" || el.cls == "fence" ? 2.2 : 1.2)
                                } else {
                                    let c = pt(el.points[0][0], el.points[0][1])
                                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(col))
                                }
                                if structured != nil && (el.cls == "window" || el.cls == "door") { continue }   // drawn on the boundary instead
                                let cx = el.points.map { $0[0] }.reduce(0, +) / Double(el.points.count)
                                let cy = el.points.map { $0[1] }.reduce(0, +) / Double(el.points.count)
                                label(Text(el.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.primary), at: pt(cx, cy))
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
                Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150).disabled(landuse.isEmpty)
                    .help("Outer: the boundary alone. Inner: the boundary and the partition of the ground from your area marks, every side dimensioned.")
                if hasBothBoundaries {
                    Picker("Boundary", selection: $boundarySource) {
                        Text("walls").tag("walls")
                        Text("footprint").tag("footprint")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .help("Walls: the perimeter walls chained corner to corner, the ground's outline only where no wall was found. Footprint: the ground's outline regularised.")
                }
                Divider().frame(height: 14)
                Toggle("Line drawing", isOn: $cleanDrawing).help("Hide the orthomosaic and contours")
                Toggle("Grid", isOn: $showGrid)
                Toggle("Contours", isOn: $showContours).disabled(cleanDrawing)
                Toggle("Boundary", isOn: $showLinework)
                Toggle("Dimensions", isOn: $showDimensions).disabled(boundary == nil)
                Toggle("Traced walls", isOn: $showTraced).help("The raw wall lines the tracer found (orange)")
                Toggle("Openings", isOn: $showOpenings).disabled(structured?.openings.isEmpty ?? true)
                Toggle("Footprint", isOn: $showFootprint)
                Toggle("Measurements", isOn: $showMeasurements)
                Toggle("Inventory", isOn: $showElements).disabled((overlay.elements ?? []).isEmpty).help("Draw the generated entities too; your marks are always drawn")
                Spacer()
                Text(String(format: "%.1f × %.1f m", overlay.widthM, overlay.heightM) + (boundary.map { String(format: " · boundary %.0f m², %d sides", $0.area, $0.points.count) } ?? "")
                     + (structured.map { b in " · " + b.edgeClasses.sorted { $0.key < $1.key }.map { "\($0.key) \(String(format: "%.0f", $0.value)) m" }.joined(separator: ", ") } ?? ""))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            if mode == .inner, !landuse.isEmpty {
                HStack(spacing: 10) {
                    Text("Inner").font(.caption.weight(.semibold))
                    ForEach(landuse) { lu in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(Overlay.swiftColor(lu.color ?? "#cccccc").opacity(0.7)).frame(width: 12, height: 10)
                            Text("\(lu.name) \(String(format: "%.1f", lu.areaM2)) m²").font(.caption)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                }
            } else if let q = overlay.quantities, case .object(let areas)? = q["areas"] {
                HStack(spacing: 10) {
                    Text("Quantities").font(.caption.weight(.semibold))
                    ForEach(areas.sorted { ($0.value.double ?? 0) > ($1.value.double ?? 0) }, id: \.key) { k, v in
                        Text("\(k) \(String(format: "%.1f", v.double ?? 0)) m²").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                    if case .object(let lengths)? = q["lengths"] {
                        ForEach(lengths.sorted { $0.key < $1.key }, id: \.key) { k, v in
                            Text("\(k) \(String(format: "%.1f", v.double ?? 0)) m").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                        }
                    }
                    if case .object(let counts)? = q["counts"] {
                        ForEach(counts.sorted { $0.key < $1.key }.filter { !["area", "wall", "fence"].contains($0.key) }, id: \.key) { k, v in
                            Text("\(v.int ?? 0) \(k)").font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text("Rotate").font(.caption)
                Slider(value: $rotation, in: -180...180, step: 0.5).frame(width: 260)
                Text(String(format: "%.1f°", rotation)).font(Theme.mono).frame(width: 52, alignment: .trailing)
                Button("Longest side") { rotation = longestSideAngle }.font(.caption)
                Button("North up") { rotation = 0 }.font(.caption)
                if let b = boundary {
                    Menu("Align to side…") {
                        ForEach(0..<b.points.count, id: \.self) { i in
                            let a = b.points[i], c = b.points[(i + 1) % b.points.count]
                            Button(String(format: "side %d · %.2f m", i + 1, i < b.lengths.count ? b.lengths[i] : 0)) { rotation = atan2(c[1] - a[1], c[0] - a[0]) * 180 / .pi }
                        }
                    }
                    .font(.caption).frame(width: 150)
                }
            }
        }
        .onAppear {
            if !rotationSet {
                boundarySource = overlay.boundarySource ?? "walls"
                rotation = longestSideAngle
                rotationSet = true
            }
        }
    }

    /// The angle of the boundary's longest side, so it lies horizontal.
    private var longestSideAngle: Double {
        guard let b = boundary, !b.points.isEmpty else { return overlay.alignDeg ?? 0 }
        var best = (0.0, 0.0)
        for i in 0..<b.points.count {
            let a = b.points[i], c = b.points[(i + 1) % b.points.count]
            let len = ((c[0] - a[0]) * (c[0] - a[0]) + (c[1] - a[1]) * (c[1] - a[1])).squareRoot()
            if len > best.0 { best = (len, atan2(c[1] - a[1], c[0] - a[0]) * 180 / .pi) }
        }
        return best.1
    }

    /// Points per metre so the rotated plan fits the view.
    private func fitScale(in size: CGSize) -> CGFloat {
        let rot = rotation * .pi / 180
        let w = abs(overlay.widthM * cos(rot)) + abs(overlay.heightM * sin(rot))
        let h = abs(overlay.widthM * sin(rot)) + abs(overlay.heightM * cos(rot))
        return min((size.width - 40) / max(w, 1), (size.height - 40) / max(h, 1))
    }
}
