module main

import math
import os
import strconv
import time

const far_away = 1000000.0
const max_depth = 5

struct BenchmarkOptions {
	width  int    = 500
	height int    = 500
	output string = 'v-ray.bmp'
}

struct RGBColor {
	b u8
	g u8
	r u8
	a u8
}

struct Vector {
	x f64
	y f64
	z f64
}

fn (v Vector) scale(k f64) Vector {
	return Vector{k * v.x, k * v.y, k * v.z}
}

fn (v Vector) add(other Vector) Vector {
	return Vector{v.x + other.x, v.y + other.y, v.z + other.z}
}

fn (v Vector) sub(other Vector) Vector {
	return Vector{v.x - other.x, v.y - other.y, v.z - other.z}
}

fn (v Vector) dot(other Vector) f64 {
	return v.x * other.x + v.y * other.y + v.z * other.z
}

fn (v Vector) mag() f64 {
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

fn (v Vector) norm() Vector {
	magnitude := v.mag()
	div := if magnitude == 0.0 { far_away } else { 1.0 / magnitude }
	return v.scale(div)
}

fn (v Vector) cross(other Vector) Vector {
	return Vector{v.y * other.z - v.z * other.y, v.z * other.x - v.x * other.z, v.x * other.y - v.y * other.x}
}

struct Color {
	r f64
	g f64
	b f64
}

fn (c Color) scale(k f64) Color {
	return Color{k * c.r, k * c.g, k * c.b}
}

fn (c Color) add(other Color) Color {
	return Color{c.r + other.r, c.g + other.g, c.b + other.b}
}

fn (c Color) mul(other Color) Color {
	return Color{c.r * other.r, c.g * other.g, c.b * other.b}
}

fn (c Color) to_rgb_color() RGBColor {
	return RGBColor{clamp(c.b), clamp(c.g), clamp(c.r), 255}
}

fn clamp(c f64) u8 {
	if c > 1.0 {
		return 255
	}
	if c < 0.0 {
		return 0
	}
	return u8(c * 255.0)
}

const white = Color{1.0, 1.0, 1.0}
const grey = Color{0.5, 0.5, 0.5}
const black = Color{0.0, 0.0, 0.0}

struct Camera {
	pos     Vector
	forward Vector
	right   Vector
	up      Vector
}

fn new_camera(pos Vector, look_at Vector) Camera {
	down := Vector{0.0, -1.0, 0.0}
	forward := look_at.sub(pos).norm()
	right := forward.cross(down).norm().scale(1.5)
	up := forward.cross(right).norm().scale(1.5)
	return Camera{pos, forward, right, up}
}

fn (camera Camera) get_point(x int, y int, width int, height int) Vector {
	recenter_x := (f64(x) - f64(width) / 2.0) / 2.0 / f64(width)
	recenter_y := -(f64(y) - f64(height) / 2.0) / 2.0 / f64(height)
	return camera.forward.add(camera.right.scale(recenter_x)).add(camera.up.scale(recenter_y)).norm()
}

struct Ray {
	start Vector
	dir   Vector
}

enum Surface {
	shiny
	checkerboard
}

enum ThingKind {
	plane
	sphere
}

struct Thing {
	kind    ThingKind
	normal  Vector
	offset  f64
	center  Vector
	radius2 f64
	surface Surface
}

struct SurfaceProperties {
	diffuse   Color
	specular  Color
	reflect   f64
	roughness f64
}

struct Light {
	pos   Vector
	color Color
}

struct Scene {
	camera Camera
	things []Thing
	lights []Light
}

struct Intersection {
	thing Thing
	ray   Ray
	dist  f64
}

struct Image {
	width  int
	height int
mut:
	data []RGBColor
}

fn main() {
	options := parse_benchmark_options(os.args)
	mut image := new_image(options.width, options.height)
	scene := new_scene()
	start := time.now()
	render(scene, mut image)
	elapsed := f64(time.since(start).nanoseconds()) / 1000000.0
	save_bmp(image, options.output) or { panic(err) }
	println('render time_ms=${elapsed:.4f} width=${options.width} height=${options.height} output="${options.output}"')
}

fn parse_benchmark_options(args []string) BenchmarkOptions {
	mut options := BenchmarkOptions{}
	mut i := 1
	for i < args.len {
		name := args[i]
		value := if i + 1 < args.len { args[i + 1] } else { '' }
		if name == '--width' && value != '' {
			options = BenchmarkOptions{
				...options
				width: strconv.atoi(value) or { options.width }
			}
			i += 2
		} else if name == '--height' && value != '' {
			options = BenchmarkOptions{
				...options
				height: strconv.atoi(value) or { options.height }
			}
			i += 2
		} else if name == '--output' && value != '' {
			options = BenchmarkOptions{
				...options
				output: value
			}
			i += 2
		} else {
			i++
		}
	}
	return options
}

fn new_scene() Scene {
	return Scene{
		camera: new_camera(Vector{3.0, 2.0, 4.0}, Vector{-1.0, 0.5, 0.0})
		things: [
			Thing{
				kind:    .plane
				normal:  Vector{0.0, 1.0, 0.0}
				offset:  0.0
				surface: .checkerboard
			},
			Thing{
				kind:    .sphere
				center:  Vector{0.0, 1.0, -0.25}
				radius2: 1.0
				surface: .shiny
			},
			Thing{
				kind:    .sphere
				center:  Vector{-1.0, 0.5, 1.5}
				radius2: 0.25
				surface: .shiny
			},
		]
		lights: [
			Light{Vector{-2.0, 2.5, 0.0}, Color{0.49, 0.07, 0.07}},
			Light{Vector{1.5, 2.5, 1.5}, Color{0.07, 0.07, 0.49}},
			Light{Vector{1.5, 2.5, -1.5}, Color{0.07, 0.49, 0.071}},
			Light{Vector{0.0, 3.5, 0.0}, Color{0.21, 0.21, 0.35}},
		]
	}
}

fn new_image(width int, height int) Image {
	return Image{
		width:  width
		height: height
		data:   []RGBColor{len: width * height}
	}
}

fn surface_properties(surface Surface, pos Vector) SurfaceProperties {
	match surface {
		.shiny {
			return SurfaceProperties{white, grey, 0.7, 250.0}
		}
		.checkerboard {
			condition := int(math.floor(pos.z) + math.floor(pos.x)) % 2 != 0
			return SurfaceProperties{
				diffuse:   if condition { white } else { black }
				specular:  white
				reflect:   if condition { 0.1 } else { 0.7 }
				roughness: 250.0
			}
		}
	}
}

fn get_normal(thing Thing, pos Vector) Vector {
	return match thing.kind {
		.plane { thing.normal }
		.sphere { pos.sub(thing.center).norm() }
	}
}

fn get_intersection(thing Thing, ray Ray) ?Intersection {
	match thing.kind {
		.plane {
			denom := thing.normal.dot(ray.dir)
			if denom > 0.0 {
				return none
			}
			dist := (thing.normal.dot(ray.start) + thing.offset) / (-denom)
			return Intersection{thing, ray, dist}
		}
		.sphere {
			eo := thing.center.sub(ray.start)
			v := eo.dot(ray.dir)
			mut dist := 0.0
			if v >= 0.0 {
				disc := thing.radius2 - (eo.dot(eo) - v * v)
				if disc >= 0.0 {
					dist = v - math.sqrt(disc)
				}
			}
			if dist == 0.0 {
				return none
			}
			return Intersection{thing, ray, dist}
		}
	}
}

fn closest_intersection(scene Scene, ray Ray) ?Intersection {
	mut closest := far_away
	mut closest_inter := ?Intersection(none)
	for thing in scene.things {
		if isect := get_intersection(thing, ray) {
			if isect.dist < closest {
				closest = isect.dist
				closest_inter = isect
			}
		}
	}
	return closest_inter
}

fn trace_ray(scene Scene, ray Ray, depth int) Color {
	if isect := closest_intersection(scene, ray) {
		return shade(scene, isect, depth)
	}
	return black
}

fn shade(scene Scene, isect Intersection, depth int) Color {
	d := isect.ray.dir
	pos := d.scale(isect.dist).add(isect.ray.start)
	normal := get_normal(isect.thing, pos)
	reflect_dir := d.sub(normal.scale(2.0 * normal.dot(d)))
	surface := surface_properties(isect.thing.surface, pos)
	natural_color := get_natural_color(scene, isect.thing, pos, normal, reflect_dir)
	reflected_color := if depth >= max_depth {
		grey
	} else {
		trace_ray(scene, Ray{pos, reflect_dir}, depth + 1).scale(surface.reflect)
	}
	return natural_color.add(reflected_color)
}

fn get_natural_color(scene Scene, thing Thing, pos Vector, normal Vector, reflect_dir Vector) Color {
	mut result := black
	surface := surface_properties(thing.surface, pos)
	ray_dir_normal := reflect_dir.norm()
	for light in scene.lights {
		ldis := light.pos.sub(pos)
		livec := ldis.norm()
		neat_isect := closest_intersection(scene, Ray{pos, livec})
		in_shadow := if isect := neat_isect { isect.dist <= ldis.mag() } else { false }
		if !in_shadow {
			illum := livec.dot(normal)
			lcolor := if illum > 0.0 { light.color.scale(illum) } else { black }
			specular := livec.dot(ray_dir_normal)
			scolor := if specular > 0.0 {
				light.color.scale(math.pow(specular, surface.roughness))
			} else {
				black
			}
			result = result.add(surface.diffuse.mul(lcolor)).add(surface.specular.mul(scolor))
		}
	}
	return result
}

fn render(scene Scene, mut image Image) {
	for y in 0 .. image.height {
		for x in 0 .. image.width {
			dir := scene.camera.get_point(x, y, image.width, image.height)
			color := trace_ray(scene, Ray{scene.camera.pos, dir}, 0).to_rgb_color()
			image.data[y * image.width + x] = color
		}
	}
}

fn save_bmp(image Image, file_name string) ! {
	mut bytes := []u8{cap: 54 + image.width * image.height * 4}
	image_size := u32(image.width * image.height * 4)
	off_bits := u32(54)

	write_u16(mut bytes, 0x4d42)
	write_u32(mut bytes, off_bits + image_size)
	write_u16(mut bytes, 0)
	write_u16(mut bytes, 0)
	write_u32(mut bytes, off_bits)
	write_u32(mut bytes, 40)
	write_i32(mut bytes, image.width)
	write_i32(mut bytes, -image.height)
	write_u16(mut bytes, 1)
	write_u16(mut bytes, 32)
	write_u32(mut bytes, 0)
	write_u32(mut bytes, image_size)
	write_i32(mut bytes, 0)
	write_i32(mut bytes, 0)
	write_u32(mut bytes, 0)
	write_u32(mut bytes, 0)
	for color in image.data {
		bytes << color.b
		bytes << color.g
		bytes << color.r
		bytes << color.a
	}
	os.write_file_array(file_name, bytes)!
}

fn write_u16(mut bytes []u8, value u16) {
	bytes << u8(value & 0xff)
	bytes << u8((value >> 8) & 0xff)
}

fn write_u32(mut bytes []u8, value u32) {
	bytes << u8(value & 0xff)
	bytes << u8((value >> 8) & 0xff)
	bytes << u8((value >> 16) & 0xff)
	bytes << u8((value >> 24) & 0xff)
}

fn write_i32(mut bytes []u8, value int) {
	write_u32(mut bytes, u32(value))
}
