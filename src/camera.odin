package main

Camera :: struct {
	origin: Vec3,
	lower_left_corner: Vec3,
	horizontal: Vec3,
	vertical: Vec3,
}

get_ray :: proc(camera: Camera, u, v: f32) -> Ray {
	using camera

	return Ray{ origin, lower_left_corner + u * horizontal + v * vertical - origin }
}