// Slowly drifting aurora blobs in the four UNO colors over a deep gradient.
// Gives the glass panels something colorful to blur.
shader_type canvas_item;

uniform vec2 size = vec2(1600.0, 900.0);
uniform vec4 accent : source_color = vec4(0.48, 0.36, 1.0, 1.0);
uniform float accent_mix = 0.0;
uniform vec4 base_top : source_color = vec4(0.035, 0.04, 0.10, 1.0);
uniform vec4 base_bottom : source_color = vec4(0.09, 0.045, 0.16, 1.0);
uniform vec4 blob1 : source_color = vec4(0.95, 0.22, 0.38, 1.0);
uniform vec4 blob2 : source_color = vec4(0.20, 0.45, 1.00, 1.0);
uniform vec4 blob3 : source_color = vec4(0.12, 0.80, 0.52, 1.0);
uniform vec4 blob4 : source_color = vec4(1.00, 0.76, 0.18, 1.0);

vec3 blob(vec2 uv, vec2 center, float radius, vec3 color) {
	float d = length(uv - center);
	return color * exp(-(d * d) / (radius * radius));
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	float aspect = size.x / max(size.y, 1.0);
	vec2 uv = vec2(UV.x * aspect, UV.y);
	float t = TIME * 0.07;

	vec3 col = mix(base_top.rgb, base_bottom.rgb, UV.y);

	col += blob(uv, vec2(aspect * (0.18 + 0.10 * sin(t * 1.3)), 0.25 + 0.12 * cos(t * 1.1)), 0.42, blob1.rgb) * 0.55;
	col += blob(uv, vec2(aspect * (0.82 + 0.08 * cos(t * 0.9)), 0.22 + 0.14 * sin(t * 1.4)), 0.40, blob2.rgb) * 0.60;
	col += blob(uv, vec2(aspect * (0.70 + 0.12 * sin(t * 0.7)), 0.85 + 0.08 * cos(t * 1.2)), 0.45, blob3.rgb) * 0.42;
	col += blob(uv, vec2(aspect * (0.28 + 0.10 * cos(t * 1.1)), 0.88 + 0.06 * sin(t * 0.8)), 0.38, blob4.rgb) * 0.38;
	col += blob(uv, vec2(aspect * 0.5, 0.5), 0.55, accent.rgb) * (0.18 + accent_mix * 0.35);

	// Vignette + film grain to avoid banding.
	float v = smoothstep(1.25, 0.25, length(UV - 0.5) * 1.4);
	col *= mix(0.55, 1.0, v);
	col += (hash(UV * size + fract(TIME)) - 0.5) * 0.018;

	COLOR = vec4(col, 1.0);
}
