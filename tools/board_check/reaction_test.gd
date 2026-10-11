## Dev tool: starts a game and gives players cookies and cakes, to see the cheering and sulking and the floating numbers.
## SHOTS_DIR=/tmp/react godot --path . res://tools/board_check/reaction_test.tscn
extends Node

var dir := ""


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func snap(n: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	get_viewport().get_texture().get_image().save_png(dir.path_join(n + ".png"))


func server_controller() -> Node:
	for n in get_tree().get_nodes_in_group("Controller"):
		if get_node("/root/Server").is_ancestor_of(n):
			return n
	return null


func _ready() -> void:
	dir = OS.get_environment("SHOTS_DIR") if OS.get_environment("SHOTS_DIR") != "" else "user://react"
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
	var ctrl := server_controller()
	# look at the players on the client side
	for n in get_tree().get_nodes_in_group("Controller"):
		if get_node("/root/Client").is_ancestor_of(n):
			n.camera_focus = n.players[0]
	await wait(3.0)
	var p = ctrl.players
	p[0].cookies += 5
	p[1].cookies -= 3
	p[2].cakes += 1
	for i in 6:
		await wait(0.25)
		snap("react_%d" % i)
	print("REACT done")
	get_tree().quit()
