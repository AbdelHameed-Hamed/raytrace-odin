package main

foreign import tile_trace "tile_trace.o"

@(default_calling_convention="cdecl")
foreign tile_trace {
	render_tile :: proc(
		width, height, begin_x, end_x, begin_y, end_y: u64,
		origin, lower_left_corner, horizental, vertical: ^f32,
		pixels: ^[4]u8,
	) ---
}