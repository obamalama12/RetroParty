extends Node3D

@onready var lobby := Lobby.get_lobby(self)

const GAME_DURATION := 45.0
## The bed can take this many hits. A ghost that reaches it is gone, but costs a point of bed health (a boss costs two),
## so one slip does not end the game after a few seconds.
const BED_HEALTH := 6
const POWERUP_FLASH := 0
const POWERUP_FREEZE := 1

var finished := false
var freeze_time := 0.0
var elapsed := 0.0
var boss_spawned := false
var powerup_timer := 6.0
var next_powerup_id := 0
var powerups := {}
var kills := 0
var bed_health := BED_HEALTH
var bed_label: Label

func _ready() -> void:
	bed_label = Label.new()
	bed_label.theme_type_variation = &"HeaderMedium"
	bed_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	bed_label.position = Vector2(24, 20)
	bed_label.add_theme_color_override(&"font_color", Color(1.0, 0.85, 0.85))
	$Control.add_child(bed_label)
	_client_bed(bed_health)

## Server: a ghost reached the bed
func ghost_reached_bed(ghost: Node) -> void:
	if finished or ghost.dead:
		return
	ghost.dead = true
	lobby.broadcast(ghost.delete)
	ghost.delete()
	bed_health = maxi(bed_health - (2 if ghost.kind == ghost.Kind.BOSS else 1), 0)
	lobby.broadcast(_client_bed.bind(bed_health))
	_client_bed(bed_health)
	lobby.broadcast(screen_flash.bind(Color(1, 0.2, 0.2, 0.5)))
	screen_flash(Color(1, 0.2, 0.2, 0.5))
	if bed_health <= 0:
		end_game()

@rpc func _client_bed(health: int) -> void:
	if bed_label:
		bed_label.text = "BED HEALTH  %d / %d" % [health, BED_HEALTH]

func end_game():
	setup_game_end()
	lobby.broadcast(_client_game_failed)
	await get_tree().create_timer(3).timeout
	lobby.minigame_gnu_loose()

func setup_game_end():
	finished = true
	for node in Utility.get_nodes_in_group(self, &"ghost"):
		node.finished = true
	lobby.broadcast(game_ended)
	$Player1.process_mode = Node.PROCESS_MODE_DISABLED
	$Player2.process_mode = Node.PROCESS_MODE_DISABLED
	$Player3.process_mode = Node.PROCESS_MODE_DISABLED
	$Player4.process_mode = Node.PROCESS_MODE_DISABLED

@rpc
func _client_game_failed():
	$LoseSound.play()
	for node in Utility.get_nodes_in_group(self, &"ghost"):
		node.win()

func _server_process(delta):
	freeze_time = maxf(0.0, freeze_time - delta)
	if $Control/Duration.time_left == 0 and not finished:
		setup_game_end()
		await get_tree().create_timer(3).timeout
		lobby.minigame_gnu_win()

func _client_process(_delta):
	if freeze_overlay and freeze_overlay.visible and Time.get_ticks_msec() > freeze_until:
		freeze_overlay.hide()
	$Control/Timer.text = "%.1f" % snapped($Control/Duration.time_left, 0.1)

@rpc func game_ended():
	$Control/Timer.hide()
	$Control/Message.show()
	$Player1.process_mode = Node.PROCESS_MODE_DISABLED
	$Player2.process_mode = Node.PROCESS_MODE_DISABLED
	$Player3.process_mode = Node.PROCESS_MODE_DISABLED
	$Player4.process_mode = Node.PROCESS_MODE_DISABLED

var freeze_overlay: ColorRect
var freeze_until := 0

@rpc func announce(text: String, color: Color):
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderLarge"
	label.add_theme_color_override(&"font_color", color)
	label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	label.position.y = 90
	$Control.add_child(label)
	var tween := create_tween()
	tween.tween_interval(1.2)
	tween.tween_property(label, ^"modulate:a", 0.0, 0.6)
	tween.tween_callback(label.queue_free)

@rpc func screen_flash(color: Color):
	var rect := ColorRect.new()
	rect.color = color
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$Control.add_child(rect)
	var tween := create_tween()
	tween.tween_property(rect, ^"color:a", 0.0, 0.5)
	tween.tween_callback(rect.queue_free)

@rpc func start_freeze(duration: float):
	if freeze_overlay == null:
		freeze_overlay = ColorRect.new()
		freeze_overlay.color = Color(0.4, 0.7, 1.0, 0.2)
		freeze_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		freeze_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		$Control.add_child(freeze_overlay)
	freeze_overlay.show()
	freeze_until = Time.get_ticks_msec() + int(duration * 1000)

@rpc func spawn_ghost(pos: Vector3, ghostname: String, kind := 0):
	var ghost = preload("res://plugins/minigames/haunted_dreams/ghost.tscn").instantiate()
	ghost.position = pos
	ghost.name = ghostname
	ghost.kind = kind
	add_child(ghost)

@rpc func spawn_powerup(id: int, type: int, pos: Vector3):
	var area := Area3D.new()
	area.add_to_group(&"powerup")
	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.7
	col.shape = shape
	area.add_child(col)
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1, 0.95, 0.5) if type == POWERUP_FLASH else Color(0.4, 0.8, 1)
	mesh.material_override = material
	area.add_child(mesh)
	var light := OmniLight3D.new()
	light.light_color = material.albedo_color
	light.omni_range = 3.0
	area.add_child(light)
	add_child(area)
	area.position = pos
	area.set_meta(&"type", type)
	powerups[id] = area
	var tween := mesh.create_tween().set_loops()
	tween.tween_property(mesh, ^"position:y", 0.25, 0.5).set_trans(Tween.TRANS_SINE)
	tween.tween_property(mesh, ^"position:y", -0.1, 0.5).set_trans(Tween.TRANS_SINE)
	if multiplayer.is_server():
		area.body_entered.connect(_on_powerup_entered.bind(id, type))
		get_tree().create_timer(9.0).timeout.connect(_expire_powerup.bind(id))

func _expire_powerup(id: int):
	if powerups.has(id):
		lobby.broadcast(remove_powerup.bind(id))
		remove_powerup(id)

@rpc func remove_powerup(id: int):
	if powerups.has(id):
		powerups[id].queue_free()
		powerups.erase(id)

func _on_powerup_entered(body: Node3D, id: int, type: int):
	if finished or not powerups.has(id) or not body.is_in_group(&"player"):
		return
	lobby.broadcast(remove_powerup.bind(id))
	remove_powerup(id)
	match type:
		POWERUP_FLASH:
			lobby.broadcast(screen_flash.bind(Color(1, 1, 0.8, 0.8)))
			screen_flash(Color(1, 1, 0.8, 0.8))
			lobby.broadcast(announce.bind(tr("HAUNTED_DREAMS_FLASH"), Color(1, 0.95, 0.5)))
			announce(tr("HAUNTED_DREAMS_FLASH"), Color(1, 0.95, 0.5))
			for ghost in Utility.get_nodes_in_group(self, &"ghost"):
				ghost.take_hit(2 if ghost.kind == ghost.Kind.BOSS else 99, true)
		POWERUP_FREEZE:
			freeze_time = 4.0
			lobby.broadcast(start_freeze.bind(4.0))
			start_freeze(4.0)
			lobby.broadcast(announce.bind(tr("HAUNTED_DREAMS_FREEZE"), Color(0.5, 0.85, 1)))
			announce(tr("HAUNTED_DREAMS_FREEZE"), Color(0.5, 0.85, 1))

func on_ghost_killed(ghost: Node):
	kills += 1
	if ghost.kind == ghost.Kind.BOSS:
		lobby.broadcast(screen_flash.bind(Color(0.8, 0.5, 1, 0.6)))
		screen_flash(Color(0.8, 0.5, 1, 0.6))
		lobby.broadcast(announce.bind(tr("HAUNTED_DREAMS_BOSS_DEFEATED"), Color(0.8, 0.5, 1)))
		announce(tr("HAUNTED_DREAMS_BOSS_DEFEATED"), Color(0.8, 0.5, 1))

func _random_ghost_pos() -> Vector3:
	var dir := randf() * 2 * PI
	return Vector3(cos(dir) * 10, 1, sin(dir) * 10)

var num_ghost_spawned := 0
func _spawn_one(kind: int):
	var pos := _random_ghost_pos()
	num_ghost_spawned += 1
	var ghostname := "Ghost" + str(num_ghost_spawned)
	lobby.broadcast(spawn_ghost.bind(pos, ghostname, kind))
	spawn_ghost(pos, ghostname, kind)

func _on_Timer_timeout():
	if not multiplayer.is_server() or finished:
		return
	var time_left: float = $Control/Duration.time_left
	if time_left <= 5:
		return
	elapsed = GAME_DURATION - time_left
	var progress := clampf(elapsed / GAME_DURATION, 0.0, 1.0)
	# The ghosts come faster and faster
	$SpawnTimer.wait_time = lerpf(1.3, 0.4, progress)
	
	# Boss ghost halfway through
	if not boss_spawned and elapsed > GAME_DURATION * 0.5:
		boss_spawned = true
		_spawn_one(3) # Boss
		lobby.broadcast(announce.bind(tr("HAUNTED_DREAMS_BOSS"), Color(0.8, 0.4, 1)))
		announce(tr("HAUNTED_DREAMS_BOSS"), Color(0.8, 0.4, 1))
	
	var kind := 0
	var roll := randf()
	if progress > 0.5 and roll < 0.18:
		kind = 2 # Tank
	elif progress > 0.3 and roll < 0.4:
		kind = 1 # Fast
	_spawn_one(kind)
	# Sometimes a pack of ghosts arrives at once
	if progress > 0.25 and randf() < 0.08 + progress * 0.1:
		for _i in range(3):
			_spawn_one(0)
	
	powerup_timer -= $SpawnTimer.wait_time
	if powerup_timer <= 0:
		powerup_timer = 8.0 + randf() * 3.0
		var angle := randf() * 2 * PI
		var pos := Vector3(cos(angle), 0.6, sin(angle)) * (2.0 + randf() * 2.5)
		var type := POWERUP_FREEZE if randf() < 0.4 else POWERUP_FLASH
		var id := next_powerup_id
		next_powerup_id += 1
		lobby.broadcast(spawn_powerup.bind(id, type, pos))
		spawn_powerup(id, type, pos)
