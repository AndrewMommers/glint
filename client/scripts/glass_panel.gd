class_name GlassPanel
extends PanelContainer
## A frosted-glass container. Children are laid out like a PanelContainer;
## the glass itself (blur, rim, shadow, glow) is drawn by glass.gdshader.

const PAD := 48.0
static var _shader: Shader

var mat := ShaderMaterial.new()

var radius := 22.0:
	set(v):
		radius = v
		mat.set_shader_parameter("radius", v)

var glow := Color(0, 0, 0, 0):
	set(v):
		glow = v
		mat.set_shader_parameter("glow_color", v)

var tint_alpha := 0.09:
	set(v):
		tint_alpha = v
		mat.set_shader_parameter("tint", Color(1, 1, 1, v))


func _init(margin: float = 20.0, corner: float = 22.0) -> void:
	if _shader == null:
		_shader = load("res://shaders/glass.gdshader")
	mat.shader = _shader
	material = mat
	radius = corner
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = margin
	sb.content_margin_right = margin
	sb.content_margin_top = margin
	sb.content_margin_bottom = margin
	add_theme_stylebox_override("panel", sb)
	resized.connect(_on_resized)


func set_margins(h: float, v: float) -> void:
	var sb := get_theme_stylebox("panel") as StyleBoxEmpty
	sb.content_margin_left = h
	sb.content_margin_right = h
	sb.content_margin_top = v
	sb.content_margin_bottom = v


func _on_resized() -> void:
	mat.set_shader_parameter("size", size)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2(-PAD, -PAD), size + Vector2(PAD, PAD) * 2.0), Color.WHITE)
