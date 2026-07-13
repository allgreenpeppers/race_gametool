import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_providers.dart';
import '../../state/level_editor_providers.dart';
import '../widgets/block_thumbnail.dart';
import 'diagnostics_panel.dart';
import 'level_canvas.dart';

/// Phase 2: stamp palette blocks on the grid canvas, route ports, generate
/// the island, and export the map scene. The palette is fed by the shared
/// asset library, which File > Open Config and every Phase 1 save refresh;
/// there is deliberately no separate import path that could go stale.
class LevelEditorPage extends ConsumerWidget {
  const LevelEditorPage({super.key, required this.tabId});

  /// Which workspace tab (and thus which `levelEditorProvider` instance) this
  /// page edits.
  final int tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final library = ref.watch(assetLibraryProvider);
    final state = ref.watch(levelEditorProvider(tabId));
    final notifier = ref.read(levelEditorProvider(tabId).notifier);

    return Row(
      children: [
        _Palette(
          tabId: tabId,
          selectedId: state.selectedPaletteId,
          onSelect: notifier.selectPalette,
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: library.isEmpty
                    ? Center(
                        child: Text(
                          'Open a config (File > Open Config...) to start '
                          'building a level',
                          style: theme.textTheme.bodyLarge,
                        ),
                      )
                    : Focus(
                        autofocus: true,
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent) {
                            final isControlPressed =
                                HardwareKeyboard.instance.isControlPressed ||
                                HardwareKeyboard.instance.isMetaPressed;
                            if (isControlPressed &&
                                event.logicalKey == LogicalKeyboardKey.keyZ) {
                              notifier.undo();
                              return KeyEventResult.handled;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.delete ||
                                event.logicalKey ==
                                    LogicalKeyboardKey.backspace) {
                              notifier.deleteSelected();
                              return KeyEventResult.handled;
                            }
                          }
                          return KeyEventResult.ignored;
                        },
                        child: LevelCanvas(tabId: tabId),
                      ),
              ),
              if (library.isNotEmpty) DiagnosticsPanel(tabId: tabId),
            ],
          ),
        ),
      ],
    );
  }
}

class _Palette extends StatelessWidget {
  const _Palette({
    required this.tabId,
    required this.selectedId,
    required this.onSelect,
  });

  final int tabId;
  final String? selectedId;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final library = ref.watch(assetLibraryProvider);
        final activeLayer = ref.watch(
          levelEditorProvider(tabId).select((s) => s.activeLayer),
        );
        final theme = Theme.of(context);
        // Only show blocks whose category belongs to the active layer.
        final blocks = [
          for (final b in library.blocks)
            if (activeLayer.accepts(b.category)) b,
        ];
        return SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'Block Palette',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (library.sourceName != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Source: ${library.sourceName}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: library.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'No blocks loaded. Open a config via File > '
                            'Open Config..., or save one in Asset Definer.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : blocks.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'No ${activeLayer.label} blocks in this bundle.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: blocks.length,
                        itemBuilder: (context, index) {
                          final block = blocks[index];
                          final selected = block.id == selectedId;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor: theme
                                .colorScheme
                                .primaryContainer
                                .withValues(alpha: 0.4),
                            leading: SizedBox(
                              width: 40,
                              height: 40,
                              child: library.sheetImage == null
                                  ? const Icon(Icons.widgets_outlined)
                                  : BlockThumbnail(
                                      image: library.sheetImage!,
                                      rect: block.spriteSheetRect,
                                    ),
                            ),
                            title: Text(block.id),
                            subtitle: Text(
                              '${block.boundingBox.width} x '
                              '${block.boundingBox.height}, '
                              '${block.ports.length} ports',
                            ),
                            onTap: () => onSelect(block.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
