extends CharacterBody3D

const SPEED = 2.8
const GRAVITY = 9.8
const GRAVITY_DIR = Vector3(0, -1, 0)

var info: Lobby.PlayerInfo

var movement = Vector3()
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
	label.position = Vector3(0, 2.0, 0)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", 3.0, 0.9)
	tween.tween_property(label, "modulate:a", 0.0, 0.7).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)

@onready var ai_waypoint = $"../Navigation/Waypoint"
@onready var lobby := Lobby.get_lobby(self)

enum STATE {
	IDLE,
	RUNNING,
	DEAD
}

var state := STATE.IDLE

func _ready():
	set_multiplayer_authority(info.addr.peer_id)

func _process(delta):
	boost_time = maxf(0.0, boost_time - delta)
	if not info.is_local() or state == STATE.DEAD:
		return
	var dir = Vector3()
	if not info.is_ai():
		dir.x = Input.get_action_strength("player%d_left" % info.player_id) - Input.get_action_strength("player%d_right" % info.player_id)
		dir.z = Input.get_action_strength("player%d_up" % info.player_id) - Input.get_action_strength("player%d_down" % info.player_id)
	else:
		dir = ai_waypoint.position - position
		dir = Vector3(dir.x, 0, dir.z)
		
		if dir.length_squared() < 0.1 and ai_waypoint.nodes and ai_waypoint.nodes.size() > 0:
			var index = randi() % ai_waypoint.nodes.size()
			ai_waypoint = ai_waypoint.nodes[index]
	
	if dir.length_squared() > 0:
		dir = dir.normalized()
		rotation.y = atan2(dir.x, dir.z)
		if state == STATE.IDLE:
			state = STATE.RUNNING
	elif dir.length_squared() == 0 and state == STATE.RUNNING:
		state = STATE.IDLE
	
	movement += GRAVITY_DIR * GRAVITY * delta
	if state != STATE.DEAD:
		set_velocity(movement + dir * SPEED * (1.6 if boost_time > 0 else 1.0))
		set_up_direction(Vector3(0, 1, 0))
		move_and_slide()
	
	if is_on_floor():
		movement = Vector3()
	
	lobby.broadcast(update_position.bind(position, rotation, state))
	# does animation
	update_position(position, rotation, state)

@rpc func update_position(pos: Vector3, rot: Vector3, nstate: STATE):
	if state == STATE.DEAD or nstate == STATE.DEAD:
		return
	
	state = nstate
	match state:
		STATE.RUNNING:
			$Model.play_animation("run")
		STATE.IDLE:
			$Model.play_animation("idle")
	
	position = pos
	rotation = rot

func die():
	state = STATE.DEAD
	$Model.play_animation("idle")
	lobby.broadcast(_client_die)

@rpc("any_peer") func _client_die():
	# Only the server is allowed to do this
	# But the network master is the controlling player
	# That's why we cannot use the puppet keyword
	if multiplayer.get_remote_sender_id() != 1:
		return
	state = STATE.DEAD
	$Model.play_animation("idle")

func is_dead():
	return state == STATE.DEAD
