import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../logic/level_diagnostics.dart';
import '../../state/level_editor_providers.dart';

/// IDE-style problems panel pinned to the bottom of the Level Editor.
/// Lists connection errors and unconnected-port warnings; clicking a row
/// selects the offending block on the canvas.
class DiagnosticsPanel extends ConsumerWidget {
  const DiagnosticsPanel({super.key, required this.tabId});

  final int tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final diagnostics = ref.watch(levelDiagnosticsProvider(tabId));
    final errors =
        diagnostics.where((d) => d.severity == DiagnosticSeverity.error).length;
    final warnings = diagnostics.length - errors;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          color: theme.colorScheme.surfaceContainerHigh,
          child: Row(
            children: [
              Text('Problems', style: theme.textTheme.labelLarge),
              const SizedBox(width: 16),
              _Count(
                icon: Icons.error_outline,
                color: theme.colorScheme.error,
                count: errors,
              ),
              const SizedBox(width: 12),
              _Count(
                icon: Icons.warning_amber_outlined,
                color: Colors.amber,
                count: warnings,
              ),
              const Spacer(),
              if (diagnostics.isEmpty)
                Text('No problems',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.greenAccent)),
            ],
          ),
        ),
        SizedBox(
          height: 132,
          child: diagnostics.isEmpty
              ? Center(
                  child: Text('Track is valid',
                      style: theme.textTheme.bodySmall),
                )
              : ListView.builder(
                  itemCount: diagnostics.length,
                  itemBuilder: (context, index) {
                    final d = diagnostics[index];
                    final isError = d.severity == DiagnosticSeverity.error;
                    return InkWell(
                      onTap: d.placementIndex == null
                          ? null
                          : () => ref
                              .read(levelEditorProvider(tabId).notifier)
                              .selectPlacement(d.placementIndex!),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              isError
                                  ? Icons.error_outline
                                  : Icons.warning_amber_outlined,
                              size: 16,
                              color: isError
                                  ? theme.colorScheme.error
                                  : Colors.amber,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(d.message,
                                  style: theme.textTheme.bodySmall),
                            ),
                            if (d.gridX != null && d.gridY != null)
                              Text('(${d.gridX}, ${d.gridY})',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.outline)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.color, required this.count});

  final IconData icon;
  final Color color;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 4),
        Text('$count', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
