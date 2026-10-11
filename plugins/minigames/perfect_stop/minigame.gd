extends "res://common/scripts/arcade/podium_game.gd"
## Perfect Stop: every player has a timing bar over their podium. A marker sweeps across it, press the button to
## stop it inside the green zone. The closer to the middle of the zone, the more points. Seven rounds: the marker gets
## faster and the zone smaller every round, and in the last rounds the zone moves while you watch.

const ROUNDS := 7
const INTRO_TIME := 1.4
const RESULT_TIME := 2.0
const ROUND_LIMIT := 5.0         # seconds a round lasts at most (players who did not stop score nothing)
const BAR_WIDTH := 2.5
const BAR_Y := 3.55

enum Phase { WAIT, INTRO, PLAY, RESULT, DONE }

# server
var phase := Phase.WAIT
var phase_time := 0.0
var round_index := 0
var stopped := {}                 # player id -> true
var ai_stop_at := {}              # player id -> seconds into the round
var ai_error := {}                # player id -> how far off a bot stops, in zone half widths

# every peer
var speed := 1.0                  # sweeps per second
var zone_center := 0.5
var zone_half := 0.1
var zone_drift := 0.0             # the zone moves back and forth, in bar widths per second (late rounds)
var round_started_at := 0
var playing := false
var markers := {}                 # player id -> MeshInstance3D
var zones := {}                   # player id -> MeshInstance3D
var frozen_at := {}               # player id -> marker position (0..1) once stopped
var big_text: Label3D
var small_text: Label3D
var drift_phase := 0.0


func stage_colors() -> Array:
	return [Color(0.20, 0.55, 0.45), Color(0.80, 0.95, 0.70), Color(0.08, 0.2, 0.2)]


func build_set() -> void:
	make_music("res://assets/music/retro/tug_march.ogg")
	big_text = world_label("", Vector3(0, 7.4, -3.6), 0.014, Color(1.0, 0.9, 0.35))
	small_text = world_label("", Vector3(0, 5.6, -3.6), 0.0075, Color.WHITE)
	for p in players:
		var id := p.info.player_id
		var x: float = podium_x[id]
		var bar := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(BAR_WIDTH + 0.2, 0.55, 0.12)
		box.material = toon(Color(0.12, 0.12, 0.2))
		bar.mesh = box
		bar.position = Vector3(x, BAR_Y, 2.0)
		add_child(bar)
		var zone := MeshInstance3D.new()
		var zbox := BoxMesh.new()
		zbox.size = Vector3(1.0, 0.4, 0.14)
		zbox.material = glow(Color(0.3, 1.0, 0.4))
		zone.mesh = zbox
		zone.position = Vector3(x, BAR_Y, 2.01)
		add_child(zone)
		zones[id] = zone
		var marker := MeshInstance3D.new()
		var mbox := BoxMesh.new()
		mbox.size = Vector3(0.12, 0.8, 0.2)
		mbox.material = glow(Color(1.0, 1.0, 1.0))
		marker.mesh = mbox
		marker.position = Vector3(x, BAR_Y, 2.1)
		add_child(marker)
		markers[id] = marker
	_update_zone_visuals()


func on_go() -> void:
	if multiplayer.is_server():
		_start_round()


# ----- server -----

func _start_round() -> void:
	phase = Phase.INTRO
	phase_time = INTRO_TIME
	stopped = {}
	var r := round_index
	var new_speed := 0.9 + 0.22 * r
	var new_half := 0.14 - 0.012 * r
	var new_center := randf_range(0.3, 0.7)
	var new_drift := 0.0 if r < 4 else 0.12 + 0.05 * (r - 4)
	lobby.broadcast(_client_round.bind(r + 1, new_speed, new_half, new_center, new_drift))
	_client_round(r + 1, new_speed, new_half, new_center, new_drift)


func server_tick(delta: float) -> void:
	phase_time -= delta
	match phase:
		Phase.INTRO:
			if phase_time <= 0.0:
				phase = Phase.PLAY
				phase_time = ROUND_LIMIT
				for p in players:
					if p.info.is_ai():
						_plan_bot(p)
				lobby.broadcast(_client_play)
				_client_play()
		Phase.PLAY:
			var since := ROUND_LIMIT - phase_time
			for p in players:
				var id := p.info.player_id
				if p.info.is_ai() and not stopped.has(id) and since >= ai_stop_at.get(id, 99.0):
					_stop(id, _marker_at(since, id) + ai_error.get(id, 0.0) * zone_half)
			if phase_time <= 0.0 or stopped.size() == players.size():
				_end_round()
		Phase.RESULT:
			if phase_time <= 0.0:
				round_index += 1
				if round_index >= ROUNDS:
					phase = Phase.DONE
					finish_by_points(score_list())
				else:
					_start_round()


## The position (0..1) of the marker `seconds` into the round: it sweeps back and forth
func _marker_at(seconds: float, player_id: int) -> float:
	# every player's marker starts at another point of the sweep, so nobody can copy the one next to them
	return absf(fmod(seconds * speed + 0.53 * player_id, 2.0) - 1.0)


## The zone centre `seconds` into the round (it may drift)
func _zone_at(seconds: float) -> float:
	if zone_drift <= 0.0:
		return zone_center
	return clampf(zone_center + sin(seconds * 2.3 + drift_phase) * zone_drift * 2.0, zone_half, 1.0 - zone_half)


func _plan_bot(p: ArcadePlayer) -> void:
	var id := p.info.player_id
	var sigma := 1.1
	match p.info.ai_difficulty:
		Lobby.Difficulty.EASY:
			sigma = 1.8
		Lobby.Difficulty.HARD:
			sigma = 0.6
	# the bot waits until the marker is close to the zone on one of its sweeps, then stops with a human-sized error
	var best := 0.0
	var best_diff := 9.0
	var t := randf_range(0.6, 1.6)
	for i in 40:
		var diff := absf(_marker_at(t, id) - _zone_at(t))
		if diff < best_diff and t > 0.8:
			best_diff = diff
			best = t
			if diff < 0.03:
				break
		t += 0.04
	ai_stop_at[id] = best + randf_range(0.0, 0.6)
	ai_error[id] = randfn(0.0, sigma)


@rpc("any_peer") func stop(player_id: int, position: float) -> void:
	if not multiplayer.is_server() or phase != Phase.PLAY or not sender_owns(player_id):
		return
	_stop(player_id, clampf(position, 0.0, 1.0))


func _stop(player_id: int, position: float) -> void:
	if stopped.has(player_id):
		return
	stopped[player_id] = true
	position = clampf(position, 0.0, 1.0)
	var since := ROUND_LIMIT - phase_time
	var off := absf(position - _zone_at(since)) / zone_half      # in zone half widths
	var tier := 0
	var gain := 0
	if off <= 0.2:
		tier = 4
		gain = 6
	elif off <= 0.55:
		tier = 3
		gain = 4
	elif off <= 1.0:
		tier = 2
		gain = 2
	elif off <= 2.0:
		tier = 1
		gain = 1
	lobby.broadcast(_client_stopped.bind(player_id, position, tier))
	_client_stopped(player_id, position, tier)
	if gain > 0:
		add_points(player_id, gain)
	react(player_id, tier >= 2)


func _end_round() -> void:
	phase = Phase.RESULT
	phase_time = RESULT_TIME
	for p in players:
		var id := p.info.player_id
		if not stopped.has(id):
			popup(id, "TOO SLOW", Color(1.0, 0.5, 0.4))
	lobby.broadcast(_client_round_over)
	_client_round_over()


# ----- every peer -----

func _update_zone_visuals() -> void:
	for id in zones:
		var zone: MeshInstance3D = zones[id]
		zone.scale.x = maxf(zone_half * 2.0 * BAR_WIDTH, 0.05)
		var seconds := _round_seconds()
		zone.position.x = podium_x[id] + (_zone_at(seconds) - 0.5) * BAR_WIDTH


func _round_seconds() -> float:
	if round_started_at == 0:
		return 0.0
	return (Time.get_ticks_msec() - round_started_at) / 1000.0


@rpc func _client_round(number: int, new_speed: float, new_half: float, new_center: float, new_drift: float) -> void:
	speed = new_speed
	zone_half = new_half
	zone_center = new_center
	zone_drift = new_drift
	drift_phase = 0.0
	playing = false
	round_started_at = 0
	frozen_at = {}
	big_text.text = "ROUND %d" % number
	small_text.text = "Stop the marker in the green zone!" if new_drift <= 0.0 else "The zone is moving!"
	for id in markers:
		markers[id].position.x = podium_x[id] - BAR_WIDTH / 2.0
		(markers[id].mesh.material as StandardMaterial3D).albedo_color = Color.WHITE
	_update_zone_visuals()


@rpc func _client_play() -> void:
	playing = true
	round_started_at = Time.get_ticks_msec()
	big_text.text = "STOP IT!"
	sound("res://assets/sounds/ui/turn_start.wav")


@rpc func _client_stopped(player_id: int, position: float, tier: int) -> void:
	frozen_at[player_id] = position
	if markers.has(player_id):
		markers[player_id].position.x = podium_x[player_id] + (position - 0.5) * BAR_WIDTH
		var mat := markers[player_id].mesh.material as StandardMaterial3D
		mat.albedo_color = [Color(0.8, 0.3, 0.3), Color(1.0, 0.7, 0.3), Color(0.9, 1.0, 0.4), Color(0.4, 1.0, 0.5), Color(0.3, 1.0, 1.0)][tier]
	var texts := ["MISS", "OK", "GOOD", "GREAT!", "PERFECT!"]
	var colors := [Color(1.0, 0.4, 0.4), Color(1.0, 0.8, 0.5), Color(0.9, 1.0, 0.4), Color(0.4, 1.0, 0.5), Color(0.4, 1.0, 1.0)]
	var p := player_by_id(player_id)
	if p:
		var label := Label3D.new()
		label.text = texts[tier]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.pixel_size = 0.0085 if tier >= 3 else 0.006
		label.font_size = 96
		label.outline_size = 24
		label.modulate = colors[tier]
		label.outline_modulate = Color(0.1, 0.05, 0.3)
		label.position = Vector3(podium_x[player_id], BAR_Y + 0.9, 2.2)
		add_child(label)
		var tween := create_tween().set_parallel()
		tween.tween_property(label, "position:y", label.position.y + 0.8, 0.9)
		tween.tween_property(label, "modulate:a", 0.0, 0.3).set_delay(0.7)
		tween.chain().tween_callback(label.queue_free)
	sound("res://assets/sounds/correct.wav" if tier >= 2 else "res://assets/sounds/wrong.wav")


@rpc func _client_round_over() -> void:
	playing = false
	big_text.text = "NICE!"


func world_tick(_delta: float) -> void:
	if not playing:
		return
	var seconds := _round_seconds()
	_update_zone_visuals()
	for id in markers:
		if not frozen_at.has(id):
			markers[id].position.x = podium_x[id] + (_marker_at(seconds, id) - 0.5) * BAR_WIDTH
	for p in players:
		if not is_mine(p) or frozen_at.has(p.info.player_id):
			continue
		if Input.is_action_just_pressed("player%d_action1" % p.info.player_id):
			# stop right away on this screen, the server then confirms it
			var pos := _marker_at(seconds, p.info.player_id)
			frozen_at[p.info.player_id] = pos
			stop.rpc_id(1, p.info.player_id, pos)
