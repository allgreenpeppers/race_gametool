import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // Path of a .rgpack the app was asked to open before Flutter was ready
  // to receive it. Delivered when Dart calls "getPendingFile".
  private var pendingFilePath: String?
  private var openChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    guard let controller = mainFlutterWindow?.contentViewController
      as? FlutterViewController else { return }

    let channel = FlutterMethodChannel(
      name: "app.rgpack/open",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "getPendingFile" {
        result(self?.pendingFilePath)
        self?.pendingFilePath = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    openChannel = channel
  }

  // Files opened via Finder association or "Open With" arrive here.
  override func application(_ application: NSApplication, open urls: [URL]) {
    guard let path = urls.first(where: { $0.isFileURL })?.path else { return }
    if let channel = openChannel {
      channel.invokeMethod("openFile", arguments: path)
    } else {
      // Launched by opening the file: hold it until Dart asks.
      pendingFilePath = path
    }
  }
}
