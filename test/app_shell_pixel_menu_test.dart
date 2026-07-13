import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:race_gametool/state/app_providers.dart';
import 'package:race_gametool/state/asset_definer_providers.dart';
import 'package:race_gametool/state/pixel_editor_providers.dart';
import 'package:race_gametool/models/block_def.dart';
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
    final pixelId = container.read(workspaceProvider).activePixelTab!;
    final initialSliders = tester.widgetList<Slider>(find.byType(Slider));
    final brushSlider = initialSliders.singleWhere(
      (slider) => slider.max == 32,
    );
    expect(brushSlider.min, 1);
    expect(brushSlider.max, 32);
    expect(brushSlider.divisions, 31);
    final opacitySlider = initialSliders.singleWhere(
      (slider) => slider.max == 1,
    );
    expect(opacitySlider.min, 0);
    expect(opacitySlider.divisions, 100);
    opacitySlider.onChanged!(0.42);
    await tester.pump();
    expect(
      container
          .read(pixelEditorProvider(pixelId))
          .document
          .layers
          .single
          .opacity,
      closeTo(0.42, 0.001),
    );
    expect(find.text('Move / Transform'), findsNothing);

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
    expect(shadedSliders, hasLength(4));
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 20));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'editing the same Asset Definer source activates its existing Pixel tab',
    (tester) async {
      final container = ProviderContainer();
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final source = img.Image(width: 16, height: 16, numChannels: 4)
        ..setPixelRgba(0, 0, 255, 0, 0, 255);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: AppShell()),
        ),
      );
      await tester.pump();

      final error = await tester.runAsync(
        () => container.read(assetDefinerProvider.notifier).importImageBytes(
              Uint8List.fromList(img.encodePng(source)),
              'track.png',
              BlockCategory.track,
            ),
      );
      expect(error, isNull);
      await tester.pump();

      await tester.tap(find.text('Edit in Pixel Editor'));
      await tester.pump();
      final firstId = container.read(workspaceProvider).activePixelTab;
      expect(firstId, isNotNull);
      expect(container.read(workspaceProvider).pixelTabs, hasLength(1));

      container.read(workspaceProvider.notifier).activatePhase1();
      await tester.pump();
      await tester.tap(find.text('Edit in Pixel Editor'));
      await tester.pump();

      final workspace = container.read(workspaceProvider);
      expect(workspace.pixelTabs, hasLength(1));
      expect(workspace.activePixelTab, firstId);

      await tester.pumpWidget(const SizedBox());
      container.dispose();
      await tester.pump(const Duration(milliseconds: 20));
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
