package main

import "core:math"
import "core:math/linalg"

Sphere :: struct {
	center: Vec3,
	radius: f32,
}

hit_sphere :: proc(r: Ray, s: Sphere) -> f32 {
	using s

	oc := r.org - center
	a := linalg.length2(r.dir)
	half_b := linalg.dot(oc, r.dir)
	c := linalg.dot(oc, oc) - radius * radius
	discriminant := half_b * half_b - a * c
	if discriminant < 0 {
		return -1
	} else {
		return (-half_b - math.sqrt(discriminant)) / a
	}
}
