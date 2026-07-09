import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/asset_definer_providers.dart';
import 'inspector_panel.dart';
import 'mask_canvas.dart';

/// Phase 1: load a raw draft image, mask track pieces with bounding boxes,
/// define ports on their edges, then crop, bin-pack, and export
/// SpriteSheet.png plus sprite_dict.json.
class AssetDefinerPage extends ConsumerWidget {
  const AssetDefinerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(assetDefinerProvider);
    final notifier = ref.read(assetDefinerProvider.notifier);
    final theme = Theme.of(context);

    return Column(
      children: [
        // Toolbar. A Wrap keeps the controls from overflowing on narrow
        // windows, flowing onto a second line instead.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: notifier.loadImage,
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Load Image'),
              ),
              OutlinedButton.icon(
                onPressed: state.image == null ? null : notifier.swapImage,
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('Swap Image'),
              ),
              OutlinedButton.icon(
                onPressed: notifier.openBundle,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('Open Bundle'),
              ),
              SegmentedButton<Phase1Tool>(
                showSelectedIcon: false,
                segments: [
                  for (final tool in Phase1Tool.values)
                    ButtonSegment(
                      value: tool,
                      tooltip: tool.label,
                      icon: Icon(switch (tool) {
                        Phase1Tool.select => Icons.near_me_outlined,
                        Phase1Tool.move => Icons.open_with,
                        Phase1Tool.drawBox => Icons.crop_square,
                        Phase1Tool.paintMask => Icons.brush_outlined,
                        Phase1Tool.addPort => Icons.adjust,
                      }),
                    ),
                ],
                selected: {state.tool},
                onSelectionChanged: (selection) =>
                    notifier.setTool(selection.first),
              ),
              FilledButton.icon(
                onPressed: state.canExport ? notifier.saveBundle : null,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('Save Bundle'),
              ),
            ],
          ),
        ),
        // Active tool name plus the latest status line.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              Text('Tool: ${state.tool.label}',
                  style: theme.textTheme.labelMedium),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  state.statusMessage ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: Container(
                  color: theme.colorScheme.surfaceContainerLowest,
                  child: state.image == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.image_outlined,
                                  size: 64,
                                  color: theme.colorScheme.outline),
                              const SizedBox(height: 12),
                              Text(
                                'Load a raw draft image, then drag boxes '
                                'over each track piece',
                                style: theme.textTheme.bodyLarge,
                              ),
                            ],
                          ),
                        )
                      : const MaskCanvas(),
                ),
              ),
              const VerticalDivider(width: 1),
              const SizedBox(width: 280, child: InspectorPanel()),
            ],
          ),
        ),
      ],
    );
  }
}
