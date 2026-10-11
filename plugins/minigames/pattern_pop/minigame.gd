extends "res://common/scripts/arcade/podium_game.gd"
## Pattern Pop: the big screen lights up a pattern of arrows, then everybody repeats it with their direction buttons.
## Five rounds, the pattern grows by one arrow each round (3 to 7). A finished pattern scores points and the fastest
## players get a bonus; a wrong button ends the round for that player and only the arrows they got right count.

const ROUNDS := 5
const FIRST_LENGTH := 3
const INTRO_TIME := 1.2
const SHOW_STEP := 0.5
const RESULT_TIME := 1.7
const HURRY_TIME := 3.5          # seconds the others have left when the first player is done
const PAD_COLORS := [Color(0.35, 0.85, 0.4), Color(0.35, 0.55, 1.0), Color(1.0, 0.45, 0.35), Color(1.0, 0.85, 0.25)]
const SPEED_BONUS := [4, 2, 1, 0]

enum Phase { WAIT, INTRO, SHOW, INPUT, RESULT, DONE }

# server
var phase := Phase.WAIT
var phase_time := 0.0
var round_index := 0
var pattern: Array[int] = []
var show_index := 0
var progress := {}            # player id -> arrows right so far
var failed := {}              # player id -> true
var finish_order: Array[int] = []
var ai_next := {}             # player id -> seconds until the next press of a bot
var input_window := 0.0

# every peer
var pads: Array[MeshInstance3D] = []
var pad_mats: Array[StandardMaterial3D] = []
var status: Label3D
var round_label: Label3D
var dots := {}                # player id -> Array of MeshInstance3D
var dot_mats := {}            # player id -> Array of StandardMaterial3D
var input_open := false
var timer_label: Label3D
var input_left := 0.0


func stage_colors() -> Array:
	return [Color(0.16, 0.10, 0.40), Color(0.85, 0.45, 0.80), Color(0.10, 0.06, 0.22)]


func build_set() -> void:
	make_music("res://assets/music/retro/tug_march.ogg")
	# the big screen: a frame with the four arrow pads in the shape of a D-pad
	var frame := MeshInstance3D.new()
	var fbox := BoxMesh.new()
	fbox.size = Vector3(6.4, 4.6, 0.3)
	fbox.material = toon(Color(0.10, 0.08, 0.18))
	frame.mesh = fbox
	frame.position = Vector3(0, 4.6, -4.2)
	add_child(frame)
	var offsets := [Vector2(0, 1.35), Vector2(-1.35, 0), Vector2(0, -1.35), Vector2(1.35, 0)]
	var rotations := [0.0, 90.0, 180.0, 270.0]
	for d in 4:
		var pad := MeshInstance3D.new()
		var pbox := BoxMesh.new()
		pbox.size = Vector3(1.25, 1.25, 0.2)
		var mat := toon(PAD_COLORS[d].darkened(0.55))
		pbox.material = mat
		pad.mesh = pbox
		pad.position = Vector3(offsets[d].x, 4.6 + offsets[d].y, -4.0)
		add_child(pad)
		pads.append(pad)
		pad_mats.append(mat)
		var arrow := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(0.8, 0.8, 0.1)
		prism.material = glow(Color(1, 1, 1, 1))
		arrow.mesh = prism
		arrow.position = Vector3(0, 0, 0.13)
		arrow.rotation_degrees.z = rotations[d]
		pad.add_child(arrow)
	status = world_label("", Vector3(0, 7.5, -3.9), 0.012, Color(1.0, 0.9, 0.35))
	round_label = world_label("", Vector3(0, 1.05, -3.9), 0.007, Color.WHITE)
	timer_label = world_label("", Vector3(3.5, 7.0, -3.9), 0.012, Color(1, 1, 1))
	_build_dots()


func _build_dots() -> void:
	for p in players:
		var id := p.info.player_id
		dots[id] = []
		dot_mats[id] = []
		var x: float = podium_x[id]
		for i in 8:
			var dot := MeshInstance3D.new()
			var sph := SphereMesh.new()
			sph.radius = 0.13
			sph.height = 0.26
			var mat := glow(Color(0.35, 0.33, 0.45))
			sph.material = mat
			dot.mesh = sph
			dot.position = Vector3(x + (i - 3.5) * 0.3, 0.12, 3.35)
			add_child(dot)
			dots[id].append(dot)
			dot_mats[id].append(mat)


func on_go() -> void:
	if multiplayer.is_server():
		_start_round()


# ----- server: the rounds -----

func _start_round() -> void:
	var length := FIRST_LENGTH + round_index
	pattern = []
	for i in length:
		# no more than two of the same arrow in a row
		var d := randi() % 4
		while pattern.size() >= 2 and pattern[-1] == d and pattern[-2] == d:
			d = randi() % 4
		pattern.append(d)
	progress = {}
	failed = {}
	finish_order = []
	for p in players:
		progress[p.info.player_id] = 0
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	lobby.broadcast(_client_round.bind(round_index + 1, length))
	_client_round(round_index + 1, length)


func server_tick(delta: float) -> void:
	phase_time -= delta
	match phase:
		Phase.INTRO:
			if phase_time <= 0.0:
				phase = Phase.SHOW
				show_index = 0
				phase_time = 0.3
		Phase.SHOW:
			if phase_time <= 0.0:
				if show_index >= pattern.size():
					_open_input()
				else:
					var d := pattern[show_index]
					show_index += 1
					lobby.broadcast(_client_light.bind(d))
					_client_light(d)
					phase_time = SHOW_STEP
		Phase.INPUT:
			_bots(delta)
			if phase_time <= 0.0 or _everybody_done():
				_end_round()
		Phase.RESULT:
			if phase_time <= 0.0:
				round_index += 1
				if round_index >= ROUNDS:
					phase = Phase.DONE
					finish_by_points(score_list())
				else:
					_start_round()


func _open_input() -> void:
	phase = Phase.INPUT
	input_window = 3.0 + pattern.size() * 0.9
	phase_time = input_window
	lobby.broadcast(_client_input.bind(input_window))
	_client_input(input_window)
	for p in players:
		if p.info.is_ai():
			ai_next[p.info.player_id] = randf_range(0.7, 1.4)


func _everybody_done() -> bool:
	for p in players:
		var id := p.info.player_id
		if not failed.has(id) and progress[id] < pattern.size():
			return false
	return true


func _bots(delta: float) -> void:
	for p in players:
		if not p.info.is_ai():
			continue
		var id := p.info.player_id
		if failed.has(id) or progress[id] >= pattern.size():
			continue
		ai_next[id] -= delta
		if ai_next[id] > 0.0:
			continue
		var skill := 1.0
		var slip := 0.05
		match p.info.ai_difficulty:
			Lobby.Difficulty.EASY:
				skill = 0.75
				slip = 0.11
			Lobby.Difficulty.HARD:
				skill = 1.3
				slip = 0.02
		ai_next[id] = randf_range(0.35, 0.6) / skill
		var d := pattern[progress[id]]
		if randf() < slip + pattern.size() * 0.004:
			d = (d + 1 + randi() % 3) % 4
		_press(id, d)


@rpc("any_peer") func submit(player_id: int, direction: int) -> void:
	if not multiplayer.is_server() or phase != Phase.INPUT or direction < 0 or direction > 3:
		return
	if not sender_owns(player_id):
		return
	_press(player_id, direction)


func _press(player_id: int, direction: int) -> void:
	if failed.has(player_id) or progress[player_id] >= pattern.size():
		return
	if direction == pattern[progress[player_id]]:
		progress[player_id] += 1
		lobby.broadcast(_client_progress.bind(player_id, progress[player_id], true, direction))
		_client_progress(player_id, progress[player_id], true, direction)
		if progress[player_id] >= pattern.size():
			finish_order.append(player_id)
			if finish_order.size() == 1:
				# the first one is done: the others have a few seconds left
				phase_time = minf(phase_time, HURRY_TIME)
				lobby.broadcast(_client_hurry.bind(HURRY_TIME))
				_client_hurry(HURRY_TIME)
			react(player_id, true)
			popup(player_id, "DONE!", Color(0.5, 1.0, 0.5), true)
	else:
		failed[player_id] = true
		lobby.broadcast(_client_progress.bind(player_id, progress[player_id], false, direction))
		_client_progress(player_id, progress[player_id], false, direction)
		react(player_id, false)
		popup(player_id, "OOPS!", Color(1.0, 0.4, 0.4), true)


func _end_round() -> void:
	phase = Phase.RESULT
	phase_time = RESULT_TIME
	for p in players:
		var id := p.info.player_id
		var gain: int = progress[id]
		if progress[id] >= pattern.size():
			var place := finish_order.find(id)
			gain = 8 + pattern.size() + SPEED_BONUS[mini(place, 3)]
		if gain > 0:
			add_points(id, gain)
			popup(id, "+%d" % gain, Color(1.0, 0.9, 0.3))
	lobby.broadcast(_client_input_closed)
	_client_input_closed()


# ----- every peer -----

@rpc func _client_round(number: int, length: int) -> void:
	status.text = "ROUND %d" % number
	round_label.text = "%d arrows" % length
	input_open = false
	timer_label.text = ""
	for id in dots:
		for i in 8:
			dot_mats[id][i].albedo_color = Color(0.35, 0.33, 0.45) if i < length else Color(0.2, 0.18, 0.28)


@rpc func _client_light(direction: int) -> void:
	status.text = "WATCH!"
	_flash_pad(direction, SHOW_STEP * 0.7)
	sound("res://assets/sounds/ui/click1.wav")


func _flash_pad(direction: int, time: float) -> void:
	var mat := pad_mats[direction]
	var pad := pads[direction]
	mat.albedo_color = PAD_COLORS[direction]
	mat.emission_enabled = true
	mat.emission = PAD_COLORS[direction]
	mat.emission_energy_multiplier = 1.6
	pad.scale = Vector3(1.12, 1.12, 1.4)
	var tween := create_tween()
	tween.tween_interval(time)
	tween.tween_callback(func():
		mat.albedo_color = PAD_COLORS[direction].darkened(0.55)
		mat.emission_enabled = false
		pad.scale = Vector3.ONE)


@rpc func _client_input(window: float) -> void:
	status.text = "YOUR TURN!"
	input_open = true
	input_left = window
	sound("res://assets/sounds/ui/turn_start.wav")


@rpc func _client_hurry(seconds: float) -> void:
	input_left = minf(input_left, seconds)
	status.text = "HURRY UP!"


@rpc func _client_input_closed() -> void:
	input_open = false
	status.text = "NICE!"
	timer_label.text = ""


@rpc func _client_progress(player_id: int, count: int, ok: bool, direction: int) -> void:
	if not dot_mats.has(player_id):
		return
	if ok:
		dot_mats[player_id][count - 1].albedo_color = Color(0.4, 1.0, 0.45)
		_flash_pad(direction, 0.18)
	else:
		for i in count:
			dot_mats[player_id][i].albedo_color = Color(0.95, 0.4, 0.35)
		if count < 8:
			dot_mats[player_id][count].albedo_color = Color(1.0, 0.15, 0.15)
		sound("res://assets/sounds/wrong.wav")


func world_tick(delta: float) -> void:
	if not input_open:
		return
	input_left = maxf(input_left - delta, 0.0)
	timer_label.text = "%d" % ceili(input_left)
	for p in players:
		if not is_mine(p):
			continue
		var d := pressed_direction(p)
		if d >= 0:
			submit.rpc_id(1, p.info.player_id, d)
