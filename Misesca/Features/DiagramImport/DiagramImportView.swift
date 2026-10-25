import SwiftUI
import MisescaKit

/// Builds a layout from a diagram image: corners, size, tables, line-up points, then details.
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
                if model.step != .corners && model.step != .reading {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", action: back)
                    }
                }
            }
            .toolbar(.visible, for: .navigationBar)
            .tint(Palette.brass)
            .task { await model.findCorners() }
            .alert("Can't save yet", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var title: String {
        switch model.step {
        case .corners: return "Corners"
        case .scale: return "Size"
        case .reading: return "Reading tables"
        case .tables: return "Tables"
        case .points: return "Line-up points"
        case .details: return "Event details"
        }
    }

    private func back() {
        model.selectedID = nil
        switch model.step {
        case .scale: model.step = .corners
        case .tables: model.step = .scale
        case .points: model.step = .tables
        case .details: model.step = .points
        default: break
        }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.step {
            case .corners: cornersPanel
            case .scale: scalePanel
            case .reading: readingPanel
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
    private var cornersPanel: some View {
        StepTitle(model.findingCorners ? "Finding the room's corners" : "Check the four corners.")
        StepText("Drag each corner onto a corner of the room. For a photo of a printout, the page's corners work too. Corners snap to the walls when you let go.")
        Button("Continue") { model.step = .scale }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.findingCorners || model.tightening)
            .opacity(model.findingCorners || model.tightening ? 0.5 : 1)
    }

    @ViewBuilder
    private var scalePanel: some View {
        StepTitle("How big is it?")
        Picker("Size from", selection: $model.scaleChoice) {
            Text("Round tables").tag(DiagramImportModel.ScaleChoice.rounds)
            Text("Room size").tag(DiagramImportModel.ScaleChoice.room)
        }
        .pickerStyle(.segmented)
        if model.scaleChoice == .rounds {
            HStack {
                Text("Rounds on this diagram are").foregroundStyle(Palette.secondary)
                Spacer()
                Picker("Round size", selection: $model.roundInches) {
                    Text("60 in").tag(60.0)
                    Text("66 in").tag(66.0)
                    Text("72 in").tag(72.0)
                }
                .pickerStyle(.menu)
            }
            StepText("Most banquet rounds are 60 in. If the venue's table list says otherwise, pick that.")
        } else {
            HStack(spacing: 12) {
                FeetField(label: "Width", text: $model.widthText)
                FeetField(label: "Depth", text: $model.depthText)
            }
            StepText("Wall to wall, matching the corners you set. This is the most accurate choice.")
        }
        if let error = model.readError {
            Text(error).font(.subheadline).foregroundStyle(Palette.terracotta).fixedSize(horizontal: false, vertical: true)
        }
        Button("Read tables") { Task { await model.read() } }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!model.canRead)
            .opacity(model.canRead ? 1 : 0.5)
    }

    private var readingPanel: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Straightening the diagram and measuring each table.")
                .foregroundStyle(Palette.secondary)
        }
    }

    @ViewBuilder
    private var tablesPanel: some View {
        if model.selected != nil {
            TableEditor(model: model)
        } else {
            if let cal = model.calibration {
                StepTitle("Found \(model.foundCount) tables. Room is \(Int(cal.widthFt.rounded())) × \(Int(cal.depthFt.rounded())) ft.")
            }
            ForEach(model.warnings, id: \.self) { w in
                Text(w).font(.subheadline).foregroundStyle(Palette.terracotta).fixedSize(horizontal: false, vertical: true)
            }
            if model.guessedCount > 0 {
                StepText("\(model.guessedCount) table \(model.guessedCount == 1 ? "number" : "numbers") couldn't be read and \(model.guessedCount == 1 ? "is" : "are") shown in gray. Tap to check \(model.guessedCount == 1 ? "it" : "them").")
            } else {
                StepText("Compare with the diagram. Tap a table to fix it, or an empty spot to add one.")
            }
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
                        .background(RoundedRectangle(cornerRadius: 8).stroke(
                            model.guessed.contains(item.id) ? Palette.terracotta : Palette.rule, lineWidth: 1.5))
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
                if model.guessed.contains(item.id) {
                    Text("This number couldn't be read. Check it against the diagram.")
                        .font(.footnote)
                        .foregroundStyle(Palette.terracotta)
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

private struct FeetField: View {
    var label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.secondary)
            HStack {
                TextField("0", text: $text)
                    .keyboardType(.decimalPad)
                    .font(.title3.monospacedDigit())
                Text("ft").foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule, lineWidth: 1.5))
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
/// In the corners step, the four corners are handles; while one is dragged a magnifier shows it close up.
private struct DiagramCanvas: View {
    @Bindable var model: DiagramImportModel
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var dragging: Int?
    @State private var dragStart: PlanPoint?

    var body: some View {
        GeometryReader { geo in
            let image = model.displayImage
            let iw = image.size.width, ih = image.size.height
            let fit = min(geo.size.width / iw, geo.size.height / ih)
            let fitted = CGSize(width: iw * fit, height: ih * fit)
            let origin = CGPoint(x: (geo.size.width - fitted.width) / 2, y: (geo.size.height - fitted.height) / 2)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            // Image pixels to screen points and back, through zoom and pan.
            let toScreen: (PlanPoint) -> CGPoint = { p in
                let local = CGPoint(x: origin.x + p.x * fit, y: origin.y + p.y * fit)
                return CGPoint(x: center.x + (local.x - center.x) * zoom + pan.width,
                               y: center.y + (local.y - center.y) * zoom + pan.height)
            }
            let toPixel: (CGPoint) -> PlanPoint = { s in
                let q = CGPoint(x: (s.x - center.x - pan.width) / zoom + center.x, y: (s.y - center.y - pan.height) / zoom + center.y)
                return PlanPoint(x: Double((q.x - origin.x) / fit), y: Double((q.y - origin.y) / fit))
            }

            ZStack(alignment: .topLeading) {
                ZStack {
                    Image(uiImage: image)
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

                if model.step == .corners {
                    ForEach(0..<4, id: \.self) { i in
                        CornerHandle(active: dragging == i)
                            .position(toScreen(model.corners[i]))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { v in
                                    if dragging == nil { dragging = i; dragStart = model.corners[i] }
                                    guard let start = dragStart else { return }
                                    let d = PlanPoint(x: Double(v.translation.width / (fit * zoom)), y: Double(v.translation.height / (fit * zoom)))
                                    model.moveCorner(i, to: start + d)
                                }
                                .onEnded { _ in
                                    dragging = nil
                                    dragStart = nil
                                    Task { await model.tightenCorners() }
                                })
                    }
                    if let i = dragging {
                        Magnifier(image: model.source.image, at: model.corners[i])
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: toScreen(model.corners[i]).x < geo.size.width / 2 ? .trailing : .leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                handleTap(toPixel(value.location))
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in zoom = min(8, max(1, zoomBase * v.magnification)) }
                .onEnded { _ in
                    zoomBase = zoom
                    if zoom == 1 { pan = .zero; panBase = .zero }
                })
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard zoom > 1, dragging == nil else { return }
                    pan = CGSize(width: panBase.width + v.translation.width, height: panBase.height + v.translation.height)
                }
                .onEnded { _ in panBase = pan })
        }
        .accessibilityElement()
        .accessibilityLabel("Diagram. \(model.items.count) pieces marked.")
    }

    private func handleTap(_ pixel: PlanPoint) {
        let size = model.displayImage.size
        guard pixel.x >= 0, pixel.y >= 0, pixel.x <= Double(size.width), pixel.y <= Double(size.height),
              let c = model.calibration else { return }
        switch model.step {
        case .tables: model.tapTables(at: c.plan(pixel))
        case .points: model.tapPoints(at: c.plan(pixel))
        default: break
        }
    }

    private func draw(_ ctx: inout GraphicsContext, fit: CGFloat) {
        let line = 2 / zoom
        func view(_ pixel: PlanPoint) -> CGPoint { CGPoint(x: pixel.x * fit, y: pixel.y * fit) }
        func dot(_ p: CGPoint, _ color: Color, _ r: CGFloat) {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
        }

        switch model.step {
        case .corners, .scale, .reading:
            var outline = Path()
            outline.addLines(model.corners.map(view))
            outline.closeSubpath()
            ctx.stroke(outline, with: .color(Palette.Fixed.brass.swiftUI), lineWidth: line * 1.5)
            return
        default:
            break
        }

        guard let cal = model.calibration else { return }
        func px(_ plan: PlanPoint) -> CGPoint { view(cal.pixel(plan)) }

        for item in model.items {
            let selected = item.id == model.selectedID
            let guessed = model.guessed.contains(item.id)
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

            let tag = Text(guessed ? "\(item.shortLabel)?" : item.shortLabel)
                .font(.system(size: 11 / zoom, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
            let resolved = ctx.resolve(tag)
            let size = resolved.measure(in: CGSize(width: 400, height: 100))
            let c = px(f.center)
            let plate = CGRect(x: c.x - size.width / 2 - 4 / zoom, y: c.y - size.height / 2 - 2 / zoom,
                               width: size.width + 8 / zoom, height: size.height + 4 / zoom)
            let plateColor = selected ? Palette.Fixed.terracotta.swiftUI : (guessed ? Palette.Fixed.slate.swiftUI : Palette.Fixed.sage.swiftUI)
            ctx.fill(Path(roundedRect: plate, cornerRadius: 3 / zoom), with: .color(plateColor))
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

/// A corner handle: a ring with a dot at the exact point, big enough to grab.
private struct CornerHandle: View {
    var active: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.001)).frame(width: 48, height: 48)
            Circle().stroke(Palette.Fixed.brass.swiftUI, lineWidth: 3).frame(width: active ? 30 : 24, height: active ? 30 : 24)
            Circle().fill(Palette.Fixed.brass.swiftUI).frame(width: 5, height: 5)
        }
        .accessibilityLabel("Corner")
    }
}

/// Close-up of the image around a point, with crosshairs, so a corner can be placed exactly.
private struct Magnifier: View {
    var image: UIImage
    var at: PlanPoint
    let size: CGFloat = 132
    let power: CGFloat = 4

    var body: some View {
        ZStack {
            if let crop = closeUp() {
                Image(uiImage: crop)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size, height: size)
            }
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
            }
            .stroke(Palette.Fixed.terracotta.swiftUI, lineWidth: 1)
        }
        .frame(width: size, height: size)
        .background(Palette.Fixed.linen.swiftUI)
        .clipShape(Circle())
        .overlay(Circle().stroke(Palette.Fixed.ink.swiftUI, lineWidth: 2))
        .allowsHitTesting(false)
    }

    /// Just the pixels around the point, padded with white past the image's edge.
    private func closeUp() -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let side = Int(size / power)
        let rect = CGRect(x: Int(at.x) - side / 2, y: Int(at.y) - side / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            if let piece = cg.cropping(to: rect.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))) {
                let drawAt = CGRect(x: max(0, -rect.minX), y: max(0, -rect.minY), width: CGFloat(piece.width), height: CGFloat(piece.height))
                UIImage(cgImage: piece).draw(in: drawAt)
            }
        }
    }
}
