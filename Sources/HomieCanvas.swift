import AppKit
import SceneKit

/// homie's 3D canvas: one short tool call shows a ready-made scene (a math surface, a molecule, the planets, 3D bars
/// or a shape), rendered on this Mac with SceneKit. The model only picks the kind and a few words, so it shows up in
/// about the time of a normal answer instead of the model writing out geometry. Drag to spin, scroll to zoom.
@MainActor final class HomieCanvas: NSObject, NSWindowDelegate {
    static let shared = HomieCanvas()

    nonisolated static let tool: [String: Any] = [
        "type": "function", "name": "show_3d",
        "description": "Show a 3D picture in homie's canvas window. kind surface: subject is a math expression in x and y, like sin(x)*cos(y). kind shape: subject is a shape (sphere, cube, torus, cone, cylinder, pyramid, helix, dna). kind molecule: subject is a molecule (water, carbon dioxide, methane, ammonia, benzene, ethanol, oxygen). kind planets: the solar system. kind bars: subject is numbers like 3,5,2 and labels names them. kind close: close the canvas.",
        "parameters": ["type": "object", "properties": [
            "kind": ["type": "string", "enum": ["surface", "shape", "molecule", "planets", "bars", "close"]],
            "subject": ["type": "string"], "labels": ["type": "string"], "title": ["type": "string"]
        ], "required": ["kind", "subject", "labels", "title"], "additionalProperties": false], "strict": true
    ]
    nonisolated static func owns(_ name: String) -> Bool { name == "show_3d" }

    private var panel: NSPanel?
    private var view: SCNView?
    private var caption: NSTextField?

    /// Runs the tool. Never throws; a bad subject comes back as an error the model can explain.
    func show(_ args: [String: Any]) -> [String: Any] {
        let kind = (args["kind"] as? String ?? "").lowercased()
        let subject = (args["subject"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = (args["labels"] as? String ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if kind == "close" { close(); return ["status": "closed"] }
        let started = ProcessInfo.processInfo.systemUptime
        let built: (SCNNode, String)?
        switch kind {
        case "surface": built = Self.surface(subject)
        case "shape": built = Self.shape(subject)
        case "molecule": built = Self.molecule(subject)
        case "planets": built = (Self.planets(), "The solar system (sizes and distances not to scale)")
        case "bars": built = Self.bars(subject, labels: labels)
        default: built = nil
        }
        guard let (node, name) = built else {
            Diagnostics.shared.record("canvas_3d", category: "unsupported")
            return ["status": "error", "message": "I can't draw that one in 3D yet. Surfaces need an expression in x and y; shapes, molecules, planets and bars are the other kinds."]
        }
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        present(node, title: title)
        Diagnostics.shared.record("canvas_3d", category: kind, number: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        return ["status": "shown", "showing": title]
    }

    func close() { panel?.orderOut(nil); view?.scene = nil }
    func windowWillClose(_ notification: Notification) { view?.scene = nil }

    // MARK: Window

    private func present(_ content: SCNNode, title: String) {
        let panel = self.panel ?? makePanel()
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 42
        camera.position = SCNVector3(0, 2.4, 6.2); camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional; key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.9, 0.6, 0); scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .ambient; fill.light?.intensity = 380
        scene.rootNode.addChildNode(fill)
        // Fit any scene to the same size: a water molecule and the solar system both fill the window.
        let (center, radius) = content.boundingSphere
        if radius > 0 {
            let fit = CGFloat(2.3 / Double(radius))
            let s = content.scale
            content.scale = SCNVector3(CGFloat(s.x) * fit, CGFloat(s.y) * fit, CGFloat(s.z) * fit)
            content.position = SCNVector3(-CGFloat(center.x) * fit, -CGFloat(center.y) * fit, -CGFloat(center.z) * fit)
        }
        let spin = SCNNode(); spin.addChildNode(content)
        spin.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24)))
        scene.rootNode.addChildNode(spin)
        view?.scene = scene
        view?.pointOfView = camera
        caption?.stringValue = title
        panel.title = title
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true; panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 320)
        panel.delegate = self
        let view = SCNView(frame: panel.contentLayoutRect)
        view.autoresizingMask = [.width, .height]
        view.allowsCameraControl = true; view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        panel.contentView = view
        let caption = NSTextField(labelWithString: "")
        caption.font = .systemFont(ofSize: 15, weight: .semibold); caption.textColor = NSColor(white: 1, alpha: 0.85)
        caption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     caption.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
                                     caption.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16)])
        self.panel = panel; self.view = view; self.caption = caption
        return panel
    }

    /// Offscreen render for tests and docs: the same scene the window would show, as a PNG.
    func snapshot(_ args: [String: Any], size: CGSize = CGSize(width: 760, height: 540)) -> NSImage? {
        guard (show(args)["status"] as? String) == "shown", let scene = view?.scene else { return nil }
        panel?.orderOut(nil)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = view?.pointOfView
        return renderer.snapshot(atTime: 1.5, with: size, antialiasingMode: .multisampling4X)
    }

    // MARK: Scenes

    nonisolated static func color(_ hex: UInt32) -> NSColor {
        NSColor(calibratedRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    private static func material(_ color: NSColor, shiny: Bool = true) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .blinn
        m.specular.contents = NSColor(white: shiny ? 0.6 : 0.1, alpha: 1); m.shininess = 0.4
        return m
    }

    /// z = f(x, y) over [-4, 4]², scaled to fit, colored by height.
    static func surface(_ raw: String) -> (SCNNode, String)? {
        guard let expression = MathExpression(raw) else { return nil }
        let n = 96, range = 4.0
        var heights = [Double](repeating: 0, count: (n + 1) * (n + 1))
        var peak = 0.0
        for j in 0...n { for i in 0...n {
            let x = -range + 2 * range * Double(i) / Double(n), y = -range + 2 * range * Double(j) / Double(n)
            var z = expression.value(x: x, y: y)
            if !z.isFinite { z = 0 }
            heights[j * (n + 1) + i] = z; peak = max(peak, abs(z))
        } }
        guard peak > 0 else { return nil }
        let scale = 1.3 / peak
        var vertices: [SCNVector3] = [], colors: [Float] = [], indices: [Int32] = []
        let low = color(0x3b82f6), mid = color(0x9b5de5), high = color(0xe5577f)
        for j in 0...n { for i in 0...n {
            let h = heights[j * (n + 1) + i] * scale
            vertices.append(SCNVector3(-2.2 + 4.4 * Double(i) / Double(n), h, -2.2 + 4.4 * Double(j) / Double(n)))
            let t = CGFloat((h / 1.3 + 1) / 2)
            let c = (t < 0.5 ? low.blended(withFraction: t * 2, of: mid) : mid.blended(withFraction: (t - 0.5) * 2, of: high)) ?? mid
            colors += [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1]
        } }
        for j in 0..<n { for i in 0..<n {
            let a = Int32(j * (n + 1) + i), b = a + 1, c = a + Int32(n + 1), d = c + 1
            indices += [a, c, b, b, c, d]
        } }
        var normals = [SCNVector3](repeating: SCNVector3(0, 1, 0), count: vertices.count)
        for j in 0...n { for i in 0...n {
            let l = vertices[j * (n + 1) + max(0, i - 1)], r = vertices[j * (n + 1) + min(n, i + 1)]
            let u = vertices[max(0, j - 1) * (n + 1) + i], d = vertices[min(n, j + 1) * (n + 1) + i]
            let dx = SCNVector3(r.x - l.x, r.y - l.y, r.z - l.z), dz = SCNVector3(d.x - u.x, d.y - u.y, d.z - u.z)
            var normal = SCNVector3(dz.y * dx.z - dz.z * dx.y, dz.z * dx.x - dz.x * dx.z, dz.x * dx.y - dz.y * dx.x)
            let length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            if length > 0 { normal = SCNVector3(normal.x / length, normal.y / length, normal.z / length) }
            normals[j * (n + 1) + i] = normal
        } }
        let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: vertices.count, usesFloatComponents: true,
                                            componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals), colorSource],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let m = SCNMaterial(); m.lightingModel = .blinn; m.isDoubleSided = true; m.diffuse.contents = NSColor.white
        m.specular.contents = NSColor(white: 0.35, alpha: 1)
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        return (node, "z = " + expression.text)
    }

    /// "a DNA helix " → "dna helix": lowercased, trimmed, without a leading article or "3d".
    nonisolated static func bare(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["a ", "an ", "the ", "3d "] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func shape(_ raw: String) -> (SCNNode, String)? {
        let name = Self.bare(raw)
        let pink = material(color(0xe5577f)), blue = material(color(0x3b82f6)), green = material(color(0x2ea44f))
        func node(_ g: SCNGeometry, _ m: SCNMaterial) -> SCNNode { g.materials = [m]; return SCNNode(geometry: g) }
        switch name {
        case "sphere", "ball": return (node(SCNSphere(radius: 1.3), blue), "A sphere")
        case "cube", "box": return (node(SCNBox(width: 1.9, height: 1.9, length: 1.9, chamferRadius: 0.08), pink), "A cube")
        case "torus", "donut", "doughnut", "ring": return (node(SCNTorus(ringRadius: 1.2, pipeRadius: 0.45), pink), "A torus")
        case "cone": return (node(SCNCone(topRadius: 0, bottomRadius: 1.2, height: 2.4), green), "A cone")
        case "cylinder": return (node(SCNCylinder(radius: 1, height: 2.2), blue), "A cylinder")
        case "pyramid": return (node(SCNPyramid(width: 2.2, height: 2, length: 2.2), material(color(0xf4b942))), "A pyramid")
        case "capsule", "pill": return (node(SCNCapsule(capRadius: 0.6, height: 2.6), green), "A capsule")
        case "helix", "spiral", "spring": return (helix(strands: 1), "A helix")
        case "dna", "dna helix", "double helix": return (helix(strands: 2), "DNA double helix")
        default: return nil
        }
    }

    private static func helix(strands: Int) -> SCNNode {
        let root = SCNNode()
        let colors = [color(0x3b82f6), color(0xe5577f)]
        let rungColors = [color(0x2ea44f), color(0xf4b942), color(0x9b5de5), color(0xff8c42)]
        let steps = 60
        for s in 0..<strands {
            let ball = SCNSphere(radius: 0.13); ball.materials = [material(colors[s])]
            for k in 0...steps {
                let a = Double(k) / Double(steps) * .pi * 6 + Double(s) * .pi
                let p = SCNNode(geometry: ball); p.position = SCNVector3(cos(a) * 1.1, -2.2 + 4.4 * Double(k) / Double(steps), sin(a) * 1.1)
                root.addChildNode(p)
            }
        }
        if strands == 2 {
            for k in stride(from: 0, through: steps, by: 3) {
                let a = Double(k) / Double(steps) * .pi * 6, y = -2.2 + 4.4 * Double(k) / Double(steps)
                root.addChildNode(bond(SCNVector3(cos(a) * 1.1, y, sin(a) * 1.1), SCNVector3(-cos(a) * 1.1, y, -sin(a) * 1.1),
                                       radius: 0.05, color: rungColors[(k / 3) % rungColors.count]))
            }
        }
        return root
    }

    private static func bond(_ a: SCNVector3, _ b: SCNVector3, radius: CGFloat, color: NSColor) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let length = sqrt(dx * dx + dy * dy + dz * dz)
        let cylinder = SCNCylinder(radius: radius, height: length); cylinder.materials = [material(color, shiny: false)]
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        node.look(at: b, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return node
    }

    /// Ball-and-stick models with standard atom colors (H white, C gray, N blue, O red). Coordinates in ångström-ish units.
    static func molecule(_ raw: String) -> (SCNNode, String)? {
        let key = Self.bare(raw.lowercased().replacingOccurrences(of: "molecule", with: ""))
        typealias Atom = (String, Double, Double, Double)
        let t = 0.63   // tetrahedral offset for C–H ~1.09
        let atoms: [Atom], bonds: [(Int, Int)], name: String
        switch key {
        case "water", "h2o":
            atoms = [("O", 0, 0, 0), ("H", 0.76, -0.59, 0), ("H", -0.76, -0.59, 0)]; bonds = [(0, 1), (0, 2)]; name = "Water (H₂O)"
        case "carbon dioxide", "co2":
            atoms = [("C", 0, 0, 0), ("O", 1.16, 0, 0), ("O", -1.16, 0, 0)]; bonds = [(0, 1), (0, 2)]; name = "Carbon dioxide (CO₂)"
        case "oxygen", "o2":
            atoms = [("O", 0.6, 0, 0), ("O", -0.6, 0, 0)]; bonds = [(0, 1)]; name = "Oxygen (O₂)"
        case "methane", "ch4":
            atoms = [("C", 0, 0, 0), ("H", t, t, t), ("H", -t, -t, t), ("H", -t, t, -t), ("H", t, -t, -t)]
            bonds = [(0, 1), (0, 2), (0, 3), (0, 4)]; name = "Methane (CH₄)"
        case "ammonia", "nh3":
            atoms = [("N", 0, 0.12, 0), ("H", 0.94, -0.27, 0), ("H", -0.47, -0.27, 0.81), ("H", -0.47, -0.27, -0.81)]
            bonds = [(0, 1), (0, 2), (0, 3)]; name = "Ammonia (NH₃)"
        case "benzene", "c6h6":
            var list: [Atom] = []; var links: [(Int, Int)] = []
            for k in 0..<6 { let a = Double(k) * .pi / 3; list.append(("C", 1.39 * cos(a), 0, 1.39 * sin(a))) }
            for k in 0..<6 { let a = Double(k) * .pi / 3; list.append(("H", 2.48 * cos(a), 0, 2.48 * sin(a))); links += [(k, (k + 1) % 6), (k, k + 6)] }
            atoms = list; bonds = links; name = "Benzene (C₆H₆)"
        case "ethanol", "alcohol", "c2h5oh":
            atoms = [("C", -0.75, 0, 0), ("C", 0.75, 0, 0), ("O", 1.25, 1.3, 0), ("H", 2.2, 1.3, 0),
                     ("H", -1.15, -1.0, 0.1), ("H", -1.15, 0.5, 0.88), ("H", -1.15, 0.5, -0.88), ("H", 1.15, -0.5, 0.88), ("H", 1.15, -0.5, -0.88)]
            bonds = [(0, 1), (1, 2), (2, 3), (0, 4), (0, 5), (0, 6), (1, 7), (1, 8)]; name = "Ethanol (C₂H₅OH)"
        default: return nil
        }
        let palette: [String: (UInt32, CGFloat)] = ["H": (0xf2f2f2, 0.28), "C": (0x5c5c66, 0.42), "N": (0x3b6ff5, 0.42), "O": (0xe53935, 0.44)]
        let root = SCNNode()
        let positions = atoms.map { SCNVector3($0.1, $0.2, $0.3) }
        for (a, b) in bonds { root.addChildNode(bond(positions[a], positions[b], radius: 0.09, color: NSColor(white: 0.75, alpha: 1))) }
        for (index, atom) in atoms.enumerated() {
            let style = palette[atom.0] ?? (0xcccccc, 0.4)
            let sphere = SCNSphere(radius: style.1); sphere.segmentCount = 36; sphere.materials = [material(color(style.0))]
            let node = SCNNode(geometry: sphere); node.position = positions[index]; root.addChildNode(node)
        }
        root.scale = SCNVector3(1.15, 1.15, 1.15)
        return (root, name)
    }

    static func planets() -> SCNNode {
        let root = SCNNode()
        let sun = SCNSphere(radius: 0.55); let glow = SCNMaterial(); glow.diffuse.contents = color(0xffb703); glow.emission.contents = color(0xffb703)
        sun.materials = [glow]; root.addChildNode(SCNNode(geometry: sun))
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .omni; light.light?.intensity = 600; root.addChildNode(light)
        let bodies: [(UInt32, CGFloat, Double, Double)] = [(0x9e9e9e, 0.06, 0.85, 4), (0xe9c46a, 0.1, 1.1, 7), (0x3b82f6, 0.11, 1.4, 10),
                                                          (0xe76f51, 0.08, 1.7, 14), (0xd4a373, 0.25, 2.15, 22), (0xe9d8a6, 0.21, 2.65, 30),
                                                          (0x90e0ef, 0.15, 3.05, 40), (0x4361ee, 0.15, 3.4, 52)]
        for (index, body) in bodies.enumerated() {
            let orbit = SCNNode(); orbit.eulerAngles.y = CGFloat(index) * 0.9
            let planet = SCNSphere(radius: body.1); planet.materials = [material(color(body.0), shiny: false)]
            let p = SCNNode(geometry: planet); p.position = SCNVector3(body.2, 0, 0); orbit.addChildNode(p)
            if index == 5 { let ring = SCNTube(innerRadius: 0.28, outerRadius: 0.42, height: 0.01); ring.materials = [material(color(0xd4c19c), shiny: false)]
                let r = SCNNode(geometry: ring); r.eulerAngles.x = 0.4; p.addChildNode(r) }
            let path = SCNTorus(ringRadius: body.2, pipeRadius: 0.004); path.materials = [material(NSColor(white: 1, alpha: 0.18), shiny: false)]
            root.addChildNode(SCNNode(geometry: path))
            orbit.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: body.3)))
            root.addChildNode(orbit)
        }
        root.scale = SCNVector3(0.75, 0.75, 0.75)
        return root
    }

    static func bars(_ raw: String, labels: [String]) -> (SCNNode, String)? {
        let values = raw.split(whereSeparator: { ",; ".contains($0) }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.count <= 24, let top = values.map(abs).max(), top > 0 else { return nil }
        let root = SCNNode(), width = 4.4 / Double(values.count)
        let palette: [UInt32] = [0xe5577f, 0x3b82f6, 0x2ea44f, 0xf4b942, 0x9b5de5, 0xff8c42]
        for (index, value) in values.enumerated() {
            let h = max(0.02, abs(value) / top * 2.4)
            let box = SCNBox(width: width * 0.7, height: h, length: width * 0.7, chamferRadius: 0.03)
            box.materials = [material(color(palette[index % palette.count]))]
            let node = SCNNode(geometry: box)
            let x = -2.2 + width * (Double(index) + 0.5)
            node.position = SCNVector3(x, value < 0 ? -h / 2 : h / 2 - 1.2, 0)
            root.addChildNode(node)
            let text = SCNText(string: index < labels.count && !labels[index].isEmpty ? labels[index] : (value.rounded() == value ? String(Int(value)) : String(value)), extrusionDepth: 0.02)
            text.font = .systemFont(ofSize: 0.28, weight: .semibold); text.flatness = 0.01; text.materials = [material(.white, shiny: false)]
            let label = SCNNode(geometry: text)
            let (minB, maxB) = label.boundingBox
            label.position = SCNVector3(x - (maxB.x - minB.x) / 2, -1.6, width * 0.4)
            root.addChildNode(label)
        }
        return (root, values.count == 1 ? "One bar" : "\(values.count) bars")
    }
}

/// A tiny math parser for surfaces: + - * / ^, parentheses, x, y, r (distance from center), pi, e,
/// sin cos tan sqrt abs exp log, and implicit multiplication ("2x", "x y", "2(x+1)").
struct MathExpression {
    let text: String
    private indirect enum Node { case number(Double), x, y, r, unary(String, Node), binary(Character, Node, Node) }
    private let root: Node

    init?(_ raw: String) {
        var s = raw.lowercased()
        for prefix in ["z=", "z =", "f(x,y)=", "f(x, y)=", "f(x,y) =", "f(x, y) =", "y="] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        s = s.replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3").replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "π", with: "pi").replacingOccurrences(of: "**", with: "^").replacingOccurrences(of: "−", with: "-")
        var parser = Parser(Array(s))
        guard let node = parser.expression(), parser.atEnd else { return nil }
        root = node; text = s.trimmingCharacters(in: .whitespaces)
    }

    func value(x: Double, y: Double) -> Double { Self.eval(root, x, y) }

    private static func eval(_ n: Node, _ x: Double, _ y: Double) -> Double {
        switch n {
        case .number(let v): return v
        case .x: return x
        case .y: return y
        case .r: return (x * x + y * y).squareRoot()
        case .unary(let f, let a):
            let v = eval(a, x, y)
            switch f { case "-": return -v; case "sin": return sin(v); case "cos": return cos(v); case "tan": return tan(v)
            case "sqrt": return v.squareRoot(); case "abs": return abs(v); case "exp": return exp(v); case "log", "ln": return log(v)
            default: return .nan }
        case .binary(let op, let a, let b):
            let l = eval(a, x, y), r = eval(b, x, y)
            switch op { case "+": return l + r; case "-": return l - r; case "*": return l * r; case "/": return l / r; default: return pow(l, r) }
        }
    }

    private struct Parser {
        let c: [Character]; var i = 0
        init(_ c: [Character]) { self.c = c }
        var atEnd: Bool { mutating get { skip(); return i >= c.count } }
        mutating func skip() { while i < c.count, c[i].isWhitespace { i += 1 } }
        mutating func peek() -> Character? { skip(); return i < c.count ? c[i] : nil }
        mutating func expression() -> Node? {
            guard var left = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" { i += 1; guard let right = term() else { return nil }; left = .binary(op, left, right) }
            return left
        }
        mutating func term() -> Node? {
            guard var left = power() else { return nil }
            while true {
                if let op = peek(), op == "*" || op == "/" { i += 1; guard let right = power() else { return nil }; left = .binary(op, left, right) }
                else if let next = peek(), next.isLetter || next == "(" || next.isNumber { guard let right = power() else { return nil }; left = .binary("*", left, right) }
                else { return left }
            }
        }
        mutating func power() -> Node? {
            if peek() == "-" { i += 1; guard let inner = power() else { return nil }; return .unary("-", inner) }
            guard let base = atom() else { return nil }
            if peek() == "^" { i += 1; guard let exponent = power() else { return nil }; return .binary("^", base, exponent) }
            return base
        }
        mutating func atom() -> Node? {
            guard let ch = peek() else { return nil }
            if ch == "(" { i += 1; guard let inner = expression(), peek() == ")" else { return nil }; i += 1; return inner }
            if ch.isNumber || ch == "." {
                var j = i; while j < c.count, c[j].isNumber || c[j] == "." { j += 1 }
                guard let v = Double(String(c[i..<j])) else { return nil }; i = j; return .number(v)
            }
            if ch.isLetter {
                var j = i; while j < c.count, c[j].isLetter { j += 1 }
                let word = String(c[i..<j])
                for function in ["sqrt", "sin", "cos", "tan", "abs", "exp", "log", "ln"] where word.hasPrefix(function) {
                    i += function.count
                    if word == function { guard let arg = power() else { return nil }; return .unary(function, arg) }
                    // "sinx": function applied to the variable glued on
                    guard let arg = power() else { return nil }; return .unary(function, arg)
                }
                if word.hasPrefix("pi") { i += 2; return .number(.pi) }
                switch ch { case "x": i += 1; return .x; case "y": i += 1; return .y; case "r": i += 1; return .r
                case "e": i += 1; return .number(M_E); default: return nil }
            }
            return nil
        }
    }
}
