package main

Vec3 :: distinct [3]f32

Ray :: struct {
	org: Vec3,
	dir: Vec3,
}

at :: proc(r: Ray, t: f32) -> Vec3 { return r.org + t * r.dir }
