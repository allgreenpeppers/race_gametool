import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'asset_definer_providers.dart';

/// Bridges the native "open .rgpack" events (Finder double-click, "Open
/// With", or launching the app on a file) into the app. The macOS
/// AppDelegate forwards paths over the "app.rgpack/open" method channel;
/// a file the app was launched with is held natively until we ask for it.
class FileOpenService {
  FileOpenService(this._ref);

  final Ref _ref;
  static const _channel = MethodChannel('app.rgpack/open');
  bool _started = false;

  /// Wires up the channel and drains any file the app was launched with.
  /// Safe to call more than once.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openFile' && call.arguments is String) {
        await _open(call.arguments as String);
      }
      return null;
    });

    try {
      final pending = await _channel.invokeMethod<String>('getPendingFile');
      if (pending != null && pending.isNotEmpty) {
        await _open(pending);
      }
    } on MissingPluginException {
      // Not running on a platform that provides the channel (e.g. tests).
    }
  }

  Future<void> _open(String path) async {
    // Bring Phase 1 forward, then load the bundle into the editor.
    _ref.read(appModeProvider.notifier).select(AppMode.assetDefiner);
    await _ref.read(assetDefinerProvider.notifier).openBundleFromPath(path);
  }
}

/// Created once and kept alive for the app's lifetime.
final fileOpenServiceProvider =
    Provider<FileOpenService>((ref) => FileOpenService(ref));
