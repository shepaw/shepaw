import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Flutter 的 macOS embedder 不像独立 Dart VM 那样把 SIGPIPE 设成忽略，
  /// 因此任何写入已断开的管道（子进程 exec 失败、socket 被对端关闭）都会
  /// 以 signal 13 直接杀掉进程——没有崩溃报告，也不会走 applicationWillTerminate。
  /// 必须在引擎启动前设置，让 EPIPE 回到 Dart 层变成普通异常。
  override init() {
    super.init()
    signal(SIGPIPE, SIG_IGN)
    Self.migrateSandboxPreferencesIfNeeded()
  }

  /// 退出 App Sandbox 后 UserDefaults 从容器里的 plist 换到了 ~/Library/Preferences，
  /// 旧值（peer_device_id、应用锁状态、ACP token 等）不会自动跟过来。
  /// SharedPreferences 走的就是 UserDefaults，所以必须赶在引擎启动前补齐。
  private static func migrateSandboxPreferencesIfNeeded() {
    let defaults = UserDefaults.standard
    let marker = "shepaw.sandboxPreferencesMigrated"
    guard !defaults.bool(forKey: marker) else { return }
    defer { defaults.set(true, forKey: marker) }

    let legacy = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(
        "Library/Containers/com.shepaw.app/Data/Library/Preferences/com.shepaw.app.plist")
    guard let stored = NSDictionary(contentsOf: legacy) as? [String: Any] else { return }

    // 只搬 SharedPreferences 的键，AppKit 的窗口位置等旧状态不要带过来。
    for (key, value) in stored
    where key.hasPrefix("flutter.") && defaults.object(forKey: key) == nil {
      defaults.set(value, forKey: key)
    }
  }

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
