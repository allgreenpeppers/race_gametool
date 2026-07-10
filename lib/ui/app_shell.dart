import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../models/block_def.dart';
import '../state/app_providers.dart';
import '../state/asset_definer_providers.dart';
import '../state/file_open_service.dart';
import '../state/level_editor_providers.dart';
import 'phase1/asset_definer_page.dart';
import 'phase2/level_editor_page.dart';

/// Main shell: a NavigationRail switching between the two tool phases.
/// The active mode lives in Riverpod so any part of the app can switch modes.
/// The top bar is custom-rendered to integrate with window manager frame hiding.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Start listening for .rgpack files opened from Finder.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(fileOpenServiceProvider).start();
    });
  }

  Future<bool> _promptUnsavedChanges({
    required String title,
    required String content,
    required VoidCallback onSave,
  }) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == 'save') {
      onSave();
      return true;
    }
    return result == 'discard';
  }

  Future<void> _handleNewConfig(WidgetRef ref) async {
    final assetState = ref.read(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);
    final levelState = ref.read(levelEditorProvider);
    final levelNotifier = ref.read(levelEditorProvider.notifier);

    if (assetState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Config Changes?',
        content: 'Your asset config has unsaved changes. Do you want to save before creating a new config?',
        onSave: () => assetNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    if (levelState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content: 'Your level map has unsaved changes. Do you want to save before creating a new config?',
        onSave: () => levelNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    assetNotifier.newConfig();
    levelNotifier.newGameMap();
  }

  Future<void> _handleNewGameMap(WidgetRef ref) async {
    final levelState = ref.read(levelEditorProvider);
    final levelNotifier = ref.read(levelEditorProvider.notifier);

    if (levelState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content: 'Your level map has unsaved changes. Do you want to save before creating a new game map?',
        onSave: () => levelNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    levelNotifier.newGameMap();
  }

  Future<void> _handleOpenConfig(WidgetRef ref) async {
    final assetState = ref.read(assetDefinerProvider);
    final assetNotifier = ref.read(assetDefinerProvider.notifier);

    if (assetState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Config Changes?',
        content: 'Your asset config has unsaved changes. Do you want to save before opening another config?',
        onSave: () => assetNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    await assetNotifier.openBundle();
  }

  Future<void> _handleOpenGameLevel(WidgetRef ref) async {
    final levelState = ref.read(levelEditorProvider);
    final levelNotifier = ref.read(levelEditorProvider.notifier);

    if (levelState.isDirty) {
      final proceed = await _promptUnsavedChanges(
        title: 'Save Game Map Changes?',
        content: 'Your level map has unsaved changes. Do you want to save before opening another level?',
        onSave: () => levelNotifier.save(),
      );
      if (!proceed) return;
    }

    if (!mounted) return;

    await levelNotifier.openGameLevelDialog();
  }

  void _handleSave(WidgetRef ref) {
    final mode = ref.read(appModeProvider);
    if (mode == AppMode.assetDefiner) {
      ref.read(assetDefinerProvider.notifier).save();
    } else {
      ref.read(levelEditorProvider.notifier).save();
    }
  }

  void _handleSaveAs(WidgetRef ref) {
    final mode = ref.read(appModeProvider);
    if (mode == AppMode.assetDefiner) {
      ref.read(assetDefinerProvider.notifier).saveAs();
    } else {
      ref.read(levelEditorProvider.notifier).saveAs();
    }
  }

  void _handleUndo(WidgetRef ref) {
    final mode = ref.read(appModeProvider);
    if (mode == AppMode.levelEditor) {
      ref.read(levelEditorProvider.notifier).undo();
    }
  }

  Future<void> _handleClearLayer(WidgetRef ref) async {
    final mode = ref.read(appModeProvider);
    if (mode != AppMode.levelEditor) return;

    final levelState = ref.read(levelEditorProvider);
    final levelNotifier = ref.read(levelEditorProvider.notifier);
    final activeLayer = levelState.activeLayer;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear ${activeLayer.label} Layer?'),
        content: Text('Are you sure you want to clear all placements on the ${activeLayer.label} layer? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirm == true) {
      levelNotifier.clearLayer(activeLayer);
    }
  }

  Future<void> _handleAutotile(
    LevelEditorNotifier levelNotifier,
  ) async {
    final levelState = ref.read(levelEditorProvider);
    if (levelState.islandGrassMask != null) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard Manual Edits?'),
          content: const Text(
            'This will discard your manual island edits and regenerate from the track footprint. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirm != true) return;
    }
    levelNotifier.generateIsland();
  }

  Widget _buildModeButton(
    BuildContext context, {
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Icon(selected ? selectedIcon : icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onPressed,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 80,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.2) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: selected ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.5)) : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontSize: 10,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuBar(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 32,
      child: MenuBar(
        style: MenuStyle(
          elevation: WidgetStateProperty.all(0),
          backgroundColor: WidgetStateProperty.all(Colors.transparent),
        ),
        children: [
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
                onPressed: () => _handleNewConfig(ref),
                child: const Text('New Config'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true),
                onPressed: () => _handleNewGameMap(ref),
                child: const Text('New Game Map'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true),
                onPressed: () => _handleOpenConfig(ref),
                child: const Text('Open Config...'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true),
                onPressed: () => _handleOpenGameLevel(ref),
                child: const Text('Open Game Level...'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true),
                onPressed: () => _handleSave(ref),
                child: const Text('Save'),
              ),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
                onPressed: () => _handleSaveAs(ref),
                child: const Text('Save As...'),
              ),
            ],
            child: const Text('File'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, control: true),
                onPressed: () => _handleUndo(ref),
                child: const Text('Undo'),
              ),
              const PopupMenuDivider(),
              MenuItemButton(
                shortcut: const SingleActivator(LogicalKeyboardKey.delete, control: true),
                onPressed: () => _handleClearLayer(ref),
                child: const Text('Clear Active Layer'),
              ),
            ],
            child: const Text('Edit'),
          ),
        ],
      ),
    );
  }

  Widget _buildRootShell(BuildContext context, Widget child) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return PlatformMenuBar(
        menus: [
          PlatformMenu(
            label: 'Race Game Tool',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
                  PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
                ],
              ),
            ],
          ),
          PlatformMenu(
            label: 'File',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'New Config',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
                    onSelected: () => _handleNewConfig(ref),
                  ),
                  PlatformMenuItem(
                    label: 'New Game Map',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true, shift: true),
                    onSelected: () => _handleNewGameMap(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Open Config...',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
                    onSelected: () => _handleOpenConfig(ref),
                  ),
                  PlatformMenuItem(
                    label: 'Open Game Level...',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
                    onSelected: () => _handleOpenGameLevel(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Save',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true),
                    onSelected: () => _handleSave(ref),
                  ),
                  PlatformMenuItem(
                    label: 'Save As...',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true),
                    onSelected: () => _handleSaveAs(ref),
                  ),
                ],
              ),
            ],
          ),
          PlatformMenu(
            label: 'Edit',
            menus: [
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Undo',
                    shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
                    onSelected: () => _handleUndo(ref),
                  ),
                ],
              ),
              PlatformMenuItemGroup(
                members: [
                  PlatformMenuItem(
                    label: 'Clear Active Layer',
                    shortcut: const SingleActivator(LogicalKeyboardKey.delete, meta: true),
                    onSelected: () => _handleClearLayer(ref),
                  ),
                ],
              ),
            ],
          ),
        ],
        child: child,
      );
    }
    return child;
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    final theme = Theme.of(context);

    // Watch specific provider states to render in the unified top toolbar.
    // This avoids rebuilding the AppShell (and triggering macOS native menubar rebuilds) on every mouse hover/movement.
    final activeCategory = ref.watch(assetDefinerProvider.select((s) => s.activeCategory));
    final assetTool = ref.watch(assetDefinerProvider.select((s) => s.tool));
    final hasActiveImage = ref.watch(assetDefinerProvider.select((s) => s.activeImage != null));
    final assetStatusMessage = ref.watch(assetDefinerProvider.select((s) => s.statusMessage));

    final activeLayer = ref.watch(levelEditorProvider.select((s) => s.activeLayer));
    final levelTool = ref.watch(levelEditorProvider.select((s) => s.tool));
    final islandBrushRadius = ref.watch(levelEditorProvider.select((s) => s.islandBrushRadius));
    final highlightedList = ref.watch(levelEditorProvider.select((s) => s.highlighted));
    final levelStatusMessage = ref.watch(levelEditorProvider.select((s) => s.statusMessage));
    final placementsLength = ref.watch(levelEditorProvider.select((s) => s.placements.length));
    final hasSpawn = ref.watch(levelEditorProvider.select((s) => s.spawn != null));

    final assetNotifier = ref.read(assetDefinerProvider.notifier);
    final levelNotifier = ref.read(levelEditorProvider.notifier);

    final mainContent = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          if (mode == AppMode.levelEditor) {
            levelNotifier.undo();
          }
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () {
          if (mode == AppMode.levelEditor) {
            levelNotifier.undo();
          }
        },
      },
      child: Scaffold(
        body: Column(
          children: [
            // Unified Top Toolbar and Window Control Row (Split into 2 Lines)
            Container(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Line 1: Window Controls + MenuBar (non-macOS) + Drag Area
                  Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        // macOS spacing to avoid the system Traffic Light buttons
                        if (defaultTargetPlatform == TargetPlatform.macOS)
                          const SizedBox(width: 80),

                        // Esport Icon and Title
                        const Icon(Icons.sports_esports, size: 20, color: Colors.cyan),
                        const SizedBox(width: 8),
                        Text(
                          'Race Game Tool',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const VerticalDivider(width: 24, indent: 10, endIndent: 10),

                        if (defaultTargetPlatform != TargetPlatform.macOS) ...[
                          _buildMenuBar(context, ref),
                          const VerticalDivider(width: 24, indent: 10, endIndent: 10),
                        ],

                        // Draggable Middle Area
                        Expanded(
                          child: DragToMoveArea(
                            child: Container(height: 40, color: Colors.transparent),
                          ),
                        ),

                        // Windows OS control buttons (rendered using WindowCaption)
                        if (defaultTargetPlatform != TargetPlatform.macOS)
                          SizedBox(
                            width: 140,
                            height: 40,
                            child: WindowCaption(
                              backgroundColor: Colors.transparent,
                              brightness: theme.brightness,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),

                  // Line 2: Tools and Action buttons (horizontal scrollable row)
                  Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (mode == AppMode.assetDefiner) ...[
                            // Tool SegmentedButton
                            SegmentedButton<Phase1Tool>(
                              showSelectedIcon: false,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                              segments: [
                                for (final t in Phase1Tool.values)
                                  if ((activeCategory == BlockCategory.track) ||
                                      (activeCategory == BlockCategory.islandTile &&
                                          t != Phase1Tool.paintMask &&
                                          t != Phase1Tool.addPort) ||
                                      (activeCategory == BlockCategory.decoration &&
                                          t != Phase1Tool.addPort))
                                    ButtonSegment(
                                      value: t,
                                      tooltip: t.label,
                                      icon: Icon(switch (t) {
                                        Phase1Tool.select => Icons.near_me_outlined,
                                        Phase1Tool.move => Icons.open_with,
                                        Phase1Tool.drawBox => Icons.crop_square,
                                        Phase1Tool.paintMask => Icons.brush_outlined,
                                        Phase1Tool.addPort => Icons.adjust,
                                      }),
                                    ),
                              ],
                              selected: {assetTool},
                              onSelectionChanged: (selection) =>
                                  assetNotifier.setTool(selection.first),
                            ),
                            const SizedBox(width: 12),

                            // Action Buttons
                            FilledButton.tonalIcon(
                              onPressed: assetNotifier.loadImage,
                              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                              icon: const Icon(Icons.image_outlined, size: 16),
                              label: Text(
                                !hasActiveImage ? 'Load Image' : 'Replace Image',
                              ),
                            ),
                          ] else if (mode == AppMode.levelEditor) ...[
                            // Tool SegmentedButton
                            SegmentedButton<LevelTool>(
                              showSelectedIcon: false,
                              style: const ButtonStyle(visualDensity: VisualDensity.compact),
                              segments: [
                                for (final tool in LevelTool.values)
                                  if ((activeLayer != MapLayer.island &&
                                          activeLayer != MapLayer.decoration) ||
                                      (tool != LevelTool.connect &&
                                          tool != LevelTool.insert &&
                                          tool != LevelTool.spawn))
                                    ButtonSegment(
                                      value: tool,
                                      tooltip: tool.label,
                                      icon: Icon(switch (tool) {
                                        LevelTool.select => Icons.near_me_outlined,
                                        LevelTool.multi => Icons.select_all,
                                        LevelTool.stamp => Icons.add_box_outlined,
                                        LevelTool.connect => Icons.hub_outlined,
                                        LevelTool.insert => Icons.linear_scale,
                                        LevelTool.spawn => Icons.flag_outlined,
                                        LevelTool.erase => Icons.cleaning_services,
                                      }),
                                    ),
                              ],
                              selected: {levelTool},
                              onSelectionChanged: (s) => levelNotifier.setTool(s.first),
                            ),
                            const SizedBox(width: 12),

                            // Island Brush Controls
                            if (activeLayer == MapLayer.island) ...[
                              const Icon(Icons.brush, size: 16),
                              const SizedBox(width: 4),
                              SegmentedButton<int>(
                                showSelectedIcon: false,
                                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                                segments: const [
                                  ButtonSegment(value: 0, label: Text('1x1')),
                                  ButtonSegment(value: 1, label: Text('3x3')),
                                  ButtonSegment(value: 2, label: Text('5x5')),
                                  ButtonSegment(value: 3, label: Text('7x7')),
                                ],
                                selected: {islandBrushRadius},
                                onSelectionChanged: (s) =>
                                    levelNotifier.setIslandBrushRadius(s.first),
                              ),
                              const SizedBox(width: 6),
                              FilledButton.tonalIcon(
                                onPressed: () => _handleAutotile(levelNotifier),
                                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                                icon: const Icon(Icons.grass, size: 16),
                                label: const Text('Autotile'),
                              ),
                              const SizedBox(width: 12),
                            ],

                            // Remove & Close Connection
                            if (highlightedList.length == 1) ...[
                              OutlinedButton.icon(
                                onPressed: () => levelNotifier.deleteStraightAndClose(
                                  highlightedList.first,
                                ),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                                icon: const Icon(Icons.compress, size: 16),
                                label: const Text('Remove & Close'),
                              ),
                              const SizedBox(width: 6),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Main View Content
            Expanded(
              child: Row(
                children: [
                  // Sidebar
                  Container(
                    width: 90,
                    color: theme.colorScheme.surfaceContainerLow,
                    child: Column(
                      children: [
                        const SizedBox(height: 12),
                        _buildModeButton(
                          context,
                          icon: Icons.category_outlined,
                          selectedIcon: Icons.category,
                          label: 'Asset\nDefiner',
                          selected: mode == AppMode.assetDefiner,
                          onPressed: () => ref.read(appModeProvider.notifier).select(AppMode.assetDefiner),
                        ),
                        const SizedBox(height: 12),
                        _buildModeButton(
                          context,
                          icon: Icons.map_outlined,
                          selectedIcon: Icons.map,
                          label: 'Level\nEditor',
                          selected: mode == AppMode.levelEditor,
                          onPressed: () => ref.read(appModeProvider.notifier).select(AppMode.levelEditor),
                        ),
                        const SizedBox(height: 16),
                        const Divider(indent: 12, endIndent: 12),
                        const SizedBox(height: 16),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                if (mode == AppMode.assetDefiner) ...[
                                  for (final cat in [
                                    BlockCategory.track,
                                    BlockCategory.islandTile,
                                    BlockCategory.decoration,
                                  ]) ...[
                                    _buildSidebarItem(
                                      context,
                                      label: categoryLabel(cat),
                                      selected: activeCategory == cat,
                                      onPressed: () => assetNotifier.setActiveCategory(cat),
                                      icon: switch (cat) {
                                        BlockCategory.track => Icons.alt_route,
                                        BlockCategory.islandTile => Icons.landscape,
                                        BlockCategory.decoration => Icons.park,
                                        _ => Icons.circle,
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                ] else if (mode == AppMode.levelEditor) ...[
                                  for (final layer in MapLayer.values) ...[
                                    _buildSidebarItem(
                                      context,
                                      label: layer.label,
                                      selected: activeLayer == layer,
                                      onPressed: () => levelNotifier.setLayer(layer),
                                      icon: switch (layer) {
                                        MapLayer.island => Icons.landscape,
                                        MapLayer.track => Icons.alt_route,
                                        MapLayer.decoration => Icons.park,
                                        MapLayer.function => Icons.settings_suggest,
                                      },
                                    ),
                                    const SizedBox(height: 12),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: switch (mode) {
                      AppMode.assetDefiner => const AssetDefinerPage(),
                      AppMode.levelEditor => const LevelEditorPage(),
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Desktop IDE-Style bottom Status Bar
            Container(
              height: 22,
              color: theme.colorScheme.surfaceContainerLow,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      mode == AppMode.assetDefiner
                          ? (assetStatusMessage ?? 'Asset Definer ready')
                          : (levelStatusMessage ?? 'Level Editor ready'),
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (mode == AppMode.levelEditor) ...[
                    Text(
                      '$placementsLength blocks placed',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                    const SizedBox(width: 16),
                    if (hasSpawn)
                      const Text(
                        'Spawn set',
                        style: TextStyle(color: Colors.greenAccent, fontSize: 11),
                      )
                    else
                      const Text(
                        'No Spawn',
                        style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return _buildRootShell(context, mainContent);
  }
}
