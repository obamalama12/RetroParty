## Dev tool: starts a game, saves it from the board, then loads that save game into a new lobby like the
## "Load game" button of the main menu does, and starts it.
## godot --path . res://tools/board_check/savegame_test.tscn
extends Node


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func server_controller() -> Node:
	for n in get_tree().get_nodes_in_group("Controller"):
		if has_node("/root/Server") and get_node("/root/Server").is_ancestor_of(n):
			return n
	return null


func _ready() -> void:
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
	await wait(8.0)
	lobby.savegame_name = "savegame_test"
	lobby.save_game()
	await wait(3.0)
	print("SAVE current_savegame: ", lobby.current_savegame != null)
	var saved = lobby.current_savegame
	if saved == null:
		print("SAVE FAILED")
		get_tree().quit()
		return
	Global.shutdown_connection()
	await wait(2.0)
	# like _on_SaveGame_Load_pressed of the main menu
	var game2 := Global.create_local_server()
	await game2.multiplayer.connected_to_server
	var lobby2 = await game2.create_lobby()
	print("LOAD lobby: ", lobby2 != null)
	lobby2.load_savegame("savegame_test", saved)
	await wait(3.0)
	lobby2.start()
	var ok := false
	for i in 90:
		await wait(1.0)
		if server_controller() != null and server_controller().players.size() == 4:
			ok = true
			break
	print("LOAD board up: ", ok)
	get_tree().quit()
