# AGENTS.md

Instructions for AI coding agents (Claude Code, Codex, Antigravity, or any
other agent) working in this repository. This file is the single source of
truth for engineering quality here — read it before making changes, not
after something breaks.

## What this project is

A Flutter desktop (macOS) tool with two phases:

- **Phase 1 (Asset Definer)**: load a draft image, mask track/island/
  decoration/wall/check-line pieces, define ports, pack everything into a
  single `.rgpack` bundle (zip: raw source + editor state + packed sheet +
  sprite dict). The bundle is the **single source of truth** — never add a
  second export path that can drift from it. `bin/extract_assets.dart`
  derives game-ready files from the bundle at build time.
- **Phase 2 (Level Editor)**: import a `.rgpack`, stamp/connect blocks on a
  grid across independent **layers** (Track, Island, Decoration, Function),
  auto/manually generate the island, place spawn + export `map_NN.json`.

State management is Riverpod 3 (`Notifier`/`NotifierProvider` — not the
legacy `StateNotifierProvider`). Grid unit is 16x16 px.

## The verification loop — non-negotiable

Before saying a change is done, run all three, in order, and only report
success if all three are clean:

```
flutter analyze          # must report "No issues found!"
flutter test              # full suite must pass, not just the file you touched
flutter build macos --debug   # must succeed
```

Do not report a feature as "complete" on the strength of `flutter analyze`
alone — this codebase has had bugs that only `flutter test` or an actual
build catches (see "dart:ui isolation" below, which `flutter analyze` alone
will not catch if you only analyze the Flutter target).

## The layer/category isolation invariant

This is the most important structural rule in the codebase, and the one
most likely to be silently violated by new code.

Placements belong to a `BlockCategory` (`track`, `islandTile`,
`decoration`, `wall`, `checkLine`, ...), which maps to a `MapLayer`. Layers
are **independent planes**: a track piece and an island tile may legally
occupy the same grid cell, because the island sits "under" the track. This
means **every** code path that reasons about occupancy, overlap, selection,
or port connectivity must scope itself to the active layer or to a single
category — never to "all placements."

Concretely, if you add a new interaction that touches placements or ports,
check it against this list (all of these had to be fixed, more than once,
because a new path forgot the same scoping):

- Hit-testing (`portAt`, `connectPortAt`, `_placementAt`) — active layer only.
- Occupancy (`occupiedCells`, `_wouldOverlap`, `_placementsInRect`,
  group-move overlap checks) — active layer only.
- Port pairing (`connectCandidates`, `_straightConnector`, `findSeams`) —
  only within the same category; a track port must never see an island
  port as a candidate neighbor, even when they overlap on the grid.
- Diagnostics (`validateLevel`) — track-category only; other categories
  (especially island tiles, which can carry up to 8 ports) must not flood
  the Problems panel.
- Shift validation after insert/delete (`_validateLayout`) — overlap is
  only a conflict **within** a category, not across layers.

If you write a new function that walks `state.placements`, ask: "does this
need to ignore other layers/categories?" The answer is almost always yes.

## dart:ui isolation in the model/logic layers

`bin/extract_assets.dart` runs on the plain Dart VM (no Flutter engine), so
`lib/models/`, `lib/logic/asset_bundle.dart`, and
`lib/logic/sprite_exporter.dart` must never import `dart:ui` (directly or
transitively). A single unused `Vec2.toOffset()` helper once broke the CLI
this way — `flutter analyze` did not catch it; only running
`dart run bin/extract_assets.dart` did. If you add a method to a model
class, check what it imports.

## Other lessons already paid for in this codebase

- **Incremental over full-recompute for interactive tools.** The grass
  brush originally re-autotiled the *entire* painted region on every mouse
  move, which both re-randomized already-placed tiles (visible flicker,
  surprising to the user) and was slow. Paint/brush-style tools must only
  touch the region that actually changed (`_retileGrassCells` scopes to
  the changed cells plus their 8-neighbours).
- **Partial success over all-or-nothing.** Auto island generation used to
  refuse to place *any* tile if the tile set was incomplete. Prefer doing
  what you can and reporting precisely what's missing/unmatched, over a
  silent or opaque total failure.
- **Clear related state together.** `clearAll` once cleared placements but
  left `islandGrassMask` set, so a stale overlay lingered on screen after
  a full clear. When a feature adds new state that's logically tied to
  placements (a paint mask, a preview, a selection), audit every existing
  "reset/clear" entry point to include it — don't just add the new state
  and assume existing resets will find it.
- **Coordinate systems must match between preview and commit.** A stamp
  ghost preview and the actual placement once computed grid cells from two
  different coordinate spaces (`MouseRegion` outside vs. inside
  `InteractiveViewer`), so the preview and the real placement landed in
  different cells after panning/zooming. When you add a hover preview for
  an interactive tool, make sure the preview and the commit path derive
  the cell from the same transform.

## Testing conventions

- Pure functions (`lib/logic/`, `lib/models/`): plain `test()`, no widget
  bindings.
- Riverpod notifier behavior: `ProviderContainer()` +
  `TestWidgetsFlutterBinding.ensureInitialized()` (tests that populate
  `AssetLibrary` decode a real `ui.Image`, which needs the binding).
- When you fix a bug, add a test that reproduces it before the fix and
  passes after — not just a test of the new happy path. Several fixes in
  this repo's history are proven by a test named after the bug (e.g.
  `test/port_isolation_test.dart`, `test/grass_brush_test.dart`).

## Style

- No emojis anywhere — code, comments, commit messages, UI text. This is
  an explicit, hard project rule.
- Don't add speculative abstractions, feature flags, or backwards-compat
  shims. Change the code directly; there are no external consumers to
  protect yet.
- Keep comments to the non-obvious "why" (a workaround, an invariant, a
  cross-reference to one of the lessons above) — not a restatement of what
  the code already says.

## Commit messages

Write a body, not just a subject. State the root cause and the fix, and
mention what test proves it. `git log` in this repo is meant to be readable
as engineering history, not just a list of subjects.
