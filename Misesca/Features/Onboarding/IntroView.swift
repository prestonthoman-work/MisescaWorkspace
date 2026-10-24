import SwiftUI

/// Three screens on first launch. Each says what the crew will do, not how it works.
struct IntroView: View {
    var finish: () -> Void
    @State private var page = 0

    private let pages: [(title: String, text: String, art: IntroArt.Kind)] = [
        ("Set the room to the plan",
         "Misesca shows the approved layout on the ballroom floor at full size. Set each table on its outline.",
         .plan),
        ("Two points line it up",
         "Tap two marked spots on the real floor, like the stage front and the main entrance. The whole layout appears where it belongs.",
         .points),
        ("Check before doors",
         "Scan the finished room. Misesca lists any table that's off, missing or extra, and any aisle that's too narrow.",
         .check)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Misesca")
                    .font(.heading(.headline))
                    .foregroundStyle(Palette.brass)
                Spacer()
                if page < pages.count - 1 {
                    Button("Skip", action: finish)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 18) {
                        IntroArt(kind: pages[i].art)
                            .frame(maxWidth: .infinity)
                            .frame(height: 280)
                            .padding(.bottom, 12)
                        Text(pages[i].title)
                            .font(.heading(.largeTitle))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pages[i].text)
                            .font(.title3)
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Palette.brass : Palette.rule)
                        .frame(width: i == page ? 20 : 8, height: 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")

            Button(page < pages.count - 1 ? "Next" : "Open events") {
                if page < pages.count - 1 {
                    withAnimation(.easeOut(duration: 0.25)) { page += 1 }
                } else {
                    finish()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Palette.background.ignoresSafeArea())
    }
}

/// Line drawings in the plan's own visual language.
struct IntroArt: View {
    enum Kind { case plan, points, check }
    var kind: Kind

    var body: some View {
        Canvas { ctx, size in
            switch kind {
            case .plan: drawPlan(&ctx, size, check: false)
            case .points: drawFloor(&ctx, size)
            case .check: drawPlan(&ctx, size, check: true)
            }
        }
        .accessibilityHidden(true)
    }

    private func drawPlan(_ ctx: inout GraphicsContext, _ size: CGSize, check: Bool) {
        let room = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
        ctx.fill(Path(room), with: .color(Palette.surface))
        ctx.stroke(Path(room), with: .color(Palette.ink), lineWidth: 1.5)
        let stage = CGRect(x: room.midX - room.width * 0.2, y: room.minY, width: room.width * 0.4, height: room.height * 0.12)
        ctx.fill(Path(stage), with: .color(Palette.ink.opacity(0.1)))
        ctx.stroke(Path(stage), with: .color(Palette.ink.opacity(0.7)), lineWidth: 1.25)

        let cols = 4, rows = 3
        let r = min(room.width / CGFloat(cols * 2) * 0.55, room.height / CGFloat(rows * 2 + 2) * 0.55)
        for row in 0..<rows {
            for col in 0..<cols {
                let x = room.minX + room.width * (CGFloat(col) + 0.5) / CGFloat(cols)
                let y = room.minY + room.height * 0.3 + room.height * 0.65 * (CGFloat(row) + 0.5) / CGFloat(rows)
                var center = CGPoint(x: x, y: y)
                let n = row * cols + col
                var color = Palette.brass
                var filled = false
                if check {
                    filled = true
                    color = Palette.sage
                    if n == 6 {
                        color = Palette.terracotta
                        center.x += r * 0.9
                        center.y -= r * 0.5
                        let ghost = Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                        ctx.stroke(ghost, with: .color(Palette.slate), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    }
                } else {
                    filled = n < 5
                    color = filled ? Palette.sage : Palette.brass
                }
                let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                ctx.fill(circle, with: .color(filled ? color : color.opacity(0.12)))
                ctx.stroke(circle, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    /// The floor in perspective with ghost tables and the two tapped points.
    private func drawFloor(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        func project(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            // u across 0...1, v depth 0 (near) ... 1 (far)
            let scale = 1 - v * 0.55
            return CGPoint(x: w / 2 + (u - 0.5) * w * scale, y: h - 10 - v * (h * 0.8))
        }
        var floor = Path()
        floor.addLines([project(0, 0), project(1, 0), project(1, 1), project(0, 1)])
        floor.closeSubpath()
        ctx.fill(floor, with: .color(Palette.surface))
        ctx.stroke(floor, with: .color(Palette.ink.opacity(0.5)), lineWidth: 1)

        for v in stride(from: 0.75, through: 0.15, by: -0.3) {
            for u in [0.2, 0.5, 0.8] {
                let c = project(u, v)
                let scale = 1 - v * 0.55
                let rx = w * 0.09 * scale, ry = rx * 0.38
                let top = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry - 18 * scale, width: 2 * rx, height: 2 * ry))
                let base = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry))
                ctx.fill(base, with: .color(Palette.brass.opacity(0.12)))
                ctx.fill(top, with: .color(Palette.brass.opacity(0.3)))
                ctx.stroke(top, with: .color(Palette.brass), lineWidth: 1.25)
            }
        }

        for (letter, u, v) in [("A", 0.5, 0.96), ("B", 0.5, 0.02)] {
            let p = project(CGFloat(u), CGFloat(v))
            let r: CGFloat = 11
            var post = Path()
            post.move(to: p)
            post.addLine(to: CGPoint(x: p.x, y: p.y - 26))
            ctx.stroke(post, with: .color(Palette.brass), lineWidth: 2)
            let head = CGPoint(x: p.x, y: p.y - 26 - r)
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - r, y: head.y - r, width: 2 * r, height: 2 * r)), with: .color(Palette.brass))
            ctx.draw(Text(letter).font(.system(size: 12, weight: .bold)).foregroundColor(Palette.onAccent), at: head)
        }
    }
}
