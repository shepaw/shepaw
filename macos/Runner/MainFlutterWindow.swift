import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 800, height: 400)
    isReleasedWhenClosed = false

    RegisterGeneratedPlugins(registry: flutterViewController)

    let windowChannel = FlutterMethodChannel(
      name: "shepaw/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setTitle":
        guard let title = call.arguments as? String else {
          result(FlutterError(
            code: "INVALID_ARGS",
            message: "Expected String title",
            details: nil
          ))
          return
        }
        DispatchQueue.main.async {
          self?.title = title
        }
        result(nil)
      case "focus":
        DispatchQueue.main.async {
          guard let window = self else { return }
          window.setIsVisible(true)
          window.makeKeyAndOrderFront(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    super.awakeFromNib()
  }
}
