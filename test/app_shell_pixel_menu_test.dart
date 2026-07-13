import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/pixel_editor_providers.dart';
import 'package:race_gametool/ui/app_shell.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const windowChannel = MethodChannel('window_manager');
  const fileOpenChannel = MethodChannel('app.rgpack/open');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, (call) async {
          if (call.method == 'isMaximized') return false;
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileOpenChannel, (_) async => null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileOpenChannel, null);
  });

  testWidgets('Pixel file actions and tools appear only for a Pixel tab', (
    tester,
  ) async {
    final container = ProviderContainer();
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AppShell()),
      ),
    );
    await tester.pump();

    List<String> fileLabels() {
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final file = bar.menus.whereType<PlatformMenu>().singleWhere(
        (menu) => menu.label == 'File',
      );
      return [
        for (final group in file.menus.whereType<PlatformMenuItemGroup>())
          for (final item in group.members) item.label,
      ];
    }

    expect(fileLabels(), isNot(contains('New Pixel Project...')));
    expect(fileLabels(), contains('New Config'));
    expect(find.text('Pencil'), findsNothing);

    container.read(workspaceProvider.notifier).openPixelTab();
    await tester.pump();

    expect(
      fileLabels(),
      containsAll([
        'New Pixel Project...',
        'Open Pixel Project...',
        'Import Image...',
        'Export PNG...',
      ]),
    );
    expect(fileLabels(), isNot(contains('New Config')));
    expect(
      find.text('Pencil'),
      findsOneWidget,
      reason: 'Pixel tools live in the left sidebar',
    );
    expect(tester.widget<Text>(find.text('Magic Wand')).maxLines, 2);
    expect(
      tester.getSize(find.byKey(const Key('pixel-options-toolbar'))).width,
      greaterThan(1200),
      reason: 'the toolbar background fills the editor width',
    );
    expect(
      tester.getCenter(find.text('Send to Asset Definer')).dx,
      greaterThan(1200),
      reason: 'Send stays pinned at the right edge',
    );
    expect(find.byType(Slider), findsOneWidget);
    final brushSlider = tester.widget<Slider>(find.byType(Slider));
    expect(brushSlider.min, 1);
    expect(brushSlider.max, 32);
    expect(brushSlider.divisions, 31);
    expect(find.text('Move / Transform'), findsNothing);

    final pixelId = container.read(workspaceProvider).activePixelTab!;
    container
        .read(pixelEditorProvider(pixelId).notifier)
        .setTool(PixelTool.fill);
    await tester.pump();
    final sliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(sliders.any((slider) => slider.max == 255), isTrue);
    expect(find.text('Shade variation'), findsOneWidget);
    container
        .read(pixelEditorPreferencesProvider.notifier)
        .setFillShadeEnabled(true);
    await tester.pump();
    final shadedSliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(shadedSliders, hasLength(3));
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 20));
    debugDefaultTargetPlatformOverride = null;
  });
}
