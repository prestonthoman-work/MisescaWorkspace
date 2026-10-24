import SwiftUI
import MisescaKit

/// Builds a layout from a diagram image: room size, tables, line-up points, then details.
struct DiagramImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DiagramImportModel
    @State private var saveError: String?
    var onSave: (EventLayout) -> Void

    init(source: DiagramSource, onSave: @escaping (EventLayout) -> Void) {
        _model = State(initialValue: DiagramImportModel(source: source))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.step != .details {
                    DiagramCanvas(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Palette.surface)
                        .clipped()
                }
                panel
            }
            .background(Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
                if model.step != .room {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", action: back)
                    }
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .tint(Palette.brass)
            .task { await model.read() }
            .alert("Can't save yet", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var title: String {
        switch model.step {
        case .room: return "Room size"
        case .tables: return "Tables"
        case .points: return "Line-up points"
        case .details: return "Event details"
        }
    }

    private func back() {
        model.selectedID = nil
        switch model.step {
        case .tables: model.step = .room
        case .points: model.step = .tables
        case .details: model.step = .points
        default: break
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .room: roomPanel
            case .tables: tablesPanel
            case .points: pointsPanel
            case .details: detailsPanel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.background)
    }

    @ViewBuilder
    private var roomPanel: some View {
        if model.topLeft == nil {
            StepTitle("Tap the room's top-left corner.")
            StepText("Pinch to zoom in for a precise tap.")
        } else if model.bottomRight == nil {
            StepTitle("Now tap the bottom-right corner.")
            Button("Redo corners", action: model.redoCorners).buttonStyle(SecondaryButtonStyle())
        } else {
            StepTitle("How wide is the room?")
            HStack {
                TextField("Width", text: $model.widthText)
                    .keyboardType(.decimalPad)
                    .font(.title3.monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
                Text("ft").foregroundStyle(Palette.secondary)
            }
            if let cal = model.calibration {
                StepText("Depth works out to \(Units.describe(feet: cal.depthFt)), from the diagram's proportions.")
            } else {
                StepText("Use the width from the diagram or the venue's floor plan, left wall to right wall.")
            }
            HStack(spacing: 12) {
                Button("Redo corners", action: model.redoCorners).buttonStyle(SecondaryButtonStyle())
                Button(action: model.confirmRoom) {
                    if model.waitingToConfirm {
                        HStack(spacing: 8) {
                            ProgressView().tint(Palette.onAccent)
                            Text("Reading")
                        }
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.calibration == nil || model.waitingToConfirm)
                .opacity(model.calibration == nil ? 0.5 : 1)
            }
        }
    }

    @ViewBuilder
    private var tablesPanel: some View {
        if model.selected != nil {
            TableEditor(model: model)
        } else {
            StepTitle(model.foundCount > 0
                      ? "Found \(model.foundCount) tables. Check them against the diagram."
                      : "No tables found. Tap each table to add it.")
            StepText("Tap a table to fix its number, type or size. Tap an empty spot to add one.")
            Button("Continue (\(model.tableCount) tables)") {
                model.selectedID = nil
                model.step = .points
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.items.isEmpty)
            .opacity(model.items.isEmpty ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var pointsPanel: some View {
        if model.pointA == nil {
            HStack(spacing: 10) {
                ReferenceBadge(letter: "A")
                StepTitle("Tap a spot the crew can find on the real floor.")
            }
            LabeledField(label: "What is it?", text: $model.labelA)
        } else if model.pointB == nil {
            HStack(spacing: 10) {
                ReferenceBadge(letter: "B")
                StepTitle("Now a second spot, far from the first.")
            }
            LabeledField(label: "What is it?", text: $model.labelB)
            Button("Redo points", action: model.redoPoints).buttonStyle(SecondaryButtonStyle())
        } else {
            StepTitle("A: \(model.labelA). B: \(model.labelB).")
            StepText("In Set Mode the crew taps these two spots to line up the layout. Spots far apart line up best.")
            HStack(spacing: 12) {
                Button("Redo points", action: model.redoPoints).buttonStyle(SecondaryButtonStyle())
                Button("Continue") { model.step = .details }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var detailsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LabeledField(label: "Event name", text: $model.eventName)
                LabeledField(label: "Room", text: $model.roomName)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Guests").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
                    TextField("Optional", text: $model.guestsText)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
                }
                Toggle("Event date and time", isOn: $model.hasDate)
                if model.hasDate {
                    DatePicker("Starts", selection: $model.date)
                }
                Text("Aisles aren't read from diagrams, so Mise Check won't measure aisle widths for this event.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                Button("Save event") {
                    switch model.makeLayout() {
                    case .success(let layout):
                        onSave(layout)
                        dismiss()
                    case .failure(let e):
                        saveError = e.message
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.eventName.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(model.eventName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Edits the selected table.
private struct TableEditor: View {
    @Bindable var model: DiagramImportModel

    private let types: [(ItemType, String)] = [
        (.roundTable, "Round"), (.banquetTable, "Banquet"), (.stage, "Stage"), (.bar, "Bar"), (.danceFloor, "Dance floor")
    ]

    var body: some View {
        if let item = model.selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TextField("Number", text: Binding(
                        get: { item.label ?? "" },
                        set: { v in var i = item; i.label = v; model.selected = i }))
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
                    Menu {
                        ForEach(types, id: \.0) { t in
                            Button(t.1) { model.setType(t.0) }
                        }
                    } label: {
                        HStack {
                            Text(types.first { $0.0 == item.type }?.1 ?? "")
                            Image(systemName: "chevron.up.chevron.down").font(.footnote)
                        }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
                    }
                }

                if item.type == .roundTable {
                    SizeStepper(title: "Diameter", value: item.diameterFt ?? 5, range: 2.5...8) { v in
                        var i = item; i.diameterFt = v
                        i.seats = DiagramLayoutBuilder.defaultSeats(.roundTable, length: v)
                        model.selected = i
                    }
                } else {
                    SizeStepper(title: "Length", value: item.lengthFt ?? 6, range: 2...60) { v in
                        var i = item; i.lengthFt = v
                        if i.type == .banquetTable { i.seats = DiagramLayoutBuilder.defaultSeats(.banquetTable, length: v) }
                        model.selected = i
                    }
                    SizeStepper(title: "Width", value: item.widthFt ?? 2.5, range: 1...40) { v in
                        var i = item; i.widthFt = v; model.selected = i
                    }
                    Stepper(value: Binding(get: { item.rotation ?? 0 }, set: { v in
                        var i = item; i.rotation = (v.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180)
                        model.selected = i
                    }), step: 15) {
                        HStack {
                            Text("Turned").foregroundStyle(Palette.secondary)
                            Spacer()
                            Text("\(Int(item.rotation ?? 0))°").monospacedDigit().fontWeight(.semibold)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button("Remove", role: .destructive, action: model.removeSelected)
                        .buttonStyle(SecondaryButtonStyle(color: Palette.terracotta))
                    Button("Done") { model.selectedID = nil }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

private struct SizeStepper: View {
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    var set: (Double) -> Void

    var body: some View {
        Stepper(value: Binding(get: { value }, set: set), in: range, step: 0.5) {
            HStack {
                Text(title).foregroundStyle(Palette.secondary)
                Spacer()
                Text(value == value.rounded() ? "\(Int(value)) ft" : String(format: "%.1f ft", value))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
        }
    }
}

private struct LabeledField: View {
    var label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
            TextField(label, text: $text)
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
        }
    }
}

private struct StepTitle: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.heading(.title3))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StepText: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Canvas

/// The diagram with what's been marked drawn on top. Pinch to zoom, drag to pan, tap to mark.
private struct DiagramCanvas: View {
    @Bindable var model: DiagramImportModel
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let iw = model.imageSize.width, ih = model.imageSize.height
            let fit = min(geo.size.width / iw, geo.size.height / ih)
            let fitted = CGSize(width: iw * fit, height: ih * fit)

            ZStack {
                Image(uiImage: model.source.image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)
                Canvas { ctx, _ in
                    draw(&ctx, fit: fit)
                }
                .frame(width: fitted.width, height: fitted.height)
                .allowsHitTesting(false)
            }
            .scaleEffect(zoom)
            .offset(pan)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let q = CGPoint(x: (value.location.x - c.x - pan.width) / zoom + c.x,
                                y: (value.location.y - c.y - pan.height) / zoom + c.y)
                let origin = CGPoint(x: (geo.size.width - fitted.width) / 2, y: (geo.size.height - fitted.height) / 2)
                let pixel = PlanPoint(x: Double((q.x - origin.x) / fit), y: Double((q.y - origin.y) / fit))
                handleTap(pixel)
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in zoom = min(6, max(1, zoomBase * v.magnification)) }
                .onEnded { _ in
                    zoomBase = zoom
                    if zoom == 1 { pan = .zero; panBase = .zero }
                })
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: panBase.width + v.translation.width, height: panBase.height + v.translation.height)
                }
                .onEnded { _ in panBase = pan })
        }
        .accessibilityElement()
        .accessibilityLabel("Diagram. \(model.items.count) pieces marked.")
    }

    private func handleTap(_ pixel: PlanPoint) {
        guard pixel.x >= 0, pixel.y >= 0, pixel.x <= Double(model.imageSize.width), pixel.y <= Double(model.imageSize.height) else { return }
        switch model.step {
        case .room: model.tapRoom(at: pixel)
        case .tables: if let c = model.calibration { model.tapTables(at: c.plan(pixel)) }
        case .points: if let c = model.calibration { model.tapPoints(at: c.plan(pixel)) }
        default: break
        }
    }

    private func draw(_ ctx: inout GraphicsContext, fit: CGFloat) {
        let line = 2 / zoom
        func view(_ pixel: PlanPoint) -> CGPoint { CGPoint(x: pixel.x * fit, y: pixel.y * fit) }
        func dot(_ p: CGPoint, _ color: Color, _ r: CGFloat) {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
        }

        // Room corners and outline.
        if let tl = model.topLeft {
            if let br = model.bottomRight {
                let a = view(tl), b = view(br)
                ctx.stroke(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)),
                           with: .color(Palette.Fixed.brass.swiftUI), lineWidth: line * 1.5)
            }
            dot(view(tl), Palette.Fixed.brass.swiftUI, 6 / zoom)
            if let br = model.bottomRight { dot(view(br), Palette.Fixed.brass.swiftUI, 6 / zoom) }
        }

        guard let cal = model.calibration, model.step != .room else { return }
        func px(_ plan: PlanPoint) -> CGPoint { view(cal.pixel(plan)) }

        for item in model.items {
            let selected = item.id == model.selectedID
            let color = selected ? Palette.Fixed.terracotta.swiftUI : Palette.Fixed.sage.swiftUI
            let f = item.footprint
            var path = Path()
            if item.type == .roundTable {
                let c = px(f.center), r = px(PlanPoint(x: f.length / 2, y: 0)).x - px(PlanPoint(x: 0, y: 0)).x
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            } else {
                path.addLines(f.corners.map(px))
                path.closeSubpath()
            }
            ctx.fill(path, with: .color(color.opacity(selected ? 0.35 : 0.22)))
            ctx.stroke(path, with: .color(color), lineWidth: line * (selected ? 1.5 : 1))

            let tag = Text(item.shortLabel)
                .font(.system(size: 11 / zoom, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
            let resolved = ctx.resolve(tag)
            let size = resolved.measure(in: CGSize(width: 400, height: 100))
            let c = px(f.center)
            let plate = CGRect(x: c.x - size.width / 2 - 4 / zoom, y: c.y - size.height / 2 - 2 / zoom,
                               width: size.width + 8 / zoom, height: size.height + 4 / zoom)
            ctx.fill(Path(roundedRect: plate, cornerRadius: 3 / zoom), with: .color(color))
            ctx.draw(resolved, at: c)
        }

        for (letter, point) in [("A", model.pointA), ("B", model.pointB)] {
            guard let point else { continue }
            let c = px(point)
            dot(c, Palette.Fixed.brass.swiftUI, 11 / zoom)
            ctx.draw(Text(letter).font(.system(size: 12 / zoom, weight: .bold)).foregroundColor(.white), at: c)
        }
    }
}
