import Cocoa
import FlutterMacOS
import Foundation

@main
class AppDelegate: FlutterAppDelegate {
  // Path of a .rgpack the app was asked to open before Flutter was ready
  // to receive it. Delivered when Dart calls "getPendingFile".
  private var pendingFilePath: String?
  private var isDartReady = false
  private var openChannel: FlutterMethodChannel?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSLog("AppDelegate: applicationDidFinishLaunching start")

    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "app.rgpack/open",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { [weak self] call, result in
        NSLog("AppDelegate: MethodChannel received call: \(call.method)")
        if call.method == "getPendingFile" {
          self?.isDartReady = true
          result(self?.pendingFilePath)
          NSLog("AppDelegate: getPendingFile returned: \(String(describing: self?.pendingFilePath))")
          self?.pendingFilePath = nil
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      openChannel = channel
      NSLog("AppDelegate: registered MethodChannel handler before super")
    } else {
      NSLog("AppDelegate: failed to get FlutterViewController before super")
    }

    super.applicationDidFinishLaunching(notification)
    NSLog("AppDelegate: applicationDidFinishLaunching complete")
  }

  // 1. Modern URL-based API
  override func application(_ application: NSApplication, open urls: [URL]) {
    NSLog("AppDelegate: open urls called with: \(urls)")
    guard let path = urls.first(where: { $0.isFileURL })?.path else {
      NSLog("AppDelegate: no valid file URL found in \(urls)")
      return
    }
    handleFileOpen(path)
  }

  // 2. Legacy AppKit multiple files API
  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    NSLog("AppDelegate: openFiles called with: \(filenames)")
    guard let path = filenames.first else { return }
    handleFileOpen(path)
    sender.reply(toOpenOrPrint: .success)
  }

  // 3. Legacy AppKit single file API
  override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    NSLog("AppDelegate: openFile called with: \(filename)")
    handleFileOpen(filename)
    return true
  }

  private func handleFileOpen(_ path: String) {
    if isDartReady, let channel = openChannel {
      NSLog("AppDelegate: Dart is ready, invoking openFile channel method with \(path)")
      channel.invokeMethod("openFile", arguments: path)
    } else {
      NSLog("AppDelegate: Dart not ready, storing pendingFilePath: \(path)")
      pendingFilePath = path
    }
  }
}
