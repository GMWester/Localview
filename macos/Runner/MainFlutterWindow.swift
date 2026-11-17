import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var windowChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Extra viewer windows get their device / monitor as the title.
    if let title = ProcessInfo.processInfo.environment["LOCALVIEW_VIEWER_TITLE"] {
      self.title = title
    }

    // "localview/window": fullscreen for Theater mode.
    let channel = FlutterMethodChannel(
      name: "localview/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "setFullscreen" {
        let on = (call.arguments as? Bool) ?? false
        let isFull = self.styleMask.contains(.fullScreen)
        if on != isFull { self.toggleFullScreen(nil) }
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel

    super.awakeFromNib()
  }
}
