import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/asset_bundle.dart';
import '../../state/app_providers.dart';
import '../widgets/block_thumbnail.dart';

/// Phase 2: load a .rgpack asset bundle into a palette, stamp blocks on
/// an InteractiveViewer grid, route straight and diagonal segments between
/// ports, generate the island terrain, and export the map scene.
///
/// This page currently loads a shared bundle and shows the block palette
/// with rendered thumbnails. Placement, routing, and island generation
/// arrive in later steps.
class LevelEditorPage extends ConsumerWidget {
  const LevelEditorPage({super.key});

  Future<void> _importBundle(WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Import asset bundle',
      type: FileType.custom,
      allowedExtensions: ['rgpack'],
      withData: true,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    final data = readAssetBundle(bytes);
    await ref.read(assetLibraryProvider.notifier).loadAssets(
          blocks: data.blocks,
          sheetBytes: data.sheetBytes,
          sourceName: result!.files.single.name,
        );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final library = ref.watch(assetLibraryProvider);

    return Row(
      children: [
        SizedBox(
          width: 240,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Block Palette',
                          style: theme.textTheme.titleMedium),
                    ),
                    IconButton(
                      tooltip: 'Import bundle (.rgpack)',
                      icon: const Icon(Icons.folder_open),
                      onPressed: () => _importBundle(ref),
                    ),
                  ],
                ),
              ),
              if (library.sourceName != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Source: ${library.sourceName}',
                      style: theme.textTheme.bodySmall),
                ),
              Expanded(
                child: library.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'No blocks loaded. Save a bundle in Phase 1, or '
                            'import a .rgpack here.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: library.blocks.length,
                        itemBuilder: (context, index) {
                          final block = library.blocks[index];
                          return ListTile(
                            dense: true,
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
                                '${block.boundingBox.height} cells, '
                                '${block.ports.length} ports'),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.grid_on_outlined,
                    size: 64, color: theme.colorScheme.outline),
                const SizedBox(height: 12),
                Text(
                    'Grid canvas (InteractiveViewer) arrives in a later step',
                    style: theme.textTheme.bodyLarge),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
