# Minigame playthrough

Starts a local game, then launches every minigame in "Try" mode through the
normal info screen, feeds random input to all four players, saves screenshots
and returns to the board. Script errors show up in the console output.

```sh
godot --path . res://tools/minigame_playthrough/playthrough.tscn
```

- `ONLY=hurdle,bowling` limits the run to those minigame folders.
- `CHARACTER=Kit` picks the character the human player uses (default `Businessman`).
- `SHOTS_DIR=/some/dir` sets where screenshots go (default `user://playthrough_shots`).
- Lines starting with `DRV` are progress; `DRV ALL DONE` marks the end.

Without a GPU: `xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --audio-driver Dummy --path . res://tools/minigame_playthrough/playthrough.tscn`.
Expect a "Dual paraboloid shadow" error from Kernel Compiling on the
Compatibility renderer, and about 10 minutes for a full run.

`UNTIL_END=1` plays each game until it ends by itself (the bots play, player 1 presses random buttons) and logs
`DRV DURATION <game> <seconds>`; `CAP=150` limits the time. Screenshots every 8 seconds. `ONLY=pattern_pop` picks games.
`TYPE=1v3` runs only the games in that mode (FFA, Duel, 2v2, 1v3, ...).
