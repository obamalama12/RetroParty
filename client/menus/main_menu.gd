extends Control

const WebSocketClient := preload("res://client/websocket/WebSocketClient.gd")
const WebSocketApi := preload("res://client/websocket/websocket_api.gd")

@onready var server_list := $ServerList/VBoxContainer/ScrollContainer/List
var add_server_button := Button.new()

var lobby: Node

func _ready() -> void:
	# Wait with main menu music until audio options have been loaded
	$AudioStreamPlayer.play()
	$MainMenu/Buttons/Play.grab_focus()
	_make_floaters()
	_setup_button_hover()
	
	var servers: Array = get_servers()
	for server in servers:
		create_server_entry(server)
	add_server_button.text = "+"
	add_server_button.pressed.connect(_on_ServerList_server_add)
	server_list.add_child(add_server_button)
	
	var current_server := Global.get_current_server()
	if current_server and Global.is_local_multiplayer():
		open_lobby(current_server.current_lobby)
		current_server.current_lobby.refresh()
	elif current_server:
		_on_connection_succeeded(current_server)
		$MainMenu.hide()

var _time := 0.0
var _floaters: Array[Control] = []

# The logo sways a little, the glow behind the mascot breathes and cookies and cakes drift around
func _process(delta: float) -> void:
	_time += delta
	var logo := $MainMenu/TextureRect
	logo.rotation = deg_to_rad(sin(_time * 1.1) * 1.3)
	var k := 0.47 + sin(_time * 1.7) * 0.006
	logo.scale = Vector2(k, k)
	$MainMenu/Glow.modulate.a = 0.5 + 0.1 * sin(_time * 1.3)
	var mascot: Control = $MainMenu/Mascot
	mascot.rotation = deg_to_rad(sin(_time * 1.6) * 2.2)
	mascot.position.y = 50.0 - absf(sin(_time * 2.4)) * 16.0
	var squash := 1.0 + sin(_time * 4.8 + 1.0) * 0.012
	mascot.scale = Vector2(1.0 / squash, squash)
	var glove: Control = $MainMenu/Glove
	glove.visible = $MainMenu.visible and $MainMenu/Buttons.visible
	var target := _glove_target + Vector2(sin(_time * 5.0) * 6.0, 0.0)
	glove.position = glove.position.lerp(target, clampf(delta * 14.0, 0.0, 1.0))
	for i in _floaters.size():
		var f := _floaters[i]
		var base: Vector2 = f.get_meta("base")
		f.position = base + Vector2(sin(_time * 0.6 + i) * 14.0, sin(_time * 0.9 + i * 1.7) * 18.0)
		f.rotation = sin(_time * 0.7 + i * 2.3) * 0.35

func _make_floaters() -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(holder)
	move_child(holder, 2)
	var textures := [
		preload("res://common/scenes/board_logic/controller/icons/cookie.png"),
		preload("res://common/scenes/board_logic/controller/icons/cake.png"),
	]
	var spots := [Vector2(700, 90), Vector2(1170, 120), Vector2(610, 330), Vector2(1190, 380),
			Vector2(720, 600), Vector2(1120, 610), Vector2(560, 80)]
	for i in spots.size():
		var tr := TextureRect.new()
		tr.texture = textures[i % 2]
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.custom_minimum_size = Vector2(1, 1)
		tr.size = Vector2.ONE * (46 + (i * 13) % 30)
		tr.pivot_offset = tr.size / 2
		tr.modulate = Color(1, 1, 1, 0.6)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tr.set_meta("base", spots[i])
		holder.add_child(tr)
		_floaters.append(tr)

var _glove_target := Vector2(14, 340)

# The pointing glove sits next to the focused button and bobs a little
func _point_glove_at(button: Control) -> void:
	_glove_target = button.global_position - $MainMenu.global_position + Vector2(-84, button.size.y / 2 - 40)

# Buttons grow a little when hovered or focused
func _setup_button_hover() -> void:
	for button: Control in $MainMenu/Buttons.get_children():
		button.focus_entered.connect(_point_glove_at.bind(button))
		button.mouse_entered.connect(_point_glove_at.bind(button))
		button.resized.connect(func(): button.pivot_offset = button.size / 2)
		var grow := func(to: float):
			var tween := create_tween()
			tween.tween_property(button, "scale", Vector2.ONE * to, 0.12).set_trans(Tween.TRANS_BACK)
		button.mouse_entered.connect(grow.bind(1.05))
		button.focus_entered.connect(grow.bind(1.05))
		button.mouse_exited.connect(grow.bind(1.0))
		button.focus_exited.connect(grow.bind(1.0))

#*** Options menu ***#

func _on_Options_pressed() -> void:
	$Animation.play_backwards("MainMenu")
	await $Animation.animation_finished
	$MainMenu/Buttons.hide()
	$MainMenu/Mascot.hide()
	$OptionsMenu.show()
	$Animation.play("OptionsMenu")
	$OptionsMenu/OptionsMenu/Menu/Back.grab_focus()

func _on_OptionsMenu_quit() -> void:
	$OptionsMenu/OptionsMenu/Menu/Back.disabled = true
	$Animation.play_backwards("OptionsMenu")
	await $Animation.animation_finished
	$OptionsMenu.hide()
	$MainMenu/Buttons.show()
	$OptionsMenu/OptionsMenu/Menu/Back.disabled = false
	$MainMenu/Mascot.show()
	$Animation.play("MainMenu")
	$MainMenu/Buttons/Options.grab_focus()

#*** Amount of players menu ***#

func _on_Play_pressed() -> void:
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	lobby = await game.create_lobby()
	if not lobby:
		Global.destroy_local_server()
		return
	open_lobby(lobby)

func open_lobby(lobby: Lobby) -> void:
	var lobby_menu = preload("res://client/menus/lobby/lobby_menu.tscn").instantiate()
	lobby_menu.lobby = lobby
	lobby_menu.mainmenu = self
	add_child(lobby_menu)
	$MainMenu.hide()

func _on_Play2_pressed() -> void:
	$MainMenu.hide()
	$ServerList.show()
	$ServerList/VBoxContainer/Footer/Leave.grab_focus()

#*** Load game menu ***#

func _on_Load_pressed() -> void:
	Global.savegame_loader.read_savegames()
	var savegame_template: PackedScene =\
			preload("res://client/savegames/savegame_entry.tscn")
	for i in Global.savegame_loader.get_num_savegames():
		var savegame_entry := savegame_template.instantiate() as Control
		var savegame := Global.savegame_loader.get_savegame(i)
		var filename := Global.savegame_loader.get_filename(i)
		savegame_entry.get_node("Load").text = filename

		savegame_entry.get_node("Load").pressed.connect(_on_SaveGame_Load_pressed.bind(filename, savegame))
		savegame_entry.get_node("Delete").pressed.connect(_on_SaveGame_Delete_pressed.bind(filename, savegame_entry))

		$LoadGameMenu/ScrollContainer/Saves.add_child(savegame_entry)

	$Animation.play_backwards("MainMenu")
	await $Animation.animation_finished
	$MainMenu/Buttons.hide()
	$LoadGameMenu.show()
	$Animation.play("LoadGameMenu")
	if $LoadGameMenu/ScrollContainer/Saves.get_child_count() > 0:
			$LoadGameMenu/ScrollContainer/Saves.\
					get_child(0).get_child(0).grab_focus()
	else:
		$LoadGameMenu/Back.grab_focus()

func _on_SaveGame_Load_pressed(filename: String, savegame: SaveGameLoader.SaveGame) -> void:
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	lobby = await game.create_lobby()
	if not lobby:
		Global.destroy_local_server()
		return
	open_lobby(lobby)
	lobby.load_savegame(filename, savegame)
	$LoadGameMenu.hide()

func _on_SaveGame_Delete_pressed(filename: String, node: Control) -> void:
	var index: int = node.get_index()
	node.queue_free()
	$LoadGameMenu/ScrollContainer/Saves.remove_child(node)

	var num_children: int =\
			$LoadGameMenu/ScrollContainer/Saves.get_child_count()
	if num_children > 0:
		# warning-ignore:narrowing_conversion
		$LoadGameMenu/ScrollContainer/Saves.get_child(
				min(index, num_children - 1)).get_child(0).grab_focus()
	else:
		$LoadGameMenu/Back.grab_focus()

	Global.savegame_loader.delete_savegame(filename)

func _on_LoadGame_Back_pressed() -> void:
	for i in $LoadGameMenu/ScrollContainer/Saves.get_children():
		i.queue_free()

	$LoadGameMenu/Back.disabled = true
	$Animation.play_backwards("LoadGameMenu")
	await $Animation.animation_finished
	$LoadGameMenu.hide()
	$MainMenu/Buttons.show()
	$LoadGameMenu/Back.disabled = false
	$Animation.play("MainMenu")
	$MainMenu/Buttons/Load.grab_focus()

func _on_Minigames_pressed() -> void:
	var menu := preload("res://client/menus/minigame_test_menu.gd").new()
	menu.back.connect(func():
		menu.queue_free()
		$MainMenu.show()
		$MainMenu/Buttons/Minigames.grab_focus())
	add_child(menu)
	$MainMenu.hide()

func _on_Quit_pressed() -> void:
	get_tree().quit()

func _on_Screenshots_pressed():
	OS.shell_open("file://{0}/screenshots".format([OS.get_user_data_dir()]))

#*** Server List Menu ***#

func _on_ServerList_Leave_pressed() -> void:
	$ServerList.hide()
	$MainMenu.show()
	$MainMenu/Buttons/Play2.grab_focus()

func _on_ServerList_server_add():
	var form := preload("res://client/menus/server_list_add_entry.tscn").instantiate()
	form.confirmed.connect(_on_ServerList_server_added.bind(form))
	form.canceled.connect(form.queue_free)
	server_list.add_child(form)
	# Make the "+" button the last child again
	add_server_button.move_to_front()

func get_servers() -> Array:
	return Global.storage.get_value("ServerList", "servers", [])

func save_servers(servers: Array):
	Global.storage.set_value("ServerList", "servers", servers)
	Global.save_storage()

func _on_ServerList_server_added(data: Dictionary, form: Node):
	form.queue_free()
	# Save to disk
	var servers: Array = get_servers()
	servers.append(data)
	save_servers(servers)
	# Add to menu
	var entry := create_server_entry(data)
	entry.get_child(0).grab_focus()
	# Make the "+" button the last child again
	add_server_button.move_to_front()

func _on_ServerList_server_edit(entry: Node):
	var form := preload("res://client/menus/server_list_add_entry.tscn").instantiate()
	form.load(get_servers()[entry.get_index()])
	form.confirmed.connect(_on_ServerList_server_replace.bind(form, entry))
	form.canceled.connect(func():
		form.add_sibling(entry)
		form.queue_free())
	entry.add_sibling(form)
	entry.get_parent().remove_child(entry)

func _on_ServerList_server_replace(data: Dictionary, form: Node, old_entry: Node):
	old_entry.free()
	var servers: Array = get_servers()
	servers[form.get_index()] = data
	save_servers(servers)
	var entry := create_server_entry(data)
	entry.get_parent().move_child(entry, form.get_index())
	entry.get_child(0).grab_focus()
	form.queue_free()

func _on_ServerList_server_delete(entry: Node):
	var idx := entry.get_index()
	entry.get_parent().remove_child(entry)
	entry.queue_free()
	if idx < server_list.get_child_count() - 1:
		server_list.get_child(idx).get_child(0).grab_focus()
	else:
		add_server_button.grab_focus()
	var servers: Array = get_servers()
	servers.remove_at(idx)
	save_servers(servers)

func create_server_entry(data) -> Container:
	var container := HBoxContainer.new()
	var edit := Button.new()
	edit.icon = preload("res://assets/icons/edit.png")
	var delete := Button.new()
	delete.icon = preload("res://assets/icons/delete.png")
	var button := Button.new()
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if data is Dictionary:
		button.text = data["display_name"]
		button.pressed.connect(remote_server.bind(data["host"], data["port"]))
	else:
		button.text = data
		button.pressed.connect(remote_server.bind(data, ProjectSettings.get("server/port")))
	edit.pressed.connect(_on_ServerList_server_edit.bind(container))
	delete.pressed.connect(_on_ServerList_server_delete.bind(container))
	container.add_child(button)
	container.add_child(edit)
	container.add_child(delete)
	server_list.add_child(container)
	return container

func format_url(host: String, port: int):
	if ":" in host:
		# Assume it's ipv6 (otherwise it's invalid anyway)
		return "[{0}]:{1}".format([host, port])
	return "{0}:{1}".format([host, port])

func check_version(host: String, port: int) -> bool:
	# Version precheck
	var websocket := WebSocketClient.new()
	var err := websocket.connect_to_url("ws://" + format_url(host, port))
	if err != Error.OK:
		push_error("Failed to connect to websocket: " + error_string(err))
		$AcceptDialog.title = "MENU_LABEL_CONNECTION_ERROR"
		$AcceptDialog.dialog_text = "MENU_LABEL_CONNECTION_TIMEOUT"
		$AcceptDialog.popup_centered()
		return false
	add_child(websocket)
	websocket.connection_closed.connect(func():
		$LoadAnimation.hide()
		websocket.queue_free()
		websocket = null)
	
	var api := WebSocketApi.new(websocket)
	var response := await api.get_version()
	websocket.close()
	
	if response == null:
		$AcceptDialog.title = "MENU_LABEL_CONNECTION_ERROR"
		$AcceptDialog.dialog_text = "MENU_LABEL_CONNECTION_TIMEOUT"
		$AcceptDialog.popup_centered()
		return false
	elif response.error != null:
		$AcceptDialog.title = "MENU_LABEL_CONNECTION_ERROR_TITLE"
		$AcceptDialog.dialog_text = response.error.message
		$AcceptDialog.popup_centered()
		return false
	elif not Global.VERSION.is_compatible(response.content):
		$AcceptDialog.title = "MENU_LABEL_VERSION_MISMATCH_TITLE"
		$AcceptDialog.dialog_text = tr("MENU_LABEL_VERSION_MISMATCH").format(
			{
				'local': Global.VERSION.format(),
				'remote': response.content.format()
			})
		$AcceptDialog.popup_centered()
		return false
	return true

func remote_server(host: String, port: int) -> void:
	$LoadAnimation.show()
	
	if not await check_version(host, port):
		return
	
	# Now connect to the game server
	var server := Global.connect_remote_server(host, port)
	if server == null:
		$AcceptDialog.title = "MENU_LABEL_CONNECTION_ERROR"
		$AcceptDialog.dialog_text = "MENU_LABEL_CONNECTION_TIMEOUT"
		$AcceptDialog.popup_centered()
		return
	var conn := server.multiplayer
	conn.connection_failed.connect(_on_connection_failed, CONNECT_DEFERRED)
	conn.connected_to_server.connect(_on_connection_succeeded.bind(server), CONNECT_DEFERRED)
	$LoadAnimation/Cancel.grab_focus()

func _on_connection_failed():
	$LoadAnimation.hide()
	$AcceptDialog.title = "MENU_LABEL_CONNECTION_ERROR"
	$AcceptDialog.dialog_text = "MENU_LABEL_CONNECTION_TIMEOUT"
	$AcceptDialog.popup_centered()
	Global.shutdown_connection()

func _on_connection_succeeded(server):
	$LoadAnimation.hide()
	var servermenu = preload("res://client/menus/lobby/servermenu.tscn").instantiate()
	servermenu.server = server
	servermenu.mainmenu = self
	add_child(servermenu)
	$ServerList.hide()
