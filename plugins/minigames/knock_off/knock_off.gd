extends Node3D

var lobby: Lobby

@onready var players = Utility.get_nodes_in_group(self, "players")

## Everybody has this many lives: the first time you fall off you come back on the ice, the second time you are out.
## That keeps a round going for a decent time instead of ending with the first push.
const LIVES := 2
var lives := {} # player id -> lives left (server)

var losses = 0 # Number of players that have been knocked-out
var placement# Placements, is filled with player id in order. Index 0 is first place
var timer_end = 4 # How long the winning message will be shown before exiting
var timer_end_start = false # When to start the end timer

var winner_team

var human_players := 0

var ground_edges = {}

# --- Shrinking ice, power-up orbs and sudden death ---
# The ice gets smaller at these points of time (seconds after the start)
const SHRINK_TIMES := [14.0, 26.0, 38.0, 50.0]
const SHRINK_FACTORS := [0.88, 0.77, 0.66, 0.55]
const SHRINK_WARNING := 2.0
const SHRINK_DURATION := 2.0
const SUDDEN_DEATH_TIME := 60.0
const POWER_DURATION := 6.0
const ORB_INTERVAL := 5.0
const ORB_LIFETIME := 12.0
const ORB_COLORS := [Color.WHITE, Color(1, 0.85, 0.1), Color(0.9, 0.2, 0.2)]

const SND_CRACK := preload("res://assets/sounds/arcade/thud.wav")
const SND_POWER := preload("res://assets/sounds/ui/turn_start.wav")
const SND_ORB := preload("res://assets/sounds/correct.wav")

var elapsed := 0.0
var shrink_stage := 0
var shrink_warned := false
var sudden_death := false
var ice_base_scale := Vector3.ONE
var orb_timer := 4.0
var orb_counter := 0
var orbs := {} # id -> {"pos": Vector3, "type": int, "age": float}
var orb_nodes := {} # id -> Node3D (clients and server)
var banner: Label
var banner_tween: Tween

func _enter_tree() -> void:
	lobby = Lobby.get_lobby(self)

func _ready():
	$Environment/Screen/Message.hide()
	
	if lobby.minigame_state.minigame_type == Lobby.MINIGAME_TYPES.DUEL:
		placement = [0, 0]
	else:
		placement = [0, 0, 0, 0]
	
	var i = 1
	for team_id in range(lobby.minigame_state.minigame_teams.size()):
		for player in lobby.minigame_state.minigame_teams[team_id]:
			var player_node = get_node("Player{0}".format([i]))
			player_node.team = team_id
			if not player_node.info.is_ai():
				human_players += 1
			i += 1
	
	precompute_ground_edges()
	ice_base_scale = $ice.scale
	
	banner = Label.new()
	banner.theme_type_variation = &"HeaderLarge"
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.offset_top = 70
	banner.offset_bottom = 130
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_color_override("font_shadow_color", Color.BLACK)
	banner.add_theme_constant_override("shadow_outline_size", 4)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.text = ""
	$Environment/Screen.add_child(banner)

func _play(stream: AudioStream):
	# The server has no audio
	if multiplayer.is_server():
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

func _show_banner(text: String, color: Color, duration: float):
	if banner_tween:
		banner_tween.kill()
	banner.text = text
	banner.modulate = color
	banner.pivot_offset = banner.size / 2.0
	banner.scale = Vector2(1.5, 1.5)
	banner_tween = create_tween()
	banner_tween.tween_property(banner, "scale", Vector2.ONE, 0.2)
	banner_tween.tween_interval(duration)
	banner_tween.tween_callback(banner.set.bind("text", ""))

func precompute_ground_edges():
	var collision_shape = $ice/IcePlatform/StaticBody3D/CollisionShape3D
	var faces = collision_shape.shape.get_faces()
	var newtransform = collision_shape.global_transform
	var inward_edges = {}
	
	var i = 0
	while i < faces.size():
		# Skip triangles that are on the bottom or on the side
		# We only want to look at the top shape
		if faces[i].y < 2 or faces[i + 1].y < 2 or faces[i + 2].y < 2:
			i += 3
			continue
		var p1 = faces[i]
		for x in range(3):
			i += 1
			var p2
			
			# Triangles, e.g. 0 -> 1 -> 2 form a triangle
			# This method calculates the distance to the edges, therefore needed edges 0 -> 1, 1 -> 2, 2 -> 0
			if x == 2:
				p2 = faces[i - 3]
			else:
				p2 = faces[i]
			
			var edge = [newtransform * p1, newtransform * p2]
			var inv_edge = [newtransform * p2, newtransform * p1]
			# Idea: each face that is not an outer edge is present two times
			# Therefore to get the outer edges, we have to get all edges
			# that are present only once
			if not inward_edges.has(edge) and not inward_edges.has(inv_edge):
				if ground_edges.has(edge):
					inward_edges[edge] = true
					ground_edges.erase(edge)
				elif ground_edges.has(inv_edge):
					inward_edges[inv_edge] = true
					ground_edges.erase(inv_edge)
				else:
					ground_edges[edge] = true
			p1 = p2
# Uncomment to visualize the resulting edges
#	var geometry = ImmediateGeometry.new()
#	geometry.material_override = SpatialMaterial.new()
#	geometry.material_override.flags_unshaded = true
#	geometry.material_override.render_priority = 1
#	geometry.material_override.albedo_color = Color.red
#	add_child(geometry)
#	geometry.begin(Mesh.PRIMITIVE_LINES)
#	for edge in ground_edges:
#		geometry.add_vertex(edge[0])
#		geometry.add_vertex(edge[1])
#	geometry.end()

func win_condition(players):
	if lobby.minigame_state.minigame_type == Lobby.MINIGAME_TYPES.FREE_FOR_ALL:
		return players.size() <= 1
	else:
		var team
		for p in players:
			if team != null and p.team != team:
				return false
			team = p.team
		
		return true

func _server_process(delta):
	if human_players == 0 and len(players) > 0:
		players[0].max_speed = 5.0
	if not timer_end_start:
		elapsed += delta
		_server_ice_and_orbs(delta)
	for p in players:
		if p.position.y < -10:
			var pid: int = p.info.player_id
			lives[pid] = lives.get(pid, LIVES) - 1
			if lives[pid] > 0 and not timer_end_start:
				# back on the ice, somewhere near the middle
				var spot := Vector3(randf_range(-1.2, 1.2), 4.2, randf_range(-1.2, 1.2))
				lobby.broadcast(p.respawn.bind(spot, lives[pid]))
				p.respawn(spot, lives[pid])
				continue
			losses += 1
			placement[placement.size() - losses] = p.info.player_id # Assign placement before deleting player
			if losses == placement.size():
				winner_team = p.team
			if not p.info.is_ai():
				human_players -= 1
			players.erase(p)
			lobby.broadcast(player_out.bind(p.info.player_id))
			p.queue_free()
	
	if win_condition(players) and not timer_end_start:
		# If the last player has not died yet, put him as the winner
		if players.size() == 1:
			placement[0] = players[0].info.player_id
			players[0].winner = true
		
		if not players.is_empty():
			winner_team = players[0].team
		timer_end_start = true
		
		match lobby.minigame_state.minigame_type:
			Lobby.MINIGAME_TYPES.FREE_FOR_ALL, Lobby.MINIGAME_TYPES.DUEL:
				lobby.broadcast(win_player.bind(placement[0]))
			Lobby.MINIGAME_TYPES.TWO_VS_TWO:
				lobby.broadcast(win_team.bind(winner_team + 1))
	
	if timer_end_start:
		timer_end -= delta
		if timer_end <= 0:
			match lobby.minigame_state.minigame_type:
				Lobby.MINIGAME_TYPES.DUEL, Lobby.MINIGAME_TYPES.FREE_FOR_ALL:
					lobby.minigame_win_by_position(placement)
				Lobby.MINIGAME_TYPES.TWO_VS_TWO:
					lobby.minigame_team_win(winner_team)

@rpc func player_out(player_id: int):
	for player in players:
		if player.info.player_id == player_id:
			players.erase(player)
			player.hide()
			player.active = false
			break

@rpc func win_player(player_id: int):
	var player = lobby.get_player_by_id(player_id)
	$Environment/Screen/Message.text = tr("KNOCK_OFF_PLAYER_WINS_MSG").format({"player": player.name})
	$Environment/Screen/Message.show()
	players[0].winner = true

@rpc func win_team(team: int):
	$Environment/Screen/Message.text = tr("KNOCK_OFF_TEAM_WINS_MSG").format({"team": team})
	$Environment/Screen/Message.show()

# ----- Shrinking ice -----

func _server_ice_and_orbs(delta: float):
	if shrink_stage < SHRINK_TIMES.size():
		var at: float = SHRINK_TIMES[shrink_stage]
		if not shrink_warned and elapsed >= at - SHRINK_WARNING:
			shrink_warned = true
			lobby.broadcast(ice_warning)
		if elapsed >= at:
			var factor: float = SHRINK_FACTORS[shrink_stage]
			shrink_stage += 1
			shrink_warned = false
			lobby.broadcast(shrink_ice.bind(factor, SHRINK_DURATION))
			shrink_ice(factor, SHRINK_DURATION)
	elif not sudden_death and elapsed >= SUDDEN_DEATH_TIME:
		# Sudden death: the ice keeps melting until somebody falls off
		sudden_death = true
		lobby.broadcast(start_sudden_death)
		start_sudden_death()
	
	# Power-up orbs
	orb_timer -= delta
	if orb_timer <= 0.0:
		orb_timer = ORB_INTERVAL
		if orbs.size() < 2 and players.size() > 1:
			_spawn_orb_on_ice()
	for id in orbs.keys():
		var orb: Dictionary = orbs[id]
		orb.age += delta
		var taken := false
		for p in players:
			if not p.active:
				continue
			var d: Vector3 = p.position - orb.pos
			d.y = 0
			if d.length() < 1.2:
				taken = true
				_collect_orb(id, p, orb.type)
				break
		if taken or orb.age > ORB_LIFETIME or orb.pos.y < -5:
			if not taken:
				lobby.broadcast(remove_orb.bind(id, false))
				remove_orb(id, false)
			orbs.erase(id)

func _spawn_orb_on_ice():
	var space := get_world_3d().direct_space_state
	for i in 12:
		var angle := randf() * TAU
		var radius: float = randf_range(0.0, 2.2) * $ice.scale.x / ice_base_scale.x
		var pos := Vector3(cos(angle) * radius, 6.0, sin(angle) * radius)
		var query := PhysicsRayQueryParameters3D.create(pos, pos + Vector3(0, -8, 0))
		var hit := space.intersect_ray(query)
		if hit.is_empty() or hit.position.y < 2.0:
			continue
		var type := 1 + randi() % 2
		var orb_pos: Vector3 = hit.position + Vector3(0, 0.7, 0)
		var id := orb_counter
		orb_counter += 1
		orbs[id] = {"pos": orb_pos, "type": type, "age": 0.0}
		lobby.broadcast(spawn_orb.bind(id, orb_pos, type))
		spawn_orb(id, orb_pos, type)
		return

func _collect_orb(id: int, p: Node, type: int):
	lobby.broadcast(remove_orb.bind(id, true))
	remove_orb(id, true)
	lobby.broadcast(power_up.bind(p.info.player_id, type, POWER_DURATION))
	power_up(p.info.player_id, type, POWER_DURATION)

@rpc func spawn_orb(id: int, pos: Vector3, type: int):
	var orb := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.35
	mesh.height = 0.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ORB_COLORS[type]
	mat.emission_enabled = true
	mat.emission = ORB_COLORS[type]
	mat.emission_energy_multiplier = 1.5
	mesh.material = mat
	orb.mesh = mesh
	orb.position = pos
	add_child(orb)
	orb_nodes[id] = orb
	# Bobbing animation
	var tween := orb.create_tween().set_loops()
	tween.tween_property(orb, "position:y", pos.y + 0.25, 0.5).set_trans(Tween.TRANS_SINE)
	tween.tween_property(orb, "position:y", pos.y, 0.5).set_trans(Tween.TRANS_SINE)
	orb.scale = Vector3.ZERO
	orb.create_tween().tween_property(orb, "scale", Vector3.ONE, 0.25)

@rpc func remove_orb(id: int, taken: bool):
	if not orb_nodes.has(id):
		return
	var orb: Node3D = orb_nodes[id]
	orb_nodes.erase(id)
	if is_instance_valid(orb):
		var tween := orb.create_tween()
		tween.tween_property(orb, "scale", Vector3.ONE * (1.8 if taken else 0.01), 0.2)
		tween.tween_callback(orb.queue_free)
	if taken:
		_play(SND_ORB)

@rpc func power_up(player_id: int, type: int, duration: float):
	for player in players:
		if is_instance_valid(player) and player.info.player_id == player_id:
			player.apply_power(type, duration)
			break
	var name_key := "KNOCK_OFF_POWER_RUSH" if type == 1 else "KNOCK_OFF_POWER_HEAVY"
	var info := lobby.get_player_by_id(player_id)
	_show_banner(tr(name_key).format({"player": info.name}), ORB_COLORS[type], 1.5)

@rpc func ice_warning():
	_show_banner(tr("KNOCK_OFF_ICE_CRACKING"), Color(0.6, 0.85, 1.0), 1.8)
	_play(SND_CRACK)
	# Shake the ice a bit as a warning
	var tween := create_tween()
	var base: Vector3 = $ice.position
	for i in 8:
		tween.tween_property($ice, "position", base + Vector3(randf_range(-0.04, 0.04), 0, randf_range(-0.04, 0.04)), 0.1)
	tween.tween_property($ice, "position", base, 0.1)

@rpc func shrink_ice(factor: float, duration: float):
	_play(SND_CRACK)
	var target := Vector3(ice_base_scale.x * factor, ice_base_scale.y, ice_base_scale.z * factor)
	var tween := create_tween()
	tween.tween_property($ice, "scale", target, duration).set_trans(Tween.TRANS_SINE)
	tween.tween_callback(_on_ice_shrunk)

func _on_ice_shrunk():
	ground_edges.clear()
	precompute_ground_edges()

@rpc func start_sudden_death():
	_show_banner(tr("KNOCK_OFF_SUDDEN_DEATH"), Color(1, 0.3, 0.3), 3.0)
	_play(SND_CRACK)
	var target := Vector3(ice_base_scale.x * 0.3, ice_base_scale.y, ice_base_scale.z * 0.3)
	var tween := create_tween()
	tween.tween_property($ice, "scale", target, 25.0)
	# Keep the edge data for the bots up to date
	var refresh := create_tween().set_loops(8)
	refresh.tween_interval(3.0)
	refresh.tween_callback(_on_ice_shrunk)
