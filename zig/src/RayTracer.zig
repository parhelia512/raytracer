const std = @import("std");
const Allocator = std.mem.Allocator;

const BenchmarkOptions = struct {
    width: i32 = 500,
    height: i32 = 500,
    output: []const u8 = "zig-ray.bmp",
};

const RGBColor = struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};

const WORD = u16;
const DWORD = u32;
const LONG = i32;

const BITMAPINFOHEADER = struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

const BITMAPFILEHEADER = packed struct {
    bfType: WORD,
    bfSize: DWORD,
    bfReserved1: WORD,
    bfReserved2: WORD,
    bfOffBits: DWORD,
};

const Vector = struct {
    x: f64,
    y: f64,
    z: f64,

    pub fn init(x: f64, y: f64, z: f64) Vector {
        return Vector{ .x = x, .y = y, .z = z };
    }

    pub fn scale(self: Vector, k: f64) Vector {
        return Vector.init(k * self.x, k * self.y, k * self.z);
    }

    pub fn add(self: Vector, v: Vector) Vector {
        return Vector.init(self.x + v.x, self.y + v.y, self.z + v.z);
    }

    pub fn sub(self: Vector, v: Vector) Vector {
        return Vector.init(self.x - v.x, self.y - v.y, self.z - v.z);
    }

    pub fn dot(self: Vector, v: Vector) f64 {
        return self.x * v.x + self.y * v.y + self.z * v.z;
    }

    pub fn mag(self: Vector) f64 {
        return std.math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn norm(self: Vector) Vector {
        const magnitude = self.mag();
        var div: f64 = 0.0;
        if (magnitude == 0.0) {
            div = FarAway;
        } else {
            div = 1.0 / magnitude;
        }
        return self.scale(div);
    }

    pub fn cross(self: Vector, v: Vector) Vector {
        return Vector.init(self.y * v.z - self.z * v.y, self.z * v.x - self.x * v.z, self.x * v.y - self.y * v.x);
    }
};

const Color = struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,

    pub fn init(r: f64, g: f64, b: f64) Color {
        return Color{ .r = r, .g = g, .b = b };
    }

    pub fn scale(self: Color, k: f64) Color {
        return Color.init(k * self.r, k * self.g, k * self.b);
    }

    pub fn add(self: Color, color: Color) Color {
        return Color.init(self.r + color.r, self.g + color.g, self.b + color.b);
    }

    pub fn mul(self: Color, color: Color) Color {
        return Color.init(self.r * color.r, self.g * color.g, self.b * color.b);
    }

    pub fn toDrawingColor(self: Color) RGBColor {
        return RGBColor{
            .r = clamp(self.r),
            .g = clamp(self.g),
            .b = clamp(self.b),
            .a = 255,
        };
    }

    pub fn clamp(c: f64) u8 {
        if (c < 0.0) return 1;
        if (c > 1.0) return 255;
        return @as(u8, @intFromFloat(c * 255.0));
    }
};

const FarAway = 1000000.0;
const MaxDepth = 5;
const White = Color.init(1.0, 1.0, 1.0);
const Grey = Color.init(0.5, 0.5, 0.5);
const Black = Color.init(0.0, 0.0, 0.0);
const Background = Black;
const DefaultColor = Black;

const Camera = struct {
    forward: Vector,
    right: Vector,
    up: Vector,
    pos: Vector,

    pub fn init(pos: Vector, lookAt: Vector) Camera {
        const down = Vector.init(0.0, -1.0, 0.0);
        const forward = lookAt.sub(pos);
        const right = forward.cross(down).norm().scale(1.5);
        const up = forward.cross(right).norm().scale(1.5);
        return Camera{
            .pos = pos,
            .forward = forward.norm(),
            .right = right,
            .up = up,
        };
    }
};

const Ray = struct {
    start: Vector,
    dir: Vector,

    pub fn init(start: Vector, dir: Vector) Ray {
        return Ray{ .start = start, .dir = dir };
    }
};

const Intersection = struct {
    thing: Thing,
    ray: Ray,
    dist: f64,

    pub fn init(thing: Thing, ray: Ray, dist: f64) Intersection {
        return Intersection{ .thing = thing, .ray = ray, .dist = dist };
    }
};

const SurfaceProperties = struct {
    diffuse: Color,
    specular: Color,
    reflect: f64,
    roughness: f64,
};

const Light = struct {
    pos: Vector,
    color: Color,
    pub fn init(pos: Vector, color: Color) Light {
        return Light{ .pos = pos, .color = color };
    }
};

const Surface = enum {
    ShinySurface,
    CheckerboardSurface,
};

const Thing = union(enum) {
    Plane: struct { norm: Vector, offset: f64, surface: Surface },
    Sphere: struct { center: Vector, radius2: f64, surface: Surface },
};

fn GetNormal(thing: Thing, pos: Vector) Vector {
    return switch (thing) {
        Thing.Plane => |plane| plane.norm,
        Thing.Sphere => |sphere| (pos.sub(sphere.center)).norm(),
    };
}

fn GetSurface(thing: Thing) Surface {
    return switch (thing) {
        Thing.Plane => |plane| plane.surface,
        Thing.Sphere => |sphere| sphere.surface,
    };
}

fn GetIntersection(thing: Thing, ray: Ray) ?Intersection {
    return switch (thing) {
        Thing.Plane => |plane| {
            const denom = plane.norm.dot(ray.dir);
            if (denom > 0) {
                return null;
            }
            const dist = (plane.norm.dot(ray.start) + plane.offset) / (-denom);
            return Intersection.init(thing, ray, dist);
        },
        Thing.Sphere => |sphere| {
            const eo = sphere.center.sub(ray.start);
            const v = eo.dot(ray.dir);
            var dist: f64 = 0.0;
            if (v >= 0) {
                const disc = sphere.radius2 - (eo.dot(eo) - v * v);
                if (disc >= 0) {
                    dist = v - std.math.sqrt(disc);
                }
            }
            if (dist == 0) {
                return null;
            }
            return Intersection.init(thing, ray, dist);
        },
    };
}

fn GetSurfaceProperties(surface: Surface, pos: Vector) SurfaceProperties {
    return switch (surface) {
        Surface.ShinySurface => {
            return SurfaceProperties{
                .diffuse = White,
                .specular = Grey,
                .reflect = 0.7,
                .roughness = 250.0,
            };
        },
        Surface.CheckerboardSurface => {
            const condition = @mod(@as(i32, @intFromFloat(std.math.floor(pos.z) + std.math.floor(pos.x))), 2) != 0;
            var color = Black;
            var reflect: f64 = 0.7;
            if (condition) {
                color = White;
                reflect = 0.1;
            }
            return SurfaceProperties{
                .diffuse = color,
                .specular = White,
                .reflect = reflect,
                .roughness = 150.0,
            };
        },
    };
}

const Scene = struct {
    things: [3]Thing,
    lights: [4]Light,
    camera: Camera,
    pub fn init() Scene {
        const things = [3]Thing{
            Thing{ .Plane = .{ .norm = Vector.init(0.0, 1.0, 0.0), .offset = 0.0, .surface = Surface.CheckerboardSurface } },
            Thing{ .Sphere = .{ .center = Vector.init(0.0, 1.0, -0.25), .radius2 = 1.0, .surface = Surface.ShinySurface } },
            Thing{ .Sphere = .{ .center = Vector.init(-1.0, 0.5, 1.5), .radius2 = 0.25, .surface = Surface.ShinySurface } },
        };
        const lights = [4]Light{
            Light.init(Vector.init(-2.0, 2.5, 0.0), Color.init(0.49, 0.07, 0.07)),
            Light.init(Vector.init(1.5, 2.5, 1.5), Color.init(0.07, 0.07, 0.49)),
            Light.init(Vector.init(1.5, 2.5, -1.5), Color.init(0.07, 0.49, 0.071)),
            Light.init(Vector.init(0.0, 3.5, 0.0), Color.init(0.21, 0.21, 0.35)),
        };
        const camera = Camera.init(Vector.init(3.0, 2.0, 4.0), Vector.init(-1.0, 0.5, 0.0));
        return Scene{ .things = things, .lights = lights, .camera = camera };
    }
};

const Image = struct {
    width: i32,
    height: i32,
    data: []RGBColor,

    pub fn init(allocator: Allocator, w: i32, h: i32) !Image {
        const size: usize = @as(usize, @intCast(w * h));

        const data = try allocator.alloc(RGBColor, size);
        return Image{ .width = w, .height = h, .data = data };
    }

    pub fn setColor(self: Image, x: i32, y: i32, c: RGBColor) void {
        const idx: usize = @as(usize, @intCast(y * self.width + x));
        self.data[idx] = c;
    }

    pub fn save(self: Image, io: std.Io, fileName: []const u8) !void {
        const file = try std.Io.Dir.cwd().createFile(io, fileName, .{});
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &buffer);
        const stream = &file_writer.interface;
        const fileHeaderSize: u32 = 14;
        const infoHeaderSize: u32 = 40;
        const offBits = fileHeaderSize + infoHeaderSize;
        const imageSize: u32 = @as(u32, @intCast(self.width * self.height * 4));

        try writeIntLittle(stream, u16, 0x4D42);
        try writeIntLittle(stream, u32, offBits + imageSize);
        try writeIntLittle(stream, u16, 0);
        try writeIntLittle(stream, u16, 0);
        try writeIntLittle(stream, u32, offBits);

        try writeIntLittle(stream, u32, infoHeaderSize);
        try writeIntLittle(stream, i32, self.width);
        try writeIntLittle(stream, i32, -self.height);
        try writeIntLittle(stream, u16, 1);
        try writeIntLittle(stream, u16, 32);
        try writeIntLittle(stream, u32, 0);
        try writeIntLittle(stream, u32, imageSize);
        try writeIntLittle(stream, i32, 0);
        try writeIntLittle(stream, i32, 0);
        try writeIntLittle(stream, u32, 0);
        try writeIntLittle(stream, u32, 0);

        for (self.data) |color| {
            try stream.writeByte(color.b);
            try stream.writeByte(color.g);
            try stream.writeByte(color.r);
            try stream.writeByte(color.a);
        }

        try stream.flush();
    }
};

fn writeIntLittle(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

pub fn GetClosestIntersection(scene: Scene, ray: Ray) ?Intersection {
    var closest: f64 = FarAway;
    var closestInter: ?Intersection = null;

    for (scene.things) |thing| {
        const isect = GetIntersection(thing, ray);
        if (isect != null and isect.?.dist < closest) {
            closestInter = isect;
            closest = isect.?.dist;
        }
    }
    return closestInter;
}

pub fn TraceRay(scene: Scene, ray: Ray, depth: i32) Color {
    const isect = GetClosestIntersection(scene, ray);
    if (isect == null) {
        return Background;
    }
    return Shade(scene, isect.?, depth);
}

pub fn Shade(scene: Scene, isect: Intersection, depth: i32) Color {
    const d = isect.ray.dir;
    const pos = d.scale(isect.dist).add(isect.ray.start);
    const normal = GetNormal(isect.thing, pos);

    const vec = normal.scale(normal.dot(d) * 2.0);
    const reflectDir = d.sub(vec);

    const naturalColor = Background.add(GetNaturalColor(scene, isect.thing, pos, normal, reflectDir));
    var reflectedColor = Grey;
    if (depth < MaxDepth) {
        reflectedColor = GetReflectionColor(scene, isect.thing, pos, reflectDir, depth);
    }
    return naturalColor.add(reflectedColor);
}

pub fn GetReflectionColor(scene: Scene, thing: Thing, pos: Vector, reflectDir: Vector, depth: i32) Color {
    const ray = Ray.init(pos, reflectDir);
    const surface = GetSurfaceProperties(GetSurface(thing), pos);
    return TraceRay(scene, ray, depth + 1).scale(surface.reflect);
}

pub fn GetNaturalColor(scene: Scene, thing: Thing, pos: Vector, norm: Vector, rd: Vector) Color {
    var resultColor = Black;
    const surface = GetSurfaceProperties(GetSurface(thing), pos);
    const rayDirNormal = rd.norm();

    const colDiffuse = surface.diffuse;
    const colSpecular = surface.specular;

    for (scene.lights) |light| {
        const ldis = light.pos.sub(pos);
        const livec = ldis.norm();
        const ray = Ray.init(pos, livec);

        const isect = GetClosestIntersection(scene, ray);
        const isInShadow = isect != null and isect.?.dist < ldis.mag();

        if (!isInShadow) {
            const illum = livec.dot(norm);
            const specular = livec.dot(rayDirNormal);

            var lcolor = DefaultColor;
            var scolor = DefaultColor;

            if (illum > 0) {
                lcolor = light.color.scale(illum);
            }
            if (specular > 0) {
                scolor = light.color.scale(std.math.pow(f64, specular, surface.roughness));
            }

            lcolor = lcolor.mul(colDiffuse);
            scolor = scolor.mul(colSpecular);

            resultColor = resultColor.add(lcolor).add(scolor);
        }
    }

    return resultColor;
}

pub fn GetPoint(camera: Camera, x: i32, y: i32, screenWidth: i32, screenHeight: i32) Vector {
    const xf = @as(f64, @floatFromInt(x));
    const yf = @as(f64, @floatFromInt(y));
    const wf = @as(f64, @floatFromInt(screenWidth));
    const hf = @as(f64, @floatFromInt(screenHeight));

    const recenterX = (xf - (wf / 2.0)) / 2.0 / wf;
    const recenterY = -(yf - (hf / 2.0)) / 2.0 / hf;

    const vx = camera.right.scale(recenterX);
    const vy = camera.up.scale(recenterY);
    const v = vx.add(vy);

    return camera.forward.add(v).norm();
}

pub fn Render(scene: Scene, image: Image) void {
    var x: i32 = 0;
    var y: i32 = 0;

    while (y < image.height) {
        x = 0;
        while (x < image.width) {
            const pt = GetPoint(scene.camera, x, y, image.width, image.height);
            const ray = Ray.init(scene.camera.pos, pt);
            const color = TraceRay(scene, ray, 0).toDrawingColor();
            image.setColor(x, y, color);
            x += 1;
        }
        y += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const options = try parseBenchmarkOptions(init.gpa, init.minimal.args);
    var image = try Image.init(allocator, options.width, options.height);
    const sceneValue = Scene.init();

    const start = std.Io.Clock.Timestamp.now(init.io, .awake);
    Render(sceneValue, image);
    const end = std.Io.Clock.Timestamp.now(init.io, .awake);

    try image.save(init.io, options.output);
    const elapsed = start.durationTo(end);
    const elapsedMs = @as(f64, @floatFromInt(elapsed.raw.nanoseconds)) / 1000000.0;
    try printBenchmark(init.io, elapsedMs, options.width, options.height, options.output);
}

fn printBenchmark(io: std.Io, elapsedMs: f64, width: i32, height: i32, output: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("render time_ms={d:.4} width={} height={} output=\"{s}\"\n", .{ elapsedMs, width, height, output });
    try stdout.flush();
}

fn parseBenchmarkOptions(allocator: Allocator, args: std.process.Args) !BenchmarkOptions {
    var options = BenchmarkOptions{};
    var iterator = try args.iterateAllocator(allocator);
    defer iterator.deinit();

    _ = iterator.skip();
    while (iterator.next()) |name| {
        if (std.mem.eql(u8, name, "--width")) {
            if (iterator.next()) |value| {
                options.width = parseInt(value, options.width);
            }
        } else if (std.mem.eql(u8, name, "--height")) {
            if (iterator.next()) |value| {
                options.height = parseInt(value, options.height);
            }
        } else if (std.mem.eql(u8, name, "--output")) {
            if (iterator.next()) |value| {
                options.output = value;
            }
        }
    }

    return options;
}

fn parseInt(value: []const u8, fallback: i32) i32 {
    return std.fmt.parseInt(i32, value, 10) catch fallback;
}
