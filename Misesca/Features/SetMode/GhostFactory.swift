import RealityKit
import UIKit
import MisescaKit

/// How a ghost looks right now.
enum GhostAppearance: Equatable {
    case ghost(opacity: Float)
    case enPlace
    case off
    case missing
    case highlight
}

/// Builds true-scale ghosts for layout items. All sizes are meters.
@MainActor
enum GhostFactory {
    static let ghostOpacity: Float = 0.35
    static let tableHeight: Float = 0.76   // 30 in
    static let stageHeight: Float = 0.6
    static let barHeight: Float = 1.07     // 42 in
    static let floorPanelHeight: Float = 0.02
    static let labelGap: Float = 0.3

    static func height(for type: ItemType) -> Float {
        switch type {
        case .roundTable, .banquetTable, .ovalTable: return tableHeight
        case .stage: return stageHeight
        case .bar: return barHeight
        case .danceFloor: return floorPanelHeight
        }
    }

    static func entityName(for id: String) -> String { "item:\(id)" }

    static func itemID(from name: String) -> String? {
        name.hasPrefix("item:") ? String(name.dropFirst(5)) : nil
    }

    /// One ghost, positioned in the layout's local frame (origin at point A, x and z along plan x and y).
    static func makeGhost(for item: LayoutItem, origin: PlanPoint) -> (body: ModelEntity, label: Entity) {
        let h = height(for: item.type)
        let length = Float(Units.meters(item.size.length))
        let width = Float(Units.meters(item.size.width))

        let mesh: MeshResource
        if item.type == .roundTable {
            mesh = cylinder(radius: length / 2, height: h)
        } else if item.type == .ovalTable {
            mesh = cylinder(radius: length / 2, height: h, depthScale: width / length)
        } else {
            mesh = .generateBox(size: [length, h, width])
        }

        let body = ModelEntity(mesh: mesh, materials: [material(.ghost(opacity: ghostOpacity))])
        body.name = entityName(for: item.id)
        let local = (item.center - origin) * Units.metersPerFoot
        body.position = [Float(local.x), h / 2, Float(local.y)]
        body.orientation = simd_quatf(angle: -Float(item.rotationDegrees * .pi / 180), axis: [0, 1, 0])
        body.generateCollisionShapes(recursive: false)

        let label = makeLabel(item.shortLabel, isTable: item.type.isTable)
        label.position = [Float(local.x), h + labelGap, Float(local.y)]
        return (body, label)
    }

    /// Flat strip on the floor showing an aisle at its required width.
    static func makeAisle(_ aisle: Aisle, origin: PlanPoint) -> ModelEntity {
        let axis = aisle.to - aisle.from
        let mid = aisle.from + axis * 0.5 - origin
        let strip = ModelEntity(
            mesh: .generateBox(size: [Float(Units.meters(axis.length)), 0.004, Float(Units.meters(aisle.minWidthFt))]),
            materials: [translucent(Palette.Fixed.slate, opacity: 0.25)]
        )
        strip.name = "aisle:\(aisle.id)"
        strip.position = [Float(Units.meters(mid.x)), 0.003, Float(Units.meters(mid.y))]
        strip.orientation = simd_quatf(angle: -Float(atan2(axis.y, axis.x)), axis: [0, 1, 0])
        return strip
    }

    static func material(_ appearance: GhostAppearance) -> RealityKit.Material {
        switch appearance {
        case .ghost(let opacity):
            return translucent(Palette.Fixed.brass, opacity: opacity)
        case .enPlace:
            return SimpleMaterial(color: Palette.Fixed.sage, roughness: 0.85, isMetallic: false)
        case .off:
            return translucent(Palette.Fixed.terracotta, opacity: 0.6)
        case .missing:
            return translucent(Palette.Fixed.slate, opacity: 0.55)
        case .highlight:
            return SimpleMaterial(color: Palette.Fixed.terracotta, roughness: 0.85, isMetallic: false)
        }
    }

    static func translucent(_ color: UIColor, opacity: Float) -> RealityKit.Material {
        var m = UnlitMaterial(color: color)
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    /// Number on an ink plate, sized to read from across a ballroom.
    static func makeLabel(_ text: String, isTable: Bool) -> Entity {
        let root = Entity()
        root.name = "label"
        let fontSize: CGFloat = isTable ? 0.26 : 0.2
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.004,
                                             font: .systemFont(ofSize: fontSize, weight: .bold),
                                             alignment: .center)
        let textEntity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: Palette.Fixed.linen)])
        let b = mesh.bounds
        textEntity.position = [-b.center.x, -b.center.y, 0.006]

        let pad: Float = 0.08
        let plate = ModelEntity(
            mesh: .generatePlane(width: b.extents.x + pad * 2, height: b.extents.y + pad * 1.5, cornerRadius: 0.04),
            materials: [translucent(Palette.Fixed.ink, opacity: 0.85)]
        )
        root.addChild(plate)
        root.addChild(textEntity)
        return root
    }

    /// Marker for a tapped reference point: a brass disc with a short post.
    static func makeMarker(letter: String) -> Entity {
        let root = Entity()
        let disc = ModelEntity(mesh: cylinder(radius: 0.12, height: 0.01),
                               materials: [SimpleMaterial(color: Palette.Fixed.brass, roughness: 0.6, isMetallic: false)])
        disc.position.y = 0.005
        let post = ModelEntity(mesh: cylinder(radius: 0.012, height: 0.5),
                               materials: [SimpleMaterial(color: Palette.Fixed.brass, roughness: 0.6, isMetallic: false)])
        post.position.y = 0.25
        let label = makeLabel(letter, isTable: true)
        label.position.y = 0.7
        root.addChild(disc)
        root.addChild(post)
        root.addChild(label)
        return root
    }

    /// A closed cylinder centered on the origin. RealityKit's own cylinder needs iOS 18.
    /// `depthScale` below 1 squashes it along z into an oval table.
    static func cylinder(radius: Float, height: Float, depthScale: Float = 1, segments: Int = 48) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let half = height / 2

        func ring(y: Float, normal: (Float, Float) -> SIMD3<Float>) -> UInt32 {
            let start = UInt32(positions.count)
            for i in 0...segments {
                let a = Float(i) / Float(segments) * 2 * .pi
                let x = cos(a), z = sin(a)
                positions.append([x * radius, y, z * radius * depthScale])
                normals.append(normal(x, z))
            }
            return start
        }

        // Side wall. On an oval the wall faces out along (x, z / depthScale).
        func side(_ x: Float, _ z: Float) -> SIMD3<Float> { simd_normalize(SIMD3<Float>(x, 0, z / depthScale)) }
        let bottom = ring(y: -half, normal: side)
        let top = ring(y: half, normal: side)
        for i in 0..<UInt32(segments) {
            indices += [bottom + i, top + i, bottom + i + 1, bottom + i + 1, top + i, top + i + 1]
        }

        // Caps.
        for (y, up) in [(half, true), (-half, false)] {
            let n: SIMD3<Float> = up ? [0, 1, 0] : [0, -1, 0]
            let center = UInt32(positions.count)
            positions.append([0, y, 0])
            normals.append(n)
            let rim = ring(y: y) { _, _ in n }
            for i in 0..<UInt32(segments) {
                indices += up ? [center, rim + i + 1, rim + i] : [center, rim + i, rim + i + 1]
            }
        }

        var descriptor = MeshDescriptor(name: "cylinder")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        // A descriptor built from valid buffers always generates; fall back to a box rather than crash.
        return (try? MeshResource.generate(from: [descriptor])) ?? .generateBox(size: [radius * 2, height, radius * 2])
    }
}
