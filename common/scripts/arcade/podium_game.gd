class_name PodiumGame
extends ArcadeGame
## Base of the stationary party games (Pattern Pop, Quick Draw, Perfect Stop). The players stand on podiums in a row,
## facing the camera like on a game show stage, and play with their buttons only. This class builds the stage and
## gives the games a few helpers: points per player, popups, reactions and the input of the local players.
##
## Scores are kept by the server per player id; `add_points` also updates the score overlay on every peer.

const PODIUM_COLORS := [Color(0.93, 0.35, 0.33), Color(0.35, 0.55, 0.95), Color(0.40, 0.80, 0.42), Color(0.96, 0.78, 0.25)]
const PODIUM_SPACING := 3.1

var camera: Camera3D
var scores := {}              # player id -> points, kept by the server
var podium_x := {}            # player id -> x on the stage


## Colours of the stage floor and sky, a game can override this before build_world runs
func stage_colors() -> Array:
	return [Color(0.30, 0.18, 0.55), Color(0.95, 0.55, 0.75), Color(0.12, 0.07, 0.25)]


func build_world() -> void:
	var c := stage_colors()
	make_sky(c[0], c[1], c[2])
	camera = make_camera(Vector3(0, 5.2, 12.8), Vector3(0, 3.0, 0.0), 50.0)
	add_floor(11.0, 1, [Color(0.55, 0.30, 0.85), Color(0.98, 0.92, 0.80), Color(0.98, 0.92, 0.80), Color(1.0, 0.8, 0.2)], 18.0)
	# a stage backdrop: a curtain wall with lamps in front of it
	var wall := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(22, 9, 0.5)
	box.material = toon(Color(0.45, 0.16, 0.45))
	wall.mesh = box
	wall.position = Vector3(0, 4.3, -6.2)
	add_child(wall)
	for i in 7:
		var stripe := MeshInstance3D.new()
		var sbox := BoxMesh.new()
		sbox.size = Vector3(1.2, 9, 0.2)
		sbox.material = toon(Color(0.62, 0.2, 0.55) if i % 2 == 0 else Color(0.5, 0.15, 0.48))
		stripe.mesh = sbox
		stripe.position = Vector3(-9.0 + i * 3.0, 4.3, -5.9)
		add_child(stripe)
	pole_ring(10.0, 7, 3.4, Color(0.95, 0.95, 0.95), Color(1.0, 0.85, 0.3), Color(0.4, 0.8, 1.0), 200.0, 340.0)
	place_players()
	build_set()


## The scenery of the game itself (the screen, the lights ...), called after the players stand on their podiums.
func build_set() -> void:
	pass


func place_players() -> void:
	var count := players.size()
	for i in count:
		var p := players[i]
		var x := (i - (count - 1) * 0.5) * PODIUM_SPACING
		podium_x[p.info.player_id] = x
		scores[p.info.player_id] = 0
		var podium := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.15
		cyl.bottom_radius = 1.3
		cyl.height = 0.5
		cyl.material = toon(PODIUM_COLORS[i % 4])
		podium.mesh = cyl
		podium.position = Vector3(x, 0.25, 2.0)
		add_child(podium)
		# the local player is moved by physics (gravity), so the podium needs a solid top
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var cyl_shape := CylinderShape3D.new()
		cyl_shape.radius = 1.15
		cyl_shape.height = 0.5
		shape.shape = cyl_shape
		body.add_child(shape)
		body.position = Vector3(x, 0.25, 2.0)
		add_child(body)
		p.position = Vector3(x, 0.5, 2.0)
		p.rotation.y = 0.0
		p.can_move = false
		p.sync_position = false
		p.auto_animation = false
		p.ai_brain = Callable()
		var plate := Label3D.new()
		plate.text = p.info.name
		plate.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		plate.no_depth_test = true
		plate.pixel_size = 0.0052
		plate.font_size = 64
		plate.outline_size = 14
		plate.outline_modulate = Color(0.1, 0.05, 0.3)
		plate.position = Vector3(x, 0.55, 3.3)
		add_child(plate)


## True when this peer controls the player (a human on this machine)
func is_mine(p: ArcadePlayer) -> bool:
	return p.info.is_local() and not p.info.is_ai()


## The server checks that a message about player_id really comes from the machine of that player.
func sender_owns(player_id: int) -> bool:
	if player_id < 1 or player_id > lobby.player_info.size():
		return false
	var info := lobby.get_player_by_id(player_id)
	return info != null and not info.is_ai() and info.addr.peer_id == multiplayer.get_remote_sender_id()


## The four directions as action suffixes, in the order of the pads: up, left, down, right
const DIRECTIONS := ["up", "left", "down", "right"]


## The direction (0..3) a local player pressed this frame, or -1
func pressed_direction(p: ArcadePlayer) -> int:
	for d in 4:
		if Input.is_action_just_pressed("player%d_%s" % [p.info.player_id, DIRECTIONS[d]]):
			return d
	return -1


func add_points(player_id: int, amount: int) -> void:
	scores[player_id] = scores.get(player_id, 0) + amount
	if has_node("Screen/ScoreOverlay"):
		# in 1 vs 3 the solo player's points count three times (and the overlay adds up the team of three)
		var shown: int = scores[player_id] * (3 if _is_solo(player_id) else 1)
		$Screen/ScoreOverlay.set_score(player_id, shown)


func _is_solo(player_id: int) -> bool:
	var state := lobby.minigame_state
	return state.minigame_type == Lobby.MINIGAME_TYPES.ONE_VS_THREE and player_id in state.minigame_teams[1]


## Number of points as an array in the order of the player nodes, for finish_by_points
func score_list() -> Array:
	var list := []
	for p in players:
		list.append(scores.get(p.info.player_id, 0))
	return list


## A floating text over a player, on every peer (the server calls this)
func popup(player_id: int, text: String, color: Color, big := false) -> void:
	lobby.broadcast(_popup.bind(player_id, text, color, big))
	_popup(player_id, text, color, big)


@rpc func _popup(player_id: int, text: String, color: Color, big: bool) -> void:
	var p := player_by_id(player_id)
	if p == null:
		return
	var label := Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.0085 if big else 0.006
	label.font_size = 96
	label.outline_size = 24
	label.modulate = color
	label.outline_modulate = Color(0.1, 0.05, 0.3)
	label.position = p.position + Vector3(0, 2.5, 0.3)
	add_child(label)
	var tween := create_tween().set_parallel()
	tween.tween_property(label, "position:y", label.position.y + 1.0, 0.8)
	tween.tween_property(label, "modulate:a", 0.0, 0.3).set_delay(0.6)
	tween.chain().tween_callback(label.queue_free)


## Makes a player cheer or sulk, with a little hop, on every peer (the server calls this)
func react(player_id: int, good: bool) -> void:
	var p := player_by_id(player_id)
	if p == null:
		return
	p.show_animation("happy" if good else "sad")
	lobby.broadcast(_hop.bind(player_id, good))
	_hop(player_id, good)
	get_tree().create_timer(1.3).timeout.connect(func(): if is_instance_valid(p) and not finished: p.show_animation("idle"))


@rpc func _hop(player_id: int, good: bool) -> void:
	var p := player_by_id(player_id)
	if p == null or not good:
		return
	var base_y := p.position.y
	var tween := create_tween()
	tween.tween_property(p, "position:y", base_y + 0.7, 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tween.tween_property(p, "position:y", base_y, 0.18).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)


## A glowing, unshaded material
func glow(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## A big label in the 3D world, for the screens of the games
func world_label(text: String, pos: Vector3, size: float, color := Color.WHITE) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.pixel_size = size
	label.font_size = 96
	label.outline_size = 24
	label.modulate = color
	label.outline_modulate = Color(0.1, 0.05, 0.3)
	label.position = pos
	add_child(label)
	return label
