import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// local_auth 的 Touch ID / 密码框关掉时，NSApp 会短暂认为没有可见窗口。
  /// 必须返回 false，否则登录成功后进程会退出。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows where window is MainFlutterWindow {
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(self)
      }
    }
    return true
  }

  /// 不要调 super：FlutterAppDelegate 没有实现这个 selector，
  /// Touch ID 关掉后 AppKit 一回调就会 unrecognized selector 崩掉。
  override func applicationDidBecomeActive(_ notification: Notification) {
    for window in NSApp.windows where window is MainFlutterWindow {
      if !window.isVisible {
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
      }
    }
  }

  override func applicationWillTerminate(_ notification: Notification) {
    Self.writeLifecycle("applicationWillTerminate")
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return false
  }

  private static func writeLifecycle(_ event: String) {
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let dir = docs.appendingPathComponent("logs")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("native_lifecycle.log")
    let line = "\(Date()) \(event)\n"
    if let data = line.data(using: .utf8) {
      if fm.fileExists(atPath: file.path) {
        if let handle = try? FileHandle(forWritingTo: file) {
          handle.seekToEndOfFile()
          handle.write(data)
          try? handle.close()
        }
      } else {
        try? data.write(to: file)
      }
    }
  }
}
