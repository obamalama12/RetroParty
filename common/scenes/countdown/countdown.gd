extends Control

@export var countdown_time: float = 3
@export var autostart: bool = true
## Show the "how to play" card (the goal and everybody's buttons) for a few seconds before the 3-2-1. It is skipped
## when the players are only trying the game out, because they have just read it.
@export var show_card: bool = true

const CARD_TIME := 4.0

signal finish

@onready var lobby := Lobby.get_lobby(self)
var time_left: float
var timer_finished: bool
var card: Control
var card_time := 0.0
var card_sound_played := false

func _force_animation_update(node):
	if node is AnimationPlayer and node.is_playing():
		node.seek(node.current_animation_position, true)
	if node is AnimationTree and node.active:
		node.advance(0)

	for child in node.get_children():
		_force_animation_update(child)

func _ready():
	if autostart:
		start()

func start():
	# Force update all animations or they won't be shown properly if they were just started
	_force_animation_update(lobby)

	timer_finished = false
	card_time = CARD_TIME if _wants_card() else 0.0
	time_left = countdown_time + card_time
	# the server only keeps the time, it has no screen
	if card_time > 0.0 and not multiplayer.is_server():
		_build_card()
	lobby.process_mode = PROCESS_MODE_DISABLED
	$Label.modulate = Color(1, 1, 1, 1)
	card_sound_played = card_time <= 0.0
	if card_time <= 0.0:
		$AudioStreamPlayer.play()

#func _is_paused():
	## Check if the pause menu is open
	#for node in Utility.get_nodes_in_group(lobby, "pausemenu"):
		#if node.paused:
			#return true
	#return false

func _process(delta):
	# Only let the timer run if the pause menu is not open
	if not timer_finished:# and not _is_paused():
		if card_time > 0.0 and time_left > countdown_time:
			$Label.text = ""
		else:
			if card:
				card.queue_free()
				card = null
			if not card_sound_played:
				card_sound_played = true
				var sound := get_node_or_null("AudioStreamPlayer") as AudioStreamPlayer
				if sound:
					sound.play()
			$Label.text = str(int(time_left) + 1)
			var state = lobby.minigame_state
			if state and state.minigame_config and state.minigame_config.heats > 1:
				$Label.text = tr("CONTEXT_HEAT").format({"heat": state.heat, "total": state.minigame_config.heats}) + "\n" + $Label.text

		time_left = max(time_left - delta, 0)
		if time_left == 0:
			_on_Timer_timeout()

func _on_Timer_timeout():
	timer_finished = true
	$Label.text = tr("CONTEXT_LABEL_GO")
	$AnimationPlayer.play("fadeout")
	lobby.process_mode = Node.PROCESS_MODE_INHERIT

	finish.emit()


func _wants_card() -> bool:
	if not show_card or lobby == null or lobby.minigame_state == null:
		return false
	return not lobby.minigame_state.is_try and lobby.minigame_state.minigame_config != null \
			and lobby.minigame_state.heat <= 1


## The card: the name and goal of the game and the buttons of every human player on this machine
func _build_card() -> void:
	var config: MinigameLoader.MinigameConfigFile = lobby.minigame_state.minigame_config
	card = PanelContainer.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.18, 0.55, 0.94)
	style.border_color = Color.WHITE
	style.set_border_width_all(5)
	style.set_corner_radius_all(20)
	style.set_content_margin_all(22)
	card.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	card.add_child(box)

	var title := Label.new()
	title.text = tr("CONTEXT_HOW_TO_PLAY")
	title.theme_type_variation = &"HeaderMedium"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(1.0, 0.9, 0.35))
	box.add_child(title)
	var name_label := Label.new()
	name_label.text = tr(config.name)
	name_label.theme_type_variation = &"HeaderLarge"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(name_label)

	# the first paragraph of the description is the goal
	var goal := Label.new()
	goal.text = tr(str(config.description)).split("\n")[0]
	goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	goal.custom_minimum_size = Vector2(760, 0)
	goal.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	goal.add_theme_font_size_override("font_size", 26)
	box.add_child(goal)

	for info in lobby.player_info:
		if not info.is_local() or info.is_ai():
			continue
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 14)
		var who := Label.new()
		who.text = info.name
		who.theme_type_variation = &"HeaderMedium"
		row.add_child(who)
		for entry in config.controls:
			if "team" in entry and not _in_team(info.player_id, entry.team):
				continue
			var label := Label.new()
			label.text = tr(entry.text) + ":"
			row.add_child(label)
			for action in entry.actions:
				if action == "spacer":
					continue
				var events := InputMap.action_get_events("player%d_%s" % [info.player_id, action])
				if events.is_empty():
					continue
				var icon := ControlHelper.ui_from_event(events[0])
				if icon:
					row.add_child(icon)
		box.add_child(row)
	add_child(card)


func _in_team(player_id: int, team: int) -> bool:
	var teams: Array = lobby.minigame_state.minigame_teams
	return team < teams.size() and player_id in teams[team]
