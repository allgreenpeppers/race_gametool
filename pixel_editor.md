# Pixel Editor

The app includes a multi-tab pixel editor for creating and revising source
images used by Asset Definer. User-facing UI uses the names **Asset Definer**,
**Pixel Editor**, and **Level Editor**; Phase 1/2 remain internal engineering
terms only.

## Workspace and file flow

- Pixel Editor documents open in independent, closable tabs with their own
  canvas, selection, history, palette, dirty state, and file path.
- While a Pixel Editor tab is active, the top-level File menu exposes New
  Pixel Project, Open Pixel Project, Import Image, Export PNG, Save, and Save
  As. Pixel-specific file commands are hidden in the other editors.
- Import Image preserves exact dimensions and pixels: one source pixel maps to
  one canvas pixel, with no scaling or filtering.
- Asset Definer images have an **Edit in Pixel Editor** action. A one-layer
  embedded `.rgpix` source is restored exactly; older PNG-only bundles are
  opened as a one-layer pixel document at their native resolution. Multi-layer
  projects are flattened because layer editing is not available yet.
- Opening an Asset Definer source that is already being edited activates its
  existing Pixel Editor tab instead of creating a second, conflicting editor.
- **Send to Asset Definer** stores both the flattened PNG and editable `.rgpix`
  source. Saving a tab opened from Asset Definer updates the same embedded
  source without requiring a separate project file.
- `.rgpack` version 4 stores the editable pixel source as an optional entry per
  source image, including each decoration image. Bundles without these entries
  remain readable and editable through the PNG fallback.

The `.rgpack` remains the single source of truth. Embedded pixel data is source
material inside the bundle, not a second export path; packed sheets and sprite
dictionaries continue to be derived by the existing bundle pipeline.

## Editing tools

- Pencil and eraser use a 1–32 px slider.
- **Mosaic Brush** uses that same slider as its square-cell size. A stroke's
  first pixel is the A/B checkerboard origin. Choose A or B in the toolbar,
  then set it with the shared right-hand color panel. A transparent B
  (`00000000`) skips those cells without painting or erasing existing pixels.
- The current single editable layer has a document-owned 0–100% opacity
  control. Opacity is undoable and persists in `.rgpix` and embedded sources.
- Line, rectangle, and ellipse use pixel-accurate previews and commit as one
  undo step.
- Rectangle and ellipse support two interaction modes:
  - **Drag**: drag the bounds and hold Shift for a square or circle.
  - **Plan**: draw initial bounds, adjust the four side handles, then Confirm
    or Cancel.
- Fill supports a 0–255 per-channel color tolerance and **Connected only**.
  When enabled, filling follows the four-directionally connected region
  containing the clicked pixel. When disabled, it replaces every matching
  color on the canvas. Tolerance 0 is an exact match; higher values include
  increasingly similar colors.
- Fill can enable **Shade variation** for a Minecraft-like textured color.
  It keeps the chosen color as the base and adds stable, clustered light and
  dark variations. The 1–32 Shade control changes the contrast; the pattern
  is coordinate-based, so it does not flicker or change when the canvas
  repaints.
- Eyedropper, horizontal/vertical/both-axis symmetry, canvas resize/crop,
  rotate, flip, and JASC `.pal` import/export are available.

## Selection and clipboard

The three selection modes are rectangle, lasso, and magic wand.

- Marquee and lasso selection automatically discard transparent padding, so
  the canvas draws the outer edge of actual image pixels rather than the full
  drag rectangle. Irregular selections do not show horizontal interior bands.
- Holding Shift adds the new mask to the current selection in all three modes.
- Dragging selected pixels lifts them into a floating selection directly; a
  separate Move tool is not required. The floating selection can be resized
  with nearest-neighbour corner handles. Escape restores the original pixels;
  clicking outside commits.
- Switching to any drawing tool cancels the selection first, so pencil,
  eraser, fill, and shapes always operate on the normal canvas. Select again
  when a limited edit or transform is wanted.
- Copy, Cut, and Paste work from the Edit menu, toolbar, and standard keyboard
  shortcuts. Pixel data is shared between Pixel Editor tabs and mirrored to
  the system clipboard in the app's versioned JSON clipboard format.

## Colors

- Each document owns its editable palette; new documents start with the
  DawnBringer 32 palette and `.rgpix` files preserve an intentionally empty
  palette.
- A separate **Image Colors** section lists up to 256 frequent non-transparent
  colors from the current image. It is a pick-only convenience section and can
  be refreshed after editing.
- HSV controls and hex/AARRGGBB entry edit the active color, and palettes can be
  imported or exported as JASC `.pal` files.

## Settings ownership

The following are session-wide Pixel Editor preferences shared by every tab
and do not dirty a document: brush size, fill tolerance, Connected only,
Shade variation and strength, symmetry, pixel grid, 16 px cell grid, and
rectangle/ellipse interaction mode.

Document-owned state is limited to canvas dimensions, layers/pixels, and the
editable palette. Tool choice, selection/floating state, image-color helpers,
undo/redo history, active color, and Mosaic B are tab-local working state.
Presentation and tool preferences are intentionally not serialized into
`.rgpix`.

## File formats and architecture

`.rgpix` version 1 is JSON containing dimensions, a bottom-to-top layer stack,
and palette. The current editor normalizes a multi-layer project to one
flattened editable layer on opening; layer editing is deferred. Layer pixels
are portable row-major RGBA bytes encoded as base64.
Older files that contain the former `settings` object remain readable; that
field is ignored because settings now belong to the app session.

- `lib/models/pixel_document.dart`: document/layer model and `.rgpix` codec;
  deliberately has no `dart:ui` dependency.
- `lib/logic/pixel_ops.dart`: pure buffer operations for drawing, fill,
  selection, transforms, image colors, and resize/crop.
- `lib/state/pixel_editor_providers.dart`: Riverpod family provider for
  tab-local editor state plus shared preferences and clipboard providers.
- `lib/ui/pixel_editor/`: canvas, options toolbar, color panel, and dialogs.
- `lib/logic/asset_bundle.dart`: optional embedded `.rgpix` entries and
  backwards-compatible bundle reading.

Layers/blend-mode UI and animation remain deferred; the document model and
file format already retain a layer stack so they can be added without changing
the current single-layer editing flow.
