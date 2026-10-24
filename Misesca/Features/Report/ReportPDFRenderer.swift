import SwiftUI
import UIKit
import MisescaKit

/// A one-or-more page Letter PDF: header, colored plan, issue list. Always rendered in light colors.
@MainActor
enum ReportPDFRenderer {
    static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    static let margin: CGFloat = 48

    static func render(layout: EventLayout, report: CheckReport) throws -> URL {
        let page = Self.page, margin = Self.margin
        let width = page.width - margin * 2
        let planHeight = min(width * layout.room.depthFt / layout.room.widthFt, 380)
        let planWidth = planHeight * layout.room.widthFt / layout.room.depthFt

        let planView = PlanCanvasView(layout: layout, report: report)
            .frame(width: planWidth, height: planHeight)
            .environment(\.colorScheme, .light)
        let imageRenderer = ImageRenderer(content: planView)
        imageRenderer.scale = 3
        let planImage = imageRenderer.uiImage

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let safeName = layout.event.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName)-Mise-Check-\(stamp.string(from: report.date)).pdf")

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(layout.event.name) Mise Check",
                               kCGPDFContextCreator as String: "Misesca"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)

        let ink = Palette.Fixed.ink, secondary = Palette.Fixed.secondary
        let title: [NSAttributedString.Key: Any] = [.font: UIFont.serif(size: 24, weight: .bold), .foregroundColor: ink]
        let heading: [NSAttributedString.Key: Any] = [.font: UIFont.serif(size: 15, weight: .semibold), .foregroundColor: ink]
        let body: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: ink]
        let small: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9.5), .foregroundColor: secondary]

        let w = Wording(layout: layout)
        var lines: [(String, UIColor)] = []
        for t in report.tables where t.status == .off { lines.append((w.message(for: t), Palette.Fixed.terracotta)) }
        for t in report.tables where t.status == .missing { lines.append((w.message(for: t), Palette.Fixed.slate)) }
        for e in report.extras { lines.append((w.message(for: e), Palette.Fixed.terracotta)) }
        for a in report.narrowAisles { lines.append((w.message(for: a), Palette.Fixed.terracotta)) }
        let notChecked = report.tables.filter { $0.status == .notChecked }
        if !notChecked.isEmpty {
            let names = notChecked.compactMap { layout.item(id: $0.itemID)?.shortLabel }.joined(separator: ", ")
            lines.append(("Not checked: \(names).", Palette.Fixed.secondary))
        }

        try renderer.writePDF(to: url) { ctx in
            var pageNumber = 0
            var y: CGFloat = 0

            func newPage() {
                ctx.beginPage()
                pageNumber += 1
                y = margin
                let footer = "Misesca · \(layout.event.name) · Page \(pageNumber)"
                (footer as NSString).draw(at: CGPoint(x: margin, y: page.height - margin + 16), withAttributes: small)
            }

            func draw(_ text: String, _ attrs: [NSAttributedString.Key: Any], indent: CGFloat = 0, after: CGFloat = 6) {
                let s = NSAttributedString(string: text, attributes: attrs)
                let box = s.boundingRect(with: CGSize(width: width - indent, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                if y + box.height > page.height - margin { newPage() }
                s.draw(with: CGRect(x: margin + indent, y: y, width: width - indent, height: box.height),
                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += ceil(box.height) + after
            }

            newPage()
            draw(layout.event.name, title, after: 4)
            var info = [layout.event.room]
            if let start = layout.event.start { info.append(Format.eventDate.string(from: start)) }
            draw(info.joined(separator: " · "), small, after: 2)
            let how = report.method == .roomScan ? "Room scan" : "Checked one at a time"
            draw("Mise Check \(Format.checkTime.string(from: report.date)) · \(how) · \(Format.inches(report.toleranceInches)) tolerance", small, after: 14)
            draw(report.isClean ? "Room's set. Everything in its place." : report.summary, heading, after: 14)

            if let planImage {
                planImage.draw(in: CGRect(x: margin + (width - planWidth) / 2, y: y, width: planWidth, height: planHeight))
                y += planHeight + 10
            }
            draw("Green: en place. Red: off or extra, dashed outline shows where it is. Gray dashed: missing.", small, after: 18)

            if !lines.isEmpty {
                draw("Issues", heading, after: 8)
                for (text, color) in lines {
                    if y + 16 > page.height - margin { newPage() }
                    color.setFill()
                    UIBezierPath(ovalIn: CGRect(x: margin, y: y + 4, width: 6, height: 6)).fill()
                    draw(text, body, indent: 14, after: 6)
                }
            }
        }
        return url
    }
}
