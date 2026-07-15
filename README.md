


# Race Game Tool

A Flutter desktop (macOS / Windows) authoring tool for a 2D top-down racing
game. It turns hand-drawn art into a packed, game-ready asset set and lets you
lay out complete levels on a grid, then exports both as plain files a game
engine (e.g. a Flame project) can load directly.

The whole pipeline is **grid-based: 1 cell = 16 x 16 px**. A standard road is
5 cells wide (80 px).

---

## The two phases

The app is a browser-style tabbed workspace. The first tab is always **Phase 1
(Asset Definer)** and is pinned. From it you open any number of **Phase 2
(Level Editor)** tabs, each an independent level that shares the same asset set.

### Phase 1 - Asset Definer

Author reusable **blocks** from draft images:

1. Load a draft image per category (Track, Island, Decoration). Decoration may
   use **several images**, each kept separate here but merged on export.
2. Mask each block (solid rectangle or freeform painted shape).
3. Define **ports** on block edges (the connection interfaces used for
   snapping in Phase 2).
4. Save a single **`.rgpack`** bundle - the single source of truth. Everything
   the game needs is derived from this file; there is no second export path
   that could drift from it.

### Phase 2 - Level Editor

Import a `.rgpack`, then build a level across independent **layers**
(Track, Island, Decoration, Function). Stamp blocks on the grid, connect them
port-to-port, auto-generate the island terrain, place the spawn point, and
export a **`map_NN.json`** scene.

Layers are independent planes: a track piece and an island tile may occupy the
same grid cell because the island sits "under" the track.

---

## Concepts

- **Grid cell** - 16 x 16 px. All editor positions are in whole cells; convert
  to pixels by multiplying by 16.
- **Category** (`BlockCategory`) - what kind of asset a block is: `TRACK`,
  `ISLAND_TILE`, `DECORATION`, `WALL`, `CHECK_LINE`.
- **Layer** (`MapLayer`) - the plane a category is edited/placed on
  (Track, Island, Decoration, Function). Each category maps to one layer.
- **Port** - a connection strip on a block edge, `span` cells long,
  perpendicular to its travel `direction`. A block that is one cell thick along
  the travel axis has a **pass-through** (`bidirectional`) port.
- **Block** (`BlockDef`) - the prefab definition: bounding box + sprite rect +
  ports + (reserved) physics. The single source of truth for what a block *is*.
- **Placement** (`BlockPlacement`) - one block stamped on the map: just a
  `blockId` and a grid position. All visuals/physics come from the `BlockDef`.

### Coordinate conventions

- **Origin** is the top-left; **y points down** (screen coordinates).
- **Angles** are in radians: `0` points right (+x), positive rotates clockwise.
- A block placed at grid `(gridX, gridY)` has its top-left pixel origin at
  `(gridX * 16, gridY * 16)`. Its footprint is
  `boundingBox.width * 16` by `boundingBox.height * 16` px.
- Port and physics coordinates are **local** to the owning block's origin.

---

## Data formats (game integration)

A game consumes exactly two derived artifacts: **`SpriteSheet.png`** and
**`sprite_dict.json`** (the asset set), plus one **`map_NN.json`** per level.
The `.rgpack` bundle is the editor's own project file; a game normally never
reads it directly - it reads the extracted pair (see the CLI below).

### `.rgpack` bundle (editor project file)

A ZIP archive. Current format is **version 3**. Entries:

| Entry                             | Purpose                                                                                                  |
| --------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `manifest.json`                 | Format id, version, cell size, block count.                                                              |
| `editor.json`                   | Editor state for re-editing:`masks[]` and `sources[]`.                                               |
| `SpriteSheet.png`               | The packed sprite sheet (derived).                                                                       |
| `sprite_dict.json`              | The block dictionary (derived).                                                                          |
| `raw_source.png`                | The first source image (legacy back-compat copy).                                                        |
| `raw_source_<category>.png`     | Raw draft image per single-image category, e.g.`raw_source_track.png`, `raw_source_island_tile.png`. |
| `raw_source_decoration_<i>.png` | One raw image per decoration source (`_0`, `_1`, ...).                                               |

`editor.json` (v3) records each draft image as a source and, for decoration,
which image each mask came from (`decorationSourceIndex`), so the multi-image
grouping round-trips. v1/v2 bundles still open (their decoration masks collapse
onto a single image). Games can ignore all of this.

### `SpriteSheet.png`

A single transparent PNG containing every block's art, bin-packed. Blocks
reference sub-rectangles of it by pixel via `spriteSheetRect`.

### `sprite_dict.json`

```json
{
  "version": 1,
  "cellSize": 16,
  "spriteSheet": "SpriteSheet.png",
  "blocks": [
    {
      "id": "block_1",
      "boundingBox": { "width": 5, "height": 2 },
      "spriteSheetRect": { "x": 0, "y": 0, "w": 80, "h": 32 },
      "category": "TRACK",
      "cornerType": "NONE",
      "ports": [
        {
          "localGridX": 0,
          "localGridY": 0,
          "direction": "UP",
          "span": 5,
          "bidirectional": true
        }
      ],
      "autoDecals": [],
      "physicsTrackArea": [],
      "physicsHardWalls": [],
      "checkLines": []
    }
  ]
}
```

Field reference (`BlockDef`):

- `id` - unique key, referenced by map placements.
- `boundingBox` `{width, height}` - size in **grid cells**.
- `spriteSheetRect` `{x, y, w, h}` - source rectangle in **pixels** inside
  `SpriteSheet.png`. `w`/`h` equal `boundingBox * 16`.
- `category` - `TRACK` | `ISLAND_TILE` | `DECORATION` | `WALL` | `CHECK_LINE`.
- `cornerType` - `NONE` | `CONVEX` | `CONCAVE` (island corner tiles only).
- `ports[]` - connection strips, local grid cells:
  - `localGridX`, `localGridY` - strip top-left cell, relative to block origin.
  - `direction` - `UP` | `DOWN` | `LEFT` | `RIGHT` | `DIAG_UR` | `DIAG_UL` |
    `DIAG_DR` | `DIAG_DL`.
  - `span` - strip length in cells (perpendicular to travel; diagonals are 1).
  - `bidirectional` - true = pass-through (connects both ways along the axis).
- `autoDecals[]` - optional auto-placed decals `{localGridX, localGridY, type}`
  with `type` `KERB_GRADIENT` | `KERB_SOLID`.
- **Physics fields** (`physicsTrackArea`, `physicsHardWalls`, `checkLines`) -
  reserved for a later authoring step and **currently emitted empty**. Schema
  when populated:
  - `physicsTrackArea` - `[[x,y], ...]` local polygon of the drivable asphalt
    (inside = road friction, outside = grass/sand).
  - `physicsHardWalls` - `[[[x,y], ...], ...]` polylines for solid collision
    barriers.
  - `checkLines` - `[{ "p1": [x,y], "p2": [x,y] }, ...]` lap/anti-cheat gates.
  - `[x, y]` points are local to the block origin.

### `map_NN.json` (level scene)

```json
{
  "mapName": "map_01",
  "spawnPoint": { "gridX": 40, "gridY": 30, "facingAngle": 0.0 },
  "placements": [
    { "blockId": "block_1", "gridX": 38, "gridY": 30 },
    { "blockId": "block_7", "gridX": 43, "gridY": 30 }
  ],
  "islandTerrain": []
}
```

- `mapName` - level id.
- `spawnPoint` - `{gridX, gridY}` in cells and `facingAngle` in radians
  (0 = right, clockwise positive).
- `placements[]` - `{blockId, gridX, gridY}`. Look `blockId` up in
  `sprite_dict.json`; draw its `spriteSheetRect` at world pixel
  `(gridX * 16, gridY * 16)`; apply its (local) ports/physics offset by the
  same origin.
- `islandTerrain` - row-major `int` grid (`0` = water, `1` = grass), reserved.
  It is **currently emitted empty**: the island is expressed as normal
  `ISLAND_TILE` placements, so the game rebuilds the island from those blocks
  like any other layer.

### Loading a level in a game (summary)

1. Extract `SpriteSheet.png` + `sprite_dict.json` from the `.rgpack` (CLI below)
   and parse the dict into a `Map<id, BlockDef>`.
2. Load `map_NN.json`. For each placement, fetch its `BlockDef`, blit
   `spriteSheetRect` at `(gridX*16, gridY*16)`.
3. Build collision/physics from each block's local `physicsTrackArea` /
   `physicsHardWalls`, translated by the placement origin (once authored).
4. Place the car at `spawnPoint` (`gridX*16, gridY*16`, `facingAngle`).
5. Use `checkLines` (in order) for lap counting once authored.

---

## CLI: extracting game assets

The game build derives its assets from a bundle instead of the editor ever
saving a separate export:

```sh
dart run bin/extract_assets.dart <bundle.rgpack> <output_dir>
```

Writes `SpriteSheet.png` and `sprite_dict.json` into `<output_dir>`. This runs
on the plain Dart VM (no Flutter engine), so it fits into any build step.

---

## Development

Tech stack: Flutter (desktop), Riverpod 3 (`Notifier`/`NotifierProvider`),
`window_manager` for the custom window frame, the `image` package for packing,
`archive` for the ZIP bundle.

Verification loop (run all three before calling a change done):

```sh
flutter analyze          # must report "No issues found!"
flutter test             # full suite must pass
flutter build macos --debug
```

See `AGENTS.md` for the engineering-quality guide (the layer-isolation
invariant, `dart:ui` isolation in the model/logic layers, testing conventions,
and style rules) that applies to all changes here.

### macOS focus-freeze workaround

Flutter engine bug [flutter/flutter#155977](https://github.com/flutter/flutter/issues/155977):
when the app is reactivated via Cmd-Tab or Mission Control, macOS sometimes
skips the occlusion-state notification, so the engine reports
`AppLifecycleState.hidden` and the framework stops rendering - the window looks
frozen until the Dock icon is clicked. `macos/Runner/AppDelegate.swift`
carries an app-side workaround (`applicationDidBecomeActive` pushes
`AppLifecycleState.resumed` over the `flutter/lifecycle` channel when the main
window is visible), equivalent to the upstream fix in
[PR #188772](https://github.com/flutter/flutter/pull/188772). Remove the
override once that fix ships in the Flutter stable channel.

### File associations (`.rgpack`)

Double-clicking a `.rgpack` opens it in the app (Finder "Open With" on macOS,
Explorer double-click on Windows). The path is forwarded into Phase 1.

- **macOS**: declared as a document type in the Xcode project; the native
  `AppDelegate` forwards the opened path over the `app.rgpack/open` channel.
- **Windows**: the association is registered by the installer's Inno Setup
  `[Registry]` section, and a double-click launch passes the file path as a
  command-line argument (forwarded by the Windows runner into Dart `main`).
  `inno_bundle` has no file-association option, so `tool/inject_rgpack_association.ps1`
  patches the generated `inno-script.iss` before it is compiled. Uninstalling
  removes the association.

### Releases (CI)

Pushing a `V*` tag (e.g. `V0.1.1`) runs `.github/workflows/release.yml`, which
builds the Windows installer and publishes it to a GitHub Release. It follows
inno_bundle's official CI (Flutter build -> generate `.iss` -> compile with the
Inno Setup action) with the association-injection step added before compile.

To build the Windows installer locally instead:

```powershell
powershell -ExecutionPolicy Bypass -File tool\build_windows_installer.ps1
```

The installer is currently unsigned, so Windows SmartScreen will warn users
until code signing is added (`inno_bundle` supports a `sign_tool`).

---

## Status / roadmap

- [X] Multi-layer level editor; blocks filtered per layer.
  - [ ] Function layer (ordered check lines and walls), invisible - layer
    exists; no placeable wall/check-line blocks yet.
  - [X] Decoration layer (finish line and other decoration).
  - [X] Track layer.
  - [X] Island layer.
- [X] Cursor alignment guides (vertical/horizontal).
- [X] Auto island generation.
  - [X] 8-direction island port marking (interior, edges, convex/concave
    corners).
  - [X] Phase 1 island tile tally and set-completeness report.
  - [X] Basic generator (full convex set) and advanced (concave notches).
  - [X] Random pick when a tile kind has several variants.
  - [X] Grow the island from the track footprint and autotile by 8-neighbour
    grass mask.
  - [X] Manual grass brush to paint/erase the island region before autotiling.
- [X] Undo; confirm before clear-all.
- [X] Custom desktop window frame (window_manager).
- [X] Import map; auto-resize in Phase 1; drag-to-stamp in Phase 2.
- [X] Browser-style tabs (pinned Phase 1 + many Phase 2 levels).
- [X] Multiple decoration images (separate in Phase 1, merged on export).
- [X] Mark the drivable road area in Phase 1 (populates each block's
  `physicsTrackArea` polygon; inside = road friction, outside = grass/sand).
