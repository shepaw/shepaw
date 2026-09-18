import Cocoa
import FlutterMacOS
import desktop_multi_window

class MainFlutterWindow: NSWindow {
  /// 用户点过关闭按钮（Cmd+W 同理）后置位，由 AppDelegate 读取：
  /// applicationDidBecomeActive 的 Touch ID 兜底不能再把窗口拉回来，
  /// 否则关掉的窗口会在切回 App 时自己冒出来。点 Dock 图标时清零。
  private(set) var closedByUser = false

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
          window.revealToUser()
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

  /// 关闭按钮只隐藏窗口，不真的 close：Flutter 引擎与后台的 Peer / ACP 连接
  /// 必须活着，而窗口一旦 close，local_auth 的 Touch ID 面板收起时 AppKit 会
  /// 顺手杀掉进程。重新打开走 Dock 图标（applicationShouldHandleReopen）。
  override func performClose(_ sender: Any?) {
    closedByUser = true
    orderOut(nil)
  }

  func revealToUser() {
    closedByUser = false
    setIsVisible(true)
    makeKeyAndOrderFront(nil)
  }
}
