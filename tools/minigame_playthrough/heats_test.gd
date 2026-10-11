## Dev tool: plays a minigame with several heats for real (not as a try) and logs the result of every heat and the
## combined result. MINIGAME_RESULT_LOG=1 ONLY=escape_from_lava TYPE=FFA godot --path . res://tools/minigame_playthrough/heats_test.tscn
extends "res://tools/minigame_playthrough/playthrough.gd"


func _ready():
	await wait(1.0)
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	client_lobby = await game.create_lobby()
	await wait(1.0)
	client_lobby.set_player_name(0, "Tester")
	client_lobby.select_character(0, "Businessman")
	client_lobby.select_board("RetroValley")
	await wait(1.0)
	client_lobby.start()
	server_lobby = find_server_lobby()
	var t := 0.0
	while get_tree().get_nodes_in_group("Controller").size() < 2 and t < 60:
		await wait(0.5)
		t += 0.5
	await wait(8.0)
	var only: String = OS.get_environment("ONLY")
	var want_type: String = OS.get_environment("TYPE")
	for cfg in PluginSystem.minigame_loader.get_minigames():
		var mname: String = cfg.scene_path.get_base_dir().get_file()
		if only != "" and not (mname in only.split(",")):
			continue
		for ty in cfg.type:
			if want_type != "" and ty != want_type:
				continue
			await play_for_real(cfg, mname, ty)
	log_("ALL DONE")
	get_tree().quit()


func play_for_real(cfg, mname: String, ty: String) -> void:
	var label := mname + "_" + ty
	log_("BEGIN " + label + " heats=" + str(cfg.heats))
	var state = Lobby.MinigameState.new()
	state.minigame_config = cfg
	state.minigame_type = TYPES[ty]
	match TYPES[ty]:
		0: state.minigame_teams = [[1], [2]]
		1: state.minigame_teams = [[1, 2, 3], [4]]
		2: state.minigame_teams = [[1, 3], [2, 4]]
		_: state.minigame_teams = [[1, 2, 3, 4], []]
	if TYPES[ty] == 0:
		server_lobby.minigame_reward = Lobby.MinigameReward.new()
		server_lobby.minigame_reward.duel_reward = Lobby.MINIGAME_DUEL_REWARDS.TEN_COOKIES
	server_lobby.minigame_state = state
	var ctrl = Utility.get_nodes_in_group(server_lobby, "Controller")[0]
	ctrl.has_rolled = true
	server_lobby.broadcast(ctrl.splash_ended)
	server_lobby.broadcast(ctrl.show_minigame.bind(state.encode()))
	await wait(6.0)
	shot(label + "_info")
	client_lobby.goto_minigame(false)
	var began := Time.get_ticks_msec()
	await wait(3.5)
	shot(label + "_card")
	var loads := 0
	var seen_scene := false
	# the bots play; wait until the board is back (the reward screen needs a press of ok)
	while (Time.get_ticks_msec() - began) / 1000.0 < 240.0:
		await wait(1.0)
		var scene = _find_scene(cfg.scene_path)
		if scene != null and not seen_scene:
			seen_scene = true
			loads += 1
			log_("%s: heat scene loaded (#%d) after %.0f s" % [label, loads, (Time.get_ticks_msec() - began) / 1000.0])
		elif scene == null:
			seen_scene = false
		var press := InputEventAction.new()
		press.action = "player1_ok"
		press.pressed = true
		Input.parse_input_event(press)
		await wait(0.1)
		press = InputEventAction.new()
		press.action = "player1_ok"
		press.pressed = false
		Input.parse_input_event(press)
		if loads >= 1 and _board_ready() and not seen_scene and (Time.get_ticks_msec() - began) / 1000.0 > 20.0:
			break
	log_("END %s after %.0f s, scenes loaded: %d" % [label, (Time.get_ticks_msec() - began) / 1000.0, loads])
