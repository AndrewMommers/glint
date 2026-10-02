extends Node
## Autoload "Settings": options menu values (audio, display, gameplay),
## saved to user://options.cfg and applied immediately.

signal changed

const PATH := "user://options.cfg"

var values := {
	"master": 0.8,
	"music": 0.55,
	"sfx": 0.8,
	"ui": 0.6,
	"mute": false,
	"fullscreen": false,
	"vsync": true,
	"max_fps": 0,
	"ui_scale": 1.0,
	"reduce_motion": false,
	"timer_ticks": true,
	"key_hints": true,
}


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		for k in values:
			values[k] = cf.get_value("options", k, values[k])
	apply.call_deferred()


func v(key: String) -> Variant:
	return values.get(key)


func set_value(key: String, value: Variant) -> void:
	values[key] = value
	apply()
	save()
	changed.emit()


func save() -> void:
	var cf := ConfigFile.new()
	for k in values:
		cf.set_value("options", k, values[k])
	cf.save(PATH)


func apply() -> void:
	var want_fs: bool = values.fullscreen
	var mode := DisplayServer.window_get_mode()
	var is_fs := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if want_fs != is_fs and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if want_fs else DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if values.vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = int(values.max_fps)
	get_tree().root.content_scale_factor = float(values.ui_scale)
	Audio.apply_volumes()


func reset_defaults() -> void:
	values = {
		"master": 0.8, "music": 0.55, "sfx": 0.8, "ui": 0.6, "mute": false,
		"fullscreen": false, "vsync": true, "max_fps": 0, "ui_scale": 1.0,
		"reduce_motion": false, "timer_ticks": true, "key_hints": true,
	}
	apply()
	save()
	changed.emit()
