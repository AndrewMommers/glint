extends SceneTree
## Renders branding/svg/*.svg to PNGs (ThorVG, works headless):
##   godot --headless --script tools/render_branding.gd -- <repo root>

const JOBS := [
	# [svg, output png, width]
	["emblem.svg", "icon-1024.png", 1024],
	["emblem.svg", "icon-512.png", 512],
	["emblem.svg", "icon-256.png", 256],
	["emblem.svg", "icon-128.png", 128],
	["emblem.svg", "icon-64.png", 64],
	["emblem.svg", "icon-48.png", 48],
	["emblem.svg", "icon-32.png", 32],
	["emblem.svg", "icon-24.png", 24],
	["emblem.svg", "icon-16.png", 16],
	["emblem-transparent.svg", "emblem-transparent-512.png", 512],
	["wordmark.svg", "wordmark-2000.png", 2000],
	["wordmark-white.svg", "wordmark-white-2000.png", 2000],
	["wordmark-dark.svg", "wordmark-dark-2000.png", 2000],
	["lockup-horizontal.svg", "lockup-horizontal-1600.png", 1600],
	["lockup-stacked.svg", "lockup-stacked-1000.png", 1000],
	["lockup-horizontal-light.svg", "lockup-horizontal-light-1600.png", 1600],
	["lockup-stacked-light.svg", "lockup-stacked-light-1000.png", 1000],
	["wordmark-light.svg", "wordmark-light-2000.png", 2000],
	["splash.svg", "splash-1600x900.png", 1600],
	["social-preview.svg", "social-preview-1280x640.png", 1280],
	["key-art-1920x1080.svg", "key-art-1920x1080.png", 1920],
	["capsule-630x500.svg", "capsule-630x500.png", 630],
	["capsule-460x215.svg", "capsule-460x215.png", 460],
	["installer-side.svg", "installer-side.png", 328],
	["installer-back.svg", "installer-back.png", 1200],
	["emblem.svg", "installer-small.png", 110],
]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var root: String = args[0] if args.size() > 0 else "."
	var svg_dir := root.path_join("branding/svg")
	var png_dir := root.path_join("branding/png")
	DirAccess.make_dir_recursive_absolute(png_dir)
	for job in JOBS:
		var svg := FileAccess.get_file_as_string(svg_dir.path_join(job[0]))
		var natural := _svg_width(svg)
		var img := Image.new()
		var err := img.load_svg_from_string(svg, float(job[2]) / natural)
		if err != OK:
			printerr("failed ", job[0], " ", err)
			continue
		if img.get_width() != job[2] and img.get_width() > 0:
			var h := int(round(img.get_height() * float(job[2]) / img.get_width()))
			img.resize(job[2], h, Image.INTERPOLATE_LANCZOS)
		img.save_png(png_dir.path_join(job[1]))
		print("rendered ", job[1], " ", img.get_size())
	# the boot splash used by the game
	var splash := Image.new()
	splash.load(png_dir.path_join("splash-1600x900.png"))
	splash.save_png(root.path_join("client/branding/splash.png"))
	print("copied splash into the game")
	quit()


func _svg_width(svg: String) -> float:
	var i := svg.find("width=\"")
	if i < 0:
		return 512.0
	var j := svg.find("\"", i + 7)
	return float(svg.substr(i + 7, j - i - 7))
