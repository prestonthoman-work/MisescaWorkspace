import SwiftUI
import MisescaKit

/// One line in the issue list.
struct ReportIssue: Identifiable, Hashable {
    var ref: IssueRef
    var text: String
    var color: Color
    var symbol: String
    var id: IssueRef { ref }

    static func all(in report: CheckReport, layout: EventLayout) -> [ReportIssue] {
        let w = Wording(layout: layout)
        var out: [ReportIssue] = []
        for t in report.tables where t.status == .off {
            out.append(ReportIssue(ref: .table(t.itemID), text: w.message(for: t), color: Palette.terracotta, symbol: "arrow.up.and.down.and.arrow.left.and.right"))
        }
        for t in report.tables where t.status == .missing {
            out.append(ReportIssue(ref: .table(t.itemID), text: w.message(for: t), color: Palette.slate, symbol: "circle.dashed"))
        }
        for (i, e) in report.extras.enumerated() {
            out.append(ReportIssue(ref: .extra(i), text: w.message(for: e), color: Palette.terracotta, symbol: "plus.square.dashed"))
        }
        for a in report.narrowAisles {
            out.append(ReportIssue(ref: .aisle(a.aisleID), text: w.message(for: a), color: Palette.terracotta, symbol: "arrow.left.and.right"))
        }
        return out
    }
}

struct ReportView: View {
    var layout: EventLayout
    var report: CheckReport
    /// When set, tapping an issue hands it back (Set Mode shows it in AR). Otherwise it's highlighted on the plan here.
    var onSelect: ((IssueRef) -> Void)?

    @State private var highlight: IssueRef?
    @State private var pdfURL: URL?
    @State private var exportFailed = false

    private var issues: [ReportIssue] { ReportIssue.all(in: report, layout: layout) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(report.isClean ? "Room's set. Everything in its place." : report.summary)
                        .font(.heading(.title2))
                        .monospacedDigit()
                        .foregroundStyle(report.isClean ? Palette.sage : Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(meta)
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    PlanCanvasView(layout: layout, report: report, highlight: highlight)
                    ResultLegend()
                }

                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(text: "Issues")
                            .padding(.bottom, 6)
                        ForEach(issues) { issue in
                            Button {
                                if let onSelect { onSelect(issue.ref) } else { highlight = highlight == issue.ref ? nil : issue.ref }
                            } label: {
                                IssueRow(issue: issue, selected: highlight == issue.ref, showsChevron: onSelect != nil)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(Palette.rule)
                        }
                        Text(onSelect != nil ? "Tap an issue to find it in the room." : "Tap an issue to find it on the plan.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondary)
                            .padding(.top, 10)
                    }
                }

                let notChecked = report.count(.notChecked)
                if notChecked > 0 {
                    Text("\(notChecked) \(notChecked == 1 ? "table wasn't" : "tables weren't") checked. Check them before calling the room set.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondary)
                }

                if report.method == .roomScan, report.count(.missing) > 0 {
                    Text("A table shows as missing if the scan didn't see it. If it's there, scan that part of the room again.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .navigationTitle("Mise Check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let pdfURL {
                    ShareLink(item: pdfURL) {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                } else if exportFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Palette.secondary)
                        .accessibilityLabel("PDF couldn't be made")
                }
            }
        }
        .task(id: report) {
            do {
                pdfURL = try ReportPDFRenderer.render(layout: layout, report: report)
            } catch {
                exportFailed = true
            }
        }
    }

    private var meta: String {
        let how = report.method == .roomScan ? "Room scan" : "Checked one at a time"
        return "\(layout.event.name) · \(Format.checkTime.string(from: report.date)) · \(how) · \(Format.inches(report.toleranceInches)) tolerance"
    }
}

private struct IssueRow: View {
    var issue: ReportIssue
    var selected: Bool
    var showsChevron: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: issue.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(issue.color)
                .frame(width: 28)
            Text(issue.text)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "scope")
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(selected ? Palette.surface : .clear)
        .contentShape(Rectangle())
    }
}
