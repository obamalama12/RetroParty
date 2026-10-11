extends "res://common/scripts/arcade/podium_game.gd"
## Quick Draw: a signal light hangs over the stage. While it is red, wait. When it turns green, press the button as fast
## as you can! Pressing too early is a false start and sits the round out. Later rounds try to trick you with a yellow
## fake flash. Six rounds, the fastest player of a round gets the most points, the last round counts double.

const ROUNDS := 6
const INTRO_TIME := 1.3
const RESULT_TIME := 2.4
const GO_WINDOW := 2.0           # seconds after the signal in which presses count
const POINTS := [5, 3, 2, 1]
const MIN_REACTION := 0.12       # nobody is that fast: a press sooner than this after the signal is not believed

enum Phase { WAIT, INTRO, WAITING, GO, RESULT, DONE }

# server
var phase := Phase.WAIT
var phase_time := 0.0
var round_index := 0
var fake_at := -1.0               # seconds into the wait when the yellow fake flash happens, -1: none
var waited := 0.0
var fake_done := false
var reactions := {}               # player id -> seconds (valid presses of this round)
var false_starts := {}            # player id -> true
var ai_reaction := {}             # player id -> seconds after the signal (or -1: false start in the wait)
var ai_false_at := {}

# every peer
var lamp: MeshInstance3D
var lamp_mat: StandardMaterial3D
var big_text: Label3D
var small_text: Label3D
var time_labels := {}             # player id -> Label3D
var go_shown_at := 0              # Time.get_ticks_msec() when the green light turned on, 0: not green
var locked := false               # this peer already pressed in this round


func stage_colors() -> Array:
	return [Color(0.55, 0.78, 1.0), Color(1.0, 0.85, 0.6), Color(0.25, 0.3, 0.45)]


func build_set() -> void:
	make_music("res://assets/music/retro/tug_march.ogg")
	# a signal tower: a dark board with the lamp in front of it
	var board := MeshInstance3D.new()
	var bbox := BoxMesh.new()
	bbox.size = Vector3(5.2, 5.2, 0.3)
	bbox.material = toon(Color(0.12, 0.12, 0.2))
	board.mesh = bbox
	board.position = Vector3(0, 4.6, -4.2)
	add_child(board)
	lamp = MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 1.45
	sph.height = 2.9
	lamp_mat = glow(Color(0.8, 0.12, 0.12))
	sph.material = lamp_mat
	lamp.mesh = sph
	lamp.position = Vector3(0, 4.9, -3.7)
	add_child(lamp)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.5
	torus.outer_radius = 1.75
	torus.material = toon(Color(0.9, 0.9, 0.95))
	ring.mesh = torus
	ring.rotation_degrees.x = 90
	ring.position = Vector3(0, 4.9, -3.7)
	add_child(ring)
	big_text = world_label("", Vector3(0, 7.9, -3.6), 0.014, Color(1.0, 0.9, 0.35))
	small_text = world_label("", Vector3(0, 2.55, -3.6), 0.007, Color.WHITE)
	for p in players:
		var id := p.info.player_id
		var label := world_label("", Vector3(podium_x[id], 3.5, 2.8), 0.0085, Color(1, 1, 1))
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		time_labels[id] = label


func on_go() -> void:
	if multiplayer.is_server():
		_start_round()


# ----- server -----

func _start_round() -> void:
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	reactions = {}
	false_starts = {}
	var last := round_index == ROUNDS - 1
	lobby.broadcast(_client_round.bind(round_index + 1, last))
	_client_round(round_index + 1, last)


func _begin_waiting() -> void:
	phase = Phase.WAITING
	waited = 0.0
	phase_time = randf_range(2.0, 4.8) + (0.8 if round_index >= 2 else 0.0)
	fake_done = false
	# from the third round on there is often a yellow fake flash somewhere in the wait
	fake_at = randf_range(0.8, phase_time - 0.9) if round_index >= 2 and randf() < 0.7 else -1.0
	for p in players:
		if not p.info.is_ai():
			continue
		var id := p.info.player_id
		var base := 0.42
		var spread := 0.12
		match p.info.ai_difficulty:
			Lobby.Difficulty.EASY:
				base = 0.55
				spread = 0.18
			Lobby.Difficulty.HARD:
				base = 0.33
				spread = 0.07
		ai_reaction[id] = base + randf_range(-spread, spread)
		# a rare false start in the wait, more likely when there is a fake flash
		ai_false_at[id] = randf_range(0.5, phase_time) if randf() < (0.04 if fake_at < 0.0 else 0.10) else -1.0
	lobby.broadcast(_client_wait)
	_client_wait()


func server_tick(delta: float) -> void:
	phase_time -= delta
	match phase:
		Phase.INTRO:
			if phase_time <= 0.0:
				_begin_waiting()
		Phase.WAITING:
			waited += delta
			if fake_at >= 0.0 and not fake_done and waited >= fake_at:
				fake_done = true
				lobby.broadcast(_client_fake)
				_client_fake()
			for p in players:
				var id := p.info.player_id
				if p.info.is_ai() and ai_false_at.get(id, -1.0) >= 0.0 and waited >= ai_false_at[id]:
					ai_false_at[id] = -1.0
					_false_start(id)
			if phase_time <= 0.0:
				phase = Phase.GO
				phase_time = GO_WINDOW
				lobby.broadcast(_client_go)
				_client_go()
		Phase.GO:
			var since := GO_WINDOW - phase_time
			for p in players:
				var id := p.info.player_id
				if p.info.is_ai() and not reactions.has(id) and not false_starts.has(id) and since >= ai_reaction.get(id, 9.0):
					_valid_press(id, ai_reaction[id])
			if phase_time <= 0.0 or _all_answered():
				_end_round()
		Phase.RESULT:
			if phase_time <= 0.0:
				round_index += 1
				if round_index >= ROUNDS:
					phase = Phase.DONE
					finish_by_points(score_list())
				else:
					_start_round()


func _all_answered() -> bool:
	for p in players:
		var id := p.info.player_id
		if not reactions.has(id) and not false_starts.has(id):
			return false
	return true


## A press from a human. `reaction` is the time the player's own screen showed the green light before the press,
## or -1 if the light was not green yet on that screen.
@rpc("any_peer") func press(player_id: int, reaction: float) -> void:
	if not multiplayer.is_server() or not sender_owns(player_id):
		return
	if reactions.has(player_id) or false_starts.has(player_id):
		return
	match phase:
		Phase.WAITING:
			_false_start(player_id)
		Phase.GO:
			if reaction < 0.0:
				_false_start(player_id)
			else:
				_valid_press(player_id, maxf(reaction, MIN_REACTION))


func _false_start(player_id: int) -> void:
	if false_starts.has(player_id) or phase == Phase.RESULT:
		return
	false_starts[player_id] = true
	lobby.broadcast(_client_time.bind(player_id, -1.0))
	_client_time(player_id, -1.0)
	react(player_id, false)
	popup(player_id, "FALSE START!", Color(1.0, 0.4, 0.4), true)


func _valid_press(player_id: int, seconds: float) -> void:
	reactions[player_id] = seconds
	lobby.broadcast(_client_time.bind(player_id, seconds))
	_client_time(player_id, seconds)


func _end_round() -> void:
	phase = Phase.RESULT
	phase_time = RESULT_TIME
	var order: Array = reactions.keys()
	order.sort_custom(func(a, b): return reactions[a] < reactions[b])
	var factor := 2 if round_index == ROUNDS - 1 else 1
	for i in order.size():
		var id: int = order[i]
		var gain: int = POINTS[mini(i, 3)] * factor
		add_points(id, gain)
		popup(id, "+%d" % gain, Color(1.0, 0.9, 0.3), i == 0)
		if i == 0:
			react(id, true)
	lobby.broadcast(_client_round_over.bind(order.size() > 0))
	_client_round_over(order.size() > 0)


# ----- every peer -----

func _set_lamp(color: Color) -> void:
	lamp_mat.albedo_color = color


@rpc func _client_round(number: int, last: bool) -> void:
	_set_lamp(Color(0.35, 0.1, 0.1))
	big_text.text = "ROUND %d" % number if not last else "FINAL ROUND x2"
	small_text.text = "Wait for GREEN, then press!"
	go_shown_at = 0
	locked = false
	for id in time_labels:
		time_labels[id].text = ""


@rpc func _client_wait() -> void:
	_set_lamp(Color(0.95, 0.12, 0.12))
	big_text.text = "WAIT..."
	small_text.text = ""


@rpc func _client_fake() -> void:
	_set_lamp(Color(1.0, 0.85, 0.15))
	big_text.text = "NOT YET!"
	sound("res://assets/sounds/wrong.wav")
	var tween := create_tween()
	tween.tween_interval(0.45)
	tween.tween_callback(func():
		if go_shown_at == 0:
			_set_lamp(Color(0.95, 0.12, 0.12))
			big_text.text = "WAIT...")


@rpc func _client_go() -> void:
	_set_lamp(Color(0.2, 1.0, 0.3))
	big_text.text = "GO!"
	go_shown_at = Time.get_ticks_msec()
	sound("res://assets/sounds/correct.wav")


@rpc func _client_time(player_id: int, seconds: float) -> void:
	if not time_labels.has(player_id):
		return
	time_labels[player_id].text = "%.3f s" % seconds if seconds >= 0.0 else "X"
	time_labels[player_id].modulate = Color(0.6, 1.0, 0.6) if seconds >= 0.0 else Color(1.0, 0.4, 0.4)


@rpc func _client_round_over(any_valid: bool) -> void:
	go_shown_at = 0
	_set_lamp(Color(0.4, 0.4, 0.6))
	big_text.text = "NICE!" if any_valid else "TOO SLOW!"


func world_tick(_delta: float) -> void:
	for p in players:
		if not is_mine(p):
			continue
		if Input.is_action_just_pressed("player%d_action1" % p.info.player_id):
			var reaction := -1.0
			if go_shown_at != 0:
				reaction = (Time.get_ticks_msec() - go_shown_at) / 1000.0
			press.rpc_id(1, p.info.player_id, reaction)
