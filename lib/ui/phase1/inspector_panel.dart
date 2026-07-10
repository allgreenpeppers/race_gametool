import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/block_def.dart';
import '../../models/port.dart';
import '../../state/asset_definer_providers.dart';
import '../widgets/port_marker.dart';
import 'asset_definer_page.dart' show categoryLabel;

/// Right-hand inspector for Phase 1: edits the selected mask's ID and
/// its list of ports, and lists all defined blocks for quick selection.
class InspectorPanel extends ConsumerWidget {
  const InspectorPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(assetDefinerProvider);
    final notifier = ref.read(assetDefinerProvider.notifier);
    final theme = Theme.of(context);
    final selectedIndex = state.selectedIndex;
    final mask = state.selectedMask;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Inspector', style: theme.textTheme.titleMedium),
        ),
        if (mask == null || selectedIndex == null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No block selected. Use the Select tool and click a box, '
              'or draw a new box.',
              style: theme.textTheme.bodySmall,
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextFormField(
              key: ValueKey('mask_id_$selectedIndex'),
              initialValue: mask.id,
              decoration: const InputDecoration(
                labelText: 'Block ID',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => notifier.renameMask(selectedIndex, value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Bounding box: ${mask.widthCells} x ${mask.heightCells} cells '
              'at (${mask.gridX}, ${mask.gridY})'
              '${mask.isFreeform ? ', freeform (${mask.cells!.length} cells)' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                const Text('Category'),
                const SizedBox(width: 8),
                DropdownButton<BlockCategory>(
                  value: mask.category,
                  isDense: true,
                  items: [
                    for (final c in BlockCategory.values)
                      DropdownMenuItem(
                          value: c, child: Text(categoryLabel(c))),
                  ],
                  onChanged: (c) {
                    if (c != null) {
                      notifier.setMaskCategory(selectedIndex, c);
                    }
                  },
                ),
              ],
            ),
          ),
          if (mask.category == BlockCategory.islandTile)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                children: [
                  const Text('Corner'),
                  const SizedBox(width: 8),
                  DropdownButton<CornerType>(
                    value: mask.cornerType,
                    isDense: true,
                    items: const [
                      DropdownMenuItem(
                          value: CornerType.none, child: Text('None / edge')),
                      DropdownMenuItem(
                          value: CornerType.convex, child: Text('Convex')),
                      DropdownMenuItem(
                          value: CornerType.concave, child: Text('Concave')),
                    ],
                    onChanged: (t) {
                      if (t != null) {
                        notifier.setMaskCornerType(selectedIndex, t);
                      }
                    },
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Ports (${mask.ports.length})',
                style: theme.textTheme.titleSmall),
          ),
          if (mask.ports.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Switch to the Add Port tool and drag a one-row or '
                'one-column strip along the block edge. The direction is '
                'chosen from the touched edge; one-cell-thick pieces get a '
                'bidirectional pass-through port.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: mask.ports.length,
              itemBuilder: (context, portIndex) {
                final port = mask.ports[portIndex];
                // Strip ports can only face along their travel axis;
                // single-cell ports may be reassigned to any direction
                // (including diagonals for special pieces).
                final options = port.span == 1
                    ? PortDirection.values
                    : [port.direction, port.direction.opposite];
                // Wide strips have a fixed travel axis; single-cell ports
                // stay editable even when auto-detected as bidirectional,
                // since a 1x1 selection cannot express the intended axis.
                final locked = port.bidirectional && port.span > 1;
                return ListTile(
                  dense: true,
                  leading: PortMarker(
                    direction: port.direction,
                    size: 26,
                    bidirectional: port.bidirectional,
                  ),
                  title: locked
                      ? Text(
                          '${port.direction.jsonValue} + '
                          '${port.direction.opposite.jsonValue}',
                          style: theme.textTheme.bodyMedium,
                        )
                      : DropdownButton<PortDirection>(
                          value: port.direction,
                          isDense: true,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final dir in options)
                              DropdownMenuItem(
                                  value: dir, child: Text(dir.jsonValue)),
                          ],
                          onChanged: (dir) {
                            if (dir == null) return;
                            // Keep the pass-through flag only when the new
                            // direction stays on the same axis.
                            final sameAxis = dir == port.direction ||
                                dir == port.direction.opposite;
                            notifier.updatePort(
                              selectedIndex,
                              portIndex,
                              port.copyWith(
                                direction: dir,
                                bidirectional:
                                    port.bidirectional && sameAxis,
                              ),
                            );
                          },
                        ),
                  subtitle: Text(
                      'cell (${port.localGridX}, ${port.localGridY}), '
                      'span ${port.span}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: 'Remove port',
                    onPressed: () =>
                        notifier.removePort(selectedIndex, portIndex),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error),
              icon: const Icon(Icons.delete_forever),
              label: const Text('Delete Block'),
              onPressed: () => notifier.removeMask(selectedIndex),
            ),
          ),
        ],
        if (mask == null) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('Blocks (${state.masks.length})',
                style: theme.textTheme.titleSmall),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.masks.length,
              itemBuilder: (context, index) {
                final m = state.masks[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.crop_square, size: 18),
                  title: Text(m.id),
                  subtitle: Text(
                      '${m.widthCells} x ${m.heightCells} cells, '
                      '${m.ports.length} ports'),
                  onTap: () => notifier.selectMask(index),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
