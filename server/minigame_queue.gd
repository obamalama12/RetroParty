extends Resource

# all minigames in the current rotation that weren't played yet
var _minigames: Array[MinigameLoader.MinigameConfigFile] = []
# all minigames in the current rotation that were already played
var _played: Array[MinigameLoader.MinigameConfigFile] = []

func _init():
	_minigames = PluginSystem.minigame_loader.get_minigames()
	_minigames.shuffle()

# The game played last, so it never comes up twice in a row
var _last: MinigameLoader.MinigameConfigFile

# Utility function that should not be called use
# get_random_1v3/get_random_2v2/get_random_duel/get_random_ffa/get_random_nolok/get_random_gnu.
# Every minigame is played once before any of them is played again, in random order.
func _get_random_minigame(type: String) -> MinigameLoader.MinigameConfigFile:
	var candidates: Array[int] = []
	for i in range(len(_minigames)):
		if type in _minigames[i].type:
			candidates.append(i)
	if candidates.is_empty():
		# Everything of this type was played: start a new round with all of it shuffled
		assert(len(_played) > 0, "No minigame for type: " + type)
		_minigames += _played
		_played = []
		_minigames.shuffle()
		return _get_random_minigame_fresh(type)
	var pick: int = candidates[randi() % candidates.size()]
	return _take(pick)

# First pick after a new round: avoid the game that was just played, unless it is the only one
func _get_random_minigame_fresh(type: String) -> MinigameLoader.MinigameConfigFile:
	var candidates: Array[int] = []
	for i in range(len(_minigames)):
		if type in _minigames[i].type:
			candidates.append(i)
	var others: Array[int] = candidates.filter(func(i): return _minigames[i] != _last)
	var pool := others if not others.is_empty() else candidates
	return _take(pool[randi() % pool.size()])

func _take(index: int) -> MinigameLoader.MinigameConfigFile:
	var minigame := _minigames[index]
	_minigames.remove_at(index)
	_played.append(minigame)
	_last = minigame
	return minigame

## Returns up to [param count] different minigames of [param type] for the players to vote on.
## Games that were not played in this rotation come first and the game played last is left out,
## so the vote offers fresh choices. Fewer than [param count] are returned only if the type has fewer games.
## Call [method choose] with the winner afterwards.
func get_vote_options(type: String, count := 3) -> Array[MinigameLoader.MinigameConfigFile]:
	var options: Array[MinigameLoader.MinigameConfigFile] = []
	_collect_options(options, type, count)
	if options.size() < count:
		# Not enough unplayed games left: start a new rotation
		_minigames += _played
		_played = []
		_minigames.shuffle()
		_collect_options(options, type, count)
	if options.size() < count and _last != null and type in _last.type and not _last in options:
		options.append(_last)
	assert(options.size() > 0, "No minigame for type: " + type)
	return options

func _collect_options(options: Array[MinigameLoader.MinigameConfigFile], type: String, count: int) -> void:
	for minigame in _minigames:
		if options.size() >= count:
			return
		if type in minigame.type and minigame != _last and not minigame in options:
			options.append(minigame)

## Marks the winner of a vote as played. The other options stay in the rotation for a later round.
func choose(minigame: MinigameLoader.MinigameConfigFile) -> void:
	var index := _minigames.find(minigame)
	if index != -1:
		_minigames.remove_at(index)
		_played.append(minigame)
	_last = minigame

## Returns a random minigame that can be played in 1v3 mode
func get_random_1v3() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("1v3")

## Returns a random minigame that can be played in 2v2 mode
func get_random_2v2() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("2v2")

## Returns a random minigame that can be played in duel mode
func get_random_duel() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("Duel")

## Returns a random minigame that can be played in ffa mode
func get_random_ffa() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("FFA")

## Returns a random minigame that can be played in nolok solo mode
func get_random_nolok_solo() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("NolokSolo")

## Returns a random minigame that can be played in nolok coop mode
func get_random_nolok_coop() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("NolokCoop")

## Returns a random minigame that can be played in gnu solo mode
func get_random_gnu_solo() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("GnuSolo")

## Returns a random minigame that can be played in gnu coop mode
func get_random_gnu_coop() -> MinigameLoader.MinigameConfigFile:
	return _get_random_minigame("GnuCoop")
