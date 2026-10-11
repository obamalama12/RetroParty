## Dev tool: plays board -> minigame -> reward screen -> board a few times and reports problems.
##
## BOARD=RetroValley ROUNDS=2 godot --path . res://tools/round_trip/round_trip.tscn
extends Node


func wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func find_with(root: Node, prop: String) -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if prop in n and n.get_script():
			return n
		stack.append_array(n.get_children())
	return null


func server_controller() -> Node:
	for n in get_tree().get_nodes_in_group("Controller"):
		if get_node("/root/Server").is_ancestor_of(n):
			return n
	return null


func wait_for(cond: Callable, timeout: float, what: String) -> bool:
	var t := 0.0
	while t < timeout:
		if cond.call():
			return true
		await wait(0.5)
		t += 0.5
	print("RT TIMEOUT waiting for ", what)
	return false


func _ready() -> void:
	var board_name := OS.get_environment("BOARD") if OS.get_environment("BOARD") != "" else "RetroValley"
	var rounds := int(OS.get_environment("ROUNDS")) if OS.get_environment("ROUNDS") != "" else 2
	await wait(1.0)
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	var lobby = await game.create_lobby()
	await wait(1.0)
	lobby.set_player_name(0, "Tester")
	lobby.select_character(0, "Businessman")
	lobby.select_board(board_name)
	await wait(1.0)
	lobby.start()
	if not await wait_for(func(): return server_controller() != null and server_controller().players.size() == 4, 90, "board"):
		get_tree().quit(1)
		return
	await wait(6.0)
	var slobby = find_with(get_node("/root/Server"), "minigame_state")
	var clobby = find_with(get_node("/root/Client"), "minigame_state")
	print("RT lobbies ", slobby, " ", clobby)
	for r in range(rounds):
		var ctrl := server_controller()
		print("RT round ", r, " starting minigame")
		ctrl.prepare_minigame()
		if not await wait_for(func(): return slobby.minigame_state != null, 60, "minigame state"):
			break
		await wait(2.0)
		clobby.goto_minigame(false)
		await wait_for(func(): return get_tree().get_nodes_in_group("players").size() > 0 and server_controller() == null, 60, "minigame scene")
		await wait(9.0)   # the how-to-play card and the countdown run first
		print("RT in minigame ", slobby.minigame_state.minigame_config.filename if slobby.minigame_state else "?")
		# end it with player 1 winning (a game with several heats needs this once per heat)
		var heats: int = slobby.minigame_state.minigame_config.heats
		for heat in heats:
			match slobby.minigame_state.minigame_type:
				Lobby.MINIGAME_TYPES.FREE_FOR_ALL:
					slobby.minigame_win_by_position([1, 2, 3, 4])
				Lobby.MINIGAME_TYPES.TWO_VS_TWO:
					slobby.minigame_team_win(0)
				Lobby.MINIGAME_TYPES.ONE_VS_THREE:
					slobby.minigame_1v3_win_solo_player()
				_:
					slobby.minigame_nolok_win()
			if heat < heats - 1:
				await wait(14.0)   # the next heat loads, counts down and starts
		print("RT minigame ended, waiting for reward screen / board")
		for i in 60:
			await wait(1.0)
			# press ok to get past reward screens and dialogs
			var press := InputEventAction.new()
			press.action = "player1_ok"
			press.pressed = true
			Input.parse_input_event(press)
			await wait(0.1)
			press = InputEventAction.new()
			press.action = "player1_ok"
			press.pressed = false
			Input.parse_input_event(press)
			if server_controller() != null:
				break
		if server_controller() == null:
			print("RT FAIL never returned to the board")
			get_tree().quit(1)
			return
		await wait(6.0)
		print("RT back on board after round ", r, " turn ", slobby.turn if "turn" in slobby else -1)
	print("RT OK")
	get_tree().quit()
