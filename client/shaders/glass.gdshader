// Frosted glass panel: blurs what's behind it, tints it, and draws a rounded
// rim, an optional colored glow and a soft drop shadow. The node draws a rect
// padded by `pad` on every side so the shadow/glow have room.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec2 size = vec2(200.0, 100.0);
uniform float radius = 22.0;
uniform float blur = 3.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.09);
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.30);
uniform float border_width = 1.25;
uniform float shadow_alpha = 0.32;
uniform float shadow_size = 26.0;
uniform vec4 glow_color : source_color = vec4(0.0);

varying vec2 local;

void vertex() {
	local = VERTEX;
}

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 half_size = size * 0.5;
	vec2 p = local - half_size;
	float r = min(radius, min(half_size.x, half_size.y));
	float d = sd_round_box(p, half_size, r);
	float inside = 1.0 - smoothstep(-0.8, 0.8, d);

	// Gaussian-ish blur over a mip level of the screen.
	vec3 bg = vec3(0.0);
	float total = 0.0;
	vec2 px = SCREEN_PIXEL_SIZE * (1.0 + blur * 1.6);
	for (int x = -2; x <= 2; x++) {
		for (int y = -2; y <= 2; y++) {
			float w = exp(-float(x * x + y * y) / 4.0);
			bg += textureLod(screen_tex, SCREEN_UV + vec2(float(x), float(y)) * px, blur).rgb * w;
			total += w;
		}
	}
	bg /= total;

	float t = clamp(local.y / max(size.y, 1.0), 0.0, 1.0);
	vec3 col = bg * 0.92;
	col = mix(col, tint.rgb, tint.a + (1.0 - t) * 0.05);
	// Subtle diagonal sheen.
	float sheen = smoothstep(0.0, 1.0, 1.0 - (local.x / max(size.x, 1.0) + t) * 0.6) * 0.035;
	col += vec3(sheen);
	// Rim: brighter on top, fading toward the bottom.
	float rim = 1.0 - smoothstep(0.0, border_width, abs(d + border_width * 0.5));
	col = mix(col, border_color.rgb, rim * border_color.a * mix(1.4, 0.45, t));
	// Inner glow when highlighted.
	col = mix(col, glow_color.rgb, glow_color.a * 0.22 * smoothstep(-40.0, 0.0, d) * inside);

	// Outside: drop shadow and outer glow.
	float sd_shadow = sd_round_box(p - vec2(0.0, 10.0), half_size, r);
	float shadow = shadow_alpha * (1.0 - smoothstep(-shadow_size * 0.4, shadow_size, sd_shadow));
	float glow = glow_color.a * exp(-max(d, 0.0) / 9.0) * step(0.0, d);
	float out_a = max(shadow, glow);
	vec3 out_rgb = mix(vec3(0.0), glow_color.rgb, clamp(glow / max(out_a, 0.0001), 0.0, 1.0));

	vec4 outer = vec4(out_rgb, out_a * (1.0 - inside));
	COLOR = mix(outer, vec4(col, 1.0), inside);
}
