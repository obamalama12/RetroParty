extends RigidBody3D

var max_speed = 2
var accel = 10

var team
var info: Lobby.PlayerInfo
var ai_difficulty: int

var active := true

var winner = false: set = set_winner
var minigame_mode: int

var is_walking = false

# Temporary power-up state (see knock_off.gd)
enum Power { NONE, RUSH, HEAVY }
var power: int = Power.NONE
var power_left := 0.0
var speed_mult := 1.0
var base_mass := 0.1

func apply_power(type: int, duration: float):
	clear_power()
	power = type
	power_left = duration
	match type:
		Power.RUSH:
			speed_mult = 1.6
		Power.HEAVY:
			mass = base_mass * 4.0
			$Ball.scale = Vector3.ONE * 1.25

func clear_power():
	power = Power.NONE
	power_left = 0.0
	speed_mult = 1.0
	mass = base_mass
	$Ball.scale = Vector3.ONE

func set_winner(win):
	winner = win
	
	if not is_walking and win:
		$Model.play_animation("happy")

func _ready():
	$Model.set_as_top_level(true)
	set_multiplayer_authority(info.addr.peer_id)
	_show_lives(2)
	minigame_mode = info.lobby.minigame_state.minigame_type
	
	if info.is_ai():
		match ai_difficulty:
			Lobby.Difficulty.EASY:
				accel = 7
				max_speed *= 0.8
			Lobby.Difficulty.NORMAL:
				accel = 10
				max_speed *= 0.9
			Lobby.Difficulty.HARD:
				accel = 11

var lives_label: Label3D

## The server puts a player that fell off back on the ice. Players are moved by the machine of their owner, so the
## server tells that machine (and everybody else) where to put the ball.
@rpc("any_peer") func respawn(spot: Vector3, lives_left: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	var xform := Transform3D(Basis(), spot)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	position = spot
	_show_lives(lives_left)
	if has_node("Model"):
		$Model.play_animation("jump")

func _show_lives(count: int) -> void:
	if lives_label == null:
		lives_label = Label3D.new()
		lives_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lives_label.no_depth_test = true
		lives_label.pixel_size = 0.006
		lives_label.font_size = 64
		lives_label.outline_size = 14
		lives_label.outline_modulate = Color(0.1, 0.05, 0.3)
		lives_label.position = Vector3(0, 1.7, 0)
		$Model.add_child(lives_label)
	lives_label.text = "%d" % count if count > 1 else "LAST LIFE"
	lives_label.modulate = Color(0.6, 1.0, 0.6) if count > 1 else Color(1.0, 0.45, 0.4)

@rpc("unreliable") func position_update(x: Vector3, v: Vector3, rot: float):
	self.position = x
	self.angular_velocity = v
	$Model.rotation.y = rot

func get_distance_to_shape(point):
	var edges = get_parent().ground_edges
	var distance = INF
	
	for e in edges:
		var p1 = e[0]
		var p2 = e[1]
		
		var dir = (p2 - p1).normalized()
		var r = dir.dot(point - p1)
		
		r = clamp(r, 0, 1)
		
		var dist = sqrt(pow((point - p1).length(), 2) - r * pow((p2-p1).length(), 2))
		if dist < distance:
			distance = dist
	
	return distance

func is_on_floor():
	return position.y > 2.4

func _process(delta):
	$Model.position = self.position + Vector3(0, 0.5, 0)
	if power != Power.NONE:
		power_left -= delta
		# Pulse while a power-up is active, faster when about to run out
		var pulse := 1.0 + 0.06 * sin(Time.get_ticks_msec() * (0.03 if power_left < 1.5 else 0.01))
		$Ball.scale = Vector3.ONE * (1.25 if power == Power.HEAVY else 1.0) * pulse
		if power_left <= 0.0:
			clear_power()
	if not is_multiplayer_authority() or not active:
		return
	var dir = Vector3()
	
	if not info.is_ai() and is_on_floor():
		dir.x = Input.get_action_strength("player%d_down" % info.player_id) - Input.get_action_strength("player%d_up" % info.player_id)
		dir.z = Input.get_action_strength("player%d_left" % info.player_id) - Input.get_action_strength("player%d_right" % info.player_id)
	elif is_on_floor():
		# Try to knock off the player, that is the farthest away from the center, yet still on the ice
		var farthest_player = null
		var farthest_distance = INF
		for p in get_parent().players:
			if p != self and (p.team != self.team or minigame_mode == Lobby.MINIGAME_TYPES.FREE_FOR_ALL):
				var distance = get_distance_to_shape(p.position)
				if p.is_on_floor() and (farthest_player == null or farthest_distance > distance):
					farthest_player = p
					farthest_distance = distance
		
		if farthest_player != null:
			dir = (farthest_player.position - position).rotated(Vector3(0, 1, 0), PI/2)
		else:
			
			# Everybody knocked off the board?
			# Move towards the center
			dir = self.position.rotated(Vector3(0, 1, 0), -PI/2)
			
			if dir.length_squared() < 0.1:
				dir = Vector3()
	
	dir = dir.normalized()
	
	if dir.length_squared() > 0:
		apply_torque(dir * accel * speed_mult * (mass / base_mass))
		var target_rotation = atan2(-dir.z, dir.x)
		
		var diff1 = (target_rotation - $Model.rotation.y)
		var diff2 = (target_rotation + sign($Model.rotation.y) * TAU - $Model.rotation.y)
		
		if abs(diff1) < abs(diff2):
			$Model.rotation.y += diff1 * delta * 3
		else:
			$Model.rotation.y += diff2 * delta * 3
		
		if not is_walking:
			$Model.play_animation("walk")
			is_walking = true
	else:
		if is_walking:
			if winner:
				$Model.play_animation("happy")
			else:
				$Model.play_animation("idle")
			is_walking = false
	
	if angular_velocity.length() > max_speed * speed_mult:
		angular_velocity = max_speed * speed_mult * angular_velocity.normalized()
	
	info.lobby.broadcast(position_update.bind(position, angular_velocity, $Model.rotation.y))
