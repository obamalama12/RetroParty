extends Node3D

const LAVA_RISE_SPEED = 0.18
const SURGE_HEIGHT := 0.45
const SURGE_SPEED := 1.1
const SURGE_WARNING_TIME := 1.8
const PICKUP_BOOST := 0
const PICKUP_RUSH := 1
const BOOST_TIME := 3.0

# Player Ids that reached the finish line
var winners = []
# Player Ids that got knocked out by the lava
var dead = []

@onready var player_count := len(Utility.get_nodes_in_group(self, "players"))
@onready var lobby := Lobby.get_lobby(self)

func process_stage(stage):
	var index = (randi() % stage.get_child_count())
	stage.get_child(index).can_be_opened = false

func _ready():
	if multiplayer.is_server():
		_do_server_setup()

func _do_server_setup():
	process_stage($Stage1)
	process_stage($Stage2)
	process_stage($Stage3)

# Lava surge state (server)
var lava_time := 0.0
var next_surge := 8.0
var surge_warning := 0.0
var surge_left := 0.0
var pickups_spawned := false
var pickups := {}
var shake := 0.0

func _allow_rush() -> bool:
	return true

func show_banner(text: String, color: Color):
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderLarge"
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_shadow_color", Color.BLACK)
	label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.position.y = 110
	$Screen.add_child(label)
	var tween := create_tween()
	tween.tween_interval(1.0)
	tween.tween_property(label, ^"modulate:a", 0.0, 0.5)
	tween.tween_callback(label.queue_free)

func play_sound(path: String, pitch := 1.0):
	var player := AudioStreamPlayer.new()
	player.stream = load(path)
	player.pitch_scale = pitch
	player.bus = &"Effects"
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

@rpc func surge_warn():
	show_banner(tr("ESCAPE_FROM_LAVA_SURGE_WARNING"), Color(1, 0.4, 0.1))
	play_sound("res://assets/sounds/wrong.wav", 0.6)
	shake = 0.15

@rpc func surge_hit():
	shake = 0.5
	play_sound("res://assets/sounds/wrong.wav", 0.5)

func start_surge():
	if surge_warning > 0 or surge_left > 0:
		return
	surge_warning = SURGE_WARNING_TIME
	lobby.broadcast(surge_warn)
	surge_warn()

func spawn_pickups():
	pickups_spawned = true
	var candidates := []
	for waypoint in $Navigation.get_children():
		if waypoint.position.z > -22 and waypoint.position.z < 14:
			candidates.append(waypoint)
	candidates.shuffle()
	var id := 0
	for waypoint in candidates.slice(0, 7):
		var type := PICKUP_BOOST
		if _allow_rush() and id % 3 == 2:
			type = PICKUP_RUSH
		var pos: Vector3 = waypoint.position + Vector3(0, 0.9, 0)
		lobby.broadcast(spawn_pickup.bind(id, type, pos))
		spawn_pickup(id, type, pos)
		id += 1

@rpc func spawn_pickup(id: int, type: int, pos: Vector3):
	var area := Area3D.new()
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.8
	col.shape = shape
	area.add_child(col)
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.3
	sphere.height = 0.6
	mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 1, 0.4) if type == PICKUP_BOOST else Color(1, 0.2, 0.1)
	mesh.material_override = material
	area.add_child(mesh)
	add_child(area)
	area.position = pos
	pickups[id] = area
	var tween := mesh.create_tween().set_loops()
	tween.tween_property(mesh, ^"position:y", 0.25, 0.5).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh, ^"position:y", -0.15, 0.5).set_trans(Tween.TRANS_SINE)
	if multiplayer.is_server():
		area.body_entered.connect(_on_pickup_entered.bind(id, type))

func _on_pickup_entered(body, id: int, type: int):
	if not pickups.has(id) or not body.is_in_group("players") or body.is_dead():
		return
	lobby.broadcast(collect_pickup.bind(id, type, body.get_path()))
	collect_pickup(id, type, body.get_path())
	if type == PICKUP_RUSH:
		start_surge()

@rpc func collect_pickup(id: int, type: int, player_path: NodePath):
	if pickups.has(id):
		pickups[id].queue_free()
		pickups.erase(id)
	var player = get_node_or_null(player_path)
	if player:
		if type == PICKUP_BOOST:
			player.apply_boost(BOOST_TIME)
			player.show_popup(tr("ESCAPE_FROM_LAVA_BOOST"), Color(0.4, 1, 0.5))
		else:
			player.show_popup(tr("ESCAPE_FROM_LAVA_RUSH"), Color(1, 0.4, 0.2))
	play_sound("res://assets/sounds/correct.wav", 1.4 if type == PICKUP_BOOST else 0.7)

func _client_process(delta):
	if shake > 0:
		shake = maxf(0.0, shake - delta)
		$Camera3D.h_offset = randf_range(-shake, shake)
		$Camera3D.v_offset = randf_range(-shake, shake)
	else:
		$Camera3D.h_offset = 0.0
		$Camera3D.v_offset = 0.0
	var min_progress = null
	
	for player in Utility.get_nodes_in_group(self, "players"):
		if not player.is_dead() and (min_progress == null or player.position.z < min_progress.z):
			min_progress = player.position
	
	if min_progress != null:
		$Camera3D.position +=  (Vector3(0, min_progress.y, min_progress.z) + Vector3(0, 3, -4) - $Camera3D.position) * delta

func _server_process(delta):
	if not pickups_spawned:
		spawn_pickups()
	var rising: bool = $EndTimer.is_stopped()
	if rising:
		lava_time += delta
		# The lava gets slowly faster, and periodically surges after a warning
		var speed := LAVA_RISE_SPEED * (1.0 + lava_time * 0.012)
		$Lava.position += Vector3(0, 1, 0) * delta * speed
		next_surge -= delta
		if next_surge <= 0:
			next_surge = 8.0 + randf() * 3.0
			start_surge()
		if surge_warning > 0:
			surge_warning -= delta
			if surge_warning <= 0:
				surge_left = SURGE_HEIGHT
				lobby.broadcast(surge_hit)
				surge_hit()
		elif surge_left > 0:
			var step := minf(surge_left, SURGE_SPEED * delta)
			surge_left -= step
			$Lava.position.y += step
	lobby.broadcast(set_lava_height.bind($Lava.position.y))

@rpc func set_lava_height(height: float):
	$Lava.position.y = height

func _on_Lava_body_entered(body):
	if not is_multiplayer_authority():
		return
	
	if body.is_in_group("players"):
		if not body.is_dead():
			body.die()
			
			dead.push_front(body.info.player_id)
			
			check_game_over()
	elif body.is_in_group("door"):
		body.destroy()


func _on_Finish_body_entered(body):
	if not is_multiplayer_authority():
		return
	
	if body.is_in_group("players") and not body.is_dead():
		winners.push_back(body.info.player_id)
		body.die()
		check_game_over()

func check_game_over():
	# There is at most one surviving player
	if len(winners) + len(dead) >= player_count - 1:
		var count = 0
		# Find the remaining player if any and declare them as winner
		for node in Utility.get_nodes_in_group(self, "players"):
			if not node.is_dead():
				winners.push_back(node.info.player_id)
				count += 1
				node.die()
		# Assert that we did not fuck up somewhere
		assert(count <= 1)
		lobby.broadcast(end_game)
		$EndTimer.start()

@rpc func end_game():
	$Screen/Label.show()

func _on_EndTimer_timeout():
	if lobby.minigame_state.minigame_type == lobby.MINIGAME_TYPES.DUEL or lobby.minigame_state.minigame_type == lobby.MINIGAME_TYPES.FREE_FOR_ALL:
		lobby.minigame_win_by_position(winners + dead)
	else:
		lobby.minigame_team_win_by_player((winners + dead)[0])
