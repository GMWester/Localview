import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Keep running in the background: while Localview has connections or is hosting,
  /// closing the window only hides it (reopen from the Dock or by starting Localview again).
  static var keepAlive = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return !AppDelegate.keepAlive
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let w = mainFlutterWindow as? MainFlutterWindow {
      w.showAgain()
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
