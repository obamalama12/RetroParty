## Dev tool: draws minigames from the queue and reports back-to-back repeats.
extends Node

func _ready() -> void:
	var q = load("res://server/minigame_queue.gd").new()
	for kind in ["ffa", "1v3", "2v2", "duel"]:
		var seq := []
		for i in 40:
			seq.append(q.call("get_random_" + kind).scene_path.get_base_dir().get_file())
		var rep := 0
		for i in range(1, seq.size()):
			if seq[i] == seq[i - 1]:
				rep += 1
		print("QUEUE ", kind, " repeats ", rep, " ", seq.slice(0, 12))
	for kind in ["FFA", "1v3", "2v2"]:
		var shown := []
		for i in 30:
			var options = q.get_vote_options(kind)
			assert(options.size() == mini(3, options.size()) and options.size() > 0)
			shown.append(options.size())
			q.choose(options.pick_random())
		print("QUEUE vote ", kind, " option counts ", shown.slice(0, 8))
	get_tree().quit()
