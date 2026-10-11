shader_type spatial;
render_mode diffuse_toon, specular_disabled;

uniform vec2 amplitude = vec2(0.2, 0.1);
uniform vec2 amplitude2 = vec2(0.1, 0.2);
uniform vec2 frequency = vec2(3.0, 2.5);
uniform vec2 frequency2 = vec2(0.5, -1.5);
uniform vec2 time_factor = vec2(3.0, 2.5);
uniform vec2 time_factor2 = vec2(1.0, 2.0);

uniform sampler2D texturemap : source_color;
uniform vec2 texture_scale = vec2(30.0, 30.0);

uniform vec2 texture_flow1 = vec2(0.5, 0.25);
uniform vec2 texture_flow2 = vec2(-0.5, 1.0);

// Shore foam. shore_map holds the water depth of the terrain under the water, 0.5 + depth / 6 m (0.5 = the shore line),
// over the square from shore_origin of shore_size metres. Leave it empty on boards without a shore.
uniform sampler2D shore_map : hint_default_white, filter_linear;
uniform vec2 shore_origin = vec2(-120.0, -120.0);
uniform float shore_size = 240.0;
uniform float foam_amount = 1.0;

varying vec2 world_xz;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float height(vec2 pos, float time) {
	return (amplitude.x * sin(pos.x*frequency.x + time*time_factor.x)) + (amplitude.y * sin(pos.y*frequency.y + time*time_factor.y)) + (amplitude2.x * sin(pos.x*frequency2.x + time*time_factor2.x)) + (amplitude2.y * sin(pos.y*frequency2.y + time*time_factor2.y)) / 2.0;
}

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	VERTEX.y += height(VERTEX.xz, TIME);
	
	TANGENT = normalize(vec3(0.0, height(VERTEX.xz + vec2(0.0, 0.2), TIME) - height(VERTEX.xz + vec2(0.0, -0.2), TIME), 0.4));
	BINORMAL = normalize(vec3(0.4, height(VERTEX.xz + vec2(0.2, 0), TIME) - height(VERTEX.xz + vec2(-0.2, 0), TIME), 0.0));
	NORMAL = cross(TANGENT, BINORMAL);
}

void fragment() {
	ALBEDO = (texture(texturemap, UV * texture_scale + TIME * texture_flow1) + 0.25 * texture(texturemap, UV * texture_scale + TIME * texture_flow2)).rgb;
	
	if (ALBEDO.r > 0.9 && ALBEDO.g > 0.9 && ALBEDO.b > 0.9) {
		ALPHA = 0.9;
	} else {
		ALPHA = 0.5;
	}
	
	// Foam: a ragged white edge that breathes in and out along the shore, and a thin wave line rolling in from deeper water
	vec2 shore_uv = (world_xz - shore_origin) / shore_size;
	if (foam_amount > 0.0 && shore_uv.x > 0.0 && shore_uv.y > 0.0 && shore_uv.x < 1.0 && shore_uv.y < 1.0) {
		float depth = (texture(shore_map, shore_uv).r - 0.5) * 6.0;
		float broken = value_noise(world_xz * 0.9 + vec2(TIME * 0.25, -TIME * 0.15)) * 0.7 + value_noise(world_xz * 2.6 - TIME * 0.3) * 0.3;
		float edge = 0.45 + 0.20 * sin(TIME * 1.4 + world_xz.x * 0.2) + 0.25 * (broken - 0.5);
		float shore_foam = 1.0 - smoothstep(edge - 0.12, edge + 0.08, depth);
		float line_at = 0.95 + 0.3 * sin(TIME * 0.9);
		float wave_line = (1.0 - smoothstep(0.0, 0.11, abs(depth - line_at))) * step(0.42, broken) * smoothstep(0.2, 0.6, depth);
		float foam = clamp(shore_foam + 0.8 * wave_line, 0.0, 1.0) * foam_amount;
		ALBEDO = mix(ALBEDO, vec3(1.0), foam);
		ALPHA = max(ALPHA, foam * 0.95);
	}

	METALLIC = 0.5;
	ROUGHNESS = 0.4;
}
