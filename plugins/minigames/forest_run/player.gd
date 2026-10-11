extends CharacterBody3D

const SPEED = 4
const JUMP_POWER = 8
const GRAVITY = 18

enum State {
	IDLE,
	RUN,
	JUMP
}

var info: Lobby.PlayerInfo

var acceleration := Vector3(0, 0, 0)
var state = State.IDLE

var boost_time := 0.0

func apply_boost(duration: float):
	boost_time = duration

func show_popup(text: String, color: Color):
	var label := Label3D.new()
	label.text = text
	label.modulate = color
	label.outline_size = 12
	label.pixel_size = 0.008
	label.font_size = 64
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(label)
	label.position = Vector3(0, 2.2, 0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", 3.2, 0.9)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)

func blink(duration: float):
	var tween := create_tween().set_loops(int(duration / 0.2))
	tween.tween_callback($Model.hide)
	tween.tween_interval(0.1)
	tween.tween_callback($Model.show)
	tween.tween_interval(0.1)

# Called on every peer when the player falls into the void
@rpc("any_peer") func respawn(pos: Vector3):
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != 1:
		return
	position = pos
	acceleration = Vector3.ZERO
	velocity = Vector3.ZERO
	$CameraTracker.position.x = pos.x
	$CameraTracker.position.z = pos.z
	if info.is_ai():
		# Let the bot continue from the closest waypoint
		var best_dist := INF
		for waypoint in $"../Ground".get_children():
			if "nodes" in waypoint:
				var d: float = waypoint.global_position.distance_squared_to(pos)
				if d < best_dist:
					best_dist = d
					ai_current_waypoint = waypoint

var ai_current_waypoint: Node3D = null
var ai_rand_start: float

func _ready():
	set_multiplayer_authority(info.addr.peer_id)
	$CameraTracker.set_as_top_level(true)
	
	if info.is_ai():
		ai_current_waypoint = $"../Ground/Waypoint"
		ai_rand_start = randf()

@rpc func position_updated(trans: Vector3, rot: Vector3, new_state):
	self.position = trans
	self.rotation = rot
	$CameraTracker.position.x = self.position.x
	$CameraTracker.position.z = self.position.z
	if state != new_state:
		state = new_state
		match state:
			State.IDLE:
				$Model.play_animation("idle")
			State.RUN:
				$Model.play_animation("run")
			State.JUMP:
				$Model.play_animation("jump")

func calc_movement(previous: float, next: float) -> float:
	if is_on_floor():
		return next
	elif sign(previous) == sign(next):
		return clamp(next, min(previous, 0), max(previous, 0))
	else:
		return previous * 0.9

func _physics_process(delta):
	boost_time = maxf(0.0, boost_time - delta)
	if not info.is_local():
		return
	
	ai_rand_start -= delta
	if ai_rand_start > 0:
		return
	var jump = false
	var speed: float = SPEED * (1.4 if boost_time > 0 else 1.0)
	if not info.is_ai():
		acceleration.x = calc_movement(acceleration.x, (Input.get_action_strength("player%d_right" % info.player_id) - Input.get_action_strength("player%d_left" % info.player_id)) * speed)
		acceleration.z = calc_movement(acceleration.z, (Input.get_action_strength("player%d_down" % info.player_id) - Input.get_action_strength("player%d_up" % info.player_id)) * speed)
		jump = Input.is_action_pressed("player%d_action1" % info.player_id)
	else:
		var dir: Vector3 = ai_current_waypoint.global_transform.origin - position
		dir.y = 0
		
		if dir.length() < randf() * 0.5:
			jump = true
			if ai_current_waypoint.nodes.size() > 0:
				ai_current_waypoint = ai_current_waypoint.nodes[0]
		
		if abs(dir.x) < 0.05:
			dir.x = 0
		if abs(dir.z) < 0.05:
			dir.z = 0
		
		dir = dir.normalized()
		dir.x = dir.x * speed
		dir.z = dir.z * speed
		acceleration.x = dir.x
		acceleration.z = dir.z

	if acceleration.x or acceleration.z:
		if state == State.IDLE:
			$Model.play_animation("run")
			state = State.RUN
		$Model.rotation.y = atan2(acceleration.x, acceleration.z)
	elif state == State.RUN:
		$Model.play_animation("idle")
		state = State.IDLE
	
	if is_on_floor():
		if state == State.JUMP:
			if acceleration.x:
				$Model.play_animation("run")
				state = State.RUN
			else:
				$Model.play_animation("idle")
				state = State.IDLE
		else:
			acceleration.y = 0
			if jump:
				acceleration.y = JUMP_POWER
				$Model.play_animation("jump")
				state = State.JUMP
	acceleration.y -= GRAVITY * delta
	
	move_and_slide()
	set_velocity(acceleration + get_platform_velocity() * delta)
	get_parent().lobby.broadcast(position_updated.bind(self.position, self.rotation, self.state))
	
	$CameraTracker.position.x = self.position.x
	$CameraTracker.position.z = self.position.z
