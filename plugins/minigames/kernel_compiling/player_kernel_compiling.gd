extends Node3D

const ACTIONS := ["up", "down", "left", "right", "action1", "action2", "action3", "action4"]

var info: Lobby.PlayerInfo

var ai_wait_time: float

var next_action: String

var disabled_input = false

var teammate: Node

var presses := 0
# Streak / bonus mechanics (server decides the values)
const STREAK_TIME := 1.2 # A press quicker than this keeps the streak
const STREAK_STEP := 5 # Every N-th quick press in a row gives a bonus
const GOLDEN_CHANCE := 0.18
const GOLDEN_VALUE := 3
var streak := 0
var golden := false
var action_time := 0.0
@onready var NEEDED_BUTTON_PRESSES := 60 if info.lobby.minigame_state.minigame_type != Lobby.MINIGAME_TYPES.TWO_VS_TWO else 120

var AI_MIN_WAIT_TIME: float
var AI_MAX_WAIT_TIME: float

func get_percentage():
	return float(presses) / NEEDED_BUTTON_PRESSES

func show_popup(text: String, color: Color):
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.outline_size = 12
	label.pixel_size = 0.0035
	label.font_size = 64
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	label.position = Vector3(0, 1.8, 0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", 2.5, 0.9)
	tween.tween_property(label, "modulate:a", 0.0, 0.9).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)

@rpc("any_peer", "call_local") func wrong_pressed():
	if info.addr.peer_id != multiplayer.get_remote_sender_id():
		return
	streak = 0

func disable_input():
	wrong_pressed.rpc_id(1)
	$Wrong.play()
	disabled_input = true
	$PenaltyTimer.start()

func generate_next_action():
	if get_parent().game_ended:
		return
	var action = ACTIONS[randi() % ACTIONS.size()]
	next_action = "player" + str(info.player_id) + "_" + action
	golden = randf() < GOLDEN_CHANCE
	action_time = Time.get_ticks_msec() / 1000.0
	info.lobby.broadcast(set_action.bind(action, golden))
	if golden:
		show_popup(tr("KERNEL_COMPILING_GOLDEN"), Color(1, 0.85, 0.2))

@rpc func set_action(action: String, is_golden := false):
	if action == "":
		next_action = ""
		$Screen/ControlView.clear_display()
		return
	if not action in ACTIONS:
		return
	next_action = "player" + str(info.player_id) + "_" + action
	$Screen/ControlView.display_action(next_action)
	if is_golden and not multiplayer.is_server():
		show_popup(tr("KERNEL_COMPILING_GOLDEN"), Color(1, 0.85, 0.2))

func clear_action():
	next_action = ""
	info.lobby.broadcast(set_action.bind(""))

func update_progress():
	# If each player has their own progress bar (every mode exect 2v2), then do it locally
	# Otherwise, let the minigame root node handle the combined progress bars for each team
	if info.lobby.minigame_state.minigame_type != Lobby.MINIGAME_TYPES.TWO_VS_TWO:
		$Progress.material_override.set_shader_parameter("percentage", get_percentage())
	else:
		get_parent().update_progress()

func _ready():
	$Model.jump_to_animation("sit")
	
	if info.lobby.minigame_state.minigame_type == Lobby.MINIGAME_TYPES.TWO_VS_TWO:
		$Progress.hide()
	
	if info.is_ai():
		match info.ai_difficulty:
			Lobby.Difficulty.EASY:
				AI_MIN_WAIT_TIME = 0.8
				AI_MAX_WAIT_TIME = 1.0
			Lobby.Difficulty.HARD:
				AI_MIN_WAIT_TIME = 0.4
				AI_MAX_WAIT_TIME = 0.6
			_:
				AI_MIN_WAIT_TIME = 0.6
				AI_MAX_WAIT_TIME = 0.8
		
		ai_wait_time = randf_range(AI_MIN_WAIT_TIME, AI_MAX_WAIT_TIME)

func press():
	pressed.rpc_id(1)

@rpc("any_peer", "call_local") func pressed():
	if info.addr.peer_id != multiplayer.get_remote_sender_id():
		return
	if next_action == "":
		return
	# Value of this press: golden keys are worth more, streaks give bonuses
	var amount := GOLDEN_VALUE if golden else 1
	var now := Time.get_ticks_msec() / 1000.0
	if now - action_time <= STREAK_TIME:
		streak += 1
	else:
		streak = 1
	var bonus := false
	if streak % STREAK_STEP == 0:
		amount += 2
		bonus = true
	golden = false
	_add_presses(amount)
	info.lobby.broadcast(_client_pressed.bind(amount, bonus))
	if bonus:
		show_popup(tr("KERNEL_COMPILING_STREAK").format({"count": streak}), Color(0.4, 1, 0.5))
	clear_action()
	if presses < NEEDED_BUTTON_PRESSES:
		get_tree().create_timer(0.25).timeout.connect(generate_next_action)
	else:
		get_parent().stop_game()

func _add_presses(amount: int):
	presses = mini(presses + amount, NEEDED_BUTTON_PRESSES)
	if teammate:
		teammate.presses = mini(teammate.presses + amount, NEEDED_BUTTON_PRESSES)

@rpc func _client_pressed(amount := 1, bonus := false):
	_add_presses(amount)
	$Correct.pitch_scale = 1.4 if amount > 1 else 1.0
	$Correct.play()
	if amount > 1:
		if not multiplayer.is_server():
			show_popup("+" + str(amount), Color(1, 0.85, 0.2) if not bonus else Color(0.4, 1, 0.5))
	update_progress()

func _server_process(delta):
	if info.is_ai() and next_action and not disabled_input:
		ai_wait_time -= delta
		if ai_wait_time <= 0:
			press()
			ai_wait_time = randf_range(AI_MIN_WAIT_TIME, AI_MAX_WAIT_TIME)

func _input(event):
	if not info.is_local() or info.is_ai():
		return
	if next_action and not disabled_input:
		if event.is_action_pressed(next_action):
			press()
		else:
			# Check if it was another action by that player
			for action in ACTIONS:
				if event.is_action_pressed("player" + str(info.player_id) + "_" + action):
					disable_input()
					$Screen/ControlView.hide()
					$Screen/PenaltySplash.show()
					return

func _on_PenaltyTimer_timeout():
	disabled_input = false
	$Screen/PenaltySplash.hide()
	$Screen/ControlView.show()
