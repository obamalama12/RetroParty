# <img alt="Retro Party logo" src="assets/icons/icon-smallest.png" width="64" height="64" /> Retro Party

[![License](https://img.shields.io/badge/License-GPL%20v3.0-orange)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Godot Version](https://img.shields.io/badge/Godot-v4.7-%23478cbf)](https://godotengine.org/)

A [free/libre](https://www.gnu.org/philosophy/free-sw.html) and
[open-source](https://opensource.org/docs/osd/) party game that is meant to
replicate the feel of games such as Mario Party.

Retro Party is a fork of [Super Tux Party](https://gitlab.com/SuperTuxParty/SuperTuxParty)
(licensed under the GPL, see below) with its own characters and a new name. The mascot is Joy, a two-colour controller buddy.

![Mini-game Screenshot](screenshot.png)

## Running it

All assets are in the repository as normal files (no Git LFS), so a plain clone is enough.
You need [Godot 4.7](https://godotengine.org/) and Python 3:

```sh
git clone -b claude/optimistic-cori-yxc743 https://github.com/obamalama12/GMParty.git
cd GMParty
python tools/first_import.py "C:/path/to/Godot_v4.7-stable_win64.exe"
```

`first_import.py` imports every asset once (about 30 seconds). Then open the folder in Godot
and press F5. In the lobby pick the board "RetroValley".

## Engine

Retro Party is built with the [Godot Engine](https://godotengine.org/).
Currently, Godot Engine version 4.7 is used.

## Minigames

Besides the original ones there are five arcade minigames made for Retro Party: **Cookie Catch** (catch falling cookies and stars,
survive the cookie storm), **Hot Bomb** (pass the lit bomb on), **Jump Rope** (jump the sweeping rope), **Tug of War**
(mash the button, best of three) and **Color Clash** (run to the called colour before the other tiles drop). Their logic is in
`plugins/minigames/<name>/minigame.gd` on top of `common/scripts/arcade`; `tools/arcade_test` plays them to the end with bots.

## Minigame vote

At the end of each round the players vote between three minigames of the right type (two for 1v3, which only has two games). Left/right moves the
cursor, OK votes, bots vote on their own and anyone who does not vote within 15 s abstains. A tie is decided by a spinning highlight.
The logic is in `common/scenes/board_logic/controller/minigamevote.gd`, the options come from `server/minigame_queue.gd`;
`tools/board_check/vote_test` takes screenshots of it.

### Stationary party games

**Pattern Pop** (repeat the pattern of arrows), **Quick Draw** (press when the light turns green, not before) and **Perfect Stop**
(stop the marker in the green zone) are played on a stage where everybody stands on a podium and only uses their buttons, like many
Mario Party games. They share `common/scripts/arcade/podium_game.gd`; the scene, config and texts of a new one come from
`tools/arcade_builder/gen_minigames.py <name>`. Every minigame starts with a "How to play" card (the goal and everybody's buttons)
before the 3-2-1, and the game info screen before it has the full description. `UNTIL_END=1` of `tools/minigame_playthrough`
plays a game to its end and reports how long it took; `tools/minigame_playthrough/heats_test` plays a game with several heats for real.
A short game can list `"heats": 2` in its `minigame.json`: it is played twice in a row and the results are added up (`_combine_heats` in `server/lobby.gd`).

## Music

The board, the main menu and the arcade minigames have original chiptune tracks (pulse, triangle and noise channels) that
`tools/music_builder/make_music.py` synthesises into `assets/music/retro` (needs numpy and ffmpeg).
The minigame test room (main menu > Minigames) starts any minigame straight away.

## Board events

The pink "?" spaces of RetroValley trigger an event run by Mayor Pixel: Cookie Shower, Robin Hood, Surprise Gift, Turbo Dice,
Cookie Swap, Double or Nothing, Sweet Crumbs, Lucky Draw, Cookie Tax and Underdog Bonus (`common/scenes/board_logic/controller/board_events.gd`; add your own there).
`tools/board_check/event_test.gd` lands a bot on an event space for every event.

## Retro look

The 3D picture is drawn with a Nintendo 64 style post-processing shader (`common/retro/`): about 240 lines,
the console's three-point texture filter, 16 bit colour with dithering. The menus and text stay sharp.
The board has distance fog, an old-TV overlay (scanlines, dark corners) sits on top, and the sound is slightly
muffled like a 90s console. Switch the look off under Options > Visual (Retro look, Old TV scanlines).

## Look of the interface

Bright blue panels with a thick white border, chunky buttons that turn gold when selected, a pointing glove in the
main menu, one colour per player on the board (red, blue, green, yellow) and outlined bold text, in the spirit of
the 90s party games. The pictures are drawn by `tools/ui_builder/make_ui_art.py`.

## Tools

`tools/` has helpers for development:

- `tools/minigame_playthrough` plays every minigame once and takes screenshots.
- `tools/character_builder` builds the characters in Blender and renders previews.
- `tools/board_builder` generates the Retro Valley board, `tools/board_tour` takes screenshots of boards.
- `tools/first_import.py` imports the assets on a fresh clone (see above). `tools/get_assets.py` re-copies assets from an upstream checkout.

## Issues

If you have ideas for mini-games, design improvements or have found a bug then
please report that under Issues.

## License

All code is licensed under the [GNU GPL V3.0](https://www.gnu.org/licenses/gpl.html) or, at your option, any later version.
See the [**LICENSE**](licenses/LICENSE) file for more information.

All other data such as art, sound, music, and etc. is released under a bunch
of different licenses.
See the [**LICENSE-ART**](licenses/LICENSE-ART.md) file, the [**LICENSE-MUSIC**](licenses/LICENSE-MUSIC.md) file, the [**LICENSE-SHADER**](licenses/LICENSE-SHADER.md) file and the [**LICENSE-FONTS**](licenses/LICENSE-FONTS.md) file for more details.

## Credits

Based on [Super Tux Party](https://gitlab.com/SuperTuxParty/SuperTuxParty) by its contributors.
