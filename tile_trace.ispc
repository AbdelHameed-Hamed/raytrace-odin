typedef uint8<4> Pixel;
typedef float<3> Vec3;
typedef float<4> Sphere;

inline float dot(Vec3 lhs, Vec3 rhs) { return lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z; }

inline static Vec3 normalize(Vec3 v) { return v / sqrt(dot(v, v)); }

struct Ray {
	Vec3 org, dir;
};

inline Vec3 at(Ray r, float t) { return r.org + t * r.dir; }

inline float hit_sphere(Ray r, Vec3 center, float radius) {
	Vec3 oc = r.org - center;
	float a = dot(r.dir, r.dir);
	float half_b = dot(oc, r.dir);
	float c = dot(oc, oc) - radius * radius;
	float discriminant = half_b * half_b - a * c;
	if (discriminant < 0) {
		return -1.0;
	} else {
		return (-half_b - sqrt(discriminant)) / a;
	}
}

inline Vec3 ray_color(Ray r, uniform const Sphere spheres[], uniform uint64 sphere_count) {
	float t = -1;
	Sphere sphere;

	for (uint64 i = 0; i < sphere_count; ++i) {
		float temp = hit_sphere(r, spheres[i].xyz, spheres[i].w);
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

export void render_tile_simd(
	uniform const uint64 width,
	uniform const uint64 height,
	uniform const uint64 begin_x,
	uniform const uint64 end_x,
	uniform const uint64 begin_y,
	uniform const uint64 end_y,
	uniform const float origin[3],
	uniform const float lower_left_corner[3],
	uniform const float horizental[3],
	uniform const float vertical[3],
	uniform const Sphere spheres[],
	uniform const uint64 sphere_count,
	uniform Pixel image[])
{
	const uniform Vec3 origin = { origin[0], origin[1], origin[2] };
	const uniform Vec3 lower_left_corner = {
		lower_left_corner[0],
		lower_left_corner[1],
		lower_left_corner[2]
	};
	const uniform Vec3 horizental = { horizental[0], horizental[1], horizental[2] };
	const uniform Vec3 vertical = { vertical[0], vertical[1], vertical[2] };

	foreach_tiled (j = begin_y...end_y, i = begin_x...end_x) {
		float u = i / (float)(width - 1), v = j / (float)(height - 1);
		Ray r = { origin, lower_left_corner + u * horizental + v * vertical - origin };
		Vec3 color = ray_color(r, spheres, sphere_count);

		image[(height - j - 1) * width + i].b = (int)(color.r * 255);
		image[(height - j - 1) * width + i].g = (int)(color.g * 255);
		image[(height - j - 1) * width + i].r = (int)(color.b * 255);
	}
}

