## Dev tool: starts a game, ends round one and takes screenshots of the minigame vote (and the tie animation).
## SHOTS_DIR=/tmp/vote godot --path . res://tools/board_check/vote_test.tscn
extends Node

var dir := ""


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func snap(n: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir.path_join(n + ".png"))


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
	await wait(0.3)


func server_controller() -> Node:
	for n in get_tree().get_nodes_in_group("Controller"):
		if get_node("/root/Server").is_ancestor_of(n):
			return n
	return null


func _ready() -> void:
	dir = OS.get_environment("SHOTS_DIR") if OS.get_environment("SHOTS_DIR") != "" else "user://vote"
	await wait(1.0)
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	var lobby = await game.create_lobby()
	await wait(1.0)
	lobby.set_player_name(0, "Tester")
	lobby.select_character(0, "Businessman")
	lobby.select_board("RetroValley")
	await wait(1.0)
	lobby.start()
	for i in 90:
		await wait(1.0)
		if server_controller() != null and server_controller().players.size() == 4:
			break
	await wait(6.0)
	var ctrl := server_controller()
	ctrl.prepare_minigame()
	await wait(2.0)
	snap("vote_1_open")
	await press("player1_right")
	await press("player1_ok")
	snap("vote_2_voted")
	# Bots vote after up to 3 s, then the result follows
	for i in 16:
		await wait(0.5)
		snap("vote_3_%02d" % i)
	print("VOTE minigame chosen: ", ctrl.lobby.minigame_state.minigame_config.filename if ctrl.lobby.minigame_state else "none yet")
	await wait(4.0)
	print("VOTE minigame chosen: ", ctrl.lobby.minigame_state.minigame_config.filename if ctrl.lobby.minigame_state else "none")
	get_tree().quit()
