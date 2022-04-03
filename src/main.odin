package main

import "core:fmt"
import "core:sys/win32"
import "core:time"
import "core:mem"
import "core:math/linalg"
import "core:math/rand"

import compute "parallel-compute-odin"

running := true

bitmap_info: win32.Bitmap_Info = {}
bitmap_mem: rawptr = nil

Mode :: enum u8 {
	Single = 0,
	Multithreaded = 1 << 0,
	SIMD = 1 << 1,
	Both = Multithreaded | SIMD,
}

mode := Mode.Multithreaded

SAMPLES_PER_PIXEL :: 8

main :: proc() {
	spheres := make([dynamic]Sphere)
	defer delete(spheres)

	append(&spheres, Sphere{ Vec3{ 0,      0, -1 }, 0.5 })
	append(&spheres, Sphere{ Vec3{ 0, -100.5, -1 }, 100 })

	cg := compute.compute_group_new()
	defer compute.compute_group_free(&cg)

	thread_prngs := make([]rand.Rand, len(cg.workers))
	defer delete(thread_prngs)

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
		viewport_height: f32 = 2
		viewport_width := viewport_height * aspect_ratio
		focal_length:f32 = 1

		camera := Camera{
			origin = Vec3{ 0, 0, 0 },
			horizontal = Vec3{ viewport_width, 0, 0 },
			vertical = Vec3{ 0, viewport_height, 0 },
		}
		camera.lower_left_corner =
			camera.origin - camera.horizontal / 2 - camera.vertical / 2 - Vec3{ 0, 0, focal_length }

		for _, i in thread_prngs {
			thread_prngs[i] = rand.Rand{ 0x853c49e6748fea9b, 0xda3e39cb94b95bdb }
		}

		image_byte_slice := mem.byte_slice(bitmap_mem, int(width * height * 4))
		image := mem.slice_data_cast([]Pixel, image_byte_slice)

		render_image(
			u64(width), u64(height),
			camera,
			spheres[:],
			thread_prngs,
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

render_image :: proc(
	width, height: u64,
	camera: Camera,
	spheres: []Sphere,
	thread_prngs: []rand.Rand,
	image: []Pixel,
	cg: ^compute.Compute_Group,
	mode: Mode)
{
	if mode & .Multithreaded != .Single {
		Data :: struct {
			width, height: u64,
			camera: Camera,
			spheres: []Sphere,
			thread_prngs: []rand.Rand,
			image: []Pixel,
			mode: Mode,
		}

		data := Data{ width, height, camera, spheres, thread_prngs, image, mode }

		compute.compute(
			cg,
			{ width, height, 1 },
			{ 64, 64, 1 },
			proc(args: compute.Workgroup_Args, data: rawptr) {
				data := (^Data)(data)^
				using data

				render_tile(
					width, height,
					args.global_id.x, args.global_id.x + args.tile_size.x,
					args.global_id.y, args.global_id.y + args.tile_size.y,
					camera,
					spheres,
					&thread_prngs[compute.local_worker_idx()],
					image,
					mode,
				)
			},
			&data,
		)
	} else {
		render_tile(width, height, 0, width, 0, height, camera, spheres, &thread_prngs[0], image, mode)
	}
}

render_tile :: proc(
	width, height, begin_x, end_x, begin_y, end_y: u64,
	camera: Camera,
	spheres: []Sphere,
	prng: ^rand.Rand,
	image: []Pixel,
	mode: Mode)
{
	if mode & .SIMD != .Single {
		camera := camera
		using camera

		render_tile_simd(
			width, height, begin_x, end_x, begin_y, end_y,
			transmute(^f32)&origin, transmute(^f32)&lower_left_corner,
			transmute(^f32)&horizontal, transmute(^f32)&vertical,
			transmute(^[4]f32)&spheres[0], u64(len(spheres)),
			transmute(^[4]u8)&image[0],
		)
	} else {
		render_tile_single(width, height, begin_x, end_x, begin_y, end_y, camera, spheres, prng, image)
	}
}

render_tile_single :: proc(
	width, height, begin_x, end_x, begin_y, end_y: u64,
	camera: Camera,
	spheres: []Sphere,
	prng: ^rand.Rand,
	image: []Pixel)
{
	for j in begin_y..<end_y {
		for i in begin_x..<end_x {
			color := Vec3{}

			for k in 0..<SAMPLES_PER_PIXEL {
				u := (f32(i) + rand.float32(prng)) / f32(width - 1)
				v := (f32(j) + rand.float32(prng)) / f32(height - 1)
				r := get_ray(camera, u, v)
				color += ray_color(r, spheres)
			}

			color /= SAMPLES_PER_PIXEL
			idx := (height - j - 1) * width + i
			image[idx].bgr = { u8(color.r * 255), u8(color.g * 255), u8(color.b * 255) }
		}
	}
}

ray_color :: proc(r: Ray, spheres: []Sphere) -> Vec3 {
	t: f32 = -1
	sphere: Sphere = ---
	for s in spheres {
		temp := hit_sphere(r, s)
		if temp > 0 && (t == -1 || temp < t) {
			t = temp
			sphere = s
		}
	}

	if t > 0 {
		n := linalg.normalize(at(r, t) - sphere.center)
		return 0.5 * (n + 1)
	}

	unit_dir := linalg.normalize(r.dir)
	t = 0.5 * (unit_dir.y + 1)
	return (1 - t) * Vec3{ 1, 1, 1 } + t * Vec3{ 0.5, 0.7, 1 }
}
