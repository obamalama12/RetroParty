class_name ArcadeGame
extends Node3D
## Base of the small arcade minigames. It finds the players, builds the camera, light and floor, runs the clock and
## calls the hooks below. The server (the peer that decides) runs `server_tick`, every peer runs `world_tick`.

@export var duration := 30.0

var lobby: Lobby
var players: Array[ArcadePlayer] = []
var running := false
var finished := false
var time_left := 0.0

const NATURE := "res://assets/models/nature/glTF/"


func _enter_tree() -> void:
	lobby = Lobby.get_lobby(self)


func _ready() -> void:
	for i in 4:
		var p := get_node_or_null("Player%d" % (i + 1)) as ArcadePlayer
		if p:
			players.append(p)
	build_world()
	if has_node("Countdown"):
		$Countdown.finish.connect(_on_go)
	else:
		_on_go()
	_update_time_label()


# ----- hooks for the games -----

## Builds the arena. Called once, before the countdown.
func build_world() -> void:
	pass

## The countdown is over.
func on_go() -> void:
	pass

## Runs on every peer while the game is on.
func world_tick(_delta: float) -> void:
	pass

## Runs on the server only while the game is on.
func server_tick(_delta: float) -> void:
	pass

## The time is up (the server decides how the game ends).
func on_time_up() -> void:
	pass


# ----- the clock -----

func _on_go() -> void:
	running = true
	time_left = duration
	on_go()


func _physics_process(delta: float) -> void:
	if not running or finished:
		return
	time_left = maxf(time_left - delta, 0.0)
	_update_time_label()
	world_tick(delta)
	if multiplayer.is_server():
		server_tick(delta)
		if time_left <= 0.0:
			on_time_up()


func _update_time_label() -> void:
	var label := get_node_or_null("Screen/Time") as Label
	if label:
		label.text = "%d" % ceili(time_left if running else duration)


# ----- helpers for building the scene -----

func make_environment(sky: Color, ambient: Color) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)


func make_camera(pos: Vector3, look_at_point: Vector3, fov := 50.0) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = fov
	cam.position = pos
	add_child(cam)
	cam.look_at(look_at_point)
	cam.current = true
	return cam


func make_music(path: String) -> void:
	var stream := load(path) as AudioStream
	if stream == null:
		return
	var music := AudioStreamPlayer.new()
	music.stream = stream
	music.bus = &"Music"
	music.autoplay = true
	add_child(music)


func toon(color: Color, texture: Texture2D = null) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = texture
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_TOON
	m.roughness = 1.0
	return m


const FLOOR_SHADER := preload("res://common/scripts/arcade/arcade_floor.gdshader")


## A round floor with collision, its top at y = 0. `mode` picks the pattern of arcade_floor.gdshader.
func add_floor(radius: float, mode: int, colors: Array, count := 12.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Floor"
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.7
	cyl.radial_segments = 96
	var mat := ShaderMaterial.new()
	mat.shader = FLOOR_SHADER
	mat.set_shader_parameter("mode", mode)
	mat.set_shader_parameter("radius", radius)
	mat.set_shader_parameter("count", count)
	var names := ["color_a", "color_b", "color_c", "color_d"]
	for i in mini(colors.size(), 4):
		mat.set_shader_parameter(names[i], Vector3(colors[i].r, colors[i].g, colors[i].b))
	cyl.material = mat
	mesh.mesh = cyl
	mesh.position.y = -0.35
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = radius
	cs.height = 0.7
	shape.shape = cs
	shape.position.y = -0.35
	body.add_child(shape)
	add_child(body)
	# a stone rim around the edge so the floor looks like a stage
	var rim := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius - 0.12
	torus.outer_radius = radius + 0.28
	torus.material = toon(Color(0.93, 0.9, 0.85))
	rim.mesh = torus
	rim.position.y = -0.02
	rim.scale.y = 0.9
	add_child(rim)
	return body


## Places scenery on an arc of a circle around the origin (angles in degrees, 270 is straight away from the camera).
func arc_props(kinds: Array, count: int, radius: float, from_deg: float, to_deg: float, scale_min := 1.0, scale_max := 1.3,
		y := -0.4, seed_value := 1, jitter := 0.4) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var holder := Node3D.new()
	holder.name = "Props"
	add_child(holder)
	var scenes: Array[PackedScene] = []
	for kind: String in kinds:
		var path := kind if kind.begins_with("res://") else NATURE + kind + ".gltf"
		var scene := load(path) as PackedScene
		if scene:
			scenes.append(scene)
	if scenes.is_empty():
		return holder
	for i in count:
		var t := float(i) / maxf(count - 1, 1)
		var ang := deg_to_rad(lerpf(from_deg, to_deg, t))
		var r := radius + rng.randf_range(-jitter, jitter)
		var inst := scenes[i % scenes.size()].instantiate() as Node3D
		inst.position = Vector3(cos(ang) * r, y, sin(ang) * r)
		inst.rotation.y = rng.randf() * TAU
		inst.scale = Vector3.ONE * rng.randf_range(scale_min, scale_max)
		holder.add_child(inst)
	return holder


## A low picket fence along an arc, built from boxes: posts with two rails between them.
func fence_arc(radius: float, from_deg: float, to_deg: float, segments: int, color := Color(0.97, 0.94, 0.88), post_color := Color(0.78, 0.55, 0.32)) -> void:
	var holder := Node3D.new()
	holder.name = "Fence"
	add_child(holder)
	var angles: Array[float] = []
	for i in segments + 1:
		angles.append(deg_to_rad(lerpf(from_deg, to_deg, float(i) / maxf(segments, 1))))
	var post_mat := toon(post_color)
	var rail_mat := toon(color)
	for i in angles.size():
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.22, 1.1, 0.22)
		box.material = post_mat
		post.mesh = box
		post.position = Vector3(cos(angles[i]) * radius, 0.55, sin(angles[i]) * radius)
		holder.add_child(post)
		var cap := MeshInstance3D.new()
		var cap_mesh := SphereMesh.new()
		cap_mesh.radius = 0.16
		cap_mesh.height = 0.32
		cap_mesh.material = post_mat
		cap.mesh = cap_mesh
		cap.position = post.position + Vector3(0, 0.62, 0)
		holder.add_child(cap)
		if i == 0:
			continue
		var p0 := Vector3(cos(angles[i - 1]) * radius, 0.0, sin(angles[i - 1]) * radius)
		var p1 := Vector3(cos(angles[i]) * radius, 0.0, sin(angles[i]) * radius)
		for height in [0.38, 0.8]:
			var rail := MeshInstance3D.new()
			var rail_box := BoxMesh.new()
			rail_box.size = Vector3(p0.distance_to(p1) + 0.02, 0.14, 0.09)
			rail_box.material = rail_mat
			rail.mesh = rail_box
			rail.position = (p0 + p1) / 2.0 + Vector3(0, height, 0)
			rail.rotation.y = -atan2(p1.z - p0.z, p1.x - p0.x)
			holder.add_child(rail)


## Poles with a ball on top, evenly spaced around a circle (balloon stands, torches, lamps ...).
func pole_ring(radius: float, count: int, height: float, pole_color: Color, ball_color: Color, alt_color := Color(-1, 0, 0), from_deg := 0.0, to_deg := 360.0) -> void:
	for i in count:
		var t: float = float(i) / (count if to_deg - from_deg >= 359.0 else maxf(count - 1, 1))
		var ang := deg_to_rad(lerpf(from_deg, to_deg, t))
		var node := Node3D.new()
		node.position = Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.07
		cyl.bottom_radius = 0.1
		cyl.height = height
		cyl.material = toon(pole_color)
		pole.mesh = cyl
		pole.position.y = height / 2.0
		node.add_child(pole)
		var ball := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.28
		sph.height = 0.56
		sph.material = toon(alt_color if (alt_color.r >= 0.0 and i % 2 == 1) else ball_color)
		ball.mesh = sph
		ball.position.y = height + 0.2
		node.add_child(ball)
		add_child(node)


func make_sky(top: Color, horizon: Color, ground: Color) -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = top
	sky_material.sky_horizon_color = horizon
	sky_material.ground_horizon_color = horizon
	sky_material.ground_bottom_color = ground
	sky_material.sun_angle_max = 8.0
	var sky := Sky.new()
	sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -28, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)


## Scenery outside of a circle: rocks, bushes and trees from the nature models.
func decorate(inner_radius: float, outer_radius: float, count: int, kinds: Array, seed_value := 1, behind_only := true) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var scenes: Array[PackedScene] = []
	for kind: String in kinds:
		var scene := load(NATURE + kind + ".gltf") as PackedScene
		if scene:
			scenes.append(scene)
	if scenes.is_empty():
		return
	var holder := Node3D.new()
	holder.name = "Scenery"
	add_child(holder)
	for i in count:
		var inst := scenes[rng.randi() % scenes.size()].instantiate() as Node3D
		var ang := rng.randf() * TAU
		if behind_only:
			ang = -rng.randf() * PI * 1.15 + PI * 0.075      # the far half, so nothing hides the arena from the camera
		var r := rng.randf_range(inner_radius, outer_radius)
		inst.position = Vector3(cos(ang) * r, -0.35, sin(ang) * r)
		inst.rotation.y = rng.randf() * TAU
		inst.scale = Vector3.ONE * rng.randf_range(1.0, 1.7)
		holder.add_child(inst)


func sound(path: String) -> void:
	var stream := load(path) as AudioStream
	if stream == null:
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.bus = &"Effects"
	add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


## Pops a big message up in the middle of the screen on every peer (the server calls this).
func announce(text: String, color := Color(1.0, 0.88, 0.25), hold := 1.1) -> void:
	lobby.broadcast(_announce.bind(text, color, hold))
	_announce(text, color, hold)


@rpc func _announce(text: String, color: Color, hold: float) -> void:
	var screen := get_node_or_null("Screen") as Control
	if screen == null:
		return
	if hold >= 0.8:
		sound("res://assets/sounds/ui/round_win.wav")
	var label := Label.new()
	label.text = text
	label.theme_type_variation = &"HeaderLarge"
	label.add_theme_font_size_override("font_size", 78)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.1, 0.05, 0.3))
	label.add_theme_constant_override("outline_size", 14)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	label.offset_left = -500
	label.offset_right = 500
	label.offset_top = 120
	label.offset_bottom = 220
	label.pivot_offset = Vector2(500, 50)
	label.scale = Vector2.ZERO
	screen.add_child(label)
	var tween := create_tween()
	tween.tween_property(label, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(hold)
	tween.tween_property(label, "modulate:a", 0.0, 0.3)
	tween.tween_callback(label.queue_free)


func player_by_id(player_id: int) -> ArcadePlayer:
	for p in players:
		if p.info.player_id == player_id:
			return p
	return null


# ----- finishing -----

## Ends a game that is won by points (one entry per player node, in order), for FFA, Duel and 2v2.
func finish_by_points(points: Array) -> void:
	if finished:
		return
	finished = true
	match lobby.minigame_state.minigame_type:
		Lobby.MINIGAME_TYPES.ONE_VS_THREE:
			# the solo player (the last player node) scores three times, so the sides are even
			var team_total: float = points[0] + points[1] + points[2]
			var solo_total: float = points[3] * 3.0
			if team_total > solo_total:
				lobby.minigame_1v3_win_team_players()
			elif team_total < solo_total:
				lobby.minigame_1v3_win_solo_player()
			else:
				lobby.minigame_1v3_draw()
		Lobby.MINIGAME_TYPES.TWO_VS_TWO:
			lobby.minigame_team_win_by_points([points[0] + points[1], points[2] + points[3]])
		_:
			lobby.minigame_win_by_points(points)
