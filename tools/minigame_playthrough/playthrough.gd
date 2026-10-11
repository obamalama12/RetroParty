## Dev tool: plays every minigame once with bot input and saves screenshots.
## See README.md in this folder.
extends Node

var SHOTS := (OS.get_environment("SHOTS_DIR") if OS.get_environment("SHOTS_DIR") != "" else "user://playthrough_shots").path_join("")
const TYPES := {"Duel": 0, "1v3": 1, "2v2": 2, "FFA": 3, "NolokSolo": 4, "NolokCoop": 5, "GnuSolo": 6, "GnuCoop": 7}
var client_lobby
var server_lobby

func log_(m): print("DRV ", m)
func wait(s: float): await get_tree().create_timer(s).timeout
func shot(n: String):
	DirAccess.make_dir_recursive_absolute(SHOTS)
	get_viewport().get_texture().get_image().save_png(SHOTS.path_join(n + ".png"))

func find_server_lobby():
	for c in get_node("/root/Server/Game").get_children():
		if "minigame_queue" in c: return c
func find_ctrl(root: Node):
	for n in get_tree().get_nodes_in_group("Controller"):
		if root.is_ancestor_of(n): return n

func _ready():
	await wait(1.0)
	var game := Global.create_local_server()
	await game.multiplayer.connected_to_server
	client_lobby = await game.create_lobby()
	log_("lobby created")
	await wait(1.0)
	client_lobby.set_player_name(0, "Tester")
	client_lobby.select_character(0, OS.get_environment("CHARACTER") if OS.get_environment("CHARACTER") != "" else "Businessman")
	client_lobby.select_board("RetroValley")
	await wait(1.0)
	client_lobby.start()
	server_lobby = find_server_lobby()
	var t := 0.0
	while not (find_ctrl(client_lobby.get_parent().get_parent()) if false else get_tree().get_nodes_in_group("Controller").size() >= 2) and t < 60:
		await wait(0.5); t += 0.5
	log_("board up after %s s, controllers=%d" % [t, get_tree().get_nodes_in_group("Controller").size()])
	await wait(8.0)
	shot("board")
	var only: String = OS.get_environment("ONLY")
	for cfg in PluginSystem.minigame_loader.get_minigames():
		var mname: String = cfg.scene_path.get_base_dir().get_file()
		if only != "" and not (mname in only.split(",")): continue
		for ty in cfg.type:
			if OS.get_environment("TYPE") != "" and ty != OS.get_environment("TYPE"):
				continue
			await run_minigame(cfg, mname, ty)
	log_("ALL DONE")
	get_tree().quit()

func run_minigame(cfg, mname: String, ty: String):
	var type: int = TYPES[ty]
	var label := mname + "_" + ty.replace(" ", "")
	log_("BEGIN " + label)
	var state = Lobby.MinigameState.new()
	state.minigame_config = cfg
	state.minigame_type = type
	state.is_try = true
	match type:
		0: state.minigame_teams = [[1], [2]]
		1: state.minigame_teams = [[1, 2, 3], [4]]
		2: state.minigame_teams = [[1, 3], [2, 4]]
		3, 5, 7: state.minigame_teams = [[1, 2, 3, 4], []]
		4, 6: state.minigame_teams = [[1], []]
	if type == 0:
		server_lobby.minigame_reward = Lobby.MinigameReward.new()
		server_lobby.minigame_reward.duel_reward = Lobby.MINIGAME_DUEL_REWARDS.TEN_COOKIES
	if type == 6:
		var items: Array = PluginSystem.item_loader.get_buyable_items()
		server_lobby.minigame_reward = Lobby.MinigameReward.new()
		server_lobby.minigame_reward.gnu_solo_item_reward = load(items[0]).new()
	server_lobby.minigame_state = state
	var ctrl = Utility.get_nodes_in_group(server_lobby, "Controller")[0]
	ctrl.has_rolled = true
	server_lobby.broadcast(ctrl.splash_ended)
	server_lobby.broadcast(ctrl.show_minigame.bind(state.encode()))
	await wait(6.0)
	shot(label + "_info")
	client_lobby.goto_minigame(true)
	var lt := 0.0
	await wait(1.0)
	while lt < 120 and (_find_scene(cfg.scene_path) == null or _find_scene("res://client/menus/loading_screen.tscn") != null):
		await wait(0.5); lt += 0.5
	var loaded = _find_scene(cfg.scene_path)
	log_("%s: minigame scene %s after %.1f s" % [label, "LOADED" if loaded else "NOT LOADED", lt])
	await wait(3.0)
	shot(label + "_a")
	var acts := ["up", "down", "left", "right", "action1", "action2"]
	if OS.get_environment("UNTIL_END") != "":
		# play until the game ends by itself (the bots play, player 1 presses random buttons) and report how long it took
		var cap := float(OS.get_environment("CAP")) if OS.get_environment("CAP") != "" else 150.0
		var began := Time.get_ticks_msec()
		var shots := 0
		while (Time.get_ticks_msec() - began) / 1000.0 < cap and _find_scene(cfg.scene_path) != null:
			var a := "player1_%s" % acts[randi() % acts.size()]
			Input.action_press(a)
			await wait(0.25)
			Input.action_release(a)
			await wait(0.15)
			if (Time.get_ticks_msec() - began) / 1000.0 > shots * 8.0 + 4.0:
				shots += 1
				shot("%s_t%02d" % [label, shots])
		var secs := (Time.get_ticks_msec() - began) / 1000.0 + 3.0
		log_("DURATION %s %.0f s %s" % [label, secs, "(CAP, still running)" if _find_scene(cfg.scene_path) != null else ""])
		if _find_scene(cfg.scene_path) == null:
			await wait(6.0)
			log_("END %s" % label)
			return
	for i in 20:
		for p in 4:
			var a := "player%d_%s" % [p + 1, acts[randi() % acts.size()]]
			Input.action_press(a)
		await wait(0.5)
		Input.flush_buffered_events()
		for p in 4:
			for a in acts: Input.action_release("player%d_%s" % [p + 1, a])
	shot(label + "_b")
	# return to board (try mode avoids reward screens)
	if server_lobby.minigame_state:
		server_lobby.minigame_state.is_try = true
		server_lobby.minigame_state.heat_results = []
		server_lobby._goto_board([[1, 2, 3, 4]])
	var t := 0.0
	await wait(3.0)
	while t < 60 and not _board_ready():
		await wait(0.5); t += 0.5
	await wait(2.0)
	log_("END %s (board back after %.1f s, ready=%s)" % [label, t + 3.0, _board_ready()])

func _board_ready() -> bool:
	return server_lobby != null and Utility.get_nodes_in_group(server_lobby, "Controller").size() > 0

func _find_scene(path: String):
	var stack: Array = [get_node("/root/Client")]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.scene_file_path == path and not n.is_queued_for_deletion(): return n
		stack.append_array(n.get_children())
	return null
