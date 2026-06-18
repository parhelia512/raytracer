import Foundation

struct BenchmarkOptions {
    var width: Int = 500
    var height: Int = 500
    var output: String = "swift-ray.bmp"

    static func parse(_ args: [String]) -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var i = 1

        while i < args.count {
            let name = args[i]
            let value = i + 1 < args.count ? args[i + 1] : ""

            if name == "--width", let width = Int(value) {
                options.width = width
                i += 2
            } else if name == "--height", let height = Int(value) {
                options.height = height
                i += 2
            } else if name == "--output", !value.isEmpty {
                options.output = value
                i += 2
            } else {
                i += 1
            }
        }

        return options
    }
}

struct Vector {
    var x: Double
    var y: Double
    var z: Double

    func dot(_ v: Vector) -> Double {
        return x * v.x + y * v.y + z * v.z
    }

    func length() -> Double {
        return (x * x + y * y + z * z).squareRoot()
    }

    static func -(a: Vector, b: Vector) -> Vector {
        return Vector(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }

    static func +(a: Vector, b: Vector) -> Vector {
        return Vector(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }

    static func *(k: Double, v: Vector) -> Vector {
        return Vector(x: k * v.x, y: k * v.y, z: k * v.z)
    }

    func norm() -> Vector {
        let length = self.length()
        let div = length == 0 ? Double.infinity : 1.0 / length
        return div * self
    }

    func cross(_ v: Vector) -> Vector {
        return Vector(
            x: y * v.z - z * v.y,
            y: z * v.x - x * v.z,
            z: x * v.y - y * v.x
        )
    }
}

struct RGBColor {
    var b: UInt8
    var g: UInt8
    var r: UInt8
    var a: UInt8
}

extension Double {
    func toColorComponent() -> UInt8 {
        if self > 1.0 { return 255 }
        if self < 0.0 { return 0 }
        return UInt8(self * 255.0)
    }
}

struct Color {
    var r: Double
    var g: Double
    var b: Double

    static func *(k: Double, v: Color) -> Color {
        return Color(r: k * v.r, g: k * v.g, b: k * v.b)
    }

    static func +(a: Color, b: Color) -> Color {
        return Color(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b)
    }

    static func *(a: Color, b: Color) -> Color {
        return Color(r: a.r * b.r, g: a.g * b.g, b: a.b * b.b)
    }

    func toDrawingColor() -> RGBColor {
        return RGBColor(
            b: self.b.toColorComponent(),
            g: self.g.toColorComponent(),
            r: self.r.toColorComponent(),
            a: 255
        )
    }
}

let white = Color(r: 1.0, g: 1.0, b: 1.0)
let grey = Color(r: 0.5, g: 0.5, b: 0.5)
let black = Color(r: 0.0, g: 0.0, b: 0.0)
let background = black
let defaultColor = black

struct Camera {
    var forward: Vector
    var right: Vector
    var up: Vector
    var pos: Vector

    init(pos: Vector, lookAt: Vector) {
        let down = Vector(x: 0.0, y: -1.0, z: 0.0)
        self.pos = pos
        self.forward = (lookAt - pos).norm()
        self.right = 1.5 * self.forward.cross(down).norm()
        self.up = 1.5 * self.forward.cross(self.right).norm()
    }

    func getPoint(x: Int, y: Int, width: Int, height: Int) -> Vector {
        let xf = Double(x)
        let yf = Double(y)
        let wf = Double(width)
        let hf = Double(height)
        let recenterX = (xf - (wf / 2.0)) / 2.0 / wf
        let recenterY = -(yf - (hf / 2.0)) / 2.0 / hf
        return (self.forward + (recenterX * self.right) + (recenterY * self.up)).norm()
    }
}

struct Ray {
    var start: Vector
    var dir: Vector
}

struct Intersection {
    var thing: Thing
    var ray: Ray
    var dist: Double
}

struct SurfaceProperties {
    var diffuse: Color
    var specular: Color
    var reflect: Double
    var roughness: Double
}

protocol Surface {
    func properties(pos: Vector) -> SurfaceProperties
}

protocol Thing {
    var surface: Surface { get }
    func intersect(ray: Ray) -> Intersection?
    func normal(pos: Vector) -> Vector
}

struct Light {
    var pos: Vector
    var color: Color
}

class Sphere: Thing {
    let radius2: Double
    let center: Vector
    let surface: Surface

    init(center: Vector, radius: Double, surface: Surface) {
        self.radius2 = radius * radius
        self.surface = surface
        self.center = center
    }

    func intersect(ray: Ray) -> Intersection? {
        let eo = center - ray.start
        let v = eo.dot(ray.dir)

        if v >= 0 {
            let disc = radius2 - (eo.dot(eo) - v * v)
            if disc >= 0 {
                let dist = v - disc.squareRoot()
                return dist == 0.0 ? nil : Intersection(thing: self, ray: ray, dist: dist)
            }
        }

        return nil
    }

    func normal(pos: Vector) -> Vector {
        return (pos - center).norm()
    }
}

class Plane: Thing {
    let normalValue: Vector
    let offset: Double
    let surface: Surface

    init(normal: Vector, offset: Double, surface: Surface) {
        self.normalValue = normal
        self.offset = offset
        self.surface = surface
    }

    func intersect(ray: Ray) -> Intersection? {
        let denom = normalValue.dot(ray.dir)
        if denom > 0 {
            return nil
        }

        let dist = (normalValue.dot(ray.start) + offset) / (-denom)
        return Intersection(thing: self, ray: ray, dist: dist)
    }

    func normal(pos: Vector) -> Vector {
        return normalValue
    }
}

class ShinySurface: Surface {
    func properties(pos: Vector) -> SurfaceProperties {
        return SurfaceProperties(diffuse: white, specular: grey, reflect: 0.7, roughness: 250.0)
    }
}

class CheckerboardSurface: Surface {
    func properties(pos: Vector) -> SurfaceProperties {
        let condition = (Int(floor(pos.z)) + Int(floor(pos.x))) % 2 != 0
        return SurfaceProperties(
            diffuse: condition ? white : black,
            specular: white,
            reflect: condition ? 0.1 : 0.7,
            roughness: 250.0
        )
    }
}

class Scene {
    let camera: Camera
    let lights: [Light]
    let things: [Thing]

    init() {
        let shiny = ShinySurface()
        let checkerboard = CheckerboardSurface()

        self.camera = Camera(pos: Vector(x: 3.0, y: 2.0, z: 4.0), lookAt: Vector(x: -1.0, y: 0.5, z: 0.0))
        self.things = [
            Plane(normal: Vector(x: 0.0, y: 1.0, z: 0.0), offset: 0.0, surface: checkerboard),
            Sphere(center: Vector(x: 0.0, y: 1.0, z: -0.25), radius: 1.0, surface: shiny),
            Sphere(center: Vector(x: -1.0, y: 0.5, z: 1.5), radius: 0.5, surface: shiny)
        ]
        self.lights = [
            Light(pos: Vector(x: -2.0, y: 2.5, z: 0.0), color: Color(r: 0.49, g: 0.07, b: 0.07)),
            Light(pos: Vector(x: 1.5, y: 2.5, z: 1.5), color: Color(r: 0.07, g: 0.07, b: 0.49)),
            Light(pos: Vector(x: 1.5, y: 2.5, z: -1.5), color: Color(r: 0.07, g: 0.49, b: 0.071)),
            Light(pos: Vector(x: 0.0, y: 3.5, z: 0.0), color: Color(r: 0.21, g: 0.21, b: 0.35))
        ]
    }
}

let maxDepth = 5

func intersections(scene: Scene, ray: Ray) -> Intersection? {
    var closest = Double.infinity
    var closestIntersection: Intersection? = nil

    for item in scene.things {
        if let intersection = item.intersect(ray: ray), intersection.dist < closest {
            closestIntersection = intersection
            closest = intersection.dist
        }
    }

    return closestIntersection
}

func traceRay(scene: Scene, ray: Ray, depth: Int) -> Color {
    guard let isect = intersections(scene: scene, ray: ray) else {
        return background
    }

    return shade(scene: scene, isect: isect, depth: depth)
}

func shade(scene: Scene, isect: Intersection, depth: Int) -> Color {
    let d = isect.ray.dir
    let pos = (isect.dist * d) + isect.ray.start
    let normal = isect.thing.normal(pos: pos)
    let reflectDir = d - (2.0 * normal.dot(d) * normal)
    let surface = isect.thing.surface.properties(pos: pos)
    let naturalColor = background + getNaturalColor(scene: scene, thing: isect.thing, pos: pos, normal: normal, reflectDir: reflectDir)
    let reflectedColor = depth >= maxDepth ? grey : surface.reflect * traceRay(scene: scene, ray: Ray(start: pos, dir: reflectDir), depth: depth + 1)
    return naturalColor + reflectedColor
}

func getNaturalColor(scene: Scene, thing: Thing, pos: Vector, normal: Vector, reflectDir: Vector) -> Color {
    var result = defaultColor
    let surface = thing.surface.properties(pos: pos)

    for light in scene.lights {
        let ldis = light.pos - pos
        let livec = ldis.norm()
        let neatIsect = intersections(scene: scene, ray: Ray(start: pos, dir: livec))
        let isInShadow = neatIsect != nil && neatIsect!.dist <= ldis.length()

        if !isInShadow {
            let illum = livec.dot(normal)
            let lcolor = illum > 0 ? illum * light.color : defaultColor

            let specular = livec.dot(reflectDir.norm())
            let scolor = specular > 0 ? pow(specular, surface.roughness) * light.color : defaultColor

            result = result + (surface.diffuse * lcolor) + (surface.specular * scolor)
        }
    }

    return result
}

class Image {
    var data: [RGBColor]
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.data = Array(repeating: RGBColor(b: 0, g: 0, r: 0, a: 0), count: width * height)
    }

    func setColor(x: Int, y: Int, color: RGBColor) {
        data[y * width + x] = color
    }

    func save(fileName: String) throws {
        var bytes = [UInt8]()
        bytes.reserveCapacity(54 + data.count * 4)

        let fileHeaderSize: UInt32 = 14
        let infoHeaderSize: UInt32 = 40
        let offBits = fileHeaderSize + infoHeaderSize
        let imageSize = UInt32(width * height * 4)

        appendUInt16(0x4D42, to: &bytes)
        appendUInt32(offBits + imageSize, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt32(offBits, to: &bytes)

        appendUInt32(infoHeaderSize, to: &bytes)
        appendInt32(Int32(width), to: &bytes)
        appendInt32(Int32(-height), to: &bytes)
        appendUInt16(1, to: &bytes)
        appendUInt16(32, to: &bytes)
        appendUInt32(0, to: &bytes)
        appendUInt32(imageSize, to: &bytes)
        appendInt32(0, to: &bytes)
        appendInt32(0, to: &bytes)
        appendUInt32(0, to: &bytes)
        appendUInt32(0, to: &bytes)

        for color in data {
            bytes.append(color.b)
            bytes.append(color.g)
            bytes.append(color.r)
            bytes.append(color.a)
        }

        try Data(bytes).write(to: URL(fileURLWithPath: fileName))
    }
}

func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0x00ff))
    bytes.append(UInt8((value >> 8) & 0x00ff))
}

func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0x000000ff))
    bytes.append(UInt8((value >> 8) & 0x000000ff))
    bytes.append(UInt8((value >> 16) & 0x000000ff))
    bytes.append(UInt8((value >> 24) & 0x000000ff))
}

func appendInt32(_ value: Int32, to bytes: inout [UInt8]) {
    appendUInt32(UInt32(bitPattern: value), to: &bytes)
}

func render(scene: Scene, image: Image) {
    for y in 0..<image.height {
        for x in 0..<image.width {
            let pt = scene.camera.getPoint(x: x, y: y, width: image.width, height: image.height)
            let ray = Ray(start: scene.camera.pos, dir: pt)
            let color = traceRay(scene: scene, ray: ray, depth: 0)
            image.setColor(x: x, y: y, color: color.toDrawingColor())
        }
    }
}

func main() throws {
    let options = BenchmarkOptions.parse(CommandLine.arguments)
    let image = Image(width: options.width, height: options.height)
    let scene = Scene()

    let start = Date()
    render(scene: scene, image: image)
    let elapsedMs = Date().timeIntervalSince(start) * 1000.0

    try image.save(fileName: options.output)
    print(String(format: "render time_ms=%.4f width=%d height=%d output=\"%@\"", elapsedMs, options.width, options.height, options.output))
}

try main()
