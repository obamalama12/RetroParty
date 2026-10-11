extends Node3D
class_name Controller

signal trigger_event(player, space)

signal path_chosen(idx)
signal item_selected(idx)

signal next_player()
signal rolled(player, num)

signal players_acknowledged()

signal _event_completed()
signal _camera_focus_aquired()

const PlayerInfo := preload("res://common/scenes/board_logic/controller/player_info.gd")

# If multiple players get on one space, this array decides the translation of
# each.
const PLAYER_TRANSLATION = [Vector3(0, 0, -0.75), Vector3(0.75, 0, 0),
		Vector3(0, 0, 0.75), Vector3(-0.75, 0, 0)]
const EMPTY_SPACE_PLAYER_TRANSLATION = Vector3(0, 0.05, 0)
const CAMERA_SPEED = 6
const FOG_DENSITY := 0.0045

# Game options that can be customized in the Godot editor
# Useful for board creation
@export var COOKIES_FOR_CAKE := 30
@export var MAX_TURNS := 6

var lobby: Lobby

# Are we the game server or a client?
var server: bool

# Array containing the player nodes.
var players: Array[PlayerBoard]

# Keeps track of whose turn it is.
var player_turn := 1

# Time the dice block needs to tumble and land before the player starts to walk
const DICE_TIME := 1.9

# Keeps track whether the current player has already rolled,
# thus preventing them from rolling multiple times during their own turn
# Reset in _on_next_player
var has_rolled := true

var wait_for_path_select := false
var wait_for_select_item := false
var wait_for_duel_selection := false

var camera_focus: Node3D

# Camera zoom: distance added behind the camera, along its viewing direction.
# Mouse wheel, +/- and Page Up/Down zoom, Z toggles a far overview of the board.
const ZOOM_MIN := -1.5
const ZOOM_MAX := 48.0
const ZOOM_OVERVIEW := 42.0
var zoom_target := 0.0
var zoom_current := 0.0
var zoom_before_overview := 0.0
var camera_base_position := Vector3.ZERO

enum EDITOR_NODE_LINKING_DISPLAY {
	DISABLED,
	NEXT_NODES,
	PREV_NODES,
	ALL
}

# Path to the node, where Players start.
@export var start_node: NodePath
@export var show_linking_type := EDITOR_NODE_LINKING_DISPLAY.ALL

# Stores the value of steps that still need to be performed after a dice roll.
# Used for display.
var step_count := 0

func _ready() -> void:
	_add_zoom_hint()
	# Force the display to stay empty until the server set up everything
	$Screen/BeforeSetupCurtain.show()
	lobby = Lobby.get_lobby(self)

	server = multiplayer.is_server()
	# We need to convert Array[Node] from get_nodes_in_group to
	# Array[PlayerBoard]
	# As this cannot be cast directly (yet?) by GDScript and the typed Array
	# constructor is verbose and non-trivial for this case, this seemed like
	# the easiest solution
	players = []
	players.append_array(Utility.get_nodes_in_group(lobby, "players"))
	for p in players:
		p.controller = self

	# The vote for the minigame of the round. Created in code, so it exists with the same path on server and clients
	var minigame_vote := preload("res://common/scenes/board_logic/controller/minigamevote.gd").new()
	minigame_vote.name = "MinigameVote"
	$Screen.add_child(minigame_vote)

	# set up player info box
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for p in players:
		const PlayerInfoContainer := preload("res://common/scenes/board_logic/controller/player_info.tscn")
		%PlayerInfo.add_child(spacer.duplicate())
		%PlayerInfo.add_child(PlayerInfoContainer.instantiate())
	%PlayerInfo.add_child(spacer)

	if server:
		next_player.connect(_on_next_player)
		rolled.connect(do_step)
		lobby.player_left.connect(_on_player_disconnected)
		lobby.load_board_state(self)
		lobby.broadcast(set_turn.bind(lobby.turn, lobby.overrides.max_turns))
		# Teleporting to the start position needs a valid space for each player
		# Therefore, we use 2 loops to set this stuff up
		for p in players:
			if not p.space:
				p.space = get_node(start_node)
			p.teleport_to(p.space)
			p.update_client()
		lobby.broadcast(_setup_finished)
	else:
		var pause_menu = load("res://client/menus/pause_menu.tscn").instantiate()
		pause_menu.can_save_game = true
		$Screen.add_child(pause_menu)
		for p in players:
			# Update the "spaces to walk" counter
			p.walking_step.connect(animation_step.bind(p.info.player_id))
			# Play a short fx when passing a step
			p.walking_step.connect(play_space_step_sfx.bind(p.info.player_id))

	if not server:
		if player_turn <= players.size():
			camera_focus = players[player_turn - 1]

		update_player_info()

	$Screen/Debug.setup()
	if lobby.minigame_summary:
		# Do some moderation according to the last minigame type being played
		if server:
			match lobby.minigame_summary.state.minigame_type:
				Lobby.MINIGAME_TYPES.GNU_SOLO:
					var player_id = player_turn
					players[player_id - 1].give_item(Item.deserialize(lobby.minigame_summary.reward))
					player_turn += 1
					# TODO: better timeouts
					await get_tree().create_timer(5.0).timeout
				Lobby.MINIGAME_TYPES.GNU_COOP:
					player_turn += 1
					await get_tree().create_timer(5.0).timeout
				Lobby.MINIGAME_TYPES.NOLOK_SOLO:
					player_turn += 1
					await get_tree().create_timer(5.0).timeout
				Lobby.MINIGAME_TYPES.NOLOK_COOP:
					player_turn += 1
					await get_tree().create_timer(5.0).timeout
		else:
			match lobby.minigame_summary.state.minigame_type:
				Lobby.MINIGAME_TYPES.GNU_SOLO:
					var player_id = player_turn
					if lobby.minigame_summary.placement:
						$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", "CONTEXT_GNU_SOLO_VICTORY", player_id)
					else:
						$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", "CONTEXT_GNU_SOLO_LOSS", player_id)
				Lobby.MINIGAME_TYPES.GNU_COOP:
					var player_id = player_turn
					if lobby.minigame_summary.placement:
						$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", "CONTEXT_GNU_COOP_VICTORY", player_id)
					else:
						$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", "CONTEXT_GNU_COOP_LOSS", player_id)
				Lobby.MINIGAME_TYPES.NOLOK_SOLO:
					var player_id = player_turn
					if lobby.minigame_summary.placement:
						$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", "CONTEXT_NOLOK_SOLO_VICTORY", player_id)
					else:
						$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", "CONTEXT_NOLOK_SOLO_LOSS", player_id)
				Lobby.MINIGAME_TYPES.NOLOK_COOP:
					var player_id = player_turn
					if lobby.minigame_summary.placement:
						$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", "CONTEXT_NOLOK_COOP_VICTORY", player_id)
					else:
						$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", "CONTEXT_NOLOK_COOP_LOSS", player_id)

#	if not server:
#		if Global.storage.get_value("Controller", "show_tutorial", true):
#			if yield(ask_yes_no("CONTEXT_SHOW_TUTORIAL"), "completed"):
#				yield(show_tutorial(), "completed")
#			Global.storage.set_value("Controller", "show_tutorial", false)
#			Global.save_storage()

	if server:
		if lobby.cake_space.is_empty():
			await relocate_cake()
		else:
			lobby.broadcast(show_cake_space.bind(lobby.cake_space))
		if lobby.minigame_state:
			# If we did try the minigame out, the minigame_state will be set
			# Therefore we still have to play the minigame
			lobby.broadcast(show_minigame.bind(lobby.minigame_state.encode()))
		else:
			# Continue with the board action
			next_player.emit()

func acknowledge():
	client_acknowledged.rpc_id(1)

func _on_player_disconnected(player_id: int):
	# when a player has left/kicked, the AI must continue currently active actions
	if player_id != player_turn:
		return
	var player: PlayerBoard = players[player_turn - 1]
	# This includes:
	# * Start your turn
	if not has_rolled:
		_on_Roll_pressed()
	# * Item Shopping
	elif $Screen/Shop.current_player:
		$Screen/Shop.end_shopping()
	# * Item Selection
	elif wait_for_select_item:
		wait_for_select_item = false
		item_selected.emit(randi() % len(player.items))
	# * Path Selection
	elif wait_for_path_select:
		wait_for_path_select = false
		var idx: int = randi() % player.space.next.size()
		path_chosen.emit(player.space.get_node(player.space.next[idx]))
	# * Space Selection (trap items)
	elif wait_for_duel_selection:
		var enemies: Array = players.duplicate()
		enemies.erase(player)
		var enemy_player = enemies[randi() % enemies.size()].info.player_id
		$Screen/DuelSelection.selected.emit(enemy_player)
	elif $SelectSpaceHelper.current_player:
		$SelectSpaceHelper.end_selection()

var current_timer: SceneTreeTimer = null
func player_timeout(addr: Lobby.PlayerAddress):
	lobby.kick(addr.peer_id, "Inactivity")

func start_timer_for_player(addr: Lobby.PlayerAddress):
	if lobby.timeout <= 0:
		return
	assert(current_timer == null, "A previous timer was not stopped")
	current_timer = get_tree().create_timer(lobby.timeout)
	current_timer.timeout.connect(player_timeout.bind(addr))

func cancel_timer():
	if not current_timer:
		return
	# Disconnect all callables
	for timer in current_timer.timeout.get_connections():
		current_timer.timeout.disconnect(timer["callable"])
	current_timer = null

var acknowledgements_needed := {}
var acknowledgement_timer: SceneTreeTimer = null
func acknowledgement_timeout():
	acknowledgement_timer = null
	for peer in acknowledgements_needed:
		lobby.kick(peer, "Inactivity")
	acknowledgements_needed.clear()
	players_acknowledged.emit()

func wait_for_acknowledgement():
	assert (acknowledgements_needed.is_empty(), "Nested acknowledgements")
	if lobby.timeout > 0:
		acknowledgement_timer = get_tree().create_timer(lobby.timeout)
		acknowledgement_timer.timeout.connect(acknowledgement_timeout)
	for player in players:
		if player.info.is_ai():
			continue
		acknowledgements_needed[player.info.addr.peer_id] = true

@rpc("any_peer") func client_acknowledged():
	if acknowledgements_needed.is_empty():
		return
	acknowledgements_needed.erase(multiplayer.get_remote_sender_id())
	if acknowledgements_needed.is_empty():
		if acknowledgement_timer:
			# Disconnect all callables
			for timer in acknowledgement_timer.timeout.get_connections():
				acknowledgement_timer.timeout.disconnect(timer["callable"])
			acknowledgement_timer = null
		players_acknowledged.emit()

func announce(text: String, format_args := {}):
	var current_player = players[player_turn - 1]
	var host_icon := "res://common/scenes/board_logic/controller/icons/host.png"
	$Screen/SpeechDialog.show_dialog("CONTEXT_SPEAKER_SARA", host_icon, text, current_player.info.player_id, format_args)
	await $Screen/SpeechDialog.dialog_finished

func ask_yes_no(text: String, format_args := {}):
	var current_player = players[player_turn - 1]
	var host_icon := "res://common/scenes/board_logic/controller/icons/host.png"
	$Screen/SpeechDialog.show_accept_dialog("CONTEXT_SPEAKER_SARA", host_icon, text, current_player.info.player_id, format_args)
	return await $Screen/SpeechDialog.dialog_option_taken

func query_range(text: String, minimum: int, maximum: int, start_value: int, format_args := {}):
	var current_player = players[player_turn - 1]
	var host_icon := "res://common/scenes/board_logic/controller/icons/host.png"
	$Screen/SpeechDialog.show_query_dialog("CONTEXT_SPEAKER_SARA", host_icon, text, current_player.info.player_id, minimum, maximum, start_value, format_args)
	return await $Screen/SpeechDialog.dialog_option_taken

# TODO: Provide a tutorial option in the main menu instead of at game creation?
# Then other players wouldn't need to wait for you to finish your tutorial...
func show_tutorial():
	await announce("CONTEXT_TUTORIAL_DICE")
	await announce("CONTEXT_TUTORIAL_SPACES_NORMAL")
	await announce("CONTEXT_TUTORIAL_SPACES_SPECIAL")
	await announce("CONTEXT_TUTORIAL_MINIGAMES")
	await announce("CONTEXT_TUTORIAL_MINIGAMES_FFA")
	await announce("CONTEXT_TUTORIAL_MINIGAMES_2V2")
	await announce("CONTEXT_TUTORIAL_MINIGAMES_1V3")
	await announce("CONTEXT_TUTORIAL_MINIGAMES_SPECIAL")
	await announce("CONTEXT_TUTORIAL_COOKIES")
	await announce("CONTEXT_TUTORIAL_CAKES")
	await announce("CONTEXT_TUTORIAL_END")

func get_player_by_player_id(id: int) -> PlayerBoard:
	for player in players:
		if player.info.player_id == id:
			return player
	return null

@rpc func _setup_finished():
	# We simulate a continuation of the loading screen until the server is fully set up
	# The server may have loaded the game slower than we did after all
	# This prevents us from rendering an incomplete (and broken) scene
	$Screen/BeforeSetupCurtain.free()

@rpc func set_turn(turn: int, max_turn: int):
	%Turn.text = tr("CONTEXT_LABEL_TURN_NUM").format({"turn": turn, "total": max_turn})

@rpc func cake_collected():
	var old_node = get_cake_space()
	await old_node.play_cake_collection_animation()
	old_node.cake = false
	acknowledge()

@rpc func show_cake_space(path: NodePath):
	var new_node = get_node(path)
	if not new_node is NodeBoard or not lobby.is_ancestor_of(new_node):
		# Server is misbehaving
		lobby.leave()
		return
	new_node.cake = true

@rpc func cake_relocated(path: NodePath):
	var new_node = get_node(path)
	if not new_node is NodeBoard or not lobby.is_ancestor_of(new_node):
		# Server is misbehaving
		lobby.leave()
		return
	var old_focus = camera_focus
	camera_focus = new_node
	new_node.cake = true
	await _camera_focus_aquired
	await announce("CONTEXT_CAKE_PLACED")
	camera_focus = old_focus
	await _camera_focus_aquired
	lobby.cake_space = path
	acknowledge()

func relocate_cake() -> void:
	var cake_nodes: Array = Utility.get_nodes_in_group(lobby, "cake_nodes")
	# Randomly place cake spot on board.
	if cake_nodes.size() > 0:
		if lobby.cake_space:
			var old_node = get_cake_space()
			wait_for_acknowledgement()
			lobby.broadcast(cake_collected)
			await players_acknowledged
			old_node.cake = false
			if cake_nodes.size() > 1:
				cake_nodes.remove_at(cake_nodes.find(old_node))
		var new_node: Node = cake_nodes[randi() % cake_nodes.size()]
		lobby.cake_space = get_path_to(new_node)
		new_node.cake = true

		wait_for_acknowledgement()
		lobby.broadcast(cake_relocated.bind(lobby.cake_space))
		await players_acknowledged

@rpc func client_next_player(next: int):
	if next < 1 || next > len(players):
		return
	$Screen/SpeechDialog.hide()
	player_turn = next
	show_splash()
	players[next - 1].play_reaction("jump", 1.0)

@rpc func splash_ended():
	$Screen/TurnBanner.dismiss()

@rpc func select_item(player_id: int):
	if player_id < 1 || player_id > len(players):
		return
	$Screen/ItemSelection.select_item(players[player_id - 1])
	_client_item_selected.rpc_id(1, await $Screen/ItemSelection.item_selected)

@rpc("any_peer") func _client_item_selected(idx: int):
	var info = lobby.get_player_by_id(player_turn)
	if info.addr.peer_id != multiplayer.get_remote_sender_id():
		return
	if idx < 0 or idx >= len(players[player_turn - 1].items):
		# Client is misbehaving
		lobby.kick(info.addr.peer_id, "Misbehaving Client")
		return
	item_selected.emit(idx)

func _on_next_player():
	if player_turn == 1 and server:
		await _round_start_banter()
	if player_turn <= len(players):
		has_rolled = false
		lobby.broadcast(client_next_player.bind(player_turn))
		if players[player_turn - 1].info.is_ai():
			await get_tree().create_timer(1.0).timeout
			_on_Roll_pressed()
		else:
			# Timer will be deactivated in roll()
			start_timer_for_player(players[player_turn - 1].info.addr)
	else:
		prepare_minigame()

func show_splash():
	var info := lobby.get_player_by_id(player_turn)
	var character := info.character
	$Screen/TurnBanner.play(info.name, PluginSystem.character_loader.load_character_splash(character), player_turn)
	camera_focus = players[player_turn - 1]

func _on_Roll_pressed() -> void:
	roll.rpc_id(1)

@rpc func item_placed(target: NodePath, item_data: Dictionary, player_id: int):
	var space = get_node(target)
	if not space is NodeBoard or not lobby.is_ancestor_of(space):
		# Server is misbehaving
		lobby.leave()
		return
	var item = Item.deserialize(item_data)
	if not item:
		lobby.leave()
		return
	var player = players[player_id - 1]
	space.trap = item
	space.trap_player = player
	camera_focus = space
	await get_tree().create_timer(1).timeout
	camera_focus = players[player_id - 1]
	acknowledge()

# Roll for the current player.
@rpc("any_peer", "call_local") func roll() -> void:
	var info := lobby.get_player_by_id(player_turn)
	if not info or multiplayer.get_remote_sender_id() != info.addr.peer_id:
		return
	if has_rolled:
		return
	# Timer started in _on_next_player
	cancel_timer()
	has_rolled = true
	lobby.broadcast(splash_ended)
	var player = players[player_turn - 1]
	var item: Item
	var dice_index := 0
	for k in player.items.size():
		if player.items[k].type == Item.TYPES.DICE:
			dice_index = k
			break
	if not player.info.is_ai() and player.items.size() > 1:
		# only ask which item to use when there is a choice; with just the dice the roll starts at once
		start_timer_for_player(player.info.addr)
		select_item.rpc_id(info.addr.peer_id, player_turn)
		wait_for_select_item = true
		var item_idx: int = await item_selected
		cancel_timer()
		wait_for_select_item = false
		item = player.items[item_idx]
	elif player.info.is_ai():
		item = player.items[randi() % len(player.items)]
	else:
		item = player.items[dice_index]

	# Remove the item from the inventory if it is consumed.
	if item.is_consumed:
		player.remove_item(item)
	if item.can_be_bought:
		player.add_stat("items_used")

	match item.type:
		Item.TYPES.DICE:
			var dice = item.activate(player, self)

			dice = max(dice + player.get_total_roll_modifier(), 0)
			player.roll_modifiers_count_down()
			step_count = dice
			player.add_stat("steps", dice)

			await _announce_dice(dice)
			rolled.emit(player, dice)
			lobby.broadcast(_rolled.bind(dice))
		Item.TYPES.PLACABLE:
			start_timer_for_player(player.info.addr)
			$SelectSpaceHelper.select_space(player, item.max_place_distance)
			var selected_space = await $SelectSpaceHelper.space_selected
			cancel_timer()
			selected_space.trap = item
			selected_space.trap_player = player

			wait_for_acknowledgement()
			lobby.broadcast(item_placed.bind(get_path_to(selected_space), item.serialize(), player.info.player_id))
			await players_acknowledged

			# Use default dice.
			var dice = (randi() % 6) + 1
			step_count = dice

			await _announce_dice(dice)
			rolled.emit(player, dice)
			lobby.broadcast(_rolled.bind(dice))
		Item.TYPES.ACTION:
			var result = item.activate(player, self)
			if result is Dictionary:
				result["args"]["kicker"] = "ITEM  !"
				lobby.broadcast(show_board_event.bind(result.title, result.text, result.args))
				await show_board_event(result.title, result.text, result.args)

			# Use default dice.
			var dice = (randi() % 6) + 1
			step_count = dice

			await _announce_dice(dice)
			rolled.emit(player, dice)
			lobby.broadcast(_rolled.bind(dice))
		_:
			push_error("Invalid type: %d (%s != %d)" % [item.type, typeof(item.type), TYPE_INT])

# Shows the tumbling dice block on every client and waits until it has landed.
func _announce_dice(dice: int) -> void:
	lobby.broadcast(show_dice.bind(dice))
	await get_tree().create_timer(DICE_TIME).timeout

@rpc func show_dice(dice: int):
	$Screen/DiceRoll.play(dice)

@rpc func _rolled(dice: int):
	step_count = dice
	$Screen/Stepcounter.text = str(step_count)

func prepare_minigame():
	var blue_team = []
	var red_team = []

	for p in players:
		match p.space.type:
			NodeBoard.NODE_TYPES.BLUE:
				blue_team.push_back(p.info.player_id)
			NodeBoard.NODE_TYPES.RED:
				red_team.push_back(p.info.player_id)
			_:
				if randi() % 2 == 0:
					blue_team.push_back(p.info.player_id)
				else:
					red_team.push_back(p.info.player_id)

	if blue_team.size() < red_team.size():
		var tmp = blue_team
		blue_team = red_team
		red_team = tmp

	var state = Lobby.MinigameState.new()
	state.minigame_teams = [blue_team, red_team]

	var vote_type: String
	match [blue_team.size(), red_team.size()]:
		[4, 0]:
			state.minigame_type = Lobby.MINIGAME_TYPES.FREE_FOR_ALL
			vote_type = "FFA"
		[3, 1]:
			state.minigame_type = Lobby.MINIGAME_TYPES.ONE_VS_THREE
			vote_type = "1v3"
		[2, 2]:
			state.minigame_type = Lobby.MINIGAME_TYPES.TWO_VS_TWO
			vote_type = "2v2"
	state.minigame_config = await _vote_for_minigame(vote_type)

	lobby.turn += 1
	player_turn = 1
	lobby.minigame_state = state
	lobby.broadcast(show_minigame.bind(state.encode()))

## The players vote between up to three minigames of the given type, the winner is played
func _vote_for_minigame(type: String) -> MinigameLoader.MinigameConfigFile:
	var options: Array = lobby.minigame_queue.get_vote_options(type)
	var chosen: MinigameLoader.MinigameConfigFile = options[0]
	if options.size() > 1:
		chosen = await $Screen/MinigameVote.run(options)
		lobby.minigame_stakes = 2 if $Screen/MinigameVote.winner_has_stakes else 1
	else:
		lobby.minigame_stakes = 1
	lobby.minigame_queue.choose(chosen)
	return chosen

@rpc func show_minigame(encoded_state: Array):
	var state = Lobby.MinigameState.decode(encoded_state)
	lobby.minigame_state = state
	await show_minigame_animation(state)
	show_minigame_info(state)

@rpc func select_path():
	create_choose_path_arrows(players[player_turn - 1])

@rpc("any_peer") func server_path_chosen(idx: int):
	if not is_multiplayer_authority():
		return
	if player_turn >= len(players):
		return
	var player = players[player_turn - 1]
	var info := lobby.get_player_by_id(player_turn)
	if info.addr.peer_id != multiplayer.get_remote_sender_id():
		return
	if idx < 0 or idx >= player.space.next.size() or not wait_for_path_select:
		# Client is misbehaving
		lobby.kick(info.addr.peer_id, "Misbehaving Client")
		return
	path_chosen.emit(player.space.get_node(player.space.next[idx]))

func create_choose_path_arrows(player: PlayerBoard) -> void:
	var first = null
	var previous = null
	var i := 0
	for n in player.space.next:
		var node := player.space.get_node(n)
		var arrow = preload("res://common/scenes/board_logic/node/arrow/" +\
				"arrow.tscn").instantiate()
		var dir = node.position - player.space.position

		dir = dir.normalized()

		if first != null:
			arrow.previous_arrow = previous
			previous.next_arrow = arrow
		else:
			first = arrow

		arrow.position = player.space.position
		arrow.rotation.y = atan2(dir.normalized().x, dir.normalized().z)

		arrow.arrow_activated.connect(_on_choose_path_arrow_activated.bind(i))

		get_parent().add_child(arrow)
		previous = arrow
		i += 1

	first.previous_arrow = previous
	previous.next_arrow = first
	first.selected = true

func _step(player: PlayerBoard, previous_space: NodeBoard, last: bool) -> Array:
	# If there are multiple branches.
	if player.space.next.size() > 1:
		if previous_space != player.space:
			update_space(previous_space)
		update_space(player.space)
		previous_space = player.space
		await player.walking_ended
		if not player.info.is_ai():
			wait_for_path_select = true
			select_path.rpc_id(player.info.addr.peer_id)
			start_timer_for_player(player.info.addr)
			player.space = await path_chosen
			cancel_timer()
			wait_for_path_select = false
		else:
			player.space = player.space.get_node(player.space.next[randi() % player.space.next.size()])
			await get_tree().create_timer(1).timeout
	elif player.space.next.size() == 1:
		player.space = player.space.get_node(player.space.next[0])

	var stopped := false
	# If player passes a cake-spot.
	if player.space.cake:
		if player.space != previous_space:
			update_space(previous_space)
		update_space(player.space)
		previous_space = player.space
		stopped = true

		await player.walking_ended
		if not player.info.is_ai():
			await buy_cake(player)
		else:
			ai_purchase_cake(player)
			await get_tree().create_timer(1).timeout

	# If player passes a shop space
	if player.space.type == NodeBoard.NODE_TYPES.SHOP and lobby.overrides.items:
		if not stopped:
			if player.space != previous_space:
				update_space(previous_space)
			update_space(player.space)
		previous_space = player.space

		await player.walking_ended
		if not player.info.is_ai():
			start_timer_for_player(player.info.addr)
			$Screen/Shop.player_do_shopping(player)
			await $Screen/Shop.shopping_completed
			cancel_timer()
		else:
			$Screen/Shop.ai_do_shopping(player)
			await get_tree().create_timer(1).timeout

	# On some circumstances we must not send a movement command, because it will
	# be set during an update_space call.
	#
	# This is either when this is the last step (on a visible space)
	# Or we're right before multiple pathways, a cake or a shop
	var space := player.space
	var last_step := last and space.is_visible_space()
	var next_step_blocking = not last and (space.next.size() > 1 or
			space.cake or (space.type == NodeBoard.NODE_TYPES.SHOP and lobby.overrides.items))
	if not last_step and not next_step_blocking:
		player._internal_walk_to(player.space, player.space.position)
	
	return [player.space.is_visible_space(), previous_space]

func land_on_space(player: PlayerBoard):
	# Activate the item placed onto the node if any.
	if player.space.trap != null and player.space.trap.activate_trap(
		player, player.space.trap_player, self):
		player.space.trap = null

	# Lose cookies if you land on red space.
	match player.space.type:
		NodeBoard.NODE_TYPES.BLUE:
			player.cookies += 3
			player.add_stat("blue_spaces")
		NodeBoard.NODE_TYPES.RED:
			player.cookies -= 3
			if player.cookies < 0:
				player.cookies = 0
			player.add_stat("red_spaces")
			if randf() < 0.6:
				quip(Quips.pick("RED"), {"player": player.info.name})
		NodeBoard.NODE_TYPES.GREEN:
			if len(trigger_event.get_connections()) > 0:
				trigger_event.emit(player, player.space)
				await _event_completed
			else:
				push_warning("Player stepped on green space, but no board event"
					+ " handler is registered, skipping...")
				await get_tree().create_timer(1).timeout
		NodeBoard.NODE_TYPES.YELLOW:
			var rewards: Array = lobby.MINIGAME_DUEL_REWARDS.values()
			# Remove the invalid placeholder value from the possible options
			rewards.erase(Lobby.MINIGAME_DUEL_REWARDS.INVALID)
			var reward: int = rewards.pick_random()
			lobby.broadcast(minigame_duel_reward_animation.bind(reward))
			await minigame_duel_reward_animation(reward)

			var enemy_player: int
			if not player.info.is_ai():
				$Screen/DuelSelection.select(player.info.player_id)
				enemy_player = await $Screen/DuelSelection.selected
			else:
				var enemies: Array = players.duplicate()
				enemies.erase(player)
				enemy_player = players[randi() % enemies.size()].info.player_id

			var minigame = lobby.minigame_queue.get_random_duel()
			var state := Lobby.MinigameState.new()
			state.minigame_type = Lobby.MINIGAME_TYPES.DUEL
			state.minigame_config = minigame
			state.minigame_teams = [[enemy_player], [player.info.player_id]]
			lobby.minigame_state = state

			lobby.broadcast(show_minigame.bind(state.encode()))
			player_turn += 1
			return
		NodeBoard.NODE_TYPES.NOLOK:
			$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", "CONTEXT_NOLOK_EVENT_START", player.info.player_id)
			await $Screen/SpeechDialog.dialog_finished

			var actions := Lobby.NOLOK_ACTION_TYPES
			var type: Lobby.NOLOK_ACTION_TYPES = actions.values()[randi() % actions.size()]
			
			var state: Lobby.MinigameState = null
			var players := []
			
			var dialog_text: String
			var format_args: Dictionary
			var nolok_text: String
			
			match type:
				Lobby.NOLOK_ACTION_TYPES.SOLO_MINIGAME:
					dialog_text = "CONTEXT_NOLOK_MINIGAME_SOLO_MODERATION"
					nolok_text = "CONTEXT_NOLOK_MINIGAME_SOLO"
					state = Lobby.MinigameState.new()
					state.minigame_type = Lobby.MINIGAME_TYPES.NOLOK_SOLO
					state.minigame_config = lobby.minigame_queue.get_random_nolok_solo()
					players.append(player.info.player_id)
				Lobby.NOLOK_ACTION_TYPES.COOP_MINIGAME:
					dialog_text = "CONTEXT_NOLOK_MINIGAME_COOP_MODERATION"
					nolok_text = "CONTEXT_NOLOK_MINIGAME_COOP"
					state = Lobby.MinigameState.new()
					state.minigame_type = Lobby.MINIGAME_TYPES.NOLOK_COOP
					state.minigame_config = lobby.minigame_queue.get_random_nolok_coop()
					for p in self.players:
						players.append(p.info.player_id)
				Lobby.NOLOK_ACTION_TYPES.BOARD_EFFECT:
					# Random negative effect
					match randi() % 2:
						0:
							# Let the player loose cookies depending on rank
							var cookies = [15, 10, 5, 5]
							var rank = _get_player_placement(player)
							
							var stolen_cookies = min(cookies[rank - 1], player.cookies)
							
							# Give them to the last player (that is not yourself)
							var target: PlayerBoard = null
							for p in self.players:
								if (not target or target.cakes > p.cakes or (target.cakes == p.cakes and target.cookies > p.cookies)) and p != player:
									target = p
							
							player.cookies -= stolen_cookies
							target.cookies += stolen_cookies
							dialog_text = "CONTEXT_NOLOK_LOSE_COOKIES_MODERATION"
							format_args = {"amount": stolen_cookies, "player": target.info.name}
							nolok_text = "CONTEXT_NOLOK_LOSE_COOKIES"
						1:
							# The next 5 rolls of the player are reduced by 2
							player.add_roll_modifier(-2, 5)
							dialog_text = "CONTEXT_NOLOK_ROLL_MODIFIER_MODERATION"
							format_args = {"amount": 2, "duration": 5}
							nolok_text = "CONTEXT_NOLOK_ROLL_MODIFIER"

			lobby.broadcast(show_nolok_animation.bind(nolok_text))
			await show_nolok_animation(nolok_text)

			$Screen/SpeechDialog.show_dialog("CONTEXT_NOLOK_NAME", "res://common/scenes/board_logic/controller/icons/nolokicon.png", dialog_text, player.info.player_id, format_args)
			await $Screen/SpeechDialog.dialog_finished

			if state:
				state.minigame_teams = [players, []]
				lobby.minigame_state = state
				lobby.broadcast(show_minigame.bind(state.encode()))
				return
		NodeBoard.NODE_TYPES.EVENT:
			player.add_stat("events")
			var outcome := BoardEvents.run(player, players, self)
			lobby.broadcast(show_board_event.bind(outcome.title, outcome.text, outcome.args))
			await show_board_event(outcome.title, outcome.text, outcome.args)
		NodeBoard.NODE_TYPES.GNU:
			$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", "CONTEXT_GNU_EVENT_START", player.info.player_id)
			await $Screen/SpeechDialog.dialog_finished
			
			var actions := Lobby.GNU_ACTION_TYPES.values()
			if not lobby.overrides.items:
				# The solo game pays out an item
				actions.erase(Lobby.GNU_ACTION_TYPES.SOLO_MINIGAME)
			var type: Lobby.GNU_ACTION_TYPES = actions[randi() % actions.size()]
			
			var state := Lobby.MinigameState.new()
			var players := []
			var dialog_text := ""
			var format_args := {}
			
			match type:
				Lobby.GNU_ACTION_TYPES.SOLO_MINIGAME:
					var items: Array = PluginSystem.item_loader.get_buyable_items()
					var reward: Item = load(items[randi() % len(items)]).new()
					dialog_text = "CONTEXT_GNU_MINIGAME_SOLO_MODERATION"
					format_args = {"reward": reward.name}

					state.minigame_type = Lobby.MINIGAME_TYPES.GNU_SOLO
					state.minigame_config = lobby.minigame_queue.get_random_gnu_solo()

					lobby.minigame_reward = Lobby.MinigameReward.new()
					lobby.minigame_reward.gnu_solo_item_reward = reward

					players.push_back(player.info.player_id)
				Lobby.GNU_ACTION_TYPES.COOP_MINIGAME:
					dialog_text = "CONTEXT_GNU_MINIGAME_COOP_MODERATION"
					state.minigame_type = Lobby.MINIGAME_TYPES.GNU_COOP
					state.minigame_config = lobby.minigame_queue.get_random_gnu_coop()
					for p in self.players:
						players.push_back(p.info.player_id)

			var is_solo := type == Lobby.GNU_ACTION_TYPES.SOLO_MINIGAME
			lobby.broadcast(gnu_minigame_animation.bind(is_solo))
			await gnu_minigame_animation(is_solo)

			$Screen/SpeechDialog.show_dialog("CONTEXT_GNU_NAME", "res://common/scenes/board_logic/controller/icons/gnu_icon.png", dialog_text, player.info.player_id, format_args)
			await $Screen/SpeechDialog.dialog_finished

			state.minigame_teams = [players, []]
			lobby.minigame_state = state
			lobby.broadcast(show_minigame.bind(state.encode()))
			return

	player_turn += 1
	next_player.emit()

# Moves a player num spaces forward and stops when a cake spot is encountered.
func do_step(player: PlayerBoard, num: int) -> void:
	# Calculates each animation step and sends them to the clients
	var previous_space = player.space
	var i := 0
	while i < num:
		var args = await _step(player, previous_space, i == num - 1)
		# visible?
		if args[0]:
			i += 1
		previous_space = args[1]

	if previous_space != player.space:
		update_space(previous_space)
	if num > 0:
		update_space(player.space)
	await player.walking_ended
	await get_tree().create_timer(0.5).timeout
	land_on_space(player)

func update_space(space) -> void:
	var idx := 0
	for player in players:
		if player.space == space:
			var offset = _get_player_offset(player.space, idx)

			var pos = player.space.position + offset
			player._internal_walk_to(player.space, pos)
			idx += 1

func show_minigame_info(state) -> void:
	$Screen/MinigameInformation.show_minigame_info(state, players)

@rpc func gnu_minigame_animation(solo: bool) -> void:
	if solo:
		$Screen/GNUSelection/Content/Selection.text = "CONTEXT_GNU_MINIGAME_SOLO"
	else:
		$Screen/GNUSelection/Content/Selection.text = "CONTEXT_GNU_MINIGAME_COOP"
	$Screen/GNUSelection/AnimationPlayer.play("show")
	await $Screen/GNUSelection/AnimationPlayer.animation_finished
	$Screen/GNUSelection.hide()

@rpc func show_board_event(title: String, text: String, args: Dictionary) -> void:
	await $Screen/BoardEventBanner.play(title, tr(text).format(args), tr(args.get("kicker", "?  EVENT  ?")))

@rpc func show_nolok_animation(text: String) -> void:
	$Screen/NolokSelection/Content/Selection.text = text
	$Screen/NolokSelection/AnimationPlayer.play("show")
	await $Screen/NolokSelection/AnimationPlayer.animation_finished
	$Screen/NolokSelection.hide()

func raise_event(action: String, pressed: bool) -> void:
	var event = InputEventAction.new()
	event.action = action
	event.pressed = pressed

	Input.parse_input_event(event)

func _set_zoom(value: float) -> void:
	zoom_target = clampf(value, ZOOM_MIN, ZOOM_MAX)

func _handle_zoom_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_zoom(zoom_target - 1.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_zoom(zoom_target + 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_MINUS, KEY_KP_SUBTRACT, KEY_PAGEDOWN:
				_set_zoom(zoom_target + 3.0)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD, KEY_PAGEUP:
				_set_zoom(zoom_target - 3.0)
			KEY_Z, KEY_HOME:
				if zoom_target < ZOOM_OVERVIEW - 0.5:
					zoom_before_overview = zoom_target
					_set_zoom(ZOOM_OVERVIEW)
				else:
					_set_zoom(zoom_before_overview)

func _unhandled_input(event: InputEvent) -> void:
	_handle_zoom_input(event)
	if player_turn <= players.size() and lobby.get_player_by_id(player_turn).is_local():
		if event.is_action_pressed("player%d_ok" % player_turn):
			_on_Roll_pressed()
		if not players[player_turn - 1].info.is_ai():
			if event.is_action_pressed("player%d_ok" % player_turn):
				raise_event("ui_accept", true)
			elif event.is_action_released("player%d_ok" % player_turn):
				raise_event("ui_accept", false)
			elif event.is_action_pressed("player%d_up" % player_turn):
				raise_event("ui_up", true)
			elif event.is_action_released("player%d_up" % player_turn):
				raise_event("ui_up", false)
			elif event.is_action_pressed("player%d_left" % player_turn):
				raise_event("ui_left", true)
			elif event.is_action_released("player%d_left" % player_turn):
				raise_event("ui_left", false)
			elif event.is_action_pressed("player%d_down" % player_turn):
				raise_event("ui_down", true)
			elif event.is_action_released("player%d_down" % player_turn):
				raise_event("ui_down", false)
			elif event.is_action_pressed("player%d_right" % player_turn):
				raise_event("ui_right", true)
			elif event.is_action_released("player%d_right" % player_turn):
				raise_event("ui_right", false)

func get_players_on_space(space) -> int:
	var num = 0
	for player in players:
		if player.space == space:
			num += 1

	return num

func _get_player_placement(p: PlayerBoard) -> int:
	var placement := 1
	for p2 in players:
		if p2.cakes > p.cakes or p2.cakes == p.cakes and p2.cookies > p.cookies:
			placement += 1
	
	return placement

func _get_player_offset(space: NodeBoard, num := -1) -> Vector3:
	var players_on_space = get_players_on_space(space)
	if num < 0:
		num = players_on_space - 1

	if players_on_space > 1:
		return PLAYER_TRANSLATION[num]
	else:
		return EMPTY_SPACE_PLAYER_TRANSLATION

# This method needs to be called, after an event triggered by landing on a
# green space is fully processed.
func board_continue() -> void:
	emit_signal.call_deferred("_event_completed")

# Gets the reference to the node, on which the cake currently can be
# collected
func get_cake_space() -> NodeBoard:
	return get_node(lobby.cake_space) as NodeBoard

func ai_purchase_cake(player):
	var cakes := int(player.cookies / COOKIES_FOR_CAKE)
	var cake_cost = cakes * COOKIES_FOR_CAKE
	player.cookies -= cake_cost
	player.cakes += cakes


func buy_cake(player: PlayerBoard) -> void:
	if player.cookies >= COOKIES_FOR_CAKE:
		if await ask_yes_no("CONTEXT_CAKE_WANT_BUY"):
			var max_cakes := int(player.cookies / COOKIES_FOR_CAKE)
			var amount := max_cakes
			if amount != 1:
				amount = await query_range("CONTEXT_CAKE_BUY_AMOUNT", 1, max_cakes, max_cakes)
			await get_tree().create_timer(0.5).timeout
			await announce("CONTEXT_CAKE_COLLECTED", {"player": player.name, "amount": amount})
			player.cookies -= amount * COOKIES_FOR_CAKE
			player.cakes += amount
			player.add_stat("cakes_bought", amount)
			quip(Quips.pick("CAKE"), {"player": player.info.name})
			await relocate_cake()
	else:
		await announce("CONTEXT_CAKE_CANT_AFFORD")

func animation_step(space: NodeBoard, player_id: int) -> void:
	if player_id != player_turn:
		return

	if space.is_visible_space():
		step_count -= 1

	if step_count > 0:
		$Screen/Stepcounter.text = str(step_count)
	else:
		$Screen/Stepcounter.text = ""

func play_space_step_sfx(space: NodeBoard, player_id: int) -> void:
	if space.is_visible_space():
		space.pulse()
	if player_id == player_turn and space.is_visible_space():
		$StepFX.play()

func _process(delta: float) -> void:
	if camera_base_position == Vector3.ZERO:
		camera_base_position = $Camera3D.position
	zoom_current = lerpf(zoom_current, zoom_target, minf(1.0, 6.0 * delta))
	$Camera3D.position = camera_base_position + $Camera3D.transform.basis.z * zoom_current
	# Zoomed out, the fog would wash the whole board out
	$Camera3D.environment.fog_density = FOG_DENSITY / (1.0 + maxf(zoom_current, 0.0) * 0.15)
	if camera_focus != null:
		var dir: Vector3 = camera_focus.position - position
		if dir.length() > 0.01:
			position +=\
					CAMERA_SPEED * dir.length() * dir.normalized() * delta
		else:
			_camera_focus_aquired.emit()

# Function that updates the player info shown in the GUI.
func update_player_info() -> void:
	var i := 1

	for p in players:
		var placement = _get_player_placement(p)

		var entry: PlayerInfo = %PlayerInfo.get_child(2 * i - 1)
		entry.update(p, placement, player_turn == i)

		i += 1

func hide_splash() -> void:
	$Screen/TurnBanner.dismiss()

func show_minigame_animation(state: Lobby.MinigameState) -> void:
	var i := 1
	for team in state.minigame_teams:
		for player_id in team:
			var character = lobby.get_player_by_id(player_id).character
			var texture = PluginSystem.character_loader.load_character_icon(character)
			$Screen/MinigameTypeAnimation/Root.get_node("Player" + str(i)).texture = texture
			i += 1

	match state.minigame_type:
		Lobby.MINIGAME_TYPES.FREE_FOR_ALL:
			$Screen/MinigameTypeAnimation.play("FFA")
		Lobby.MINIGAME_TYPES.ONE_VS_THREE:
			$Screen/MinigameTypeAnimation.play("1v3")
		Lobby.MINIGAME_TYPES.TWO_VS_TWO:
			$Screen/MinigameTypeAnimation.play("2v2")
		Lobby.MINIGAME_TYPES.DUEL:
			$Screen/MinigameTypeAnimation.play("Duel")

	if $Screen/MinigameTypeAnimation.is_playing():
		await $Screen/MinigameTypeAnimation.animation_finished

@rpc func minigame_duel_reward_animation(reward: Lobby.MINIGAME_DUEL_REWARDS) -> void:
	lobby.minigame_reward = lobby.MinigameReward.new()
	lobby.minigame_reward.duel_reward = reward
	var reward_name := "BUG: Unknown Reward ({0})".format([reward])
	for key in Lobby.MINIGAME_DUEL_REWARDS.keys():
		if Lobby.MINIGAME_DUEL_REWARDS[key] == reward:
			reward_name = key

	if reward_name == "TEN_COOKIES":
		$Screen/DuelReward/Value.text = "CONTEXT_LABEL_STEAL_TEN_COOKIES"
	elif reward_name == "ONE_CAKE":
		$Screen/DuelReward/Value.text = "CONTEXT_LABEL_STEAL_ONE_CAKE"
	else:
		$Screen/DuelReward/Value.text = reward_name

	$Screen/DuelReward.show()
	await get_tree().create_timer(2).timeout
	$Screen/DuelReward.hide()

func _on_choose_path_arrow_activated(idx: int) -> void:
	server_path_chosen.rpc_id(1, idx)


func _add_zoom_hint() -> void:
	var hint := Label.new()
	hint.text = tr("CONTEXT_ZOOM_HINT")
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	hint.add_theme_constant_override("outline_size", 4)
	hint.modulate = Color(1, 1, 1, 0.8)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.offset_left = -520
	hint.offset_top = -30
	hint.offset_right = -14
	hint.offset_bottom = -6
	$Screen.add_child(hint)
	# Only needed for the first moments of a turn
	var tween := create_tween()
	tween.tween_interval(12.0)
	tween.tween_property(hint, "modulate:a", 0.0, 1.5)
	tween.tween_callback(hint.queue_free)


# ----- Mayor Pixel's remarks -----

var quip_panel: PanelContainer
var quip_label: Label
var quip_tween: Tween

func _build_quip_ticker() -> void:
	quip_panel = PanelContainer.new()
	quip_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	quip_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	quip_panel.custom_minimum_size = Vector2(760, 0)
	quip_panel.offset_left = -380
	quip_panel.offset_right = 380
	quip_panel.offset_top = 132
	quip_panel.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	quip_panel.add_child(row)
	var portrait := TextureRect.new()
	portrait.texture = load("res://common/scenes/board_logic/controller/icons/host.png")
	portrait.custom_minimum_size = Vector2(64, 64)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(portrait)
	quip_label = Label.new()
	quip_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quip_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	quip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quip_label.add_theme_font_size_override("font_size", 22)
	quip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(quip_label)
	$Screen.add_child(quip_panel)


## Server: Mayor Pixel says something short (it does not stop the game).
func quip(key: String, args := {}) -> void:
	lobby.broadcast(show_quip.bind(key, args))
	show_quip(key, args)


@rpc func show_quip(key: String, args: Dictionary) -> void:
	if quip_panel == null:
		_build_quip_ticker()
	quip_label.text = tr(key).format(args)
	quip_panel.visible = true
	quip_panel.modulate.a = 0.0
	if quip_tween:
		quip_tween.kill()
	quip_tween = create_tween()
	quip_tween.tween_property(quip_panel, "modulate:a", 1.0, 0.25)
	quip_tween.tween_interval(4.2)
	quip_tween.tween_property(quip_panel, "modulate:a", 0.0, 0.4)
	quip_tween.tween_callback(quip_panel.hide)


func _standings() -> Array:
	var sorted_players: Array = players.duplicate()
	sorted_players.sort_custom(func(a, b): return a.cakes > b.cakes or (a.cakes == b.cakes and a.cookies > b.cookies))
	return sorted_players


# Server: at the start of a round the mayor comments on the standings, and the last rounds are announced.
func _round_start_banter() -> void:
	var max_turns: int = lobby.overrides.max_turns
	if lobby.turn >= max_turns - 1 and max_turns > 2:
		var last: bool = lobby.turn >= max_turns
		var args := {"kicker": "FRENZY_KICKER"}
		var title := "FRENZY_LAST" if last else "FRENZY_START"
		var text := title + "_TEXT"
		lobby.broadcast(show_board_event.bind(title, text, args))
		await show_board_event(title, text, args)
		return
	var order := _standings()
	if order.is_empty():
		return
	var leader: PlayerBoard = order[0]
	var trailer: PlayerBoard = order[order.size() - 1]
	var mood := randi() % 4
	if leader.cakes == trailer.cakes and leader.cookies == trailer.cookies:
		quip(Quips.pick("TIED"))
	elif mood == 0 and trailer.cookies <= 3:
		quip(Quips.pick("POOR"), {"player": trailer.info.name})
	elif mood <= 1:
		quip(Quips.pick("LAST"), {"player": trailer.info.name})
	else:
		quip(Quips.pick("LEADER"), {"player": leader.info.name, "cakes": leader.cakes})
