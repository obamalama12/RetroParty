extends RigidBody3D

const BOMB := preload("res://plugins/minigames/boat_rally/bomb.tscn")
const MAX_SPEED := 10.0
const BOOST_SPEED := 17.0
const BOOST_DURATION := 3.5
const FINISH_Z := 360.0
const BOMB_STOP_Z := FINISH_Z - 12.0
const ROCK := preload("res://plugins/minigames/boat_rally/formationLarge_rock.tscn")
const PICKUP_BOOST := 0
const PICKUP_SHIELD := 1

@onready var lobby := Lobby.get_lobby(self)

var countdown := 1.0
var is_hit := false
var boost_time := 0.0
var shield := false
var shield_mesh: MeshInstance3D
var pickups := {}
var next_pickup_id := 0
var pickup_countdown := 3.0
var wave := 0
var finished := false
## The boat survives this many bombs (the last one sinks it), and cannot be hit again for a moment after a hit.
const MAX_LIVES := 3
const HIT_PROTECTION := 2.0
var lives := MAX_LIVES
var protection := 0.0

@rpc func hit_popup(lives_left: int) -> void:
	show_popup(tr("BOAT_RALLY_OUCH").format({"lives": lives_left}), Color(1, 0.35, 0.3))
	play_sound("res://assets/sounds/wrong.wav", 0.7)

func _integrate_forces(state):
	if is_hit:
		state.linear_velocity = Vector3()
		state.angular_velocity = Vector3()
	
	var max_speed := BOOST_SPEED if boost_time > 0 else MAX_SPEED
	if state.linear_velocity.length() > max_speed:
		state.linear_velocity = state.linear_velocity.normalized() * max_speed
	if rotation_degrees.y < -45:
		rotation_degrees.y = -45
		state.angular_velocity = Vector3(0, 1, 0)
	elif rotation_degrees.y > 45:
		rotation_degrees.y = 45
		state.angular_velocity = Vector3(0, -1, 0)

func _ready():
	$Ground.set_as_top_level(true)
	extend_track()

# Makes the course longer: more rocks along the sides, a bigger sea and the finish line further away
func extend_track():
	var z := 120.0
	while z < FINISH_Z + 12.0:
		for x in [12.0, -10.0]:
			var rock := ROCK.instantiate()
			rock.position = Vector3(x, -1, z)
			rock.rotation.y = PI / 2
			$Ground.add_child(rock)
		z += 4.0
	$Ground/Area3D.position.z = FINISH_Z
	$Ground/MeshInstance3D.scale.z = 4.0
	$Ground/MeshInstance3D.position.z = 170.0

@rpc("any_peer") func fire(pos: Vector3, dir: Vector3):
	if not is_hit:
		self.apply_impulse(dir, pos)
		return true
	return false

func _process(_delta):
	$"Ground/Scene Root2".position.z = self.position.z + 20
	$"Ground/Scene Root3".position.z = self.position.z + 40

@rpc func spawn_bombs(positions: Array):
	var i := 0
	for pos in positions:
		var bomb = BOMB.instantiate()
		bomb.position = pos
		bomb.name = "Bomb" + str(i)
		$Ground.add_child(bomb)
		i += 1
	if not multiplayer.is_server():
		$AudioStreamPlayer.play()

@rpc func update_position(trans: Vector3, rot: Vector3):
	self.position = trans
	self.rotation = rot

func show_popup(text: String, color: Color):
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.outline_size = 16
	label.pixel_size = 0.012
	label.font_size = 64
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	label.position = Vector3(0, 2.5, 0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", 4.5, 1.0)
	tween.tween_property(label, "modulate:a", 0.0, 0.8).set_delay(0.4)
	tween.chain().tween_callback(label.queue_free)

func play_sound(path: String, pitch := 1.0):
	var player := AudioStreamPlayer.new()
	player.stream = load(path)
	player.pitch_scale = pitch
	player.bus = &"Effects"
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()

func make_pickup_mesh(type: int) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if type == PICKUP_BOOST:
		var prism := PrismMesh.new()
		prism.size = Vector3(1.2, 1.6, 0.6)
		mesh.mesh = prism
		material.albedo_color = Color(1, 0.8, 0.1)
		mesh.rotation_degrees.x = 90
	else:
		var sphere := SphereMesh.new()
		sphere.radius = 0.7
		sphere.height = 1.4
		mesh.mesh = sphere
		material.albedo_color = Color(0.3, 0.9, 1)
	mesh.material_override = material
	return mesh

@rpc func spawn_pickup(id: int, type: int, pos: Vector3):
	var area := Area3D.new()
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 1.4
	col.shape = shape
	area.add_child(col)
	var mesh := make_pickup_mesh(type)
	mesh.name = "Mesh"
	area.add_child(mesh)
	$Ground.add_child(area)
	area.position = pos
	pickups[id] = area
	var tween := mesh.create_tween().set_loops()
	tween.tween_property(mesh, "position:y", 0.4, 0.6).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh, "position:y", -0.4, 0.6).set_trans(Tween.TRANS_SINE)
	var spin := mesh.create_tween().set_loops()
	spin.tween_property(mesh, "scale", Vector3(1.25, 1.25, 1.25), 0.4)
	spin.tween_property(mesh, "scale", Vector3(0.9, 0.9, 0.9), 0.4)
	if multiplayer.is_server():
		area.body_entered.connect(_on_pickup_entered.bind(id, type))

func _on_pickup_entered(body, id: int, type: int):
	if body != self or not pickups.has(id) or is_hit:
		return
	lobby.broadcast(collect_pickup.bind(id, type))
	collect_pickup(id, type)

@rpc func collect_pickup(id: int, type: int):
	if pickups.has(id):
		pickups[id].queue_free()
		pickups.erase(id)
	if type == PICKUP_BOOST:
		boost_time = BOOST_DURATION
		if multiplayer.is_server():
			apply_central_impulse(Vector3(0, 0, 6))
		show_popup(tr("BOAT_RALLY_BOOST"), Color(1, 0.85, 0.1))
		play_sound("res://assets/sounds/correct.wav", 1.5)
		var cam: Camera3D = $Camera3D
		var tween := create_tween()
		tween.tween_property(cam, "fov", cam.fov + 15, 0.2)
		tween.tween_property(cam, "fov", cam.fov, 0.6).set_delay(BOOST_DURATION - 0.8)
	else:
		set_shield(true)
		show_popup(tr("BOAT_RALLY_SHIELD"), Color(0.3, 0.9, 1))
		play_sound("res://assets/sounds/correct.wav", 1.0)

@rpc func set_shield(on: bool):
	shield = on
	if on and shield_mesh == null:
		shield_mesh = MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 2.4
		sphere.height = 4.8
		shield_mesh.mesh = sphere
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(0.3, 0.9, 1, 0.25)
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		shield_mesh.material_override = material
		add_child(shield_mesh)
		shield_mesh.position = Vector3(0, 0.2, 0.3)
	if shield_mesh:
		shield_mesh.visible = on
	if not on:
		show_popup(tr("BOAT_RALLY_SHIELD_BREAK"), Color(1, 0.5, 0.3))
		play_sound("res://assets/sounds/wrong.wav", 1.2)

func break_shield():
	lobby.broadcast(set_shield.bind(false))
	set_shield(false)

@rpc func celebrate():
	show_popup(tr("BOAT_RALLY_FINISH"), Color(1, 1, 0.3))
	play_sound("res://assets/sounds/correct.wav", 1.8)
	var tween := create_tween()
	tween.tween_property($Camera3D, "fov", $Camera3D.fov + 25, 0.8)

func spawn_wave():
	# The further the boat gets, the denser the waves are
	var progress := clampf(position.z / BOMB_STOP_Z, 0.0, 1.0)
	var positions := []
	var count := 4 + int(progress * 3.0)
	for _i in range(count):
		positions.append(Vector3((randf() - 0.5) * 16, 20, 10 + randf() * 10 + position.z))
		positions.append(Vector3((randf() - 0.5) * 16, 20, randf() * 5 + position.z))
	# Aimed bombs: later on some of them are dropped where the boat is heading
	if progress > 0.3:
		var aimed := 1 + int(progress * 2.0)
		for _i in range(aimed):
			var target := position + linear_velocity * 2.0
			positions.append(Vector3(clampf(target.x + (randf() - 0.5) * 3, -8, 8), 20, target.z + (randf() - 0.5) * 2))
	lobby.broadcast(spawn_bombs.bind(positions))
	spawn_bombs(positions)
	wave += 1

func spawn_pickups():
	var type := PICKUP_SHIELD if (randf() < 0.3 and not shield) else PICKUP_BOOST
	var pos := Vector3((randf() - 0.5) * 12, 0.6, position.z + 14 + randf() * 8)
	var id := next_pickup_id
	next_pickup_id += 1
	lobby.broadcast(spawn_pickup.bind(id, type, pos))
	spawn_pickup(id, type, pos)

func _server_process(delta):
	countdown -= delta
	protection = maxf(0.0, protection - delta)
	boost_time = maxf(0.0, boost_time - delta)
	if not finished and not is_hit:
		pickup_countdown -= delta
		if pickup_countdown <= 0 and position.z <= BOMB_STOP_Z:
			spawn_pickups()
			pickup_countdown = 3.0 + randf() * 2.0
	if countdown <= 0 and position.z <= BOMB_STOP_Z:
		spawn_wave()
		countdown = lerpf(4.0, 2.6, clampf(position.z / BOMB_STOP_Z, 0.0, 1.0))
	lobby.broadcast(update_position.bind(self.position, self.rotation))

func _on_Area_body_entered(body):
	if not multiplayer.is_server():
		return
	if body.is_in_group("player") and not finished and not is_hit:
		finished = true
		lobby.broadcast(celebrate)
		celebrate()
		await get_tree().create_timer(1.2).timeout
		lobby.minigame_nolok_win()
