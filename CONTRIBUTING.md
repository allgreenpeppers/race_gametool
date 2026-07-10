# Contributing to race_gametool

This project has both human and AI-agent contributors (Claude Code, Codex,
Antigravity, and others). If you are an AI agent, read `AGENTS.md` first —
it has the engineering-quality rules this file only summarizes.

## Workflow

- Branch off `dev`, not `main`. `main` is merged from `dev` via PR.
- Before opening a PR, all three of these must be clean:
  1. `flutter analyze` — zero issues.
  2. `flutter test` — full suite green.
  3. `flutter build macos --debug` — succeeds.
- Write commit messages with a body, not just a subject line. Explain the
  **why** / root cause, not just what changed — `git log --oneline` should
  read as a changelog, but the full message is what the next person (human
  or agent) reads to understand a bug fix without re-deriving it.
- Update `README.md`'s Todo list when you finish or add a tracked item.

## Project shape

- `lib/models/` — pure Dart data models (BlockDef, Port, MapScene, ...).
  No `dart:ui`. See "dart:ui isolation" in `AGENTS.md` for why.
- `lib/logic/` — pure functions: bin packing, sprite export, port
  placement rules, island tiling, track topology, diagnostics. These take
  plain data in, return plain data out, and are the easiest place to add a
  unit test.
- `lib/state/` — Riverpod 3 `Notifier`/`NotifierProvider` state for Phase 1
  (Asset Definer) and Phase 2 (Level Editor). Use the `Notifier` API, not
  the legacy `StateNotifierProvider`.
- `lib/ui/` — widgets. Canvas rendering is `CustomPainter`; keep paint
  logic out of the notifiers and vice versa.
- `bin/extract_assets.dart` — plain-Dart-VM CLI that pulls the game-ready
  sprite sheet + dict out of a `.rgpack` bundle. It cannot depend on
  anything under `lib/` that imports `dart:ui`.

## Testing conventions

- Pure logic in `lib/logic/` and `lib/models/`: plain `test()` blocks, no
  widget bindings needed.
- Riverpod notifier behavior: `ProviderContainer` plus
  `TestWidgetsFlutterBinding.ensureInitialized()` (needed because tests
  that set up `AssetLibrary` decode a real `ui.Image`).
- Name test files after what they cover, not after the source file 1:1 —
  e.g. `port_isolation_test.dart` covers a cross-cutting concern spanning
  several files in `lib/state/` and `lib/logic/`.

## Style

- No emojis in code, comments, commit messages, or UI text — this is a
  hard project rule, not a preference.
- Don't add a feature-flag or backwards-compat shim for something you can
  just change outright; this is a young codebase with no external
  consumers to protect yet.
- Prefer fixing the root cause over papering over a symptom — see
  "engineering-quality lessons" in `AGENTS.md` for concrete examples from
  this project's own history.
