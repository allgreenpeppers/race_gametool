import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/pixel_ops.dart';
import '../../models/block_def.dart';
import '../../state/pixel_editor_providers.dart';
import 'color_panel.dart';
import 'pixel_canvas.dart';

IconData pixelToolIcon(PixelTool tool) => switch (tool) {
  PixelTool.pencil => Icons.edit,
  PixelTool.eraser => Icons.cleaning_services,
  PixelTool.line => Icons.timeline,
  PixelTool.rect => Icons.crop_square,
  PixelTool.ellipse => Icons.circle_outlined,
  PixelTool.fill => Icons.format_color_fill,
  PixelTool.eyedropper => Icons.colorize,
  PixelTool.selectRect => Icons.highlight_alt,
  PixelTool.lasso => Icons.gesture,
  PixelTool.wand => Icons.auto_fix_high,
  PixelTool.move => Icons.open_with,
};

String pixelToolShortcut(PixelTool tool) => switch (tool) {
  PixelTool.pencil => 'B',
  PixelTool.eraser => 'E',
  PixelTool.line => 'L',
  PixelTool.rect => 'R',
  PixelTool.ellipse => 'O',
  PixelTool.fill => 'G',
  PixelTool.eyedropper => 'I',
  PixelTool.selectRect => 'M',
  PixelTool.lasso => 'Q',
  PixelTool.wand => 'W',
  PixelTool.move => 'V',
};

/// One Pixel Editor document tab. File actions live in the application File
/// menu; this page owns document tools, options, canvas, and palette UI.
class PixelEditorPage extends ConsumerWidget {
  const PixelEditorPage({super.key, required this.tabId});

  final int tabId;

  Future<void> _resizeDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(pixelEditorProvider(tabId));
    var anchorX = -1, anchorY = -1;
    final size = await promptCanvasSize(
      context,
      title: 'Canvas Size',
      initialWidth: state.document.width,
      initialHeight: state.document.height,
      extra: StatefulBuilder(
        builder: (context, setState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            const Text('Anchor existing content:'),
            const SizedBox(height: 4),
            for (final y in [-1, 0, 1])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final x in [-1, 0, 1])
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      isSelected: anchorX == x && anchorY == y,
                      icon: Icon(
                        anchorX == x && anchorY == y
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 16,
                      ),
                      onPressed: () => setState(() {
                        anchorX = x;
                        anchorY = y;
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
    if (size == null) return;
    ref
        .read(pixelEditorProvider(tabId).notifier)
        .resizeCanvasTo(size.$1, size.$2, anchorX: anchorX, anchorY: anchorY);
  }

  static Future<(int, int)?> promptCanvasSize(
    BuildContext context, {
    required String title,
    required int initialWidth,
    required int initialHeight,
    Widget? extra,
  }) async {
    final widthController = TextEditingController(text: '$initialWidth');
    final heightController = TextEditingController(text: '$initialHeight');
    final result = await showDialog<(int, int)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: widthController,
                    decoration: const InputDecoration(
                      labelText: 'Width (px)',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: heightController,
                    decoration: const InputDecoration(
                      labelText: 'Height (px)',
                      isDense: true,
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),
              ],
            ),
            const Text(
              '1-1024 px. One grid cell is 16 px.',
              style: TextStyle(fontSize: 11),
            ),
            ?extra,
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final w = int.tryParse(widthController.text);
              final h = int.tryParse(heightController.text);
              if (w == null || h == null || w < 1 || h < 1) return;
              Navigator.pop(context, (w.clamp(1, 1024), h.clamp(1, 1024)));
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    widthController.dispose();
    heightController.dispose();
    return result;
  }

  Future<void> _sendToAssetDefiner(BuildContext context, WidgetRef ref) async {
    final state = ref.read(pixelEditorProvider(tabId));
    if (state.assetTarget != null) {
      await ref.read(pixelEditorProvider(tabId).notifier).sendToAssetDefiner();
      return;
    }
    final category = await showDialog<BlockCategory>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Send to Asset Definer as...'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.track),
            child: const Text('Track source image (replaces current)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.islandTile),
            child: const Text('Island source image (replaces current)'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, BlockCategory.decoration),
            child: const Text('New decoration image (added)'),
          ),
        ],
      ),
    );
    if (category == null) return;
    await ref
        .read(pixelEditorProvider(tabId).notifier)
        .sendToAssetDefiner(category);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(pixelEditorProvider(tabId).notifier);
    final tool = ref.watch(pixelEditorProvider(tabId).select((s) => s.tool));
    final preferences = ref.watch(pixelEditorPreferencesProvider);
    final brushSize = preferences.brushSize;
    final layerOpacity = ref.watch(
      pixelEditorProvider(tabId).select((s) => s.document.layers.first.opacity),
    );
    final symmetry = preferences.symmetry;
    final fillContiguous = preferences.fillContiguous;
    final fillTolerance = preferences.fillTolerance;
    final fillShadeEnabled = preferences.fillShadeEnabled;
    final fillShadeStrength = preferences.fillShadeStrength;
    final showPixelGrid = preferences.showPixelGrid;
    final showCellGrid = preferences.showCellGrid;
    final shapeMode = preferences.shapeMode;
    final shapePlan = ref.watch(
      pixelEditorProvider(tabId).select((s) => s.shapePlan),
    );
    final hasSelection = ref.watch(
      pixelEditorProvider(
        tabId,
      ).select((s) => s.selection != null || s.floating != null),
    );

    // Single-letter tool shortcuts live on the canvas area only (not the
    // whole page), so typing in the color panel's hex field never switches
    // tools.
    final canvasShortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyB): () =>
          notifier.setTool(PixelTool.pencil),
      const SingleActivator(LogicalKeyboardKey.keyE): () =>
          notifier.setTool(PixelTool.eraser),
      const SingleActivator(LogicalKeyboardKey.keyL): () =>
          notifier.setTool(PixelTool.line),
      const SingleActivator(LogicalKeyboardKey.keyR): () =>
          notifier.setTool(PixelTool.rect),
      const SingleActivator(LogicalKeyboardKey.keyO): () =>
          notifier.setTool(PixelTool.ellipse),
      const SingleActivator(LogicalKeyboardKey.keyG): () =>
          notifier.setTool(PixelTool.fill),
      const SingleActivator(LogicalKeyboardKey.keyI): () =>
          notifier.setTool(PixelTool.eyedropper),
      const SingleActivator(LogicalKeyboardKey.keyM): () =>
          notifier.setTool(PixelTool.selectRect),
      const SingleActivator(LogicalKeyboardKey.keyQ): () =>
          notifier.setTool(PixelTool.lasso),
      const SingleActivator(LogicalKeyboardKey.keyW): () =>
          notifier.setTool(PixelTool.wand),
      const SingleActivator(LogicalKeyboardKey.bracketLeft): () => notifier
          .setBrushSize(ref.read(pixelEditorPreferencesProvider).brushSize - 1),
      const SingleActivator(LogicalKeyboardKey.bracketRight): () => notifier
          .setBrushSize(ref.read(pixelEditorPreferencesProvider).brushSize + 1),
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          notifier.cancelFloatingOrSelection(),
      const SingleActivator(LogicalKeyboardKey.delete): () =>
          notifier.deleteSelectionContents(),
      const SingleActivator(LogicalKeyboardKey.backspace): () =>
          notifier.deleteSelectionContents(),
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true): () =>
          notifier.selectAll(),
      const SingleActivator(LogicalKeyboardKey.keyA, control: true): () =>
          notifier.selectAll(),
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
          notifier.undo(),
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
          notifier.undo(),
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true): () =>
          notifier.copySelection(),
      const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
          notifier.copySelection(),
      const SingleActivator(LogicalKeyboardKey.keyX, meta: true): () =>
          notifier.cutSelection(),
      const SingleActivator(LogicalKeyboardKey.keyX, control: true): () =>
          notifier.cutSelection(),
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): () =>
          notifier.pasteSelection(),
      const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
          notifier.pasteSelection(),
      const SingleActivator(LogicalKeyboardKey.enter): () =>
          notifier.confirmShapePlan(),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        meta: true,
        shift: true,
      ): () =>
          notifier.redo(),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): () =>
          notifier.redo(),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('pixel-options-toolbar'),
          height: 44,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Icon(Icons.brush, size: 14),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 170,
                        child: Slider(
                          min: 1,
                          max: 32,
                          divisions: 31,
                          value: brushSize.toDouble(),
                          label: '$brushSize px',
                          onChanged: (value) =>
                              notifier.setBrushSize(value.round()),
                        ),
                      ),
                      SizedBox(
                        width: 38,
                        child: Text(
                          '$brushSize px',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text('Opacity', style: TextStyle(fontSize: 11)),
                      Tooltip(
                        message: 'Opacity of the single editable layer',
                        child: SizedBox(
                          width: 110,
                          child: Slider(
                            min: 0,
                            max: 1,
                            divisions: 100,
                            value: layerOpacity,
                            label: '${(layerOpacity * 100).round()}%',
                            onChanged: notifier.setLayerOpacity,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 32,
                        child: Text(
                          '${(layerOpacity * 100).round()}%',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Tooltip(
                        message: 'Symmetry (mirror drawing)',
                        child: SegmentedButton<SymmetryMode>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: SymmetryMode.none,
                              label: Text('Off'),
                            ),
                            ButtonSegment(
                              value: SymmetryMode.horizontal,
                              label: Text('X'),
                            ),
                            ButtonSegment(
                              value: SymmetryMode.vertical,
                              label: Text('Y'),
                            ),
                            ButtonSegment(
                              value: SymmetryMode.both,
                              label: Text('XY'),
                            ),
                          ],
                          selected: {symmetry},
                          onSelectionChanged: (s) =>
                              notifier.setSymmetry(s.first),
                        ),
                      ),
                      if (tool == PixelTool.rect ||
                          tool == PixelTool.ellipse) ...[
                        const SizedBox(width: 12),
                        SegmentedButton<ShapeInteractionMode>(
                          showSelectedIcon: false,
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                          segments: const [
                            ButtonSegment(
                              value: ShapeInteractionMode.drag,
                              label: Text('Drag'),
                            ),
                            ButtonSegment(
                              value: ShapeInteractionMode.planned,
                              label: Text('Plan'),
                            ),
                          ],
                          selected: {shapeMode},
                          onSelectionChanged: (selection) =>
                              notifier.setShapeMode(selection.first),
                        ),
                        if (shapePlan != null) ...[
                          const SizedBox(width: 6),
                          FilledButton.tonalIcon(
                            onPressed: notifier.confirmShapePlan,
                            icon: const Icon(Icons.check, size: 16),
                            label: const Text('Confirm'),
                          ),
                          IconButton(
                            tooltip: 'Cancel planned shape',
                            onPressed: notifier.cancelShapePlan,
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ],
                      if (tool == PixelTool.fill || tool == PixelTool.wand) ...[
                        const SizedBox(width: 12),
                        FilterChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text('Connected only'),
                          tooltip:
                              'Off: replace or select matching colors '
                              'across the whole canvas',
                          selected: fillContiguous,
                          onSelected: notifier.setFillContiguous,
                        ),
                        const SizedBox(width: 8),
                        const Text('Tolerance', style: TextStyle(fontSize: 11)),
                        Tooltip(
                          message: '0 = exact color; 255 = any color',
                          child: SizedBox(
                            width: 110,
                            child: Slider(
                              value: fillTolerance.toDouble(),
                              max: 255,
                              divisions: 255,
                              label: '$fillTolerance',
                              onChanged: (v) =>
                                  notifier.setFillTolerance(v.round()),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 28,
                          child: Text(
                            '$fillTolerance',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        if (tool == PixelTool.fill) ...[
                          const SizedBox(width: 8),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text('Shade variation'),
                            tooltip:
                                'Adds stable light and dark texture around '
                                'the selected fill color',
                            selected: fillShadeEnabled,
                            onSelected: notifier.setFillShadeEnabled,
                          ),
                          if (fillShadeEnabled) ...[
                            const SizedBox(width: 6),
                            const Text('Shade', style: TextStyle(fontSize: 11)),
                            SizedBox(
                              width: 90,
                              child: Slider(
                                min: 1,
                                max: 32,
                                divisions: 31,
                                value: fillShadeStrength.toDouble(),
                                label: '$fillShadeStrength',
                                onChanged: (value) => notifier
                                    .setFillShadeStrength(value.round()),
                              ),
                            ),
                            SizedBox(
                              width: 20,
                              child: Text(
                                '$fillShadeStrength',
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ],
                      ],
                      const SizedBox(width: 12),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Pixel grid',
                        isSelected: showPixelGrid,
                        icon: const Icon(Icons.grid_3x3, size: 18),
                        onPressed: notifier.togglePixelGrid,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '16 px cell grid',
                        isSelected: showCellGrid,
                        icon: const Icon(Icons.grid_4x4, size: 18),
                        onPressed: notifier.toggleCellGrid,
                      ),
                      const SizedBox(width: 12),
                      MenuAnchor(
                        builder: (context, controller, _) => IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Canvas operations',
                          icon: const Icon(Icons.aspect_ratio, size: 18),
                          onPressed: () => controller.isOpen
                              ? controller.close()
                              : controller.open(),
                        ),
                        menuChildren: [
                          MenuItemButton(
                            onPressed: () => _resizeDialog(context, ref),
                            child: const Text('Canvas Size...'),
                          ),
                          MenuItemButton(
                            onPressed: hasSelection
                                ? notifier.cropToSelection
                                : null,
                            child: const Text('Crop to Selection'),
                          ),
                          const Divider(height: 1),
                          MenuItemButton(
                            onPressed: () =>
                                notifier.rotate90Action(clockwise: true),
                            child: Text(
                              hasSelection
                                  ? 'Rotate Selection 90 CW'
                                  : 'Rotate Canvas 90 CW',
                            ),
                          ),
                          MenuItemButton(
                            onPressed: () =>
                                notifier.rotate90Action(clockwise: false),
                            child: Text(
                              hasSelection
                                  ? 'Rotate Selection 90 CCW'
                                  : 'Rotate Canvas 90 CCW',
                            ),
                          ),
                          MenuItemButton(
                            onPressed: () =>
                                notifier.flipAction(horizontal: true),
                            child: Text(
                              hasSelection
                                  ? 'Flip Selection Horizontal'
                                  : 'Flip Canvas Horizontal',
                            ),
                          ),
                          MenuItemButton(
                            onPressed: () =>
                                notifier.flipAction(horizontal: false),
                            child: Text(
                              hasSelection
                                  ? 'Flip Selection Vertical'
                                  : 'Flip Canvas Vertical',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Copy selection',
                        onPressed: hasSelection ? notifier.copySelection : null,
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                      IconButton(
                        tooltip: 'Cut selection',
                        onPressed: hasSelection ? notifier.cutSelection : null,
                        icon: const Icon(Icons.content_cut, size: 18),
                      ),
                      IconButton(
                        tooltip: 'Paste pixels',
                        onPressed: notifier.pasteSelection,
                        icon: const Icon(Icons.content_paste, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Send to Asset Definer'),
                onPressed: () => _sendToAssetDefiner(context, ref),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: CallbackShortcuts(
                  bindings: canvasShortcuts,
                  child: Focus(
                    autofocus: true,
                    child: Builder(
                      builder: (context) => Listener(
                        // Clicking the canvas returns keyboard focus to it
                        // after typing in the color panel.
                        onPointerDown: (_) => Focus.of(context).requestFocus(),
                        child: Container(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLowest,
                          child: PixelCanvas(tabId: tabId),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              ColorPanel(tabId: tabId),
            ],
          ),
        ),
      ],
    );
  }
}
