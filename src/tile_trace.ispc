typedef uint8 u8;
typedef uint16 u16;
typedef uint32 u32;
typedef uint64 u64;
typedef int8 i8;
typedef int16 i16;
typedef int32 i32;
typedef int64 i64;
typedef float f32;
typedef double f64;

typedef u8<4> Pixel;
typedef f32<3> Vec3;
typedef f32<4> Sphere;

inline f32 dot(Vec3 lhs, Vec3 rhs) { return lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z; }

inline static Vec3 normalize(Vec3 v) { return v / sqrt(dot(v, v)); }

struct Ray {
	Vec3 org, dir;
};

inline Vec3 at(Ray r, f32 t) { return r.org + t * r.dir; }

struct Camera {
	f32 origin[3], lower_left_corner[3], horizental[3], vertical[3];
};

inline f32 hit_sphere(Ray r, uniform Vec3 center, uniform f32 radius) {
	Vec3 oc = r.org - center;
	f32 a = dot(r.dir, r.dir);
	f32 half_b = dot(oc, r.dir);
	f32 c = dot(oc, oc) - radius * radius;
	f32 discriminant = half_b * half_b - a * c;
	if (discriminant < 0) {
		return -1.0;
	} else {
		return (-half_b - sqrt(discriminant)) / a;
	}
}

inline Vec3 ray_color(Ray r, uniform const Sphere spheres[], uniform u64 sphere_count) {
	f32 t = -1;
	Sphere sphere;

	for (uniform u64 i = 0; i < sphere_count; ++i) {
		f32 temp = hit_sphere(r, spheres[i].xyz, spheres[i].w);
		if (temp > 0 && (t == -1 || temp < t)) {
			t = temp;
			sphere = spheres[i];
		}
	}

	if (t > 0.0) {
		Vec3 n = normalize(at(r, t) - sphere.xyz);
		return 0.5 * (n + 1);
	}

	Vec3 unit_dir = normalize(r.dir);
	t = 0.5 * (unit_dir.y + 1.0);
	Vec3 white = { 1.0, 1.0, 1.0 }, blueish = { 0.5, 0.7, 1.0 };
	return (1.0 - t) * white + t * blueish;
}

struct Rand {
	u64 state, inc;
};

inline u32 rand_u32(Rand& r) {
	u64 old_state = r.state;
	r.state = old_state * 6364136223846793005 + (r.inc | 1);
	u32 xor_shited = u32(((old_state >> 18) ^ old_state) >> 27);
	u32 rot = u32(old_state >> 59);
	return (xor_shited >> rot) | (xor_shited << ((-rot) & 31));
}

inline u64 rand_u64(Rand& r) {
	u32 a = rand_u32(r);
	u32 b = rand_u32(r);
	return (a << 32) | b;
}

inline i32 rand_i31(Rand& r) { return i32(rand_u32(r) << 1 >> 1); }
inline i64 rand_i63(Rand& r) { return i64(rand_u64(r) << 1 >> 1); }

export void render_tile_simd(
	uniform const u64 width,
	uniform const u64 height,
	uniform const u64 begin_x,
	uniform const u64 end_x,
	uniform const u64 begin_y,
	uniform const u64 end_y,
	uniform const Camera camera,
	uniform const Sphere spheres[],
	uniform const u64 sphere_count,
	uniform Pixel image[])
{
	const uniform Vec3 origin = { camera.origin[0], camera.origin[1], camera.origin[2] };
	const uniform Vec3 lower_left_corner = {
		camera.lower_left_corner[0],
		camera.lower_left_corner[1],
		camera.lower_left_corner[2]
	};
	const uniform Vec3 horizental = { camera.horizental[0], camera.horizental[1], camera.horizental[2] };
	const uniform Vec3 vertical = { camera.vertical[0], camera.vertical[1], camera.vertical[2] };

	foreach_tiled (j = begin_y...end_y, i = begin_x...end_x) {
		f32 u = i / (f32)(width - 1), v = j / (f32)(height - 1);
		Ray r = { origin, lower_left_corner + u * horizental + v * vertical - origin };
		Vec3 color = ray_color(r, spheres, sphere_count);

		image[(height - j - 1) * width + i].b = (int)(color.r * 255);
		image[(height - j - 1) * width + i].g = (int)(color.g * 255);
		image[(height - j - 1) * width + i].r = (int)(color.b * 255);
	}
}

