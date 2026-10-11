extends Control
## The vote at the end of every round: the players choose between up to three minigames.
## The most voted game is played. On a tie the highlight spins between the tied games and
## lands on a random one. The same script runs on the server (counts the votes) and on the clients (shows them).

## Seconds the players have to vote, bots vote right away
const VOTE_TIME := 15.0
## Seconds the result stays on screen (the server waits as long, the clients hide the vote at the same time)
const RESULT_TIME := 2.2
const TIE_RESULT_TIME := 5.6
const SPIN_STEPS := 18
## Chance that one of the offered games is a high stakes game
const STAKES_CHANCE := 0.6
const CARD_SIZE := Vector2(340, 330)
const ICON_SIZE := Vector2(44, 44)

const COLOR_IDLE := Color(1, 1, 1, 0.25)
const COLOR_CURSOR := Color(1, 1, 1, 0.9)
const COLOR_SPIN := Color(1, 0.85, 0.2, 1)

@onready var controller: Controller = get_parent().get_parent()

# ---- server ---- #

var _options: Array = []
var _votes := {}
var _open := false
## Set by [method run]: whether the winner was the high stakes game (double cookies)
var winner_has_stakes := false

# ---- client ---- #

var _cards: Array[PanelContainer] = []
var _icon_rows: Array[HBoxContainer] = []
var _count_labels: Array[Label] = []
var _title: Label
var _timer_label: Label
var _hint: Label
var _time_left := 0.0
var _active := false
var _local_players: Array[int] = []
var _cursor := {}
var _client_votes := {}


func _ready() -> void:
	hide()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ----------------------------------------------------------------------------------------------- #
# Server
# ----------------------------------------------------------------------------------------------- #

## Lets the players vote between [param options] ([MinigameLoader.MinigameConfigFile]) and returns the winner.
func run(options: Array) -> MinigameLoader.MinigameConfigFile:
	_options = options
	_votes = {}
	_open = true
	var filenames := []
	for option in options:
		filenames.append(option.filename)
	# Often one of the games is offered with double cookies
	var stakes_idx := randi() % options.size() if randf() < STAKES_CHANCE else -1
	controller.lobby.broadcast(_client_open.bind(filenames, VOTE_TIME, stakes_idx))

	for player in controller.players:
		if player.info.is_ai():
			_ai_vote(player.info.player_id, randf_range(0.8, 3.0))

	var waited := 0.0
	while waited < VOTE_TIME and not _pending_humans().is_empty():
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	_open = false

	var counts := []
	counts.resize(options.size())
	counts.fill(0)
	for player_id in _votes:
		counts[_votes[player_id]] += 1
	var best: int = counts.max()
	var tied := []
	for i in options.size():
		if counts[i] == best:
			tied.append(i)
	var winner: int = tied.pick_random()
	winner_has_stakes = winner == stakes_idx

	controller.lobby.broadcast(_client_reveal.bind(counts, tied, winner))
	await get_tree().create_timer(TIE_RESULT_TIME if tied.size() > 1 else RESULT_TIME).timeout
	return options[winner]


func _pending_humans() -> Array:
	var pending := []
	for player in controller.players:
		if not player.info.is_ai() and not _votes.has(player.info.player_id):
			pending.append(player.info.player_id)
	return pending


func _ai_vote(player_id: int, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	if _open and not _votes.has(player_id):
		_cast(player_id, randi() % _options.size())


func _cast(player_id: int, idx: int) -> void:
	_votes[player_id] = idx
	controller.lobby.broadcast(_client_votes_changed.bind(_votes))


@rpc("any_peer") func _server_vote(player_id: int, idx: int) -> void:
	if not _open or idx < 0 or idx >= _options.size():
		return
	if player_id < 1 or player_id > controller.players.size():
		return
	var info := controller.lobby.get_player_by_id(player_id)
	if info.is_ai() or info.addr.peer_id != multiplayer.get_remote_sender_id():
		return
	if _votes.has(player_id):
		return
	_cast(player_id, idx)


# ----------------------------------------------------------------------------------------------- #
# Client
# ----------------------------------------------------------------------------------------------- #

@rpc func _client_open(filenames: Array, time: float, stakes_idx: int) -> void:
	var configs := []
	for filename in filenames:
		var config := PluginSystem.minigame_loader.get_config_by_path(filename)
		if config:
			configs.append(config)
	if configs.is_empty():
		return

	_client_votes = {}
	_cursor = {}
	_local_players = []
	for player in controller.players:
		if player.info.is_local() and not player.info.is_ai():
			_local_players.append(player.info.player_id)
			_cursor[player.info.player_id] = 0
	_time_left = time
	_build(configs, stakes_idx)
	_active = true
	_refresh()
	show()
	_hint.text = tr("CONTEXT_VOTE_HINT") if not _local_players.is_empty() else tr("CONTEXT_VOTE_WAIT")


@rpc func _client_votes_changed(votes: Dictionary) -> void:
	_client_votes = votes
	_refresh()


@rpc func _client_reveal(counts: Array, tied: Array, winner: int) -> void:
	if _cards.is_empty():
		return
	_active = false
	_client_votes_to_counts(counts)
	_timer_label.text = ""
	var started := Time.get_ticks_msec()
	var total := TIE_RESULT_TIME if tied.size() > 1 else RESULT_TIME

	if tied.size() > 1:
		_hint.text = ""
		_title.text = tr("CONTEXT_VOTE_TIE")
		_highlight(-1, COLOR_IDLE)
		await get_tree().create_timer(0.9).timeout
		# Walk through the tied games, slowing down, so that the last step is the winner
		var start: int = posmod(tied.find(winner) - SPIN_STEPS, tied.size())
		for step in range(1, SPIN_STEPS + 1):
			var pick: int = tied[(start + step) % tied.size()]
			_highlight(pick, COLOR_SPIN)
			_pop(pick)
			var progress := float(step) / SPIN_STEPS
			await get_tree().create_timer(lerpf(0.06, 0.42, progress * progress)).timeout

	_title.text = tr("CONTEXT_VOTE_WINNER")
	_highlight(winner, COLOR_SPIN)
	for i in _cards.size():
		if i != winner:
			_cards[i].modulate = Color(1, 1, 1, 0.4)
	_pop(winner)

	var remaining := total - (Time.get_ticks_msec() - started) / 1000.0
	if remaining > 0:
		await get_tree().create_timer(remaining).timeout
	hide()
	_cards.clear()


func _process(delta: float) -> void:
	if _active:
		_time_left = maxf(_time_left - delta, 0.0)
		_timer_label.text = str(ceili(_time_left))


func _input(event: InputEvent) -> void:
	if not _active:
		return
	for player_id in _local_players:
		if _client_votes.has(player_id):
			continue
		if event.is_action_pressed("player%d_left" % player_id):
			_move_cursor(player_id, -1)
		elif event.is_action_pressed("player%d_right" % player_id):
			_move_cursor(player_id, 1)
		elif event.is_action_pressed("player%d_ok" % player_id) \
				or event.is_action_pressed("player%d_action1" % player_id):
			_vote(player_id, _cursor[player_id])
		else:
			continue
		get_viewport().set_input_as_handled()
		return


func _move_cursor(player_id: int, direction: int) -> void:
	_cursor[player_id] = posmod(_cursor[player_id] + direction, _cards.size())
	_refresh()


func _vote(player_id: int, idx: int) -> void:
	# Show the vote right away, the server confirms it
	_client_votes[player_id] = idx
	_refresh()
	_server_vote.rpc_id(1, player_id, idx)


func _on_card_input(event: InputEvent, idx: int) -> void:
	if not _active or not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	# The mouse votes for the first local player who has not voted yet
	for player_id in _local_players:
		if not _client_votes.has(player_id):
			_vote(player_id, idx)
			return


# ---- drawing ---- #

func _build(configs: Array, stakes_idx: int) -> void:
	for child in get_children():
		child.queue_free()
	_cards.clear()
	_icon_rows.clear()
	_count_labels.clear()

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.9)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)

	_title = Label.new()
	_title.theme_type_variation = &"HeaderLarge"
	_title.text = tr("CONTEXT_VOTE_TITLE")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)

	for i in configs.size():
		row.add_child(_build_card(configs[i], i, i == stakes_idx))

	_hint = Label.new()
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_hint)

	_timer_label = Label.new()
	_timer_label.theme_type_variation = &"HeaderMedium"
	_timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_timer_label)


func _build_card(config: MinigameLoader.MinigameConfigFile, idx: int, stakes: bool) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	card.pivot_offset = CARD_SIZE / 2.0
	card.gui_input.connect(_on_card_input.bind(idx))
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	_cards.append(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(box)

	var picture := TextureRect.new()
	picture.custom_minimum_size = Vector2(CARD_SIZE.x - 24, 150)
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if config.image_path != null and ResourceLoader.exists(config.image_path):
		picture.texture = load(config.image_path)
	box.add_child(picture)

	if stakes:
		var badge := Label.new()
		badge.text = tr("CONTEXT_VOTE_STAKES")
		badge.theme_type_variation = &"HeaderMedium"
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.add_theme_color_override("font_color", COLOR_SPIN)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(badge)

	var name_label := Label.new()
	name_label.theme_type_variation = &"HeaderMedium"
	name_label.text = _text(config, config.name)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(name_label)

	var description := Label.new()
	description.text = _short(_text(config, str(config.description)))
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	description.custom_minimum_size = Vector2(CARD_SIZE.x - 24, 60)
	description.size_flags_vertical = Control.SIZE_EXPAND_FILL
	description.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(description)

	var icons := HBoxContainer.new()
	icons.alignment = BoxContainer.ALIGNMENT_CENTER
	icons.custom_minimum_size = Vector2(0, ICON_SIZE.y)
	icons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(icons)
	_icon_rows.append(icons)

	var count := Label.new()
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(count)
	_count_labels.append(count)
	return card


## Shows the vote icons (solid) and the cursors of the local players (faded) on the cards
func _refresh() -> void:
	if _cards.is_empty() or not _active:
		return
	var cursor_cards := []
	for i in _cards.size():
		for child in _icon_rows[i].get_children():
			child.queue_free()
		_count_labels[i].text = ""
	for player in controller.players:
		var player_id: int = player.info.player_id
		var idx := -1
		var voted := _client_votes.has(player_id)
		if voted:
			idx = _client_votes[player_id]
		elif _cursor.has(player_id):
			idx = _cursor[player_id]
			cursor_cards.append(idx)
		if idx < 0 or idx >= _cards.size():
			continue
		var icon := TextureRect.new()
		icon.texture = PluginSystem.character_loader.load_character_icon(player.info.character)
		icon.custom_minimum_size = ICON_SIZE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.modulate = Color.WHITE if voted else Color(1, 1, 1, 0.4)
		_icon_rows[idx].add_child(icon)
	for i in _cards.size():
		_set_border(_cards[i], COLOR_CURSOR if i in cursor_cards else COLOR_IDLE)


func _client_votes_to_counts(counts: Array) -> void:
	for i in _cards.size():
		_count_labels[i].text = tr("CONTEXT_VOTE_COUNT").format({"count": counts[i]})


func _highlight(idx: int, color: Color) -> void:
	for i in _cards.size():
		_set_border(_cards[i], color if i == idx else COLOR_IDLE)
		_cards[i].modulate = Color.WHITE if i == idx or idx < 0 else Color(1, 1, 1, 0.55)


func _pop(idx: int) -> void:
	var card := _cards[idx]
	card.scale = Vector2(1.08, 1.08)
	create_tween().tween_property(card, "scale", Vector2.ONE, 0.18)


func _set_border(card: PanelContainer, color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.16, 0.95)
	style.border_color = color
	style.set_border_width_all(5)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(12)
	card.add_theme_stylebox_override("panel", style)


## Looks a text up in the translation files of the minigame. Every minigame uses the same keys,
## so the texts of the three candidates cannot be installed in the TranslationServer at the same time.
func _text(config: MinigameLoader.MinigameConfigFile, key: String) -> String:
	var locale := TranslationServer.get_locale()
	for code in [locale, locale.split("_")[0], "en"]:
		var path := config.translation_directory.path_join(code + ".po")
		if not ResourceLoader.exists(path):
			continue
		var translation := load(path) as Translation
		if translation:
			var message := str(translation.get_message(key))
			if not message.is_empty():
				return message
	return key


## First paragraph without BBCode, cut to a length that fits on a card
func _short(text: String) -> String:
	var regex := RegEx.new()
	regex.compile("\\[[^\\]]*\\]")
	text = regex.sub(text, "", true).split("\n")[0].strip_edges()
	if text.length() > 120:
		text = text.substr(0, 117).strip_edges() + "..."
	return text
