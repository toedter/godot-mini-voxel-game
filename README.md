# Godot Mini Voxel Game

A small first-person exploration game built in [Godot 4.7](https://godotengine.org/): a single procedurally generated voxel island, wrapped around a hand-authored drowned ruin and the vault beneath it. Play with mouse and keyboard, or put on a headset — the game detects OpenXR at startup and swaps in a full VR rig automatically, no menu required.

## Screenshots

<!--
Add a few images here, e.g.:
![Grassland at sunrise](screenshots/01-island.png)
![The drowned ruin at low tide](screenshots/02-ruin.png)
![Inside the vault](screenshots/03-vault.png)
-->

## Features

- **One continuous island, generated from a seed.** A heightmap of 10 cm voxel columns rises out of the sea and blends between grassland, desert, beach and mountain biomes with no visible seams; the same terrain continues under the water as the sea bed.
- **Living surface detail.** Wind-wobbled grass, trees, glowing fantasy mushrooms that light their surroundings, mist that thickens with distance, and a day/night cycle with a moving sun and moon.
- **Tides as a game mechanic.** The sea rises and falls between authored notches — low, mean, and flood — reshaping which parts of the island are dry, and puzzles are built around what each tide level opens up or seals off.
- **A drowned ruin and the vault beneath it.** Explore an authored structure sitting in the tideline, then descend into a five-chamber vault behind a stone gate. Carry a burning torch — flickering light, drifting embers — to a pedestal to free a seized tide lock, and use it to light the braziers deeper in.
- **Carryables, pedestals and interiors.** Pick things up, set them down, and step through doorways into rooms that hang below the terrain independent of the outdoor world.
- **Save and load.** The island itself is never saved (it's a pure function of the seed) — only what changed: where you are, what the tide is doing, and what's sitting in which socket.
- **Seated VR support.** Built on the [Godot XR Development Kit](https://github.com/GodotVR/godot-xr-tools) with OpenXR. Smooth locomotion, snap turning, controller jump, and a debug teleport back to the ruins. Runs as an ordinary desktop game when no headset is present.

## Controls

### Desktop (mouse and keyboard)

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move |
| Mouse | Look around |
| `Shift` | Sprint |
| `Space` | Jump / swim up |
| `Ctrl` | Dive |
| `E` | Interact |
| `Esc` | Release the mouse cursor |
| `F5` / `F9` | Save / load |
| `M` | Toggle ambient music |
| `P` | Pause the day/night cycle |
| `T` | Jump to the ruins (debug) |
| `Page Up` / `Page Down` | Nudge the tide by a metre (debug) |
| `Home` | Reset the tide (debug) |

### VR (OpenXR headset)

| Input | Action |
| --- | --- |
| Thumbstick | Smooth move / snap turn |
| `A` (right controller) | Jump |
| `X` (left controller) | Jump to the ruins (debug) |
| Grip / trigger | Interact and carry |

## Running the project

1. Install [Godot 4.7](https://godotengine.org/download) or newer.
2. Open this folder as a project in Godot (or run `godot --path .` from the repository root).
3. Press **Play**. If an OpenXR headset is connected and its runtime is running, the game starts in VR; otherwise it starts as a normal desktop game.

## License

MIT — see [LICENSE](LICENSE).
