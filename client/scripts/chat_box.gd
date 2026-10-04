class_name ChatBox
extends VBoxContainer
## Room chat for the lobby: recent messages and an input line. The table
## shows chat lines in its activity feed using ChatBox.line().

const MAX_LEN := 140

var scroll := ScrollContainer.new()
var lines := UI.vbox(6)
var input: LineEdit


func _init(height: float = 300.0) -> void:
	add_theme_constant_override("separation", 10)
	add_child(UI.section("Chat"))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, height)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lines.alignment = BoxContainer.ALIGNMENT_END
	scroll.add_child(lines)
	add_child(scroll)
	input = UI.line_edit("", "Say something…", MAX_LEN)
	input.text_submitted.connect(func(t: String) -> void:
		ChatBox.send(t)
		input.clear())
	add_child(input)


func set_history(items: Array) -> void:
	for c in lines.get_children():
		c.queue_free()
	if items.is_empty():
		lines.add_child(UI.label("No messages yet. Say hi!", 14, 500, UI.MUTED))
	for e in items:
		lines.add_child(line(e))
	_to_bottom()


func add(entry: Dictionary) -> void:
	if lines.get_child_count() == 1 and lines.get_child(0) is Label:
		lines.get_child(0).queue_free()  # the "no messages" hint
	lines.add_child(line(entry))
	while lines.get_child_count() > 60:
		lines.get_child(0).free()
	_to_bottom()


func _to_bottom() -> void:
	if not is_inside_tree():
		await ready
	await get_tree().process_frame
	if is_instance_valid(scroll):
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)


static func send(text: String) -> void:
	text = text.strip_edges()
	if text != "":
		Net.send({"t": "chat", "text": text})


## One chat message: the sender's name in their avatar color, then the text.
## System messages (joins, leaves, host changes) are muted.
static func line(e: Dictionary, size: int = 15) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_theme_font_override("normal_font", UI.font(500))
	r.add_theme_font_override("bold_font", UI.font(800))
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	if e.get("sys", false):
		r.push_color(UI.MUTED)
		r.add_text(str(e.get("text", "")))
		r.pop()
		return r
	var nm := str(e.get("name", "?"))
	r.push_bold()
	r.push_color(UI.avatar_color(nm).lightened(0.35))
	r.add_text(nm)
	r.pop()
	r.pop()
	r.push_color(Color(1, 1, 1, 0.92))
	r.add_text("  " + str(e.get("text", "")))
	r.pop()
	return r
