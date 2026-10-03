// A diagonal light sweep across a texture (logo shine).
shader_type canvas_item;

uniform float sweep = -0.5;  // animate from about -0.5 to 1.5
uniform float width = 0.09;
uniform float strength = 0.6;

void fragment() {
	vec4 c = COLOR;  // already texture * modulate
	float d = abs((UV.x + UV.y * 0.35) - sweep);
	float band = 1.0 - smoothstep(0.0, width, d);
	c.rgb = mix(c.rgb, vec3(1.0), band * strength * c.a);
	COLOR = c;
}
