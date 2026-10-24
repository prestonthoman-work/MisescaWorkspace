import SwiftUI
import MisescaKit

/// The one main action on a screen. Tall enough for gloved hands.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Palette.brass

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = Palette.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10).stroke(Palette.rule, lineWidth: 1.5))
            .background(Palette.background.opacity(configuration.isPressed ? 0.6 : 0.001), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}

/// A colored dot and the status in words. Color is never the only signal.
struct StatusLabel: View {
    var status: EventStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(status.color).frame(width: 9, height: 9)
            Text(status.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status == .notStarted ? Palette.secondary : status.color)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small caps-style label above a group of facts.
struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Palette.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The circled A or B used on the plan and in the reference point list.
struct ReferenceBadge: View {
    var letter: String

    var body: some View {
        Text(letter)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Palette.onAccent)
            .frame(width: 24, height: 24)
            .background(Palette.brass, in: Circle())
            .accessibilityLabel("Point \(letter)")
    }
}

struct ProgressLine: View {
    var done: Int
    var total: Int
    var color: Color = Palette.sage

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.rule)
                Capsule().fill(color)
                    .frame(width: total > 0 ? geo.size.width * CGFloat(done) / CGFloat(total) : 0)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
