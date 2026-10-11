## Dev tool: screenshots of the menus and the board HUD.
##
## SHOTS_DIR=/tmp/ui godot --path . res://tools/ui_shots/ui_shots.tscn
extends Node

var dir := ""


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


## Reports controls that stick out of the window and texts that do not fit their control.
func audit(name: String) -> void:
	var win := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var problems := 0
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if not (n is Control) or not n.is_visible_in_tree() or n.get_viewport() != get_viewport():
			continue
		var c: Control = n
		var r := c.get_global_rect()
		if c.size.x < 2 or c.size.y < 2 or c.modulate.a < 0.05:
			continue
		var reason := ""
		if c is Label or c is Button or c is CheckBox:
			var text: String = tr(c.text)
			if text != "" and not (c is Label and (c as Label).autowrap_mode != TextServer.AUTOWRAP_OFF):
				var font: Font = c.get_theme_font("font")
				var fs: int = c.get_theme_font_size("font_size")
				var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var avail: float = c.size.x
				if c is Button:
					avail -= 20
				var ellipsis: bool = (c is Label and (c as Label).text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING) or \
						(c is Button and (c as Button).text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING)
				if w > avail + 2.0:
					reason = "text %dpx wide in %dpx%s" % [w, avail, " (trimmed)" if ellipsis else ""]
					if ellipsis and not OS.get_environment("AUDIT_TRIMMED") != "":
						reason = ""
		if reason == "" and r.size.x > 4 and r.size.y > 4 and (r.position.x < -3 or r.position.y < -3 or r.end.x > win.size.x + 3 or r.end.y > win.size.y + 3):
			if not (c is Label and c.get_parent() is ProgressBar) and not c.get_parent() is ScrollContainer and c.get_parent() != null and c.get_parent().get_class() != "SubViewportContainer":
				reason = "outside the window %s" % [r]
		if reason != "":
			problems += 1
			print("AUDIT ", name, ": ", n.get_path(), " ", reason)
	print("AUDIT ", name, " done, problems: ", problems)


func snap(name: String) -> void:
	await wait(0.8)
	audit(name)
	get_viewport().get_texture().get_image().save_png(dir.path_join(name + ".png"))
	print("UI ", name)


func press(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	Input.parse_input_event(e)
	await wait(0.12)
	e = InputEventAction.new()
	e.action = action
	e.pressed = false
	Input.parse_input_event(e)
	await wait(0.4)


func _ready() -> void:
	dir = OS.get_environment("SHOTS_DIR") if OS.get_environment("SHOTS_DIR") != "" else "user://ui"
	DirAccess.make_dir_recursive_absolute(dir)
	var only := OS.get_environment("ONLY")
	await wait(2.0)
	# the main menu is the scene the game starts with: load it here as a child
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(holder)
	var menu: Node = load("res://client/menus/main_menu.tscn").instantiate()
	holder.add_child(menu)
	await snap("main_menu")
	menu._on_Options_pressed()
	await wait(1.5)
	await snap("options")
	menu.queue_free()
	await wait(0.5)
	var pause: PopupPanel = load("res://client/menus/pause_menu.tscn").instantiate()
	holder.add_child(pause)
	pause.popup_centered(Vector2i(420, 480))
	await snap("pause")
	pause.queue_free()
	var loading: Node = load("res://client/menus/loading_screen.tscn").instantiate()
	holder.add_child(loading)
	await snap("loading")
	loading.queue_free()
	await wait(0.5)

	var menu2: Node = load("res://client/menus/main_menu.tscn").instantiate()
	holder.add_child(menu2)
	await wait(1.0)
	menu2._on_Play_pressed()
	await wait(3.0)
	await snap("lobby")
	await press("player1_ok")
	await press("player1_ok")
	await snap("lobby_2")
	var lobby = menu2.lobby
	lobby.set_player_name(0, "Tester")
	lobby.select_character(0, "Businessman")
	await wait(1.0)
	lobby.select_board("RetroValley")
	await snap("lobby_board")
	lobby.start()
	await wait(25.0)
	await snap("board_hud_1")
	await press("player1_ok")
	await wait(3.0)
	await snap("board_hud_2")
	var ctrl: Node = null
	for n in get_tree().get_nodes_in_group("Controller"):
		if get_node("/root/Server").is_ancestor_of(n):
			ctrl = n
	ctrl.prepare_minigame()
	await wait(2.0)
	await snap("minigame_vote")
	await press("player1_ok")
	await wait(9.0)
	await snap("minigame_intro")
	await wait(4.0)
	await snap("minigame_info")
	get_tree().quit()
