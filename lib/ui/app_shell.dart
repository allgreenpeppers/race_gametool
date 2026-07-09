import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_providers.dart';
import '../state/file_open_service.dart';
import 'phase1/asset_definer_page.dart';
import 'phase2/level_editor_page.dart';

/// Main shell: a NavigationRail switching between the two tool phases.
/// The active mode lives in Riverpod so any part of the app (for example
/// a "send to Level Editor" action in Phase 1) can switch modes.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    // Start listening for .rgpack files opened from Finder. Deferred to
    // after the first frame so the engine and providers are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(fileOpenServiceProvider).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(appModeProvider);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: mode.index,
            onDestinationSelected: (index) => ref
                .read(appModeProvider.notifier)
                .select(AppMode.values[index]),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.category_outlined),
                selectedIcon: Icon(Icons.category),
                label: Text('Asset\nDefiner', textAlign: TextAlign.center),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.map_outlined),
                selectedIcon: Icon(Icons.map),
                label: Text('Level\nEditor', textAlign: TextAlign.center),
              ),
            ],
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
    );
  }
}
