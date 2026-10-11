extends Node3D

const MAX_KNOCKOUT := 3
var knocked_out := 0

var lobby: Lobby

var box_counter := 0
const GAME_TIME := 40.0
const BARRAGE_TIME := 7.0
var minigame_time := GAME_TIME
var banner: Label
var banner_tween: Tween

const SND_HIT := preload("res://assets/sounds/arcade/boom.wav")
const SND_POWER := preload("res://assets/sounds/ui/turn_start.wav")
const SND_WIN := preload("res://assets/sounds/ui/round_win.wav")

var winner := -1

func _enter_tree() -> void:
	lobby = Lobby.get_lobby(self)

func _ready() -> void:
	banner = Label.new()
	banner.theme_type_variation = &"HeaderLarge"
	banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner.offset_top = 230
	banner.offset_bottom = 290
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.add_theme_constant_override("outline_size", 8)
	banner.add_theme_color_override("font_outline_color", Color.BLACK)
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.text = ""
	$Screen.add_child(banner)

func _play(stream: AudioStream):
	# The server has no audio
	if multiplayer.is_server():
		return
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	player.play()
	player.finished.connect(player.queue_free)

func show_banner(text: String, color: Color, duration: float = 1.2):
	banner.text = text
	banner.modulate = color
	banner.pivot_offset = banner.size / 2.0
	banner.scale = Vector2(1.7, 1.7)
	if banner_tween:
		banner_tween.kill()
	banner_tween = create_tween()
	banner_tween.tween_property(banner, "scale", Vector2.ONE, 0.2)
	banner_tween.tween_interval(duration)
	banner_tween.tween_callback(banner.set.bind("text", ""))

# Time passed in the match in the range 0..1
func progress() -> float:
	return clamp(1.0 - minigame_time / GAME_TIME, 0.0, 1.0)

# The cannon fires faster the longer the game lasts, with a final barrage
func fire_cooldown_time() -> float:
	if minigame_time < BARRAGE_TIME:
		return 0.45
	return lerpf(0.85, 0.6, progress())

@rpc func _client_win():
	$Screen/Time.hide()
	$Screen/Label.show()

func win(team: int):
	lobby.broadcast(_client_win)
	winner = team
	if multiplayer.is_server():
		$EndTimer.start()

func _process(delta: float):
	if winner != -1:
		return
	
	var before := minigame_time
	minigame_time -= delta
	if before >= BARRAGE_TIME and minigame_time < BARRAGE_TIME:
		show_banner(tr("BOWLING_BARRAGE"), Color(1, 0.4, 0.2), 1.5)
		_play(SND_POWER)
	if minigame_time <= 0:
		minigame_time = 0
		if multiplayer.is_server():
			win(0)
		
	$Screen/Time.text= str(snapped(minigame_time, 0.1))

func knockout():
	assert (multiplayer.is_server())
	if winner != -1:
		return
	
	knocked_out += 1
	lobby.broadcast(_client_hit.bind(knocked_out))
	_client_hit(knocked_out)
	if knocked_out == MAX_KNOCKOUT:
		win(1)

@rpc func _client_hit(count: int):
	var text := tr("BOWLING_STRIKE") if count == 1 else tr("BOWLING_KNOCKOUTS").format({"count": count, "max": MAX_KNOCKOUT})
	if count >= MAX_KNOCKOUT:
		text = tr("BOWLING_ALL_DOWN")
	show_banner(text, Color(1, 0.85, 0.2), 1.2)
	_play(SND_HIT)

func _on_EndTimer_timeout():
	lobby.minigame_team_win(winner)

func _on_Countdown_finish():
	$Screen/Time.show()

func _on_SpawnTimer_timeout():
	if winner != -1:
		return
	if not multiplayer.is_server():
		return
	
	# Boxes rain down more often towards the end
	$SpawnTimer.wait_time = lerpf(1.5, 1.0, progress())
	var pos := Vector3(randf_range(-2.5, 2.5), 5, randf_range(-2.5, -0.5))
	_spawn_box(pos)
	lobby.broadcast(_spawn_box.bind(pos))

@rpc func _spawn_box(pos: Vector3):
	var box = preload("res://plugins/minigames/bowling/box.tscn").instantiate()
	# Prevent desync issues
	# Generate a unique name, so that the names on the client and the server
	# will always match
	box.name = "Box" + str(box_counter)
	box.position = pos
	add_child(box)
	
	box_counter += 1

@rpc func die(player_id: int, movement: Vector3):
	for player in Utility.get_nodes_in_group(self, "players"):
		if player.info.player_id == player_id:
			player.state = player.STATE.DEAD
			player.movement = movement
