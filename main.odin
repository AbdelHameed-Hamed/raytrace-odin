package main

import "core:fmt"
import "core:sys/win32"
import "core:time"
import "core:mem"
import "core:math"
import "core:math/linalg"

running := true

bitmap_info: win32.Bitmap_Info = {}
bitmap_mem: rawptr = nil

Mode :: enum u8 {
	Single = 0,
	Multithreaded = 1 << 0,
	SIMD = 1 << 1,
	Both = Multithreaded | SIMD,
}

mode := Mode.Single

main :: proc() {
	cg := compute_group_new()
	defer compute_group_free(&cg)

	using win32

	h_instance := cast(Hinstance)get_module_handle_a(nil)

	class_name: cstring = "Raytracer"

	wc := Wnd_Class_A {
		instance = h_instance,
		class_name = class_name,
		wnd_proc = proc "std" (hwnd: Hwnd, msg: u32, w_param: Wparam, l_param: Lparam) -> Lresult {
			res: Lresult = 0

			switch msg {
			case WM_KEYDOWN:
				switch w_param {
				case VK_ESCAPE:
					running = false
				case VK_NUMPAD1:
					mode ~= Mode.Multithreaded
				case VK_NUMPAD2:
					mode ~= Mode.SIMD
				}
			case WM_QUIT, WM_CLOSE, WM_DESTROY:
				running = false
			case WM_SIZE:
				rect: Rect
				get_client_rect(hwnd, &rect)
				width, height := rect.right - rect.left, rect.bottom - rect.top

				if bitmap_mem != nil {
					virtual_free(bitmap_mem, 0, MEM_RELEASE)
				}

				bitmap_info.header.size = size_of(bitmap_info.header)
				bitmap_info.header.width = width
				bitmap_info.header.height = -height
				bitmap_info.header.planes = 1
				bitmap_info.header.bit_count = 32
				bitmap_info.header.compression = BI_RGB

				bitmap_mem = virtual_alloc(nil, cast(uint)(width * height * 4), MEM_COMMIT, PAGE_READWRITE)
			case WM_PAINT:
				paint: Paint_Struct
				device_ctx := begin_paint(hwnd, &paint)
				defer end_paint(hwnd, &paint)

				x, y := paint.rc_paint.left, paint.rc_paint.top
				width := paint.rc_paint.right - paint.rc_paint.left
				height := paint.rc_paint.bottom - paint.rc_paint.top

				stretch_dibits(
					device_ctx,
					x, y, width, height,
					x, y, width, height,
					bitmap_mem,
					&bitmap_info,
					DIB_RGB_COLORS, SRCCOPY,
				)
			case:
				res = def_window_proc_a(hwnd, msg, w_param, l_param)
			}

			return res
		},
	}
	register_class_a(&wc)

	hwnd := create_window_ex_a(
		0,
		class_name,
		"Toy Raytracer",
		WS_OVERLAPPEDWINDOW | WS_VISIBLE,
		CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
		nil, nil,
		h_instance,
		nil,
	)

	stopwatch: time.Stopwatch
	title_buffer: [200]byte = ---

	for msg: Msg; running; {
		time.stopwatch_start(&stopwatch)
		defer {
			frame_time := time.duration_milliseconds(time.stopwatch_duration(stopwatch))
			fmt.bprintf(
				title_buffer[:],
				"Frame time: {}, FPS: {}, mode: {}\x00",
				frame_time, 1000 / frame_time,
				mode,
			)
			win32.set_window_text_a(hwnd, cstring(&title_buffer[0]))
			time.stopwatch_reset(&stopwatch)
		}

		for peek_message_a(&msg, hwnd, 0, 0, PM_REMOVE) {
			translate_message(&msg)
			dispatch_message_a(&msg)
		}

		device_ctx := get_dc(hwnd)
		defer release_dc(hwnd, device_ctx)
		rect: Rect
		get_client_rect(hwnd, &rect)
		width, height := rect.right - rect.left, rect.bottom - rect.top

		aspect_ratio := cast(f32)width / cast(f32)height
		viewport_height: f32 = 2.0
		viewport_width := viewport_height * aspect_ratio
		focal_length:f32 = 1.0

		origin := Vec3{ 0, 0, 0 }
		horizental := Vec3{ viewport_width, 0, 0 }
		vertical := Vec3{ 0, viewport_height, 0 }
		lower_left_corner := origin - horizental / 2 - vertical / 2 - Vec3{ 0, 0, focal_length }

		image_byte_slice := mem.byte_slice(bitmap_mem, int(width * height * 4))
		image := mem.slice_data_cast([]Pixel, image_byte_slice)

		render_image(
			u64(width), u64(height),
			origin, lower_left_corner, horizental, vertical,
			image,
			&cg,
			mode,
		)
		stretch_dibits(
			device_ctx,
			0, 0, width, height,
			0, 0, width, height,
			bitmap_mem,
			&bitmap_info,
			DIB_RGB_COLORS, SRCCOPY,
		)
	}
}

Pixel :: distinct [4]u8

render_weird_gradient :: proc(time_s: f32, width, height: int) {
	image_byte_slice := mem.byte_slice(bitmap_mem, width * height * 4)
	image := mem.slice_data_cast([]Pixel, image_byte_slice)

	Vec2 :: distinct [2]f32

	for row in 0..<height {
		for col in 0..<width {
			uv := Vec2 { cast(f32)row / cast(f32)width, cast(f32)col / cast(f32)height }
			idx := cast(u32)(row * width + col)

			image[idx].b = cast(u8)((0.5 + 0.5 * math.cos(time_s + uv.x + 4)) * 255)
			image[idx].g = cast(u8)((0.5 + 0.5 * math.cos(time_s + uv.y + 2)) * 255)
			image[idx].r = cast(u8)((0.5 + 0.5 * math.cos(time_s + uv.x + 0)) * 255)
		}
	}
}

render_image :: proc(
	width, height: u64,
	origin, lower_left_corner, horizental, vertical: Vec3,
	image: []Pixel,
	cg: ^Compute_Group,
	mode: Mode)
{
	if mode & .Multithreaded != .Single {
		Data :: struct {
			width, height: u64,
			origin, lower_left_corner, horizental, vertical: Vec3,
			image: []Pixel,
			mode: Mode,
		}

		data := Data{ width, height, origin, lower_left_corner, horizental, vertical, image, mode }

		compute(
			cg,
			{ width, height, 1 },
			{ 64, 64, 1 },
			proc(args: Workgroup_Args, data: rawptr) {
				data := (^Data)(data)^
				using data

				render_tile(
					width, height,
					args.global_id.x, args.global_id.x + args.tile_size.x,
					args.global_id.y, args.global_id.y + args.tile_size.y,
					origin, lower_left_corner, horizental, vertical,
					image,
					mode,
				)
			},
			&data,
		)
	} else {
		render_tile(
			width, height, 0, width, 0, height,
			origin, lower_left_corner, horizental, vertical,
			image,
			mode,
		)
	}
}

render_tile :: proc(
	width, height, begin_x, end_x, begin_y, end_y: u64,
	origin, lower_left_corner, horizental, vertical: Vec3,
	image: []Pixel,
	mode: Mode)
{
	if mode & .SIMD != .Single {
		origin, lower_left_corner, horizental, vertical := origin, lower_left_corner, horizental, vertical
		render_tile_simd(
			width, height, begin_x, end_x, begin_y, end_y,
			transmute(^f32)&origin, transmute(^f32)&lower_left_corner,
			transmute(^f32)&horizental, transmute(^f32)&vertical,
			transmute(^[4]u8)&image[0],
		)
	} else {
		render_tile_single(
			width, height, begin_x, end_x, begin_y, end_y,
			origin, lower_left_corner, horizental, vertical,
			image,
		)
	}
}

render_tile_single :: proc(
	width, height, begin_x, end_x, begin_y, end_y: u64,
	origin, lower_left_corner, horizental, vertical: Vec3,
	image: []Pixel)
{
	for j in begin_y..<end_y {
		for i in begin_x..<end_x {
			u, v := cast(f32)(i) / cast(f32)(width - 1), cast(f32)j / cast(f32)(height - 1)
			r := Ray{ origin, lower_left_corner + u * horizental + v * vertical - origin }
			color := ray_color(r)

			idx := (height - j - 1) * width + i
			image[idx].b = cast(u8)(color.r * 255)
			image[idx].g = cast(u8)(color.g * 255)
			image[idx].r = cast(u8)(color.b * 255)
		}
	}
}

ray_color :: proc(r: Ray) -> Vec3 {
	t := hit_sphere(r, Vec3{ 0, 0, -1 }, 0.5)
	if t > 0.0 {
		n := linalg.normalize(at(r, t) - Vec3{ 0, 0, -1 })
		return 0.5 * (n + 1)
	}

	unit_dir := linalg.normalize(r.dir)
	t = 0.5 * (unit_dir.y + 1.0)
	return (1.0 - t) * Vec3{ 1.0, 1.0, 1.0 } + t * Vec3{ 0.5, 0.7, 1.0 }
}

hit_sphere :: proc(r: Ray, center: Vec3, radius: f32) -> f32 {
	oc := r.org - center
	a := linalg.length2(r.dir)
	half_b := linalg.dot(oc, r.dir)
	c := linalg.dot(oc, oc) - radius * radius
	discriminant := half_b * half_b - a * c
	if discriminant < 0 {
		return -1.0
	} else {
		return (-half_b - math.sqrt(discriminant)) / a
	}
}
