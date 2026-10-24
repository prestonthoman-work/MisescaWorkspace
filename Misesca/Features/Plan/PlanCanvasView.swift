import SwiftUI
import MisescaKit

/// Something a report points at, used to highlight it on the plan or in AR.
enum IssueRef: Hashable {
    case table(String)
    case extra(Int)
    case aisle(String)
}

/// Top-down plan drawn to scale. Shows setup progress, or check results when given a report.
struct PlanCanvasView: View {
    var layout: EventLayout
    var placed: Set<String> = []
    var report: CheckReport?
    var highlight: IssueRef?

    var body: some View {
        Canvas { ctx, size in
            draw(in: &ctx, size: size)
        }
        .aspectRatio(layout.room.widthFt / layout.room.depthFt, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let c = layout.counts
        var s = "Plan of \(layout.event.room), \(Int(layout.room.widthFt)) by \(Int(layout.room.depthFt)) feet. \(c.rounds) rounds, \(c.banquetTables) banquet tables."
        if let report { s += " Check result: \(report.summary)" }
        else if !placed.isEmpty { s += " \(placed.count) of \(layout.items.count) en place." }
        return s
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let s = size.width / layout.room.widthFt
        func pt(_ p: PlanPoint) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }

        let room = CGRect(x: 0, y: 0, width: layout.room.widthFt * s, height: layout.room.depthFt * s)
        ctx.fill(Path(room), with: .color(Palette.surface))
        ctx.stroke(Path(room), with: .color(Palette.ink), lineWidth: 1.5)

        // Aisles: a light strip at the required width, with a dashed center line.
        for aisle in layout.aisles {
            let result = report?.aisles.first { $0.aisleID == aisle.id }
            let failing = result.map { !$0.passes } ?? false
            let color = failing ? Palette.terracotta : Palette.slate
            let axis = aisle.to - aisle.from
            let strip = Footprint(center: aisle.from + axis * 0.5, length: axis.length, width: aisle.minWidthFt,
                                  rotationDegrees: atan2(axis.y, axis.x) * 180 / .pi)
            ctx.fill(polygon(strip, pt), with: .color(color.opacity(failing ? 0.22 : 0.12)))
            var line = Path()
            line.move(to: pt(aisle.from))
            line.addLine(to: pt(aisle.to))
            ctx.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if failing, let at = result?.narrowestAt {
                let c = pt(at)
                let r: CGFloat = 5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Palette.terracotta))
            }
            if highlight == .aisle(aisle.id) {
                ctx.stroke(polygon(strip.inflated(by: 0.6), pt), with: .color(Palette.terracotta), lineWidth: 2.5)
            }
        }

        // Non-table pieces first so tables sit on top.
        let ordered = layout.items.sorted { ($0.type.isTable ? 1 : 0) < ($1.type.isTable ? 1 : 0) }
        for item in ordered {
            let shape = itemPath(item.footprint, round: item.type == .roundTable, pt)
            let style = self.style(for: item)
            if let fill = style.fill { ctx.fill(shape, with: .color(fill)) }
            ctx.stroke(shape, with: .color(style.stroke), style: StrokeStyle(lineWidth: style.lineWidth, dash: style.dash))

            if let offset = report?.tables.first(where: { $0.itemID == item.id && $0.status == .off })?.offset {
                // Where the real table is: dashed outline and a line back to its plan spot.
                var moved = item.footprint
                moved.center = moved.center + offset
                ctx.stroke(itemPath(moved, round: item.type == .roundTable, pt), with: .color(Palette.terracotta),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                var link = Path()
                link.move(to: pt(item.center))
                link.addLine(to: pt(moved.center))
                ctx.stroke(link, with: .color(Palette.terracotta), lineWidth: 1)
            }

            if highlight == .table(item.id) {
                ctx.stroke(itemPath(item.footprint.inflated(by: 1.2), round: item.type == .roundTable, pt),
                           with: .color(Palette.terracotta), lineWidth: 2.5)
            }

            let minSide = min(item.size.length, item.size.width) * s
            if item.type.isTable {
                let fontSize = min(max(minSide * 0.5, 7), 13)
                let word = item.shortLabel.split(separator: " ").first.map(String.init) ?? item.shortLabel
                let text = Text(word.count > 4 ? String(word.prefix(1)) : word)
                    .font(.system(size: fontSize, weight: .semibold).monospacedDigit())
                    .foregroundColor(style.labelColor)
                ctx.draw(text, at: pt(item.center))
            } else {
                let fontSize = min(max(minSide * 0.35, 7), 12)
                ctx.draw(Text(item.shortLabel).font(.system(size: fontSize, weight: .medium)).foregroundColor(Palette.secondary),
                         at: pt(item.center))
            }
        }

        if let report {
            for (i, extra) in report.extras.enumerated() {
                let shape = polygon(extra.footprint, pt)
                ctx.stroke(shape, with: .color(Palette.terracotta), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                let c = extra.footprint.corners.map(pt)
                var x = Path()
                x.move(to: c[0]); x.addLine(to: c[2])
                x.move(to: c[1]); x.addLine(to: c[3])
                ctx.stroke(x, with: .color(Palette.terracotta), lineWidth: 1)
                if highlight == .extra(i) {
                    ctx.stroke(polygon(extra.footprint.inflated(by: 1.2), pt), with: .color(Palette.terracotta), lineWidth: 2.5)
                }
            }
        }

        // Reference points.
        for (letter, ref) in [("A", layout.referencePoints.a), ("B", layout.referencePoints.b)] {
            let c = pt(ref.point)
            let r: CGFloat = 8
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(Palette.brass))
            ctx.draw(Text(letter).font(.system(size: 10, weight: .bold)).foregroundColor(Palette.onAccent), at: c)
        }
    }

    private struct ItemStyle {
        var fill: Color?
        var stroke: Color
        var lineWidth: CGFloat = 1.25
        var dash: [CGFloat] = []
        var labelColor: Color = Palette.ink
    }

    private func style(for item: LayoutItem) -> ItemStyle {
        if !item.type.isTable {
            switch item.type {
            case .danceFloor: return ItemStyle(fill: Palette.ink.opacity(0.05), stroke: Palette.secondary, dash: [2, 2])
            default: return ItemStyle(fill: Palette.ink.opacity(0.10), stroke: Palette.ink.opacity(0.7))
            }
        }
        if let report {
            switch report.tables.first(where: { $0.itemID == item.id })?.status {
            case .enPlace: return ItemStyle(fill: Palette.sage, stroke: Palette.sage, labelColor: Palette.onAccent)
            case .off: return ItemStyle(fill: Palette.terracotta, stroke: Palette.terracotta, labelColor: Palette.onAccent)
            case .missing: return ItemStyle(fill: nil, stroke: Palette.slate, lineWidth: 1.5, dash: [3, 2], labelColor: Palette.slate)
            case .notChecked, .none: return ItemStyle(fill: Palette.brass.opacity(0.12), stroke: Palette.brass)
            }
        }
        if placed.contains(item.id) {
            return ItemStyle(fill: Palette.sage, stroke: Palette.sage, labelColor: Palette.onAccent)
        }
        return ItemStyle(fill: Palette.brass.opacity(0.12), stroke: Palette.brass, lineWidth: 1.5)
    }

    private func polygon(_ f: Footprint, _ pt: (PlanPoint) -> CGPoint) -> Path {
        var p = Path()
        p.addLines(f.corners.map(pt))
        p.closeSubpath()
        return p
    }

    private func itemPath(_ f: Footprint, round: Bool, _ pt: (PlanPoint) -> CGPoint) -> Path {
        guard round else { return polygon(f, pt) }
        let c = pt(f.center)
        let r = pt(PlanPoint(x: f.length / 2, y: 0)).x
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
}

/// Small key for report colors.
struct ResultLegend: View {
    var body: some View {
        HStack(spacing: 16) {
            entry(Palette.sage, "En place", dashed: false)
            entry(Palette.terracotta, "Off or extra", dashed: false)
            entry(Palette.slate, "Missing", dashed: true)
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
    }

    private func entry(_ color: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            if dashed {
                Circle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 11, height: 11)
            } else {
                Circle().fill(color).frame(width: 11, height: 11)
            }
            Text(label)
        }
    }
}
